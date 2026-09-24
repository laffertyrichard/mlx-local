#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="MLX Menu"
DEST="${HOME}/Applications/${APP_NAME}.app"
V1_WAS_RUNNING="${MLX_MENU_RESTORE_V1:-0}"
PLIST_PATH="$HOME/Library/LaunchAgents/local.mccully.mlx-menu.plist"
if [[ -f "$PLIST_PATH" ]] && grep -q '<string>--start</string>' "$PLIST_PATH"; then V1_WAS_RUNNING=1; fi
if curl -fsS --max-time 1 http://127.0.0.1:8081/health >/dev/null 2>&1; then V1_WAS_RUNNING=1; fi

missing=()
[[ -x "$HOME/.local/share/uv/tools/mlx-lm/bin/python" || -x "$HOME/.local/bin/mlx_lm.server" ]] || missing+=("mlx-lm")
[[ -x "$HOME/.local/bin/mlx_vlm.server" ]] || missing+=("mlx-vlm")
[[ -x "$HOME/.local/bin/mlx_audio.server" ]] || missing+=("mlx-audio[server]")
if ((${#missing[@]})); then
  echo "Warning: missing optional V2 backend(s): ${missing[*]}" >&2
  echo "Manual V1 remains available; install missing uv tools to enable every Auto modality." >&2
fi

"$ROOT/scripts/build-app.sh" "$DEST" >/dev/null

if [[ "${1:-}" != "--no-launch-at-login" ]]; then
  mkdir -p "$(dirname "$PLIST_PATH")"
  START_ARGUMENT=""
  [[ "$V1_WAS_RUNNING" == "1" ]] && START_ARGUMENT="<string>--start</string>"
  cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>local.mccully.mlx-menu</string>
<key>ProgramArguments</key><array><string>$DEST/Contents/MacOS/MLXMenu</string>$START_ARGUMENT</array>
<key>RunAtLoad</key><true/>
<key>ProcessType</key><string>Interactive</string>
</dict></plist>
PLIST
  DOMAIN="gui/$(id -u)"
  launchctl bootout "$DOMAIN/local.mccully.mlx-menu" 2>/dev/null || true
  for _ in {1..20}; do
    launchctl print "$DOMAIN/local.mccully.mlx-menu" >/dev/null 2>&1 || break
    sleep 0.25
  done
  if ! launchctl bootstrap "$DOMAIN" "$PLIST_PATH"; then
    # launchd can transiently retain the old label after bootout; one bounded retry is safe.
    launchctl bootout "$DOMAIN/local.mccully.mlx-menu" 2>/dev/null || true
    sleep 1
    launchctl bootstrap "$DOMAIN" "$PLIST_PATH"
  fi
fi

echo "Installed $DEST"
