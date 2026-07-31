#!/usr/bin/env bash
#
# canon-g3020-ubuntu — uninstaller. Removes the drivers, the print queue,
# and the ink helper. Does NOT re-enable cups-browsed automatically.
#
set -euo pipefail

QUEUE_NAME="Canon_G3020"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m  ✓ %s\033[0m\n' "$*"; }

[ "$(id -u)" -ne 0 ] || { echo "Run as your normal user, not root." >&2; exit 1; }

log "Removing print queue '$QUEUE_NAME' (if present)"
sudo lpadmin -x "$QUEUE_NAME" 2>/dev/null && ok "Queue removed" || echo "  (no queue)"

log "Removing driver packages"
sudo apt-get remove -y cnijfilter2 scangearmp2 2>/dev/null || true
ok "Packages removed"

log "Removing ink helper"
sudo rm -f /usr/local/bin/canon-ink
ok "Removed /usr/local/bin/canon-ink"

cat <<EOF

Uninstalled.
  • Scanning via sane-airscan (eSCL/WSD) is a system feature and was left in place.
  • If you disabled cups-browsed during install and want it back:
        sudo systemctl enable --now cups-browsed
EOF
