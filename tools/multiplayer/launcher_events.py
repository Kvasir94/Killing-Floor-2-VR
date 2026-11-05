"""Structured progress for the player window: one JSON object per line.

friends.py keeps printing its human log for bug reports. When the window starts
it, it also gets an events file (--events, inherited as KF2VR_EVENTS by helper
processes) and the window reads only that, so log wording can change freely.

Event shapes:
  {"phase": "<key>"}                       a step in PHASES has started
  {"progress": 0.0-100.0}                  determinate progress for the current phase
  {"download_log": "<path>"}               SteamCMD log to follow for download percent
  {"join_code": "KF2VR1:..."} / {"join_code": null}
  {"epic_options": "<launch options line>"}
  {"done": true}                           the session ended normally
  {"error": "<code>", "message": "<raw>"}  the session failed; code is in ERRORS
"""
import json
import os
from pathlib import Path
import threading


def logs_folder():
    """Launcher logs live with the profile, so they outlive an extracted release."""
    return Path(os.environ.get("LOCALAPPDATA", str(Path.home()))) / "KF2VR/Logs"

# Ordered steps the window shows. Not every session visits every step.
PHASES = (
    ("checking", "Checking your game and files"),
    ("join-accepted", "Join code accepted"),
    ("server-install", "Setting up the game server"),
    ("server-download", "Downloading the game server (about 9 GB the first time)"),
    ("server-starting", "Starting the game server"),
    ("connecting", "Connecting to the game server"),
    ("host-ready", "Your game is up"),
    ("epic-options", "Paste the launch line into Epic"),
    ("epic-connected", "Epic connected"),
    ("game-starting", "Killing Floor 2 is starting"),
)
PHASE_TEXT = dict(PHASES)

# code, distinctive fragment(s) of the backend's message, and what the player sees.
ERRORS = (
    ("GAME_VERSION", "KF2 version differs",
     "Your copy of Killing Floor 2 doesn't match this KF2-VR build. Let Steam finish updating KF2, "
     "then get the newest KF2-VR from where you downloaded this one."),
    ("STOCK_CONFIG_MISSING", "Start standard KF2 once",
     "Start normal Killing Floor 2 from Steam once, quit it, then try again."),
    ("HEADSET_RUNTIME", "No usable active OpenXR runtime",
     "Your headset isn't ready. Start Quest Link / Air Link, SteamVR or your headset's PC app, "
     "then try again. Or choose Desktop."),
    ("ALREADY_RUNNING", "Another KF2-VR session is running",
     "KF2-VR is already running in another window. Close that game first."),
    ("STUCK_SESSION", "Another VR/mod session",
     "A previous KF2-VR session didn't finish tidying up. Press Help > Repair, then try again."),
    ("STEAM_NOT_RUNNING", "Steam isn't running",
     "Steam isn't running or isn't signed in. Open Steam, sign in, then try again."),
    ("KF2_OPEN", "Close KF2 and its SDK",
     "Killing Floor 2 is already open. Close it, then try again."),
    ("SERVER_UNREACHABLE", "Cannot verify server",
     "Couldn't reach your friend's game. Check the code is the newest one, and ask them to make sure "
     "their game says it's up."),
    ("PACKAGE_DAMAGED", "Package file changed or missing",
     "Some KF2-VR files are missing or damaged. Delete this folder and unzip a fresh copy."),
    ("DISK_FULL", ("free disk space", "disk ran out of space"),
     "There isn't enough free disk space for the game server. Free some space, then try again."),
    ("SERVER_INSTALL", "dedicated server could not be installed",
     "The game server download didn't finish. Check your internet and disk space, then try again."),
    ("SERVER_EXITED", "Dedicated server exited",
     "The game server stopped while starting. Save logs for a bug report if it keeps happening."),
    ("VAC_ENABLED", "Server reports VAC enabled",
     "That server has VAC (Steam anti-cheat) on. KF2-VR can only join servers with VAC off."),
    ("MAP_MISSING", "is not installed on both client and server",
     "That map isn't installed. Pick a different map."),
    ("JOIN_CODE", "Invalid join code",
     "That join code isn't valid. Copy the whole code from your friend again."),
    ("JOIN_BUILD", "different KF2-VR build",
     "Your friend has a different KF2-VR version. You both need the same version."),
    ("DLSS_UNAVAILABLE", "no DLSS runtime",
     "This KF2-VR package can't use DLSS. Set DLSS to Off in Graphics."),
)
ERROR_TEXT = {code: text for code, _, text in ERRORS}
UNKNOWN = "UNKNOWN"

_lock = threading.Lock()


def configure(path):
    """Send this process's events, and its helper processes', to path."""
    if path:
        os.environ["KF2VR_EVENTS"] = str(Path(path).resolve())


def emit(**event):
    path = os.environ.get("KF2VR_EVENTS")
    if not path:
        return
    line = json.dumps(event, separators=(",", ":")) + "\n"
    with _lock:
        try:
            with open(path, "a", encoding="utf-8") as stream:
                stream.write(line)
        except OSError:
            pass  # Progress display must never fail a launch.


def phase(name):
    assert name in PHASE_TEXT, name
    emit(phase=name)


def classify(message):
    text = str(message or "").lower()
    for code, fragments, _ in ERRORS:
        if any(fragment.lower() in text for fragment in ((fragments,) if isinstance(fragments, str) else fragments)):
            return code
    return UNKNOWN


def fail(message):
    emit(error=classify(message), message=str(message))


def read(path, offset=0):
    """Events written since offset, and the new offset. Partial lines wait."""
    try:
        with open(path, "rb") as stream:
            stream.seek(offset)
            data = stream.read()
    except OSError:
        return [], offset
    complete = data.rfind(b"\n") + 1
    events = []
    for line in data[:complete].splitlines():
        try:
            value = json.loads(line)
        except ValueError:
            continue
        if isinstance(value, dict):
            events.append(value)
    return events, offset + complete
