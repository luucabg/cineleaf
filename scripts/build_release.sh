#!/usr/bin/env bash
set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$REPOSITORY_ROOT/dist"
DERIVED_DATA="$REPOSITORY_ROOT/build/ReleaseDerivedData"
RELEASE_VERSION="${CINELEAF_RELEASE_VERSION:-0.3.0}"

if [[ ! "$RELEASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  echo "Invalid release version: $RELEASE_VERSION" >&2
  exit 1
fi
MAC_BASENAME="Cineleaf-$RELEASE_VERSION-macOS"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Release builds require macOS with Xcode." >&2
  exit 1
fi
for tool in xcodebuild xcodegen codesign ditto shasum; do
  command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 1; }
done

case "$DIST_DIR" in
  "$REPOSITORY_ROOT/dist") ;;
  *) echo "Refusing unexpected distribution directory: $DIST_DIR" >&2; exit 1 ;;
esac
case "$DERIVED_DATA" in
  "$REPOSITORY_ROOT/build/ReleaseDerivedData") ;;
  *) echo "Refusing unexpected derived-data directory: $DERIVED_DATA" >&2; exit 1 ;;
esac
rm -rf "$DIST_DIR" "$DERIVED_DATA"
mkdir -p "$DIST_DIR" "$DERIVED_DATA"
cd "$REPOSITORY_ROOT"

xcodegen generate
xcodebuild \
  -project Cineleaf.xcodeproj \
  -scheme Cineleaf \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  ARCHS='arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  build

xcodebuild \
  -project Cineleaf.xcodeproj \
  -scheme CineleafCLI \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  ARCHS='arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  build

APP_SOURCE="$DERIVED_DATA/Build/Products/Release/Cineleaf.app"
[[ -d "$APP_SOURCE" ]] || { echo "Cineleaf.app was not produced." >&2; exit 1; }
ditto "$APP_SOURCE" "$DIST_DIR/Cineleaf.app"
CLI_SOURCE="$DERIVED_DATA/Build/Products/Release/CineleafCLI"
[[ -x "$CLI_SOURCE" ]] || { echo "CineleafCLI was not produced." >&2; exit 1; }
ditto "$CLI_SOURCE" "$DIST_DIR/Cineleaf.app/Contents/MacOS/CineleafCLI"
AUTOMATION_RESOURCES="$DIST_DIR/Cineleaf.app/Contents/Resources/Automation"
mkdir -p "$AUTOMATION_RESOURCES/mcp/src"
ditto "$REPOSITORY_ROOT/Automation/mcp/package.json" "$AUTOMATION_RESOURCES/mcp/package.json"
ditto "$REPOSITORY_ROOT/Automation/mcp/package-lock.json" "$AUTOMATION_RESOURCES/mcp/package-lock.json"
ditto "$REPOSITORY_ROOT/Automation/mcp/src" "$AUTOMATION_RESOURCES/mcp/src"
ditto "$REPOSITORY_ROOT/scripts/setup_cineleaf_mcp.sh" "$AUTOMATION_RESOURCES/setup_cineleaf_mcp.sh"
codesign --force --deep --sign - "$DIST_DIR/Cineleaf.app"
codesign --verify --deep --strict "$DIST_DIR/Cineleaf.app"
ditto -c -k --sequesterRsrc --keepParent "$DIST_DIR/Cineleaf.app" "$DIST_DIR/$MAC_BASENAME.zip"
"$REPOSITORY_ROOT/scripts/create_dmg.sh" \
  "$DIST_DIR/Cineleaf.app" \
  "$DIST_DIR/$MAC_BASENAME.dmg" \
  "Cineleaf $RELEASE_VERSION"

(
  cd "$DIST_DIR"
  shasum -a 256 "$MAC_BASENAME.zip" "$MAC_BASENAME.dmg" > "$MAC_BASENAME-SHA256SUMS.txt"
)

echo "Created ad-hoc signed, non-notarized artifacts in $DIST_DIR"
