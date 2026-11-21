# Musiplex server for Linux

A headless Musiplex server: your iPhone/iPad connects to it exactly like it connects to the Mac app (home Wi‑Fi or Tailscale). It serves the music in `~/Music` and `~/Documents/Songs`, keeps the shared playback session (one of your devices is the speaker), and offers its Floaters to your Mac.

```bash
git clone https://github.com/Mozaix/Musiplex.git
```

```bash
cd Musiplex/Linux && ./install.sh
```

The script installs a private Python environment (aiohttp, mutagen, zeroconf) and a `systemd --user` service that starts on boot. Then, once:

```bash
sudo loginctl enable-linger $USER
```

(This keeps it running while you're logged out.) If a firewall is on, also open ports 7860–7861/tcp and 5353/udp.

- **PIN:** run `~/.local/share/musiplex/venv/bin/python ~/.local/share/musiplex/musiplex_server.py --show-pin`.
- **Logs:** `journalctl --user -u musiplex -f`.
- **On the Mac:** go to **Settings → Linked Server**, enter this machine's address and the PIN, and new Floaters copy over every minute.

## The Musiplex window

`install.sh` also adds **Musiplex** to your app menu and pins it to the KDE Plasma taskbar
(on other desktops, right-click it in the app menu and pin it yourself). It opens a small window
(Chromium/Brave/Chrome app mode, or your default browser) with:

- now playing, with play/pause, next, previous and Surprise (the sound plays on your phone),
- the address and PIN for pairing, and which devices are connected,
- your Floaters, and a searchable song list (click a song to play it).

Right-click the taskbar icon for **Restart server** or **Open Floaters folder**. The window only
works from the laptop itself: other computers on the network can't open it.
