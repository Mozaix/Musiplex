# Musiplex

Turn a Mac into a music server, and play from it on your iPhone, iPad and Apple Watch.

- **Mac app**: a library built from Apple Music and imported folders, with playlists, duplicate hiding, crossfade, a notch overlay (music, file box, clipboard, notes, currency, AirDrop) and a menu bar player.
- **iPhone / iPad app**:
  - Browse the Mac's library and stream it.
  - Download songs (the **Sync** button downloads every song you don't have yet, one copy each).
  - Control what's playing on any device.
  - Dynamic Island and Live Activity.
  - Bluetooth fallback.
- **Apple Watch app**: now playing, controls, the device picker and Digital Crown volume. It talks to the Watch through the iPhone.

Devices find the Mac over home Wi‑Fi automatically, over Bluetooth when there's no Wi‑Fi, and through [Tailscale](https://tailscale.com) when you're away from home.

---

## Run the server on another Mac

You need Xcode (free from the Mac App Store) and a free Apple ID.

1. Clone the repository.

   ```bash
   git clone https://github.com/<you>/Musiplex.git
   ```

   ```bash
   open Musiplex/Musiplex.xcodeproj
   ```

2. In Xcode, click the **Musiplex** project.
3. For each target (Musiplex, MusiplexRemote, MusiplexLive, MusiplexWatch), open **Signing & Capabilities** and pick your own **Team**. If Xcode complains that a bundle ID is taken, change `com.musiplex` to something of your own, for example `com.yourname.musiplex`, and do the same for all four targets.
4. Choose the **Musiplex** scheme and **My Mac**, then press **⌘R**. Musiplex asks to read your music library. Allow it, or use **Import Folder** to add music files.
5. For a copy that runs without Xcode, use **Product → Archive → Distribute App → Copy App**, then drag the copy into Applications.
6. To install on iPhone, iPad and Watch:
   1. Plug in the iPhone.
   2. Choose the **MusiplexRemote** scheme and the iPhone, then press **⌘R**. The Watch app installs through the iPhone.
   3. With a free Apple ID, apps stop opening after 7 days. Press ⌘R again to renew them.

The phone pairs with one Mac at a time. The first time it connects to a new Mac, it asks for that Mac's 6‑digit PIN, shown in the bottom‑left corner of Musiplex.

### Keep the server awake (Ethernet, lid closed)

- **System Settings → Battery → Options**: turn on **Prevent automatic sleeping on power adapter when the display is off**.
- To keep it running with the lid **closed** and no external display, run this in Terminal (undo it later with `0` instead of `1`):

  ```bash
  sudo pmset -a disablesleep 1
  ```

- Plain `caffeinate` only works while that Terminal window keeps running, and it doesn't stop sleep when you close the lid.
- **System Settings → General → Login Items**: add Musiplex so it starts after a restart.
- Ethernet is the best connection for the server. Downloads are limited by the slowest link, which is usually the phone's Wi‑Fi.

---

## Tailscale: listen from anywhere

Tailscale puts your Mac and phone on a private network that works anywhere. Musiplex sees it as just another network.

1. **On the server Mac**, install Tailscale from <https://tailscale.com/download/mac> and sign in.
2. **On the iPhone**, install Tailscale from the App Store and sign in with the **same account**.
3. Check that both appear in the Tailscale app as connected. The Mac's address starts with `100.`.
4. **Connect once at home over Wi‑Fi** with Tailscale on. The Mac sends the phone its Tailscale address automatically. You'll see it under **Settings → Away from home → Found automatically** in the phone app.
5. Away from home, turn on Tailscale on the phone and open Musiplex. It tries every address it knows at once and uses the first that answers.

**If it still says Offline away from home:**

- **The Mac is asleep.** This is the usual cause. See "Keep the server awake" above. If the Mac app shows its Tailscale address in the sidebar, Tailscale is fine on that side.
- **Tailscale is off on the phone.** Turn the VPN toggle on in the Tailscale app. iOS sometimes turns it off.
- **Test the connection.** On the phone, with Tailscale on, open Safari and go to `http://100.x.y.z:7860/ping`, using your Mac's Tailscale IP. It should say `musiplex`. If it doesn't load, the problem is Tailscale or the Mac, not Musiplex.
- **The macOS firewall is blocking Musiplex.** In **System Settings → Network → Firewall → Options**, make sure Musiplex is set to **Allow incoming connections**.
- **Type the address yourself.** If needed, enter the address under **Settings → Away from home** on the phone, either `100.x.y.z` or the MagicDNS name like `my-mac.tailnet-name.ts.net`.

---

## Speed notes

- **Downloads:**
  - While the app is open, songs download 6 at a time at full Wi‑Fi speed. The banner shows the current speed.
  - If you leave the app, downloads carry on in the background but slower. iOS throttles background transfers, so leave Musiplex open for a big sync.
- **Controls:** play, pause and skip are sent immediately. When the phone is the speaker, it pauses on its own without waiting for the Mac.
- **Bluetooth headphones:** headphones on the Mac add about 0.2–0.3 s of delay of their own.

## Project layout

| Folder | What's in it |
| --- | --- |
| `Mac/` | Mac app: library, HTTP + WebSocket server, notch, menu bar |
| `Phone/` | iPhone / iPad app: connection, downloads, UI |
| `Watch/` | Apple Watch app |
| `Live/`, `LiveShared/` | Dynamic Island / Live Activity widget |
| `Shared/` | Models, playback engine (crossfade), shared UI |
| `Config/` | Info.plist files |

The server uses port 7860 for HTTP (catalog, artwork and audio, with Range support) and port 7861 for WebSocket control, and advertises itself over Bonjour as `_musiplex._tcp`.
