# vendor/sqlite3 — vendored SQLite3 for cross-compilation

This directory contains the sqlite3 binary + headers needed to cross-compile the
ginwasaas project to **macOS** and **Windows** from Linux. The native Linux
build uses the system sqlite3 and does not touch this directory.

## Layout

```
vendor/sqlite3/
├── amalgamation/                              # sqlite3.c + sqlite3.h (single source)
│   └── sqlite-amalgamation-3530400/
│       ├── sqlite3.c                          # ~7 MB C source
│       └── sqlite3.h                          # public header
├── windows-amd64/
│   ├── sqlite3.dll                            # Windows DLL (sqlite.org)
│   ├── sqlite3.def                            # DLL exports
│   └── libsqlite3.a                           # import library (zig ar)
├── macos-arm64/
│   ├── sqlite3.o                              # zig cc -target aarch64-macos
│   └── libsqlite3.a                           # zig ar archive
├── macos-x86_64/
│   ├── sqlite3.o                              # zig cc -target x86_64-macos
│   └── libsqlite3.a                           # zig ar archive
├── libc-windows-amd64/                        # merged Windows include + lib
│   ├── include/                               # symlink farm → MinGW headers + sqlite3.h
│   └── lib/                                   # symlink farm → MinGW libs + libsqlite3.a
├── libc-windows-amd64.txt                     # --libc file (legacy, not used)
└── macos-arm64.txt                            # --libc file (legacy, not used)
```

## How `build.zig` wires it up

```zig
switch (target.result.os.tag) {
    .windows => {
        mod.addIncludePath(b.path("vendor/sqlite3/libc-windows-amd64/include"));
        mod.addLibraryPath(b.path("vendor/sqlite3/libc-windows-amd64/lib"));
        mod.linkSystemLibrary("bcrypt", .{});
    },
    .macos => {
        mod.addIncludePath(b.path("vendor/sqlite3/amalgamation/sqlite-amalgamation-3530400"));
        const macos_lib = switch (target.result.cpu.arch) {
            .aarch64 => "vendor/sqlite3/macos-arm64",
            .x86_64 => "vendor/sqlite3/macos-x86_64",
            else => return,
        };
        mod.addLibraryPath(b.path(macos_lib));
    },
    else => {},
}
```

Build commands (all run from the project root):

```bash
zig build                                       # native Linux
zig build -Dtarget=x86_64-windows-gnu           # Windows (MinGW)
zig build -Dtarget=aarch64-macos                # macOS Apple Silicon
zig build -Dtarget=x86_64-macos                 # macOS Intel
```

## How the artifacts were produced

### Windows (`windows-amd64/`)

```bash
# Download from sqlite.org (single source of truth)
curl -sL https://www.sqlite.org/2026/sqlite-dll-win-x64-3530400.zip \
  -o /tmp/sqlite3-win.zip
unzip /tmp/sqlite3-win.zip -d vendor/sqlite3/windows-amd64/

# Generate import library from .def
x86_64-w64-mingw32-dlltool -d vendor/sqlite3/windows-amd64/sqlite3.def \
    -l vendor/sqlite3/windows-amd64/libsqlite3.a
```

### macOS (`macos-arm64/`, `macos-x86_64/`)

```bash
# Cross-compile the amalgamation for each target — no SDK needed for sqlite3.c
zig cc -target aarch64-macos -O2 -c \
    vendor/sqlite3/amalgamation/sqlite-amalgamation-3530400/sqlite3.c \
    -o vendor/sqlite3/macos-arm64/sqlite3.o
zig cc -target x86_64-macos -O2 -c \
    vendor/sqlite3/amalgamation/sqlite-amalgamation-3530400/sqlite3.c \
    -o vendor/sqlite3/macos-x86_64/sqlite3.o

# Wrap into static archives
zig ar rcs vendor/sqlite3/macos-arm64/libsqlite3.a   vendor/sqlite3/macos-arm64/sqlite3.o
zig ar rcs vendor/sqlite3/macos-x86_64/libsqlite3.a vendor/sqlite3/macos-x86_64/sqlite3.o
```

### Merged Windows dir (`libc-windows-amd64/`)

A symlink farm uniting MinGW headers/libs with the Windows sqlite3 import
library. Built once via:

```bash
cd vendor/sqlite3
mkdir -p libc-windows-amd64/include libc-windows-amd64/lib
for f in /usr/x86_64-w64-mingw32/include/*; do
    ln -sf "$f" "libc-windows-amd64/include/$(basename "$f")"
done
ln -sf /home/ginwa/ginwasaas/vendor/sqlite3/amalgamation/sqlite-amalgamation-3530400/sqlite3.h \
    libc-windows-amd64/include/sqlite3.h
for f in /usr/x86_64-w64-mingw32/lib/*; do
    ln -sf "$f" "libc-windows-amd64/lib/$(basename "$f")"
done
ln -sf /home/ginwa/ginwasaas/vendor/sqlite3/windows-amd64/libsqlite3.a \
    libc-windows-amd64/lib/libsqlite3.a
```

## Why we don't use `--libc` flags

The `--libc` file mechanism (`vendor/sqlite3/libc-windows-amd64.txt`,
`macos-arm64.txt`) was the original plan, but it has two problems:

1. **`--libc` REPLACES Zig's auto-detection**, not augments it. Without
   `--libc`, Zig uses its bundled MinGW (compiled from source under
   `/usr/lib/zig/libc/mingw/`) for `-windows-gnu` and its bundled
   `libSystem.tbd` for `-macos`. Passing `--libc` overrides this with
   our shim, requiring us to provide full MinGW headers + crts + the
   matching .lib files — none of which are needed if we let Zig do it.

2. **Single-value fields.** `libc.txt` only takes one `include_dir` and
   one `crt_dir`. To merge `sqlite3.h` into the include path, we need
   `-I` *adding* to Zig's defaults, not replacing them. That's exactly
   what `Module.addIncludePath` does.

Result: the `*.txt` files are kept as documentation/legacy but unused.

## Why we changed `std.c.getrandom` in `security.zig`

`std.c.getrandom` is `void` on Windows and macOS targets (see
`std/c.zig` in Zig 0.16). Cross-compile trips the "type 'void' not a
function" error. The fix uses `BCryptGenRandom` on Windows
(linked via `linkSystemLibrary("bcrypt")`), `arc4random_buf` on darwin
(backed by `SecRandomCopyBytes` since macOS 10.12), and keeps
`std.c.getrandom` on Linux/FreeBSD.

## Cost

| File / dir                          | Size      |
|-------------------------------------|----------:|
| `amalgamation/sqlite3.c`            |   ~7 MB   |
| `amalgamation/sqlite3.h`            |   ~140 KB |
| `windows-amd64/*`                   |   ~1 MB   |
| `macos-arm64/libsqlite3.a`          |   ~6 MB   |
| `macos-x86_64/libsqlite3.a`         |   ~6 MB   |
| `libc-windows-amd64/` (symlinks)    |   ~50 MB  |
| **Total**                           |  **~70 MB** |

Comparable to a typical Homebrew install of `sqlite3` + `mingw-w64`.

## Tested

Run on 2026-08-07 with Zig 0.16.0 on Arch Linux:

```bash
zig build                                     # native Linux  → ELF 64-bit LSB executable
zig build -Dtarget=x86_64-windows-gnu         # Windows       → PE32+ x86-64 console
zig build -Dtarget=aarch64-macos              # macOS arm64   → Mach-O 64-bit arm64
zig build -Dtarget=x86_64-macos               # macOS x86_64  → Mach-O 64-bit x86_64
```
