"""Pinned bootstrap downloads; verify before extraction, including cached bytes."""
import hashlib
import json
from pathlib import Path
import urllib.request
import zipfile

PINS = json.loads((Path(__file__).resolve().parents[1] / "dependency-pins.json").read_text())


def steamcmd_running():
    """True while any SteamCMD process is alive (Windows only)."""
    import os
    import subprocess
    if os.name != "nt":
        return False
    listing = subprocess.run(["tasklist", "/FI", "IMAGENAME eq steamcmd.exe", "/FO", "CSV", "/NH"],
                             capture_output=True, text=True, creationflags=subprocess.CREATE_NO_WINDOW)
    return "steamcmd.exe" in listing.stdout.lower()


def workshop_download(steam_root, item_id, done, *, timeout=600):
    """Download a Workshop item with SteamCMD until done() holds; returns (done, log path).

    A fresh SteamCMD first updates itself, restarts, and finishes the download in a child process
    the first run does not wait for. Wait for every SteamCMD process to exit before judging the
    result, and run the download once more if the first run only updated SteamCMD."""
    import subprocess
    import time
    steam_root = Path(steam_root)
    log = steam_root / f"workshop-{item_id}.log"
    startup = subprocess.STARTUPINFO()
    startup.dwFlags = subprocess.STARTF_USESHOWWINDOW
    startup.wShowWindow = 0
    for attempt in range(2):
        with log.open("ab" if attempt else "wb") as output:
            subprocess.run([str(steam_root / "steamcmd.exe"), "+login", "anonymous", "+workshop_download_item",
                            "232090", item_id, "validate", "+quit"], cwd=steam_root, startupinfo=startup,
                           stdin=subprocess.DEVNULL, stdout=output, stderr=subprocess.STDOUT, timeout=timeout)
        deadline = time.monotonic() + timeout
        while steamcmd_running() and time.monotonic() < deadline:
            time.sleep(2)
        if done():
            return True, log
    return False, log


def verified_archive(name, path):
    pin = PINS[name]
    path = Path(path)
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_suffix(".download")
        urllib.request.urlretrieve(pin["url"], temporary)
        if hashlib.sha256(temporary.read_bytes()).hexdigest().upper() != pin["sha256"]:
            raise RuntimeError("Downloaded dependency differs from reviewed pin: " + name)
        temporary.replace(path)
    if hashlib.sha256(path.read_bytes()).hexdigest().upper() != pin["sha256"]:
        raise RuntimeError("Cached dependency differs from reviewed pin: " + name)
    return path


def extract_verified(name, path, destination):
    path = verified_archive(name, path)
    destination = Path(destination).resolve()
    with zipfile.ZipFile(path) as archive:
        for item in archive.infolist():
            if not (destination / item.filename).resolve().is_relative_to(destination):
                raise RuntimeError("Dependency contains a path outside extraction root")
        archive.extractall(destination)
