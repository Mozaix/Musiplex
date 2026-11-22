#!/usr/bin/env python3
"""Pulls your Toddle deadlines and hands them to Musiplex on this computer.

Run every 15 minutes by the systemd timer that install.sh sets up. Uses Toddle's
own calendar feed (Calendar → Subscribe → Others → copy the iCal link), so it
never needs your Toddle password.

Config: ~/.config/workload/toddle.json
  {
    "ics_urls": ["https://...toddle...ics"],   # one or more iCal links
    "server": "http://127.0.0.1:7860",         # Musiplex on this machine
    "days_ahead": 60,                           # ignore events further out
    "only_keywords": [],                        # keep only titles containing one of these (empty = all)
    "skip_keywords": []                         # drop titles containing any of these
  }

Usage:
  toddle_sync.py            fetch and send
  toddle_sync.py --dry-run  print what would be sent
"""
from __future__ import annotations

import json
import re
import sys
import urllib.request
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

try:
    from zoneinfo import ZoneInfo
except ImportError:  # pragma: no cover
    ZoneInfo = None

CONFIG = Path.home() / ".config" / "workload" / "toddle.json"


def unfold(text: str) -> list[str]:
    """iCal lines that start with a space continue the previous line."""
    out: list[str] = []
    for line in text.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        if line[:1] in (" ", "\t") and out:
            out[-1] += line[1:]
        elif line:
            out.append(line)
    return out


def unescape(v: str) -> str:
    return v.replace("\\n", " ").replace("\\N", " ").replace("\\,", ",").replace("\\;", ";").replace("\\\\", "\\").strip()


def parse_when(params: dict, value: str) -> tuple[datetime | date, bool] | None:
    """Returns (when, has_time). Timed values are converted to this computer's local time."""
    value = value.strip()
    try:
        if params.get("VALUE") == "DATE" or re.fullmatch(r"\d{8}", value):
            return date(int(value[:4]), int(value[4:6]), int(value[6:8])), False
        dt = datetime.strptime(value.rstrip("Z")[:15], "%Y%m%dT%H%M%S")
    except ValueError:
        return None
    if value.endswith("Z"):
        dt = dt.replace(tzinfo=timezone.utc)
    elif "TZID" in params and ZoneInfo is not None:
        try:
            dt = dt.replace(tzinfo=ZoneInfo(params["TZID"].strip('"')))
        except Exception:
            dt = dt.astimezone()  # unknown zone: treat as local
    else:
        dt = dt.astimezone()       # floating time = local
    return dt.astimezone().replace(tzinfo=None), True


def parse_ics(text: str) -> list[dict]:
    events, cur, nested = [], None, 0
    for line in unfold(text):
        if line == "BEGIN:VEVENT" or line == "BEGIN:VTODO":
            cur, nested = {}, 0
        elif line in ("END:VEVENT", "END:VTODO"):
            if cur is not None:
                events.append(cur)
            cur = None
        elif cur is not None and line.startswith("BEGIN:"):
            nested += 1          # a reminder (VALARM) inside the event: its SUMMARY isn't the task's
        elif cur is not None and line.startswith("END:"):
            nested = max(0, nested - 1)
        elif cur is not None and nested == 0 and ":" in line:
            head, value = line.split(":", 1)
            name, *rest = head.split(";")
            params = dict(p.split("=", 1) for p in rest if "=" in p)
            cur[name.upper()] = (params, value)
    return events


def to_tasks(events: list[dict], cfg: dict) -> list[dict]:
    now = datetime.now()
    horizon = now + timedelta(days=int(cfg.get("days_ahead", 60)))
    only = [k.lower() for k in cfg.get("only_keywords") or []]
    skip = [k.lower() for k in cfg.get("skip_keywords") or []]
    tasks = []
    for ev in events:
        if "UID" not in ev or "SUMMARY" not in ev:
            continue
        title = unescape(ev["SUMMARY"][1])
        low = title.lower()
        if only and not any(k in low for k in only):
            continue
        if any(k in low for k in skip):
            continue
        # A to-do's DUE, otherwise the event's start (Toddle puts the deadline there).
        raw = ev.get("DUE") or ev.get("DTSTART")
        when = parse_when(*raw) if raw else None
        if when is None:
            continue
        moment, has_time = when
        as_dt = moment if isinstance(moment, datetime) else datetime.combine(moment, datetime.max.time())
        if as_dt < now - timedelta(days=1) or as_dt > horizon:
            continue
        due = moment.strftime("%Y-%m-%dT%H:%M") if has_time else moment.isoformat()
        uid = re.sub(r"[^A-Za-z0-9_.@-]", "", ev["UID"][1])[:150]
        tasks.append({"sourceId": uid, "title": title, "due": due})
    return tasks


def main() -> int:
    dry = "--dry-run" in sys.argv
    if not CONFIG.exists():
        print(f"No config at {CONFIG}. Run install.sh, or create it with your Toddle iCal link.", file=sys.stderr)
        return 1
    cfg = json.loads(CONFIG.read_text())
    tasks: list[dict] = []
    complete = bool(cfg.get("ics_urls"))   # every feed fetched and looked like a calendar
    for url in cfg.get("ics_urls") or []:
        url = url.replace("webcal://", "https://", 1)
        req = urllib.request.Request(url, headers={"User-Agent": "Workload-Toddle-Sync/1.0"})
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                text = r.read().decode("utf-8", "replace")
        except Exception as e:
            print(f"Couldn't fetch a Toddle feed: {e}", file=sys.stderr)
            complete = False
            continue
        if "BEGIN:VCALENDAR" not in text:
            print("A Toddle link didn't return a calendar (expired link?).", file=sys.stderr)
            complete = False
            continue
        tasks += to_tasks(parse_ics(text), cfg)

    if dry:
        print(json.dumps(tasks, indent=2))
        return 0
    if not tasks:
        print("No upcoming Toddle deadlines found.")
        return 0

    server = cfg.get("server", "http://127.0.0.1:7860").rstrip("/")
    # "complete" lets the server remove upcoming Toddle deadlines that are gone from Toddle.
    body = json.dumps({"source": "toddle", "tasks": tasks, "complete": complete}).encode()
    req = urllib.request.Request(f"{server}/local/tasks", data=body, method="POST",
                                 headers={"Content-Type": "application/json", "X-Musiplex": "1"})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            result = json.loads(r.read())
    except Exception as e:
        print(f"Couldn't reach Musiplex at {server}: {e}", file=sys.stderr)
        return 2
    print(f"Sent {len(tasks)} Toddle deadlines ({result.get('added', 0)} new, {result.get('removed', 0)} removed, "
          f"{result.get('total')} tasks in total).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
