#!/bin/sh
# No installs or discovery side effects. Choose an already-installed Python explicitly.
set -eu
package_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export PYTHONDONTWRITEBYTECODE=1
exec "${TAKEOFF_PYTHON:-python3}" "$package_root/skills/plan-area-takeoff/scripts/cad.py" "$@"
