"""Host/join launcher shipped with the multiplayer prototype. No SDK required."""
from __future__ import annotations

import argparse
import ctypes
from datetime import datetime, timezone
import importlib
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import sys
import time

from launch_support import query_server
from native_fixture import NativeDeployment
from vr_config import ALIASES as VR_SECTION_ALIASES, import_preferences, export_preferences, export_session_preferences
import desktop_settings
import vr_graphics
import join_code
import settings_registry
import game_install
import machine_settings
import launcher_events
import range_map
from workshop_map import MAP_NAME, ensure_map, cached_solo_map, installed_map, add_map_path, receipt as map_receipt
from launch_menu import (DIFFICULTIES, LENGTHS, host_url, solo_url, installed_maps, installed_solo_maps,
                         resolve_solo_map, choose_options)
from workshop_loadout import (parse_mods, require_ukfp_for_spawns, load_preferences, save_preferences, save_dlss_preferences, prepare_content,
                              configure_content, configure_mod_settings, damage_popups_enabled,
                              KF2VR_FULL_WORKSHOP_URL)
from launch_support import digest, config_hashes, role_config, set_ini, read_ini, log_text, unreal_command, check_port
from watchdog import api, creation_time
from launch_support import events


def developer_tool(name):
    """Motion recording, highlight logging and local test control stay in the
    checkout; the player ZIP leaves them out, so load them only when asked."""
    try:
        return importlib.import_module(name)
    except ModuleNotFoundError as error:
        if error.name != name:
            raise
        raise RuntimeError(f"{name.replace('_', ' ')} is a developer tool and is not part of this package.") from None


def local_test_requested(args):
    return getattr(args, "local_test_control", False) or getattr(args, "local_test_diagnostic", False)

ROOT = Path(__file__).resolve().parents[2]
# Server and Workshop cache sit beside the extracted release so later releases
# reuse them. A ZIP keeps the release in app/ under its own top-level folder.
SHARED = ROOT.parent.parent if ROOT.name.lower() == "app" else ROOT.parent

# The XP line on the Play page; the Solo form says when a match earns none, where that is chosen.
XP_NOTE = "Matches earn XP as usual."
# Says only what holds for the player in a KF2-VR game. How a flat launch is affected depends on how the
# game was started (Workshop launch options will choose per boot), so the note does not promise it.
LAUNCH_NOTE = ("KF2-VR plays with VAC (Steam's anti-cheat) off, so it joins only VAC-off servers. " + XP_NOTE)


def launch_notices(store):
    """The one note shown before play: the VAC line for Steam; Epic has no VAC and its limits are said once
    on the Play page already."""
    return () if store == "epic" else (LAUNCH_NOTE,)


def server_adapter_ready(text):
    """Require the packaged dedicated adapter and both progression hooks."""
    for line in text.splitlines():
        if not line.startswith("server_adapter "):
            continue
        fields = dict(re.findall(r"(\w+)=(\S+)", line))
        if all(fields.get(key) == "1" for key in ("ready", "ranked", "content_xp")):
            return True
    return False


def server_install_failure(output, code):
    """Keep actionable installer errors visible in the launcher's status message."""
    match = re.search(r"(Not enough free disk space.*?try again\.|The disk ran out of space.*?try again\.)",
                      re.sub(r"\s+", " ", output))
    return match.group(1) if match else f"The dedicated server could not be installed (exit {code}); see the details below."


def install_server(server_root, env):
    # Stream progress so the GUI can follow SteamCMD's download log immediately.
    output = []
    with subprocess.Popen(["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
            str(ROOT / "tools/install-multiplayer-server.ps1"), "-ServerRoot", str(server_root)],
            env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace",
            creationflags=subprocess.CREATE_NO_WINDOW) as installer:
        for line in installer.stdout:
            print(line, end="", flush=True)
            output.append(line)
            if line.startswith("Download log: "):
                launcher_events.emit(download_log=line[len("Download log: "):].strip())
                launcher_events.phase("server-download")
        code = installer.wait()
    if code != 0:
        raise RuntimeError(server_install_failure("".join(output), code))


def save_session_record(output, record):
    """Publish a complete session record despite a concurrent watchdog read."""
    temporary = output.with_suffix(".tmp")
    temporary.write_text(json.dumps(record, indent=2), encoding="utf-8")
    # On Windows, the watchdog's short read may omit FILE_SHARE_DELETE. Keep
    # the complete temporary record and retry its atomic replacement instead
    # of treating that momentary sharing violation as a failed game session.
    for attempt in range(20):
        try:
            temporary.replace(output)
            return
        except PermissionError:
            if attempt == 19:
                raise
            time.sleep(0.05)


def collect_avatar_captures(run, user_config, log, started, finished, expected_requests=6, *, max_requests=6, budget_bytes=128*1024*1024):
    """Copy only logged, current-session captures; never alter engine originals."""
    source_root = (Path(user_config).parent / "Screenshots").resolve()
    destination = Path(run).resolve() / "captures"
    requests = events(log, "avatar_capture")
    named = {}
    invalid = []
    for event in requests:
        name = event.get("name", "")
        if not re.fullmatch(r"KF2VR_Avatar_[0-9]{1,12}_[0-9]{1,12}_[1-9][0-9]{0,2}", name) or not 1 <= int(name.rsplit("_", 1)[1]) <= max_requests:
            invalid.append(event)
        elif name not in named:
            named[name] = {"name": name, "status": "missing", "files": [], "stale_sources": []}
    result = {"schema": "kf2vr/avatar-captures/1", "source_root": str(source_root),
              "destination_root": str(destination), "started_unix": started, "finished_unix": finished,
              "request_events": requests, "expected_request_count": expected_requests,
              "valid_request_count": len(named), "invalid_requests": invalid,
              "missing_request_count": max(0, expected_requests - len(named)),
              "entries": list(named.values()), "search_errors": [],
              "visual_acceptance_verified": False}
    candidates = {name: [] for name in named}
    # UE3 bugscreenshot prepends map/date text and appends its screenshot
    # counter 0 to the supplied name. Do not use substring/prefix matches that
    # could accept a different capture index, epoch, or arbitrary log path.
    patterns = {name: re.compile(re.escape(name) + r"(?:0)?\.(?:bmp|png)$", re.I) for name in named}
    try:
        if not 1 <= max_requests <= 100 or len(named) > max_requests:
            raise ValueError("Avatar capture sequence exceeds its configured bound")
        if named and source_root.exists():
            inspected = 0
            directories = 0
            def walk_error(error):
                result["search_errors"].append(str(error))
            for folder, dirs, files in os.walk(source_root, followlinks=False, onerror=walk_error):
                directories += 1
                inspected += len(files)
                if directories > 2000 or inspected > 20000:
                    raise ValueError("Screenshot search exceeded its 2000-directory/20000-file bound")
                dirs[:] = sorted(name for name in dirs
                    if not (Path(folder) / name).is_symlink()
                    and not (Path(folder) / name).is_junction()
                    and (Path(folder) / name).resolve().is_relative_to(source_root))
                for filename in sorted(files):
                    for name, pattern in patterns.items():
                        if not pattern.search(filename):
                            continue
                        path = Path(folder) / filename
                        if path.is_symlink() or not path.resolve().is_relative_to(source_root) or not path.is_file():
                            result["search_errors"].append(f"Capture is not an ordinary file inside screenshot root: {path}")
                            continue
                        stat = path.stat()
                        info = {"source_path": str(path.resolve()), "size_bytes": stat.st_size,
                                "modified_unix": stat.st_mtime}
                        if not started <= stat.st_mtime <= finished:
                            named[name]["stale_sources"].append(info)
                        else:
                            candidates[name].append(info)
        if destination.is_symlink() or destination.is_junction() or not destination.resolve().is_relative_to(Path(run).resolve()):
            raise ValueError("Capture destination must remain inside this session")
        copied_bytes = 0
        for name, entry in named.items():
            matches = candidates[name]
            if len(matches) > 1:
                entry.update(status="ambiguous", matching_sources=matches)
                continue
            if not matches:
                continue
            source = Path(matches[0]["source_path"])
            info = matches[0]
            try:
                if not 0 < info["size_bytes"] <= 64 * 1024 * 1024:
                    raise ValueError("Capture must be nonempty and at most 64 MiB")
                if copied_bytes + info["size_bytes"] > budget_bytes:
                    raise ValueError("Capture disk budget exceeded")
                copied_bytes += info["size_bytes"]
                info["source_sha256"] = digest(source)
                target = destination / source.name
                destination.mkdir(parents=True, exist_ok=True)
                if target.exists():
                    if target.is_symlink() or digest(target) != info["source_sha256"]:
                        raise ValueError("Existing capture copy differs; refusing to overwrite it")
                else:
                    # Exclusive creation also preserves an unexpected existing
                    # file if one appears between the check and copy.
                    with source.open("rb") as incoming, target.open("xb") as outgoing:
                        shutil.copyfileobj(incoming, outgoing)
                info.update(copied_path=str(target), copied_sha256=digest(target))
                if info["copied_sha256"] != info["source_sha256"] or digest(source) != info["source_sha256"]:
                    raise ValueError("Capture changed while being collected")
                entry.update(status="copied", files=[info])
            except (OSError, ValueError) as error:
                entry.update(status="copy_failed", files=[info], error=str(error))
    except (OSError, ValueError) as error:
        result["search_errors"].append(str(error))
    result["missing_names"] = [name for name, entry in named.items() if entry["status"] != "copied"]
    result["capture_missing"] = bool(result["missing_names"] or result["missing_request_count"] or invalid)
    result["all_logged_captures_collected"] = bool(named) and not (result["missing_names"] or invalid or result["search_errors"])
    result["collection_complete"] = result["all_logged_captures_collected"] and not result["missing_request_count"]
    return result


def avatar_capture_receipt(run, user_config, player_role, started, expected_requests=6):
    """Keep optional capture I/O from masking a fixture/cleanup failure."""
    try:
        return collect_avatar_captures(run, user_config, log_text(player_role),
                                       started, time.time(), expected_requests)
    except Exception as error:
        return {"schema": "kf2vr/avatar-captures/1", "status": "collection_failed",
                "source_log": player_role.get("log"), "search_errors": [str(error)],
                "collection_complete": False, "all_logged_captures_collected": False,
                "capture_missing": True, "visual_acceptance_verified": False}


def cleanup_order(owned, avatar_preview=False):
    """End preview observation before intentionally stopping its pose producer."""
    ordered = list(reversed(owned))
    if avatar_preview:
        return ([item for item in ordered if item[0]["role"] == "driver"]
                + [item for item in ordered if item[0]["role"] != "driver"])
    return ordered


def disable_mouse_look(text):
    """Keep mouse counters/buttons in the VR input copy, without camera axes."""
    def strip(match):
        row = match.group()
        if not re.search(r'(?i)\bName\s*=\s*"?Mouse[XY]"?\s*[,)]', row):
            return row
        def command(found):
            parts = [p.strip() for p in found.group(2).split("|")]
            kept = [p for p in parts if not re.match(r"(?i)Axis\s+aMouse[XY]\b", p)]
            return found.group(1) + " | ".join(kept) + found.group(3)
        return re.sub(r'(?i)(\bCommand\s*=\s*")([^"]*)(")', command, row)
    for section in ("Engine.PlayerInput", "KFGame.KFPlayerInput"):
        pattern = re.compile(r"(?ims)^[ \t]*\[" + re.escape(section) + r"\][^\r\n]*(?:\r?\n|$).*?(?=^[ \t]*\[|\Z)")
        text = pattern.sub(lambda block: re.sub(
            r"(?im)^[ \t]*[+.-]?Bindings\s*=[^\r\n]*", strip, block.group()), text)
    return text


DEFAULT_SERVER_NAME = settings_registry.DEFAULT_SERVER_NAME
WELCOME_MOTD = ("Welcome to a KF2-VR server!@nl@@nl@Want to play in VR? Press the Website button, "
                "subscribe to KF2VR, and follow the setup on that page.@nl@@nl@"
                "Playing on a normal screen works as usual.")
SERVER_NAME_PATTERN = r"[A-Za-z0-9 .,'!&()+_-]{1,48}"


def resolve_host_identity(args, saved):
    args.server_name = (args.server_name if args.server_name is not None
                        else saved.get("server_name", DEFAULT_SERVER_NAME)).strip()
    if not re.fullmatch(SERVER_NAME_PATTERN, args.server_name):
        raise RuntimeError("Use a server name of 1-48 letters, numbers, spaces or . , ' ! & ( ) + _ -")
    if args.open_server:
        args.password = ""
    else:
        args.password = args.password or saved.get("host_password") or secrets.token_hex(4)
    if not re.fullmatch(r"[A-Za-z0-9_-]{0,64}", args.password):
        raise RuntimeError("Use a session password containing letters, numbers, underscore or hyphen, or none.")
    saved["server_name"] = args.server_name
    if args.password:
        saved["host_password"] = args.password


def announce_host(args, manifest, server_log):
    """Publish this host's connection details before declaring it ready."""
    path = ROOT / "JOIN-SERVER.txt"
    # An unavailable address must not leave an earlier host's instructions.
    path.unlink(missing_ok=True)
    address = args.share_address or join_code.public_address(server_log)
    if address:
        code = join_code.encode(dict(address=address, password=args.password, port=args.port,
            query_port=args.query_port, build=manifest["build_id"], mods=args.mods, map=args.map))
        instructions = ("Send your friends the same KF2-VR ZIP and this code:\n\n" + code +
            "\n\nUnzip it, open Start KF2-VR, click Join a friend and paste the code. "
            "Keep the KF2-VR window open while playing.\n\n"
            f"Host: forward UDP {args.port} and UDP {args.query_port} to your PC for internet play. "
            + ("This code contains the session password; share it privately. " if args.password else
               "This server has no password: anyone who reaches it can join. ") +
            "Generating a code does not verify internet reachability.\n")
        temporary = path.with_suffix(".tmp")
        temporary.write_text(instructions, encoding="utf-8")
        temporary.replace(path)
        print(instructions + "Copy/share instructions from: " + str(path), flush=True)
        launcher_events.emit(join_code=code)
    else:
        print("Public address unavailable. Use --share-address YOUR_PUBLIC_IP on the next host launch to generate a join code.", flush=True)
        launcher_events.emit(join_code=None)
    launcher_events.phase("host-ready")
    print(f"Host ready. Session password: {args.password or '(none: anyone can join)'}\nFriends use your LAN/VPN/public address. Game UDP {args.port}; query UDP {args.query_port}.", flush=True)


def validate_server_query(info, password):
    if info["secure"]:
        raise RuntimeError("Server reports VAC enabled. This prototype requires the KF2-VR VAC-off host.")
    if info["folder"] != "kf2" or bool(info["password"]) != bool(password):
        raise ValueError("Expected a password-protected KF2 server" if password
                         else "Expected a KF2 server without a password")


def preview_camera_binding(text, command="KF2VRAvatarToggleCamera"):
    """Change only unmodified F8 in the isolated input copy; retain array rows."""
    if command not in ("KF2VRAvatarToggleCamera", "KF2VRThirdPersonToggle"):
        raise ValueError("Unsupported F8 command")
    binding = f'Bindings=(Name="F8",Command="{command}",Control=False,Shift=False,Alt=False,bIgnoreCtrl=False,bIgnoreShift=False,bIgnoreAlt=False)'
    for section in ("Engine.PlayerInput", "KFGame.KFPlayerInput"):
        pattern = re.compile(r"(?ims)^[ \t]*\[" + re.escape(section) + r"\][^\r\n]*(?:\r?\n|$).*?(?=^[ \t]*\[|\Z)")
        matches = list(pattern.finditer(text))
        if len(matches) > 1:
            raise ValueError(f"Duplicate INI section: {section}")
        if not matches:
            # Do not create an input array containing only F8 over inherited
            # stock controls. Initialized KF2 input has both concrete arrays.
            continue
        def remove_plain_f8(match):
            row = match.group()
            is_f8 = re.search(r'(?i)\bName\s*=\s*"?F8"?\s*[,)]', row)
            modified = re.search(r'(?i)\b(?:Control|Shift|Alt)\s*=\s*true\b', row)
            return "" if is_f8 and not modified else row
        block = re.sub(r"(?im)^[ \t]*[+.-]?Bindings\s*=[^\r\n]*(?:\r?\n|$)", remove_plain_f8, matches[0].group())
        head, _, tail = block.partition("\n")
        newline = "\r\n" if head.endswith("\r") else "\n"
        block = head + "\n" + binding + newline + tail
        text = pattern.sub(lambda _: block, text)
    return text


def eye_render_percent(value):
    if not re.fullmatch(r"[0-9]{2,3}", value) or not 50 <= int(value) <= 100:
        raise argparse.ArgumentTypeError("eye render percent must be an integer from 50 to 100")
    return int(value)


def role_environment(environment, role):
    # Windows environment names are case-insensitive. Clear inherited fixture
    # controls before adding only this role's recorded native settings.
    result = {key: value for key, value in environment.items() if not key.upper().startswith("KF2VR_")}
    if role["native_adapter"]:
        result["KF2VR_LOG_PATH"] = str(Path(role["log"]).with_name("native.log"))
    # Diagnostics only: a capture root set in the launching shell reaches the
    # VR driver (one-shot eye captures, re-armed by an 'arm' file in it).
    capture = next((value for key, value in environment.items() if key.upper() == "KF2VR_CAPTURE_ROOT"), None)
    if capture and role.get("role") == "driver" and role["native_adapter"] and "-kf2vr-stereo" in role["args"]:
        result["KF2VR_CAPTURE_ROOT"] = capture
    if role.get("server_adapter"):
        result["KF2VR_SERVER_LOG_PATH"] = str(Path(role["log"]).with_name("native.log"))
    if "eye_render_percent" in role:
        percent = role["eye_render_percent"]
        if (role["role"] != "driver" or not role["native_adapter"] or "-kf2vr-stereo" not in role["args"]
                or type(percent) is not int or not 50 <= percent <= 100):
            raise ValueError("Eye resolution is valid only for the live VR driver, from 50 to 100 percent")
        result["KF2VR_EYE_RENDER_PERCENT"] = str(percent)
    if role.get("role") == "driver" and role.get("native_adapter"):
        from epic_broker import graphics_payload
        graphics_payload(role.get("dlss", "off"), role.get("dlss_sharpness", 0), role.get("hide_bile_lens", False), role.get("hide_blood_lens", False))
    if role.get("role") == "driver" and role.get("native_adapter") and role.get("hide_bile_lens"):
        result["KF2VR_HIDE_BILE_LENS"] = "1"
    if role.get("role") == "driver" and role.get("native_adapter") and role.get("hide_blood_lens"):
        result["KF2VR_HIDE_BLOOD_LENS"] = "1"
    if role.get("dlss", "off") != "off" and role.get("role") == "driver" and role.get("native_adapter"):
        # The adapter loads nvngx_dlss.dll from the release's native folder.
        result["KF2VR_DLSS"] = role["dlss"]
        result["KF2VR_NGX_DIR"] = str(ROOT / "Native")
        result["KF2VR_DLSS_SHARPNESS"] = str(int(role.get("dlss_sharpness", 0)))
    if role.get("promo_session") is not None:
        result.update(developer_tool("promo_session").environment(role))
    if role.get("capture_session_id") is not None:
        result.update(developer_tool("motion_session").environment(role))
    return result


def peak_working_set_mib(process):
    """Peak working set of an owned game process in MiB, or None. Read from the
    launcher side with GetProcessMemoryInfo, so it costs the game nothing."""
    import ctypes

    class Counters(ctypes.Structure):
        _fields_ = [("cb", ctypes.c_uint32), ("PageFaultCount", ctypes.c_uint32),
                    ("PeakWorkingSetSize", ctypes.c_size_t), ("WorkingSetSize", ctypes.c_size_t),
                    ("QuotaPeakPagedPoolUsage", ctypes.c_size_t), ("QuotaPagedPoolUsage", ctypes.c_size_t),
                    ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t), ("QuotaNonPagedPoolUsage", ctypes.c_size_t),
                    ("PagefileUsage", ctypes.c_size_t), ("PeakPagefileUsage", ctypes.c_size_t)]
    counters = Counters()
    counters.cb = ctypes.sizeof(Counters)
    try:
        handle = ctypes.c_void_p(int(process._handle))
        if not ctypes.windll.psapi.GetProcessMemoryInfo(handle, ctypes.byref(counters), counters.cb):
            return None
    except (AttributeError, OSError, ValueError):
        return None
    return counters.PeakWorkingSetSize // (1024 * 1024)


STEAM_NOT_RUNNING = "Steam isn't running or isn't signed in. Open Steam, sign in, then try again."


def steam_running():
    """True when a Steam client process is running and Steam reports a signed-in user."""
    import winreg
    # ActiveProcess\pid can go stale across Steam restarts, so look for the process itself.
    listing = subprocess.run(["tasklist", "/FI", "IMAGENAME eq steam.exe", "/FO", "CSV", "/NH"],
                             capture_output=True, text=True, creationflags=subprocess.CREATE_NO_WINDOW)
    if "steam.exe" not in listing.stdout.lower():
        return False
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Valve\Steam\ActiveProcess") as key:
            return int(winreg.QueryValueEx(key, "ActiveUser")[0]) != 0
    except (OSError, ValueError):
        return True  # running, and nothing says it isn't signed in: let the game try


def ensure_steam(timeout=90):
    """Killing Floor 2 quits at once without Steam: start it and wait for sign-in, or stop with a plain reason."""
    if steam_running():
        return
    print("Starting Steam: Killing Floor 2 needs it running and signed in...", flush=True)
    try:
        os.startfile("steam://open/main")
    except OSError:
        raise RuntimeError(STEAM_NOT_RUNNING) from None
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        time.sleep(2)
        if steam_running():
            # Signed in; give the client a moment to finish starting before the game asks for it.
            time.sleep(5)
            return
    raise RuntimeError(STEAM_NOT_RUNNING)


def find_game() -> Path | None:
    import winreg
    candidates = [Path("D:/SteamLibrary"), Path("C:/Program Files (x86)/Steam")]
    # Steam's own path for this user, else the machine-wide install path; every
    # library folder it lists (other drives included) is searched.
    for hive, subkey, value in ((winreg.HKEY_CURRENT_USER, r"Software\Valve\Steam", "SteamPath"),
                                (winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\WOW6432Node\Valve\Steam", "InstallPath")):
        try:
            with winreg.OpenKey(hive, subkey) as key:
                steam = Path(winreg.QueryValueEx(key, value)[0])
        except OSError:
            continue
        candidates.insert(0, steam)
        vdf = steam / "steamapps/libraryfolders.vdf"
        try:
            candidates += [Path(p.replace("\\\\", "\\")) for p in
                           re.findall(r'"path"\s+"([^"]+)"', vdf.read_text(encoding="utf-8"))]
        except OSError:
            pass
        break
    return next((p / "steamapps/common/killingfloor2" for p in candidates
                 if (p / "steamapps/common/killingfloor2/Binaries/Win64/KFGame.exe").exists()), None)


# The shared session setup isolates single-PC test clients: voice off, and
# screenshots, saves and local profile data under the session folder. A desktop
# player is a real player and keeps the stock locations.
DESKTOP_ENGINE_KEYS = {"Core.System": ("SavePath", "ScreenShotPath"),
                       "OnlineSubsystemSteamworks.OnlineSubsystemSteamworks": ("ProfileDataDirectory",)}


def restore_desktop_engine(configs, user):
    stock_path, path = Path(user) / "KFEngine.ini", Path(configs) / "KFEngine.ini"
    if not stock_path.exists() or not path.exists():
        return
    stock, text = read_ini(stock_path), read_ini(path)
    for section, keys in DESKTOP_ENGINE_KEYS.items():
        found = dict(re.findall(r"(?m)^([A-Za-z]\w*)=([^\r\n]*)", section_text(stock, section)))
        restored = {key: found[key] for key in keys if key in found}
        if restored:
            text = set_ini(text, section, restored)
    path.write_text(text, encoding="utf-16")


def section_text(text, section):
    match = re.search(r"(?ims)^[ \t]*\[" + re.escape(section) + r"\][^\n]*\n(.*?)(?=^[ \t]*\[|\Z)", text)
    return match[1] if match else ""


def configure_role(run, name, user, game, args):
    test_map = getattr(args, "test_map", False)
    replay = getattr(args, "replay_teammate", False)
    avatar = getattr(args, "avatar_preview", False)
    locomotion = getattr(args, "locomotion_preview", False)
    if name == "teammate":
        # Reuse the proven owning-client native controller replay. This is a
        # separate KFGame connection, not a server bot or the headset's input.
        role = role_config(run / "replay", "driver", user, ROOT / "Packages", game,
                           args.port, args.query_port, args.cache_root,
                           combat=not locomotion, online_server=True, native_replay=True,
                           movement=not (avatar or locomotion), expected_clients=2)
        role["role"] = "teammate"
        role["args"][0] = f"127.0.0.1:{args.port}?Password={args.password}?Name=Replay_Teammate"
        role["args"] = [a for a in role["args"] if not a.startswith(("-Port=", "-QueryPort="))]
        role["args"] += [f"-Port={args.port + 20}", f"-QueryPort={args.query_port + 20}"]
        configs = Path(role["config_root"])
        path = configs / "KFGame.ini"
        text = set_ini(read_ini(path), "KF2VRNet.KF2VRNetPlayerController", {
            "bDiagnosticVisualReplay": "true",
            "bDiagnosticAvatarPreview": "false",
            "bDiagnosticAvatarCamera": "false",
            "bDiagnosticLocomotionReplay": "true" if locomotion else "false",
            "bDiagnosticAvatarReplay": "true" if avatar else "false"})
        text = set_ini(text, "Engine.AccessControl", {"GamePassword": args.password})
        path.write_text(text, encoding="utf-16")
        role["config_hashes"] = config_hashes(configs)
        return role
    role = role_config(run, name, user, ROOT / "Packages", game, args.port, args.query_port,
                       args.cache_root, False, True, False)
    configs = Path(role["config_root"])
    path = configs / "KFGame.ini"
    text = set_ini(read_ini(path), "KF2VRNet.KF2VRNetPlayerController", {
        "bDiagnosticSyntheticAutoStart": "false", "bDiagnosticObserverDebug": "true" if replay else "false",
        "bDiagnosticObserverOnly": "false", "bDiagnosticAutoFire9mm": "false",
        "bDiagnosticDamage": "false", "bDiagnosticVisualReplay": "false",
        "bDiagnosticAvatarPreview": "true" if avatar and name == "driver" else "false",
        "bDiagnosticAvatarCamera": "true" if avatar and name == "driver" and not args.vr else "false",
        "bDiagnosticAvatarReplay": "false",
        "bDiagnosticLocomotionReplay": "true" if locomotion and name == "driver" else "false",
        "bEnableVRClient": "true" if name == "driver" and args.vr else "false"})
    text = set_ini(text, "KF2VRNet.KF2VRNetPlayerController", {"bDiagnosticMovement": "false"})
    if name == "server":
        # Persist host capability through ordinary map travel. Individual
        # desktop players keep stock weapons; VR owners opt in via tracking.
        text = set_ini(text, "Engine.GameReplicationInfo", {
            "ServerName": getattr(args, "server_name", None) or DEFAULT_SERVER_NAME})
        text = set_ini(text, "KFGame.KFGameInfo", {"ServerMOTD": WELCOME_MOTD,
                                                   "WebsiteLink": KF2VR_FULL_WORKSHOP_URL})
        host_settings = {
            "bServerAdapter": "true", "bIndependentWeapons": "false" if replay and not locomotion else "true",
            "bInventoryFocusEnabled": "false",
            "bMultiplayerZedGrabAllowed": "false"}
        text = set_ini(text, "KF2VRNet.KF2VRNetGame", host_settings)
        role["server_adapter"] = True
        role["args"] += ["-kf2vr-server-adapter"]
    # Remote friends use stock authentication. The localhost test exception must
    # not leak into a shipped remote-client configuration.
    text = set_ini(text, "Engine.AccessControl", {"GamePassword": args.password,
                   "bAuthenticateServer": "false" if args.address == "127.0.0.1" else "true"})
    path.write_text(text, encoding="utf-16")
    server_url = host_url(args)
    role["args"][0] = (server_url
                        if name == "server" else f"{args.address}:{args.port}"
                        + (f"?Password={args.password}" if args.password else ""))
    if name == "server" and replay and not test_map:
        role["args"][0] += "?VRNetDiagnostics=1?VRNetAutoReady=1?VRNet9mm=1?VRNetClients=2"
        if not args.replay_match:
            role["args"][0] += "?VRNetRecovery=1"
    if name == "driver":
        # -NOINI marks the standard Engine/Game/Input/Editor/UI/Benchmarking
        # INIs NoSave, so an in-game SaveConfig never reaches disk and the
        # profile export reads launch values. Every standard INI the game edits
        # is an explicit session copy (-*INI=); KFEditor.ini is not, but only a
        # dirty file is flushed and play never edits it. user_config_preserved
        # still hash-checks the base folder.
        role["args"] = [a for a in role["args"] if a not in ("-NOINI", "-windowed")
                        and not a.startswith(("-MULTIHOME=", "-ResX=", "-ResY="))]
        if args.vr:
            # The headset renders the game; the desktop window is only a mirror.
            role["args"] += ["-windowed", "-ResX=1280", "-ResY=720"]
        else:
            restore_desktop_engine(configs, user)
        if locomotion:
            role["args"] += ["-windowed", "-ResX=1280", "-ResY=720"]
        # Every player client needs Vivox initialised: KF2's Steam lobby code
        # (friend join URL -> FVoiceInterfaceVivox::SetLobbyUid) writes through
        # the voice interface without a null check and crashes at the menu.
        path = configs / "KFEngine.ini"
        if path.exists():
            path.write_text(set_ini(read_ini(path), "VoIP", {"bHasVoiceEnabled": "true"}), encoding="utf-16")
        f8_command = ("KF2VRAvatarToggleCamera" if avatar and not args.vr else
                      "KF2VRThirdPersonToggle" if args.vr and not avatar else None)
        if f8_command:
            path = configs / "KFInput.ini"
            if path.exists():
                path.write_text(preview_camera_binding(read_ini(path), f8_command), encoding="utf-16", newline="")
        if args.vr:
            path = configs / "KFInput.ini"
            if path.exists():
                input_text = set_ini(disable_mouse_look(read_ini(path)), "KFGame.KFPlayerInput", {"bRequiresPushToTalk":"True"})
                path.write_text(input_text, encoding="utf-16", newline="")
            path = configs / "KFEngine.ini"
            path.write_text(set_ini(read_ini(path), "Engine.Engine", {
                "GameViewportClientClassName": "KF2VRNetClient.KF2VRNetViewportClient",
                "bSmoothFrameRate": "False"}), encoding="utf-16")
            quality = getattr(args, "vr_quality", "quality")
            settings = {
                "MotionBlur": "False", "MotionBlurPause": "False", "MotionBlurQuality": "0",
                "AllowRadialBlur": "False",
                "DepthOfField": "False", "DepthOfFieldQuality": "0", "bAllowTemporalAA": "False",
                "PostProcessAA": "False", "UseVsync": "False", "AmbientOcclusion": "False",
                "HBAO": "False", "AllowScreenSpaceReflections": "False", "LensFlares": "False",
                "ImageGrainScaler": "0.500000"}
            # Optional screen effects. HBAO+ is KF2's AmbientOcclusion effect
            # with the HBAO+ technique selected. Lens flares and grain stay off.
            hbao = getattr(args, "hbao", False) is True
            reflections = getattr(args, "reflections", False) is True
            if hbao:
                settings.update({"AmbientOcclusion": "True", "HBAO": "True"})
            if reflections:
                settings["AllowScreenSpaceReflections"] = "True"
            if hbao or reflections:
                settings["ImageGrainScaler"] = "0.000000"
            path = configs / "KFSystemSettings.ini"
            text = read_ini(path) if path.exists() else "[SystemSettings]\n"
            text = set_ini(text, "SystemSettings", settings)
            path.write_text(text, encoding="utf-16")
            role["vr_quality"] = quality
            role["args"] += ["-kf2vr-probe", "-kf2vr-network", "-kf2vr-stereo"]
            # Fixed render modes (Kvasir94, 11-05, #200): UE3's own render thread,
            # and single-pass stereo, on Steam and Epic.
            role["args"].append("-kf2vr-threaded-render" if getattr(args, "threaded_render", True) else "-onethread")
            if getattr(args, "frame_timings", False):
                # Coarse stage timers and a non-blocking GPU query every 30th
                # frame; the costly per-script-call tracing stays off.
                role["args"].append("-kf2vr-frame-timings")
            if getattr(args, "single_pass", True):
                role["args"].append("-kf2vr-single-pass")
            role["native_adapter"] = True
            role["dlss"] = getattr(args, "dlss", None) or "off"
            role["dlss_sharpness"] = int(getattr(args, "dlss_sharpness", None) or 0)
            role["hide_bile_lens"] = getattr(args, "hide_bile_lens", True) is not False
            role["hide_blood_lens"] = getattr(args, "hide_blood_lens", True) is not False
            requested_percent = getattr(args, "eye_render_percent", None)
            role["eye_render_percent"] = import_preferences(configs, eye_percent=requested_percent,
                                                            root=getattr(args, "profile_root", None))
            # Enable the capability on both bridge classes after importing the
            # profile. Individual effects are owned by Graphics; a stale legacy
            # capability flag must not silently override those live choices.
            path = configs / "KFGame.ini"
            text = read_ini(path)
            # The launcher owns the standing-hold choice. Written after the
            # profile import, to the solo bridge and its network subclass, so a
            # value an earlier session's SaveConfig left behind never wins.
            standing = {"bExperimentalStandingHolds": "False", "bVRScreenEffects": "True"}
            for section in ("KF2VR.VRHandsBridge", VR_SECTION_ALIASES["KF2VR.VRHandsBridge"]):
                text = set_ini(text, section, standing)
            path.write_text(text, encoding="utf-16")
    if getattr(args, "solo", False):
        # Ordinary VR Solo loads no mutator, so stock keeps the match ranked and
        # grants XP; VRGameViewportClient attaches the hands. Test control (and
        # the fixture that sets vr_demo) still needs the VRDemo chain, and a
        # zed spawn override loads the Unofficial KF2 Patch.
        vr_demo = args.vr and (getattr(args, "local_test_control", False) or getattr(args, "vr_demo", False))
        role["args"][0] = solo_url(args, vr_demo)
        # Solo is standalone.
        role["args"] = [a for a in role["args"] if a != "-kf2vr-network"]
        if args.vr:
            path = configs / "KFEngine.ini"
            path.write_text(set_ini(read_ini(path), "Engine.Engine", {
                "GameViewportClientClassName": ("KF2VRNetClient.KF2VRNetViewportClient" if args.map == range_map.MAP_NAME
                                                else "KF2VR.VRGameViewportClient")}), encoding="utf-16")
            path = configs / "KFGame.ini"
            text = set_ini(read_ini(path), "KF2VR.VRHandsBridge", {"bIndependentHands": "True", "bApplyVRRenderSettings": "True"})
            text = set_ini(text, "KF2VR.VRDemo", {"bNormalGame": "True", "bRenderDiagnostic": "False"})
            text = set_ini(text, "KF2VR.VRSessionUI", {"LocalMutators": ""})
            path.write_text(text, encoding="utf-16")
    if local_test_requested(args):
        developer_tool("local_test_control").configure_role(role, args, name)
    if test_map:
        add_map_path(configs, args.test_map_path)
    elif name == "driver" and getattr(args, "menu_map_path", None):
        # The VR menu can start Solo on Remilly from any session; mount it
        # wherever this PC already has it so that choice can load.
        add_map_path(configs, args.menu_map_path)
    configure_content(configs, args, server=name == "server")
    configure_mod_settings(role, args, game, user)
    if name == "driver" and not args.vr:
        desktop_settings.apply(configs, user, getattr(args, "profile_root", None))
    elif name == "driver" and args.vr:
        import settings_graphics
        graphics_migration=settings_graphics.legacy_independent(configs, getattr(args,"profile_root",None) or __import__("vr_config").profile_root())
        settings_graphics.apply_baseline(configs, getattr(args,"vr_quality","quality"))
        vr_graphics.apply(configs, getattr(args, "profile_root", None),
                          reset=getattr(args, "vr_quality_requested", None) is not None, preset=getattr(args,"vr_quality","quality"), migration=graphics_migration)
        path = configs / "KFGame.ini"
        text = read_ini(path)
        for section in ("KF2VR.VRSessionUI", VR_SECTION_ALIASES["KF2VR.VRSessionUI"]):
            text = set_ini(text, section, launch_graphics_summary(args))
        path.write_text(text, encoding="utf-16")
    if name == "driver":
        # Personal client effects, applied after desktop profile restoration too.
        path = configs / "KFEngine.ini"
        level = 0  # FleX is retired; stale profiles and flags cannot enable it.
        path.write_text(set_ini(read_ini(path), "Engine.Engine", {"PhysXLevel": str(level)}), encoding="utf-16")
    role["config_hashes"] = config_hashes(configs)
    return role


def launch_graphics_summary(args):
    """The two read-only lines VR SETTINGS > GRAPHICS shows for launch-time effects."""
    dlss = (getattr(args, "dlss", None) or "off").upper().replace("ULTRAPERFORMANCE", "ULTRA PERFORMANCE")
    first = (getattr(args, "vr_quality", None) or "quality").upper() + " PRESET  DLSS " + dlss
    if dlss != "OFF" and getattr(args, "dlss_sharpness", 0):
        first += f"  SHARPEN {int(args.dlss_sharpness)}"

    on = lambda value: "ON" if value else "OFF"
    second = (f"AO {on(getattr(args, 'hbao', settings_registry.default('hbao')))}  REFLECTIONS {on(getattr(args, 'reflections', settings_registry.default('reflections')))}"
              f"  SINGLE-PASS {on(getattr(args, 'single_pass', True))}")
    mode = settings_registry.DLSS_MODES.index(getattr(args,"dlss",None) or "off")
    return {"LaunchGraphicsSummary": first, "LaunchEffectsSummary": second, "LaunchDlssMode":str(mode),
            "RequestedDlssMode":str(mode), "DlssSharpness":str(getattr(args,"dlss_sharpness",None) or 0),
            "bBileSplatter":"False" if getattr(args,"hide_bile_lens",True) else "True",
            "bBloodSplatter":"False" if getattr(args,"hide_blood_lens",True) else "True"}


def default_data_roots():
    """Dedicated server and Workshop cache folders when the player has not chosen any.

    Players extract the release into Documents or the Desktop, which OneDrive
    and Google Drive back up: the sync client locks the 32 GB server files as
    SteamCMD writes them and the download aborts. Default to a "KF2-VR Data"
    folder at the root of the game's drive instead, which already holds KF2 and
    is not synced. A server or cache that an earlier release installed beside
    the release stays in use.
    """
    roots = {}
    try:
        machine = machine_settings.load(ROOT)
        game = machine.get("game_root") or find_game()
    except OSError:
        machine, game = {}, None
    base = Path(Path(game).anchor) / "KF2-VR Data" if game and Path(game).anchor else SHARED
    for dest, name, ready in (("server_root", "KF2VR-Server", "Binaries/Win64/KFServer.exe"),
                              ("cache_root", "KF2VR-Cache", "")):
        legacy = SHARED / name
        roots[dest] = legacy if (legacy / ready).exists() and (ready or any(legacy.iterdir())) else base / name
    # A server folder this PC has or the player chose (machine.json "server_root", set by the player window's
    # Host > Change folder, which creates it) is used as is; the first Host downloads the server into it.
    chosen = machine.get("server_root")
    if chosen and ((Path(chosen) / "Binaries/Win64/KFServer.exe").exists() or Path(chosen).is_dir()):
        roots["server_root"] = Path(chosen)
    return roots


def parse_options(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    settings_registry.add_arguments(parser, types={"mods": parse_mods, "eye_render_percent": eye_render_percent},
                                    defaults=default_data_roots())
    args = parser.parse_args(argv)
    if args.locomotion_preview:
        if not args.host or args.vr or args.solo or args.avatar_preview or args.replay_match:
            parser.error("--locomotion-preview requires --host and desktop quiet inspection; omit --vr, --solo, --avatar-preview and --replay-match")
        args.replay_teammate = True
        args.desktop = True

    try:
        if local_test_requested(args):
            developer_tool("local_test_control").validate_options(args)
    except RuntimeError as error:
        parser.error(str(error))
    if not args.host and (args.server_name is not None or args.open_server is not None or args.workshop_desktop is not None
                          or args.zed_grabs is not None or args.gravity_grab is not None):
        parser.error("--server-name, --open-server, --workshop-desktop, --zed-grabs and --gravity-grab require --host")
    if args.share_address and (not args.host or not re.fullmatch(r"[A-Za-z0-9.-]{1,253}", args.share_address)):
        parser.error("--share-address requires --host and an IP address or hostname without a port or URL")
    if args.solo and (args.host or args.address or args.replay_teammate or args.avatar_preview):
        parser.error("--solo cannot be combined with Host/Join or diagnostic sessions")
    args.mods_requested = args.mods is not None
    # Which selections the caller made, as opposed to which ones the profile
    # will supply. Map, difficulty, length, quality and focus stay None here
    # and are resolved in load_preferences.
    args.mode_requested = args.vr or args.desktop
    args.map_requested = args.map is not None or args.test_map
    if args.vr and args.desktop:
        parser.error("Choose either --vr or --desktop")
    if args.desktop:
        args.vr = False
    if args.inventory_focus and not args.host:
        parser.error("--inventory-focus requires --host; the remote host controls shared slowdown")
    if args.test_map_players is not None and not args.host:
        parser.error("--test-map-players requires --host; the remote host controls scaling")
    if (args.replay_teammate or args.avatar_preview) and (args.mods or args.damage_popups is not None or args.test_map_players is not None):
        parser.error("Mod selections are for normal play; omit replay/preview modes")
    if (args.menu or args.map or args.difficulty or args.game_length or args.max_zeds is not None
            or args.wave_zeds_percent is not None or args.spawn_rate_percent is not None) and not (args.host or args.solo):
        parser.error("Map/difficulty/match length/zed spawns require --host or --solo")
    if args.menu and (args.replay_teammate or args.avatar_preview):
        parser.error("--menu is for normal play; omit replay/preview modes")
    if args.map and not re.fullmatch(r"KF-[A-Za-z0-9_-]+", args.map):
        parser.error("--map must be a KF- map name, without a path, extension or URL options")
    if args.test_map and args.map and args.map != MAP_NAME:
        parser.error("Choose either --test-map or a different --map")
    args.test_map = args.test_map or args.map == MAP_NAME
    if args.test_map and (not (args.host or args.solo) or args.replay_teammate or args.avatar_preview):
        parser.error("--test-map requires --host or --solo and cannot be combined with replay/preview modes")
    if args.test_mode and (not (args.host or args.solo) or args.replay_teammate or args.avatar_preview
                           or args.locomotion_preview):
        parser.error("--test-mode requires --host or --solo and cannot be combined with replay/preview modes")
    if args.solo and args.test_map and args.store != "steam":
        parser.error("The cached Solo test map requires explicit --store steam.")
    args.vr_quality_requested = args.vr_quality
    # Checked against an explicit flat-screen request only: with neither flag
    # the play mode is still the profile's to decide.
    if args.desktop and (args.headset_preset is not None or args.vr_quality is not None or args.eye_render_percent is not None):
        parser.error("--headset-preset, --vr-quality and --eye-render-percent require VR play; omit --desktop")
    if args.frame_timings and not args.vr:
        parser.error("--frame-timings requires --vr")
    if getattr(args, "dlss", None) not in (None, "off") and not args.vr:
        parser.error("--dlss requires --vr")
    if args.dlss_sharpness is not None and not 0 <= args.dlss_sharpness <= 100:
        parser.error("--dlss-sharpness must be from 0 to 100")
    if args.desktop and any(getattr(args, key) is not None for key in ("hbao", "reflections", "hide_blood_lens")):
        parser.error("HBAO, reflections and blood lens choices require VR play; omit --desktop")
    if (args.eye_render_percent is not None and not args.vr
            and (args.desktop or args.replay_teammate or args.avatar_preview or not (args.host or args.solo))):
        parser.error("--eye-render-percent requires --vr")
    if args.avatar_preview:
        if not args.host:
            parser.error("--avatar-preview requires --host; preview connections stay on this PC")
        if args.replay_match:
            parser.error("--avatar-preview uses quiet inspection; omit --replay-match")
        args.replay_teammate = True
    if args.replay_teammate and not args.host:
        parser.error("--replay-teammate requires --host; all replay connections stay on this PC")
    if args.replay_match and not args.replay_teammate:
        parser.error("--replay-match requires --replay-teammate")
    if not (1 <= args.port <= 65535 and 1 <= args.query_port <= 65535) or args.port == args.query_port:
        parser.error("Choose distinct game/query ports from 1 to 65535")
    if args.duration is not None and not 5 <= args.duration <= 7200:
        parser.error("--duration must be 5..7200 seconds")
    ports = [p + offset for p in (args.port, args.query_port)
             for offset in ((0, 10, 20) if args.replay_teammate else (0, 10))]
    if len(ports) != len(set(ports)):
        parser.error("Game/query ports and their client offsets overlap")
    if args.host and max(ports) > 65535:
        parser.error("Hosting needs game/query ports low enough for their client offsets (up to 65535)")
    return args


def validate_play_mode(args):
    if local_test_requested(args):
        developer_tool("local_test_control").validate_options(args)
    if (args.promo_events or args.record_motion) and (not args.vr or args.replay_teammate or args.avatar_preview or args.locomotion_preview):
        raise RuntimeError("Motion recording and highlight events require live VR play; omit desktop and replay/preview options.")
    # Profile and menu choices resolve after parsing. An explicit VR override
    # must not silently disappear when the resolved play mode is Desktop.
    if not args.vr and (getattr(args, "headset_preset", None) is not None
                       or getattr(args, "vr_quality_requested", None) is not None
                       or args.eye_render_percent is not None):
        raise RuntimeError("VR graphics and headset render scale require VR play; choose --vr or remove the override.")


def validate_dlss_package(args, manifest):
    # Auto only asks; without a runtime the adapter renders natively.
    if args.vr and getattr(args, "dlss", "off") not in (None, "off", "auto") and not manifest.get("native_build", {}).get("dlss_enabled", False):
        raise ValueError("This package has no DLSS runtime. Choose DLSS Off or use a DLSS-enabled package.")


def active_openxr_runtime():
    """The active OpenXR runtime manifest and its display name; raises if unusable."""
    import winreg
    with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\Khronos\OpenXR\1") as key:
        runtime = Path(winreg.QueryValueEx(key, "ActiveRuntime")[0])
    if not runtime.is_file():
        raise OSError("Runtime manifest is missing")
    data = json.loads(runtime.read_text(encoding="utf-8-sig"))
    library = Path(data["runtime"]["library_path"])
    if not library.is_absolute():
        library = runtime.parent / library
    if not library.is_file():
        raise OSError("Runtime library is missing")
    name = data["runtime"].get("name")
    return runtime, name if isinstance(name, str) and name else runtime.stem


def preflight(manifest, game, vr):
    launcher_events.phase("checking")
    print("Build: " + manifest.get("build_id", ROOT.name), flush=True)
    print(f"KF2 installation: {game}; executable SHA-256: {manifest['game_sha256']}", flush=True)
    print("Package integrity: verified. Native files are deployed temporarily and restored after play.", flush=True)
    if vr:
        try:
            runtime, _ = active_openxr_runtime()
            print("Active OpenXR runtime: " + str(runtime), flush=True)
        except (OSError, KeyError, ValueError) as error:
            raise RuntimeError("No usable active OpenXR runtime. Enable your headset runtime, then retry. " + str(error)) from error
        # The adapter/loader use static C++ runtimes; the private Python
        # distribution carries its own vcruntime DLLs. A System32 VC++ 2015
        # installation is therefore not a prerequisite for this package.


def main():
    args = parse_options()
    launcher_events.configure(args.events)
    manifest = json.loads((ROOT / "release.json").read_text(encoding="utf-8"))
    for name, expected in manifest["files_sha256"].items():
        if not (ROOT / name).resolve().is_relative_to(ROOT.resolve()) or digest(ROOT / name) != expected:
            raise RuntimeError(f"Package file changed or missing: {name}. Extract a fresh copy.")
    saved = machine_settings.load(ROOT, getattr(args, "profile_root", None))
    install = game_install.select_for_launch(store=args.store, root=args.game_root, saved_root=saved.get("game_root"))
    game_install.validate_native(install, manifest.get("supported_game_sha256", [manifest["game_sha256"]]))
    args.store = install.store
    game, exe = install.root, install.executable
    for notice in launch_notices(install.store):
        print(notice, flush=True)
    if install.store == "epic":
        from epic_manual import run_session
        return run_session(args, manifest, install)
    if args.recover_epic:
        raise RuntimeError("Epic recovery requires --store epic and the Epic installation.")
    if (exe.parent / "dinput8.dll").exists():
        raise RuntimeError("Another VR/mod session has a native proxy installed. Close it and let its launcher clean up first.")
    load_preferences(args)
    if args.host or args.solo:
        maps = installed_solo_maps(game) if args.solo else installed_maps(game, args.server_root)
        if args.solo:
            resolve_solo_map(args, maps)
        if args.menu and not choose_options(args, maps):
            return 0
        if args.solo:
            resolve_solo_map(args, maps)
        if not args.test_map and args.map not in maps:
            raise RuntimeError(f"Map {args.map} is not available locally or in the managed Workshop list. Use --menu to choose an available map.")
    validate_play_mode(args)
    validate_dlss_package(args, manifest)
    preflight(manifest, game, args.vr)
    if args.solo:
        args.address, args.password = "127.0.0.1", "solo-unused"
        args.mods = []
        require_ukfp_for_spawns(args)
    elif args.host:
        args.address = "127.0.0.1"
        require_ukfp_for_spawns(args)
        resolve_host_identity(args, saved)
    else:
        args.address = args.address or input(f"Paste join code (or host address) [{saved.get('address', '')}]: ").strip() or saved.get("address", "")
        if args.address.startswith(join_code.PREFIX):
            details = join_code.decode(args.address, manifest["build_id"])
            for key in ("address", "password", "port", "query_port", "mods", "map"):
                setattr(args, key, details[key])
            args.mods_requested = True
            args.test_map = args.map == MAP_NAME
            print("Join code accepted. Host connection and content settings applied.", flush=True)
            launcher_events.phase("join-accepted")
        else:
            if args.password is None:
                args.password = input("Session password (Enter for none): ").strip()
    if not re.fullmatch(r"[a-zA-Z0-9.-]+", args.address or ""):
        raise RuntimeError("Enter the host IP address or hostname, without a port or URL.")
    if not re.fullmatch(r"[a-zA-Z0-9_-]{0,64}", args.password or ""):
        raise RuntimeError("Use a session password containing letters, numbers, underscore or hyphen, or none.")
    saved.update(game_root=str(game), address=args.address, store="steam")
    machine_settings.save(saved, getattr(args, "profile_root", None))
    # Use the Windows known-folder API through the standard registry for moved
    # Documents folders (including OneDrive), rather than assuming USERPROFILE.
    import winreg
    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders") as key:
        documents = Path(os.path.expandvars(winreg.QueryValueEx(key, "Personal")[0]))
    user = documents / "My Games/KillingFloor2/KFGame/Config"
    before = config_hashes(user)
    if not before:
        raise RuntimeError("Start standard KF2 once, then close it and run this launcher again.")
    steam_root = args.server_root.parent / "steamcmd"
    if args.test_map:
        args.test_map_path = (cached_solo_map(args.cache_root) if args.solo else
                             ensure_map(args.cache_root, steam_root, download=not args.prepare_only))
    elif args.vr and args.store == "steam":
        # The launcher's SteamCMD (current and pre-move layouts), then a
        # Steam Workshop subscription in the game's own library.
        args.menu_map_path = installed_map(args.cache_root, steam_root, SHARED / "steamcmd",
                                           Path(game).parents[2] if len(Path(game).parents) > 2 else None)
    prepare_content(args, game, steam_root)
    if args.host and args.workshop_desktop:
        from workshop_loadout import verify_desktop_workshop
        try:
            verify_desktop_workshop(args, game, steam_root, ROOT)
        except RuntimeError as error:
            # Hosting without Workshop delivery is safe: VR friends with this
            # build still join. Only this session drops it; the saved choice stays.
            print("Desktop Workshop joining is off for this session: the KF2-VR item on the Steam Workshop "
                  f"could not be matched to this exact build ({str(error).rstrip('.')}). "
                  "Hosting continues: friends using this KF2-VR build can join, and desktop players "
                  "can join after installing this build's KF2-VR ZIP.", flush=True)
            args.workshop_desktop = False
            args.workshop_desktop_session_off = True
    run = ROOT / "sessions" / datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S-%f")
    names = ["server", "driver"] if args.host else ["driver"]
    if args.replay_teammate:
        names.append("teammate")
    roles = [configure_role(run, name, user, game, args) for name in names]
    promo_id = developer_tool("promo_session").configure(roles, True) if args.promo_events else None
    capture = (developer_tool("motion_session").configure(roles, args.record_motion)
               if args.record_motion or promo_id else None)
    player_role = next(role for role in roles if role["role"] == "driver")
    # Host and Solo share common choices; save_preferences retains the hosted
    # loadout when Solo's effective content selection is empty.
    if (args.host or args.solo) and not args.replay_teammate:
        save_preferences(args)
    elif not args.replay_teammate:
        save_dlss_preferences(args)
    record = {"launcher_pid": os.getpid(), "launcher_creation_time": creation_time(api(), ctypes.windll.kernel32.GetCurrentProcess()),
              "build_id": manifest.get("build_id", ROOT.name), "protocol_version": manifest.get("protocol_version"),
              "session_mode": "solo" if args.solo else ("host" if args.host else "join"),
              "status": "prepared", "roles": roles, "host": args.host, "vr": args.vr,
              "mods": args.mods, "damage_popups": damage_popups_enabled(args) and "ukfp" in args.mods,
              "damage_popups_requested": args.damage_popups and "ukfp" in args.mods,
              "test_map_players": args.test_map_players if args.test_map and "ukfp" in args.mods else 0,
              "workshop_content": args.workshop_content,
              "test_map": args.test_map, "test_mode": args.test_mode,
              "host_map": MAP_NAME if args.test_map else args.map,
              "difficulty": args.difficulty, "game_length": args.game_length,
              "max_zeds": args.max_zeds, "wave_zeds_percent": args.wave_zeds_percent,
              "spawn_rate_percent": args.spawn_rate_percent,
              "inventory_focus": args.inventory_focus,
              "test_map_receipt": map_receipt(args.test_map_path) if args.test_map else None,
              "release": ROOT.name, "release_manifest_sha256": digest(ROOT / "release.json"),
              "user_config_before": before, "user_config_root": str(user), "mod_handshake_observed": False,
              "replay_teammate": args.replay_teammate, "replay_match": args.replay_match,
              "avatar_preview": args.avatar_preview,
              "vr_quality": player_role.get("vr_quality"),
              "vr_quality_requested": args.vr_quality_requested,
              "eye_render_percent": player_role.get("eye_render_percent"),
              "eye_render_percent_requested": args.eye_render_percent,
              "frame_timings": args.frame_timings, "threaded_render": getattr(args, "threaded_render", True),
              "promo_events": args.promo_events, "promo_session_id": promo_id,
              "capture": capture, "record_motion": args.record_motion}
    if capture:
        print(f"Capture session: {capture['capture_session_id']} UTC {capture['capture_session_started_utc']}", flush=True)
        if args.record_motion:
            print(f"Replay recording output: {capture['motion_session_dir']}", flush=True)
        if args.promo_events:
            print("Highlight event output: " + ", ".join(role['promo_log'] for role in roles if role.get('promo_log')), flush=True)
    if args.avatar_preview:
        record["capture_search_started_unix"] = time.time()
    output = run / "run.json"
    def save():
        save_session_record(output, record)
    save()
    print(f"Session details: {output}", flush=True)
    if args.prepare_only:
        return 0
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.CreateMutexW.restype = ctypes.c_void_p
    kernel.CreateMutexW.argtypes = (ctypes.c_void_p, ctypes.c_int, ctypes.c_wchar_p)
    kernel.WaitForSingleObject.argtypes = (ctypes.c_void_p, ctypes.c_uint)
    kernel.ReleaseMutex.argtypes = (ctypes.c_void_p,)
    kernel.CloseHandle.argtypes = (ctypes.c_void_p,)
    mutex = kernel.CreateMutexW(None, False, "Local\\KF2VR_DevelopmentFixture")
    locked = False
    owned = []
    deployment = None
    server_deployment = None
    try:
        locked = bool(mutex) and kernel.WaitForSingleObject(mutex, 0) in (0, 0x80)
        if not locked:
            raise RuntimeError("Another KF2-VR session is running.")
        if re.search(r'"KF(?:Game|Editor|Server)\.exe"', subprocess.check_output(["tasklist", "/FO", "CSV", "/NH"], text=True), re.I):
            raise RuntimeError("Close KF2 and its SDK before starting this session.")
        if args.replay_teammate:
            ports = [args.port + offset for offset in (0, 10, 20)] + [args.query_port + offset for offset in (0, 10, 20)]
            if len(set(ports)) != len(ports):
                raise RuntimeError("Visual-test game/query ports overlap.")
            for port in ports:
                check_port(port)
        # role_environment() admits only the diagnostic capture root of these.
        env = {k: v for k, v in os.environ.items()
               if not k.upper().startswith("KF2VR_") or k.upper() == "KF2VR_CAPTURE_ROOT"}
        env.update(SteamAppId="232090", SteamGameId="232090")
        with (run / "watchdog.log").open("wb") as watcher_log:
            watcher = subprocess.Popen([sys.executable, str(Path(__file__).with_name("watchdog.py")),
                str(output), str(os.getpid())], stdin=subprocess.DEVNULL, stdout=watcher_log,
                stderr=subprocess.STDOUT, creationflags=subprocess.DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP)
        record["watchdog_pid"] = watcher.pid
        save()
        def start(role, executable, working, hidden):
            startup = subprocess.STARTUPINFO()
            startup.dwFlags = subprocess.STARTF_USESHOWWINDOW
            startup.wShowWindow = 0 if hidden else 1
            child_env = role_environment(env, role)
            with Path(role["log"]).with_name("console.log").open("wb") as console:
                process = subprocess.Popen(unreal_command(executable, role["args"]), cwd=working, env=child_env,
                    startupinfo=startup, stdin=subprocess.DEVNULL, stdout=console, stderr=subprocess.STDOUT)
            owned.append((role, process))
            role["pid"] = process.pid
            role["creation_time"] = creation_time(api(), process._handle)
            save()
            return process
        server = None
        ensure_steam()
        if args.host:
            print("Preparing the free dedicated server. The first download is about 9 GB and needs about 35 GB of free disk space.", flush=True)
            launcher_events.phase("server-install")
            install_env = env.copy()
            # PowerShell 7's inherited module path can hide Windows PowerShell
            # 5.1 built-ins. Let the shipped Windows shell initialize its own.
            install_env = {k: v for k, v in install_env.items() if k.upper() != "PSMODULEPATH"}
            install_server(args.server_root, install_env)
            launcher_events.phase("server-starting")
            server_deployment = NativeDeployment(ROOT / "ServerNative", args.server_root / "Binaries/Win64",
                run / "server-native-backup", {"artifacts_sha256": manifest["native_build"]["server_artifacts_sha256"]},
                digest, server=True)
            record["server_native_deployment"] = {"source": str(server_deployment.source),
                "destination": str(server_deployment.destination), "backup": str(server_deployment.backup),
                "receipt": server_deployment.receipt, "server": True}
            save()
            server_deployment.install()
            server = start(roles[0], args.server_root / "Binaries/Win64/KFServer.exe", args.server_root, True)
            # A copied DLL is not evidence that its entry point ran. The old
            # fixture passed an extra client probe flag and hid this failure.
            native_log = Path(roles[0]["log"]).with_name("native.log")
            ready_deadline = time.monotonic() + 20
            while time.monotonic() < ready_deadline:
                if native_log.exists() and server_adapter_ready(native_log.read_text(errors="replace")):
                    record["server_adapter_ready"] = True
                    save()
                    break
                if server.poll() is not None:
                    break
                time.sleep(0.1)
            if not record.get("server_adapter_ready"):
                raise RuntimeError(f"VR server adapter or XP hooks did not initialize; see {native_log}")
        if not args.solo:
            print("Checking the server and VAC status...", flush=True)
            launcher_events.phase("connecting")
            deadline = time.monotonic() + (120 if args.host else 15)
            last_error = "no response"
            while time.monotonic() < deadline:
                if server and server.poll() is not None:
                    raise RuntimeError("Dedicated server exited. See the server log in session details.")
                try:
                    info = query_server(args.address, args.query_port)
                    validate_server_query(info, args.password)
                    if server and "OnServerDataUpdateResponse complete successfully" not in log_text(roles[0]):
                        raise ValueError("Server registration is still starting")
                    record["server_query"] = info
                    break
                except (OSError, ValueError) as error:
                    last_error = str(error)
                    time.sleep(0.5)
            else:
                raise RuntimeError(f"Cannot verify server: {last_error}. Check host address and UDP query port {args.query_port}.")
        if args.vr or args.replay_teammate:
            deployment = NativeDeployment(ROOT / "Native", exe.parent, run / "native-backup",
                manifest["native_build"], digest)
            record["native_deployment"] = {"source": str(deployment.source), "destination": str(deployment.destination),
                "backup": str(deployment.backup), "receipt": deployment.receipt}
            save()
            deployment.install()
        if args.host:
            announce_host(args, manifest, log_text(roles[0]))
        client = start(player_role, exe, exe.parent, bool(args.duration) and not (args.avatar_preview or args.locomotion_preview))
        teammate = None
        if args.replay_teammate:
            print("Waiting for your lobby before starting the replay teammate...", flush=True)
            deadline = time.monotonic() + 120
            while time.monotonic() < deadline:
                if client.poll() is not None or server.poll() is not None:
                    raise RuntimeError("A game process exited during visual-test setup.")
                if any(e.get("hello", "").lower() == "true" and e.get("perk_ready", "").lower() == "true"
                       for e in events(log_text(player_role), "status")):
                    break
                time.sleep(0.5)
            else:
                raise RuntimeError("Your lobby/perk did not initialize before the replay startup limit.")
            teammate = start(roles[-1], exe, exe.parent, True)
        record["status"] = "playing"
        save()
        launcher_events.phase("game-starting")
        if teammate:
            if args.locomotion_preview:
                print("Locomotion inspection: actual remote pawn, repeating 32-second cycle: "
                      "4s idle, 8s roomscale, 4s idle, 8s stick walking, 8s idle. Close your game to finish.", flush=True)
            else:
                print("Visual test: automatic Ready. Replay_Teammate starts its sequence after 20 seconds, "
                      "then repeats with 15-second pauses while stock ammo lasts. Close your game to finish.", flush=True)
            if args.avatar_preview:
                print("Avatar preview: the live player's observer rig uses recorded teammate poses. "
                      "This inspection does not establish live tracking or shot accuracy.", flush=True)
        else:
            print("KF2 is starting. Choose your perk and Ready. Keep this launcher open; closing the game cleans up the session.", flush=True)
        end = time.monotonic() + args.duration if args.duration else float("inf")
        next_memory_sample = time.monotonic()
        while client.poll() is None and time.monotonic() < end:
            if time.monotonic() >= next_memory_sample:
                # One kernel query every 5 s from the launcher process; the game does no work for it.
                peak = peak_working_set_mib(client)
                if peak:
                    player_role["peak_working_set_mib"] = peak
                next_memory_sample += 5
            if server and server.poll() is not None:
                raise RuntimeError("Dedicated server stopped during play.")
            if teammate and teammate.poll() is not None:
                raise RuntimeError("Replay teammate exited; see its game log.")
            if not record["mod_handshake_observed"] and re.search(r"KF2VRNet status .*hello=True .*netmode=NM_Client", log_text(player_role)):
                record["mod_handshake_observed"] = True
                save()
            if teammate and not record.get("replay_sequence_observed") and any(
                e.get("phase") == "complete" for e in events(log_text(roles[-1]), "fire_fixture")):
                record["replay_sequence_observed"] = True
                save()
            time.sleep(0.5)
        # The game quits within a second when Steam is closed: say so instead of a normal close.
        if client.poll() is not None and "STEAM is required to play the game" in log_text(player_role):
            raise RuntimeError(STEAM_NOT_RUNNING)
        record["status"] = "closed"
    except BaseException as error:
        record.update(status="failed", error=str(error))
        raise
    finally:
        errors = []
        for role, process in cleanup_order(owned, args.avatar_preview):
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
            role["exit_code"] = process.returncode
            if role is player_role:
                role["peak_working_set_mib"] = peak_working_set_mib(process) or role.get("peak_working_set_mib")
        if deployment:
            errors += deployment.restore()
        if server_deployment:
            errors += server_deployment.restore()
        try:
            export_session_preferences(record, root=getattr(args, "profile_root", None))
        except (OSError, ValueError) as error:
            errors.append(f"Could not save preferences: {error}")
        record["user_config_preserved"] = before == config_hashes(user)
        record["cleanup_errors"] = errors
        record["cleanup_complete"] = not errors and record["user_config_preserved"]
        if errors or not record["user_config_preserved"]:
            record["status"] = "cleanup_failed"
        try:
            if args.avatar_preview:
                record["avatar_captures"] = avatar_capture_receipt(run, user, player_role,
                    record["capture_search_started_unix"], 0 if args.vr else 6)
            save()
        finally:
            if locked:
                kernel.ReleaseMutex(mutex)
            if mutex:
                kernel.CloseHandle(mutex)
    return 0 if record["status"] == "closed" else 1


if __name__ == "__main__":
    try:
        code = main()
        if code == 0:
            launcher_events.emit(done=True)
        else:
            launcher_events.fail("The session did not close cleanly.")
        raise SystemExit(code)
    except Exception as error:
        print(f"\nCould not start/finish KF2-VR: {error}", flush=True)
        launcher_events.fail(error)
        raise SystemExit(1)
