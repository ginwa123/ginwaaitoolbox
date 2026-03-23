# Fix Autospawn Backend on Port 8080 — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the dotnet autospawn to reliably start the nalar backend on port 8080 without killing nalar on port 8081.

**Architecture:** The C# autospawn implementation uses fork/daemon/exec to start `/usr/local/bin/nalar --port 8080` as a daemon. The current implementation has silent failures in daemon() and execvp() calls, and uses HttpClient which has connection pooling issues. We'll fix by: (1) using raw sockets for backend checks, (2) improving error reporting, (3) adding setsid() for proper daemonization, and (4) increasing wait times.

**Tech Stack:** C# (.NET), P/Invoke to libc (fork, setsid, daemon, execv), raw POSIX sockets

---

## Exploration Synthesis

### What We Set Out to Discover
1. Where is the autospawn logic?
2. Why does it fail with "Connection refused" on port 8080?
3. Is the nalar binary broken?

### Findings per Agent

| Agent | Target | Answer | Confidence | Key Evidence |
|-------|--------|--------|------------|--------------|
| find-autospawn | C# Program.cs | Found autospawn in BackendManager class, lines 86-198 | high | Lines 142-167 show fork/daemon/execvp |
| check-ports | System ports | Port 8080 is FREE, 8081 occupied by nalar | high | `ss -tlnp` shows nalar on 8081 |
| test-nalar-startup | nalar binary | nalar works correctly on 8080 | high | curl returns 200, no errors |
| read-csharp-spawner | Program.cs full | daemon/exec failures are silent | high | Lines 162-164, 169-171 exit silently |
| read-zig-spawner | backend.zig | Zig uses execl() + realpath, C# uses execv() | high | Lines 10, 71 in Zig vs lines 63, 66 in C# |

### Hypothesis Verdict
**CONFIRMED with specifics:** The nalar binary works fine. The problem is in the C# autospawn logic:
1. daemon() failure exits silently (parent thinks success)
2. execvp() failure exits silently (parent thinks success)  
3. HttpClient connection caching causes spurious failures
4. Manual argv construction in execv() may have bugs

### Root Causes
1. **Silent failures** — daemon() and execvp() errors cause child to exit without notifying parent
2. **No setsid()** — daemon() alone may not fully detach from controlling terminal
3. **HttpClient issues** — connection pooling and 500ms timeout too short
4. **No realpath()** — symlinks not resolved before exec

---

## Chunk 1: Fix Backend Path Resolution & Backend Check

**Files:**
- Modify: `src/apps/tuicsharp/Program.cs:92-105` (IsBackendRunning)
- Modify: `src/apps/tuicsharp/Program.cs:126-134` (path check)

- [ ] **Step 1: Read current Program.cs to get exact code**

Run: `read_file src/apps/tuicsharp/Program.cs`

- [ ] **Step 2: Replace IsBackendRunning with raw socket (lines 92-105)**

Replace the HttpClient-based backend check with raw POSIX socket:

```csharp
private static bool IsBackendRunning(int port)
{
    try
    {
        using var socket = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
        socket.ReceiveTimeout = 500;  // 500ms
        socket.SendTimeout = 500;
        socket.Connect("127.0.0.1", port);
        return true;  // If connect succeeds, backend is running
    }
    catch (SocketException)
    {
        return false;
    }
    catch
    {
        return false;
    }
}
```

- [ ] **Step 3: Add realpath() P/Invoke declaration**

Add after existing NativeMethods class (around line 24):

```csharp
[DllImport("libc", SetLastError = true)]
private static extern IntPtr realpath(string path, IntPtr resolved_path);
```

- [ ] **Step 4: Add ResolveBackendPath helper method**

Add after IsBackendRunning (around line 106):

```csharp
private static string? ResolveBackendPath()
{
    // Try to resolve the real path of the backend binary
    var path = "/usr/local/bin/nalar";
    
    // Method 1: Try realpath first
    var resolved = realpath(path, IntPtr.Zero);
    if (resolved != IntPtr.Zero)
    {
        var resolvedStr = Marshal.PtrToStringAuto(resolved);
        if (File.Exists(resolvedStr))
            return resolvedStr;
    }
    
    // Method 2: Fallback to File.Exists on original path
    if (File.Exists(path))
        return path;
    
    return null;
}
```

- [ ] **Step 5: Update backend path check (lines 126-134)**

Replace:
```csharp
var backendPath = "/usr/local/bin/nalar";
if (!File.Exists(backendPath))
{
    if (verbose) AnsiConsole.MarkupLine($"[red]Backend not found at {backendPath}[/]");
    return false;
}
```

With:
```csharp
var backendPath = ResolveBackendPath();
if (backendPath == null)
{
    if (verbose) AnsiConsole.MarkupLine("[red]Backend not found at /usr/local/bin/nalar[/]");
    return false;
}
if (verbose) AnsiConsole.MarkupLine($"[dim]Using backend: {backendPath}[/]");
```

- [ ] **Step 6: Build and verify**

Run: `cd src/apps/tuicsharp && dotnet build 2>&1 | head -n 50`
Expected: SUCCESS (no compilation errors)

- [ ] **Step 7: Commit**

```bash
git add src/apps/tuicsharp/Program.cs
git commit -m "fix(tuicsharp): use raw socket for backend check and resolve symlinks"
```

---

## Chunk 2: Fix Daemonization with setsid()

**Files:**
- Modify: `src/apps/tuicsharp/NativeMethods.cs` (if exists) or `Program.cs`

- [ ] **Step 1: Check if NativeMethods.cs exists**

Run: `ls -la src/apps/tuicsharp/*.cs | head -n 20`

- [ ] **Step 2: Add setsid() P/Invoke**

If NativeMethods.cs exists, add to it. Otherwise, add to Program.cs near other P/Invoke declarations:

```csharp
[DllImport("libc", SetLastError = true)]
private static extern int setsid();
```

- [ ] **Step 3: Update daemon() call to include setsid()**

Find the child process code (around line 159) and update:

Replace:
```csharp
// Child process - daemonize and run the backend
// daemon(1, 0) - change to / and close stdio
if (NativeMethods.daemon(1, 0) != 0)
{
    Environment.Exit(1);
}
```

With:
```csharp
// Child process - detach from controlling terminal
// First, create new session with setsid()
// Then daemonize with daemon(1, 0) - nochdir=1 (keep cwd), noclose=0 (keep fd)
if (NativeMethods.setsid() < 0)
{
    // Log error to stderr before exit
    Console.Error.WriteLine($"setsid failed: {Marshal.GetLastWin32Error()}");
    Environment.Exit(1);
}

// Daemonize - change to / and close stdin/stdout/stderr
if (NativeMethods.daemon(1, 0) != 0)
{
    Console.Error.WriteLine($"daemon failed: {Marshal.GetLastWin32Error()}");
    Environment.Exit(1);
}
```

- [ ] **Step 4: Build and verify**

Run: `cd src/apps/tuicsharp && dotnet build 2>&1 | head -n 50`
Expected: SUCCESS

- [ ] **Step 5: Commit**

```bash
git add src/apps/tuicsharp/Program.cs  # or NativeMethods.cs if created
git commit -m "fix(tuicsharp): add setsid() before daemon() for proper session detachment"
```

---

## Chunk 3: Fix execvp() with Better Error Handling

**Files:**
- Modify: `src/apps/tuicsharp/Program.cs:66-170`

- [ ] **Step 1: Read current exec implementation**

Run: `read_file src/apps/tuicsharp/Program.cs:60-75` to see current argv construction

- [ ] **Step 2: Add Pipe for Child-to-Parent Communication**

Before fork() (around line 138), add:

```csharp
// Create pipe for child to report errors to parent
int[] errorPipe = new int[2];
if (NativeMethods.pipe(errorPipe) < 0)
{
    if (verbose) AnsiConsole.MarkupLine("[red]pipe() failed[/]");
    return false;
}
```

- [ ] **Step 3: Update child process code to use pipe for error reporting**

Replace the child process section (lines 159-171) with:

```csharp
// Child process
close(errorPipe[0]);  // Close read end in child

// First, create new session
if (NativeMethods.setsid() < 0)
{
    // Report error to parent via pipe
    var err = Marshal.GetLastWin32Error();
    write(errorPipe[1], ref err, sizeof(int));
    close(errorPipe[1]);
    Environment.Exit(1);
}

// Daemonize
if (NativeMethods.daemon(1, 0) != 0)
{
    var err = Marshal.GetLastWin32Error();
    write(errorPipe[1], ref err, sizeof(int));
    close(errorPipe[1]);
    Environment.Exit(1);
}

// Execute nalar
var argv = new List<IntPtr>();
argv.Add(Marshal.StringToHGlobalAnsi(backendPath));  // argv[0] = program name
argv.Add(Marshal.StringToHGlobalAnsi("--port"));
argv.Add(Marshal.StringToHGlobalAnsi(port.ToString()));
argv.Add(IntPtr.Zero);  // NULL terminator

var execResult = NativeMethods.execv(backendPath, argv.ToArray());

// If we get here, exec failed - report error to parent
var errno = Marshal.GetLastWin32Error();
write(errorPipe[1], ref errno, sizeof(int));
close(errorPipe[1]);

// Free allocated strings
foreach (var ptr in argv)
    Marshal.FreeHGlobal(ptr);

Environment.Exit(1);
```

- [ ] **Step 4: Update parent process to read from pipe**

After fork() (around line 152), update parent code:

Replace:
```csharp
if (pid != IntPtr.Zero)
{
    // Parent process - return immediately after giving child time to start
    NativeMethods.usleep(500000); // 500ms
    return true;
}
```

With:
```csharp
if (pid != IntPtr.Zero)
{
    // Parent process
    close(errorPipe[1]);  // Close write end in parent
    
    // Give child time to start
    NativeMethods.usleep(500000); // 500ms
    
    // Check if child reported an error via pipe
    var childPid = NativeMethods.waitpid(pid, out var status, 0);
    if (childPid > 0 && status != 0)
    {
        // Non-zero status means child exited with error
        if (verbose) AnsiConsole.MarkupLine($"[red]Backend failed to start (status {status})[/]");
        return false;
    }
    
    // Child is still running (or already daemonized) - success
    return true;
}
```

**Note:** This is a simplified version. For a more robust implementation, we may need to use non-blocking I/O or a timeout. For now, we'll use the 500ms wait approach but with proper error capture.

- [ ] **Step 5: Simplify for safety — use blocking pipe read with timeout**

Actually, since daemon() detaches the child, we can't waitpid() on it directly (it becomes a daemon managed by init). Let's simplify:

```csharp
if (pid != IntPtr.Zero)
{
    // Parent process
    close(errorPipe[1]);  // Close write end
    
    // Set pipe to non-blocking
    NativeMethods.fcntl(errorPipe[0], NativeMethods.F_SETFL, NativeMethods.O_NONBLOCK);
    
    // Give child some time to potentially report an error
    NativeMethods.usleep(100000); // 100ms
    
    // Try to read any error code
    int errorCode = 0;
    var bytesRead = read(errorPipe[0], ref errorCode, sizeof(int));
    close(errorPipe[0]);
    
    if (bytesRead > 0 && errorCode != 0)
    {
        if (verbose) AnsiConsole.MarkupLine($"[red]Backend failed: errno {errorCode}[/]");
        return false;
    }
    
    // Give daemon more time to fully start
    NativeMethods.usleep(400000); // 400ms more
    
    return true;
}
```

- [ ] **Step 6: Build and verify**

Run: `cd src/apps/tuicsharp && dotnet build 2>&1 | head -n 50`
Expected: SUCCESS

- [ ] **Step 7: Commit**

```bash
git add src/apps/tuicsharp/Program.cs
git commit -m "fix(tuicsharp): add pipe-based error reporting from child to parent"
```

---

## Chunk 4: Increase Wait Times and Improve Diagnostics

**Files:**
- Modify: `src/apps/tuicsharp/Program.cs`

- [ ] **Step 1: Increase waitForHttpServer timeout**

Find WaitForHttpServerAsync (around line 175) and update:

```csharp
private static async Task<bool> WaitForHttpServerAsync(int timeoutMs, int port, CancellationToken cancellationToken = default)
{
    var endTime = DateTime.UtcNow.AddMilliseconds(timeoutMs);
    
    while (DateTime.UtcNow < endTime)
    {
        cancellationToken.ThrowIfCancellationRequested();
        
        try
        {
            using var socket = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
            socket.ReceiveTimeout = 100;
            socket.SendTimeout = 100;
            socket.Connect("127.0.0.1", port);
            
            // Socket connected - now try HTTP request
            var request = "GET /api/session HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n";
            var requestBytes = System.Text.Encoding.ASCII.GetBytes(request);
            socket.Send(requestBytes);
            
            var buffer = new byte[1024];
            var bytesReceived = socket.Receive(buffer);
            var response = System.Text.Encoding.ASCII.GetString(buffer, 0, bytesReceived);
            
            // Check for HTTP 200 OK
            if (response.Contains("200 OK") || response.Contains("200"))
            {
                return true;
            }
        }
        catch
        {
            // Socket connect or receive failed - retry
        }
        
        await Task.Delay(50, cancellationToken);
    }
    
    return false;
}
```

- [ ] **Step 2: Add diagnostic output before "Connection refused" error**

Find where the "Connection refused" error is thrown (after WaitForHttpServerAsync) and add diagnostics:

```csharp
// Check again after waiting
var isRunning = IsBackendRunning(port);
if (!isRunning)
{
    // More diagnostic output
    if (verbose)
    {
        AnsiConsole.MarkupLine("[yellow]Backend check failed. Debugging...[/]");
        
        // Check if binary exists
        var backendPath = ResolveBackendPath();
        if (backendPath != null)
            AnsiConsole.MarkupLine($"[dim]  Binary exists: {backendPath}[/]");
        else
            AnsiConsole.MarkupLine("[red]  Binary NOT found![/]");
        
        // Check what process is on port (if any)
        AnsiConsole.MarkupLine("[dim]  Note: If nalar is on port 8081, you're querying the wrong port[/]");
    }
}
```

- [ ] **Step 3: Build and verify**

Run: `cd src/apps/tuicsharp && dotnet build 2>&1 | head -n 50`
Expected: SUCCESS

- [ ] **Step 4: Commit**

```bash
git add src/apps/tuicsharp/Program.cs
git commit -m "fix(tuicsharp): improve wait times and add diagnostic output"
```

---

## Chunk 5: Integration Testing

**Files:**
- Modify: `src/apps/tuicsharp/Program.cs` (no functional changes, just cleanup)

- [ ] **Step 1: Test the autospawn flow**

```bash
# First, make sure no nalar on 8080
ss -tlnp | grep 8080 || echo "Port 8080 is free"

# Kill any existing test instance
pkill -f "nalar.*8080" 2>/dev/null || true

# Wait a moment
sleep 1

# Run the dotnet command
cd src/apps/tuicsharp && dotnet run -q "show me your current working directory"
```

Expected output: Should successfully connect and respond (no "Connection refused")

- [ ] **Step 2: Verify nalar on 8081 is untouched**

```bash
ss -tlnp | grep 8081
ps aux | grep nalar | grep -v grep
```

Expected: nalar on 8081 is still running

- [ ] **Step 3: Verify nalar started on 8080**

```bash
ss -tlnp | grep 8080
curl -s http://127.0.0.1:8080/api/session | head -n 5
```

Expected: nalar listening on 8080, curl returns 200

- [ ] **Step 4: Cleanup test instance**

```bash
pkill -f "nalar.*8080" 2>/dev/null || true
```

- [ ] **Step 5: Final commit with all changes**

```bash
git add -A
git commit -m "fix(tuicsharp): comprehensive autospawn fixes

- Use raw sockets for backend checks (not HttpClient)
- Add realpath() to resolve symlinks
- Add setsid() before daemon() for proper session detachment
- Add pipe-based error reporting from child to parent
- Increase wait times and add diagnostics
- Fix all silent failure modes"
```

---

## Checkpoints

### After Chunk 1
- [ ] `dotnet build` succeeds
- [ ] IsBackendRunning uses raw sockets
- [ ] Backend path is resolved via realpath()

### After Chunk 2
- [ ] `dotnet build` succeeds
- [ ] setsid() is called before daemon()

### After Chunk 3
- [ ] `dotnet build` succeeds
- [ ] Pipe-based error reporting is in place

### After Chunk 4
- [ ] `dotnet build` succeeds
- [ ] WaitForHttpServerAsync has improved timeout handling

### After Chunk 5 (Final)
- [ ] `dotnet run -q "..."` succeeds without "Connection refused"
- [ ] nalar on 8081 is NOT killed
- [ ] nalar starts successfully on 8080

---

## Fallback

If Chunk 3 (pipe-based error reporting) is too complex or causes issues:
- Simplify by just improving the diagnostic output in Chunk 4
- The key fix is Chunk 1 (raw sockets) and Chunk 2 (setsid)
- Pipe error reporting is nice-to-have for better debugging

If the issue persists after all chunks:
- Check if systemd is managing a nalar instance that conflicts
- Check if SELinux or AppArmor is blocking the exec
- Check if the nalar binary has the execute bit set

---

## Open Questions

1. **Should we use systemd to manage nalar instead of manual fork/daemon?** — Current approach works but systemd would be more robust
2. **Should the default port be configurable?** — Currently hardcoded to 8080
3. **Should we support multiple nalar instances?** — Currently only one instance supported

These are out of scope for this fix but worth noting for future improvements.
