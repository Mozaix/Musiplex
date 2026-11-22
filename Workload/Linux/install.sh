#!/usr/bin/env bash
# Sets up the hourly Toddle → Musiplex sync on this Linux computer (CachyOS etc.).
# Usage: ./install.sh            (asks for your Toddle iCal link)
#        ./install.sh <ical-url>
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
dest="$HOME/.local/share/workload"
conf="$HOME/.config/workload"
units="$HOME/.config/systemd/user"
mkdir -p "$dest" "$conf" "$units"

install -m 755 "$here/toddle_sync.py" "$dest/toddle_sync.py"

# The task store add-on for Musiplex, next to the Musiplex server if it's installed.
# (In the Musiplex repo, Linux/install.sh already installs it; this covers the Workload repo.)
src="$here/../Server/workload_tasks.py"; [[ -f "$src" ]] || src="$here/../../Linux/workload_tasks.py"
if [[ -d "$HOME/.local/share/musiplex" && -f "$src" ]]; then
  install -m 644 "$src" "$HOME/.local/share/musiplex/workload_tasks.py"
  echo "Copied workload_tasks.py into ~/.local/share/musiplex"
fi

if [[ ! -f "$conf/toddle.json" ]]; then
  url="${1:-}"
  if [[ -z "$url" ]]; then
    echo
    echo "In Toddle (web): Calendar → Subscribe → Others → copy the iCal link for your deadlines."
    read -r -p "Paste the iCal link: " url
  fi
  python3 - "$url" "$conf/toddle.json" <<'PY'
import json, sys
url, path = sys.argv[1].strip(), sys.argv[2]
json.dump({"ics_urls": [url] if url else [], "server": "http://127.0.0.1:7860",
           "days_ahead": 60, "only_keywords": [], "skip_keywords": []}, open(path, "w"), indent=2)
PY
  chmod 600 "$conf/toddle.json"
fi

cat > "$units/workload-toddle.service" <<UNIT
[Unit]
Description=Workload: send Toddle deadlines to Musiplex
After=network-online.target musiplex.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/env python3 $dest/toddle_sync.py
UNIT

cat > "$units/workload-toddle.timer" <<UNIT
[Unit]
Description=Workload: check Toddle every hour

[Timer]
OnBootSec=2min
OnUnitActiveSec=1h
Persistent=true

[Install]
WantedBy=timers.target
UNIT

systemctl --user daemon-reload
systemctl --user enable --now workload-toddle.timer
systemctl --user start workload-toddle.service || true

echo
echo "Done. Toddle is checked every hour."
echo "  Run it now:   systemctl --user start workload-toddle.service"
echo "  See the log:  journalctl --user -u workload-toddle.service -n 20"
echo "  Preview:      python3 $dest/toddle_sync.py --dry-run"
echo "  Settings:     $conf/toddle.json"
