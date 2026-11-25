#!/usr/bin/env bash
# Prepares a sysroot that pins the C library of the native modules.
#
# The sysroot holds the headers, startup files and shared libraries of an
# older distribution, so a module that is compiled against it keeps working on
# distributions that are older than the build host. The script downloads the
# packages of that distribution from the configured apt sources and unpacks
# them into a directory.
#
# Usage:
#   ./desktop/scripts/prepare-sysroot.sh --arch <arm64|x64> [--suite bullseye]
#       [--output <dir>]
set -euo pipefail

ARCH=""
SUITE="bullseye"
OUTPUT=""

usage() {
  cat <<EOF
Usage: $0 --arch <arm64|x64> [--suite <suite>] [--output <dir>]

Downloads the C library of the given suite for the given architecture and
unpacks it into a sysroot directory. The default output directory is
\$XDG_CACHE_HOME/minimax-code-sysroots/<suite>-<arch>.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --arch) ARCH="${2:?missing value}"; shift 2 ;;
    --suite) SUITE="${2:?missing value}"; shift 2 ;;
    --output) OUTPUT="${2:?missing value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [ -z "$ARCH" ]; then
  usage >&2
  exit 1
fi

case "$ARCH" in
  arm64) DEB_ARCH=arm64 ;;
  x64) DEB_ARCH=amd64 ;;
  *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;;
esac

CACHE_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/minimax-code-sysroots"
OUTPUT="${OUTPUT:-$CACHE_ROOT/$SUITE-$DEB_ARCH}"
PACKAGE_DIR="$CACHE_ROOT/packages/$SUITE-$DEB_ARCH"

command -v apt-get >/dev/null || { echo "apt-get is required" >&2; exit 1; }
command -v dpkg-deb >/dev/null || { echo "dpkg-deb is required" >&2; exit 1; }

# The packages that a compile and link against the C library needs.
PACKAGES=(
  "libc6"
  "libc6-dev"
  "linux-libc-dev"
  "libstdc++6"
  "libstdc++-10-dev"
  "libgcc-10-dev"
)

mkdir -p "$PACKAGE_DIR" "$OUTPUT"

for package in "${PACKAGES[@]}"; do
  if apt-get download -o "Dir::Cache::archives=$PACKAGE_DIR" \
      "$package:$DEB_ARCH" >/dev/null 2>&1; then
    continue
  fi
  # The package is not available for the architecture, try the generic name.
  apt-get download -o "Dir::Cache::archives=$PACKAGE_DIR" \
    "$package" >/dev/null 2>&1 ||
    echo "Skipped $package ($DEB_ARCH)"
done

for archive in "$PACKAGE_DIR"/*.deb; do
  [ -f "$archive" ] || continue
  dpkg-deb -x "$archive" "$OUTPUT"
done

# The distribution links its libraries with absolute paths, for example
# /usr/lib/aarch64-linux-gnu/libm.so -> /lib/aarch64-linux-gnu/libm.so.6.
# Inside the sysroot those links have to point at the sysroot, otherwise the
# linker picks up the C library of the build host.
fixed=0
while IFS= read -r link; do
  target="$(readlink "$link")"
  case "$target" in
    /*) ;;
    *) continue ;;
  esac
  if [ -e "$OUTPUT$target" ]; then
    relative="$(python3 - "$link" "$OUTPUT$target" <<'PY'
import os
import sys
link, target = sys.argv[1], sys.argv[2]
print(os.path.relpath(target, os.path.dirname(link)))
PY
)"
    ln -sfn "$relative" "$link"
    fixed=$((fixed + 1))
  fi
done < <(find "$OUTPUT" -type l)

echo "Sysroot ready: $OUTPUT ($fixed symlink(s) rewritten)"
