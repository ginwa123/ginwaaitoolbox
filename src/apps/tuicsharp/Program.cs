using System;
using System.IO;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Diagnostics;
using System.Runtime.InteropServices;
using Spectre.Console;
using Spectre.Console.Cli;
using System.ComponentModel;

namespace MyCli;

internal static partial class NativeMethods
{
    [DllImport("libc", SetLastError = true)]
    public static extern IntPtr fork();

    [DllImport("libc", SetLastError = true)]
    public static extern int daemon(int nochdir, int noclose);

    [DllImport("libc", SetLastError = true)]
    public static extern int execv(string path, IntPtr argv);

    [DllImport("libc", SetLastError = true)]
    public static extern IntPtr malloc(IntPtr size);

    [DllImport("libc", SetLastError = true)]
    public static extern void free(IntPtr ptr);

    /// Execute a program with the given arguments
    public static void execvp(string file, string[] args)
    {
        // Build argument array with null terminator
        var argc = args.Length + 2; // program name + args + null
        var argvPtrs = new IntPtr[argc];

        // Allocate array of pointers (8 bytes each on 64-bit)
        var argvSize = (IntPtr)(argc * IntPtr.Size);
        var argv = malloc(argvSize);
        if (argv == IntPtr.Zero) Environment.Exit(1);

        var strPtrs = new List<IntPtr>();

        try
        {
            // First arg is program name
            var progPtr = Marshal.StringToHGlobalAnsi(file);
            strPtrs.Add(progPtr);
            Marshal.WriteIntPtr(argv, 0, progPtr);

            // Remaining args
            for (int i = 0; i < args.Length; i++)
            {
                var argPtr = Marshal.StringToHGlobalAnsi(args[i]);
                strPtrs.Add(argPtr);
                Marshal.WriteIntPtr(argv, i * IntPtr.Size + IntPtr.Size, argPtr);
            }

            // Null terminator
            Marshal.WriteIntPtr(argv, args.Length * IntPtr.Size + IntPtr.Size, IntPtr.Zero);

            // execv replaces this process
            execv(file, argv);

            // If we get here, exec failed
            Environment.Exit(1);
        }
        finally
        {
            // Free all allocated strings
            foreach (var ptr in strPtrs)
            {
                Marshal.FreeHGlobal(ptr);
            }
            free(argv);
        }
    }

    [DllImport("libc", SetLastError = true)]
    public static extern int usleep(uint usec);

    [DllImport("libc", SetLastError = true)]
    public static extern IntPtr realpath(string path, IntPtr resolved_path);

    [DllImport("libc", SetLastError = true)]
    public static extern int setsid();

    [DllImport("libc")]
    public static extern void _exit(int status);
}

/// Spawn the backend server as a daemon process (mirrors Zig backend.zig)
internal static class BackendManager
{
    private const int DefaultPort = 8080;

    /// Check if backend is already running by trying to connect to HTTP port
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
        catch
        {
            return false;
        }
    }

    /// Resolve the real path of the backend binary (handles symlinks)
    private static string? ResolveBackendPath()
    {
        var path = "/usr/local/bin/nalar";

        // Method 1: Try realpath first to resolve symlinks
        var resolved = NativeMethods.realpath(path, IntPtr.Zero);
        if (resolved != IntPtr.Zero)
        {
            var resolvedStr = Marshal.PtrToStringAnsi(resolved);
            if (File.Exists(resolvedStr))
                return resolvedStr;
        }

        // Method 2: Fallback to File.Exists on original path
        if (File.Exists(path))
            return path;

        return null;
    }

    /// Public version for debugging (exposes ResolveBackendPath)
    public static string? ResolveBackendPathForDebug()
    {
        return ResolveBackendPath();
    }

    /// Spawn the nalar backend as a daemon process
    public static bool SpawnBackend(bool verbose, int port = DefaultPort)
    {
        if (verbose)
        {
            AnsiConsole.MarkupLine($"[dim]Checking if backend is already running on port {port}...[/]");
        }

        // Check if backend is already running
        if (IsBackendRunning(port))
        {
            if (verbose)
            {
                AnsiConsole.MarkupLine($"[green]Backend already running, skipping spawn[/]");
            }
            return true;
        }

        // Get the backend path with symlink resolution
        var backendPath = ResolveBackendPath();
        if (backendPath == null)
        {
            if (verbose)
            {
                AnsiConsole.MarkupLine("[red]Backend not found at /usr/local/bin/nalar[/]");
            }
            return false;
        }

        if (verbose)
        {
            AnsiConsole.MarkupLine($"[yellow]Spawning backend on port {port}...[/]");
        }

        // Use native_daemon helper to avoid .NET's problematic fork() semantics
        // The native helper does fork/setsid/daemon/exec in one step
        var nativeDaemonPath = Path.Combine(AppContext.BaseDirectory, "native_daemon");
        if (!File.Exists(nativeDaemonPath))
        {
            // Try local build path
            nativeDaemonPath = "/home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/tuicsharp/native_daemon";
        }

        if (!File.Exists(nativeDaemonPath))
        {
            if (verbose)
            {
                AnsiConsole.MarkupLine($"[red]native_daemon helper not found at {nativeDaemonPath}[/]");
            }
            return false;
        }

        // Spawn via native_daemon: it handles fork/setsid/daemon/exec properly
        var startInfo = new ProcessStartInfo
        {
            FileName = nativeDaemonPath,
            Arguments = $"{backendPath} --port {port}",
            UseShellExecute = false,
            CreateNoWindow = true
        };

        try
        {
            using var process = Process.Start(startInfo);
            if (process != null)
            {
                // Wait a moment for the process to spawn and daemonize
                Thread.Sleep(500);

                // Check if process exited immediately (failure)
                if (process.HasExited && process.ExitCode != 0)
                {
                    if (verbose)
                    {
                        AnsiConsole.MarkupLine($"[red]native_daemon failed with exit code {process.ExitCode}[/]");
                    }
                    return false;
                }
            }

            if (verbose)
            {
                AnsiConsole.MarkupLine("[dim]Backend spawned via native daemon[/]");
            }
            return true;
        }
        catch (Exception ex)
        {
            if (verbose)
            {
                AnsiConsole.MarkupLine($"[red]Failed to spawn backend: {ex.Message}[/]");
            }
            return false;
        }
    }

    /// Wait for the HTTP server to become available
    public static async Task<bool> WaitForHttpServerAsync(int timeoutMs = 5000, int port = DefaultPort)
    {
        var deadline = DateTimeOffset.UtcNow.AddMilliseconds(timeoutMs);

        while (DateTimeOffset.UtcNow < deadline)
        {
            try
            {
                // Use raw socket for faster, more reliable check
                using var socket = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
                socket.ReceiveTimeout = 100;
                socket.SendTimeout = 100;
                socket.Connect("127.0.0.1", port);

                // Socket connected - now try HTTP request
                var request = "GET /api/session HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n";
                var requestBytes = Encoding.ASCII.GetBytes(request);
                socket.Send(requestBytes);

                var buffer = new byte[1024];
                var bytesReceived = socket.Receive(buffer);
                var response = Encoding.ASCII.GetString(buffer, 0, bytesReceived);

                // Check for HTTP 200 OK
                if (response.Contains("200"))
                {
                    return true;
                }
            }
            catch
            {
                // Socket connect or receive failed - retry
            }
            await Task.Delay(50);
        }
        return false;
    }
}

public class DefaultCommand : AsyncCommand<DefaultCommand.Settings>
{
    private const string HttpHost = "127.0.0.1";
    private const int DefaultPort = 8080;

    public class Settings : CommandSettings
    {
        [CommandOption("-c|--config")]
        [Description("Configuration path or value")]
        public string? Config { get; init; }

        [CommandOption("-q|--query")]
        [Description("Query string to send to LLM")]
        public string? Query { get; init; }

        [CommandOption("-p|--port")]
        [Description("HTTP server port (default: 8080)")]
        public int Port { get; init; } = DefaultPort;

        [CommandOption("-h|--help")]
        [Description("Show help information")]
        public bool Help { get; init; }
    }

    public override async Task<int> ExecuteAsync(CommandContext context, Settings settings, CancellationToken cancellationToken)
    {
        if (settings.Help || string.IsNullOrEmpty(settings.Query))
        {
            ShowHelp();
            return 0;
        }

        var port = settings.Port > 0 ? settings.Port : DefaultPort;

        if (!string.IsNullOrEmpty(settings.Config))
        {
            AnsiConsole.MarkupLine($"[green]Config:[/] {settings.Config}");
        }

        // Try to spawn the backend first
        if (!BackendManager.SpawnBackend(verbose: true, port: port))
        {
            // Check again if it's already running (maybe just wasn't before)
            var isBackendRunning = await CheckBackendAsync(port);
            if (!isBackendRunning)
            {
                AnsiConsole.MarkupLine("[yellow]Backend not running. Please start the nalar server first.[/]");
                return 1;
            }
        }

        // Wait for the backend to be ready
        AnsiConsole.MarkupLine("[dim]Waiting for backend to be ready...[/]");
        var isReady = await BackendManager.WaitForHttpServerAsync(timeoutMs: 5000, port: port);
        if (!isReady)
        {
            // More diagnostic output
            AnsiConsole.MarkupLine("[yellow]Backend check failed. Debugging...[/]");

            // Check if binary exists
            var debugBackendPath = BackendManager.ResolveBackendPathForDebug();
            if (debugBackendPath != null)
                AnsiConsole.MarkupLine($"[dim]  Binary exists: {debugBackendPath}[/]");
            else
                AnsiConsole.MarkupLine("[red]  Binary NOT found![/]");

            // Check what process is on port (if any)
            try
            {
                using var socket = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
                socket.Connect("127.0.0.1", port);
                AnsiConsole.MarkupLine($"[dim]  Port {port} is open but not responding to /api/session[/]");
            }
            catch
            {
                AnsiConsole.MarkupLine($"[dim]  Port {port} is not accepting connections[/]");
            }

            AnsiConsole.MarkupLine("[yellow]Backend may not be fully ready, proceeding anyway...[/]");
        }

        AnsiConsole.MarkupLine("[dim]Sending query to LLM...[/]");

        // Run synchronous streaming in a task
        await Task.Run(() => StreamLlmResponse(settings.Query, port), cancellationToken);

        return 0;
    }

    private static async Task<bool> CheckBackendAsync(int port)
    {
        try
        {
            using var client = new HttpClient();
            client.Timeout = TimeSpan.FromSeconds(2);
            var response = await client.GetAsync($"http://{HttpHost}:{port}/api/session");
            return response.IsSuccessStatusCode;
        }
        catch
        {
            return false;
        }
    }

    private static void StreamLlmResponse(string query, int port)
    {
        string sessionId = $"session_{DateTimeOffset.UtcNow.ToUnixTimeSeconds()}";
        Socket? sseSocket = null;
        Socket? postSocket = null;

        try
        {
            // Create SSE socket
            sseSocket = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
            sseSocket.NoDelay = true;
            sseSocket.Connect(HttpHost, port);

            // Send SSE subscription
            var sseRequest = $"GET /api/stream/{sessionId} HTTP/1.1\r\nHost: {HttpHost}:{port}\r\nAccept: text/event-stream\r\nConnection: keep-alive\r\n\r\n";
            sseSocket.Send(Encoding.UTF8.GetBytes(sseRequest));

            // Wait for connected
            if (!WaitForConnected(sseSocket, 5000))
            {
                AnsiConsole.MarkupLine("[red]Failed to connect[/]");
                return;
            }

            // Send message via POST
            var jsonPayload = JsonSerializer.Serialize(new
            {
                app_type = "cli",
                command_type = "run_llm",
                session_id = sessionId,
                content = EscapeJsonString(query),
                cwd_session = Environment.CurrentDirectory
            });

            postSocket = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
            postSocket.Connect(HttpHost, port);

            var postRequest = $"POST /api/command HTTP/1.1\r\nHost: {HttpHost}:{port}\r\nContent-Type: application/json\r\nContent-Length: {jsonPayload.Length}\r\n\r\n{jsonPayload}";
            postSocket.Send(Encoding.UTF8.GetBytes(postRequest));
            postSocket.Close();
            postSocket = null;

            // Stream response
            AnsiConsole.Markup("[bold cyan]Response:[/] ");
            StreamResponse(sseSocket);
            AnsiConsole.WriteLine();
        }
        catch (Exception ex)
        {
            AnsiConsole.MarkupLine($"\n[red]Error: {ex.Message}[/]");
        }
        finally
        {
            sseSocket?.Close();
            postSocket?.Close();
        }
    }

    private static bool WaitForConnected(Socket socket, int timeoutMs)
    {
        var buffer = new byte[4096];
        var sb = new StringBuilder();
        var deadline = DateTime.UtcNow.AddMilliseconds(timeoutMs);

        while (DateTime.UtcNow < deadline)
        {
            if (socket.Poll(100000, SelectMode.SelectRead))
            {
                int n = socket.Receive(buffer);
                if (n > 0)
                {
                    sb.Append(Encoding.UTF8.GetString(buffer, 0, n));
                    if (sb.ToString().Contains("event: connected")) return true;
                }
                else return false;
            }
        }
        return false;
    }

    private static void StreamResponse(Socket socket)
    {
        var buffer = new byte[16384];
        var rawBuffer = new StringBuilder();
        bool foundResponse = false;
        int loopCount = 0;

        while (true)
        {
            if (socket.Poll(100000, SelectMode.SelectRead))
            {
                int n = socket.Receive(buffer);
                if (n == 0) break;

                rawBuffer.Append(Encoding.UTF8.GetString(buffer, 0, n));

                // Process all complete SSE events in the buffer
                foundResponse = ProcessSseBuffer(rawBuffer, foundResponse);

                // Check for finish
                if (rawBuffer.ToString().Contains("</finish_reason>"))
                {
                    break;
                }
            }
            loopCount++;
            if (loopCount > 1000)
            {
                break;
            }
        }

        if (!foundResponse) AnsiConsole.Markup("[dim](no response)[/]");
    }

    /// Process the raw buffer to extract and display SSE events
    internal static bool ProcessSseBuffer(StringBuilder rawBuffer, bool foundResponse)
    {
        var raw = rawBuffer.ToString();

        // Skip HTTP headers to get body
        var headerEnd = raw.IndexOf("\r\n\r\n");
        var body = (headerEnd >= 0) ? raw.Substring(headerEnd + 4) : raw;

        if (string.IsNullOrEmpty(body)) return foundResponse;

        // Decode chunked transfer encoding if present
        var decodedBody = TryDecodeChunked(body);

        if (string.IsNullOrEmpty(decodedBody)) return foundResponse;

        // Parse SSE format: "event: type\ndata: content\ndata: more\n\n"
        // The double newline separates events

        // Split by double newline to get event chunks
        var eventChunks = decodedBody.Split(new string[] { "\n\n" }, StringSplitOptions.None);

        foreach (var chunk in eventChunks)
        {
            if (string.IsNullOrEmpty(chunk)) continue;

            // Parse this event chunk - extract event type and data
            var eventType = "";
            var eventData = new StringBuilder();

            // Split by single newline to process each line
            var lines = chunk.Split('\n');
            foreach (var line in lines)
            {
                var trimmed = line.TrimEnd('\r');
                trimmed = trimmed.Trim();

                // Skip empty lines
                if (string.IsNullOrEmpty(trimmed)) continue;

                // Skip comment lines (keepalive)
                if (trimmed.StartsWith(":")) continue;

                // Event type
                if (trimmed.StartsWith("event:"))
                {
                    eventType = trimmed.Substring(6).Trim();
                    continue;
                }

                // Data line
                if (trimmed.StartsWith("data:"))
                {
                    eventData.Append(trimmed.Substring(5));
                    continue;
                }

                // Continuation of data
                eventData.Append(trimmed);
            }

            // Process this event's data
            var dataStr = eventData.ToString();
            if (!string.IsNullOrEmpty(dataStr))
            {
                foundResponse = ParseAndDisplayXml(dataStr, foundResponse);
                if (foundResponse) break;
            }
        }

        return foundResponse;
    }

    /// Try to decode chunked transfer encoding, return original if not chunked
    internal static string TryDecodeChunked(string body)
    {
        // Chunked transfer encoding format:
        // size\r\n
        // data (exactly 'size' bytes, may contain \r\n)\r\n
        // ... repeat ...
        // 0\r\n
        // \r\n

        var pos = 0;
        var result = new StringBuilder();
        var isChunked = false;

        while (pos < body.Length)
        {
            // Find end of size line
            var lineEnd = body.IndexOf('\n', pos);
            if (lineEnd == -1) break;

            var sizeLine = body.Substring(pos, lineEnd - pos).Trim();
            pos = lineEnd + 1;

            if (string.IsNullOrEmpty(sizeLine)) continue;

            // Parse hex chunk size
            if (!int.TryParse(sizeLine, System.Globalization.NumberStyles.HexNumber, null, out int size))
            {
                break;
            }

            isChunked = true;

            if (size == 0) break; // End of chunks

            // Extract chunk data (exactly 'size' bytes, including any \r\n within)
            if (pos + size > body.Length) break;

            result.Append(body.Substring(pos, size));
            pos += size;

            // Skip trailing \r\n after chunk data
            if (pos < body.Length && body[pos] == '\r') pos++;
            if (pos < body.Length && body[pos] == '\n') pos++;
        }

        return isChunked ? result.ToString() : body;
    }

    /// Parse XML content and display response/tool_result tags
    /// need testing
    private static bool ParseAndDisplayXml(string xmlContent, bool foundResponse)
    {
        if (string.IsNullOrEmpty(xmlContent)) return foundResponse;

        // Unescape XML entities
        xmlContent = xmlContent.Replace("&lt;", "<")
                            .Replace("&gt;", ">")
                            .Replace("&amp;", "&")
                            .Replace("&quot;", "\"")
                            .Replace("&apos;", "'");

        // Find <response> tags
        var idx = 0;
        while ((idx = xmlContent.IndexOf("<response>", idx)) != -1)
        {
            var endIdx = xmlContent.IndexOf("</response>", idx);
            if (endIdx == -1) break;

            var responseContent = xmlContent.Substring(idx + 10, endIdx - idx - 10);
            idx = endIdx + 11;

            if (!string.IsNullOrEmpty(responseContent))
            {
                // Extract content from nested <content> tag
                var contentIdx = responseContent.IndexOf("<content>");
                if (contentIdx >= 0)
                {
                    var contentEndIdx = responseContent.IndexOf("</content>", contentIdx);
                    if (contentEndIdx > contentIdx)
                    {
                        var content = responseContent.Substring(contentIdx + 9, contentEndIdx - contentIdx - 9);
                        if (!string.IsNullOrEmpty(content))
                        {
                            AnsiConsole.Markup(content);
                            foundResponse = true;
                        }
                    }
                }
                else
                {
                    // No <content> tag, just print the whole thing
                    AnsiConsole.Markup(responseContent);
                    foundResponse = true;
                }
            }
        }

        // Also handle <tool_result> tags
        idx = 0;
        while ((idx = xmlContent.IndexOf("<tool_result>", idx)) != -1)
        {
            var endIdx = xmlContent.IndexOf("</tool_result>", idx);
            if (endIdx == -1) break;

            var content = xmlContent.Substring(idx + 13, endIdx - idx - 13);
            idx = endIdx + 14;

            if (!string.IsNullOrEmpty(content))
            {
                AnsiConsole.Markup(content);
                foundResponse = true;
            }
        }

        return foundResponse;
    }

    private static string EscapeJsonString(string input)
    {
        return input.Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\n", "\\n").Replace("\r", "\\r");
    }

    private static void ShowHelp()
    {
        var table = new Table()
            .Title("[bold cyan]MyCli - Command Line Tool[/]")
            .AddColumn(new TableColumn("[yellow]Option[/]"))
            .AddColumn(new TableColumn("[yellow]Description[/]"))
            .AddRow("-c, --config <value>", "Set configuration path")
            .AddRow("-q, --query <value>", "Send query to LLM")
            .AddRow("-p, --port <value>", "HTTP server port (default: 8080)")
            .AddRow("-h, --help", "Show help");
        AnsiConsole.Write(table);
        AnsiConsole.WriteLine();
        AnsiConsole.MarkupLine("[dim]Example:[/] [green]mycli -q \"Hello\"[/]");
        AnsiConsole.MarkupLine("[dim]Example:[/] [green]mycli -q \"Hello\" -p 9000[/]");
    }
}

public class Program
{
    public static int Main(string[] args)
    {
        return new CommandApp<DefaultCommand>().Run(args);
    }
}
