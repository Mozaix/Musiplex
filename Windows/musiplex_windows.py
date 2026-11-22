"""Musiplex for Windows: one Musiplex.exe, like the Mac app.

- The Musiplex window: your library, playlists, For You (Surprise, Guess), Your Taste and
  Discover, version history, settings — and it plays the music itself (or on a phone).
- The notch: a slim bar at the top of the screen. Hover over it for the song and controls,
  a file box, clipboard history, notes, a currency converter and the battery.
- A mini player that stays on top, and a tray icon with play/pause/next.
- The music server for your phones runs inside it (starts at login, no window).

Command line: `--background` (start hidden, what runs at login), `--serve` (the server
only, no windows), `--uninstall` (stop starting at login, remove the Start menu shortcut).

Nothing about you is built in: the pairing PIN, key and name are made on this PC the
first time it starts (kept in %APPDATA%\\Musiplex), and its addresses are looked up live.
"""
from __future__ import annotations

import ctypes
import json
import os
import shutil
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
import webbrowser
from pathlib import Path

PORT = 7860
URL = f"http://127.0.0.1:{PORT}/"
APPDATA = Path(os.environ.get("APPDATA", Path.home())) / "Musiplex"
HOME = Path(os.environ.get("LOCALAPPDATA", Path.home())) / "Musiplex"
EXE = HOME / "Musiplex.exe"
LOG = APPDATA / "server.log"
PREFS = APPDATA / "windows.json"
RUN_KEY = r"Software\Microsoft\Windows\CurrentVersion\Run"
SHORTCUT = Path(os.environ.get("APPDATA", Path.home())) / "Microsoft/Windows/Start Menu/Programs/Musiplex.lnk"
NO_WINDOW = 0x08000000
BUNDLE = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parent))
# Left by the installer (Inno Setup's uninstaller sits next to the apps), so its choices win.
INSTALLED = Path(os.environ.get("LOCALAPPDATA", Path.home())) / "Musiplex Apps" / "unins000.exe"


# ----------------------------------------------------------------------------- helpers

def running() -> bool:
    try:
        with urllib.request.urlopen(URL + "ping", timeout=1.5) as r:
            return r.read().startswith(b"musiplex")
    except Exception:
        return False


def local_post(path: str, body: dict):
    try:
        req = urllib.request.Request(URL + path.lstrip("/"), data=json.dumps(body).encode(), method="POST",
                                     headers={"Content-Type": "application/json", "X-Musiplex": "1"})
        urllib.request.urlopen(req, timeout=3).read()
    except Exception:
        pass


def run_key_set() -> bool:
    try:
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY) as k:
            winreg.QueryValueEx(k, "Musiplex")
            return True
    except OSError:
        return False


def prefs() -> dict:
    """Notch on by default. Start at login: what you chose in Settings, else whatever the
    installer set up (or on for a plain Musiplex.exe run without the installer)."""
    try:
        p = json.loads(PREFS.read_text())
    except Exception:
        p = {}
    startup = p["startup"] if "startup" in p else (run_key_set() or not INSTALLED.exists())
    return {"notch": p.get("notch", True), "startup": startup}


def save_prefs(p: dict):
    APPDATA.mkdir(parents=True, exist_ok=True)
    PREFS.write_text(json.dumps(p))


def set_startup(on: bool, target: Path):
    try:
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY, 0, winreg.KEY_SET_VALUE) as k:
            if on:
                winreg.SetValueEx(k, "Musiplex", 0, winreg.REG_SZ, f'"{target}" --background')
            else:
                try:
                    winreg.DeleteValue(k, "Musiplex")
                except OSError:
                    pass
    except OSError:
        pass


def install() -> Path:
    """Copies this exe to a fixed place (also how an update installs), sets up login start and the shortcut."""
    me = Path(sys.executable)
    HOME.mkdir(parents=True, exist_ok=True)
    if getattr(sys, "frozen", False) and me.resolve() != EXE.resolve():
        try:
            shutil.copy2(me, EXE)
        except OSError:
            pass
    target = EXE if EXE.exists() else me
    set_startup(prefs()["startup"], target)
    ps = ("$s=(New-Object -ComObject WScript.Shell).CreateShortcut($env:LNK);"
          "$s.TargetPath=$env:EXE;$s.IconLocation=$env:EXE+',0';$s.Description='Musiplex';$s.Save()")
    try:
        subprocess.run(["powershell", "-NoProfile", "-WindowStyle", "Hidden", "-Command", ps],
                       env={**os.environ, "LNK": str(SHORTCUT), "EXE": str(target)}, creationflags=NO_WINDOW, timeout=20)
    except Exception:
        pass
    return target


def uninstall():
    set_startup(False, EXE)
    SHORTCUT.unlink(missing_ok=True)


def log_to_file():
    APPDATA.mkdir(parents=True, exist_ok=True)
    f = open(LOG, "a", buffering=1, encoding="utf-8")
    sys.stdout = sys.stderr = f   # a windowed exe has no console


# ----------------------------------------------------------------------------- clipboard (Win32)

user32 = ctypes.windll.user32 if os.name == "nt" else None
kernel32 = ctypes.windll.kernel32 if os.name == "nt" else None
if user32:
    user32.GetClipboardData.restype = ctypes.c_void_p
    user32.SetClipboardData.argtypes = [ctypes.c_uint, ctypes.c_void_p]
    kernel32.GlobalLock.restype = ctypes.c_void_p
    kernel32.GlobalLock.argtypes = [ctypes.c_void_p]
    kernel32.GlobalUnlock.argtypes = [ctypes.c_void_p]
    kernel32.GlobalAlloc.restype = ctypes.c_void_p
    kernel32.GlobalAlloc.argtypes = [ctypes.c_uint, ctypes.c_size_t]
CF_UNICODETEXT = 13
clips: list[str] = []


def clip_read() -> str | None:
    if not user32 or not user32.OpenClipboard(None):
        return None
    try:
        h = user32.GetClipboardData(CF_UNICODETEXT)
        if not h:
            return None
        p = kernel32.GlobalLock(h)
        try:
            return ctypes.wstring_at(p) if p else None
        finally:
            kernel32.GlobalUnlock(h)
    finally:
        user32.CloseClipboard()


def clip_write(text: str):
    if not user32 or not user32.OpenClipboard(None):
        return
    try:
        user32.EmptyClipboard()
        data = ctypes.create_unicode_buffer(text)
        size = ctypes.sizeof(data)
        h = kernel32.GlobalAlloc(0x0002, size)
        p = kernel32.GlobalLock(h)
        ctypes.memmove(p, data, size)
        kernel32.GlobalUnlock(h)
        user32.SetClipboardData(CF_UNICODETEXT, h)
    finally:
        user32.CloseClipboard()


def watch_clipboard():
    """Clipboard history for the notch (kept in memory only, last 25 texts)."""
    last = None
    while True:
        time.sleep(1)
        try:
            n = user32.GetClipboardSequenceNumber()
            if n == last:
                continue
            last = n
            t = clip_read()
            if t and t.strip():
                if t in clips:
                    clips.remove(t)
                clips.insert(0, t[:5000])
                del clips[25:]
        except Exception:
            pass


# ----------------------------------------------------------------------------- windows

windows: dict = {}
screen_w = user32.GetSystemMetrics(0) if user32 else 1920
NOTCH_SMALL, NOTCH_IDLE, NOTCH_OPEN = (200, 32), (150, 6), (680, 250)
MINI, MINI_QUEUE = (360, 168), (360, 480)


class Api:
    """Called from the Musiplex page (window.pywebview.api)."""

    def notch(self, open_: bool, idle_hidden: bool = False):
        w = windows.get("notch")
        if not w:
            return
        size = NOTCH_OPEN if open_ else NOTCH_IDLE if idle_hidden else NOTCH_SMALL
        w.resize(*size)
        w.move(int((screen_w - size[0]) / 2), 0)

    def show_main(self):
        w = windows.get("main")
        if w:
            w.show()
            w.restore()

    def toggle_mini(self):
        import webview
        w = windows.get("mini")
        if w is None:
            windows["mini"] = webview.create_window(
                "Musiplex Mini Player", URL + "app?mode=mini", width=MINI[0], height=MINI[1], on_top=True,
                resizable=False, background_color="#121218", js_api=self, x=screen_w - MINI[0] - 24, y=60)
            windows["mini"].events.closed += lambda: windows.pop("mini", None)
            main = windows.get("main")
            if main:
                main.hide()
        else:
            w.destroy()
            windows.pop("mini", None)

    def mini_queue(self, open_: bool):
        w = windows.get("mini")
        if w:
            w.resize(*(MINI_QUEUE if open_ else MINI))

    def clipboard(self):
        return list(clips)

    def copy(self, text: str):
        clip_write(text)
        if text in clips:
            clips.remove(text)
        clips.insert(0, text)

    def pick_folder(self):
        import webview
        w = windows.get("main")
        r = w.create_file_dialog(webview.FOLDER_DIALOG) if w else None
        return r[0] if r else None

    def save_text(self, name: str, text: str):
        folder = Path.home() / "Downloads"
        folder.mkdir(exist_ok=True)
        path = folder / os.path.basename(name)
        path.write_text(text, encoding="utf-8-sig")
        return str(path)

    def open_url(self, url: str):
        if url.startswith(("https://", "http://")):
            webbrowser.open(url)

    def tasks(self):
        """Workload's school tasks for the notch Calendar: from the server Workload syncs with
        (%APPDATA%\\Workload\\sync.json), else this PC's own Musiplex server."""
        sources = []
        try:
            sync = json.loads((Path(os.environ.get("APPDATA", Path.home())) / "Workload" / "sync.json").read_text())
            host, token = str(sync.get("host") or ""), str(sync.get("token") or "")
            if host and token:
                q = urllib.parse.urlencode({"t": token})
                sources.append(f"http://{host}:{PORT}/tasks?{q}")
        except Exception:
            pass
        sources.append(URL + "local/tasks")
        for url in sources:
            try:
                with urllib.request.urlopen(url, timeout=5) as r:
                    return json.loads(r.read())
            except Exception:
                continue
        return None

    def workload_installed(self):
        """Workload was ticked in the installer (or added later)."""
        return (Path(os.environ.get("LOCALAPPDATA", Path.home())) / "Workload" / "Workload.exe").exists()

    def get_prefs(self):
        return prefs()

    def set_pref(self, key: str, value: bool):
        p = prefs()
        p[key] = bool(value)
        save_prefs(p)
        if key == "startup":
            set_startup(p["startup"], EXE if EXE.exists() else Path(sys.executable))
        if key == "notch":
            if value and "notch" not in windows:
                make_notch(self)
            elif not value and "notch" in windows:
                windows.pop("notch").destroy()


def make_notch(api: Api):
    import webview
    w, h = NOTCH_SMALL
    windows["notch"] = webview.create_window(
        "Musiplex Notch", URL + "app?mode=notch", width=w, height=h, x=int((screen_w - w) / 2), y=0,
        frameless=True, on_top=True, resizable=False, easy_drag=False, focus=False, shadow=False,
        background_color="#000000", js_api=api)


def tray(api: Api):
    """The tray icon: open, mini player, play/pause, next, previous, quit."""
    try:
        import pystray
        from PIL import Image
    except Exception:
        return
    cmd = lambda action: (lambda *_: local_post("/local/cmd", {"action": action}))

    def quit_all(icon, _):
        icon.stop()
        for w in list(windows.values()):
            try:
                w.destroy()
            except Exception:
                pass
        os._exit(0)

    menu = pystray.Menu(
        pystray.MenuItem("Open Musiplex", lambda *_: api.show_main(), default=True),
        pystray.MenuItem("Mini Player", lambda *_: api.toggle_mini()),
        pystray.Menu.SEPARATOR,
        pystray.MenuItem("Play / Pause", cmd("toggle")),
        pystray.MenuItem("Next", cmd("next")),
        pystray.MenuItem("Previous", cmd("prev")),
        pystray.Menu.SEPARATOR,
        pystray.MenuItem("Quit Musiplex", quit_all),
    )
    pystray.Icon("Musiplex", Image.open(BUNDLE / "musiplex.png"), "Musiplex", menu).run_detached()


# ----------------------------------------------------------------------------- start

def start_server(argv: list[str]):
    import asyncio
    sys.path.insert(0, str(BUNDLE))
    import musiplex_server
    parser_args = musiplex_server.build_parser().parse_args(argv)
    srv = musiplex_server.Server(parser_args)

    def run():
        try:
            asyncio.run(srv.run())
        except Exception as e:
            print("server stopped:", repr(e), flush=True)
    threading.Thread(target=run, daemon=True, name="server").start()
    return srv


def main():
    args = sys.argv[1:]
    if "--uninstall" in args:
        return uninstall()
    if "--serve" in args:       # the server alone, no windows
        args.remove("--serve")
        log_to_file()
        sys.path.insert(0, str(BUNDLE))
        import musiplex_server
        sys.argv = [sys.argv[0], *args]
        return musiplex_server.main()
    background = "--background" in args
    args = [a for a in args if a != "--background"]
    if running():               # already open: bring its window forward
        if not background:
            local_post("/local/ui", {"show": "main"})
        return
    target = install()
    log_to_file()
    srv = start_server(args)
    for _ in range(60):
        if running():
            break
        time.sleep(0.25)

    import webview
    api = Api()
    srv.ui_hook = lambda what: api.toggle_mini() if what == "mini" else api.show_main()
    main_win = webview.create_window("Musiplex", URL + "app", width=1180, height=760, min_size=(420, 520),
                                     hidden=background, background_color="#07070b", js_api=api)
    windows["main"] = main_win

    def closing():
        main_win.hide()          # like the Mac: closing the window keeps Musiplex (and the music) going
        return False
    main_win.events.closing += closing
    if prefs()["notch"]:
        make_notch(api)
    threading.Thread(target=watch_clipboard, daemon=True).start()
    tray(api)
    webview.start(private_mode=False, storage_path=str(APPDATA / "window"))
    os._exit(0)


if __name__ == "__main__":
    main()
