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
        size = NOTCH_OPEN if open_ else NOTCH_IDLE if idle_hidden else NOTCH_SMALL
        notch_shape.go(size)

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

    def open_browser(self, url: str = ""):
        browser.open(url or None)

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


class NotchShape:
    """Moves and sizes the notch natively, like the Mac's: always centred on the main screen
    (in real pixels, so display scaling can't push it off-centre), size and position changed
    in one step, eased open and closed, with rounded bottom corners."""
    SWP = 0x0010 | 0x0040 | 0x0004          # NOACTIVATE | SHOWWINDOW | NOZORDER
    TOPMOST = -1

    def __init__(self):
        self.hwnd = None
        self.size = NOTCH_SMALL               # logical (96-dpi) size
        self.target = NOTCH_SMALL
        self.lock = threading.Lock()
        self.anim = None

    def attach(self, window):
        try:
            self.hwnd = int(window.native.Handle.ToInt64())
        except Exception:
            self.hwnd = None
        self.apply(self.size)

    def screen(self):
        """(left, top, width, scale) of the primary monitor, in physical pixels."""
        try:
            class RECT(ctypes.Structure):
                _fields_ = [("l", ctypes.c_long), ("t", ctypes.c_long), ("r", ctypes.c_long), ("b", ctypes.c_long)]

            class MONITORINFO(ctypes.Structure):
                _fields_ = [("cb", ctypes.c_ulong), ("rcMonitor", RECT), ("rcWork", RECT), ("flags", ctypes.c_ulong)]

            class POINT(ctypes.Structure):
                _fields_ = [("x", ctypes.c_long), ("y", ctypes.c_long)]
            user32.MonitorFromPoint.restype = ctypes.c_void_p
            mon = user32.MonitorFromPoint(POINT(0, 0), 1)            # MONITOR_DEFAULTTOPRIMARY
            info = MONITORINFO(); info.cb = ctypes.sizeof(MONITORINFO)
            user32.GetMonitorInfoW(ctypes.c_void_p(mon), ctypes.byref(info))
            dpi = user32.GetDpiForWindow(self.hwnd) if self.hwnd else 96
            r = info.rcMonitor
            return r.l, r.t, r.r - r.l, (dpi or 96) / 96
        except Exception:
            return 0, 0, screen_w, 1.0

    def apply(self, size):
        if not (self.hwnd and user32):
            w = windows.get("notch")
            if w:   # fallback: pywebview's own (two-step) move
                w.resize(int(size[0]), int(size[1]))
                w.move(int((screen_w - size[0]) / 2), 0)
            return
        left, top, width, scale = self.screen()
        w, h = max(1, round(size[0] * scale)), max(1, round(size[1] * scale))
        x = left + (width - w) // 2
        user32.SetWindowPos(ctypes.c_void_p(self.hwnd), ctypes.c_void_p(self.TOPMOST), x, top, w, h, self.SWP & ~0x0004)
        radius = round(16 * scale) if size[1] > 12 else round(3 * scale)
        gdi = ctypes.windll.gdi32
        gdi.CreateRoundRectRgn.restype = ctypes.c_void_p
        rgn = gdi.CreateRoundRectRgn(0, -radius, w + 1, h + 1, radius * 2, radius * 2)   # square top, round bottom
        user32.SetWindowRgn(ctypes.c_void_p(self.hwnd), ctypes.c_void_p(rgn), True)

    def go(self, target):
        """Ease from the current size to `target` (~0.2 s, quick start and soft landing)."""
        with self.lock:
            self.target = tuple(target)
            if self.anim and self.anim.is_alive():
                return                          # the running animation picks up the new target
            self.anim = threading.Thread(target=self._animate, daemon=True)
            self.anim.start()

    def _animate(self):
        while True:
            with self.lock:
                start, end = self.size, self.target
            if start == end:
                return
            frames = 14
            for i in range(1, frames + 1):
                with self.lock:
                    if self.target != end:      # changed mid-way: restart from here
                        break
                t = i / frames
                ease = 1 - (1 - t) ** 3
                cur = (start[0] + (end[0] - start[0]) * ease, start[1] + (end[1] - start[1]) * ease)
                self.apply(cur)
                with self.lock:
                    self.size = cur if i < frames else end
                time.sleep(0.014)


notch_shape = NotchShape()


# ----------------------------------------------------------------------------- built-in browser

FLOATERS = Path(os.environ.get("MUSIPLEX_FLOATERS", Path.home() / "Documents" / "Songs" / "Floaters"))
AD_HOSTS = (
    "doubleclick.net", "googlesyndication.com", "googleadservices.com", "google-analytics.com",
    "googletagmanager.com", "googletagservices.com", "adservice.google.com", "amazon-adsystem.com", "adnxs.com",
    "adsrvr.org", "taboola.com", "outbrain.com", "criteo.com", "criteo.net", "pubmatic.com", "rubiconproject.com",
    "openx.net", "casalemedia.com", "scorecardresearch.com", "quantserve.com", "moatads.com", "adform.net",
    "smartadserver.com", "yieldmo.com", "media.net", "zedo.com", "propellerads.com", "popads.net", "popcash.net",
    "adsterra.com", "exoclick.com", "juicyads.com", "hilltopads.net", "onclickads.net", "trafficjunky.net", "mgid.com",
    "revcontent.com", "hotjar.com", "mouseflow.com", "fullstory.com", "facebook.net", "ads-twitter.com",
    "analytics.twitter.com", "bat.bing.com", "clarity.ms", "adcolony.com", "applovin.com", "unityads.unity3d.com",
    "chartbeat.com", "newrelic.com", "nr-data.net", "segment.io", "mixpanel.com", "branch.io", "onesignal.com",
    "pushwoosh.com", "a-ads.com", "coinzilla.com", "bidvertiser.com", "adcash.com")


def blocked(host: str) -> bool:
    host = (host or "").lower()
    return any(host == d or host.endswith("." + d) for d in AD_HOSTS)


class Browser:
    """Musiplex's built-in browser (like the Mac's): back, forward, reload, an address bar,
    ad and tracker blocking, and downloads saved straight to Documents/Songs/Floaters, so
    music you download shows up in Floating. It's a native window with Microsoft Edge's
    engine (WebView2, already part of Musiplex.exe), and it only exists while it's open."""

    def __init__(self):
        self.form = None
        self.on_ready = None          # selftest hook

    def open(self, url: str | None = None):
        main = windows.get("main") or windows.get("notch")
        if not main:
            return
        from System import Action
        main.native.BeginInvoke(Action(lambda: self._open(url)))

    def _open(self, url):
        import clr  # noqa: F401  (pythonnet, loaded by pywebview)
        clr.AddReference("System.Windows.Forms")
        clr.AddReference("System.Drawing")
        from System import Uri, EventHandler
        from System.Drawing import Color, Font, Size, Point, FontStyle, ContentAlignment
        from System.Windows.Forms import (Form, Panel, TextBox, Button, DockStyle, FlatStyle, Keys,
                                          AnchorStyles, Label, Padding, FormStartPosition, BorderStyle)
        from Microsoft.Web.WebView2.WinForms import WebView2, CoreWebView2CreationProperties
        if self.form is not None and not self.form.IsDisposed:
            self.form.Show(); self.form.Activate()
            if url:
                self._go(url)
            return
        p = prefs_raw()
        ads_on = p.get("adblock", True)
        dark, panel, text = Color.FromArgb(18, 18, 24), Color.FromArgb(28, 28, 34), Color.FromArgb(240, 240, 245)
        form = Form()
        form.Text = "Musiplex Browser"
        form.Size = Size(1200, 820)
        form.StartPosition = FormStartPosition.CenterScreen
        form.BackColor = dark
        bar = Panel(); bar.Dock = DockStyle.Top; bar.Height = 46; bar.BackColor = panel; bar.Padding = Padding(8, 8, 8, 8)

        def button(label, x, width=34, tip=""):
            b = Button(); b.Text = label; b.Location = Point(x, 8); b.Size = Size(width, 30)
            b.FlatStyle = FlatStyle.Flat; b.FlatAppearance.BorderSize = 0
            b.BackColor = Color.FromArgb(44, 44, 52); b.ForeColor = text
            b.Font = Font("Segoe UI", 10.5); b.TabStop = False
            bar.Controls.Add(b)
            return b
        back, fwd, reload = button("‹", 8), button("›", 46), button("⟳", 84)
        address = TextBox(); address.Location = Point(126, 11); address.Height = 26
        address.Font = Font("Segoe UI", 10.5); address.BackColor = Color.FromArgb(40, 40, 48); address.ForeColor = text
        address.BorderStyle = getattr(BorderStyle, "None")
        address.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right
        bar.Controls.Add(address)
        ads = button("Ads blocked" if ads_on else "Ads allowed", 0, 104)
        floaters = button("Floaters", 0, 82)
        status = Label(); status.ForeColor = Color.FromArgb(163, 138, 255); status.AutoSize = False
        status.Size = Size(220, 30); status.TextAlign = ContentAlignment.MiddleLeft
        status.Font = Font("Segoe UI", 9, FontStyle.Bold)
        bar.Controls.Add(status)

        def layout(*_):
            w = bar.ClientSize.Width
            floaters.Location = Point(w - 90, 8)
            ads.Location = Point(w - 200, 8)
            status.Location = Point(w - 430, 8)
            address.Width = max(120, w - 126 - 440)
        bar.Resize += EventHandler(layout)

        view = WebView2(); view.Dock = DockStyle.Fill
        props = CoreWebView2CreationProperties()
        props.UserDataFolder = str(APPDATA / "browser")
        view.CreationProperties = props
        form.Controls.Add(view)
        form.Controls.Add(bar)
        self.form, self.view, self.address, self.status = form, view, address, status

        def ready(sender, e):
            core = view.CoreWebView2
            if core is None:
                return
            FLOATERS.mkdir(parents=True, exist_ok=True)
            try:
                core.Profile.DefaultDownloadFolderPath = str(FLOATERS)     # downloads → Floaters
            except Exception:
                pass
            try:
                from Microsoft.Web.WebView2.Core import CoreWebView2WebResourceContext
                core.AddWebResourceRequestedFilter("*", CoreWebView2WebResourceContext.All)

                def request(s, ev):
                    if prefs_raw().get("adblock", True) and blocked(Uri(ev.Request.Uri).Host):
                        ev.Response = core.Environment.CreateWebResourceResponse(None, 403, "Blocked", "")
                core.WebResourceRequested += request
            except Exception:
                pass

            def navigated(s, ev):
                address.Text = core.Source
                form.Text = (core.DocumentTitle or "Musiplex Browser") + " — Musiplex"
                back.Enabled, fwd.Enabled = core.CanGoBack, core.CanGoForward
                save_pref_raw("browser_last", core.Source)
            core.NavigationCompleted += navigated

            def download(s, ev):
                op = ev.DownloadOperation
                name = os.path.basename(op.ResultFilePath)
                status.Text = f"Downloading {name}…"

                def changed(s2, e2):
                    if str(op.State) == "Completed":
                        status.Text = f"Saved to Floaters: {name}"
                    elif str(op.State) == "Interrupted":
                        status.Text = f"Download stopped: {name}"
                op.StateChanged += changed
            try:
                core.DownloadStarting += download
            except Exception:
                pass
            self._go(url or p.get("browser_last") or "https://www.google.com")
            if self.on_ready:
                self.on_ready(True)
        view.CoreWebView2InitializationCompleted += ready

        def go_typed(sender, e):
            if e.KeyCode == Keys.Enter:
                e.SuppressKeyPress = True
                self._go(address.Text)
        address.KeyDown += go_typed
        back.Click += lambda s, e: view.CoreWebView2 and view.CoreWebView2.GoBack()
        fwd.Click += lambda s, e: view.CoreWebView2 and view.CoreWebView2.GoForward()
        reload.Click += lambda s, e: view.CoreWebView2 and view.CoreWebView2.Reload()

        def toggle_ads(s, e):
            on = not prefs_raw().get("adblock", True)
            save_pref_raw("adblock", on)
            ads.Text = "Ads blocked" if on else "Ads allowed"
            if view.CoreWebView2:
                view.CoreWebView2.Reload()
        ads.Click += toggle_ads
        floaters.Click += lambda s, e: local_post("/local/open", {"what": "floaters"})

        def closed(s, e):
            self.form = None   # gone: its memory is freed
        form.FormClosed += closed
        layout()
        form.Show()
        view.EnsureCoreWebView2Async(None)

    def _go(self, text):
        text = (text or "").strip()
        if not text:
            return
        if "://" not in text:
            text = ("https://" + text) if ("." in text and " " not in text) else \
                "https://www.google.com/search?q=" + urllib.parse.quote_plus(text)
        try:
            self.view.CoreWebView2.Navigate(text)
        except Exception:
            try:
                from System import Uri
                self.view.Source = Uri(text)
            except Exception:
                pass


browser = Browser()


def prefs_raw() -> dict:
    try:
        return json.loads(PREFS.read_text())
    except Exception:
        return {}


def save_pref_raw(key, value):
    p = prefs_raw()
    p[key] = value
    save_prefs(p)


def make_notch(api: Api):
    import webview
    w, h = NOTCH_SMALL
    win = webview.create_window(
        "Musiplex Notch", URL + "app?mode=notch", width=w, height=h, x=int((screen_w - w) / 2), y=0,
        frameless=True, on_top=True, resizable=False, easy_drag=False, focus=False, shadow=False,
        background_color="#000000", js_api=api)
    windows["notch"] = win
    win.events.shown += lambda: notch_shape.attach(win)


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
    if "--selftest-browser" in args:
        return selftest_browser()
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


def selftest_browser():
    """CI: opens the app's window and the built-in browser, and exits 0 once the browser's
    engine is ready (1 after 40 s). Writes %APPDATA%\\Musiplex\\selftest.log."""
    APPDATA.mkdir(parents=True, exist_ok=True)
    log = open(APPDATA / "selftest.log", "w", encoding="utf-8", buffering=1)
    import traceback
    import webview
    win = webview.create_window("Musiplex selftest", html="<p>selftest</p>", width=300, height=200)
    windows["main"] = win

    def done(ok):
        log.write(f"browser ready: {ok}\n")
        os._exit(0 if ok else 1)
    browser.on_ready = done

    def go():
        try:
            time.sleep(1)
            browser.open("about:blank")
            log.write("browser opening\n")
        except Exception:
            log.write(traceback.format_exc())
            os._exit(1)
    threading.Timer(40, lambda: (log.write("timed out\n"), os._exit(1))).start()
    win.events.loaded += lambda: threading.Thread(target=go, daemon=True).start()
    try:
        webview.start()
    except Exception:
        log.write(traceback.format_exc())
        os._exit(1)


if __name__ == "__main__":
    main()
