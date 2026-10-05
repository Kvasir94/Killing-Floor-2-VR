"""Host/join launcher shipped with the multiplayer prototype. No SDK required."""
from __future__ import annotations

import argparse
import ctypes
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import sys
import time

from evidence import query_server
from native_fixture import NativeDeployment
from vr_config import import_preferences, export_preferences
import desktop_settings
import local_test_control
import join_code
import breacher
from workshop_map import MAP_NAME, ensure_map, add_map_path, receipt as map_receipt
from launch_menu import (DIFFICULTIES, LENGTHS, host_url, installed_maps,
                         installed_solo_maps, resolve_solo_map, choose_options)
from workshop_loadout import (parse_mods, load_preferences, save_preferences, prepare_content,
                              configure_content, configure_mod_settings, damage_popups_enabled, HEADSET_PRESETS)
from session import digest, config_hashes, role_config, set_ini, read_ini, log_text, unreal_command, check_port
from watchdog import api, creation_time
from evidence import events

ROOT = Path(__file__).resolve().parents[2]
# Server and Workshop cache sit beside the extracted release so later releases
# reuse them. A ZIP keeps the release in app/ under its own top-level folder.
SHARED = ROOT.parent.parent if ROOT.name.lower() == "app" else ROOT.parent


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
    if role.get("server_adapter"):
        result["KF2VR_SERVER_LOG_PATH"] = str(Path(role["log"]).with_name("native.log"))
    if "eye_render_percent" in role:
        percent = role["eye_render_percent"]
        if (role["role"] != "driver" or not role["native_adapter"] or "-kf2vr-stereo" not in role["args"]
                or type(percent) is not int or not 50 <= percent <= 100):
            raise ValueError("Eye resolution is valid only for the live VR driver, from 50 to 100 percent")
        result["KF2VR_EYE_RENDER_PERCENT"] = str(percent)
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


def find_game() -> Path | None:
    import winreg
    candidates = [Path("D:/SteamLibrary"), Path("C:/Program Files (x86)/Steam")]
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Valve\Steam") as key:
            steam = Path(winreg.QueryValueEx(key, "SteamPath")[0])
        candidates.insert(0, steam)
        vdf = steam / "steamapps/libraryfolders.vdf"
        if vdf.exists():
            candidates += [Path(p.replace("\\\\", "\\")) for p in
                           re.findall(r'"path"\s+"([^"]+)"', vdf.read_text(encoding="utf-8"))]
    except OSError:
        pass
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
        text = set_ini(text, "KF2VRNet.KF2VRNetGame", {
            "bServerAdapter": "true", "bIndependentWeapons": "false" if replay and not locomotion else "true",
            "bInventoryFocusEnabled": "true" if getattr(args, "inventory_focus", False) else "false",
            "bMultiplayerZedGrabAllowed": "true" if getattr(args, "multiplayer_grabs", False) else "false"})
        role["server_adapter"] = True
        role["args"] += ["-kf2vr-server-adapter"]
    # Remote friends use stock authentication. The localhost test exception must
    # not leak into a shipped remote-client configuration.
    text = set_ini(text, "Engine.AccessControl", {"GamePassword": args.password,
                   "bAuthenticateServer": "false" if args.address == "127.0.0.1" else "true"})
    path.write_text(text, encoding="utf-16")
    server_url = host_url(args)
    role["args"][0] = (server_url
                        if name == "server" else f"{args.address}:{args.port}?Password={args.password}" + breacher.options(args))
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
            path = configs / "KFEngine.ini"
            path.write_text(set_ini(read_ini(path), "Engine.Engine", {
                "GameViewportClientClassName": "KF2VRNetClient.KF2VRNetViewportClient",
                "bSmoothFrameRate": "False"}), encoding="utf-16")
            quality = getattr(args, "vr_quality", "performance")
            settings = {
                "MotionBlur": "False", "MotionBlurPause": "False", "MotionBlurQuality": "0",
                "AllowRadialBlur": "False",
                "DepthOfField": "False", "DepthOfFieldQuality": "0", "bAllowTemporalAA": "False",
                "PostProcessAA": "False", "UseVsync": "False", "AmbientOcclusion": "False",
                "HBAO": "False", "AllowScreenSpaceReflections": "False", "LensFlares": "False",
                "ImageGrainScaler": "0.500000"}
            path = configs / "KFSystemSettings.ini"
            text = read_ini(path) if path.exists() else "[SystemSettings]\n"
            text = set_ini(text, "SystemSettings", settings)
            if quality == "balanced":
                text = set_ini(text, "SystemSettings", {
                    "MaxDrawDistanceScale": "0.9", "ShadowFilterQualityBias": "1"})
            elif quality == "performance":
                text = set_ini(text, "SystemSettings", {
                    "MaxDrawDistanceScale": "0.8", "ShadowFilterQualityBias": "1",
                    "SkeletalMeshLODBias": "1", "ParticleLODBias": "1", "DynamicShadows": "False",
                    "LightEnvironmentShadows": "False", "StaticDecals": "False"})
            path.write_text(text, encoding="utf-16")
            role["vr_quality"] = quality
            role["args"] += ["-kf2vr-probe", "-kf2vr-network", "-kf2vr-stereo", "-onethread", "-kf2vr-no-portals"]
            if getattr(args, "frame_timings", False):
                # Coarse stage timers and a non-blocking GPU query every 30th
                # frame; the costly per-script-call tracing stays off.
                role["args"].append("-kf2vr-frame-timings")
            if getattr(args, "threaded_render", False):
                # Experimental: UE3's render thread draws frame N while the
                # game thread ticks N+1. Replaces -onethread; no portals.
                role["args"][role["args"].index("-onethread")] = "-kf2vr-threaded-render"
            role["native_adapter"] = True
            requested_percent = getattr(args, "eye_render_percent", None)
            role["eye_render_percent"] = import_preferences(configs, eye_percent=requested_percent,
                                                            root=getattr(args, "profile_root", None))
    if getattr(args, "solo", False):
        role["args"][0] = (f"{args.map}?Game=KFGameContent.KFGameInfo_Survival"
            f"?Difficulty={DIFFICULTIES[args.difficulty]}?GameLength={LENGTHS[args.game_length]}"
            + ("?Mutator=KF2VR.VRBootstrap,KF2VR.VRDemo?VRNormalGame=1" if args.vr else ""))
        role["args"][0] = breacher.add_mutator(role["args"][0], args)
        # Solo is standalone: the experimental Portal Gun's capture hooks are allowed.
        role["args"] = [a for a in role["args"] if a not in ("-kf2vr-network", "-kf2vr-no-portals")]
        if args.vr:
            path = configs / "KFEngine.ini"
            path.write_text(set_ini(read_ini(path), "Engine.Engine", {
                "GameViewportClientClassName": "KF2VR.VRGameViewportClient"}), encoding="utf-16")
            path = configs / "KFGame.ini"
            text = set_ini(read_ini(path), "KF2VR.VRHandsBridge", {"bIndependentHands": "True", "bApplyVRRenderSettings": "True"})
            text = set_ini(text, "KF2VR.VRDemo", {"bNormalGame": "True", "bRenderDiagnostic": "False"})
            text = set_ini(text, "KF2VR.VRSessionUI", {"LocalMutators": "KF2VR.VRBootstrap,KF2VR.VRDemo" + ("," + breacher.MUTATOR if getattr(args, "breacher", False) else "")})
            # Solo-only trader entry; the catalog also refuses it in any networked game.
            text = set_ini(text, "KF2VR.VRTraderCatalog", {"bOfferPortalGun": "True" if getattr(args, "portal_gun", False) else "False"})
            path.write_text(text, encoding="utf-16")
    local_test_control.configure_role(role, args, name)
    if test_map:
        add_map_path(configs, args.test_map_path)
    configure_content(configs, args, server=name == "server")
    breacher.configure_content(configs, args)
    configure_mod_settings(role, args, game, user)
    if name == "driver" and not args.vr:
        desktop_settings.apply(configs, user, getattr(args, "profile_root", None))
    role["config_hashes"] = config_hashes(configs)
    return role


def parse_options(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", action="store_true")
    parser.add_argument("--solo", action="store_true", help="Standalone normal match; no dedicated server")
    parser.add_argument("--menu", action="store_true", help="Interactive match selections before launching; requires --host or --solo")
    parser.add_argument("--map", help="Installed KF- map name (default: KF-BurningParis); requires --host or --solo")
    parser.add_argument("--difficulty", type=str.lower, choices=DIFFICULTIES,
                        help="normal, hard, suicidal, hellonearth (default: normal); requires --host or --solo")
    parser.add_argument("--game-length", type=str.lower, choices=LENGTHS,
                        help="short (4), medium (7), long (10 waves), then boss; default short; requires --host or --solo")
    parser.add_argument("--test-map", action="store_true",
                        help="Host Remilly's Workshop test map with the normal VR game; requires --host")
    parser.add_argument("--vr", action="store_true")
    parser.add_argument("--desktop", action="store_true",
                        help="Flat screen for this session; without either flag Host/Solo uses the saved play mode")
    parser.add_argument("--mods", type=parse_mods,
                        help="Saved VR selection or comma-separated ukfp,friendlyhud,yas,aal,cvc,lti; 'none' disables mods")
    parser.add_argument("--damage-popups", action=argparse.BooleanOptionalAction, default=None,
                        help="Allow UKFP damage popups in Desktop sessions (VR suppresses its flat overlay)")
    parser.add_argument("--inventory-focus", action=argparse.BooleanOptionalAction, default=None,
                        help="Experimental shared slowdown while a VR selector is held (saved, initially off); requires --host")
    parser.add_argument("--multiplayer-grabs", action=argparse.BooleanOptionalAction, default=None,
                        help="Experimental host grab permission for every VR player (saved, initially off); requires --host")
    parser.add_argument("--breacher", action=argparse.BooleanOptionalAction, default=None,
                        help="Optional Deadbolt/Cascade experiment; every player needs the same local compiled package (default OFF)")
    parser.add_argument("--portal-gun", action=argparse.BooleanOptionalAction, default=None,
                        help="Solo only: offer the experimental Portal Gun at the trader (saved, initially off)")
    parser.add_argument("--test-map-players", type=int, choices=(0, 6),
                        help="Remilly UKFP scaling: 0 actual players, 6 faked players (default: 6); requires --host")
    parser.add_argument("--headset-preset", choices=tuple(HEADSET_PRESETS),
                        help="Provisional VR graphics/eye-scale starting point; explicit settings win")
    parser.add_argument("--vr-quality", choices=("quality", "balanced", "performance"),
                        help="Session VR graphics preset (default: quality); requires --vr")
    parser.add_argument("--eye-render-percent", type=eye_render_percent,
                        help="Override saved VR eye resolution (50-100, first-run default 100); requires --vr")
    parser.add_argument("--frame-timings", action="store_true",
                        help="Log CPU stage and GPU frame times to native.log every 5 s (low overhead); requires --vr")
    parser.add_argument("--threaded-render", action=argparse.BooleanOptionalAction, default=None,
                        help="Experimental: render on UE3's render thread instead of -onethread (saved, initially off). "
                             "The portal gun's see-through view works only with this off; requires --vr")
    parser.add_argument("--replay-teammate", action="store_true",
                        help="Host a visual test with one separate native controller replay client")
    parser.add_argument("--replay-match", action="store_true",
                        help="Keep normal enemy waves in the replay test (default: quiet inspection)")
    parser.add_argument("--avatar-preview", action="store_true",
                        help="Host a quiet solo rig preview with a separate recorded-pose teammate; add --vr for a headset")
    parser.add_argument("--locomotion-preview", action="store_true",
                        help="Desktop observation of the actual remote pawn: idle, roomscale, idle, stick walking")
    parser.add_argument("--address", help="Host address or the complete KF2VR1 join code (code supplies connection settings)")
    parser.add_argument("--share-address", help="Host-only address for the join code; defaults to the public IP reported by the server")
    parser.add_argument("--password")
    parser.add_argument("--game-root", type=Path)
    parser.add_argument("--server-root", type=Path, default=SHARED / "KF2VR-Server")
    parser.add_argument("--cache-root", type=Path, default=SHARED / "KF2VR-Cache")
    parser.add_argument("--port", type=int, default=7777)
    parser.add_argument("--query-port", type=int, default=27015)
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--duration", type=int, help="Optional bounded developer launch; ordinary play has no limit")
    local_test_control.add_options(parser)
    args = parser.parse_args(argv)
    if args.locomotion_preview:
        if not args.host or args.vr or args.solo or args.avatar_preview or args.replay_match:
            parser.error("--locomotion-preview requires --host and desktop quiet inspection; omit --vr, --solo, --avatar-preview and --replay-match")
        args.replay_teammate = True
        args.desktop = True

    try:
        local_test_control.validate_options(args)
    except RuntimeError as error:
        parser.error(str(error))
    args.breacher_requested_off = args.breacher is False
    if args.share_address and (not args.host or not re.fullmatch(r"[A-Za-z0-9.-]{1,253}", args.share_address)):
        parser.error("--share-address requires --host and an IP address or hostname without a port or URL")
    if args.solo and (args.host or args.address or args.test_map or args.replay_teammate or args.avatar_preview):
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
    if args.multiplayer_grabs is not None and not args.host:
        parser.error("--multiplayer-grabs requires --host")
    if args.portal_gun is not None and not args.solo:
        parser.error("--portal-gun requires --solo; portals are local-only and hosted or joined games never offer the gun")
    if args.inventory_focus and not args.host:
        parser.error("--inventory-focus requires --host; the remote host controls shared slowdown")
    if args.test_map_players is not None and not args.host:
        parser.error("--test-map-players requires --host; the remote host controls scaling")
    if (args.replay_teammate or args.avatar_preview) and (args.mods or args.damage_popups is not None or args.test_map_players is not None):
        parser.error("Mod selections are for normal play; omit replay/preview modes")
    if (args.menu or args.map or args.difficulty or args.game_length) and not (args.host or args.solo):
        parser.error("Map/difficulty/match length require --host or --solo")
    if args.menu and (args.replay_teammate or args.avatar_preview):
        parser.error("--menu is for normal play; omit replay/preview modes")
    if args.map and not re.fullmatch(r"KF-[A-Za-z0-9_-]+", args.map):
        parser.error("--map must be a KF- map name, without a path, extension or URL options")
    if args.test_map and args.map and args.map != MAP_NAME:
        parser.error("Choose either --test-map or a different --map")
    args.test_map = args.test_map or args.map == MAP_NAME
    if args.test_map and (not args.host or args.replay_teammate or args.avatar_preview):
        parser.error("--test-map requires --host and cannot be combined with replay/preview modes")
    args.vr_quality_requested = args.vr_quality
    # Checked against an explicit flat-screen request only: with neither flag
    # the play mode is still the profile's to decide.
    if args.desktop and (args.headset_preset is not None or args.vr_quality is not None or args.eye_render_percent is not None):
        parser.error("--headset-preset, --vr-quality and --eye-render-percent require VR play; omit --desktop")
    if args.frame_timings and not args.vr:
        parser.error("--frame-timings requires --vr")
    if args.threaded_render and not args.vr:
        parser.error("--threaded-render requires --vr")
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
    if not (1024 <= args.port <= 65000 and 1024 <= args.query_port <= 65000) or args.port == args.query_port:
        parser.error("Choose distinct game/query ports from 1024 to 65000")
    if args.duration is not None and not 5 <= args.duration <= 7200:
        parser.error("--duration must be 5..7200 seconds")
    ports = [p + offset for p in (args.port, args.query_port)
             for offset in ((0, 10, 20) if args.replay_teammate else (0, 10))]
    if len(ports) != len(set(ports)):
        parser.error("Game/query ports and their client offsets overlap")
    return args


def validate_play_mode(args):
    local_test_control.validate_options(args)
    # Profile and menu choices resolve after parsing. An explicit VR override
    # must not silently disappear when the resolved play mode is Desktop.
    if not args.vr and (getattr(args, "headset_preset", None) is not None
                       or getattr(args, "vr_quality_requested", None) is not None
                       or args.eye_render_percent is not None):
        raise RuntimeError("VR graphics and headset render scale require VR play; choose --vr or remove the override.")


def preflight(manifest, game, vr):
    print("Build: " + manifest.get("build_id", ROOT.name), flush=True)
    print(f"KF2 installation: {game}; executable SHA-256: {manifest['game_sha256']}", flush=True)
    print("Package integrity: verified. Native files are deployed temporarily and restored after play.", flush=True)
    if vr:
        import winreg
        try:
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
            print("Active OpenXR runtime: " + str(runtime), flush=True)
        except (OSError, KeyError, ValueError) as error:
            raise RuntimeError("No usable active OpenXR runtime. Enable your headset runtime, then retry. " + str(error)) from error
        # The adapter/loader use static C++ runtimes; the private Python
        # distribution carries its own vcruntime DLLs. A System32 VC++ 2015
        # installation is therefore not a prerequisite for this package.


def main():
    args = parse_options()
    manifest = json.loads((ROOT / "release.json").read_text(encoding="utf-8"))
    for name, expected in manifest["files_sha256"].items():
        if not (ROOT / name).resolve().is_relative_to(ROOT.resolve()) or digest(ROOT / name) != expected:
            raise RuntimeError(f"Package file changed or missing: {name}. Extract a fresh copy.")
    saved_path = ROOT / "settings.json"
    saved = json.loads(saved_path.read_text(encoding="utf-8")) if saved_path.exists() else {}
    game = args.game_root or (Path(saved["game_root"]) if saved.get("game_root") else find_game())
    if not game:
        game = Path(input("KF2 installation folder: ").strip().strip('"'))
    exe = game / "Binaries/Win64/KFGame.exe"
    if not exe.exists() or digest(exe) != manifest["game_sha256"]:
        raise RuntimeError("KF2 version differs from this prototype. A matching build is required.")
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
            raise RuntimeError(f"Map {args.map} is not installed on both client and server. Use --menu to choose an available map.")
    validate_play_mode(args)
    preflight(manifest, game, args.vr)
    if args.solo:
        args.address, args.password = "127.0.0.1", "solo-unused"
        args.mods = []
    elif args.host:
        args.address = "127.0.0.1"
        args.password = args.password or saved.get("host_password") or secrets.token_hex(4)
        saved["host_password"] = args.password
    else:
        args.address = args.address or input(f"Paste join code (or host address) [{saved.get('address', '')}]: ").strip() or saved.get("address", "")
        if args.address.startswith(join_code.PREFIX):
            details = join_code.decode(args.address, manifest["build_id"])
            for key in ("address", "password", "port", "query_port", "mods", "map"):
                setattr(args, key, details[key])
            args.breacher_expected = details.get("breacher")
            if args.breacher is False and getattr(args, "breacher_requested_off", False) and args.breacher_expected:
                raise RuntimeError("Host requires Breacher, but --no-breacher was requested.")
            args.breacher = args.breacher_expected is not None
            args.mods_requested = True
            args.test_map = args.map == MAP_NAME
            print("Join code accepted. Host connection and content settings applied.", flush=True)
        else:
            args.password = args.password or input("Session password: ").strip()
    if not re.fullmatch(r"[a-zA-Z0-9.-]+", args.address or ""):
        raise RuntimeError("Enter the host IP address or hostname, without a port or URL.")
    if not re.fullmatch(r"[a-zA-Z0-9_-]{1,64}", args.password or ""):
        raise RuntimeError("Use a session password containing letters, numbers, underscore or hyphen.")
    breacher.prepare(args, ROOT, manifest)
    if args.breacher:
        print("Breacher ON: experimental Deadbolt/Cascade; all players require matching local content. No automatic download.", flush=True)
    saved.update(game_root=str(game), address=args.address)
    saved_path.write_text(json.dumps(saved, indent=2), encoding="utf-8")
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
        args.test_map_path = ensure_map(args.cache_root, steam_root, download=not args.prepare_only)
    prepare_content(args, game, steam_root)
    run = ROOT / "sessions" / datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S-%f")
    names = ["server", "driver"] if args.host else ["driver"]
    if args.replay_teammate:
        names.append("teammate")
    roles = [configure_role(run, name, user, game, args) for name in names]
    player_role = next(role for role in roles if role["role"] == "driver")
    # Host and Solo share common choices; save_preferences retains the hosted
    # loadout when Solo's effective content selection is empty.
    if (args.host or args.solo) and not args.replay_teammate:
        save_preferences(args)
    record = {"launcher_pid": os.getpid(), "launcher_creation_time": creation_time(api(), ctypes.windll.kernel32.GetCurrentProcess()),
              "build_id": manifest.get("build_id", ROOT.name), "protocol_version": manifest.get("protocol_version"),
              "session_mode": "solo" if args.solo else ("host" if args.host else "join"),
              "multiplayer_grabs_host_requested": args.multiplayer_grabs if args.host else None,
              "portal_gun": bool(getattr(args, "portal_gun", False)) if args.solo else None,
              "breacher": breacher.descriptor(args),
              "status": "prepared", "roles": roles, "host": args.host, "vr": args.vr,
              "mods": args.mods, "damage_popups": damage_popups_enabled(args) and "ukfp" in args.mods,
              "damage_popups_requested": args.damage_popups and "ukfp" in args.mods,
              "test_map_players": args.test_map_players if args.test_map and "ukfp" in args.mods else 0,
              "workshop_content": args.workshop_content,
              "test_map": args.test_map,
              "host_map": MAP_NAME if args.test_map else args.map,
              "difficulty": args.difficulty, "game_length": args.game_length,
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
              "frame_timings": args.frame_timings, "threaded_render": args.threaded_render}
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
        env = {k: v for k, v in os.environ.items() if not k.upper().startswith("KF2VR_")}
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
        if args.host:
            print("Preparing the free dedicated server. The first download needs about 32 GB of disk space.", flush=True)
            install_env = env.copy()
            # PowerShell 7's inherited module path can hide Windows PowerShell
            # 5.1 built-ins. Let the shipped Windows shell initialize its own.
            install_env = {k: v for k, v in install_env.items() if k.upper() != "PSMODULEPATH"}
            subprocess.run(["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
                str(ROOT / "tools/install-multiplayer-server.ps1"), "-ServerRoot", str(args.server_root)], check=True, env=install_env)
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
                if native_log.exists() and "server_adapter ready=1" in native_log.read_text(errors="replace"):
                    record["server_adapter_ready"] = True
                    save()
                    break
                if server.poll() is not None:
                    break
                time.sleep(0.1)
            if not record.get("server_adapter_ready"):
                raise RuntimeError(f"VR server adapter did not initialize; see {native_log}")
        if not args.solo:
            print("Checking the server and VAC status...", flush=True)
            deadline = time.monotonic() + (120 if args.host else 15)
            last_error = "no response"
            while time.monotonic() < deadline:
                if server and server.poll() is not None:
                    raise RuntimeError("Dedicated server exited. See the server log in session details.")
                try:
                    info = query_server(args.address, args.query_port)
                    if info["secure"]:
                        raise RuntimeError("Server reports VAC enabled. This prototype requires the KF2-VR VAC-off host.")
                    if info["folder"] != "kf2" or not info["password"]:
                        raise ValueError("Expected a password-protected KF2 server")
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
            print(f"Host ready. Session password: {args.password}\nFriends use your LAN/VPN/public address. Game UDP {args.port}; query UDP {args.query_port}.", flush=True)
            address = args.share_address or join_code.public_address(log_text(roles[0]))
            if address:
                code = join_code.encode(dict(address=address, password=args.password, port=args.port,
                    query_port=args.query_port, build=manifest["build_id"], mods=args.mods, map=args.map,
                    **({"breacher": breacher.descriptor(args)} if args.breacher else {})))
                instructions = ("Send your friends the same KF2-VR ZIP and this code:\n\n" + code +
                    "\n\nUnzip it, open Start KF2-VR, click Join a friend and paste the code. "
                    "Keep the KF2-VR window open while playing.\n\n"
                    f"Host: forward UDP {args.port} and UDP {args.query_port} to your PC for internet play. "
                    "This code contains the session password; share it privately. "
                    "Generating a code does not verify internet reachability.\n")
                (ROOT / "JOIN-SERVER.txt").write_text(instructions, encoding="utf-8")
                print(instructions + "Copy/share instructions from: " + str(ROOT / "JOIN-SERVER.txt"), flush=True)
            else:
                print("Public address unavailable. Use --share-address YOUR_PUBLIC_IP on the next host launch to generate a join code.", flush=True)
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
        if args.vr and any(role is player_role for role, _ in owned):
            try:
                export_preferences(Path(player_role["config_root"]), network=not args.solo)
            except (OSError, ValueError) as error:
                errors.append(f"Could not save VR preferences: {error}")
        elif not args.vr and any(role is player_role for role, _ in owned):
            try:
                desktop_settings.export(Path(player_role["config_root"]), user)
            except (OSError, ValueError) as error:
                errors.append(f"Could not save desktop settings: {error}")
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
        raise SystemExit(main())
    except Exception as error:
        print(f"\nCould not start/finish KF2-VR: {error}", flush=True)
        raise SystemExit(1)
