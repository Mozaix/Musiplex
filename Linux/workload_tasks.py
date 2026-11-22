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
                                       "done": False, "source": "toddle", "updated": now, "deleted": False}
                    added += 1
                elif not mine["deleted"] and (mine["title"] != title or mine["due"] != due):
                    mine.update(title=title, due=due, updated=now)
            if complete and seen:
                today = datetime.now().strftime("%Y-%m-%d")
                for t in self.tasks.values():
                    if (t["source"] == source and t["id"].startswith(source + "-") and t["id"] not in seen
                            and not t["deleted"] and not t["done"] and (t["due"] or "") >= today):
                        t.update(deleted=True, title="", updated=now)
                        removed += 1
            self._save()
        return added, removed


def install(router, server, config_dir: Path) -> TaskStore:
    """Adds the task routes to a Musiplex aiohttp router. `server` needs
    authorized(request) and local(request, write=False), as Musiplex's Server has."""
    from aiohttp import web

    store = TaskStore(Path(config_dir))
    server.workload = store

    async def get_tasks(request):
        if not server.authorized(request):
            return web.Response(status=401)
        return web.json_response(store.snapshot(), headers={"Cache-Control": "no-store"})

    async def post_tasks(request):
        if not server.authorized(request):
            return web.Response(status=401)
        try:
            body = await request.json()
        except ValueError:
            return web.Response(status=400)
        store.merge((body or {}).get("tasks"))
        return web.json_response(store.snapshot())

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
