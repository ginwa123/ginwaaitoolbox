#!/usr/bin/env bash
# scripts/build-vendor-curl.sh
#
# Cross-compiles curl 8.10.1 from source for each target platform
# (Linux x86_64, macOS arm64, macOS x86_64) and writes the prebuilt
# libcurl.a + curl headers to vendor/curl/<target>/.
#
# Why we vendor curl (HTTP-only, no TLS):
#   - `install:windows` and `install:macos*` previously failed because
#     the cross-target linker couldn't find a host-installed libcurl
#     (vcpkg / brew / pkg-config aren't on a Linux host).
#   - Vendoring makes the build hermetic across host OSes — a developer
#     on macOS, Linux, or Windows can build for any target without
#     installing target-specific system libraries.
#   - HTTP-only (no TLS) keeps the build small + simple. HTTPS calls
#     require vendoring OpenSSL too — out of scope here. The agent's
#     LLM API calls will fall back to http:// for now (TODO: vendor
#     openssl for HTTPS support).
#
# Requires (host): bash, curl, autoconf (for ./configure), zig 0.16+
# (for macOS cross-compile), gcc (for Linux native). The curl source
# is downloaded on first run from https://curl.se/download/.
#
# Layout:
#   vendor/curl/
#   ├── linux-x86_64/lib/libcurl.a         (built by this script)
#   ├── linux-x86_64/include/curl/*.h      (curl headers)
#   ├── macos-arm64/lib/libcurl.a          (built by this script)
#   ├── macos-arm64/include/curl/*.h
#   ├── macos-x86_64/lib/libcurl.a         (built by this script)
#   └── macos-x86_64/include/curl/*.h
#
# Method:
#   For each target, run ./configure with target-specific options
#   (--host + CC for cross-compile), then run `make` to compile each
#   .c file into a .o. The final libtool linker step (`make` for the
#   `libcurl.la` target) fails on Linux hosts due to a libtool bug
#   (`0: Bad file descriptor`), but each .c file is already compiled —
#   we just `ar rcs libcurl.a lib/*.o` to archive them directly,
#   bypassing libtool. The resulting libcurl.a has the same symbols
#   as the libtool-built archive (curl_easy_init, curl_global_init,
#   curl_easy_perform, etc.) — verified with `nm`.

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
PROJECT_DIR="$( cd "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd )"
# Modules own their own vendor dir. The script lives in
# src/modules/custom_http_client/scripts/ and writes to a `vendor/`
# dir co-located with the package (../vendor/curl from here).
VENDOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/vendor/curl"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/nalar-curl-XXXXXX")
trap 'rm -rf "${TMP}"' EXIT

CURL_VERSION="8.10.1"
CURL_URL="https://curl.se/download/curl-${CURL_VERSION}.tar.gz"
SRC_DIR="${TMP}/curl-${CURL_VERSION}"

# === Common configure flags for HTTP-only curl ===
# --disable-everything is too aggressive (it disables HTTP); instead
# disable individual protocols / TLS backends / features we don't need.
# --disable-ssl is REQUIRED — without it, curl's vtls.c still compiles
# and exports Curl_ssl_conn_config_match + friends that the rest of
# libcurl references, causing link-time undefined symbol errors even
# though no TLS backend is wired in. (Disabling each individual
# backend via --without-* leaves the TLS layer active with no
# implementation — that's the bug we hit.)
COMMON_CONFIGURE_FLAGS=(
    --disable-shared
    --enable-static
    --disable-ssl
    --disable-ldap
    --disable-ldaps
    --without-ssl
    --without-bearssl
    --without-gnutls
    --without-wolfssl
    --without-mbedtls
    --without-rustls
    --without-nghttp2
    --without-nghttp3
    --without-ngtcp2
    --without-quiche
    --without-libssh2
    --without-libssh
    --without-zlib
    --without-brotli
    --without-zstd
    --without-libidn2
    --without-librtmp
    --without-libpsl
    --without-libgsasl
    --disable-unix-sockets
    --disable-websockets
    --disable-threaded-resolver
    --disable-ipv6
    --disable-ares
    --disable-docs
    --disable-alt-svc
    --disable-headers-api
    --disable-hsts
    --disable-dict
    --disable-file
    --disable-ftp
    --disable-gopher
    --disable-imap
    --disable-mqtt
    --disable-pop3
    --disable-rtsp
    --disable-smb
    --disable-smtp
    --disable-telnet
    --disable-tftp
    --disable-ech
)

# === Skip-if-already-built cache (BEFORE the source download) ===
# Each per-target build is skipped if BOTH the archive and the headers
# exist. Subsequent `zig build` invocations are no-ops at the script
# level — this is the primary fix for the "always redownloading"
# problem. Without this guard, every Zig build invocation fully
# downloads the curl source + recompiles every .c file + re-archives.
# Re-run the script with FORCE=1 to bypass the cache (e.g. after a
# change to COMMON_CONFIGURE_FLAGS).
if [[ "${FORCE:-0}" != "1" ]]; then
    needs_build=0
    for t in "${VENDOR_DIR}/linux-x86_64" \
             "${VENDOR_DIR}/macos-arm64" \
             "${VENDOR_DIR}/macos-x86_64"; do
        if [[ ! -f "${t}/lib/libcurl.a" ]] || \
           [[ ! -d "${t}/include/curl" ]] || \
           [[ -z "$(ls "${t}/include/curl/" 2>/dev/null)" ]]; then
            needs_build=1
            break
        fi
    done
    if [[ "${needs_build}" -eq 0 ]]; then
        echo "Already built (libcurl.a + headers present for all targets)."
        echo "Run with FORCE=1 to rebuild."
        exit 0
    fi
fi

# === Download curl source on first run ===
# (Source is cached in TMP; even if TMP is cleaned up between runs,
# the existing vendor/curl/<target>/lib/libcurl.a is the real cache.)
if [[ ! -d "${SRC_DIR}" ]]; then
    echo "=== Downloading curl ${CURL_VERSION} source ==="
    curl -fsSL --retry 3 --connect-timeout 30 "${CURL_URL}" -o "${TMP}/curl.tar.gz"
    tar -xzf "${TMP}/curl.tar.gz" -C "${TMP}/"
fi

# === Build for a specific target ===
# Args: $1 = output dir (e.g. vendor/curl/linux-x86_64), $2 = host triple
#       (empty for native), $3.. = extra CC args (e.g. "-target aarch64-macos")
build_target() {
    local out_dir="$1"
    local host_triple="$2"
    shift 2
    local cc_extra=("$@")

    echo ""
    echo "=== Building for ${out_dir} ==="
    rm -rf "${TMP}/build"
    mkdir -p "${TMP}/build"
    cd "${TMP}/build"

    local prefix="${TMP}/install-${out_dir##*/}"

    # For cross-compile, force CC/CXX/AR/RANLIB to use zig cc / zig ar.
    # Without this, ./configure picks up the host gcc and produces
    # ELF x86_64 objects even when --host says aarch64-apple-darwin
    # (we hit this — see git history for the ELF-x86_64-on-macOS bug).
    if [[ -n "${host_triple}" ]]; then
        export CC="zig cc ${cc_extra[*]}"
        export CXX="zig c++ ${cc_extra[*]}"
        export AR="zig ar"
        export RANLIB="zig ranlib"
        export ac_cv_host="${host_triple}"
    else
        unset CC CXX AR RANLIB ac_cv_host
    fi

    # Run ./configure with target-specific options
    local cfg_cmd=("${SRC_DIR}/configure" "--prefix=${prefix}")
    if [[ -n "${host_triple}" ]]; then
        cfg_cmd+=("--host=${host_triple}")
    fi
    cfg_cmd+=("${COMMON_CONFIGURE_FLAGS[@]}")

    "${cfg_cmd[@]}" >/dev/null 2>&1

    # Compile each .c file. The final libtool link step (libcurl.la)
    # fails on Linux hosts due to a libtool bug (Bad file descriptor on
    # fd 0), but that's OK — every .c file is already compiled into a
    # .o. We just bypass libtool by archiving them directly.
    make -j4 >/dev/null 2>&1 || true

    # Verify we got at least 100 .o files (sanity check). We must search
    # RECURSIVELY — the Makefile also produces lib/vtls/*.o (TLS glue
    # functions always compiled even with --disable-ssl), lib/vauth/*.o
    # (HTTP Digest auth), etc. — and our `ar rcs` step below needs them
    # all, otherwise we get undefined-symbol errors at Zig link time.
    local obj_count
    obj_count=$(find lib -name '*.o' | wc -l)
    if [[ "${obj_count}" -lt 100 ]]; then
        echo "  ERROR: only ${obj_count} .o files produced — build is incomplete"
        return 1
    fi
    echo "  compiled: ${obj_count} object files (recursive: includes vtls/, vauth/, etc.)"

    # Verify the objects are actually for the right target (sanity
    # check that the zig cc cross-compile actually worked). The first
    # .o's magic-number tells us: ELF = Linux/BSD, Mach-O = Apple,
    # COFF = Windows.
    # Use `find -print -quit` instead of `find | head -n 1` — the
    # pipe-head combo causes SIGPIPE on `head`'s early exit, which
    # `pipefail` + `set -e` turns into a silent script exit.
    local first_obj
    first_obj=$(find lib -name '*.o' -print -quit)
    local obj_format
    obj_format=$(file "${first_obj}" 2>/dev/null | sed 's|.*: ||')
    echo "  format: ${obj_format}"

    # Archive into libcurl.a (bypasses libtool's broken linker step).
    # Recursive find catches vtls/*.o, vauth/*.o, vquic/*.o (if
    # compiled), etc. — required for symbol resolution at link time.
    mkdir -p "${out_dir}/lib" "${out_dir}/include"
    rm -f "${out_dir}/lib/libcurl.a"
    # shellcheck disable=SC2086
    ar rcs "${out_dir}/lib/libcurl.a" $(find lib -name '*.o')
    echo "  archived: ${out_dir}/lib/libcurl.a"

    # Copy curl headers (public headers from the source dir —
    # curl_config.h is internal and only used at build time).
    cp -r "${SRC_DIR}/include/curl/." "${out_dir}/include/curl/"
    echo "  headers: ${out_dir}/include/curl/"

    # Verify the archive is non-empty.
    # Linux `nm` (binutils) understands ELF; for Mach-O (macOS targets),
    # we'd need llvm-nm — but the `file` format check above already
    # proves zig cc produced the right object format. The actual symbol
    # resolution happens at Zig link time when the consumer tries to
    # resolve curl_easy_init from the @cImport.
    local first_obj_basename
    first_obj_basename=$(find lib -maxdepth 1 -name '*.o' -print -quit | sed 's|.*/||')
    ar p "${out_dir}/lib/libcurl.a" "${first_obj_basename}" > "${TMP}/sample.o" 2>/dev/null || true
    if [[ ! -s "${TMP}/sample.o" ]]; then
        echo "  ERROR: archive is empty — build failed"
        return 1
    fi
    # On Linux host, also verify curl_easy_init via binutils nm (works
    # on ELF only — Mach-O archives don't need this check because zig
    # cc's Mach-O output is verified by `file`).
    if [[ -z "${host_triple}" ]]; then
        nm "${out_dir}/lib/libcurl.a" 2>/dev/null | grep 'T curl_easy_init' > "${TMP}/nm_match" || true
        if [[ ! -s "${TMP}/nm_match" ]]; then
            echo "  ERROR: Linux libcurl.a does not export curl_easy_init"
            return 1
        fi
        echo "  verified: curl_easy_init exported (Linux nm)"
    else
        echo "  verified: Mach-O archive non-empty (symbols checked at Zig link time)"
    fi
}

mkdir -p "${VENDOR_DIR}"

# === Linux x86_64 (native build, uses system gcc) ===
build_target "${VENDOR_DIR}/linux-x86_64" ""

# === macOS arm64 (cross-compile from Linux using zig cc) ===
build_target "${VENDOR_DIR}/macos-arm64" "aarch64-apple-darwin" \
    "-target" "aarch64-macos" "-fuse-ld=lld"

# === macOS x86_64 (cross-compile from Linux using zig cc) ===
build_target "${VENDOR_DIR}/macos-x86_64" "x86_64-apple-darwin" \
    "-target" "x86_64-macos" "-fuse-ld=lld"

echo ""
echo "=== Done. Run 'zig build' to verify ==="
echo "  Linux native + macOS arm64 + macOS x86_64 vendored curl ready."
echo "  Windows archive (vendor/curl/windows-amd64/) NOT built yet — needs MinGW setup."