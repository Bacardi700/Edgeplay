#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
#
# Builds chiaki-ng's streaming library (plus OpenSSL, Opus, json-c, libevent,
# miniupnpc and curl) for iOS and packages it as Frameworks/ChiakiCore.xcframework.
#
# Run on a Mac with Xcode installed:
#   brew install cmake ninja pkg-config autoconf automake libtool protobuf
#   python3 -m pip install --user protobuf grpcio-tools
#   ./scripts/build-chiaki-ios.sh            # device only (what you need to play)
#   ./scripts/build-chiaki-ios.sh --simulator # also build an arm64 simulator slice
#
# First run takes 10-20 minutes (mostly OpenSSL). Later runs reuse the cache in .build/.

set -euo pipefail

CHIAKI_REPO="https://github.com/streetpea/chiaki-ng.git"
CHIAKI_COMMIT="43728af2e639fecb8a7af1cd68c29820a40de973"   # tested API revision
IOS_MIN="16.0"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.build"
SRC="$WORK/chiaki-ng"
VCPKG="$WORK/vcpkg"
TRIPLETS="$WORK/triplets"
OUT="$ROOT/Frameworks"

WITH_SIM=0
[[ "${1:-}" == "--simulator" ]] && WITH_SIM=1

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------------ preflight
[[ "$(uname)" == "Darwin" ]] || die "This script must run on macOS with Xcode."
for t in xcodebuild xcrun cmake ninja git pkg-config python3 libtool protoc; do
  command -v "$t" >/dev/null || die "Missing '$t'. See the brew line at the top of this script."
done
python3 -c "import google.protobuf, grpc_tools" 2>/dev/null \
  || die "Python protobuf tools missing: python3 -m pip install --user protobuf grpcio-tools"

mkdir -p "$WORK" "$OUT" "$TRIPLETS"

# ------------------------------------------------------------------ sources
if [[ ! -d "$SRC/.git" ]]; then
  log "Fetching chiaki-ng"
  git init -q "$SRC"
  git -C "$SRC" remote add origin "$CHIAKI_REPO"
fi
if [[ "$(git -C "$SRC" rev-parse HEAD 2>/dev/null || true)" != "$CHIAKI_COMMIT" ]]; then
  git -C "$SRC" fetch -q --depth 1 origin "$CHIAKI_COMMIT"
  git -C "$SRC" checkout -q --force FETCH_HEAD
fi
git -C "$SRC" submodule update --init --depth 1 \
  third-party/nanopb third-party/jerasure third-party/gf-complete third-party/curl

# chiaki forces the macOS deployment target for every Apple platform, which would
# set the *iOS* minimum to the Mac's version. Restrict that block to macOS.
if grep -q '^if(APPLE)$' "$SRC/CMakeLists.txt"; then
  log "Patching deployment-target block for iOS"
  /usr/bin/sed -i '' 's/^if(APPLE)$/if(APPLE AND NOT IOS)/' "$SRC/CMakeLists.txt"
fi

# EdgePlay's own tweaks to chiaki (network QoS, bigger socket buffer). Idempotent.
python3 "$ROOT/scripts/patches/chiaki-network.py" "$SRC"

# ------------------------------------------------------------------ vcpkg deps
if [[ ! -x "$VCPKG/vcpkg" ]]; then
  log "Bootstrapping vcpkg"
  git clone -q --depth 1 https://github.com/microsoft/vcpkg.git "$VCPKG"
  "$VCPKG/bootstrap-vcpkg.sh" -disableMetrics
fi

write_triplet() { # name sysroot
  cat > "$TRIPLETS/$1.cmake" <<EOF
set(VCPKG_TARGET_ARCHITECTURE arm64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE static)
set(VCPKG_CMAKE_SYSTEM_NAME iOS)
set(VCPKG_OSX_SYSROOT $2)
set(VCPKG_OSX_DEPLOYMENT_TARGET $IOS_MIN)
set(VCPKG_BUILD_TYPE release)
EOF
}
write_triplet edgeplay-ios iphoneos
write_triplet edgeplay-ios-sim iphonesimulator

DEPS=(openssl opus json-c libevent miniupnpc)

# ------------------------------------------------------------------ one slice
build_slice() { # triplet sysroot outdir
  local triplet="$1" sysroot="$2" dest="$3"
  local installed="$VCPKG/installed/$triplet"
  local bdir="$WORK/build-$triplet"

  log "[$triplet] Building dependencies with vcpkg"
  "$VCPKG/vcpkg" install --classic --overlay-triplets="$TRIPLETS" --triplet "$triplet" "${DEPS[@]}"

  log "[$triplet] Configuring chiaki-ng"
  # Only use the iOS .pc files, never Homebrew's.
  export PKG_CONFIG_LIBDIR="$installed/lib/pkgconfig:$installed/share/pkgconfig"
  export PKG_CONFIG_PATH=""
  cmake -S "$SRC" -B "$bdir" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_TOOLCHAIN_FILE="$VCPKG/scripts/buildsystems/vcpkg.cmake" \
    -DVCPKG_TARGET_TRIPLET="$triplet" \
    -DVCPKG_OVERLAY_TRIPLETS="$TRIPLETS" \
    -DVCPKG_MANIFEST_MODE=OFF \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT="$sysroot" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN" \
    -DCHIAKI_ENABLE_GUI=OFF -DCHIAKI_ENABLE_CLI=OFF -DCHIAKI_ENABLE_TESTS=OFF \
    -DCHIAKI_ENABLE_FFMPEG_DECODER=OFF -DCHIAKI_ENABLE_PI_DECODER=OFF \
    -DCHIAKI_ENABLE_SETSU=OFF -DCHIAKI_ENABLE_STEAMDECK_NATIVE=OFF \
    -DCHIAKI_ENABLE_SPEEX=OFF -DCHIAKI_ENABLE_STEAM_SHORTCUT=OFF \
    -DCHIAKI_GUI_ENABLE_SDL_GAMECONTROLLER=OFF \
    -DCHIAKI_LIB_ENABLE_OPUS=ON \
    -DCHIAKI_USE_SYSTEM_CURL=OFF -DCHIAKI_USE_SYSTEM_JERASURE=OFF -DCHIAKI_USE_SYSTEM_NANOPB=OFF \
    -DCURL_USE_LIBPSL=OFF -DUSE_LIBIDN2=OFF -DCURL_USE_LIBSSH2=OFF -DCURL_ZLIB=OFF \
    -DCURL_BROTLI=OFF -DCURL_ZSTD=OFF -DUSE_NGHTTP2=OFF -DCURL_DISABLE_LDAP=ON \
    -DPython3_EXECUTABLE="$(command -v python3)" \
    -DPYTHON_EXECUTABLE="$(command -v python3)" \
    -DPROTOC="$(command -v protoc)" \
    -Wno-dev

  log "[$triplet] Compiling"
  cmake --build "$bdir" --target chiaki-lib

  log "[$triplet] Merging static libraries"
  rm -rf "$dest" && mkdir -p "$dest/Headers"
  local libs=(
    "$bdir/lib/libchiaki.a"
    "$(find "$bdir/third-party" -name 'libjerasure.a' | head -1)"
    "$(find "$bdir/third-party" -name 'libgf_complete.a' | head -1)"
    "$(find "$bdir/third-party" -name 'libprotobuf-nanopb*.a' | head -1)"
    "$(find "$bdir/third-party" -name 'libcurl*.a' | head -1)"
    "$installed/lib/libssl.a"
    "$installed/lib/libcrypto.a"
    "$installed/lib/libopus.a"
    "$installed/lib/libjson-c.a"
    "$installed/lib/libminiupnpc.a"
  )
  # chiaki only needs libevent's core; the all-in-one archive would duplicate it.
  if [[ -f "$installed/lib/libevent_core.a" ]]; then
    libs+=("$installed/lib/libevent_core.a")
  else
    libs+=("$installed/lib/libevent.a")
  fi
  for l in "${libs[@]}"; do [[ -f "$l" ]] || die "Expected library not found: $l"; done
  libtool -static -no_warning_for_no_symbols -o "$dest/libChiakiCore.a" "${libs[@]}"

  cp -R "$SRC/lib/include/chiaki" "$dest/Headers/"
  cp "$bdir/lib/include/chiaki/config.h" "$dest/Headers/chiaki/config.h"
}

build_slice edgeplay-ios iphoneos "$WORK/slice-ios"
XC_ARGS=(-library "$WORK/slice-ios/libChiakiCore.a" -headers "$WORK/slice-ios/Headers")

if [[ $WITH_SIM == 1 ]]; then
  build_slice edgeplay-ios-sim iphonesimulator "$WORK/slice-sim"
  XC_ARGS+=(-library "$WORK/slice-sim/libChiakiCore.a" -headers "$WORK/slice-sim/Headers")
fi

log "Creating ChiakiCore.xcframework"
rm -rf "$OUT/ChiakiCore.xcframework" "$OUT/include"
xcodebuild -create-xcframework "${XC_ARGS[@]}" -output "$OUT/ChiakiCore.xcframework"
# Plain copy of the headers too, referenced by HEADER_SEARCH_PATHS in project.yml.
mkdir -p "$OUT/include" && cp -R "$WORK/slice-ios/Headers/chiaki" "$OUT/include/"

log "Done: $OUT/ChiakiCore.xcframework"
echo "Next: xcodegen generate && open EdgePlay.xcodeproj"
