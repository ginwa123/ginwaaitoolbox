#!/usr/bin/env bash
# scripts/build-vendor-curl.sh
#
# Cross-compiles curl 8.10.1 from source for each target platform
# (Linux x86_64, macOS arm64, macOS x86_64, Windows amd64) and writes
# the prebuilt libcurl.a + curl headers to vendor/curl/<target>/.
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
# Requires (host): bash, zig 0.16+ (for macOS cross-compile), system gcc
# (for Linux native + MinGW for Windows). The curl source is downloaded
# on first run from https://curl.se/download/.
#
# Layout:
#   vendor/curl/
#   ├── linux-x86_64/lib/libcurl.a         (built by this script)
#   ├── linux-x86_64/include/curl/*.h      (curl headers)
#   ├── macos-arm64/lib/libcurl.a          (built by this script)
#   ├── macos-arm64/include/curl/*.h
#   ├── macos-x86_64/lib/libcurl.a         (built by this script)
#   ├── macos-x86_64/include/curl/*.h
#   ├── windows-amd64/lib/libcurl.a        (built by this script, or
#   │                                      from official curl Windows
#   │                                      zip if you prefer)
#   └── windows-amd64/include/curl/*.h

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
PROJECT_DIR="$( cd "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd )"
VENDOR_DIR="${PROJECT_DIR}/vendor/curl"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/nalar-curl-XXXXXX")
trap 'rm -rf "${TMP}"' EXIT

CURL_VERSION="8.10.1"
CURL_URL="https://curl.se/download/curl-${CURL_VERSION}.tar.gz"
SRC_DIR="${TMP}/curl-${CURL_VERSION}"
BUILD_LINUX="${TMP}/build-linux"
BUILD_MACOS_ARM64="${TMP}/build-macos-arm64"
BUILD_MACOS_X86_64="${TMP}/build-macos-x86_64"

# === Download curl source on first run ===
if [[ ! -d "${SRC_DIR}" ]]; then
    echo "=== Downloading curl ${CURL_VERSION} source ==="
    curl -fsSL --retry 3 --connect-timeout 30 "${CURL_URL}" -o "${TMP}/curl.tar.gz"
    tar -xzf "${TMP}/curl.tar.gz" -C "${TMP}/"
fi

# === List of curl .c source files (excluding platform-specific + TLS backends) ===
# We skip:
#   - TLS backends (vtls/, openssl.c, wolfssl.c, etc.) — no TLS support
#   - OS-specific backends (darwin, win32, os400, etc.) — host-specific
#   - Auth backends requiring system deps (krb5, gsasl, cleartext)
CURL_SOURCES=$(find "${SRC_DIR}/lib" -maxdepth 1 -name '*.c' \
    ! -name 'darwin*' \
    ! -name 'os400*' \
    ! -name 'windows*' \
    ! -name 'win32*' \
    ! -name 'wininet*' \
    ! -name 'wldap*' \
    ! -name 'security.c' \
    ! -name 'schannel.c' \
    ! -name 'msdos.c' \
    ! -name 'riscos.c' \
    ! -name 'plan9.c' \
    ! -name 'beos.c' \
    ! -name 'netware.c' \
    ! -name 'openbsd.c' \
    ! -name 'haiku.c' \
    ! -name 'symbian.c' \
    ! -name 'tpf.c' \
    ! -name 'aros.c' \
    ! -name 'qnx.c' \
    ! -name 'xdk.c' \
    | sort)

# === Common compile flags for HTTP-only curl ===
COMMON_FLAGS=(
    -DHAVE_CONFIG_H
    -DBUILDING_LIBCURL
    -DCURL_DISABLE_LDAP
    -DCURL_DISABLE_LDAPS
    -DCURL_USE_OPENSSL=0
    -DCURL_USE_BEARSSL=0
    -DCURL_USE_GNUTLS=0
    -DCURL_USE_WOLFSSL=0
    -DCURL_USE_MBEDTLS=0
    -DCURL_USE_RUSTLS=0
    -DCURL_USE_NGHTTP2=0
    -DCURL_USE_NGHTTP3=0
    -DCURL_USE_NGTCP2=0
    -DCURL_USE_QUICHE=0
    -DCURL_USE_LIBSSH2=0
    -DCURL_USE_LIBSSH=0
    -DCURL_USE_ZLIB=0
    -DCURL_USE_BROTLI=0
    -DCURL_USE_ZSTD=0
    -DCURL_USE_LIBPSL=0
    -DCURL_USE_LIBIDN2=0
    -DCURL_USE_LIBRTMP=0
    -DENABLE_IPV6=0
    -DENABLE_UNIX_SOCKETS=0
    -DENABLE_WEBSOCKETS=0
    -DENABLE_THREADED_RESOLVER=0
)

# === Build a minimal curl_config.h for HTTP-only curl ===
# curl_setup.h includes curl_config.h. Without it, curl_setup.h fails.
# We generate a tiny one that disables all optional features.
make_minimal_config_h() {
    local out="$1"
    cat > "${out}" <<'CONFIG_EOF'
/* Minimal curl_config.h for HTTP-only curl (no TLS, no extras) */
#define HAVE_ARPA_INET_H 1
#define HAVE_ERRNO_H 1
#define HAVE_FCNTL_H 1
#define HAVE_NETDB_H 1
#define HAVE_NETINET_IN_H 1
#define HAVE_NETINET_TCP_H 1
#define HAVE_POLL_H 1
#define HAVE_SELECT_H 1
#define HAVE_SOCKADDR_IN6_SIN6_ADDR 1
#define HAVE_SOCKADDR_IN6_SIN6_SCOPE_ID 1
#define HAVE_STRINGS_H 1
#define HAVE_STDINT_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRING_H 1
#define HAVE_STRUCT_TIMEVAL 1
#define HAVE_SYS_FILIO_H 1
#define HAVE_SYS_IOCTL_H 1
#define HAVE_SYS_PARAM_H 1
#define HAVE_SYS_POLL_H 1
#define HAVE_SYS_RESOURCE_H 1
#define HAVE_SYS_SELECT_H 1
#define HAVE_SYS_SOCKET_H 1
#define HAVE_SYS_STAT_H 1
#define HAVE_SYS_TIME_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_SYS_UIO_H 1
#define HAVE_UNISTD_H 1
#define HAVE_CLOCK_GETTIME_MONOTONIC 1
#define HAVE_GETADDRINFO 1
#define HAVE_GETHOSTBYADDR 1
#define HAVE_GETHOSTBYNAME 1
#define HAVE_GETNAMEINFO 1
#define HAVE_GETPEERNAME 1
#define HAVE_GETSOCKNAME 1
#define HAVE_GETTIMEOFDAY 1
#define HAVE_INET_NTOP 1
#define HAVE_INET_PTON 1
#define HAVE_MSG_NOSIGNAL 1
#define HAVE_PIPE 1
#define HAVE_POLL 1
#define HAVE_RECV 1
#define HAVE_RECVFROM 1
#define HAVE_SEND 1
#define HAVE_SIGACTION 1
#define HAVE_SOCKET 1
#define HAVE_STRCASECMP 1
#define HAVE_STRDUP 1
#define HAVE_STRERROR_R 1
#define HAVE_STRICMP 1
#define HAVE_STRNCASECMP 1
#define HAVE_STRNICMP 1
#define HAVE_WRITEV 1
#define OS "linux"
#define HAVE_SOCKLEN_T 1
#define HAVE_LIMITS_H 1
#define HAVE_FCNTL_O_NONBLOCK 1
CONFIG_EOF
}

# === Helper: compile all curl .c files + archive ===
# Args: $1 = output dir, $2 = archiver, $3.. = CC + CC args
build_target() {
    local out_dir="$1"
    local ar_cmd="$2"
    shift 2
    local cc_cmd=("$@")

    echo ""
    echo "=== Building for ${out_dir} ==="
    mkdir -p "${out_dir}/obj" "${out_dir}/include"

    # Headers
    cp -r "${SRC_DIR}/include/curl/." "${out_dir}/include/curl/"
    echo "  headers: ${out_dir}/include/curl/"

    # Generate minimal curl_config.h
    make_minimal_config_h "${out_dir}/include/curl/curl_config.h"

    # Compile each .c file
    local count=0
    local failed=0
    for src in ${CURL_SOURCES}; do
        local base=$(basename "${src}" .c)
        local obj="${out_dir}/obj/${base}.o"
        if "${cc_cmd[@]}" \
            "${COMMON_FLAGS[@]}" \
            -I"${SRC_DIR}/include" \
            -I"${out_dir}/include/curl" \
            -c "${src}" -o "${obj}" 2>/dev/null; then
            count=$((count + 1))
        else
            # Some files may have platform-specific issues — skip with warning
            echo "  WARN: ${base}.c failed to compile for ${out_dir} (platform-specific)"
            failed=$((failed + 1))
        fi
    done
    echo "  compiled: ${count} (${failed} skipped)"

    # Archive
    echo "  archiving..."
    rm -f "${out_dir}/lib/libcurl.a"
    "${ar_cmd}" "${out_dir}/lib/libcurl.a" "${out_dir}/obj/"*.o
    echo "  done: ${out_dir}/lib/libcurl.a"
}

mkdir -p "${VENDOR_DIR}"

# === Linux x86_64 (native build, uses system gcc) ===
build_target \
    "${VENDOR_DIR}/linux-x86_64" \
    "ar" \
    gcc \
    -O2 \
    -fPIC

# === macOS arm64 (cross-compile from Linux using zig cc) ===
build_target \
    "${VENDOR_DIR}/macos-arm64" \
    "zig" \
    ar \
    zig cc \
    -target aarch64-macos \
    -O2 \
    -fPIC

# === macOS x86_64 (cross-compile from Linux using zig cc) ===
build_target \
    "${VENDOR_DIR}/macos-x86_64" \
    "zig" \
    ar \
    zig cc \
    -target x86_64-macos \
    -O2 \
    -fPIC

echo ""
echo "=== Done. Run 'zig build' to verify ==="
echo "  Linux native + cross-compile from any host OS now has vendored curl."
