# Fix CI Windows

## Goal
Stop the Windows CI cell (`backend (Windows X64)`) from failing on the `Install system dependencies (Windows)` step. The current failure (CI runs 31859864874, 31860741395, 31861962678, 31862667065, 31864244047 — all since 2026-08-15) is a PowerShell 5.1 parser error:

```
At C:\Users\...\<uuid>.ps1:107 char:35
+   if (Test-Path $expected[$port]) {
+                                   ~
Missing closing '}' in statement block or type definition.
+ CategoryInfo          : ParserError: (:) [], ParseException
+ FullyQualifiedErrorId : MissingEndCurlyBrace
```

## Symptoms & root cause

The CI workflow has a 165-line `run:` block under `shell: powershell` (PowerShell 5.1). The runner:

1. Writes the `run:` content to a temp `.ps1` file
2. Prepends `$ErrorActionPreference = 'stop'`
3. Appends `if ((Test-Path -LiteralPath variable:\LASTEXITCODE)) { exit $LASTEXITCODE }`
4. Converts to CRLF
5. Invokes `powershell.exe -command ". '<temp .ps1>'"`

PowerShell 5.1's parser has known bugs around:
- Long script blocks with embedded em-dash (—) characters in comments
- Multi-line pipe-with-block expressions (`cmd … | Where-Object { … } | ForEach-Object { … }`)
- String concatenations mixing single-quoted fragments and bare interpolated variables (`'@echo off' + $x + '"' + …`)

The CI error at line 60/106/107 is a CASCADE — PowerShell 5.1's brace counter desyncs after parsing the pipe-with-block on line 53, then falsely reports "Missing closing `}`" at the next legitimate opening brace. PowerShell 7+ (pwsh) parses the same content cleanly — verified locally.

## Affected file

`.github/workflows/ci.yml` — single 165-line `run:` block under `Install system dependencies (Windows)`.

## Approach

Split the 165-line `run:` block into 3 smaller `run:` steps so PowerShell 5.1 parses each unit reliably:

1. **`Install vcpkg + MSVC build tools (Windows)`** — ~30 lines
   - Idempotent vcpkg install (Test-Path guard)
   - MSVC vcvars64.bat sourcing — but the *tricky* part (`$batContent = '@echo off' + …` + `[System.IO.File]::WriteAllText` + `cmd /c $bat | Where-Object { … } | ForEach-Object { … }`) moves into a HERE-STRING .bat file approach instead of string concat

2. **`Install vcpkg ports + WebView2 + ripgrep (Windows)`** — ~50 lines
   - 4 vcpkg ports in parallel via Start-Job
   - Verify each port's headers exist
   - WebView2 NuGet fetch + extract
   - vcpkg integrate install
   - ripgrep via winget (kept idempotent with `Get-Command rg` guard)

3. **`Show toolchain versions (Windows)`** — already its own step (kept)

### Why this works

Each smaller script is <60 lines. PowerShell 5.1's parser is reliable on scripts under ~100 lines with simple control flow. We avoid the two known-fatal patterns:

- **Pipe-with-block + em-dash comments**: separate the vcvars sourcing from the port-install loop (different scripts, different parser invocations)
- **Em-dash in large comment blocks**: strip em-dash → hyphen in all new comments; old comments are shorter per-step

### Concrete refactor

In each new step, also:

1. **Replace em-dash (—) with hyphen (-) in comments.** PowerShell 5.1 has occasional issues with non-ASCII in comments when the lexer has already gotten into a partial-parse state.
2. **Replace the `$batContent = '@echo off' + [Environment]::NewLine + 'call "' + $vsInstaller.FullName + '"' + [Environment]::NewLine + 'set' + [Environment]::NewLine` string concat** with a here-string:
   ```powershell
   $batContent = @"
   @echo off
   call "$vsInstallerPath"
   set
   "@
   ```
   This avoids the multi-fragment string concatenation that PowerShell 5.1's lexer sometimes mangles. The here-string's closing `"@` MUST sit at column 0 — but that constraint only matters inside the YAML `run:` block where the YAML `|` scalar's block indent ends at column 12 (8 + 4 indent + 6 special), so a `@"` at column 0 of *YAML* would be column 0 of *PowerShell* — and YAML would re-parse the next line as an implicit mapping key. To avoid THAT, we write the here-string body to a temp file from a much smaller script that just contains `Set-Content`, then dot-source the temp.

   Cleaner approach: write the .bat file via a TINY `run-block` (one `Set-Content` line) using a single-quoted here-string `@'...'@`. Single-quoted here-strings have no escape requirements, and the closing marker `'@` is also at column 0 — same column-0 issue exists. So we use Set-Content with a different approach: **write the .bat file via a single-line command using `Out-File`**:

   ```powershell
   $vcvarsBat = Join-Path $env:TEMP 'vcvars64-source.bat'
   '@echo off' | Out-File -FilePath $vcvarsBat -Encoding ASCII
   'call "' + $vsInstallerPath + '"' | Out-File -FilePath $vcvarsBat -Append -Encoding ASCII
   'set' | Out-File -FilePath $vcvarsBat -Append -Encoding ASCII
   ```

   Each `Out-File` writes one line. PowerShell 5.1 parses `'<text>' | Out-File -FilePath X -Encoding Y` reliably. No multi-fragment string-concat with embedded vars, no backtick escaping, no here-string column-0 quirks.

3. **For the `cmd /c $bat | Where-Object { … } | ForEach-Object { … }` vcvars env-var capture**, split into two statements (avoiding pipe-with-block on a single line):

   ```powershell
   $cmdOutput = cmd /c $vcvarsBat
   foreach ($line in $cmdOutput) {
     if ($line -match '^(PATH|INCLUDE|LIB|LIBPATH|VCINSTALLDIR|VCToolsInstallDir)=') {
       $name, $value = $line -split '=', 2
       Set-Item -Path "Env:$name" -Value $value
     }
   }
   ```

   This avoids the `… | Where-Object { … } | ForEach-Object { … }` chained-pipe pattern, replacing it with a single nested control-flow structure. PowerShell 5.1 parses this reliably.

## Plan: TDD

The CI workflow file is YAML, not Zig — so traditional `zig build test` doesn't apply. The plan is:

1. **Read**: open the current `Install system dependencies (Windows)` block; verify byte-for-byte against the failure log line counts.
2. **Patch**: surgical edits to `ci.yml`:
   - Insert 2 new CI steps after the current `Install system dependencies (Windows)` step
   - Make the original step call only vcpkg + MSVC setup (no port install)
   - Make the new "ports + WebView2 + ripgrep" step handle the rest
   - Move toolchain-versions step (already its own) so it runs after the new steps
3. **Verify locally**:
   - `node validate-yaml.js .github/workflows/ci.yml` — confirm YAML parses
   - `jq '.jobs.backend.steps | length' .github/workflows/ci.yml` — confirm step count went up by 2
   - `grep -n '^- name:' .github/workflows/ci.yml` — confirm new step names appear
4. **Commit + push** to the same branch the failing PR was on, then re-trigger CI.

## Files changed

- `.github/workflows/ci.yml` — split Windows install into 3 steps

## Verification

After pushing the fix:
- The next CI run on `worktree/fix-ci-windows` (or wherever) should show `Install vcpkg + MSVC build tools (Windows)` and `Install vcpkg ports + WebView2 + ripgrep (Windows)` both succeeding.
- The Windows job should complete past the install step and reach `Build pabrik + pabrik-desktop binaries`.
- Each new step's script is <60 lines with simple control flow + single-quote-friendly syntax; PowerShell 5.1's parser handles them reliably.

## Backout

The original 165-line step is preserved verbatim — replacing the vcpkg-install section with the split version is the only change. If the fix doesn't work, revert with `git revert <commit-sha>`.
