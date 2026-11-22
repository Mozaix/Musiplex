#!/usr/bin/env python3
"""Musiplex server for Linux and Windows (headless).

Speaks the same protocol as the Mac app, so the iPhone/iPad app connects to it
exactly like it connects to a Mac: found on the home network automatically
(Bonjour), or by its Tailscale address from anywhere.

- Library: ~/Music and ~/Documents/Songs (including Songs/Floaters), rescanned
  every few minutes; tags and artwork read with mutagen.
- Desktop window: http://127.0.0.1:7860/ (this computer only), opened by the
  Musiplex launcher in the app menu / taskbar.
- HTTP (port 7860): /ping, /catalog, /art/<id>, /file/<id>.<ext> (with Range),
  plus /pair, /floaters and /floater for other Musiplex servers (the Mac pulls
  new Floaters from here).
- WebSocket (port 7861): pairing (PIN), the shared playback session, playlist
  edits. This server has no speakers of its own: one of your devices is the
  speaker and the others mirror it, muted.

Memory: a few MB of metadata on top of Python itself (roughly 40-60 MB total).
"""

from __future__ import annotations

import argparse
import asyncio
import hashlib
import json
import os
import random
import secrets
import socket
import subprocess
import time
import unicodedata
import uuid
from pathlib import Path

from aiohttp import ClientError, ClientSession, ClientTimeout, WSMsgType, web

try:
    import mutagen
except ImportError:  # pragma: no cover - checked at startup
    mutagen = None

try:
    from zeroconf import IPVersion, ServiceInfo
    from zeroconf.asyncio import AsyncZeroconf
except ImportError:  # Bonjour is optional (Tailscale / typed address still work)
    AsyncZeroconf = None

AUDIO = {".mp3", ".m4a", ".mp4", ".aac", ".wav", ".aif", ".aiff", ".flac", ".ogg", ".opus", ".caf"}
WINDOWS = os.name == "nt"
CONFIG = (Path(os.environ.get("APPDATA", Path.home())) / "Musiplex" if WINDOWS
          else Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "musiplex")
HOME = Path.home()
FLOATERS = Path(os.environ.get("MUSIPLEX_FLOATERS", HOME / "Documents" / "Songs" / "Floaters"))


def song_key(title: str, artist: str) -> str:
    """Same song on two machines (the Mac's songKey): case, accents and punctuation ignored."""
    def norm(s):
        return "".join(ch for ch in unicodedata.normalize("NFKD", (s or "").casefold()) if ch.isalnum())
    return f"{norm(title)}|{norm(artist)}"


def track_id(path: str) -> str:
    """Same as the Mac: first 8 bytes of SHA-256 of the NFC path, as hex."""
    normal = unicodedata.normalize("NFC", path)
    return hashlib.sha256(normal.encode()).hexdigest()[:16]


def now() -> float:
    return time.time()


# Dates in the catalog use Apple's reference date (2001-01-01), like Swift's default encoder.
APPLE_EPOCH = 978307200.0


# --------------------------------------------------------------------------- library

class Library:
    def __init__(self, roots: list[Path]):
        self.roots = roots
        self.art_dir = CONFIG / "art"
        self.art_dir.mkdir(parents=True, exist_ok=True)
        self.cache_file = CONFIG / "library.json"
        self.playlists_file = CONFIG / "playlists.json"
        self.history_file = CONFIG / "history.json"
        self.entries: dict[str, dict] = {}       # path -> {"mtime", "track"}
        self.paths: dict[str, str] = {}          # id -> path
        self.tracks: list[dict] = []
        self.playlists: list[dict] = self._load(self.playlists_file, [])
        self.history: list[dict] = self._load(self.history_file, [])
        cached = self._load(self.cache_file, {})
        if isinstance(cached, dict):
            self.entries = cached
        self._install()

    @staticmethod
    def _load(path: Path, default):
        try:
            return json.loads(path.read_text())
        except Exception:
            return default

    @staticmethod
    def _save(path: Path, value):
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps(value))
        tmp.replace(path)

    # ---- scanning

    def scan(self) -> bool:
        """Walks the music folders; reads tags only for new/changed files. Returns True if anything changed."""
        seen: dict[str, dict] = {}
        changed = False
        for root in self.roots:
            if not root.exists():
                continue
            for dirpath, dirnames, filenames in os.walk(root):
                dirnames[:] = [d for d in dirnames if not d.startswith(".")]
                for name in filenames:
                    if name.startswith(".") or Path(name).suffix.lower() not in AUDIO:
                        continue
                    path = os.path.join(dirpath, name)
                    try:
                        st = os.stat(path)
                    except OSError:
                        continue
                    old = self.entries.get(path)
                    if old and old.get("mtime") == st.st_mtime:
                        seen[path] = old
                        continue
                    track = self._read(path, st)
                    if track:
                        seen[path] = {"mtime": st.st_mtime, "track": track}
                        changed = True
        if set(seen) != set(self.entries):
            changed = True
        self.entries = seen
        if changed:
            self._save(self.cache_file, self.entries)
            self._install()
        return changed

    def _read(self, path: str, st) -> dict | None:
        tid = track_id(path)
        p = Path(path)
        title = artist = album = genre = None
        duration = 0.0
        if mutagen is not None:
            try:
                easy = mutagen.File(path, easy=True)
                if easy is not None:
                    duration = float(getattr(easy.info, "length", 0) or 0)
                    tags = easy.tags or {}
                    first = lambda k: (tags.get(k) or [None])[0]
                    title, artist, album, genre = first("title"), first("artist"), first("album"), first("genre")
                self._write_art(path, tid)
            except Exception:
                pass
        # Fall back to Artist/Album/Song folders and the file name.
        parts = p.parts
        if not artist and len(parts) >= 3:
            artist = parts[-3]
        if not album and len(parts) >= 2:
            album = parts[-2]
        if not title:
            import re
            title = re.sub(r"^(\d+-)?\d{1,3}[\s._-]+(?=\S)", "", p.stem)
        return {
            "id": tid, "title": title.strip() or p.stem, "artist": (artist or "Unknown Artist").strip(),
            "album": (album or "Unknown Album").strip(), "duration": duration,
            "ext": p.suffix.lower().lstrip("."), "size": st.st_size,
            "addedAt": getattr(st, "st_birthtime", st.st_mtime),   # seconds since 1970, like the Mac
            **({"genre": genre.strip()} if genre and genre.strip() else {}),
        }

    def _write_art(self, path: str, tid: str):
        target = self.art_dir / f"{tid}.jpg"
        if target.exists():
            return
        try:
            f = mutagen.File(path)
            data = None
            if f is None:
                return
            pictures = getattr(f, "pictures", None)          # FLAC
            if pictures:
                data = pictures[0].data
            tags = getattr(f, "tags", None)
            if data is None and tags is not None:
                for key in list(tags.keys()):
                    if key.startswith("APIC"):              # MP3
                        data = tags[key].data
                        break
                    if key == "covr" and tags[key]:          # M4A
                        data = bytes(tags[key][0])
                        break
            if data:
                target.write_bytes(data)
        except Exception:
            pass

    def _install(self):
        tracks = []
        self.paths = {}
        for path, entry in self.entries.items():
            t = entry["track"]
            self.paths[t["id"]] = path
            tracks.append(t)
        tracks.sort(key=lambda t: t["title"].lower())
        self.tracks = tracks
        self.by_id = {t["id"]: t for t in tracks}

    # ---- catalog

    def catalog(self, extra_playlists: list[dict]) -> dict:
        groups: dict[str, list[dict]] = {}
        for t in self.tracks:
            key = f"?|{t['artist']}" if t["album"] == "Unknown Album" else t["album"].lower()
            groups.setdefault(key, []).append(t)
        albums = []
        for key, items in groups.items():
            items.sort(key=lambda t: self.paths.get(t["id"], ""))
            artists = {t["artist"] for t in items}
            albums.append({"id": key, "name": items[0]["album"],
                           "subtitle": items[0]["artist"] if len(artists) == 1 else "Various Artists",
                           "trackIDs": [t["id"] for t in items]})
        albums.sort(key=lambda a: a["name"].lower())
        lists = extra_playlists + [
            {"id": p["id"], "name": p["name"], "subtitle": "mine", "trackIDs": [i for i in p["trackIDs"] if i in self.by_id]}
            for p in self.playlists
        ]
        return {"tracks": self.tracks, "albums": albums, "playlists": lists, "history": self.history[:100]}

    # ---- playlists (with version history, like the Mac)

    def _label(self, tid):
        t = self.by_id.get(tid)
        return f"{t['title']} — {t['artist']}" if t else "Unknown song"

    def _record(self, changes: list[dict], source: str):
        if not changes:
            return
        number = (self.history[0]["number"] if self.history else 0) + 1
        self.history.insert(0, {"number": number, "date": now() - APPLE_EPOCH, "source": source, "changes": changes})
        del self.history[500:]
        self._save(self.history_file, self.history)

    def _find(self, pid):
        return next((p for p in self.playlists if p["id"] == pid), None)

    def edit_playlist(self, pid, name, add, remove, source):
        p = self._find(pid) if pid else None
        changes = []
        if p is None:
            p = {"id": pid if pid and pid.startswith("my-") else f"my-{uuid.uuid4()}".upper().replace("MY-", "my-"),
                 "name": (name or "New Playlist").strip() or "New Playlist", "trackIDs": []}
            self.playlists.insert(0, p)
            changes.append({"playlist": p["name"], "kind": "created", "songs": [], "playlistID": p["id"]})
        elif name and name.strip() and name.strip() != p["name"]:
            changes.append({"playlist": name.strip(), "kind": "renamed", "songs": [], "detail": p["name"], "playlistID": p["id"]})
            p["name"] = name.strip()
        added = [i for i in (add or []) if i not in p["trackIDs"]]
        p["trackIDs"] += added
        if added:
            changes.append({"playlist": p["name"], "kind": "added", "songs": [self._label(i) for i in added],
                            "playlistID": p["id"], "ids": added})
        gone = [i for i in (remove or []) if i in p["trackIDs"]]
        p["trackIDs"] = [i for i in p["trackIDs"] if i not in gone]
        if gone:
            changes.append({"playlist": p["name"], "kind": "removed", "songs": [self._label(i) for i in gone],
                            "playlistID": p["id"], "ids": gone})
        self._save(self.playlists_file, self.playlists)
        self._record(changes, source)

    def delete_playlist(self, pid, source):
        p = self._find(pid)
        if not p:
            return
        self.playlists.remove(p)
        self._save(self.playlists_file, self.playlists)
        self._record([{"playlist": p["name"], "kind": "deleted", "songs": [self._label(i) for i in p["trackIDs"]],
                       "playlistID": pid, "ids": p["trackIDs"]}], source)

    def reorder(self, ids):
        rank = {i: n for n, i in enumerate(ids)}
        self.playlists.sort(key=lambda p: rank.get(p["id"], 10**6))
        self._save(self.playlists_file, self.playlists)

    def revert(self, number, source):
        v = next((h for h in self.history if h["number"] == number), None)
        if not v:
            return
        for c in reversed(v["changes"]):
            pid = c.get("playlistID")
            if c["kind"] == "added" and pid:
                self.edit_playlist(pid, None, [], c.get("ids", []), f"{source} · undo 1.{number}")
            elif c["kind"] == "removed" and pid:
                self.edit_playlist(pid, None, c.get("ids", []), [], f"{source} · undo 1.{number}")
            elif c["kind"] == "renamed" and pid and c.get("detail"):
                self.edit_playlist(pid, c["detail"], [], [], f"{source} · undo 1.{number}")
            elif c["kind"] == "created" and pid:
                self.delete_playlist(pid, f"{source} · undo 1.{number}")
            elif c["kind"] == "deleted":
                self.edit_playlist(pid, c["playlist"], c.get("ids", []), [], f"{source} · undo 1.{number}")


# --------------------------------------------------------------------------- session

class Session:
    """The shared playback session. Authoritative here; devices follow it.
    Time is kept by the clock (this server has no audio output)."""

    def __init__(self, library: Library, on_change):
        self.lib = library
        self.on_change = on_change
        self.state = {"queue": [], "index": 0, "isPlaying": False, "position": 0.0, "activeDevice": "",
                      "volume": 0.8, "shuffle": False, "repeatMode": "off", "crossfade": 0.0, "fade": 0.0}
        self.anchor_pos = 0.0
        self.anchor_at = now()
        self.unshuffled = None
        self.timer: asyncio.TimerHandle | None = None
        self.recent: list[str] = []

    def position(self) -> float:
        return self.anchor_pos + (now() - self.anchor_at if self.state["isPlaying"] else 0)

    def current(self):
        q, i = self.state["queue"], self.state["index"]
        return q[i] if 0 <= i < len(q) else None

    def snapshot(self) -> dict:
        s = dict(self.state)
        s["position"] = self.position()
        return s

    def _seek(self, pos):
        self.anchor_pos = max(0.0, pos)
        self.anchor_at = now()

    def perform(self, c: dict):
        s = self.state
        action = c.get("action")
        pos = self.position()
        self._seek(pos)
        s["fade"] = 0.0
        seek = None
        if action == "play":
            ids = c.get("ids") or []
            if not ids:
                return
            i = min(max(c.get("index") or 0, 0), len(ids) - 1)
            queue = list(ids)
            if s["shuffle"]:
                self.unshuffled = list(ids)
                cur = queue.pop(i)
                random.shuffle(queue)
                queue.insert(0, cur)
                i = 0
            else:
                self.unshuffled = None
            s["queue"], s["index"], s["isPlaying"] = queue, i, True
            s["radio"] = "surprise" if c.get("text") == "surprise" else None
            seek = 0
        elif action == "jump":
            i = c.get("index")
            if i is None or not (0 <= i < len(s["queue"])):
                return
            s["index"], s["isPlaying"], seek = i, True, 0
        elif action == "toggle":
            if self.current() is None:
                return
            s["isPlaying"] = not s["isPlaying"]
        elif action == "pause":
            s["isPlaying"] = False
        elif action == "resume":
            if self.current() is None:
                return
            s["isPlaying"] = True
        elif action in ("next", "auto"):
            self._advance(auto=action == "auto")
            if action == "auto":
                s["fade"] = s["crossfade"]
            seek = 0
        elif action == "prev":
            if pos < 3 and s["index"] > 0:
                s["index"] -= 1
            seek = 0
        elif action == "seek":
            seek = max(0.0, c.get("value") or 0)
        elif action == "volume":
            s["volume"] = min(max(c.get("value", s["volume"]), 0), 1)
        elif action == "crossfade":
            s["crossfade"] = min(max(c.get("value") or 0, 0), 12)
        elif action == "device":
            if c.get("text"):
                s["activeDevice"] = c["text"]
        elif action == "shuffle":
            s["shuffle"] = not s["shuffle"]
            cur = self.current()
            if s["shuffle"]:
                self.unshuffled = list(s["queue"])
                if cur:
                    rest = s["queue"][:s["index"]] + s["queue"][s["index"] + 1:]
                    random.shuffle(rest)
                    s["queue"], s["index"] = [cur] + rest, 0
            elif self.unshuffled and cur in self.unshuffled:
                s["queue"], s["index"] = self.unshuffled, self.unshuffled.index(cur)
                self.unshuffled = None
        elif action == "repeat":
            s["repeatMode"] = {"off": "all", "all": "one", "one": "off"}[s["repeatMode"]]
        elif action in ("playNext", "enqueue"):
            ids = c.get("ids") or []
            if not ids:
                return
            if not s["queue"]:
                s["queue"], s["index"], s["isPlaying"], seek = list(ids), 0, True, 0
            elif action == "playNext":
                s["queue"][s["index"] + 1:s["index"] + 1] = ids
            else:
                s["queue"] += ids
        elif action == "surprise":
            first = self.pick()
            if first:
                return self.perform({"action": "play", "ids": [first], "index": 0, "text": "surprise"})
            return
        else:
            return
        if seek is not None:
            self._seek(seek)
        self._keep_surprise_going()
        self._schedule()
        self.on_change()

    def _advance(self, auto):
        s = self.state
        if not s["queue"]:
            return
        if auto and s["repeatMode"] == "one":
            return
        cur = self.current()
        if cur:
            self.recent = (self.recent + [cur])[-60:]
        if s["index"] + 1 < len(s["queue"]):
            s["index"] += 1
        else:
            s["index"] = 0
            if auto and s["repeatMode"] == "off":
                s["isPlaying"] = False

    def pick(self):
        """Surprise on the server: a song you haven't heard lately, leaning to the current genre/artist."""
        if not self.lib.tracks:
            return None
        cur = self.lib.by_id.get(self.current() or "")
        avoid = set(self.recent) | set(self.state["queue"][-30:])
        pool = [t for t in self.lib.tracks if t["id"] not in avoid] or self.lib.tracks
        if cur:
            close = [t for t in pool if t.get("genre") and t.get("genre") == cur.get("genre")] + \
                    [t for t in pool if t["artist"] == cur["artist"]]
            if close and random.random() < 0.6:
                return random.choice(close)["id"]
        return random.choice(pool)["id"]

    def _keep_surprise_going(self):
        s = self.state
        if s.get("radio") == "surprise" and len(s["queue"]) - s["index"] <= 2:
            nxt = self.pick()
            if nxt:
                s["queue"].append(nxt)

    def _schedule(self):
        """Moves to the next song when this one ends (crossfade seconds early)."""
        if self.timer:
            self.timer.cancel()
            self.timer = None
        cur = self.lib.by_id.get(self.current() or "")
        if not self.state["isPlaying"] or not cur or cur["duration"] <= 0:
            return
        lead = self.state["crossfade"] if self.state["crossfade"] and cur["duration"] > self.state["crossfade"] + 2 else 0
        remaining = cur["duration"] - lead - self.position() + (0 if lead else 0.8)
        loop = asyncio.get_running_loop()
        self.timer = loop.call_later(max(0.2, remaining), lambda: self.perform({"action": "auto"}))


# --------------------------------------------------------------------------- server

class Server:
    def __init__(self, args):
        CONFIG.mkdir(parents=True, exist_ok=True)
        cfg_file = CONFIG / "config.json"
        cfg = Library._load(cfg_file, {})
        if not cfg.get("token"):
            cfg["token"] = secrets.token_hex(16)
            cfg["pin"] = f"{secrets.randbelow(10**6):06d}"
        cfg.setdefault("name", args.name or f"{socket.gethostname()} ({'Windows' if WINDOWS else 'Linux'})")
        Library._save(cfg_file, cfg)
        self.token, self.pin, self.name = cfg["token"], cfg["pin"], cfg["name"]
        self.http_port = 7860 + args.port_offset
        self.ws_port = 7861 + args.port_offset
        roots = [Path(p).expanduser() for p in (args.music or ["~/Music", "~/Documents/Songs"])]
        FLOATERS.mkdir(parents=True, exist_ok=True)
        self.library = Library(roots)
        self.session = Session(self.library, self.state_changed)
        self.clients: dict[web.WebSocketResponse, dict] = {}
        self.seen_seqs: dict[str, list[int]] = {}
        self.pin_failures = 0
        self.remote: dict | None = None        # what a linked Mac is playing (for the window)
        self.remote_commands: list[dict] = []  # buttons pressed for it, sent back in its next report
        # The chain: while a linked Mac is on, phones that connect here are passed
        # straight through to it (one shared session). Its key is kept so phones
        # that got it from the Mac still get in here when the Mac is off.
        self.cfg_file, self.cfg = cfg_file, cfg
        self.leader: dict | None = cfg.get("leader")
        self.leader_at = 0.0
        self.client: ClientSession | None = None
        # Live link to the linked Mac (for the window): its session and songs.
        self.mac_ws = None
        self.mac_state: dict | None = None
        self.mac_state_at = 0.0
        self.mac_tracks: dict[str, dict] = {}
        self.mac_keys: dict[str, str] = {}

    # ---- helpers

    @staticmethod
    def addresses():
        """This computer's IPv4 addresses, found fresh each time (nothing is stored)."""
        found: list[str] = []
        if not WINDOWS:
            try:
                out = subprocess.run(["ip", "-4", "-o", "addr", "show", "scope", "global"],
                                     capture_output=True, text=True).stdout
                found = [line.split()[3].split("/")[0] for line in out.splitlines() if len(line.split()) > 3]
            except Exception:
                pass
        if not found:   # Windows (or no `ip`): every adapter's address, plus the one with the default route
            try:
                found = [a[4][0] for a in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET)]
            except OSError:
                found = []
            try:
                with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
                    s.connect(("192.0.2.1", 9))   # no packet is sent; just picks the outgoing interface
                    found.insert(0, s.getsockname()[0])
            except OSError:
                pass
        out: list[str] = []
        for ip in found:
            if ip not in out and not ip.startswith(("127.", "169.254.")):
                out.append(ip)
        return out

    @staticmethod
    def is_tailscale(ip):
        a = ip.split(".")
        return len(a) == 4 and a[0] == "100" and 64 <= int(a[1]) <= 127

    def lan_ip(self):
        return next((ip for ip in self.addresses() if not self.is_tailscale(ip)), "")

    def tailscale_ip(self):
        return next((ip for ip in self.addresses() if self.is_tailscale(ip)), None)

    def phones(self):
        return [c for c in self.clients.values() if c["authed"]]

    def devices(self):
        return [{"id": c["deviceID"], "name": c["name"], "kind": c["kind"]} for c in self.phones()]

    def known_token(self, t) -> bool:
        return bool(t) and (t == self.token or (self.leader is not None and t == self.leader.get("token")))

    def authorized(self, request) -> bool:
        return self.known_token(request.query.get("t"))

    def leader_live(self) -> bool:
        """The linked Mac reported in the last 20 s (it does every 2-6 s while it's on)."""
        return self.leader is not None and now() - self.leader_at < 20

    def for_leader(self, request) -> bool:
        return self.leader_live() and request.query.get("t") == self.leader["token"]

    async def proxy(self, request):
        """Passes a phone's request through to the linked Mac (catalog, art, songs with Range)."""
        url = f"http://{self.leader['host']}:{self.leader['http']}{request.path_qs}"
        headers = {k: v for k, v in request.headers.items() if k.lower() in ("range", "if-range")}
        try:
            async with self.client.get(url, headers=headers) as r:
                keep = ("content-type", "content-length", "content-range", "accept-ranges", "last-modified", "etag")
                resp = web.StreamResponse(status=r.status, headers={k: v for k, v in r.headers.items() if k.lower() in keep})
                await resp.prepare(request)
                async for chunk in r.content.iter_chunked(1 << 16):
                    await resp.write(chunk)
                await resp.write_eof()
                return resp
        except (ClientError, asyncio.TimeoutError, ConnectionResetError):
            return web.Response(status=502)

    async def send(self, ws, msg: dict):
        try:
            await ws.send_str(json.dumps(msg))
        except Exception:
            pass

    def broadcast(self, msg: dict):
        for ws in [w for w, c in self.clients.items() if c["authed"]]:
            asyncio.ensure_future(self.send(ws, msg))

    def state_changed(self):
        self.broadcast({"type": "state", "state": self.session.snapshot()})

    def catalog_bytes(self):
        moment = time.strftime("%A ") + ("morning" if 5 <= time.localtime().tm_hour < 12 else
                                          "afternoon" if time.localtime().tm_hour < 17 else
                                          "evening" if time.localtime().tm_hour < 22 else "night")
        extra = [{"id": "auto-surprise", "name": "Surprise", "subtitle": "auto", "trackIDs": []}]
        return json.dumps(self.library.catalog(extra)).encode()

    # ---- HTTP

    async def ping(self, request):
        return web.Response(text="musiplex")

    async def catalog(self, request):
        if not self.authorized(request):
            return web.Response(status=401)
        if self.for_leader(request):
            return await self.proxy(request)
        return web.Response(body=self.catalog_bytes(), content_type="application/json")

    async def art(self, request):
        if not self.authorized(request):
            return web.Response(status=401)
        if self.for_leader(request):
            return await self.proxy(request)
        tid = "".join(ch for ch in request.match_info["id"] if ch in "0123456789abcdef")
        path = self.library.art_dir / f"{tid}.jpg"
        if not path.exists():
            return web.Response(status=404)
        return web.FileResponse(path, headers={"Content-Type": "image/jpeg"})

    async def file(self, request):
        if not self.authorized(request):
            return web.Response(status=401)
        if self.for_leader(request):
            return await self.proxy(request)
        tid = request.match_info["name"].split(".")[0]
        path = self.library.paths.get(tid)
        if not path or not os.path.exists(path):
            return web.Response(status=404)
        return web.FileResponse(path)  # handles Range requests

    async def pair(self, request):
        """Another Musiplex (your Mac) trades the PIN for the token, to pull Floaters."""
        if request.query.get("pin") != self.pin:
            self.pin_failures += 1
            await asyncio.sleep(min(10, self.pin_failures))
            return web.Response(status=401)
        self.pin_failures = 0
        return web.json_response({"token": self.token, "name": self.name,
                                  "hosts": [h for h in [self.lan_ip(), self.tailscale_ip()] if h]})

    async def floaters(self, request):
        if not self.authorized(request):
            return web.Response(status=401)
        items = []
        for p in sorted(FLOATERS.iterdir()) if FLOATERS.exists() else []:
            if p.is_file() and not p.name.startswith(".") and p.suffix.lower() in AUDIO:
                st = p.stat()
                items.append({"name": p.name, "size": st.st_size, "mtime": st.st_mtime})
        return web.json_response(items)

    async def floater(self, request):
        if not self.authorized(request):
            return web.Response(status=401)
        name = os.path.basename(request.query.get("name", ""))
        path = FLOATERS / name
        if not name or not path.is_file():
            return web.Response(status=404)
        return web.FileResponse(path)

    # ---- desktop window (only from this computer)

    def local(self, request, write=False) -> bool:
        """Only this computer, through its own address (stops other sites and other machines)."""
        if request.remote not in ("127.0.0.1", "::1"):
            return False
        host = request.host.rsplit(":", 1)[0].strip("[]")
        if host not in ("127.0.0.1", "localhost", "::1"):
            return False
        return not write or request.headers.get("X-Musiplex") == "1"

    async def dashboard(self, request):
        if not self.local(request):
            return web.Response(text="musiplex")
        return web.Response(text=DASHBOARD.replace("__VERSION__", DASHBOARD_VERSION), content_type="text/html",
                            headers={"Cache-Control": "no-store"})

    async def local_status(self, request):
        if not self.local(request):
            return web.Response(status=403)
        cur = self.library.by_id.get(self.session.current() or "")
        floaters = []
        if FLOATERS.exists():
            floaters = sorted((p for p in FLOATERS.iterdir() if p.is_file() and not p.name.startswith(".")
                               and p.suffix.lower() in AUDIO), key=lambda p: p.stat().st_mtime, reverse=True)
        return web.json_response({
            "name": self.name, "songs": len(self.library.tracks), "pin": self.pin,
            "lan": self.lan_ip(), "tailscale": self.tailscale_ip(), "devices": self.devices(),
            "state": self.session.snapshot(),
            "current": {k: cur.get(k) for k in ("id", "title", "artist", "album", "duration")} if cur else None,
            "hasArt": bool(cur and (self.library.art_dir / f"{cur['id']}.jpg").exists()),
            "floatersPath": str(FLOATERS), "floaters": [p.name for p in floaters[:50]],
            "floaterCount": len(floaters), "remote": self.remote_view(), "macLink": self.mac_ws is not None, "version": DASHBOARD_VERSION},
            headers={"Cache-Control": "no-store"})

    def remote_view(self):
        r = self.remote
        st = self.mac_state if self.mac_ws is not None else None
        if st is not None:                 # live from the Mac link: changes show at once
            q, i = st.get("queue") or [], st.get("index") or 0
            mt = self.mac_tracks.get(q[i]) if 0 <= i < len(q) else None
            if not mt:
                return None
            t = {k: mt.get(k) for k in ("title", "artist", "album", "duration")}
            t["isPlaying"] = bool(st.get("isPlaying"))
            t["position"] = (st.get("position") or 0) + (now() - self.mac_state_at if t["isPlaying"] else 0)
        else:
            if not r or now() - r["at"] > 20 or not r.get("track"):
                return None
            t = dict(r["track"])
            if t.get("isPlaying"):
                t["position"] = (t.get("position") or 0) + now() - r["at"]
        key = (str(t.get("title", "")).lower(), str(t.get("artist", "")).lower())
        mine = next((x for x in self.library.tracks if (x["title"].lower(), x["artist"].lower()) == key), None)
        t["artID"] = mine["id"] if mine and (self.library.art_dir / f"{mine['id']}.jpg").exists() else None
        t["from"] = r.get("name") or "Mac"
        return t

    async def linked_nowplaying(self, request):
        """A linked Mac reports what it's playing; gets back buttons pressed for it in the window."""
        if not self.authorized(request):
            return web.Response(status=401)
        try:
            body = await request.json()
        except ValueError:
            return web.Response(status=400)
        track = body.get("track") if isinstance(body.get("track"), dict) else None
        self.remote = {"name": str(body.get("name") or "Mac")[:80], "track": track, "at": now()}
        lead = body.get("leader")
        if isinstance(lead, dict) and isinstance(lead.get("token"), str) and lead["token"]:
            leader = {"token": lead["token"], "host": request.remote,
                      "http": int(lead.get("http") or 7860), "ws": int(lead.get("ws") or 7861)}
            if leader != self.leader:
                self.leader = leader
                self.cfg["leader"] = leader
                Library._save(self.cfg_file, self.cfg)
            self.leader_at = now()
        commands, self.remote_commands = self.remote_commands, []
        return web.json_response({"commands": commands})

    async def local_songs(self, request):
        if not self.local(request):
            return web.Response(status=403)
        return web.json_response([[t["id"], t["title"], t["artist"]] for t in self.library.tracks])

    async def local_art(self, request):
        if not self.local(request):
            return web.Response(status=403)
        tid = "".join(ch for ch in request.match_info["id"] if ch in "0123456789abcdef")
        path = self.library.art_dir / f"{tid}.jpg"
        return web.FileResponse(path, headers={"Content-Type": "image/jpeg"}) if path.exists() else web.Response(status=404)

    async def local_cmd(self, request):
        if not self.local(request, write=True):
            return web.Response(status=403)
        try:
            command = await request.json()
        except ValueError:
            return web.Response(status=400)
        if command.get("action") not in ("play", "toggle", "next", "prev", "surprise", "pause", "resume"):
            return web.Response(status=400)
        if command.get("target") == "remote" and self.mac_ws is not None:   # straight to the Mac, at once
            if command["action"] == "play":
                ids, i = command.get("ids") or [], command.get("index") or 0
                t = self.library.by_id.get(ids[i]) if 0 <= i < len(ids) else None
                mac_id = self.mac_keys.get(song_key(t["title"], t["artist"])) if t else None
                if not mac_id:
                    return web.Response(status=404)
                command = {"action": "play", "ids": [mac_id], "index": 0}
            else:
                command = {"action": command["action"]}
            try:
                await self.mac_ws.send_str(json.dumps({"type": "command", "command": command}))
                return web.json_response({"ok": True})
            except (ClientError, ConnectionResetError, RuntimeError):
                pass                                  # fall back to the next report
        if command.get("target") == "remote":         # a button for the linked Mac
            if command["action"] == "play":
                ids, i = command.get("ids") or [], command.get("index") or 0
                t = self.library.by_id.get(ids[i]) if 0 <= i < len(ids) else None
                if not t:
                    return web.Response(status=400)
                command = {"action": "play", "title": t["title"], "artist": t["artist"]}
            self.remote_commands = (self.remote_commands + [{k: command[k] for k in ("action", "title", "artist") if k in command}])[-10:]
            return web.json_response({"ok": True})
        self.session.perform(command)
        return web.json_response({"ok": True})

    # ---- WebSocket

    async def socket(self, request):
        ws = web.WebSocketResponse(heartbeat=30, max_msg_size=8 << 20)
        await ws.prepare(request)
        if self.leader_live():
            try:
                up = await self.client.ws_connect(f"ws://{self.leader['host']}:{self.leader['ws']}/",
                                                  heartbeat=30, max_msg_size=8 << 20)
            except (ClientError, asyncio.TimeoutError, OSError):
                up = None
            if up is not None:
                await self.relay(ws, up)
                return ws
        self.clients[ws] = {"authed": False, "deviceID": "", "name": "iPhone", "kind": "iphone"}
        try:
            async for msg in ws:
                if msg.type != WSMsgType.TEXT:
                    continue
                try:
                    m = json.loads(msg.data)
                except ValueError:
                    continue
                await self.handle(ws, m)
        finally:
            client = self.clients.pop(ws, None)
            if client and client["authed"]:
                self.device_left(client)
        return ws

    async def mac_link(self):
        """While the linked Mac is on: a live connection to it, so the window shows its song
        the moment it changes and its buttons act at once (no waiting for the next report)."""
        while True:
            if not self.leader_live():
                await asyncio.sleep(2)
                continue
            lead = self.leader
            try:
                await self.load_mac_catalog(lead)
                ws = await self.client.ws_connect(f"ws://{lead['host']}:{lead['ws']}/", heartbeat=30,
                                                  max_msg_size=16 << 20)
                await ws.send_str(json.dumps({"type": "hello", "token": lead["token"], "kind": "server",
                                              "deviceID": "server-" + self.token[:12], "name": self.name}))
                async for msg in ws:
                    if msg.type != WSMsgType.TEXT:
                        continue
                    m = json.loads(msg.data)
                    kind = m.get("type")
                    if kind in ("welcome", "state", "promoted") and m.get("state"):
                        self.mac_ws = ws
                        self.mac_state, self.mac_state_at = m["state"], now()
                    elif kind == "tick" and self.mac_state is not None:
                        self.mac_state["position"] = m.get("position") or 0
                        self.mac_state["isPlaying"] = bool(m.get("isPlaying"))
                        self.mac_state_at = now()
                    elif kind == "library":
                        await self.load_mac_catalog(lead)
                    elif kind == "denied":
                        break
            except (ClientError, asyncio.TimeoutError, OSError, ValueError):
                pass
            self.mac_ws, self.mac_state = None, None
            await asyncio.sleep(3)

    async def load_mac_catalog(self, lead):
        async with self.client.get(f"http://{lead['host']}:{lead['http']}/catalog?t={lead['token']}") as r:
            cat = await r.json(content_type=None)
        tracks = cat.get("tracks") or []
        self.mac_tracks = {t["id"]: t for t in tracks}
        self.mac_keys = {song_key(t.get("title", ""), t.get("artist", "")): t["id"] for t in tracks}

    async def relay(self, ws, up):
        """Chain: this phone talks to the linked Mac through here. Its hello is let in with
        this server's PIN or key (or the Mac's), and passed on with the Mac's key."""
        async def from_phone():
            async for msg in ws:
                if msg.type != WSMsgType.TEXT:
                    continue
                data = msg.data
                try:
                    m = json.loads(data)
                except ValueError:
                    continue
                if m.get("type") == "hello":
                    if not (self.known_token(m.get("token")) or m.get("pin") == self.pin):
                        await self.send(ws, {"type": "denied"})
                        return
                    m["token"] = self.leader["token"]
                    m.pop("pin", None)
                    data = json.dumps(m)
                await up.send_str(data)

        async def from_mac():
            async for msg in up:
                if msg.type == WSMsgType.TEXT:
                    await ws.send_str(msg.data)

        tasks = [asyncio.ensure_future(from_phone()), asyncio.ensure_future(from_mac())]
        try:
            await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        finally:
            for t in tasks:
                t.cancel()
            await up.close()
            await ws.close()

    def device_left(self, client):
        self.broadcast({"type": "devices", "devices": self.devices()})
        s = self.session.state
        if s["activeDevice"] == client["deviceID"]:
            others = self.phones()
            if others:
                s["activeDevice"] = others[0]["deviceID"]
            else:
                self.session.perform({"action": "pause"})
            self.state_changed()

    async def handle(self, ws, m: dict):
        client = self.clients.get(ws)
        if client is None:
            return
        kind = m.get("type")
        if kind == "hello":
            if not self.known_token(m.get("token")) and m.get("pin") != self.pin:
                await self.send(ws, {"type": "denied"})
                return
            device = m.get("deviceID") or str(uuid.uuid4())
            for other, c in list(self.clients.items()):   # a device reconnecting replaces its old link
                if other is not ws and c["deviceID"] == device:
                    self.clients.pop(other, None)
                    asyncio.ensure_future(other.close())
            client.update(authed=True, deviceID=device, name=m.get("name") or "iPhone", kind=m.get("kind") or "iphone")
            s = self.session.state
            if s["activeDevice"] not in {c["deviceID"] for c in self.phones()}:
                s["activeDevice"] = device          # no speakers here: a device plays the sound
            hosts = [h for h in [self.tailscale_ip()] if h]
            await self.send(ws, {"type": "welcome", "token": self.token, "name": self.name,
                                 "state": self.session.snapshot(), "devices": self.devices(), "hosts": hosts})
            self.broadcast({"type": "devices", "devices": self.devices()})
            return
        if not client["authed"]:
            return
        source = m.get("source") or client["name"]
        if kind == "command":
            seq = m.get("seq")
            if seq is not None:
                seen = self.seen_seqs.setdefault(client["deviceID"], [])
                if seq in seen:
                    return
                seen.append(seq)
                del seen[:-64]
            command = m.get("command") or {}
            if command.get("action") == "device" and command.get("text") not in {c["deviceID"] for c in self.phones()}:
                return
            self.session.perform(command)
        elif kind == "playlist":
            self.library.edit_playlist(m.get("text"), m.get("name"), m.get("ids"), m.get("removeIDs"), source)
            self.broadcast({"type": "library"})
        elif kind == "deletePlaylist":
            self.library.delete_playlist(m.get("text"), source)
            self.broadcast({"type": "library"})
        elif kind == "reorderPlaylists":
            self.library.reorder(m.get("ids") or [])
            self.broadcast({"type": "library"})
        elif kind == "revert":
            try:
                self.library.revert(int(m.get("text") or 0), source)
            except ValueError:
                return
            self.broadcast({"type": "library"})
        # "taste", "exportPlaylist" and Bluetooth "fetch" are Mac-only: ignored here.

    # ---- background jobs

    async def ticker(self):
        while True:
            await asyncio.sleep(3)
            if self.session.state["isPlaying"] and self.phones():
                self.broadcast({"type": "tick", "position": self.session.position(), "isPlaying": True})

    async def rescanner(self):
        """Quick check every 20 s (only new/changed files are read), so new Floaters show up fast."""
        while True:
            changed = await asyncio.get_running_loop().run_in_executor(None, self.library.scan)
            if changed:
                self.broadcast({"type": "library"})
            await asyncio.sleep(20)

    async def advertise(self):
        if AsyncZeroconf is None:
            return None
        ip = self.lan_ip()
        if not ip:
            return None
        info = ServiceInfo("_musiplex._tcp.local.", f"{self.name}._musiplex._tcp.local.",
                           addresses=[socket.inet_aton(ip)], port=self.ws_port,
                           properties={"ip": ip, "http": str(self.http_port), "ws": str(self.ws_port)},
                           server=f"{socket.gethostname()}.local.")
        zc = AsyncZeroconf(ip_version=IPVersion.V4Only)
        await zc.async_register_service(info)
        return zc

    async def run(self):
        self.client = ClientSession(timeout=ClientTimeout(total=None, connect=4, sock_read=30))
        http = web.Application(client_max_size=1 << 20)
        http.router.add_get("/ping", self.ping)
        http.router.add_get("/catalog", self.catalog)
        http.router.add_get("/art/{id}", self.art)
        http.router.add_get("/file/{name}", self.file)
        http.router.add_get("/pair", self.pair)
        http.router.add_get("/floaters", self.floaters)
        http.router.add_get("/floater", self.floater)
        # The desktop window (this computer only).
        http.router.add_get("/", self.dashboard)
        http.router.add_get("/local/status", self.local_status)
        http.router.add_get("/local/songs", self.local_songs)
        http.router.add_get("/local/art/{id}", self.local_art)
        http.router.add_post("/local/cmd", self.local_cmd)
        http.router.add_post("/linked/nowplaying", self.linked_nowplaying)
        ws = web.Application()
        ws.router.add_get("/", self.socket)
        runners = []
        for app, port in ((http, self.http_port), (ws, self.ws_port)):
            runner = web.AppRunner(app, access_log=None)
            await runner.setup()
            await web.TCPSite(runner, "0.0.0.0", port).start()
            runners.append(runner)
        await asyncio.get_running_loop().run_in_executor(None, self.library.scan)
        zc = await self.advertise()
        print(f"Musiplex server '{self.name}' running", flush=True)
        print(f"  songs: {len(self.library.tracks)}  ·  PIN: {self.pin}", flush=True)
        print(f"  home network: {self.lan_ip()}  ·  Tailscale: {self.tailscale_ip() or 'off'}", flush=True)
        print(f"  ports: {self.http_port} (HTTP), {self.ws_port} (WebSocket)", flush=True)
        try:
            await asyncio.gather(self.ticker(), self.rescanner(), self.mac_link())
        finally:
            if zc:
                await zc.async_close()


DASHBOARD = r"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Musiplex</title>
<style>
:root{--bg:#f4f4f6;--card:#fff;--text:#16161a;--dim:#6b6b76;--line:#e4e4ea;--accent:#7c5cff;--ok:#1fa66a}
@media (prefers-color-scheme:dark){:root{--bg:#111114;--card:#1c1c21;--text:#f2f2f5;--dim:#9a9aa6;--line:#2c2c33;--accent:#9b82ff;--ok:#3ccf8e}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:14px/1.4 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
main{max-width:760px;margin:0 auto;padding:20px 16px;display:grid;gap:14px}
header{display:flex;align-items:center;gap:10px}h1{font-size:20px;margin:0}
.dot{width:9px;height:9px;border-radius:50%;background:var(--ok)}.dot.off{background:#d04545}
.sub{color:var(--dim)}.card{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:16px}
.now{display:flex;gap:16px;align-items:center}.art{width:96px;height:96px;border-radius:10px;background:var(--line);object-fit:cover;flex:none}
.title{font-size:17px;font-weight:600}.bar{height:4px;background:var(--line);border-radius:2px;margin:10px 0 4px;overflow:hidden}
.bar i{display:block;height:100%;background:var(--accent);width:0}
.times{display:flex;justify-content:space-between;color:var(--dim);font-size:12px}
.controls{display:flex;gap:8px;margin-top:8px;flex-wrap:wrap}
button{font:inherit;border:1px solid var(--line);background:var(--card);color:var(--text);border-radius:999px;padding:7px 14px;cursor:pointer}
button.main{background:var(--accent);border-color:var(--accent);color:#fff;font-weight:600}button:hover{filter:brightness(1.08)}
.grid{display:grid;grid-template-columns:1fr 1fr;gap:14px}@media (max-width:600px){.grid{grid-template-columns:1fr}}
h2{font-size:13px;text-transform:uppercase;letter-spacing:.04em;color:var(--dim);margin:0 0 10px}
.row{display:flex;justify-content:space-between;gap:10px;padding:5px 0;border-bottom:1px solid var(--line)}.row:last-child{border:0}
code{font:13px ui-monospace,monospace}.pin{letter-spacing:.15em}
input{width:100%;font:inherit;padding:9px 12px;border-radius:10px;border:1px solid var(--line);background:var(--bg);color:var(--text)}
ul{list-style:none;margin:8px 0 0;padding:0;max-height:300px;overflow:auto}li{padding:7px 4px;border-bottom:1px solid var(--line);cursor:pointer;display:flex;justify-content:space-between;gap:10px}
li:hover{background:var(--bg)}li span{color:var(--dim);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.hint{color:var(--dim);font-size:12px;margin-top:8px}
</style></head><body><main>
<header><span class="dot" id="dot"></span><h1 id="name">Musiplex</h1><span class="sub" id="songs"></span></header>
<section class="card"><div class="now"><img class="art" id="art" alt="">
<div style="flex:1;min-width:0"><div class="sub" id="from" style="font-size:12px"></div><div class="title" id="title">Nothing playing</div><div class="sub" id="artist"></div>
<div class="bar"><i id="prog"></i></div><div class="times"><span id="pos"></span><span id="dur"></span></div>
<div class="controls"><button onclick="cmd('prev')">⏮</button><button class="main" id="toggle" onclick="cmd('toggle')">Play</button>
<button onclick="cmd('next')">⏭</button><button onclick="cmd('surprise')">✨ Surprise</button></div></div></div>
<div class="hint" id="speaker"></div></section>
<div class="grid">
<section class="card"><h2>Connect a device</h2>
<div class="row"><span>Home network</span><code id="lan">—</code></div>
<div class="row"><span>Tailscale</span><code id="ts">off</code></div>
<div class="row"><span>PIN</span><code class="pin" id="pin">••••••</code></div>
<div class="hint"><a href="#" id="reveal" style="color:var(--accent)">Show PIN</a></div></section>
<section class="card"><h2>Devices</h2><div id="devices" class="sub">None connected</div></section>
</div>
<section class="card"><h2>Floaters <span id="fcount"></span></h2><div class="sub"><code id="fpath"></code></div><ul id="floaters"></ul>
<div class="hint">Drop songs in this folder: they show up on your phone in a few seconds, and on your Mac within a minute.</div></section>
<section class="card"><h2>Songs</h2><input id="q" placeholder="Search songs or artists" autocomplete="off"><ul id="list"></ul></section>
</main><script>
const VERSION="__VERSION__";let st=null,remote=false,shown=null,songs=[],showPin=false,artId=null,base=0;
const $=id=>document.getElementById(id);
const fmt=s=>{s=Math.max(0,Math.floor(s||0));return Math.floor(s/60)+":"+String(s%60).padStart(2,"0")};
const esc=t=>String(t).replace(/[&<>"]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));
async function cmd(action,extra){const body=Object.assign({action},extra||{});if(remote)body.target="remote";
  await fetch("/local/cmd",{method:"POST",headers:{"Content-Type":"application/json","X-Musiplex":"1"},body:JSON.stringify(body)});setTimeout(poll,150)}
async function poll(){
  try{const r=await fetch("/local/status");st=await r.json();if(st.version&&st.version!==VERSION){location.reload();return}base=performance.now();$("dot").className="dot"}catch(e){$("dot").className="dot off";$("songs").textContent="server not running";return}
  $("name").textContent=st.name;$("songs").textContent=st.songs.toLocaleString()+" songs";
  $("lan").textContent=st.lan||"—";$("ts").textContent=st.tailscale||"off";$("pin").textContent=showPin?st.pin:"••••••";
  const r=st.remote,own=st.current;remote=!!(r&&(!own||!st.state.isPlaying||!st.devices.length));
  const c=remote?r:own;shown=c;if(remote){st.state=Object.assign({},st.state,{isPlaying:r.isPlaying,position:r.position});st.hasArt=!!r.artID;c.id=r.artID}
  $("from").textContent=remote?"Playing on "+r.from:(own?"Playing here":"");
  $("title").textContent=c?c.title:"Nothing playing";$("artist").textContent=c?c.artist+" · "+c.album:"";
  if(c&&st.hasArt&&artId!==c.id){$("art").src="/local/art/"+c.id;artId=c.id}else if(!c||!st.hasArt){$("art").removeAttribute("src");artId=null}
  $("toggle").textContent=st.state.isPlaying?"Pause":"Play";
  $("devices").innerHTML=st.devices.length?st.devices.map(d=>'<div class="row"><span>'+esc(d.name)+'</span><span class="sub">'+esc(d.kind)+(d.id===st.state.activeDevice?" · speaker":"")+'</span></div>').join(""):"None connected";
  $("speaker").textContent=st.devices.length||remote?"":"This computer has no speaker of its own in Musiplex: open Musiplex on your phone and the sound plays there.";
  $("fcount").textContent="("+st.floaterCount+")";$("fpath").textContent=st.floatersPath;
  $("floaters").innerHTML=st.floaters.map(n=>"<li>"+esc(n)+"</li>").join("")||'<li class="sub">Empty</li>';
  if(songs.length!==st.songs)loadSongs();tick()}
function tick(){if(!st||!shown){$("pos").textContent=$("dur").textContent="";$("prog").style.width="0";return}const d=shown.duration||0;let p=st.state.position+(st.state.isPlaying?(performance.now()-base)/1000:0);p=Math.min(p,d);
  $("pos").textContent=fmt(p);$("dur").textContent=fmt(d);$("prog").style.width=(d?p/d*100:0)+"%"}
async function loadSongs(){songs=await (await fetch("/local/songs")).json();render()}
function render(){const q=$("q").value.trim().toLowerCase();const hits=(q?songs.filter(s=>(s[1]+" "+s[2]).toLowerCase().includes(q)):songs).slice(0,200);
  $("list").innerHTML=hits.map(s=>'<li data-id="'+s[0]+'">'+esc(s[1])+"<span>"+esc(s[2])+"</span></li>").join("")}
$("list").onclick=e=>{const li=e.target.closest("li");if(!li)return;const q=$("q").value.trim().toLowerCase();
  const ids=(q?songs.filter(s=>(s[1]+" "+s[2]).toLowerCase().includes(q)):songs).map(s=>s[0]);cmd("play",{ids,index:ids.indexOf(li.dataset.id)})};
$("q").oninput=render;$("reveal").onclick=e=>{e.preventDefault();showPin=!showPin;$("reveal").textContent=showPin?"Hide PIN":"Show PIN";poll()};
poll();setInterval(()=>{if(!document.hidden)poll()},1000);setInterval(tick,500);
</script></body></html>"""

DASHBOARD_VERSION = hashlib.sha256(DASHBOARD.encode()).hexdigest()[:12]


def main():
    parser = argparse.ArgumentParser(description="Musiplex server for Linux and Windows")
    parser.add_argument("--music", action="append", help="music folder (repeatable); default ~/Music and ~/Documents/Songs")
    parser.add_argument("--name", help="name shown on your devices")
    parser.add_argument("--port-offset", type=int, default=int(os.environ.get("MUSIPLEX_PORT_OFFSET", "0")))
    parser.add_argument("--show-pin", action="store_true", help="print the pairing PIN and exit")
    args = parser.parse_args()
    if args.show_pin:
        cfg = Library._load(CONFIG / "config.json", {})
        print(cfg.get("pin", "(start the server once first)"))
        return
    if mutagen is None:
        raise SystemExit("mutagen is missing: run install.sh")
    asyncio.run(Server(args).run())


if __name__ == "__main__":
    main()
