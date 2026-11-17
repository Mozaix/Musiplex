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
   git clone https://github.com/Mozaix/Musiplex.git
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

## Listen from anywhere: Tailscale, from scratch

Tailscale makes a private network between your Mac and your phone that works from anywhere: school, the gym, mobile data. Musiplex then reaches your Mac the same way it does at home.

**Why it wasn't working before:** Tailscale on the Mac was set to *not* start at login, and it was switched off. When Tailscale on the Mac is off, the phone has nothing to connect to. Musiplex now watches for this and turns Tailscale back on by itself (**Settings → Turn Tailscale back on if it switches off**).

### Start fresh

Follow these in order.

**A. Remove the old setup** (optional, if you want a clean start)

1. On the Mac, quit Tailscale (menu bar icon → Quit) and drag **Tailscale** from Applications to the Bin.
2. On the iPhone, press and hold the Tailscale app → **Remove App**. Then open **Settings → General → VPN & Device Management → VPN**, and delete any Tailscale entry.
3. Optional: at <https://login.tailscale.com/admin/machines>, delete the old machines. Or simply make a new account below.

**B. Make the account and set up the Mac**

4. On the **Mac**, download Tailscale from <https://tailscale.com/download/mac> and open it.
5. Click **Log in**. In the browser, choose how to sign in (Google, Apple, GitHub or Microsoft); a new Tailscale account is created on the spot. Remember which one you picked.
6. If macOS asks to **allow the VPN configuration** or a **system extension**, click **Allow**. You may need to open System Settings → Privacy & Security and click Allow there.
7. Click the Tailscale icon in the menu bar and turn on **Launch at login** (in Settings / Preferences). Make sure it says **Connected**.
8. Open **Musiplex** on the Mac and go to **Settings** (in the sidebar). "Listen From Anywhere" should show a green dot and an address starting with **100.**

**C. Set up the iPhone (and iPad)**

9. Install **Tailscale** from the App Store and open it.
10. Tap **Log in** and sign in with the **same** Google / Apple / GitHub / Microsoft account as on the Mac.
11. When iOS asks to **Add VPN Configurations**, tap **Allow** and confirm with Face ID or your passcode.
12. Make sure the switch at the top says **Connected**. Your Mac should appear in the list of devices.

**D. Connect Musiplex once at home**

13. At home on Wi‑Fi, with Tailscale on, open Musiplex on the phone. If it asks, type the PIN from the Mac's Settings page.
14. On the phone, open the status button (top right) → **Away from home**. It should show **Found automatically: 100.x.y.z**. That's the Mac's Tailscale address, saved for when you're out.

**E. Test it away from home**

15. Turn **Wi‑Fi off** on the phone, so you're on mobile data, and check Tailscale still says Connected.
16. Open Safari and go to `http://100.x.y.z:7860/ping`, using your Mac's address. It should show **musiplex**.
17. Open Musiplex. It should connect within a few seconds.

**If step 16 fails, the problem is the Mac:**

- **The Mac is asleep.** Musiplex keeps it awake while it's open (Settings → Keep this Mac awake), but closing the lid of a MacBook still sleeps it. Either keep it plugged in and open, or run this once in Terminal (undo it later with `0` instead of `1`):

  ```bash
  sudo pmset -a disablesleep 1
  ```

- **Tailscale is off on the Mac.** Musiplex → Settings shows an orange dot. Click **Turn On Tailscale**.
- **The firewall is blocking Musiplex.** In **System Settings → Network → Firewall → Options**, set Musiplex to *Allow incoming connections*.

**If step 16 works but Musiplex doesn't connect:** type the address yourself under **Away from home** in the phone app, then tap **Connect**.

### Another option: ZeroTier

[ZeroTier](https://www.zerotier.com) is a free alternative that works the same way: install it on the Mac and the phone, and join both to the same network. Then type the Mac's ZeroTier address into **Away from home** on the phone. Musiplex doesn't need anything else.

---

## Playlist versions & Apple Music

- **Versions:** every playlist change gets a version number (1.1, 1.2, 1.3, …) with the date and the device it came from: this Mac, your iPhone, your iPad, or "Apple Music on your iPhone".
  - To see them, open **Settings** on the Mac, or the **History** tab on the iPhone and iPad.
  - Tap or click a version to see exactly which songs were added to or removed from which playlist.
- **Apple Music sync (iPhone):** turn it on in the phone app under **Settings → Apple Music**. It's on by default on iPhone and off on iPad.
  - Playlists you make or change in Apple Music on the phone appear in Musiplex.
  - Songs you add to a Musiplex playlist are added to the matching Apple Music playlist.
  - Apple doesn't let apps remove songs from Apple Music playlists. So removing a song in Apple Music removes it from Musiplex, but not the other way round.
  - Songs are matched by title and artist, so only songs that exist on both sides can be synced.

## Surprise & Guess (on-device recommendations)

Musiplex learns what you like from what you play, entirely on your own devices. There's no account, no cloud and no machine-learning model, just small counts:

- **Plays and skips per song.** A skip is leaving within 30 seconds and before 40% of the song.
- **When you listen:** hour of day and day of week.
- **What you play next:** which songs tend to follow which.

That's a few hundred bytes per song you've played. On a 929-song library with 20,000 plays of history, it uses under 3 MB of memory, and picking a song takes about 0.3 ms.

- **Surprise:** a playlist with no songs. Press play and it picks the next song as it goes, using:
  - songs you often play after the current one
  - the same genre or artist
  - what you like at this time of day
  - a little discovery
  - never something you heard in the last few hours
- **Guess:** a playlist made for right now (for example "Tuesday evening"), from the songs and genres you play at this hour on this kind of day. It refreshes every hour.
- **Your Taste** (Mac Settings): your genres, plus songs in your library you haven't played yet that fit them.
- **iPhone and iPad:** they swap listening history with the Mac each time they connect. Offline, Surprise and Guess run on the device itself, using your downloaded songs.
- **Genres:** read from the Music app and your files' tags. Songs with no tag borrow their artist's genre.
  - If your library has no genre tags at all, you can turn on **Find genres online** in Settings.
  - It looks up each artist once on Apple's public music search, and only artist names are sent. It's off by default.

## Playlists, queue, mini player and Floating

- **Order:** new playlists appear at the top.
  - On the Mac, drag a playlist in the sidebar onto another to move it there.
  - On the iPhone or iPad, tap **Rearrange** in the Playlists tab.
  - The order is saved on the Mac and used on every device.
- **Auto-push to Apple Music:** Mac **Settings → Apple Music**. When on, any change to one of your playlists is sent to the Music app a few seconds later.
- **Queue:**
  - On the Mac, click the song in the player bar.
  - On the phone, tap the song name (or the list button) on the Now Playing screen, then tap any song to jump to it.
- **Mini player (Mac):** the button next to the queue button in the player bar hides the big window and opens a small floating player. Its list button slides the queue out to the side, and the expand button brings the big window back.
- **Floating:** put music files in **Documents › Songs › Floaters**.
  - They appear in Musiplex within a few seconds, in the Floating list under Mac **Settings**. They aren't shown in the sidebar.
  - Use **Move to** to put a song into a playlist, and it leaves Floating.

## Connection: Bluetooth backup

Turn on **Settings → Connection → Bluetooth backup link** to keep a Bluetooth link to the Mac open alongside Wi‑Fi. Play, pause and skip go over both links, and the Mac runs each command only once. If Wi‑Fi drops, control switches to Bluetooth straight away.

It's **off by default**. Keeping Bluetooth and peer-to-peer Wi‑Fi busy makes Wi‑Fi briefly hop away from your router, which can cause the odd stutter while streaming. When the phone is connected over Wi‑Fi and the backup is off, Musiplex switches Bluetooth scanning off on both devices.

You can't merge Bluetooth and Wi‑Fi into one faster connection: Bluetooth adds only about 2 Mbit/s next to Wi‑Fi's hundreds. So Bluetooth is used for reliability, not speed.

## Speed notes

- **Downloads:**
  - While the app is open, songs download 6 at a time at full Wi‑Fi speed. The banner shows the current speed.
  - If you leave the app, downloads carry on in the background but slower. iOS throttles background transfers, so leave Musiplex open for a big sync.
- **Controls:** play, pause and skip are sent immediately. When the phone is the speaker, it pauses on its own without waiting for the Mac.
- **Bluetooth headphones:** headphones on the Mac add about 0.2–0.3 s of delay of their own.

## Notch

- **Layout:** tabs sit either side of the camera, with the battery on the right.
- **Power:** click the battery to see watts coming into the Mac, watts the Mac is using, power flowing into or out of the battery, and each USB‑C port's power contract.
- **Paused:** the notch shrinks back to normal size. Hover over it to open it.

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
