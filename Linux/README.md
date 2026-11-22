# Your own Musiplex server on Linux

Most people don't need this: Musiplex on a Mac or Windows PC is already the server, and Workload
on that computer keeps its tasks there. A **dedicated Linux server** (an always-on laptop or mini PC)
is for when you want your music and your Workload tasks on a machine that's always on, with your
Mac, PC and phones all syncing to it.

What it does once it's set up:
- serves your music to your phones (and passes them through to your Mac when the Mac is on),
- keeps the **Workload** task list for every device (the "hub"), and
- checks your **Toddle** deadlines every 15 minutes.

Commands below go in the Linux computer's terminal (Konsole, GNOME Terminal…), **one line at a
time**: type or paste a line, press Enter, wait for it to finish. (In the fish shell, paste only the
command, without anything in front of it.)

---

## 1. Get the files

Either download `Musiplex-<version>-Linux.tar.gz` from the
[latest release](https://github.com/Mozaix/Musiplex/releases/latest) and unpack it:

```bash
tar xzf ~/Downloads/Musiplex-*-Linux.tar.gz -C ~
```

```bash
mv ~/Musiplex-*-Linux ~/Musiplex
```

or, to update with `git pull` later, clone it (needs `git`):

```bash
git clone https://github.com/Mozaix/Musiplex.git ~/Musiplex
```

## 2. Install

```bash
cd ~/Musiplex
```

```bash
./Linux/install.sh
```

This needs no admin password. It installs a private Python environment (aiohttp, mutagen,
zeroconf) in `~/.local/share/musiplex`, a `systemd --user` service that starts at login, and two
apps in your menu and taskbar: **Musiplex** (the player window) and **Workload** (tasks). At the end
it prints the **pairing PIN**.

If `install.sh` says "Permission denied", make it runnable first: `chmod +x Linux/install.sh`.

## 3. Permissions (once)

Keep it running when nobody is logged in (asks for your password):

```bash
sudo loginctl enable-linger $USER
```

If a firewall is on, let your devices in. With `ufw`:

```bash
sudo ufw allow 7860:7861/tcp
```

```bash
sudo ufw allow 5353/udp
```

With `firewalld` (Fedora, CachyOS with firewalld):

```bash
sudo firewall-cmd --permanent --add-port=7860-7861/tcp --add-service=mdns
```

```bash
sudo firewall-cmd --reload
```

Ports: 7860 (music, artwork, tasks), 7861 (live control), 5353/udp (so devices find it on the Wi‑Fi).

## 4. Connect your devices

- **Mac:** Musiplex → **Settings → Linked Server** → this computer's address and PIN → **Link**.
  Workload on that Mac then syncs with the Linux server by itself (no PIN), and the notch's
  Calendar tab shows the server's tasks.
- **Windows PC:** Workload pairs with the Linux server's PIN once (its Sync page lists the server).
- **iPhone, iPad, Android:** Musiplex and Workload find the server on the same Wi‑Fi and ask for the
  PIN once.
- **Forgot the PIN?** Open **Musiplex** on the Linux computer → **Settings**, or run
  `~/.local/share/musiplex/venv/bin/python ~/.local/share/musiplex/musiplex_server.py --show-pin`.

## 5. Toddle

Paste your Toddle calendar link (Toddle on the web → **Calendar → Subscribe → Others**) in either
place; it's saved on the Linux server and checked every 15 minutes:
- on the Linux computer: **Musiplex → Settings → Workload**, or
- on a Mac linked to it: **Musiplex → Settings → Workload**.

New deadlines are added, changed ones updated, and ones removed from Toddle are removed (shown in
Workload's **Removed** page, where you can reinstate them).

## 6. Away from home (Tailscale)

Install Tailscale on the server and on your devices, and sign in with the same account. On the
server:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
```

```bash
sudo tailscale up
```

Let your own user (and Claude Code, below) start and stop it without `sudo`:

```bash
sudo tailscale set --operator=$USER
```

Phones learn the server's Tailscale address the first time they connect at home. Don't set an
**exit node** unless you want all your internet traffic to go through another device; to clear
one: `tailscale set --exit-node=`.

## 7. Updating

```bash
cd ~/Musiplex
```

```bash
git pull
```

```bash
./Linux/install.sh
```

(With the downloaded archive instead of git, unpack the new one over `~/Musiplex` and run the last
line.) Your music, PIN, tasks and Toddle link are kept.

## 8. Letting Claude Code run these for you (optional)

Claude Code asks before running commands. To allow just the ones for this server, add them to
`~/.claude/settings.json` on the Linux computer. This command adds them and keeps anything already
in the file:

```bash
python3 -c 'import json,os;p=os.path.expanduser("~/.claude/settings.json");t=open(p).read().strip() if os.path.exists(p) else "";d=json.loads(t) if t else {};a=d.setdefault("permissions",{}).setdefault("allow",[]);[a.append(r) for r in ["Bash(git pull)","Bash(./Linux/install.sh)","Bash(systemctl --user:*)","Bash(tailscale:*)","Bash(journalctl --user:*)"] if r not in a];json.dump(d,open(p,"w"),indent=2);print(open(p).read())'
```

Then restart Claude Code. `settings.json` is a settings file you edit, not a command to run.

## Handy

- **Status:** `systemctl --user status musiplex`
- **Restart:** `systemctl --user restart musiplex` (or right-click the Musiplex taskbar icon)
- **Logs:** `journalctl --user -u musiplex -f`
- **Where things are:** settings, PIN, tasks and the Toddle link in `~/.config/musiplex/`; the app in
  `~/.local/share/musiplex/`.

## How it fits with the Mac (the chain)

Once a Mac is linked, it checks in every few seconds. While it's on, phones that connect to the
Linux server are passed straight through to the Mac: same queue, same speaker, same songs. The
Musiplex window on Linux shows and controls the Mac's song. When the Mac is off or asleep, the Linux
server runs its own session and the same phones still get in (no re-pairing). Workload's tasks
always live on the Linux server.
