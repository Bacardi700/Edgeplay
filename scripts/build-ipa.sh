#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
#
# Builds an UNSIGNED EdgePlay.ipa for sideloading. AltStore, SideStore, Sideloadly
# (or a signing service) re-sign it with your own Apple ID when they install it.
#
#   ./scripts/build-ipa.sh                 # version from git tag, or 0.1.0
#   VERSION=1.2.0 BUILD=42 ./scripts/build-ipa.sh
#
# Output: build/EdgePlay.ipa

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-$(date +%Y%m%d%H%M)}"
OUT="$ROOT/build"
DERIVED="$OUT/DerivedData"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

if [[ ! -d Frameworks/ChiakiCore.xcframework ]]; then
  log "ChiakiCore.xcframework missing, building it first"
  ./scripts/build-chiaki-ios.sh
fi

command -v xcodegen >/dev/null || { echo "Install XcodeGen: brew install xcodegen" >&2; exit 1; }
log "Generating Xcode project"
xcodegen generate --quiet

log "Building EdgePlay $VERSION ($BUILD), unsigned"
rm -rf "$OUT" && mkdir -p "$OUT"
xcodebuild \
  -project EdgePlay.xcodeproj \
  -scheme EdgePlay \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  DEVELOPMENT_TEAM="" \
  build | { command -v xcpretty >/dev/null && xcpretty || cat; }

APP="$DERIVED/Build/Products/Release-iphoneos/EdgePlay.app"
[[ -d "$APP" ]] || { echo "Build produced no app at $APP" >&2; exit 1; }

log "Packaging IPA"
STAGE="$OUT/ipa"
mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
rm -rf "$STAGE/Payload/EdgePlay.app/_CodeSignature"
(cd "$STAGE" && zip -qry "$OUT/EdgePlay.ipa" Payload)
rm -rf "$STAGE"

echo "$VERSION" > "$OUT/VERSION"
log "Done: $OUT/EdgePlay.ipa ($(du -h "$OUT/EdgePlay.ipa" | cut -f1))"
