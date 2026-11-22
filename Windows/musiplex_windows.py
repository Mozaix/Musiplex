"""Musiplex for Windows: one Musiplex.exe.

- Double-click (or the Start menu / taskbar): makes sure the server is running
  in the background, then opens the Musiplex window.
- First run: copies itself to %LOCALAPPDATA%\\Musiplex, starts at login (no window),
  and adds a Start menu shortcut you can pin to the taskbar.
- `Musiplex.exe --serve`: the background server itself (what runs at login).
- `Musiplex.exe --uninstall`: stops starting at login and removes the shortcut.

Nothing about you is built in: the pairing PIN, key and name are made on this
PC the first time the server starts (kept in %APPDATA%\\Musiplex\\config.json),
and its addresses are looked up live.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import time
import urllib.request
import webbrowser
from pathlib import Path

URL = "http://127.0.0.1:7860/"
HOME = Path(os.environ.get("LOCALAPPDATA", Path.home())) / "Musiplex"
EXE = HOME / "Musiplex.exe"
LOG = Path(os.environ.get("APPDATA", Path.home())) / "Musiplex" / "server.log"
RUN_KEY = r"Software\Microsoft\Windows\CurrentVersion\Run"
SHORTCUT = Path(os.environ.get("APPDATA", Path.home())) / "Microsoft/Windows/Start Menu/Programs/Musiplex.lnk"
NO_WINDOW = 0x08000000  # CREATE_NO_WINDOW
DETACHED = 0x00000008   # DETACHED_PROCESS


def running() -> bool:
    try:
        with urllib.request.urlopen(URL + "ping", timeout=1.5) as r:
            return r.read().startswith(b"musiplex")
    except Exception:
        return False


def install() -> Path:
    """Copies this exe to a fixed place, and sets up login start and the shortcut."""
    me = Path(sys.executable)
    HOME.mkdir(parents=True, exist_ok=True)
    if getattr(sys, "frozen", False) and me.resolve() != EXE.resolve():
        try:
            shutil.copy2(me, EXE)   # also how an update is installed: run the new exe once
        except OSError:
            pass                     # the old one is running; keep using it
    target = EXE if EXE.exists() else me
    try:
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY, 0, winreg.KEY_SET_VALUE) as k:
            winreg.SetValueEx(k, "Musiplex", 0, winreg.REG_SZ, f'"{target}" --serve')
    except OSError:
        pass
    if not SHORTCUT.exists():
        ps = ("$s=(New-Object -ComObject WScript.Shell).CreateShortcut($env:LNK);"
              "$s.TargetPath=$env:EXE;$s.IconLocation=$env:EXE+',0';$s.Description='Musiplex';$s.Save()")
        try:
            subprocess.run(["powershell", "-NoProfile", "-WindowStyle", "Hidden", "-Command", ps],
                           env={**os.environ, "LNK": str(SHORTCUT), "EXE": str(target)},
                           creationflags=NO_WINDOW, timeout=20)
        except Exception:
            pass
    return target


def uninstall():
    try:
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY, 0, winreg.KEY_SET_VALUE) as k:
            winreg.DeleteValue(k, "Musiplex")
    except OSError:
        pass
    SHORTCUT.unlink(missing_ok=True)


def open_window():
    """Its own app window (Edge or Chrome app mode), else the default browser."""
    for exe in (
        Path(os.environ.get("ProgramFiles(x86)", "")) / "Microsoft/Edge/Application/msedge.exe",
        Path(os.environ.get("ProgramFiles", "")) / "Microsoft/Edge/Application/msedge.exe",
        Path(os.environ.get("ProgramFiles", "")) / "Google/Chrome/Application/chrome.exe",
        Path(os.environ.get("LOCALAPPDATA", "")) / "Google/Chrome/Application/chrome.exe",
    ):
        if exe.is_file():
            subprocess.Popen([str(exe), f"--app={URL}", "--window-size=820,900"], creationflags=DETACHED)
            return
    webbrowser.open(URL)


def serve(argv: list[str]):
    LOG.parent.mkdir(parents=True, exist_ok=True)
    log = open(LOG, "a", buffering=1, encoding="utf-8")
    sys.stdout = sys.stderr = log   # a windowed exe has no console to print to
    import musiplex_server
    sys.argv = [sys.argv[0], *argv]
    musiplex_server.main()


def main():
    args = sys.argv[1:]
    if "--serve" in args:
        args.remove("--serve")
        return serve(args)
    if "--uninstall" in args:
        return uninstall()
    target = install()
    if not running():
        subprocess.Popen([str(target), "--serve"], creationflags=DETACHED | NO_WINDOW, close_fds=True)
        for _ in range(40):
            time.sleep(0.25)
            if running():
                break
    open_window()


if __name__ == "__main__":
    main()
