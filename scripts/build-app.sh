#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="MLX Menu"
DEST="${1:-$ROOT/dist/${APP_NAME}.app}"
[[ "$DEST" == *.app && "$DEST" != "/" ]] || {
  echo "Bundle destination must be a .app path: $DEST" >&2
  exit 2
}
# shellcheck disable=SC1091
source "$ROOT/packaging/version.env"
VERSION="$MLX_MENU_VERSION"
BUILD_NUMBER="$MLX_MENU_BUILD_NUMBER"
BUNDLE_ID="local.mccully.mlx-menu"
SIGNING_IDENTITY="${CODESIGN_IDENTITY:--}"

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
  echo "MLX Menu can only be built on Apple silicon macOS." >&2
  exit 1
fi

cd "$ROOT"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$DEST"
umask 022
mkdir -p "$DEST/Contents/MacOS" "$DEST/Contents/Resources"
chmod 0755 "$DEST" "$DEST/Contents" "$DEST/Contents/MacOS" "$DEST/Contents/Resources"
install -m 0755 "$BIN_DIR/MLXMenu" "$DEST/Contents/MacOS/MLXMenu"
install -m 0644 "$ROOT/Sources/MLXMenu/Resources/mlx_server_no_mpi.py" "$DEST/Contents/Resources/mlx_server_no_mpi.py"
install -m 0644 "$ROOT/Sources/MLXMenu/Resources/worker_watchdog.py" "$DEST/Contents/Resources/worker_watchdog.py"
install -m 0644 "$ROOT/Benchmarks/local-results.json" "$DEST/Contents/Resources/local-results.json"
install -m 0644 "$ROOT/ModelMetadata/capabilities.json" "$DEST/Contents/Resources/capabilities.json"
install -m 0644 "$ROOT/V3/model-profiles.json" "$DEST/Contents/Resources/model-profiles.json"

cat > "$DEST/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MLXMenu</string>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleName</key><string>$APP_NAME</string>
<key>CFBundleDisplayName</key><string>$APP_NAME</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

plutil -lint "$DEST/Contents/Info.plist" >/dev/null
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  codesign --force --sign - "$DEST" >/dev/null
else
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$DEST"
fi
codesign --verify --deep --strict "$DEST"

echo "$DEST"
