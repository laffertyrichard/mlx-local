#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${1:-$ROOT/dist}"
APP_NAME="MLX Menu"
PRODUCT_ID="local.mccully.mlx-menu"
COMPONENT_ID="${PRODUCT_ID}.component"
INSTALLER_IDENTITY="${INSTALLER_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

for tool in pkgbuild productbuild pkgutil; do
  command -v "$tool" >/dev/null || { echo "Missing required macOS tool: $tool" >&2; exit 1; }
done
if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
  echo "The MLX Menu package must be built on Apple silicon macOS." >&2
  exit 1
fi
if [[ -n "${CODESIGN_IDENTITY:-}" || -n "$INSTALLER_IDENTITY" ]]; then
  [[ -n "${CODESIGN_IDENTITY:-}" && "${CODESIGN_IDENTITY:-}" != "-" && -n "$INSTALLER_IDENTITY" ]] || {
    echo "A non-ad-hoc CODESIGN_IDENTITY and INSTALLER_IDENTITY must be supplied together." >&2
    exit 1
  }
fi
if [[ -n "$NOTARY_PROFILE" && -z "$INSTALLER_IDENTITY" ]]; then
  echo "NOTARY_PROFILE requires Developer ID application and installer identities." >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mlx-menu-package.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# Root the component directly at /Applications so the BOM can never change the
# ownership or mode of the existing system /Applications directory.
PAYLOAD="$WORK/payload"
APP="$PAYLOAD/${APP_NAME}.app"
umask 022
mkdir -p "$PAYLOAD"
chmod 0755 "$PAYLOAD"
"$ROOT/scripts/build-app.sh" "$APP" >/dev/null

INFO="$APP/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO")"
PACKAGE_VERSION="${VERSION}.${BUILD_NUMBER}"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO")"
[[ "$BUNDLE_ID" == "$PRODUCT_ID" ]] || { echo "Unexpected bundle identifier: $BUNDLE_ID" >&2; exit 1; }

COMPONENT_PLIST="$WORK/component.plist"
cat > "$COMPONENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><array><dict>
<key>BundleHasStrictIdentifier</key><true/>
<key>BundleIsRelocatable</key><false/>
<key>BundleIsVersionChecked</key><true/>
<key>BundleOverwriteAction</key><string>upgrade</string>
<key>RootRelativeBundlePath</key><string>${APP_NAME}.app</string>
</dict></array></plist>
PLIST
plutil -lint "$COMPONENT_PLIST" >/dev/null

COMPONENT_PKG="$WORK/MLXMenu-component.pkg"
pkgbuild \
  --root "$PAYLOAD" \
  --component-plist "$COMPONENT_PLIST" \
  --identifier "$COMPONENT_ID" \
  --version "$PACKAGE_VERSION" \
  --install-location /Applications \
  --ownership recommended \
  "$COMPONENT_PKG" >/dev/null

DISTRIBUTION="$WORK/Distribution.xml"
cat > "$DISTRIBUTION" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>MLX Menu $VERSION</title>
  <organization>$PRODUCT_ID</organization>
  <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
  <options customize="never" require-scripts="false" hostArchitectures="arm64"/>
  <volume-check>
    <allowed-os-versions><os-version min="14.0"/></allowed-os-versions>
  </volume-check>
  <welcome file="welcome.html" mime-type="text/html"/>
  <readme file="readme.html" mime-type="text/html"/>
  <choices-outline><line choice="default"/></choices-outline>
  <choice id="default" title="MLX Menu" visible="false"><pkg-ref id="$COMPONENT_ID"/></choice>
  <pkg-ref id="$COMPONENT_ID" version="$PACKAGE_VERSION" onConclusion="none">MLXMenu-component.pkg
    <must-close><app id="$PRODUCT_ID"/></must-close>
  </pkg-ref>
</installer-gui-script>
XML

PKG="$OUTPUT_DIR/MLX-Menu-${PACKAGE_VERSION}.pkg"
STAGED_PKG="$WORK/MLX-Menu-${PACKAGE_VERSION}.pkg"
CHECKSUM="${PKG}.sha256"
rm -f "$PKG" "$CHECKSUM"
PRODUCT_ARGS=(--distribution "$DISTRIBUTION" --resources "$ROOT/packaging/resources" --package-path "$WORK")
if [[ -n "$INSTALLER_IDENTITY" ]]; then
  PRODUCT_ARGS+=(--sign "$INSTALLER_IDENTITY")
fi
productbuild "${PRODUCT_ARGS[@]}" "$STAGED_PKG" >/dev/null

if [[ -n "$NOTARY_PROFILE" ]]; then
  xcrun notarytool submit "$STAGED_PKG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$STAGED_PKG"
fi

if [[ -n "$INSTALLER_IDENTITY" ]]; then
  REQUIRE_SIGNED=1 "$ROOT/scripts/verify-package.sh" "$STAGED_PKG"
else
  "$ROOT/scripts/verify-package.sh" "$STAGED_PKG"
fi
mv "$STAGED_PKG" "$PKG"
(
  cd "$OUTPUT_DIR"
  shasum -a 256 "$(basename "$PKG")" > "$(basename "$CHECKSUM")"
)
echo "Built $PKG"
echo "Checksum: $CHECKSUM"
