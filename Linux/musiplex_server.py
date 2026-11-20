#!/usr/bin/env python3
"""Musiplex server for Linux (headless).

Speaks the same protocol as the Mac app, so the iPhone/iPad app connects to it
exactly like it connects to a Mac: found on the home network automatically
(Bonjour), or by its Tailscale address from anywhere.

- Library: ~/Music and ~/Documents/Songs (including Songs/Floaters), rescanned
  every few minutes; tags and artwork read with mutagen.
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

from aiohttp import WSMsgType, web

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
CONFIG = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "musiplex"
HOME = Path.home()
FLOATERS = Path(os.environ.get("MUSIPLEX_FLOATERS", HOME / "Documents" / "Songs" / "Floaters"))


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
        cfg.setdefault("name", args.name or f"{socket.gethostname()} (Linux)")
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

    # ---- helpers

    @staticmethod
    def addresses():
        try:
            out = subprocess.run(["ip", "-4", "-o", "addr", "show", "scope", "global"], capture_output=True, text=True).stdout
        except Exception:
            return []
        return [line.split()[3].split("/")[0] for line in out.splitlines() if len(line.split()) > 3]

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

    def authorized(self, request) -> bool:
        return request.query.get("t") == self.token

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
        return web.Response(body=self.catalog_bytes(), content_type="application/json")

    async def art(self, request):
        if not self.authorized(request):
            return web.Response(status=401)
        tid = "".join(ch for ch in request.match_info["id"] if ch in "0123456789abcdef")
        path = self.library.art_dir / f"{tid}.jpg"
        if not path.exists():
            return web.Response(status=404)
        return web.FileResponse(path, headers={"Content-Type": "image/jpeg"})

    async def file(self, request):
        if not self.authorized(request):
            return web.Response(status=401)
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

    # ---- WebSocket

    async def socket(self, request):
        ws = web.WebSocketResponse(heartbeat=30, max_msg_size=8 << 20)
        await ws.prepare(request)
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
            if m.get("token") != self.token and m.get("pin") != self.pin:
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
        http = web.Application(client_max_size=1 << 20)
        http.router.add_get("/ping", self.ping)
        http.router.add_get("/catalog", self.catalog)
        http.router.add_get("/art/{id}", self.art)
        http.router.add_get("/file/{name}", self.file)
        http.router.add_get("/pair", self.pair)
        http.router.add_get("/floaters", self.floaters)
        http.router.add_get("/floater", self.floater)
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
            await asyncio.gather(self.ticker(), self.rescanner())
        finally:
            if zc:
                await zc.async_close()


def main():
    parser = argparse.ArgumentParser(description="Musiplex server for Linux")
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
