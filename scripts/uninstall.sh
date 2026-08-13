#!/bin/bash
set -euo pipefail
launchctl bootout "gui/$(id -u)/local.mccully.mlx-menu" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/local.mccully.mlx-menu.plist"
rm -rf "$HOME/Applications/MLX Menu.app"
echo "MLX Menu removed"
