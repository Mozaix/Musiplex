"""Workload tasks for a Musiplex server.

Adds a small task store to the Musiplex HTTP server so the Workload apps
(iPhone, iPad, Mac), the Musiplex notch calendar and the Toddle sync on Linux
all share one list of assignments.

Wiring (inside Musiplex's Server.run, next to the other routes):

    import workload_tasks
    workload_tasks.install(http.router, self, CONFIG)

Routes
  GET  /tasks?t=<token>          -> {"tasks": [...], "now": <epoch>}
  POST /tasks?t=<token>          body {"tasks": [...]}; merged, returns the same as GET
  POST /local/tasks              this computer only (header X-Musiplex: 1);
                                 body {"source": "toddle", "tasks": [{"sourceId","title","due"}],
                                       "complete": bool}  (complete: remove upcoming ones no longer listed)
  GET  /local/tasks              this computer only; same as GET /tasks

A task:
  {"id": str, "title": str, "due": "YYYY-MM-DD" | "YYYY-MM-DDTHH:MM" | null,
   "urgency": "green" | "yellow" | "red", "done": bool,
   "source": "manual" | "toddle", "updated": <epoch seconds>, "deleted": bool}

Merging is last-write-wins per task on "updated". Deleted tasks are kept as
tombstones for 30 days so every device learns about the deletion.

Run on its own for testing (no Musiplex needed):
    python3 workload_tasks.py --standalone --port 7870 --token test
"""
from __future__ import annotations

import json
import os
import threading
import time
from datetime import date, datetime
from pathlib import Path

URGENCIES = ("green", "yellow", "red")
TOMBSTONE_DAYS = 30


def default_urgency(due: str | None) -> str:
    """Red when due within a day, yellow within three days, otherwise green."""
    if not due:
        return "green"
    try:
        d = datetime.fromisoformat(due) if "T" in due else datetime.combine(date.fromisoformat(due), datetime.max.time())
    except ValueError:
        return "green"
    days = (d - datetime.now()).total_seconds() / 86400
    return "red" if days <= 1 else "yellow" if days <= 3 else "green"


def clean(t: dict) -> dict | None:
    """Keeps only known fields with sane types; None if it isn't a task."""
    if not isinstance(t, dict) or not isinstance(t.get("id"), str) or not t["id"]:
        return None
    due = t.get("due")
    if due is not None and not isinstance(due, str):
        due = None
    urgency = t.get("urgency") if t.get("urgency") in URGENCIES else "green"
    try:
        updated = float(t.get("updated") or 0)
    except (TypeError, ValueError):
        updated = 0.0
    return {
        "id": t["id"][:200],
        "title": str(t.get("title") or "")[:500],
        "due": due[:32] if due else None,
        "urgency": urgency,
        "done": bool(t.get("done")),
        "source": t.get("source") if t.get("source") in ("manual", "toddle") else "manual",
        "updated": updated,
        "deleted": bool(t.get("deleted")),
        # Who removed it and when ("Sam's iPhone", "Toddle"), for the Removed list.
        "deletedBy": str(t["deletedBy"])[:120] if t.get("deleted") and t.get("deletedBy") else None,
        "deletedAt": float(t["deletedAt"]) if t.get("deleted") and isinstance(t.get("deletedAt"), (int, float)) else None,
    }


class TaskStore:
    def __init__(self, folder: Path):
        folder.mkdir(parents=True, exist_ok=True)
        self.file = folder / "tasks.json"
        self.lock = threading.Lock()
        self.tasks: dict[str, dict] = {}
        try:
            for t in json.loads(self.file.read_text()).get("tasks", []):
                c = clean(t)
                if c:
                    self.tasks[c["id"]] = c
        except (OSError, ValueError):
            pass

    def _save(self):
        tmp = self.file.with_suffix(".tmp")
        tmp.write_text(json.dumps({"tasks": list(self.tasks.values())}, indent=1))
        os.replace(tmp, self.file)

    def _prune(self):
        cutoff = time.time() - TOMBSTONE_DAYS * 86400
        for k in [k for k, t in self.tasks.items() if t["deleted"] and t["updated"] < cutoff]:
            del self.tasks[k]

    def snapshot(self) -> dict:
        with self.lock:
            items = sorted(self.tasks.values(), key=lambda t: (t["due"] or "9999", t["title"].lower()))
            return {"tasks": items, "now": time.time()}

    def merge(self, incoming: list) -> None:
        """Last write wins, per task."""
        with self.lock:
            changed = False
            for raw in incoming if isinstance(incoming, list) else []:
                t = clean(raw)
                if not t:
                    continue
                mine = self.tasks.get(t["id"])
                if mine is None or t["updated"] > mine["updated"]:
                    if mine is not None and mine["deleted"] and not t["deleted"] and t["source"] == "toddle":
                        t["source"] = "manual"   # reinstated: Toddle no longer removes it
                    self.tasks[t["id"]] = t
                    changed = True
            if changed:
                self._prune()
                self._save()

    def import_feed(self, source: str, items: list, complete: bool = False) -> tuple[int, int]:
        """Tasks from Toddle: new ones are added; existing ones get the feed's
        title and due date, but keep the urgency and done mark you set.

        With `complete` (every feed fetched fine), upcoming deadlines that are no
        longer in Toddle are removed. Past ones and ones you finished stay."""
        now = time.time()
        added = removed = 0
        seen: set[str] = set()
        with self.lock:
            for it in items if isinstance(items, list) else []:
                if not isinstance(it, dict) or not it.get("sourceId") or not it.get("title"):
                    continue
                tid = f"{source}-{it['sourceId']}"[:200]
                seen.add(tid)
                title = str(it["title"])[:500]
                due = it.get("due") if isinstance(it.get("due"), str) else None
                mine = self.tasks.get(tid)
                if mine is None:
                    self.tasks[tid] = {"id": tid, "title": title, "due": due, "urgency": default_urgency(due),
                                       "done": False, "source": "toddle", "updated": now, "deleted": False,
                                       "deletedBy": None, "deletedAt": None}
                    added += 1
                elif not mine["deleted"] and (mine["title"] != title or mine["due"] != due):
                    mine.update(title=title, due=due, updated=now)
            if complete and seen:
                today = datetime.now().strftime("%Y-%m-%d")
                for t in self.tasks.values():
                    if (t["source"] == source and t["id"].startswith(source + "-") and t["id"] not in seen
                            and not t["deleted"] and not t["done"] and (t["due"] or "") >= today):
                        t.update(deleted=True, deletedBy="Toddle", deletedAt=now, updated=now)
                        removed += 1
            self._save()
        return added, removed


# --------------------------------------------------------------------------- Toddle, built in

TODDLE_EVERY = 15 * 60


def _unfold(text: str) -> list[str]:
    out: list[str] = []
    for line in text.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        if line[:1] in (" ", "\t") and out:
            out[-1] += line[1:]
        elif line:
            out.append(line)
    return out


def _unescape(v: str) -> str:
    return v.replace("\\n", " ").replace("\\N", " ").replace("\\,", ",").replace("\\;", ";").replace("\\\\", "\\").strip()


def _when(params: dict, value: str):
    import re
    from datetime import timezone
    value = value.strip()
    try:
        if params.get("VALUE") == "DATE" or re.fullmatch(r"\d{8}", value):
            return date(int(value[:4]), int(value[4:6]), int(value[6:8])), False
        dt = datetime.strptime(value.rstrip("Z")[:15], "%Y%m%dT%H%M%S")
    except ValueError:
        return None
    if value.endswith("Z"):
        dt = dt.replace(tzinfo=timezone.utc)
    elif "TZID" in params:
        try:
            from zoneinfo import ZoneInfo
            dt = dt.replace(tzinfo=ZoneInfo(params["TZID"].strip('"')))
        except Exception:
            dt = dt.astimezone()
    else:
        dt = dt.astimezone()
    return dt.astimezone().replace(tzinfo=None), True


def parse_feed(text: str, days_ahead: int = 60) -> list[dict]:
    """Toddle's calendar (iCal) → [{"sourceId","title","due"}], upcoming deadlines only.
    Reminders (VALARM) inside an event don't overwrite the event's own fields."""
    import re
    from datetime import timedelta
    events, cur, nested = [], None, 0
    for line in _unfold(text):
        if line in ("BEGIN:VEVENT", "BEGIN:VTODO"):
            cur, nested = {}, 0
        elif line in ("END:VEVENT", "END:VTODO"):
            if cur is not None:
                events.append(cur)
            cur = None
        elif cur is not None and line.startswith("BEGIN:"):
            nested += 1
        elif cur is not None and line.startswith("END:"):
            nested = max(0, nested - 1)
        elif cur is not None and nested == 0 and ":" in line:
            head, value = line.split(":", 1)
            name, *rest = head.split(";")
            cur[name.upper()] = (dict(p.split("=", 1) for p in rest if "=" in p), value)
    now = datetime.now()
    horizon = now + timedelta(days=days_ahead)
    out = []
    for ev in events:
        if "UID" not in ev or "SUMMARY" not in ev:
            continue
        raw = ev.get("DUE") or ev.get("DTSTART")
        when = _when(*raw) if raw else None
        if when is None:
            continue
        moment, has_time = when
        as_dt = moment if isinstance(moment, datetime) else datetime.combine(moment, datetime.max.time())
        if as_dt < now - timedelta(days=1) or as_dt > horizon:
            continue
        out.append({"sourceId": re.sub(r"[^A-Za-z0-9_.@-]", "", ev["UID"][1])[:150],
                    "title": _unescape(ev["SUMMARY"][1]),
                    "due": moment.strftime("%Y-%m-%dT%H:%M") if has_time else moment.isoformat()})
    return out


class Toddle:
    """Checks your Toddle calendar link(s) every 15 minutes and updates the tasks.
    The link is kept only on this computer (toddle.json next to tasks.json)."""

    def __init__(self, store: TaskStore, folder: Path):
        self.store = store
        self.file = Path(folder) / "toddle.json"
        try:
            self.cfg = json.loads(self.file.read_text())
        except (OSError, ValueError):
            self.cfg = {}
        self.cfg.setdefault("urls", [])
        self.status = {"checked": None, "ok": None, "added": 0, "removed": 0, "found": 0, "error": ""}
        self.wake = None

    def save(self):
        self.file.write_text(json.dumps(self.cfg))
        try:
            os.chmod(self.file, 0o600)
        except OSError:
            pass

    async def check(self, session) -> None:
        urls = [u for u in self.cfg.get("urls") or [] if u]
        if not urls:
            return
        items, complete, error = [], True, ""
        for url in urls:
            try:
                async with session.get(url.replace("webcal://", "https://", 1),
                                       headers={"User-Agent": "Musiplex-Workload/2.4"}) as r:
                    text = await r.text(errors="replace")
                if r.status != 200 or "BEGIN:VCALENDAR" not in text:
                    complete, error = False, f"Toddle answered {r.status}"
                    continue
                items += parse_feed(text)
            except Exception as e:
                complete, error = False, f"Couldn't reach Toddle ({type(e).__name__})"
        added, removed = self.store.import_feed("toddle", items, complete=complete and bool(items)) if items else (0, 0)
        self.status = {"checked": time.time(), "ok": not error, "added": added, "removed": removed,
                       "found": len(items), "error": error}

    async def loop(self, session):
        import asyncio
        self.wake = asyncio.Event()
        while True:
            try:
                await self.check(session)
            except Exception as e:  # never stop the loop
                self.status["error"] = repr(e)
            try:
                await asyncio.wait_for(self.wake.wait(), TODDLE_EVERY)
            except asyncio.TimeoutError:
                pass
            self.wake.clear()


def install(router, server, config_dir: Path) -> TaskStore:
    """Adds the task routes to a Musiplex aiohttp router. `server` needs
    authorized(request) and local(request, write=False), as Musiplex's Server has."""
    from aiohttp import web

    store = TaskStore(Path(config_dir))
    server.workload = store

    def with_hubs(snap: dict) -> dict:
        """Other computers that keep the same list (a Mac linked to this server replicates it
        and accepts this server's key), so a phone paired here can sync with either."""
        lead = getattr(server, "leader", None)
        if isinstance(lead, dict) and lead.get("host"):
            snap["hubs"] = [{"host": lead["host"], "port": int(lead.get("http") or 7860), "name": "Mac"}]
        return snap

    async def get_tasks(request):
        if not server.authorized(request):
            return web.Response(status=401)
        return web.json_response(with_hubs(store.snapshot()), headers={"Cache-Control": "no-store"})

    async def post_tasks(request):
        if not server.authorized(request):
            return web.Response(status=401)
        try:
            body = await request.json()
        except ValueError:
            return web.Response(status=400)
        store.merge((body or {}).get("tasks"))
        return web.json_response(with_hubs(store.snapshot()))

    async def local_tasks(request):
        if request.method == "GET":
            if not server.local(request):
                return web.Response(status=403)
            return web.json_response(store.snapshot())
        if not server.local(request, write=True):
            return web.Response(status=403)
        try:
            body = await request.json()
        except ValueError:
            return web.Response(status=400)
        added, removed = store.import_feed(str(body.get("source") or "toddle"), body.get("tasks"),
                                           complete=bool(body.get("complete")))
        live = sum(1 for t in store.tasks.values() if not t["deleted"])
        return web.json_response({"added": added, "removed": removed, "total": live})

    toddle = Toddle(store, Path(config_dir))
    server.toddle = toddle

    def toddle_reply():
        url = (toddle.cfg.get("urls") or [""])[0]
        return web.json_response({"set": bool(url), "link": (url[:28] + "…") if len(url) > 30 else url,
                                  "status": toddle.status, "every": TODDLE_EVERY})

    async def set_toddle(request):
        body = await request.json()
        url = str(body.get("url") or "").strip()
        if url and not url.startswith(("https://", "http://", "webcal://")):
            return web.json_response({"error": "That doesn't look like a calendar link."}, status=400)
        toddle.cfg["urls"] = [url] if url else []
        toddle.save()
        if toddle.wake:
            toddle.wake.set()     # check now
        return toddle_reply()

    async def remote_toddle(request):
        """The same setting from a linked Musiplex (a Mac linked to this hub), with this server's key."""
        if not server.authorized(request):
            return web.Response(status=401)
        if request.method == "POST":
            return await set_toddle(request)
        return toddle_reply()

    async def local_toddle(request):
        """Musiplex Settings: the Toddle link (shown masked) and when it was last checked."""
        if request.method == "POST":
            if not server.local(request, write=True):
                return web.Response(status=403)
            body = await request.json()
            url = str(body.get("url") or "").strip()
            if url and not url.startswith(("https://", "http://", "webcal://")):
                return web.json_response({"error": "That doesn't look like a calendar link."}, status=400)
            toddle.cfg["urls"] = [url] if url else []
            toddle.save()
            if toddle.wake:
                toddle.wake.set()     # check now
        elif not server.local(request):
            return web.Response(status=403)
        url = (toddle.cfg.get("urls") or [""])[0]
        return web.json_response({"set": bool(url), "link": (url[:28] + "…") if len(url) > 30 else url,
                                  "status": toddle.status, "every": TODDLE_EVERY})

    async def local_workload(request):
        """Workload on this computer connects here with no PIN: the hub it should sync with."""
        if not server.local(request):
            return web.Response(status=403)
        return web.json_response({"host": "127.0.0.1", "port": server.http_port, "token": server.token,
                                  "name": server.name, "via": "local", "toddle": bool(toddle.cfg.get("urls"))})

    router.add_route("*", "/local/toddle", local_toddle)
    router.add_route("*", "/toddle", remote_toddle)
    router.add_get("/local/workload", local_workload)
    router.add_get("/tasks", get_tasks)
    router.add_post("/tasks", post_tasks)
    router.add_route("*", "/local/tasks", local_tasks)
    return store


# --------------------------------------------------------------------------- standalone (testing)

if __name__ == "__main__":
    import argparse

    p = argparse.ArgumentParser(description="Workload task store without Musiplex (for testing)")
    p.add_argument("--standalone", action="store_true", required=True)
    p.add_argument("--port", type=int, default=7870)
    p.add_argument("--token", default="test")
    p.add_argument("--pin", default="123456")
    p.add_argument("--dir", default=str(Path.home() / ".config" / "workload-test"))
    a = p.parse_args()

    from aiohttp import web

    class Stub:
        def authorized(self, request):
            return request.query.get("t") == a.token

        def local(self, request, write=False):
            return request.remote in ("127.0.0.1", "::1") and (not write or request.headers.get("X-Musiplex") == "1")

    app = web.Application()
    stub = Stub()

    async def ping(_):
        return web.Response(text="musiplex")

    async def pair(request):
        if request.query.get("pin") != a.pin:
            return web.Response(status=401)
        return web.json_response({"token": a.token, "name": "Workload test server", "hosts": []})

    page = Path(__file__).resolve().parent.parent / "Web" / "workload.html"

    async def index(_):
        return web.FileResponse(page) if page.exists() else web.Response(text="musiplex")

    app.router.add_get("/", index)
    app.router.add_get("/ping", ping)
    app.router.add_get("/pair", pair)
    install(app.router, stub, Path(a.dir))
    print(f"Workload test server on :{a.port} (PIN {a.pin})", flush=True)
    web.run_app(app, port=a.port, print=None)
