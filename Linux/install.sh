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
install -m 644 "$here/workload_tasks.py" "$dest/workload_tasks.py"
# The app window (shared with Android and Windows).
install -m 644 "$here/../Client/musiplex.html" "$dest/musiplex.html"
# Workload (school tasks): its page and window launcher, when it's in this checkout.
if [[ -f "$here/../Workload/Web/workload.html" ]]; then
  mkdir -p "$HOME/.local/share/applications" "$HOME/.local/share/icons/hicolor/256x256/apps"
  install -m 644 "$here/../Workload/Web/workload.html" "$dest/workload.html"
  install -m 755 "$here/workload-open" "$dest/workload-open"
  install -m 644 "$here/../Workload/Windows/workload.png" "$HOME/.local/share/icons/hicolor/256x256/apps/workload.png"
  cat > "$HOME/.local/share/applications/workload.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Workload
Comment=School tasks and deadlines, synced through Musiplex
Exec=$dest/workload-open
Icon=workload
Terminal=false
Categories=Office;Education;
StartupWMClass=Workload
DESKTOP
fi
install -m 755 "$here/musiplex-open" "$dest/musiplex-open"

# App menu / taskbar launcher.
mkdir -p "$HOME/.local/share/applications" "$HOME/.local/share/icons/hicolor/256x256/apps"
install -m 644 "$here/musiplex.png" "$HOME/.local/share/icons/hicolor/256x256/apps/musiplex.png"
cat > "$HOME/.local/share/applications/musiplex.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Musiplex
Comment=Your music server: now playing, songs, Floaters, pairing
Exec=$dest/musiplex-open
Icon=musiplex
Terminal=false
Categories=AudioVideo;Audio;Player;
StartupWMClass=Musiplex
Actions=restart;floaters;

[Desktop Action restart]
Name=Restart server
Exec=systemctl --user restart musiplex.service

[Desktop Action floaters]
Name=Open Floaters folder
Exec=xdg-open $HOME/Documents/Songs/Floaters
DESKTOP
update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true

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
systemctl --user enable musiplex.service
systemctl --user restart musiplex.service   # picks up a new version on re-install
sleep 3
systemctl --user --no-pager status musiplex.service | head -5 || true
# Pin it to the KDE Plasma taskbar (skipped quietly on other desktops).
qdbus=$(command -v qdbus6 || command -v qdbus || true)
if [ -n "$qdbus" ]; then
  "$qdbus" org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript '
    panels().forEach(function (p) { p.widgets().forEach(function (w) {
      if (w.type != "org.kde.plasma.icontasks" && w.type != "org.kde.plasma.taskmanager") return;
      w.currentConfigGroup = ["General"];
      var l = String(w.readConfig("launchers", ""));
      if (l.indexOf("musiplex.desktop") < 0) w.writeConfig("launchers", (l ? l + "," : "") + "applications:musiplex.desktop");
    }); });' >/dev/null 2>&1 && echo "Pinned Musiplex to the taskbar." || true
fi
echo
"$dest/venv/bin/python" "$dest/musiplex_server.py" --show-pin | sed 's/^/Pairing PIN: /'
echo
echo "To keep it running when you're logged out, run once:  sudo loginctl enable-linger $USER"
echo "Firewall (if ufw is on):  sudo ufw allow 7860:7861/tcp && sudo ufw allow 5353/udp"
