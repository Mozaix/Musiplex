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

## Chain: one session across the Mac, the laptop and your phone

Once the Mac is linked (Settings → Linked Server), it checks in with the laptop every few seconds.
While it does, any phone that connects to the laptop is passed straight through to the Mac: same
queue, same speaker choice, same songs, as if it had connected to the Mac directly. The laptop
window shows and controls the Mac's song. When the Mac is off or asleep, the laptop runs its own
session again and the same phones still get in (no re-pairing).
