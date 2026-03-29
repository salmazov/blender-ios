#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────
#  Blender iOS – macOS build-environment setup
#
#  Usage:  ./setup_ios.sh          (interactive, will ask before acting)
#          ./setup_ios.sh --auto   (non-interactive, installs everything)
#
#  What it does:
#    1. Verifies macOS and Apple Silicon
#    2. Checks / installs Xcode Command Line Tools
#    3. Checks / installs Homebrew
#    4. Checks / installs CMake (via Homebrew)
#    5. Checks / installs Git LFS
#    6. Clones prebuilt library submodules (ios_arm64 + macos_arm64)
#    7. Runs CMake to configure the Xcode project
#    8. Builds Blender for iOS (Release)
# ──────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Colour

ok()   { printf "${GREEN}✔${NC}  %s\n" "$*"; }
warn() { printf "${YELLOW}⚠${NC}  %s\n" "$*"; }
err()  { printf "${RED}✖${NC}  %s\n" "$*" >&2; }
info() { printf "${CYAN}→${NC}  %s\n" "$*"; }

AUTO=false
[[ "${1:-}" == "--auto" ]] && AUTO=true

ask() {
  if $AUTO; then return 0; fi
  printf "${CYAN}?${NC}  %s [Y/n] " "$1"
  read -r ans
  [[ -z "$ans" || "$ans" =~ ^[Yy] ]]
}

# ── 0. Locate repo root ─────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"

if [[ ! -f "$REPO_ROOT/CMakeLists.txt" ]]; then
  err "Cannot find CMakeLists.txt in $REPO_ROOT"
  err "Run this script from the repository root."
  exit 1
fi

BUILD_DIR="$REPO_ROOT/build_ios"

echo ""
info "Blender iOS build setup"
info "Repository: $REPO_ROOT"
info "Build dir:  $BUILD_DIR"
echo ""

# ── 1. Platform check ───────────────────────────────────────────────
if [[ "$(uname)" != "Darwin" ]]; then
  err "This script requires macOS."
  exit 1
fi
ok "macOS detected"

ARCH="$(uname -m)"
if [[ "$ARCH" != "arm64" ]]; then
  warn "Apple Silicon (arm64) recommended. Detected: $ARCH"
  warn "Cross-compilation to iOS may require arm64 host libraries."
fi

# ── 2. Xcode / Command Line Tools ───────────────────────────────────
if xcode-select -p &>/dev/null; then
  XCODE_PATH="$(xcode-select -p)"
  ok "Xcode developer tools: $XCODE_PATH"
else
  warn "Xcode Command Line Tools not found."
  if ask "Install Xcode Command Line Tools?"; then
    xcode-select --install
    info "Please complete the installation dialog, then re-run this script."
    exit 0
  else
    err "Xcode Command Line Tools are required."
    exit 1
  fi
fi

# Verify Xcode.app is available (not just CLI tools)
if [[ ! -d "/Applications/Xcode.app" ]]; then
  err "Xcode.app not found in /Applications."
  err "Install Xcode from the App Store — the full IDE is required for iOS builds."
  exit 1
fi
ok "Xcode.app found"

# Verify iOS SDK is present
IOS_SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || true)"
if [[ -z "$IOS_SDK_PATH" || ! -d "$IOS_SDK_PATH" ]]; then
  err "iOS SDK not found. Open Xcode → Settings → Platforms → install iOS."
  exit 1
fi
ok "iOS SDK: $IOS_SDK_PATH"

# ── 3. Homebrew ──────────────────────────────────────────────────────
if command -v brew &>/dev/null; then
  ok "Homebrew: $(brew --version | head -1)"
else
  warn "Homebrew not found."
  if ask "Install Homebrew?"; then
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    eval "$(/opt/homebrew/bin/brew shellenv)"
  else
    err "Homebrew is needed for installing CMake."
    exit 1
  fi
fi

# ── 4. CMake ─────────────────────────────────────────────────────────
CMAKE_MIN="3.10"
if command -v cmake &>/dev/null; then
  CMAKE_VER="$(cmake --version | head -1 | sed 's/cmake version //')"
  ok "CMake: $CMAKE_VER"
else
  warn "CMake not found."
  if ask "Install CMake via Homebrew?"; then
    brew install cmake
  else
    err "CMake >= $CMAKE_MIN is required."
    exit 1
  fi
fi

# ── 5. Git LFS ──────────────────────────────────────────────────────
if command -v git-lfs &>/dev/null; then
  ok "Git LFS: $(git lfs version | head -1)"
else
  warn "Git LFS not found."
  if ask "Install Git LFS via Homebrew?"; then
    brew install git-lfs
    git lfs install
  else
    warn "Git LFS is optional but some assets may not download correctly."
  fi
fi

# ── 6. Prebuilt libraries (submodules) ───────────────────────────────
echo ""
info "Checking prebuilt libraries…"

fetch_lib() {
  local lib_path="$1"
  local lib_name
  lib_name="$(basename "$lib_path")"

  if [[ -d "$lib_path" && -f "$lib_path/python/lib/libpython3.11.a" ]]; then
    ok "lib/$lib_name already present"
    return 0
  fi

  info "Fetching lib/$lib_name (this may take a while, ~2 GB)…"
  cd "$REPO_ROOT"
  GIT_LFS_SKIP_SMUDGE=0 git submodule update --init --depth 1 "lib/$lib_name"
  ok "lib/$lib_name fetched"
}

fetch_lib "$REPO_ROOT/lib/ios_arm64"
fetch_lib "$REPO_ROOT/lib/macos_arm64"

# Verify Python exists in iOS libs
if [[ ! -f "$REPO_ROOT/lib/ios_arm64/python/lib/libpython3.11.a" ]]; then
  err "lib/ios_arm64/python/lib/libpython3.11.a not found."
  err "The iOS prebuilt libraries may be incomplete. Try:"
  err "  cd lib/ios_arm64 && git lfs pull"
  exit 1
fi
ok "iOS Python library present"

# Verify host Python for cross-compilation
HOST_PYTHON="$(find "$REPO_ROOT/lib/macos_arm64/python/bin" -name 'python3.*' -not -name '*config*' 2>/dev/null | head -1 || true)"
if [[ -z "$HOST_PYTHON" ]]; then
  err "Host Python not found in lib/macos_arm64/python/bin/"
  err "The macOS prebuilt libraries may be incomplete. Try:"
  err "  cd lib/macos_arm64 && git lfs pull"
  exit 1
fi
ok "Host Python: $HOST_PYTHON"

# ── 7. CMake configure ──────────────────────────────────────────────
echo ""
info "Configuring CMake for iOS…"

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# Clean stale cache if source directory changed
if [[ -f CMakeCache.txt ]]; then
  CACHED_SRC="$(grep 'CMAKE_HOME_DIRECTORY:INTERNAL=' CMakeCache.txt 2>/dev/null | cut -d= -f2)"
  if [[ -n "$CACHED_SRC" && "$CACHED_SRC" != "$REPO_ROOT" ]]; then
    warn "CMake cache points to different source: $CACHED_SRC"
    info "Removing stale cache…"
    rm -f CMakeCache.txt
    rm -rf CMakeFiles CMakeScripts
  fi
fi

IOS_LIBDIR="$REPO_ROOT/lib/ios_arm64"
IOS_SDK_ROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
IOS_DEV_ROOT="$(dirname "$IOS_SDK_ROOT")"

cmake -G Xcode \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DWITH_APPLE_CROSSPLATFORM=ON \
  -DAPPLE_TARGET_DEVICE=ios \
  -DCMAKE_FIND_ROOT_PATH="$IOS_DEV_ROOT;$(dirname "$IOS_DEV_ROOT");$IOS_LIBDIR" \
  "$REPO_ROOT"

ok "CMake configuration complete"

# ── 8. Build ─────────────────────────────────────────────────────────
echo ""
if ask "Build Blender for iOS now? (Release, this takes 10–30 min on first run)"; then
  info "Building…"
  NCPU="$(sysctl -n hw.ncpu)"
  xcodebuild \
    -project Blender.xcodeproj \
    -scheme blender \
    -configuration Release \
    -sdk iphoneos \
    -jobs "$NCPU" \
    build 2>&1 | tail -5

  echo ""
  ok "Build finished"
else
  info "Skipping build. To build manually:"
  info "  cd $BUILD_DIR"
  info "  xcodebuild -project Blender.xcodeproj -scheme blender -configuration Release -sdk iphoneos build"
fi

echo ""
ok "Setup complete!"
