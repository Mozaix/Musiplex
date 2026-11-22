"""Workload for Windows: the same app as on iPhone and Mac, as one Workload.exe.

- The Workload window: Tasks, Entries and Sync (Web/workload.html).
- A tray icon (next to the clock). Click it for the companion: what Musiplex is
  playing, your next tasks and a quick-add box, like the Mac menu bar.
- Starts with Windows (in the tray, no window). Closing the window keeps the tray.

Tasks sync with your Musiplex server (the CachyOS laptop) over the Wi‑Fi, found
automatically with Bonjour, or over Tailscale when you're away.

Command line: `--background` (tray only, what runs at login), `--uninstall`
(stop starting at login, remove the Start menu shortcut), `--selftest` (open the
page hidden and exit 0 if it works; used by the release build).

Installed at %LOCALAPPDATA%\\Workload\\Workload.exe by the Musiplex/Workload installer.

Everything is kept in %APPDATA%\\Workload\\state.json.
"""
from __future__ import annotations

import json
import os
import socket
import sys
import threading
import urllib.error
import urllib.request
from pathlib import Path

APP = "Workload"
DATA = Path(os.environ.get("APPDATA", Path.home())) / APP
STATE = DATA / "state.json"
BUNDLE = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parent))
SINGLE_PORT = 7879                 # one Workload at a time; a second launch shows the first
RUN_KEY = r"Software\Microsoft\Windows\CurrentVersion\Run"
SHORTCUT = Path(os.environ.get("APPDATA", Path.home())) / "Microsoft/Windows/Start Menu/Programs/Workload.lnk"
WINDOWS = sys.platform == "win32"


def page_path() -> Path:
    for p in (BUNDLE / "workload.html", BUNDLE.parent / "Web" / "workload.html"):
        if p.exists():
            return p
    raise SystemExit("workload.html is missing")


def icon_path() -> Path | None:
    for p in (BUNDLE / "workload.png", BUNDLE.parent / "Art" / "icon-1024.png"):
        if p.exists():
            return p
    return None


# ----------------------------------------------------------------------------- Bonjour

class Finder:
    """Musiplex servers on the Wi‑Fi (_musiplex._tcp), kept up to date in the background."""

    def __init__(self):
        self.servers: dict[str, dict] = {}
        self.zc = None
        try:
            from zeroconf import ServiceBrowser, Zeroconf
            self.zc = Zeroconf()
            ServiceBrowser(self.zc, "_musiplex._tcp.local.", handlers=[self.on_change])
        except Exception as e:  # no zeroconf / no network: typing an address still works
            print("Bonjour unavailable:", e)

    def on_change(self, zeroconf, service_type, name, state_change):
        from zeroconf import ServiceStateChange
        short = name.replace("." + service_type, "")
        if state_change is ServiceStateChange.Removed:
            self.servers.pop(short, None)
            return
        info = zeroconf.get_service_info(service_type, name, 3000)
        if not info:
            return
        props = {k.decode(): (v.decode() if isinstance(v, bytes) else v) for k, v in (info.properties or {}).items()}
        ip = props.get("ip") or (info.parsed_addresses()[0] if info.parsed_addresses() else "")
        if ip:
            self.servers[short] = {"name": short, "ip": ip, "http": int(props.get("http") or 7860),
                                   "ws": int(props.get("ws") or 7861)}

    def list(self) -> list[dict]:
        return list(self.servers.values())


# ----------------------------------------------------------------------------- the page's API

class Api:
    """What workload.html calls through window.pywebview.api."""

    def __init__(self, app: "App"):
        self._app = app

    def request(self, method: str, url: str, body: str | None = None) -> dict:
        data = body.encode() if body else None
        req = urllib.request.Request(url, data=data, method=method,
                                     headers={"Content-Type": "application/json"} if data else {})
        try:
            with urllib.request.urlopen(req, timeout=6) as r:
                return {"status": r.status, "text": r.read().decode("utf-8", "replace")}
        except urllib.error.HTTPError as e:
            return {"status": e.code, "text": e.read().decode("utf-8", "replace")}
        except Exception as e:
            return {"status": -1, "text": str(e)}

    def load(self) -> str | None:
        try:
            return STATE.read_text(encoding="utf-8")
        except OSError:
            return None

    def save(self, text: str) -> None:
        DATA.mkdir(parents=True, exist_ok=True)
        tmp = STATE.with_suffix(".tmp")
        tmp.write_text(text, encoding="utf-8")
        os.replace(tmp, STATE)
        write_sync_file(text)
        self._app.saved(self)

    def discover(self) -> list[dict]:
        return self._app.finder.list()

    def musiplex_local(self) -> dict | None:
        """Musiplex running on this PC: its key, from its local-only endpoint."""
        try:
            with urllib.request.urlopen("http://127.0.0.1:7860/local/token", timeout=1.5) as r:
                info = json.loads(r.read())
            return {"token": info.get("token"), "name": info.get("name"), "http": 7860, "ws": 7861}
        except Exception:
            return None

    def open_main(self) -> None:
        self._app.show_main()

    def quit(self) -> None:
        self._app.quit()


# ----------------------------------------------------------------------------- the app

class App:
    def __init__(self, background: bool):
        import webview
        self.webview = webview
        self.finder = Finder()
        url = page_path().as_uri() + "?shell=pywebview"
        self.main_api, self.comp_api = Api(self), Api(self)
        self.main = webview.create_window(APP, url, width=1080, height=720, min_size=(380, 480),
                                          hidden=background, js_api=self.main_api, background_color="#FFFFFF")
        self.main.events.closing += self.on_close_main
        self.comp = webview.create_window(f"{APP} companion", url + "#companion", width=340, height=560,
                                          frameless=True, on_top=True, hidden=True, easy_drag=True,
                                          js_api=self.comp_api, background_color="#FFFFFF")
        self.comp.events.closing += self.on_close_comp
        self.comp_visible = False
        self.quitting = False
        self.tray = None

    # Two windows share one state file; when one saves, the other re-reads it.
    def saved(self, who: Api):
        other = self.comp if who is self.main_api else self.main
        try:
            other.evaluate_js("window.workloadReload && window.workloadReload()")
        except Exception:
            pass

    def on_close_main(self):
        if self.quitting:
            return True
        self.main.hide()          # keep running in the tray
        return False

    def on_close_comp(self):
        if self.quitting:
            return True
        self.comp.hide()
        self.comp_visible = False
        return False

    def show_main(self):
        self.main.show()
        self.main.restore()

    def toggle_companion(self):
        if self.comp_visible:
            self.comp.hide()
            self.comp_visible = False
            return
        try:   # bottom-right, above the taskbar, next to the tray
            screen = self.webview.screens[0]
            self.comp.move(screen.width - 340 - 12, screen.height - 560 - 56)
        except Exception:
            pass
        self.comp.show()
        self.comp_visible = True
        try:
            self.comp.evaluate_js("window.workloadResume && window.workloadResume()")
        except Exception:
            pass

    def quit(self):
        self.quitting = True
        if self.tray:
            self.tray.stop()
        for w in (self.comp, self.main):
            try:
                w.destroy()
            except Exception:
                pass

    def start_tray(self):
        if not WINDOWS:          # pystray's own loop only works next to pywebview on Windows
            return
        try:
            import pystray
            from PIL import Image
        except ImportError:
            return
        p = icon_path()
        image = Image.open(p) if p else Image.new("RGB", (64, 64), "#191919")
        menu = pystray.Menu(
            pystray.MenuItem("Companion", lambda *_: self.toggle_companion(), default=True),
            pystray.MenuItem("Open Workload", lambda *_: self.show_main()),
            pystray.Menu.SEPARATOR,
            pystray.MenuItem("Play / Pause", lambda *_: musiplex_cmd("toggle")),
            pystray.MenuItem("Next", lambda *_: musiplex_cmd("next")),
            pystray.MenuItem("Previous", lambda *_: musiplex_cmd("prev")),
            pystray.Menu.SEPARATOR,
            pystray.MenuItem("Quit Workload", lambda *_: self.quit()),
        )
        self.tray = pystray.Icon(APP, image, APP, menu)
        self.tray.run_detached()

    def run(self):
        threading.Thread(target=single_instance_server, args=(self,), daemon=True).start()
        self.webview.start(self.start_tray, private_mode=False, storage_path=str(DATA / "webview"))


def write_sync_file(state_text: str):
    """%APPDATA%\\Workload\\sync.json: the server and key Workload syncs with, so the
    Musiplex notch Calendar on this PC shows the same list."""
    try:
        prefs = json.loads(state_text).get("prefs") or {}
    except ValueError:
        return
    path = DATA / "sync.json"
    if prefs.get("token") and prefs.get("serverHost"):
        info = {"host": prefs["serverHost"], "port": prefs.get("serverPort") or 7860, "token": prefs["token"],
                "away": prefs.get("awayHost") or ""}
        try:
            if path.exists() and json.loads(path.read_text()) == info:
                return
        except (OSError, ValueError):
            pass
        path.write_text(json.dumps(info), encoding="utf-8")
    elif path.exists():
        path.unlink()


def musiplex_cmd(action: str):
    """Play/pause/next on Musiplex on this PC (its local-only command endpoint)."""
    try:
        req = urllib.request.Request("http://127.0.0.1:7860/local/cmd", data=json.dumps({"action": action}).encode(),
                                     method="POST", headers={"Content-Type": "application/json", "X-Musiplex": "1"})
        urllib.request.urlopen(req, timeout=2).read()
    except Exception:
        pass


# ----------------------------------------------------------------------------- one copy, login item

def single_instance_server(app: App):
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        srv.bind(("127.0.0.1", SINGLE_PORT))
    except OSError:
        return
    srv.listen(2)
    while True:
        conn, _ = srv.accept()
        conn.close()
        app.show_main()


def already_running() -> bool:
    try:
        with socket.create_connection(("127.0.0.1", SINGLE_PORT), timeout=0.5):
            return True          # it shows its window when we connect
    except OSError:
        return False


def set_login_item(on: bool):
    if not WINDOWS:
        return
    import winreg
    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY, 0, winreg.KEY_SET_VALUE) as k:
        if on:
            exe = sys.executable if getattr(sys, "frozen", False) else f'"{sys.executable}" "{Path(__file__).resolve()}"'
            winreg.SetValueEx(k, APP, 0, winreg.REG_SZ, f'"{exe}" --background' if getattr(sys, "frozen", False) else f"{exe} --background")
        else:
            try:
                winreg.DeleteValue(k, APP)
            except FileNotFoundError:
                pass


class SelftestApi:
    """What the page needs, with nothing saved and no network."""
    def request(self, method, url, body=None): return {"status": -1, "text": "selftest"}
    def load(self): return None
    def save(self, text): pass
    def discover(self): return []
    def musiplex_local(self): return None
    def open_main(self): pass
    def quit(self): pass


def selftest() -> int:
    """For the release build: open the page hidden, check it started, exit 0 (or 1)."""
    import webview
    result = {"ok": False}
    win = webview.create_window(APP, page_path().as_uri() + "?shell=pywebview", hidden=True, js_api=SelftestApi())

    def check():
        import time
        for _ in range(60):
            time.sleep(0.5)
            try:
                if win.evaluate_js("typeof parseEntry === 'function' && parseEntry('Essay - Dec 3').title === 'Essay'"):
                    result["ok"] = True
                    break
            except Exception:
                pass
        print("selftest", "passed" if result["ok"] else "FAILED", flush=True)
        os._exit(0 if result["ok"] else 1)   # the window loop doesn't always end on its own

    webview.start(check, private_mode=True)
    return 1


def main():
    if "--selftest" in sys.argv:
        sys.exit(selftest())
    if "--uninstall" in sys.argv:
        set_login_item(False)
        SHORTCUT.unlink(missing_ok=True)
        print("Workload won't start with Windows any more.")
        return
    if already_running():
        return
    DATA.mkdir(parents=True, exist_ok=True)
    try:
        set_login_item(True)
    except Exception as e:
        print("Couldn't add the login item:", e)
    App(background="--background" in sys.argv).run()


if __name__ == "__main__":
    main()
