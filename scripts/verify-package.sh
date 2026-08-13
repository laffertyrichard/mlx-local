#!/bin/bash
set -euo pipefail

PKG="${1:-}"
[[ -n "$PKG" && -f "$PKG" ]] || { echo "Usage: $0 path/to/MLX-Menu.pkg" >&2; exit 2; }

for tool in pkgutil lsbom lipo vtool codesign python3; do
  command -v "$tool" >/dev/null || { echo "Missing required verification tool: $tool" >&2; exit 1; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/mlx-menu-verify.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

pkgutil --expand "$PKG" "$WORK/flat"
pkgutil --expand-full "$PKG" "$WORK/expanded"
DISTRIBUTION="$WORK/expanded/Distribution"
[[ -f "$DISTRIBUTION" ]] || { echo "Package is missing its Distribution file." >&2; exit 1; }

python3 - "$DISTRIBUTION" <<'PY'
import sys
import xml.etree.ElementTree as ET

def fail(message: str) -> None:
    raise SystemExit(message)

root = ET.parse(sys.argv[1]).getroot()
options = root.find("options")
if options is None or options.get("hostArchitectures") != "arm64":
    fail("arm64 installer gate missing")
os_version = root.find("./volume-check/allowed-os-versions/os-version")
if os_version is None or os_version.get("min") != "14.0":
    fail("macOS 14 installer gate missing")
volume_check = root.find("volume-check")
if volume_check is None or volume_check.get("script") is not None:
    fail("unexpected Distribution volume-check script")
if root.find("script") is not None or root.find("installation-check") is not None:
    fail("unexpected Distribution install script")
if root.findall(".//locator") or root.findall(".//search"):
    fail("unexpected Distribution search logic")
pkg_refs = root.findall("pkg-ref")
if not any(ref.find("./must-close/app[@id='local.mccully.mlx-menu']") is not None for ref in pkg_refs):
    fail("running-app upgrade guard missing")
PY

if find "$WORK/expanded" -type d -name Scripts -print -quit | grep -q .; then
  echo "Package unexpectedly contains component install scripts." >&2
  exit 1
fi

BOMS="$(find "$WORK/flat" -type f -name Bom -print)"
[[ "$(printf '%s\n' "$BOMS" | sed '/^$/d' | wc -l | tr -d ' ')" == "1" ]] || {
  echo "Package must contain exactly one component BOM." >&2
  exit 1
}
BOM="$BOMS"
BOM_LIST="$WORK/bom-list"
lsbom -s "$BOM" > "$BOM_LIST"
if grep -Eq '(^|/)Applications($|/)' "$BOM_LIST"; then
  echo "Package BOM must not contain the system /Applications directory." >&2
  exit 1
fi
PACKAGE_INFOS="$(find "$WORK/expanded" -type f -name PackageInfo -print)"
[[ "$(printf '%s\n' "$PACKAGE_INFOS" | sed '/^$/d' | wc -l | tr -d ' ')" == "1" ]] || {
  echo "Package must contain exactly one PackageInfo." >&2
  exit 1
}
PACKAGE_INFO="$PACKAGE_INFOS"
grep -q 'install-location="/Applications"' "$PACKAGE_INFO" || {
  echo "Component is not rooted directly at /Applications." >&2
  exit 1
}

APPS="$(find "$WORK/expanded" -type d -name '*.app' -print)"
[[ "$(printf '%s\n' "$APPS" | sed '/^$/d' | wc -l | tr -d ' ')" == "1" ]] || {
  echo "Package must contain exactly one application bundle." >&2
  exit 1
}
APP="$APPS"
[[ "$APP" == */Payload/MLX\ Menu.app ]] || {
  echo "Package payload does not contain the expected MLX Menu.app." >&2
  exit 1
}
if find "$APP" -type l -print -quit | grep -q .; then
  echo "Application payload unexpectedly contains a symbolic link." >&2
  exit 1
fi

EXPECTED="$WORK/expected-files"
ACTUAL="$WORK/actual-files"
cat > "$EXPECTED" <<'FILES'
Contents/Info.plist
Contents/MacOS/MLXMenu
Contents/Resources/capabilities.json
Contents/Resources/local-results.json
Contents/Resources/mlx_server_no_mpi.py
Contents/Resources/model-profiles.json
Contents/Resources/worker_watchdog.py
Contents/_CodeSignature/CodeResources
FILES
(
  cd "$APP"
  find . -type f -print | sed 's#^./##' | LC_ALL=C sort
) > "$ACTUAL"
diff -u "$EXPECTED" "$ACTUAL" || {
  echo "Application payload differs from the release allowlist." >&2
  exit 1
}

plutil -lint "$APP/Contents/Info.plist" >/dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" == "local.mccully.mlx-menu" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")" == "14.0" ]]
[[ "$(lipo -archs "$APP/Contents/MacOS/MLXMenu")" == "arm64" ]] || {
  echo "MLX Menu binary is not a thin arm64 executable." >&2
  exit 1
}
vtool -show-build-version "$APP/Contents/MacOS/MLXMenu" | grep -Eq '^[[:space:]]*minos 14\.0$' || {
  echo "MLX Menu binary does not declare macOS 14.0 as its deployment target." >&2
  exit 1
}
codesign --verify --deep --strict "$APP"

if [[ "${REQUIRE_SIGNED:-0}" == "1" ]]; then
  APP_SIGNATURE="$(codesign -dv --verbose=4 "$APP" 2>&1)"
  grep -q '^Authority=Developer ID Application:' <<<"$APP_SIGNATURE" || {
    echo "App is not signed with a Developer ID Application identity." >&2
    exit 1
  }
  grep -Eq 'flags=0x[0-9a-f]+\([^)]*runtime' <<<"$APP_SIGNATURE" || {
    echo "App signature does not enable the hardened runtime." >&2
    exit 1
  }
  PKG_SIGNATURE="$(pkgutil --check-signature "$PKG")"
  grep -q 'Developer ID Installer:' <<<"$PKG_SIGNATURE" || {
    echo "Package is not signed with a Developer ID Installer identity." >&2
    exit 1
  }
  spctl --assess --type install --verbose=4 "$PKG"
  xcrun stapler validate "$PKG"
  echo "Package verification passed (Developer ID signed and notarization ticket stapled)."
elif pkgutil --check-signature "$PKG" >/dev/null 2>&1; then
  echo "Package verification passed (signed installer; trust/notarization not required in this mode)."
else
  echo "Package verification passed (unsigned installer; sign and notarize for frictionless distribution)."
fi
