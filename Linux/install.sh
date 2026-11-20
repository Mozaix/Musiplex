#!/usr/bin/env bash
# Installs the Musiplex server for this user and keeps it running in the background.
# No sudo needed for this part. Run from the Linux/ folder of the Musiplex repo.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
dest="$HOME/.local/share/musiplex"
mkdir -p "$dest" "$HOME/.config/systemd/user" "$HOME/Documents/Songs/Floaters"

python3 -m venv "$dest/venv"
"$dest/venv/bin/pip" install --quiet --upgrade pip
"$dest/venv/bin/pip" install --quiet aiohttp mutagen zeroconf
install -m 755 "$here/musiplex_server.py" "$dest/musiplex_server.py"

cat > "$HOME/.config/systemd/user/musiplex.service" <<UNIT
[Unit]
Description=Musiplex music server
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$dest/venv/bin/python $dest/musiplex_server.py
Restart=always
RestartSec=5
Nice=5
# Keep it light.
MemoryHigh=150M
MemoryMax=250M

[Install]
WantedBy=default.target
UNIT

systemctl --user daemon-reload
systemctl --user enable --now musiplex.service
sleep 3
systemctl --user --no-pager status musiplex.service | head -5 || true
echo
"$dest/venv/bin/python" "$dest/musiplex_server.py" --show-pin | sed 's/^/Pairing PIN: /'
echo
echo "To keep it running when you're logged out, run once:  sudo loginctl enable-linger $USER"
echo "Firewall (if ufw is on):  sudo ufw allow 7860:7861/tcp && sudo ufw allow 5353/udp"
