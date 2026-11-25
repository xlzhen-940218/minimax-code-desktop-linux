#!/usr/bin/env bash
# Build a runnable Linux desktop package (and .deb) from the official MiniMax
# Code Windows installer. See desktop/README.md for prerequisites and details.
set -euo pipefail

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "$HERE/.." && pwd)"

ARCH="${ARCH:-$(uname -m)}"
case "$ARCH" in
  aarch64|arm64) ARCH=arm64 ;;
  x86_64|amd64|x64) ARCH=x64 ;;
  *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;;
esac

HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
  aarch64|arm64) HOST_ARCH=arm64 ;;
  x86_64|amd64) HOST_ARCH=x64 ;;
esac

INSTALLER="${INSTALLER:-}"
ELECTRON_VERSION="${ELECTRON_VERSION:-42.11.16}"
REGISTRY="${NPM_REGISTRY:-https://registry.npmmirror.com}"
ELECTRON_MIRROR="${ELECTRON_MIRROR:-https://cdn.npmmirror.com/binaries}"
DEB_COMPRESS="${DEB_COMPRESS:-xz}"
# Sysroot that pins the C library the native modules are compiled against.
# It keeps the package installable on distributions older than the build host.
SYSROOT="${SYSROOT:-}"
CXX_PREFIX="${CXX_PREFIX:-}"
CROSS=0

# Intermediate files are several gigabytes, so they default to the user cache
# instead of the repository. Override with BUILD_DIR.
BUILD_DIR="${BUILD_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/minimax-code-linux-build}"
CACHE_DIR="$BUILD_DIR/cache"
WORK_DIR="$BUILD_DIR/work"
DIST_DIR="$HERE/dist"
TOOLS_DIR="$BUILD_DIR/tools"

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --installer <path>        Official MiniMax Code Setup <version>.exe
                            (default: newest matching file for the target
                            architecture in the repository root)
  --arch <arm64|x64>        Target architecture (default: host architecture)
  --electron-version <ver>  Electron version bundled by the installer (default: $ELECTRON_VERSION)
  --registry <url>          npm registry (default: $REGISTRY)
  --sysroot <dir>           Build the native modules against this sysroot, so
                            the package keeps working on older distributions
  --cxx-prefix <dir>        Tree that holds the C++ headers of the target
                            architecture, needed for a cross build
  --cross                   Allow building for an architecture other than the
                            host one, using a cross compiler
  --portable                Also create a portable .tar.gz next to the .deb
  -h, --help                Show this help

Environment: INSTALLER, ARCH, ELECTRON_VERSION, NPM_REGISTRY, ELECTRON_MIRROR,
  BUILD_DIR (default: $BUILD_DIR), DEB_COMPRESS (default: $DEB_COMPRESS),
  SYSROOT, CXX_PREFIX, MAX_GLIBC.
EOF
}

PORTABLE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --installer) INSTALLER="${2:?missing value}"; shift 2 ;;
    --arch) ARCH="${2:?missing value}"; shift 2 ;;
    --electron-version) ELECTRON_VERSION="${2:?missing value}"; shift 2 ;;
    --registry) REGISTRY="${2:?missing value}"; shift 2 ;;
    --sysroot) SYSROOT="${2:?missing value}"; shift 2 ;;
    --cxx-prefix) CXX_PREFIX="${2:?missing value}"; shift 2 ;;
    --cross) CROSS=1; shift ;;
    --portable) PORTABLE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

case "$ARCH" in
  arm64) PAYLOAD="app-arm64.7z"; DEB_ARCH=arm64 ;;
  x64) PAYLOAD="app-64.7z"; DEB_ARCH=amd64 ;;
esac

# The official installers are published per architecture. Prefer the one that
# matches the target, and fall back to an architecture neutral installer.
find_installer() {
  local dir="$1" pattern="$2" found
  [ -d "$dir" ] || return 0
  found="$(find "$dir" -maxdepth 1 -type f -name "$pattern" | sort -V | tail -1)"
  [ -n "$found" ] || return 0
  printf '%s\n' "$found"
}

if [ -z "$INSTALLER" ]; then
  for dir in "$REPO_ROOT" "$BUILD_DIR/installers"; do
    candidate="$(find_installer "$dir" "MiniMax Code Setup *-$ARCH.exe")"
    if [ -n "$candidate" ]; then
      INSTALLER="$candidate"
      break
    fi
  done
  if [ -z "$INSTALLER" ]; then
    for dir in "$REPO_ROOT" "$BUILD_DIR/installers"; do
      candidate="$(find_installer "$dir" "MiniMax Code Setup *.exe")"
      [ -n "$candidate" ] || continue
      INSTALLER="$candidate"
      break
    done
  fi
fi
if [ -z "$INSTALLER" ] || [ ! -f "$INSTALLER" ]; then
  echo "Official Windows installer not found. Pass --installer <path>." >&2
  usage >&2
  exit 1
fi
INSTALLER="$(CDPATH= cd -- "$(dirname -- "$INSTALLER")" && pwd)/$(basename -- "$INSTALLER")"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}
for cmd in node npm 7z tar curl g++ make python3 dpkg-deb; do need "$cmd"; done

NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
if [ "$NODE_MAJOR" -lt 20 ]; then
  echo "Node.js 20 or newer is required (found $(node -v))." >&2
  exit 1
fi

log() { printf '\n==> %s\n' "$*"; }

# Toolchain selection. A build for the host architecture uses the host compiler,
# a build for another architecture uses the matching cross compiler.
case "$ARCH" in
  arm64) TRIPLE="aarch64-linux-gnu" ;;
  x64) TRIPLE="x86_64-linux-gnu" ;;
esac

if [ "$ARCH" = "$HOST_ARCH" ]; then
  CC_BIN="${CC:-gcc}"
  CXX_BIN="${CXX:-g++}"
else
  if [ "$CROSS" -ne 1 ]; then
    echo "Native modules for $ARCH must be built on a $ARCH host (current host: $HOST_ARCH)." >&2
    echo "Run this script on a $ARCH Linux machine, or pass --cross to use a cross compiler." >&2
    exit 1
  fi
  TOOL_PREFIX="${TOOL_PREFIX:-$TRIPLE-}"
  CC_BIN="${CC:-${TOOL_PREFIX}gcc}"
  CXX_BIN="${CXX:-${TOOL_PREFIX}g++}"
  need "$CC_BIN"
  need "$CXX_BIN"
  log "Cross building for $ARCH with $CC_BIN"
fi

# Sysroot flags. The sysroot supplies the C library headers and the startup
# files, so the native modules only need symbols that the targeted C library
# actually provides.
SYSROOT_C_FLAGS=()
SYSROOT_CXX_FLAGS=()
SYSROOT_LINK_LIBS=()
if [ -n "$SYSROOT" ]; then
  SYSROOT="$(CDPATH= cd -- "$SYSROOT" && pwd)"
  if [ ! -d "$SYSROOT/usr/include" ]; then
    echo "Sysroot $SYSROOT does not contain usr/include." >&2
    exit 1
  fi
  GCC_DIR="$(find "$SYSROOT/usr/lib/gcc/$TRIPLE" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -V | tail -1)"
  if [ -z "$GCC_DIR" ]; then
    echo "Sysroot $SYSROOT has no compiler support files for $TRIPLE." >&2
    exit 1
  fi
  CXX_VER="$(basename "$GCC_DIR")"
  # The library search path of the compiler itself is not prefixed with the
  # sysroot, so the directories of the sysroot are added explicitly. Without
  # them the linker would pick up the C library of the build host.
  SYSROOT_C_FLAGS=(
    "--sysroot=$SYSROOT"
    "-B$GCC_DIR/"
    "-L$SYSROOT/usr/lib/$TRIPLE"
    "-L$SYSROOT/lib/$TRIPLE"
  )
  # The C++ headers of the host compiler are newer than the ones in the
  # sysroot, and Electron needs C++20 for its V8 headers. The runtime libraries
  # still come from the sysroot, so only the C library stays old.
  # CXX_PREFIX points at a tree that holds the C++ headers of the target
  # architecture, for example a tree with the libstdc++ headers of the other
  # architecture.
  if [ -z "$CXX_PREFIX" ]; then
    if [ -d "/usr/include/$TRIPLE/c++" ]; then
      CXX_PREFIX="/"
    else
      echo "No C++ headers for $TRIPLE found. Pass --cxx-prefix <dir>." >&2
      exit 1
    fi
  fi
  HOST_CXX_DIR=""
  for candidate in "$CXX_PREFIX"/usr/include/c++/*; do
    [ -d "$candidate" ] || continue
    HOST_CXX_DIR="$candidate"
  done
  if [ -z "$HOST_CXX_DIR" ]; then
    echo "No C++ headers under $CXX_PREFIX/usr/include/c++." >&2
    exit 1
  fi
  HOST_CXX_VER="$(basename "$HOST_CXX_DIR")"
  HOST_CXX_TRIPLE_DIR="$CXX_PREFIX/usr/include/$TRIPLE/c++/$HOST_CXX_VER"
  HOST_GCC_INCLUDE="$("$CXX_BIN" -print-file-name=include)"
  SYSROOT_CXX_FLAGS=(
    "-isystem$HOST_CXX_DIR"
    "-isystem$HOST_CXX_TRIPLE_DIR"
    "-isystem$HOST_CXX_DIR/backward"
    "-isystem$HOST_GCC_INCLUDE"
  )
  SYSROOT_LINK_LIBS=(
    "$GCC_DIR/libstdc++.a"
    "$GCC_DIR/libgcc.a"
  )
  # Statically linking the C++ runtime keeps the modules free of a libstdc++
  # version dependency, which would otherwise tie them to one distribution.
  SYSROOT_TAG="$(basename "$SYSROOT")"
  log "Using sysroot $SYSROOT (C library from the sysroot, static C++ runtime)"
fi
log "Installer: $INSTALLER"
log "Target: Linux $ARCH, Electron $ELECTRON_VERSION"

rm -rf "$WORK_DIR"
mkdir -p "$CACHE_DIR" "$WORK_DIR" "$DIST_DIR" "$WORK_DIR/logs"

log "Extracting installer payload"
mkdir -p "$WORK_DIR/installer" "$WORK_DIR/win-app"
7z x -y "$INSTALLER" -o"$WORK_DIR/installer" >/dev/null
PAYLOAD_PATH="$WORK_DIR/installer/\$PLUGINSDIR/$PAYLOAD"
if [ ! -f "$PAYLOAD_PATH" ]; then
  echo "Payload $PAYLOAD not found. Is this installer built for $ARCH?" >&2
  exit 1
fi
7z x -y "$PAYLOAD_PATH" -o"$WORK_DIR/win-app" >/dev/null

ASAR_SRC="$WORK_DIR/win-app/resources/app.asar"
UNPACKED_SRC="$WORK_DIR/win-app/resources/app.asar.unpacked"
if [ ! -f "$ASAR_SRC" ]; then
  echo "app.asar not found in the extracted payload." >&2
  exit 1
fi

log "Downloading the Electron Linux $ARCH runtime"
ELECTRON_ZIP="$CACHE_DIR/electron-v$ELECTRON_VERSION-linux-$ARCH.zip"
if [ ! -f "$ELECTRON_ZIP" ]; then
  curl -fL --retry 3 -o "$ELECTRON_ZIP.part" \
    "$ELECTRON_MIRROR/electron/$ELECTRON_VERSION/electron-v$ELECTRON_VERSION-linux-$ARCH.zip"
  mv "$ELECTRON_ZIP.part" "$ELECTRON_ZIP"
fi
mkdir -p "$WORK_DIR/electron"
7z x -y "$ELECTRON_ZIP" -o"$WORK_DIR/electron" >/dev/null

log "Preparing shared build tools"
if [ ! -x "$TOOLS_DIR/node_modules/.bin/asar" ] || [ ! -x "$TOOLS_DIR/node_modules/.bin/node-gyp" ]; then
  mkdir -p "$TOOLS_DIR"
  (cd "$TOOLS_DIR" && npm init -y >/dev/null 2>&1)
  npm install --prefix "$TOOLS_DIR" --registry "$REGISTRY" --no-audit --no-fund \
    @electron/asar@3 node-gyp@11 >/dev/null
fi
ASAR_BIN="$TOOLS_DIR/node_modules/.bin/asar"
NODE_GYP_BIN="$TOOLS_DIR/node_modules/.bin/node-gyp"

log "Extracting app.asar"
node "$HERE/scripts/asar-placeholders.mjs" --asar "$ASAR_SRC" --unpacked "$UNPACKED_SRC"
APP_DIR="$WORK_DIR/app"
mkdir -p "$APP_DIR"
"$ASAR_BIN" extract "$ASAR_SRC" "$APP_DIR" >/dev/null
if [ -d "$UNPACKED_SRC" ]; then
  cp -a "$UNPACKED_SRC/." "$APP_DIR/"
fi

log "Applying Linux patches"
node "$HERE/scripts/patch-app.mjs" --app="$APP_DIR"

APP_VERSION="$(node -p "require('$APP_DIR/package.json').version")"
log "Detected MiniMax Code $APP_VERSION"

log "Installing Linux $ARCH native packages"
node "$HERE/scripts/install-platform-packages.mjs" \
  --app "$APP_DIR" --arch "$ARCH" --registry "$REGISTRY" --work "$WORK_DIR/platform-packages"

log "Downloading Electron $ELECTRON_VERSION headers"
HEADERS_TAR="$CACHE_DIR/node-v$ELECTRON_VERSION-headers.tar.gz"
if [ ! -f "$HEADERS_TAR" ]; then
  curl -fL --retry 3 -o "$HEADERS_TAR.part" \
    "$ELECTRON_MIRROR/electron/$ELECTRON_VERSION/node-v$ELECTRON_VERSION-headers.tar.gz" ||
    curl -fL --retry 3 -o "$HEADERS_TAR.part" \
      "https://artifacts.electronjs.org/headers/dist/v$ELECTRON_VERSION/node-v$ELECTRON_VERSION-headers.tar.gz"
  mv "$HEADERS_TAR.part" "$HEADERS_TAR"
fi
HEADERS_DIR="$WORK_DIR/headers"
mkdir -p "$HEADERS_DIR"
tar -xzf "$HEADERS_TAR" -C "$HEADERS_DIR" --strip-components=1

# node-gyp picks the compiler up from the environment. Wrappers keep the
# sysroot flags out of the generated makefiles, where gyp would reorder them.
CC_WRAPPER="$WORK_DIR/tools/cc"
CXX_WRAPPER="$WORK_DIR/tools/cxx"
mkdir -p "$WORK_DIR/tools"
{
  echo "#!/bin/sh"
  printf 'exec %s' "$CC_BIN"
  [ ${#SYSROOT_C_FLAGS[@]} -gt 0 ] && printf ' %s' "${SYSROOT_C_FLAGS[@]}"
  printf ' "$@"\n'
} > "$CC_WRAPPER"
{
  echo "#!/bin/sh"
  printf 'exec %s' "$CXX_BIN"
  [ ${#SYSROOT_C_FLAGS[@]} -gt 0 ] && printf ' %s' "${SYSROOT_C_FLAGS[@]}"
  [ ${#SYSROOT_CXX_FLAGS[@]} -gt 0 ] && printf ' %s' "${SYSROOT_CXX_FLAGS[@]}"
  printf ' "$@"'
  if [ ${#SYSROOT_LINK_LIBS[@]} -gt 0 ]; then
    # Link the C++ runtime statically, but only for a link step.
    printf '\nfor arg in "$@"; do\n  if [ "$arg" = "-shared" ]; then\n    exec %s' "$CXX_BIN"
    [ ${#SYSROOT_C_FLAGS[@]} -gt 0 ] && printf ' %s' "${SYSROOT_C_FLAGS[@]}"
    [ ${#SYSROOT_CXX_FLAGS[@]} -gt 0 ] && printf ' %s' "${SYSROOT_CXX_FLAGS[@]}"
    printf ' "$@"'
    printf ' %s' "${SYSROOT_LINK_LIBS[@]}"
    printf '\n  fi\ndone\nexec %s' "$CXX_BIN"
    [ ${#SYSROOT_C_FLAGS[@]} -gt 0 ] && printf ' %s' "${SYSROOT_C_FLAGS[@]}"
    [ ${#SYSROOT_CXX_FLAGS[@]} -gt 0 ] && printf ' %s' "${SYSROOT_CXX_FLAGS[@]}"
    printf ' "$@"\n'
  else
    printf '\n'
  fi
} > "$CXX_WRAPPER"
chmod +x "$CC_WRAPPER" "$CXX_WRAPPER"

build_native() {
  local module="$1"
  shift
  local version
  version="$(node -p "require('$APP_DIR/node_modules/$module/package.json').version")"
  local dest="$APP_DIR/node_modules/$module"

  # The compiled modules are cached, because building them takes minutes and
  # the result only depends on the module version, the Electron release, the
  # architecture and the sysroot.
  local cache_key="$module-$version-electron$ELECTRON_VERSION-$ARCH-${SYSROOT_TAG:-host}"
  local cache_dir="$CACHE_DIR/native/$cache_key"
  if [ -d "$cache_dir/build" ]; then
    log "Restoring cached $module@$version ($ARCH)"
    rm -rf "$dest/build"
    cp -a "$cache_dir/build" "$dest/build"
    return 0
  fi

  log "Building $module@$version for Electron $ELECTRON_VERSION ($ARCH)"

  local src="$WORK_DIR/source/$module"
  local tarball
  mkdir -p "$WORK_DIR/source" "$WORK_DIR/source-packages"
  tarball="$(npm pack "$module@$version" --pack-destination "$WORK_DIR/source-packages" \
    --registry "$REGISTRY" --prefer-offline --no-audit --no-fund | tail -1)"
  rm -rf "$src"
  mkdir -p "$src"
  tar -xzf "$WORK_DIR/source-packages/$tarball" -C "$src" --strip-components=1

  for path in "$@"; do
    if [ -e "$src/$path" ]; then
      rm -rf "$dest/$path"
      cp -a "$src/$path" "$dest/$path"
    fi
  done

  (cd "$dest" && CC="$CC_WRAPPER" CXX="$CXX_WRAPPER" \
    "$NODE_GYP_BIN" rebuild \
    --target="$ELECTRON_VERSION" --arch="$ARCH" --nodedir="$HEADERS_DIR" --jobs=max \
    > "$WORK_DIR/logs/$module-build.log" 2>&1) || {
      echo "Failed to build $module. See $WORK_DIR/logs/$module-build.log" >&2
      tail -30 "$WORK_DIR/logs/$module-build.log" >&2
      exit 1
    }

  rm -rf "$cache_dir"
  mkdir -p "$cache_dir"
  cp -a "$dest/build" "$cache_dir/build"
}

build_native better-sqlite3 binding.gyp src deps lib
build_native node-pty binding.gyp src deps third_party

log "Checking the compiled native modules"
node "$HERE/scripts/check-native-modules.mjs" --app "$APP_DIR" --arch "$ARCH" \
  --max-glibc "${MAX_GLIBC:-2.34}"

log "Repacking app.asar"
PKG_DIR="$WORK_DIR/pkg/MiniMaxCode-$APP_VERSION-linux-$ARCH"
mkdir -p "$PKG_DIR/resources"
cp -a "$WORK_DIR/electron/." "$PKG_DIR/"
if [ -d "$WORK_DIR/win-app/resources/resources" ]; then
  cp -a "$WORK_DIR/win-app/resources/resources" "$PKG_DIR/resources/"
fi
"$ASAR_BIN" pack "$APP_DIR" "$PKG_DIR/resources/app.asar" --unpack-dir node_modules >/dev/null
cp "$HERE/assets/icon.png" "$PKG_DIR/resources/resources/icon.png"
cp "$HERE/assets/launcher.sh" "$PKG_DIR/minimax-code"
chmod +x "$PKG_DIR/minimax-code" "$PKG_DIR/electron"

log "Auditing the runtime dependencies"
node "$HERE/scripts/check-package-deps.mjs" --pkg "$PKG_DIR" --control "$HERE/debian/control.in"

log "Building Debian package"
DEB_ROOT="$WORK_DIR/deb"
mkdir -p "$DEB_ROOT/DEBIAN" \
  "$DEB_ROOT/opt/minimax-code" \
  "$DEB_ROOT/usr/bin" \
  "$DEB_ROOT/usr/share/applications" \
  "$DEB_ROOT/usr/share/icons/hicolor/256x256/apps" \
  "$DEB_ROOT/usr/share/doc/minimax-code"
cp -a "$PKG_DIR/." "$DEB_ROOT/opt/minimax-code/"
ln -s /opt/minimax-code/minimax-code "$DEB_ROOT/usr/bin/minimax-code"
cp "$HERE/assets/icon.png" "$DEB_ROOT/usr/share/icons/hicolor/256x256/apps/minimax-code.png"
sed -e "s|@VERSION@|$APP_VERSION|g" \
    -e "s|@DEB_ARCH@|$DEB_ARCH|g" \
    -e "s|@INSTALLED_SIZE@|$(du -sk "$DEB_ROOT/opt" | cut -f1)|g" \
    "$HERE/debian/control.in" > "$DEB_ROOT/DEBIAN/control"
cp "$HERE/debian/minimax-code.desktop" "$DEB_ROOT/usr/share/applications/minimax-code.desktop"
cp "$HERE/debian/copyright" "$DEB_ROOT/usr/share/doc/minimax-code/copyright"
cp "$HERE/debian/postinst" "$DEB_ROOT/DEBIAN/postinst"
cp "$HERE/debian/postrm" "$DEB_ROOT/DEBIAN/postrm"
chmod 755 "$DEB_ROOT/DEBIAN/postinst" "$DEB_ROOT/DEBIAN/postrm"

DEB_FILE="$DIST_DIR/minimax-code_${APP_VERSION}_${DEB_ARCH}.deb"
dpkg-deb --root-owner-group -Z"$DEB_COMPRESS" --build "$DEB_ROOT" "$DEB_FILE" >/dev/null

if [ "$PORTABLE" -eq 1 ]; then
  log "Creating portable archive"
  tar -C "$WORK_DIR/pkg" -czf "$DIST_DIR/MiniMaxCode-$APP_VERSION-linux-$ARCH.tar.gz" \
    "MiniMaxCode-$APP_VERSION-linux-$ARCH"
fi

log "Done"
echo "Debian package: $DEB_FILE"
if [ "$PORTABLE" -eq 1 ]; then
  echo "Portable app:  $DIST_DIR/MiniMaxCode-$APP_VERSION-linux-$ARCH.tar.gz"
fi
echo "Portable folder: $PKG_DIR"
