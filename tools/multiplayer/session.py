"""Single-PC, real-process network diagnostic with optional native hand replay.

Uses the installed, fingerprinted KF2 and an independently compiled KF2VRNet.u.
Preparation is the default; --run launches a bounded session with local clients.
Bots and synthetic poses never stand in for a second network connection.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import time
from datetime import datetime, timezone
from evidence import (events, mode_is, query_loopback, verify_transport, verify_fire_reload, verify_held_ledger, verify_server_pending, verify_held_network, verify_dual_weapons, verify_dual_damage,
                      verify_damage, verify_movement, verify_room_movement, verify_room_clamp,
                      verify_room_residual, verify_vr_controls, verify_pose_dropout, verify_reconnect, verify_disconnect_cleanup,
                      verify_lifecycle, world_logs, verify_remote_weapons, verify_dual_vr_owners)
from native_fixture import verify_native, NativeDeployment
from vr_config import DEFAULTS, import_preferences
from release_state import verify_release
from workshop_map import MAP_NAME, ensure_map, add_map_path, receipt as map_receipt
from evidence import verify_paired_smoke, local_lan_readiness


ROOT = Path(__file__).resolve().parents[2]


def replay_core_evidence(logs, *, native_replay=False, server_adapter=False,
                         dual_weapons=False, paired_weapons=False):
    """Shared observation/finish gate: wait for every mandatory core signal."""
    result = {"transport": verify_transport(*logs), "held_ledger": verify_held_ledger(logs[0])}
    if server_adapter:
        result["server_pending"] = verify_server_pending(logs[0])
        if not (dual_weapons or paired_weapons):
            result["held_network"] = verify_held_network(*logs[:2])
    if native_replay:
        result["native_replay"] = {"passed": any(
            e.get("samples", "").isdigit() and int(e["samples"]) >= 30
            and e.get("valid") == "3" and e.get("calibrated", "").lower() == "true"
            and e.get("connection") == "2" for e in events(logs[1], "native_frame"))}
    return result


# Bytes/second per connection, for both the hosted server and every client.
NET_RATE = "40000"
CONFIG_KINDS = ("ENGINE", "GAME", "INPUT", "UI", "WEB", "SYSTEMSETTINGS", "LIGHTMASS", "BENCHMARKING", "MAP")


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest().upper()


def unreal_command(executable: Path, arguments: list[str]) -> str:
    """UE3 reads the raw Windows command line, not CRT argv splitting.

    For a path with spaces it requires -KEY="value", rather than quoting the
    whole -KEY=value token as subprocess.list2cmdline normally would.
    """
    parts = [subprocess.list2cmdline([str(executable)])]
    for argument in arguments:
        if '"' in argument or '\n' in argument or '\r' in argument:
            raise ValueError("Unexpected quote/control character in Unreal argument")
        if argument.startswith("-") and "=" in argument:
            key, value = argument.split("=", 1)
            if any(c.isspace() for c in value):
                parts.append(f'{key}="{value}"')
                continue
        parts.append(subprocess.list2cmdline([argument]))
    return " ".join(parts)


def read_ini(path: Path) -> str:
    data = path.read_bytes()
    text = data.decode("utf-16" if data.startswith((b"\xff\xfe", b"\xfe\xff")) else "utf-8-sig")
    # write_text translates LF on Windows. Normalize decoded bytes first so
    # repeated configuration passes cannot grow CRCRLF and defeat section/key
    # replacement, leaving stale duplicates ahead of an explicit override.
    return re.sub(r"\r+\n", "\n", text).replace("\r", "\n")


def set_ini(text: str, section: str, values: dict[str, str | list[str]]) -> str:
    """Replace keys in one section; never depend on duplicate-section precedence."""
    pattern = re.compile(r"(?ims)^[ \t]*\[" + re.escape(section) + r"\][^\r\n]*(?:\r?\n|$).*?(?=^[ \t]*\[|\Z)")
    matches = list(pattern.finditer(text))
    if len(matches) > 1:
        raise ValueError(f"Duplicate INI section: {section}")
    old = matches[0].group() if matches else f"[{section}]\n"
    for key in values:
        old = re.sub(r"(?im)^[ \t]*[+!.-]?" + re.escape(key) + r"[ \t]*=[^\r\n]*(?:\r?\n|$)", "", old)
    head, _, tail = old.partition("\n")
    lines = [f"{key}={item}" for key, value in values.items() for item in (value if isinstance(value, list) else [value])]
    replacement = head.rstrip("\r") + "\n" + "\n".join(lines) + "\n" + tail
    return pattern.sub(lambda _: replacement, text) if matches else text.rstrip() + "\n\n" + replacement


def set_ini_defaults(text: str, section: str, values: dict[str, str]) -> str:
    """Seed only keys the copied profile does not already define.

    The pinned SDK ignores defaultproperties assignments to config fields, so
    an absent key means false/0 rather than the intended playable value. This
    mirrors tools/test-bootstrap.ps1 so the multiplayer client starts with the
    same controls as the standalone playable build while preserving whatever
    the player has already saved.
    """
    pattern = re.compile(r"(?ims)^[ \t]*\[" + re.escape(section) + r"\][^\r\n]*(?:\r?\n|$).*?(?=^[ \t]*\[|\Z)")
    match = pattern.search(text)
    body = match.group() if match else ""
    missing = {key: value for key, value in values.items()
               if not re.search(r"(?im)^[ \t]*[+!.-]?" + re.escape(key) + r"[ \t]*=", body)}
    return set_ini(text, section, missing) if missing else text


# Controls parity with the standalone playable build. bIndependentHands is
# forced in KF2VRNetHandsBridge and is deliberately not listed here.
VR_CONTROL_DEFAULTS = DEFAULTS["KF2VR.VRHandsBridge"]


def config_hashes(directory: Path) -> dict[str, str]:
    return {p.name: digest(p) for p in sorted(directory.glob("*.ini"))}


def source_hashes() -> dict[str, str]:
    base = ROOT / "script/KF2VRNet"
    return {p.relative_to(base).as_posix(): digest(p) for p in sorted(base.rglob("*.uc"))}


def verify_build(game: Path) -> tuple[Path, dict]:
    manifest = json.loads((ROOT / "docs/intake/install_manifest.json").read_text(encoding="utf-8-sig"))
    exe = game / "Binaries/Win64/KFGame.exe"
    if digest(exe) != manifest["binaries"]["game"]["sha256"].upper():
        raise RuntimeError("Game executable differs from the audited build")
    # This fixture must not accidentally activate another task's proxy.
    if (exe.parent / "dinput8.dll").exists():
        raise RuntimeError("A dinput8 proxy is installed; finish its owning fixture first")
    package = ROOT / "build/multiplayer/script/KF2VRNet.u"
    receipt = json.loads((package.parent / "build.json").read_text(encoding="utf-8-sig"))
    if not receipt.get("success") or digest(package) != receipt.get("package_sha256", "").upper():
        raise RuntimeError("Network package is missing or does not match its successful build receipt")
    if source_hashes() != receipt.get("sources_sha256"):
        raise RuntimeError("Network package is stale; compile the current source")
    return exe, receipt


def verify_server(server: Path) -> tuple[Path, dict]:
    exe = server / "Binaries/Win64/KFServer.exe"
    receipt_path = server / "kf2vr-install.json"
    if not exe.exists() or not receipt_path.exists():
        raise RuntimeError("Dedicated server not installed; run tools/install-multiplayer-server.ps1")
    receipt = json.loads(receipt_path.read_text(encoding="utf-8-sig"))
    if receipt.get("app_id") != 232130 or not receipt.get("success") or digest(exe) != receipt.get("server_sha256"):
        raise RuntimeError("Dedicated server differs from its successful SteamCMD installation receipt")
    return exe, receipt


def role_config(run: Path, role: str, user: Path, package_dir: Path, game: Path, port: int, query_port: int,
                cache_root: Path, combat: bool, online_server: bool = False, native_replay: bool = False,
                damage: bool = False, movement: bool = False, room_movement: bool = False,
                room_clamp: bool = False, room_residual: bool = False,
                vr_controls: bool = False, expected_clients: int = 1,
                pose_dropout: bool = False, lifecycle: bool = False, dual_weapons: bool = False,
                dual_vr_owners: bool = False) -> dict:
    role_root = run / role
    configs = role_root / "Config"
    configs.mkdir(parents=True)
    for file in user.glob("*.ini"):
        shutil.copy2(file, configs / file.name)
    dual_vr_low_memory_config = None
    if dual_vr_owners and role != "server":
        system_path = configs / "KFSystemSettings.ini"
        system_ini = read_ini(system_path) if system_path.exists() else ""
        system_ini = set_ini(system_ini, "SystemSettings", {
            "ResX": "640", "ResY": "360", "ScreenPercentage": "50.000000",
            "MotionBlur": "False", "MotionBlurPause": "False",
            "DepthOfField": "False", "AmbientOcclusion": "False", "Bloom": "False"})
        system_path.write_text(system_ini, encoding="utf-16")
        dual_vr_low_memory_config = {"res_x": 640, "res_y": 360, "screen_percentage": 50.0}
    engine_path = configs / "KFEngine.ini"
    if not engine_path.exists():
        raise RuntimeError("Expected an initialized KF2 user profile (KFEngine.ini)")
    engine = read_ini(engine_path)
    # Preserve existing stock content paths while prepending only our compiled package.
    core = re.search(r"(?ims)^\[Core\.System\][^\n]*\n(.*?)(?=^\[|\Z)", engine)
    if not core:
        raise RuntimeError("Missing Core.System in KFEngine.ini")
    paths = {key: [str(package_dir)] + re.findall(r"(?im)^" + key + r"=([^\r\n]*)", core[1])
             for key in ("Paths", "ScriptPaths", "SeekFreePCPaths", "BrewedPCPaths")}
    paths["Suppress"] = [value for value in re.findall(r"(?im)^Suppress=([^\r\n]*)", core[1])
                         if not value.lower().startswith(("devnet", "devonline", "devauth"))]
    for key in ("CachePath", "SavePath", "ScreenShotPath"):
        target = cache_root if key == "CachePath" else role_root / key
        target.mkdir(parents=True, exist_ok=True)
        paths[key] = str(target)
    engine = set_ini(engine, "Core.System", paths)
    save = role_root / "SaveData"
    save.mkdir()
    engine = set_ini(engine, "OnlineSubsystemSteamworks.OnlineSubsystemSteamworks", {
        "bUseVAC": "false", "bRelaunchInSteam": "false", "ProfileDataDirectory": str(save)})
    # Match the playable launcher: the stock Steam lobby path expects the
    # Vivox interface to exist even for synthetic desktop clients.
    engine = set_ini(engine, "VoIP", {"bHasVoiceEnabled": "false" if role == "server" else "true"})
    # Every VR player's always-relevant pose actor reaches every client, ~15 kB/s
    # (up to ~22 kB/s) per client with six players, above stock's 10 kB/s
    # internet cap. The client asks for ConfiguredInternetSpeed (LanSpeed for a
    # LAN URL); the server clamps that to MaxClientRate and, for an internet
    # connection, MaxInternetClientRate. Raise every link of that chain.
    engine = set_ini(engine, "Engine.Player", {"ConfiguredInternetSpeed": NET_RATE,
                                               "ConfiguredLanSpeed": NET_RATE})
    engine = set_ini(engine, "IpDrv.TcpNetDriver", {"MaxClientRate": NET_RATE,
                                                    "MaxInternetClientRate": NET_RATE})
    if role == "server":
        # KF2's default 1s unverified handshake limit expires while a cold
        # local client blocks loading its startup menu/EOS state. Friend co-op
        # tolerates that startup delay; this does not delay in-game input.
        engine = set_ini(engine, "IpDrv.TcpNetDriver", {"HandShakeTimeOutSec": "60"})
    native_driver = native_replay and (role == "driver" or (dual_vr_owners and role == "observer"))
    if native_replay and role != "server":
        engine = set_ini(engine, "Engine.Engine", {"GameViewportClientClassName": "KF2VRNetClient.KF2VRNetViewportClient"})
        engine = set_ini(engine, "KF2VRNetClient.KF2VRNetViewportClient", {"bDiagnosticInputIsolation": "true"})
    engine_path.write_text(engine, encoding="utf-16")
    game_path = configs / "KFGame.ini"
    game_ini = read_ini(game_path) if game_path.exists() else ""
    game_ini = set_ini(game_ini, "KF2VRNet.KF2VRNetPlayerController", {
        "bDiagnosticSyntheticAutoStart": "true" if role == "driver" and not native_driver else "false",
        "bEnableVRClient": "true" if native_driver else "false",
        "bDiagnosticDamage": "true" if damage and role == "driver" else "false",
        "bDiagnosticMovement": "true" if movement and role == "driver" else "false",
        "bDiagnosticLocomotionReplay": "false",
        "bDiagnosticRoomMovement": "true" if (room_movement or room_clamp) and role == "driver" else "false",
        "bDiagnosticRoomClamp": "true" if room_clamp and role == "driver" else "false",
        "bDiagnosticRoomResidual": "true" if room_residual and role == "driver" else "false",
        "bDiagnosticVRControls": "true" if vr_controls and role == "driver" else "false",
        "bDiagnosticDualWeapons": "true" if dual_weapons and role != "server" else "false",
        "bDiagnosticPairedWeapons": "false",
        "bDiagnosticPoseDropout": "true" if pose_dropout and role == "driver" else "false",
        "bDiagnosticLifecycle": "true" if lifecycle and role == "driver" else "false",
        "bDiagnosticVisualReplay": "false",
        "bDiagnosticAvatarPreview": "false",
        "bDiagnosticAvatarCamera": "false",
        "bDiagnosticAvatarReplay": "false",
        "bDiagnosticObserverDebug": "true",
        "bDiagnosticObserverOnly": "true" if role == "observer" and not lifecycle and not dual_vr_owners else "false",
        "bDiagnosticAutoFire9mm": "true" if combat and role == "driver" else "false"})
    access = {"GamePassword": "kf2vr-local-diagnostic"}
    if role != "server":
        # Stock server skips Steam authentication for 127.0.0.1. Avoid the
        # client's matching server-auth retry on this local diagnostic only.
        access["bAuthenticateServer"] = "false"
    game_ini = set_ini(game_ini, "Engine.AccessControl", access)
    if role != "server":
        game_ini = set_ini_defaults(game_ini, "KF2VR.VRHandsBridge", VR_CONTROL_DEFAULTS)
    if native_driver:
        # Recorded inputs assume the shipped control layout (including button
        # reload and stick walking). A copied player's physical reload,
        # handedness or teleport preferences must not reinterpret the replay.
        for section, defaults in DEFAULTS.items():
            game_ini = set_ini(game_ini, section, defaults)
    game_path.write_text(game_ini, encoding="utf-16")
    if role != "server":
        import_preferences(configs, persistent=False)
    log = role_root / "game.log"
    url = ("KF-BurningParis?Game=KF2VRNet.KF2VRNetGame?VRNetDiagnostics=1?VRNetAutoReady=1?VRNet9mm=1?Difficulty=0?GameLength=0?bIsLanMatch=true"
           if role == "server" else f"127.0.0.1:{port}?Password=kf2vr-local-diagnostic?Name=VRNet_{role}")
    if role == "server" and online_server:
        url = url.replace("?bIsLanMatch=true", "")
    if role == "server":
        url += f"?VRNetClients={expected_clients}"
        if pose_dropout:
            url += "?VRNetRecovery=1"
        if lifecycle:
            url += "?VRNetLifecycle=1"
        # The room fixtures measure a walk over tens of seconds and are not
        # measuring combat. An ambient wave kills the pawn mid-measurement and
        # the run reports a frozen walk rather than a result.
        if room_movement or room_clamp or room_residual:
            url += "?VRNetQuietZeds=1"
    if role == "observer" and not lifecycle and not dual_vr_owners:
        url += "?SpectatorOnly=1"
    args = [url, "-useunpublished", "-nosplash", "-nostartupmovies",
        "-unattended", "-nopause", "-AUTOINIUPDATE" if role == "server" else "-NOAUTOINIUPDATE",
        "-NOINI", "-FORCELOGFLUSH", f"-ABSLOG={log}"]
    # Working Steam mode uses all server interfaces; clients connect locally.
    # No router or firewall changes are made by the diagnostic.
    bind_address = "0.0.0.0" if role == "server" and online_server else "127.0.0.1"
    args += [f"-MULTIHOME={bind_address}", f"-Port={port if role == 'server' else port + (10 if role == 'driver' else 20)}",
             f"-QueryPort={query_port if role == 'server' else query_port + (10 if role == 'driver' else 20)}"]
    if role != "server":
        args += ["-windowed", "-ResX=640", "-ResY=360"]
        # Diagnostic clients keep fallback output beside their explicit role
        # paths, matching the previously isolated capture fixture.
        if native_replay:
            args.append("-nohomedir")
    if native_driver:
        args += ["-kf2vr-probe", "-kf2vr-network", "-kf2vr-hand-replay", "-onethread", "-kf2vr-no-portals"]
    for kind in CONFIG_KINDS:
        name = {"SYSTEMSETTINGS": "KFSystemSettings"}.get(kind, "KF" + kind.title())
        args.append(f"-{kind}INI={configs / (name + '.ini')}")
    return {"role": role, "args": args, "log": str(log), "config_root": str(configs),
            "config_hashes": config_hashes(configs), "native_adapter": native_driver,
            "dual_vr_low_memory_config": dual_vr_low_memory_config}


def log_text(role: dict) -> str:
    path = Path(role["log"])
    if not path.exists():
        return ""
    data = path.read_bytes()
    encoding = "utf-16" if data.startswith((b"\xff\xfe", b"\xfe\xff")) else "utf-8-sig"
    return data.decode(encoding, errors="replace")


def await_client_startup(role, server, process, timeout, *, read_log=log_text, clock=time.monotonic, sleep=time.sleep):
    """Startup gets its own finite budget; the caller starts handshake time afterward."""
    began = clock()
    seen = set()
    milestones = (("steam_ready", "Steam Client API initialized 1"),
                  ("voice_connect", "FVoiceInterfaceVivox::vivoxConnect"),
                  ("eos_login", "Connect Login complete"),
                  ("initial_join", "Browse: 127.0.0.1"),
                  ("main_menu_load", "LoadMap: KFMainMenu"))
    while clock() - began < timeout:
        for name, owned in (("server", server), (role["role"], process)):
            code = owned.poll()
            if code is not None:
                raise RuntimeError(f"Owned {name} exited during engine startup ({code})")
        log = read_log(role)
        if "Steam Client API initialized 0" in log:
            raise RuntimeError("Steam client initialization failed; leave Steam open and signed in")
        for key, needle in milestones:
            if needle in log and key not in seen:
                seen.add(key)
                print(f"PHASE role={role['role']} elapsed={clock()-began:.1f}s milestone={key}", flush=True)
        if "Initializing Engine Completed" in log:
            return round(clock() - began, 3)
        sleep(0.5)
    raise RuntimeError(f"Engine-startup phase exceeded {timeout}s for {role['role']}")


def check_port(port: int) -> None:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.bind(("127.0.0.1", port))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game-root", type=Path, default=Path("D:/SteamLibrary/steamapps/common/killingfloor2"))
    parser.add_argument("--server-root", type=Path, default=ROOT / "build/multiplayer/server")
    parser.add_argument("--user-config", type=Path, default=Path.home() / "Documents/My Games/KillingFloor2/KFGame/Config")
    parser.add_argument("--run", action="store_true", help="Launch owned, bounded server/client processes")
    parser.add_argument("--clients", type=int, choices=(1, 2), default=1)
    parser.add_argument("--duration", type=int, default=40, help="Observation seconds after connection startup")
    parser.add_argument("--startup-timeout", type=int, default=120, help="Server-readiness and post-startup handshake/transport allowance per phase")
    parser.add_argument("--client-startup-timeout", type=int, default=120, help="Separate engine-startup allowance per desktop client")
    parser.add_argument("--motion-capture-interval", type=float, default=3.0, help="Motion observer screenshot interval, 0.25..30 seconds (default 3)")
    parser.add_argument("--motion-capture-limit", type=int, default=12, help="Motion observer screenshot count, 1..100; collection limited to 128 MiB")
    parser.add_argument("--motion-clip", type=Path, help="Replay this existing saved motion file; no recording or overwrite")
    parser.add_argument("--motion-camera-mode", type=int, choices=(0,1,2), default=0, help="Separate motion observer: 0 follow, 1 orbit, 2 free")
    parser.add_argument("--motion-fixture", action="store_true", help="Record/play authored synthetic input in an isolated clip directory; requires --native-replay")
    parser.add_argument("--lan-no-voice", action="store_true", help="Disable optional voice only in disposable LAN client configs; rejects --online-server")
    parser.add_argument("--port", type=int, default=17777)
    parser.add_argument("--query-port", type=int, default=37015)
    parser.add_argument("--cache-root", type=Path, default=ROOT / "build/workshop-cache")
    parser.add_argument("--combat", action="store_true", help="Request the bounded stock 9mm fire/reload scenario")
    parser.add_argument("--native-replay", action="store_true", help="Exercise native hand input in a real network client without a headset")
    parser.add_argument("--server-adapter", action="store_true", help="Deploy the pinned server adapter and require independent pending-fire evidence")
    parser.add_argument("--dual-weapons", action="store_true", help="Exercise two predicted local weapons with stock independent firing/reload and server ammo agreement")
    parser.add_argument("--damage", action="store_true", help="Aim the five-shot fixture at a server-spawned stock clot and verify shared damage/death")
    parser.add_argument("--movement", action="store_true", help="Verify native replay stick input and stock network movement after firing/reload")
    parser.add_argument("--room-movement", action="store_true", help="Inject room-scale displacement without a headset and verify it replicates without correction")
    parser.add_argument("--room-clamp", action="store_true", help="Drop the client-side room clamp and verify the server refuses oversize and over-speed displacement by name")
    parser.add_argument("--room-residual", action="store_true", help="Strand a room request across a recenter and a respawn and verify neither leaves an offset behind")
    parser.add_argument("--vr-controls", action="store_true", help="Run the modern control stack on the network client and verify the weapon contract end to end")
    parser.add_argument("--recovery", action="store_true", help="Interrupt pose uploads, reconnect the desktop observer, then verify driver-disconnect cleanup (requires two native-replay clients)")
    parser.add_argument("--lifecycle", action="store_true", help="Two active players: death, stock trader respawn/purchase, then server travel and repeated native combat")
    parser.add_argument("--online-server", action="store_true", help="Use a password-protected Steam-registered server bound to all interfaces; clients still connect locally")
    parser.add_argument("--dual-vr-owners", action="store_true", help="Run both clients as active native replay VR owners; requires --clients 2 --native-replay --dual-weapons")
    parser.add_argument("--release", type=Path, help="Use this immutable playtest release instead of loose build artifacts")
    parser.add_argument("--output-root", type=Path, help="Parent directory for this session's receipt and logs")
    parser.add_argument("--test-map", action="store_true", help="Load the same Remilly map as Play-KF2VR.cmd -TestMap")
    parser.add_argument("--paired-weapons", action="store_true", help="Short 1858/9mm check through production network conversion and shared presentation")
    options = parser.parse_args()
    if options.paired_weapons:
        if options.dual_vr_owners or options.lifecycle:
            parser.error("--paired-weapons is the short 1858/9mm scenario; run lifecycle or dual owners separately")
        options.dual_weapons = True
    if options.dual_weapons:
        if options.vr_controls or options.combat or options.damage or options.movement or options.recovery:
            parser.error("Run --dual-weapons separately from single-current-weapon scenarios")
        options.server_adapter = True
    if options.dual_vr_owners and not (options.clients == 2 and options.native_replay and options.dual_weapons):
        parser.error("--dual-vr-owners requires --clients 2 --native-replay --dual-weapons")
    if options.server_adapter and not options.native_replay:
        parser.error("--server-adapter requires --native-replay for matching native/script verification")
    if options.recovery and options.lifecycle:
        parser.error("Run --recovery and --lifecycle as separate scenarios")
    if options.recovery or options.lifecycle:
        if options.clients != 2 or not options.native_replay:
            parser.error("--recovery/--lifecycle requires --clients 2 --native-replay")
        if not options.dual_weapons:
            options.damage = options.movement = True
    if options.damage or options.movement:
        options.combat = True
    if options.movement and not options.native_replay:
        parser.error("--movement requires --native-replay")
    if options.room_movement and not options.native_replay:
        parser.error("--room-movement requires --native-replay")
    if options.room_clamp and not options.native_replay:
        parser.error("--room-clamp requires --native-replay")
    # The clamp run provokes refusals and the corrections that enforce them, so
    # it cannot also be the run that claims an uncorrected walk.
    if options.room_clamp and options.room_movement:
        parser.error("Run --room-clamp separately from --room-movement; it refuses moves on purpose")
    if options.room_residual and not options.native_replay:
        parser.error("--room-residual requires --native-replay")
    # The residual probe measures a pawn that nothing else is displacing.
    if options.room_residual and (options.room_movement or options.room_clamp):
        parser.error("Run --room-residual separately from the room-movement walk")
    if options.vr_controls and not options.native_replay:
        parser.error("--vr-controls requires --native-replay")
    if options.lan_no_voice and options.online_server:
        parser.error("--lan-no-voice is scoped to disposable loopback LAN fixtures")
    saved_motion = None
    if options.motion_clip:
        from saved_motion import inspect_clip
        if any((options.combat,options.dual_weapons,options.room_movement,options.room_clamp,options.room_residual,options.vr_controls,options.recovery,options.lifecycle)):
            parser.error("Saved motion review must run separately from other gameplay scenarios")
        saved_motion = inspect_clip(options.motion_clip)
        if options.test_map:parser.error("Saved motion uses its recorded installed map; do not combine --test-map")
        options.motion_fixture = True
        options.duration = max(options.duration, saved_motion['observation_seconds'])
    if options.motion_fixture and not (options.native_replay and options.clients == 2):
        parser.error("--motion-fixture requires --native-replay --clients 2 for saved-file network observation")
    if not (.25 <= options.motion_capture_interval <= 30 and 1 <= options.motion_capture_limit <= 100):
        parser.error("Motion capture interval must be 0.25..30 and count 1..100")
    if not (10 <= options.client_startup_timeout <= 300):
        parser.error("Client startup timeout must be 10..300 seconds")
    if not (5 <= options.duration <= 300 and 10 <= options.startup_timeout <= 300):
        parser.error("Duration must be 5..300 seconds and startup timeout 10..300")
    if not (1024 <= options.port <= 65000 and 1024 <= options.query_port <= 65000):
        parser.error("Ports must be 1024..65000")
    release = verify_release(options.release) if options.release else None
    if release:
        exe = options.game_root / "Binaries/Win64/KFGame.exe"
        if digest(exe) != release["game_sha256"] or (exe.parent / "dinput8.dll").exists():
            raise RuntimeError("Game binary differs or another session owns its native proxy")
        receipt = release["script_build"]
        native_receipt = release["native_build"] if options.native_replay else None
        script_source = options.release / "Packages"
        native_source = options.release / "Native"
        server_native_source = options.release / "ServerNative"
    else:
        exe, receipt = verify_build(options.game_root)
        native_receipt = verify_native(ROOT, receipt, digest) if options.native_replay else None
        script_source = ROOT / "build/multiplayer/script"
        native_source = ROOT / "build/multiplayer/native/native/adapter/Release"
        server_native_source = ROOT / "build/multiplayer/native/native/adapter/server/Release"
    server_exe, server_receipt = verify_server(options.server_root)
    before = config_hashes(options.user_config)
    if not before:
        raise RuntimeError("No initialized user config found")
    run = (options.output_root or ROOT / "build/multiplayer/sessions") / datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S-%f")
    packages = run / "Packages"
    packages.mkdir(parents=True)
    shutil.copy2(script_source / "KF2VRNet.u", packages)
    if options.native_replay:
        for name in ("KF2VR.u", "KF2VRNetClient.u", "KF2VRHands.upk"):
            shutil.copy2(script_source / name, packages)
    roles = [role_config(run, name, options.user_config, packages, options.game_root, options.port, options.query_port,
                         options.cache_root.resolve(), options.combat, options.online_server, options.native_replay, options.damage, options.movement, options.room_movement, options.room_clamp, options.room_residual, options.vr_controls, options.clients, options.recovery, options.lifecycle, options.dual_weapons, options.dual_vr_owners)
             for name in (["server", "driver", "observer"] if options.clients == 2 else ["server", "driver"])]
    if options.server_adapter:
        roles[0]["server_adapter"] = True
        roles[0]["args"] += ["-kf2vr-server-adapter"]
        config = Path(roles[0]["config_root"]) / "KFGame.ini"
        config.write_text(set_ini(read_ini(config), "KF2VRNet.KF2VRNetGame", {
            "bServerAdapter": "true", "bIndependentWeapons": "true" if options.dual_weapons else "false"}), encoding="utf-16")
    if options.paired_weapons:
        for role in roles:
            config = Path(role["config_root"]) / "KFGame.ini"
            config.write_text(set_ini(read_ini(config), "KF2VRNet.KF2VRNetPlayerController", {
                "bDiagnosticPairedWeapons": "true" if role["native_adapter"] else "false"}), encoding="utf-16")
    test_map = None
    if options.test_map:
        test_map = ensure_map(options.cache_root, options.server_root.parent / "steamcmd", download=options.run)
        roles[0]["args"][0] = roles[0]["args"][0].replace("KF-BurningParis?", MAP_NAME + "?", 1)
        for role in roles:
            add_map_path(role["config_root"], test_map)
    for role in roles:
        role["config_hashes"] = config_hashes(Path(role["config_root"]))
    if options.lan_no_voice:
        for role in roles:
            if role["role"] != "server":
                config = Path(role["config_root"]) / "KFEngine.ini"
                config.write_text(set_ini(read_ini(config), "VoIP", {"bHasVoiceEnabled": "false"}), encoding="utf-16")
                role["config_hashes"] = config_hashes(Path(role["config_root"]))
                role["test_override"] = "Optional voice disabled only in disposable loopback LAN config; normal launch unchanged"
    if options.native_replay:
        roles[1]["args"].append("-kf2vr-input-isolation-probe")
    if options.motion_fixture:
        # Replay authority is enabled only on this explicitly requested disposable host.
        roles[0]["args"][0] += "?VRMotionReplay=1?VRNetQuietZeds=1"
        role = roles[1]
        config = Path(role["config_root"]) / "KFGame.ini"
        config.write_text(set_ini(read_ini(config), "KF2VRNet.KF2VRNetPlayerController", {"bDiagnosticMotionFixture": "true", "bDiagnosticMotionFileOnly": "false"}), encoding="utf-16")
        role["args"].append("-kf2vr-motion-fixture")
        role["config_hashes"] = config_hashes(Path(role["config_root"]))
        role["motion_fixture_root"] = str(Path(role["log"]).parent / "synthetic-clips")
        if saved_motion:
            from saved_motion import stage_clip
            stage_clip(saved_motion,Path(role['motion_fixture_root'])/'clip-1.kfm')
            roles[0]['args'][0] = saved_motion['map'] + '?' + roles[0]['args'][0].split('?',1)[1]
            config.write_text(set_ini(read_ini(config), "KF2VRNet.KF2VRNetPlayerController", {
                "bDiagnosticMotionFileOnly":"true", "MotionReviewSeconds":str(saved_motion['duration_seconds'])}),encoding="utf-16")
            role['config_hashes'] = config_hashes(Path(role['config_root']))
        if options.clients == 2:
            observer = roles[2]
            config = Path(observer["config_root"]) / "KFGame.ini"
            config.write_text(set_ini(read_ini(config), "KF2VRNet.KF2VRNetPlayerController", {"bDiagnosticMotionObserver": "true", "bDiagnosticObserverDebug": "false", "MotionCaptureInterval": str(options.motion_capture_interval), "MotionCaptureLimit": str(options.motion_capture_limit), "MotionCameraMode":str(options.motion_camera_mode)}), encoding="utf-16")
            observer["config_hashes"] = config_hashes(Path(observer["config_root"]))
    record = {"schema": "kf2vr/net-session/1", "prepared_utc": datetime.now(timezone.utc).isoformat(),
              "session_id": run.name, "clock_anchors": [],
              "saved_motion_source": saved_motion,
              "motion_capture_interval_seconds": options.motion_capture_interval,
              "motion_capture_limit": options.motion_capture_limit,
              "roles": roles, "status": "prepared", "runtime_pass": False, "native_vr_tested": False,
              "fire_reload_requested": options.combat, "fire_reload_tested": False, "damage_tested": False,
              "game_sha256": digest(exe), "package_sha256": receipt["package_sha256"],
              "server_sha256": server_receipt["server_sha256"], "server_executable": str(server_exe),
              "online_server_requested": options.online_server,
              "native_replay_requested": options.native_replay, "native_build": native_receipt,
              "server_adapter_requested": options.server_adapter,
              "dual_weapons_requested": options.dual_weapons,
              "dual_vr_owners_requested": options.dual_vr_owners,
              "paired_weapons_requested": options.paired_weapons,
              "release": options.release.name if options.release else None,
              "release_manifest_sha256": digest(options.release / "release.json") if options.release else None,
              "test_map": map_receipt(test_map) if test_map else None,
              "damage_requested": options.damage,
              "movement_requested": options.movement,
              "room_movement_requested": options.room_movement,
              "room_clamp_requested": options.room_clamp,
              "room_residual_requested": options.room_residual,
              "vr_controls_requested": options.vr_controls,
              "recovery_requested": options.recovery,
              "lifecycle_requested": options.lifecycle,
              "user_config_before": before, "observer_connection_requested": options.clients == 2,
              "phase_budgets_seconds": {"engine_startup_per_client": options.client_startup_timeout,
                                         "server_readiness": options.startup_timeout, "handshake": options.startup_timeout,
                                         "network_transport": options.startup_timeout},
              "verification_input": "authored synthetic; no physical XR" if options.native_replay else "desktop diagnostic"}
    output = run / "run.json"
    def save():
        output.write_text(json.dumps(record, indent=2), encoding="utf-8")
    def current_logs():
        logs = (log_text(roles[0]), log_text(roles[1]), log_text(roles[2]) if options.clients == 2 else None)
        sessions = events(logs[0], "session")
        return world_logs(*logs, sessions[-1]["world"]) if options.lifecycle and sessions else logs
    def core_evidence():
        return replay_core_evidence(current_logs(), native_replay=options.native_replay,
            server_adapter=options.server_adapter, dual_weapons=options.dual_weapons,
            paired_weapons=options.paired_weapons)
    save()
    print(f"Session receipt: {output}", flush=True)
    if not options.run:
        return 0
    if os.name != "nt":
        raise RuntimeError("This fixture requires the audited Windows KF2 build")
    # Respect the same named mutex as the existing compiler and game fixtures.
    import ctypes
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.CreateMutexW.restype = ctypes.c_void_p
    kernel.CreateMutexW.argtypes = (ctypes.c_void_p, ctypes.c_int, ctypes.c_wchar_p)
    kernel.WaitForSingleObject.argtypes = (ctypes.c_void_p, ctypes.c_uint)
    kernel.ReleaseMutex.argtypes = (ctypes.c_void_p,)
    kernel.CloseHandle.argtypes = (ctypes.c_void_p,)
    mutex = kernel.CreateMutexW(None, False, "Local\\KF2VR_DevelopmentFixture")
    locked = False
    processes: list[subprocess.Popen] = []
    deployment = None
    server_deployment = None
    try:
        if not mutex:
            raise OSError(ctypes.get_last_error(), "Cannot open fixture mutex")
        locked = kernel.WaitForSingleObject(mutex, 0) in (0, 0x80)
        if not locked:
            raise RuntimeError("Another KF2-VR fixture owns the SDK/game slot")
        existing = subprocess.check_output(["tasklist", "/FO", "CSV", "/NH"], text=True)
        if re.search(r'"KF(?:Game|Editor|Server)\.exe"', existing, re.I):
            raise RuntimeError("KF2 or its editor is already running; no process was launched")
        ports = [options.port, options.query_port, options.port + 10, options.query_port + 10]
        if options.clients == 2:
            ports += [options.port + 20, options.query_port + 20]
        if len(set(ports)) != len(ports):
            raise RuntimeError("Diagnostic ports overlap")
        for port in ports:
            check_port(port)
        environment = os.environ.copy()
        environment.update(SteamAppId="232090", SteamGameId="232090")
        for key in list(environment):
            if key.startswith("KF2VR_"):
                environment.pop(key)
        def start(role):
            startup = subprocess.STARTUPINFO()
            startup.dwFlags = subprocess.STARTF_USESHOWWINDOW
            startup.wShowWindow = 0
            executable = server_exe if role["role"] == "server" else exe
            role["executable"] = str(executable)
            role["console_log"] = str(Path(role["log"]).with_name("console.log"))
            working_dir = options.server_root if role["role"] == "server" else executable.parent
            role["working_directory"] = str(working_dir)
            child_environment = environment.copy()
            if role["role"] == "server" and options.server_adapter:
                role["native_log"] = str(Path(role["log"]).with_name("native.log"))
                child_environment["KF2VR_SERVER_LOG_PATH"] = role["native_log"]
            if role["native_adapter"]:
                role["native_log"] = str(Path(role["log"]).with_name("native.log"))
                child_environment["KF2VR_LOG_PATH"] = role["native_log"]
                if role.get("motion_fixture_root"):
                    Path(role["motion_fixture_root"]).mkdir(exist_ok=True)
                    child_environment["KF2VR_MOTION_FIXTURE_ROOT"] = role["motion_fixture_root"]
                if options.dual_weapons or options.motion_fixture:
                    captures = Path(role["log"]).parent / "captures"
                    captures.mkdir(exist_ok=True)
                    role["captures"] = str(captures)
                    child_environment["KF2VR_CAPTURE_ROOT"] = str(captures)
            # Server distribution's own KF2Server.bat starts from its root.
            # Capture pre-engine startup errors as well as the later ABSLOG.
            with Path(role["console_log"]).open("wb") as console:
                process = subprocess.Popen(unreal_command(executable, role["args"]), cwd=working_dir, env=child_environment,
                    startupinfo=startup, stdin=subprocess.DEVNULL, stdout=console, stderr=subprocess.STDOUT)
            processes.append(process)
            role["pid"] = process.pid
            role["started_utc"] = datetime.now(timezone.utc).isoformat()
            role["started_monotonic"] = time.monotonic()
            record["clock_anchors"].append({"role": role["role"], "utc": role["started_utc"],
                                             "monotonic_seconds": role["started_monotonic"], "kind": "process_started"})
            save()
            return process
        if options.server_adapter:
            server_deployment = NativeDeployment(server_native_source,
                server_exe.parent, run / "server-native-backup",
                {"artifacts_sha256": native_receipt["server_artifacts_sha256"]}, digest, server=True)
            server_deployment.install()
        server = start(roles[0])
        record["status"] = "waiting_for_insecure_server"
        save()
        deadline = time.monotonic() + options.startup_timeout
        last_query_error = None
        while time.monotonic() < deadline:
            if server.poll() is not None:
                raise RuntimeError(f"Owned server exited during startup ({server.returncode})")
            log = log_text(roles[0])
            if any(mode_is(event.get("netmode"), "dedicated") for event in events(log, "session")):
                try:
                    expected_map = MAP_NAME.lower() if options.test_map else "kf-burningparis"
                    if options.online_server:
                        info = query_loopback(options.query_port)
                        record["server_query"] = info
                        if info["secure"]:
                            raise RuntimeError("Owned diagnostic server advertised VAC enabled; clients were not launched")
                        if info["folder"] != "kf2" or expected_map not in info["map"].lower() or not info["password"]:
                            raise ValueError("Waiting for expected private KF2 map query metadata")
                    else:
                        # LAN starts its own beacon without a Steam server UID
                        # or A2S response. Observe the stock LAN settings and
                        # loopback socket; never label them a successful query.
                        lan = local_lan_readiness(log, options.port, expected_map)
                        record["server_lan_readiness"] = lan
                        if not lan["passed"]:
                            raise ValueError("Waiting for owned loopback LAN startup evidence")
                    # This KFServer build advertises type='l', appid=0 even
                    # after Steam registration. The owned executable and mod's
                    # NM_DedicatedServer event establish the actual world role.
                    if options.server_adapter:
                        native_log = Path(roles[0]["log"]).with_name("native.log")
                        if not native_log.exists() or "server_adapter ready=1" not in native_log.read_text(errors="replace"):
                            raise ValueError("Waiting for the normal server-adapter entry point")
                        record["server_adapter_ready"] = True
                    if options.online_server and "OnServerDataUpdateResponse complete successfully" not in log:
                        raise ValueError("Waiting for initialized Steam server registration")
                    record["server_role_evidence"] = "owned KFServer.exe and NM_DedicatedServer session log"
                    record["server_insecure_observed_utc"] = datetime.now(timezone.utc).isoformat()
                    break
                except (OSError, ValueError) as error:
                    last_query_error = str(error)
            time.sleep(0.5)
        else:
            raise RuntimeError(f"Dedicated/insecure server readiness not established: {last_query_error}")
        if options.native_replay:
            deployment = NativeDeployment(native_source,
                                          exe.parent, run / "native-backup", native_receipt, digest)
            deployment.install()
        def wait_engine_startup(role, process):
            record["status"] = "waiting_for_" + role["role"] + "_engine_startup"
            save()
            began = time.monotonic()
            elapsed = await_client_startup(role, server, process, options.client_startup_timeout)
            record.setdefault("phase_timings", {})[role["role"] + "_engine_startup_seconds"] = elapsed
            print(f"PHASE role={role['role']} elapsed={time.monotonic()-began:.1f}s milestone=engine_ready", flush=True)
            save()
        driver = start(roles[1])
        wait_engine_startup(roles[1], driver)
        if options.clients == 2:
            # The same Steam account is used for the local observer. Initialize
            # the real player's lobby/perk first, before the spectator's login.
            # Server auto-ready waits for both handshakes, so no wave starts yet.
            record["status"] = "waiting_for_driver_lobby"
            save()
            deadline = time.monotonic() + options.startup_timeout
            while time.monotonic() < deadline:
                if server.poll() is not None or driver.poll() is not None:
                    raise RuntimeError("An owned process exited while preparing the driver lobby")
                statuses = events(log_text(roles[1]), "status")
                if any(e.get("hello", "").lower() == "true" and e.get("perk_ready", "").lower() == "true" for e in statuses):
                    break
                time.sleep(0.5)
            else:
                raise RuntimeError("Driver handshake/perk initialization did not complete before observer startup")
            print("PHASE role=driver milestone=handshake_and_perk_ready", flush=True)
            observer = start(roles[2])
            wait_engine_startup(roles[2], observer)
        record["status"] = "waiting_for_network_clients"
        save()
        deadline = time.monotonic() + options.startup_timeout
        while time.monotonic() < deadline:
            for role, process in zip(roles, processes):
                if process.poll() is not None:
                    raise RuntimeError(f"Owned {role['role']} exited ({process.returncode}); see its log")
                if role["role"] != "server" and re.search(r"Pending connect to .* failed;", log_text(role)):
                    raise RuntimeError(f"Owned {role['role']} connection failed; see network diagnostics in its log")
            evidence = verify_transport(log_text(roles[0]), log_text(roles[1]), log_text(roles[2]) if options.clients == 2 else None)
            if evidence["passed"]:
                break
            time.sleep(0.5)
        else:
            record["transport"] = evidence
            raise RuntimeError("Real-client pose transport evidence did not complete before timeout")
        print("PHASE milestone=network_transport_pass", flush=True)
        record["status"] = "observing"
        save()
        minimum_end = time.monotonic() + max(options.duration, 45 if options.motion_fixture else 0)
        # The in-game input scenario has a 45-second lifetime after equipping.
        # Give it time to finish without turning a partial cycle into a pass.
        deadline = max(minimum_end, time.monotonic() + 50 if options.combat else minimum_end)
        if options.dual_weapons:
            deadline = max(minimum_end, time.monotonic() + 60)
        if options.paired_weapons:
            deadline = max(minimum_end, time.monotonic() + 95)
        if options.lifecycle:
            deadline = time.monotonic() + 300
        fire_reload = None
        while time.monotonic() < deadline:
            for role, process in zip(roles, processes):
                if process.poll() is not None:
                    record["unexpected_exit"] = {"role": role["role"], "pid": process.pid,
                        "exit_code": process.returncode, "log": role["log"]}
                    raise RuntimeError(f"Owned {role['role']} exited during observation (0x{process.returncode & 0xffffffff:08X})")
            if any(re.search(r"Pending connect to .* failed;", log_text(role)) for role in roles[1:]):
                raise RuntimeError("An owned client connection failed during observation or map travel; see its log")
            if options.combat:
                fire_reload = verify_fire_reload(*current_logs()[:2])
            damage_done = not options.damage or verify_damage(*current_logs())["passed"]
            movement_done = not options.movement or verify_movement(*current_logs()[:2])["passed"]
            room_done = not options.room_movement or verify_room_movement(*current_logs()[:2])["passed"]
            clamp_done = not options.room_clamp or verify_room_clamp(*current_logs()[:2])["passed"]
            residual_done = not options.room_residual or verify_room_residual(
                *current_logs()[:2], respawn_required=options.lifecycle)["passed"]
            controls_done = not options.vr_controls or verify_vr_controls(*current_logs()[:2])["passed"]
            dual_owner_done = True
            if options.dual_vr_owners:
                server_log, driver_log, observer_log = current_logs()
                dual_owner_evidence = verify_dual_vr_owners(server_log, driver_log, observer_log)
                dual_owner_done = dual_owner_evidence["passed"]
                record["dual_vr_owners_evidence"] = dual_owner_evidence
            dual_done = not options.dual_weapons or (dual_owner_done and verify_dual_weapons(*current_logs()[:2])["passed"]
                and verify_dual_damage(*current_logs())["passed"]
                and (options.clients != 2 or verify_remote_weapons(*current_logs()[1:])["passed"]))
            if options.paired_weapons:
                dual_done = verify_paired_smoke(*current_logs()[:2])["passed"]
            dropout_done = not options.recovery or verify_pose_dropout(log_text(roles[0]), log_text(roles[1]), log_text(roles[2]))["passed"]
            if options.motion_fixture:
                latest = events(log_text(roles[1]), "motion_sent")
                if latest:
                    e = latest[-1]
                    seen = (e.get("replay"), e.get("sequence"))
                    if record.get("last_motion_clock_seen") != list(seen):
                        record["last_motion_clock_seen"] = list(seen)
                        record["clock_anchors"].append({"kind": "driver_log_observed", "replay": e.get("replay"),
                            "sample": e.get("sample"), "sequence": e.get("sequence"), "clip_seconds": e.get("clip_time"),
                            "replay_clock_seconds": e.get("clock"), "game_real_seconds": e.get("time"),
                            "monotonic_seconds": time.monotonic(), "utc": datetime.now(timezone.utc).isoformat(),
                            "precision": "log observation; polling/flush latency included"})
            lifecycle_done = not options.lifecycle or verify_lifecycle(log_text(roles[0]), log_text(roles[1]), log_text(roles[2]), dual_weapons=options.dual_weapons)["passed"]
            core_done = all(check["passed"] for check in core_evidence().values())
            if time.monotonic() >= minimum_end and core_done and (not options.combat or fire_reload["passed"]) and damage_done and movement_done and room_done and clamp_done and residual_done and controls_done and dual_done and dropout_done and lifecycle_done:
                break
            time.sleep(0.5)
        core = core_evidence()
        record.update({key: value for key, value in core.items() if key != "native_replay"})
        record["runtime_pass"] = all(check["passed"] for check in core.values())
        if options.motion_fixture and options.clients == 2:
            from friends import collect_avatar_captures
            record["observer_captures"] = collect_avatar_captures(
                run / "observer", options.game_root / "KFGame/Config", log_text(roles[2]),
                datetime.fromisoformat(roles[2]["started_utc"]).timestamp(), time.time(), expected_requests=1,
                max_requests=options.motion_capture_limit, budget_bytes=128*1024*1024)
            record["runtime_pass"] = record["runtime_pass"] and record["observer_captures"]["collection_complete"]
        if options.dual_vr_owners:
            record["dual_vr_owners_evidence"] = verify_dual_vr_owners(*current_logs())
            record["runtime_pass"] = record["runtime_pass"] and record["dual_vr_owners_evidence"]["passed"]
        if options.server_adapter:
            if options.paired_weapons:
                record["paired_smoke"] = verify_paired_smoke(*current_logs()[:2])
                record["runtime_pass"] = record["runtime_pass"] and record["paired_smoke"]["passed"]
            elif options.dual_weapons:
                record["dual_weapons"] = verify_dual_weapons(*current_logs()[:2])
                record["dual_damage"] = verify_dual_damage(*current_logs())
                record["runtime_pass"] = record["runtime_pass"] and record["dual_weapons"]["passed"] and record["dual_damage"]["passed"]
                if options.clients == 2:
                    record["remote_weapons"] = verify_remote_weapons(*current_logs()[1:])
                    record["runtime_pass"] = record["runtime_pass"] and record["remote_weapons"]["passed"]
        if options.native_replay:
            record["native_replay_pass"] = core["native_replay"]["passed"]
        if options.combat:
            record["fire_reload_tested"] = True
            record["fire_reload"] = verify_fire_reload(*current_logs()[:2])
            record["runtime_pass"] = record["runtime_pass"] and record["fire_reload"]["passed"]
        if options.damage:
            record["damage_tested"] = True
            record["damage"] = verify_damage(*current_logs())
            record["runtime_pass"] = record["runtime_pass"] and record["damage"]["passed"]
        if options.movement:
            record["movement"] = verify_movement(*current_logs()[:2])
            record["runtime_pass"] = record["runtime_pass"] and record["movement"]["passed"]
        if options.room_movement:
            record["room_movement"] = verify_room_movement(*current_logs()[:2])
            record["runtime_pass"] = record["runtime_pass"] and record["room_movement"]["passed"]
        if options.room_clamp:
            record["room_clamp"] = verify_room_clamp(*current_logs()[:2])
            record["runtime_pass"] = record["runtime_pass"] and record["room_clamp"]["passed"]
        if options.room_residual:
            record["room_residual"] = verify_room_residual(
                *current_logs()[:2], respawn_required=options.lifecycle)
            record["runtime_pass"] = record["runtime_pass"] and record["room_residual"]["passed"]
        if options.vr_controls:
            record["vr_controls"] = verify_vr_controls(*current_logs()[:2])
            record["runtime_pass"] = record["runtime_pass"] and record["vr_controls"]["passed"]
        if options.lifecycle:
            record["lifecycle"] = verify_lifecycle(log_text(roles[0]), log_text(roles[1]), log_text(roles[2]), dual_weapons=options.dual_weapons)
            record["runtime_pass"] = record["runtime_pass"] and record["lifecycle"]["passed"]
            if record["runtime_pass"]:
                record["post_travel_query"] = query_loopback(options.query_port)
                record["runtime_pass"] = (not record["post_travel_query"]["secure"]
                    and record["post_travel_query"]["map"].lower() == "kf-outpost")
        if options.recovery:
            record["pose_dropout"] = verify_pose_dropout(log_text(roles[0]), log_text(roles[1]), log_text(roles[2]))
            record["runtime_pass"] = record["runtime_pass"] and record["pose_dropout"]["passed"]
            if record["runtime_pass"]:
                # Preserve each process and log independently. A restarted role
                # never replaces the Popen handle whose cleanup we already own.
                record["status"] = "reconnecting_observer"
                save()
                observer = processes[2]
                observer.terminate()
                observer.wait(timeout=10)
                roles[2]["intentional_disconnect"] = True
                rejoined = role_config(run / "reconnect", "observer", options.user_config, packages,
                    options.game_root, options.port, options.query_port, options.cache_root.resolve(),
                    False, options.online_server, expected_clients=2)
                roles.append(rejoined)
                observer = start(rejoined)
                deadline = time.monotonic() + options.startup_timeout
                while time.monotonic() < deadline:
                    if any(p.poll() is not None for p in (server, driver, observer)):
                        raise RuntimeError("An active owned process exited during observer reconnection")
                    record["reconnect"] = verify_reconnect(log_text(roles[0]), log_text(roles[1]),
                        log_text(roles[2]), log_text(rejoined))
                    if record["reconnect"]["passed"]:
                        break
                    time.sleep(0.5)
                record["runtime_pass"] = record["runtime_pass"] and record["reconnect"]["passed"]
                if record["runtime_pass"]:
                    record["status"] = "checking_driver_disconnect"
                    save()
                    driver.terminate()
                    driver.wait(timeout=10)
                    roles[1]["intentional_disconnect"] = True
                    # Abrupt process loss exercises the engine's actual socket
                    # timeout/Logout path; do not fake destruction by RPC.
                    deadline = time.monotonic() + options.startup_timeout
                    while time.monotonic() < deadline:
                        if any(p.poll() is not None for p in (server, observer)):
                            raise RuntimeError("A remaining owned process exited during disconnect cleanup")
                        record["disconnect_cleanup"] = verify_disconnect_cleanup(log_text(roles[0]),
                            log_text(roles[1]), log_text(rejoined))
                        if record["disconnect_cleanup"]["passed"]:
                            break
                        time.sleep(0.5)
                    record["runtime_pass"] = record["runtime_pass"] and record["disconnect_cleanup"]["passed"]
                save()
        if options.native_replay:
            native_log = Path(roles[1]["native_log"]).read_text(errors="replace")
            record["input_isolation_pass"] = "ReplayInputIsolationProbe passed=1" in native_log
            record["runtime_pass"] = record["runtime_pass"] and record["input_isolation_pass"]
        if options.motion_fixture:
            motion_log = log_text(roles[1])
            clip = Path(roles[1]["motion_fixture_root"]) / "clip-1.kfm"
            checks = {"saved": "KF2VR_MOTION_FIXTURE phase=saved status=3" in motion_log,
                      "playing": "KF2VR_MOTION_FIXTURE phase=playing passed=True" in motion_log,
                      "complete": "KF2VR_MOTION_FIXTURE phase=complete passed=True" in motion_log,
                      "clip_written": clip.exists() and clip.stat().st_size > 0,
                      "recording_capture": (Path(roles[1]["captures"]) / "hands-850.png").exists(),
                      "playback_capture": (Path(roles[1]["captures"]) / "hands-851.png").exists(),
                      "restored_capture": (Path(roles[1]["captures"]) / "hands-852.png").exists()}
            if saved_motion:
                checks = {"source_unchanged":digest(options.motion_clip)==saved_motion['sha256'],
                          "staged_identical":digest(clip)==saved_motion['sha256'],
                          "natural_end":"KF2VR_MOTION_FIXTURE phase=network_end passed=True" in motion_log,
                          "restored":"KF2VR_MOTION_FIXTURE phase=network_complete passed=True" in motion_log}
            record["synthetic_motion_fixture"] = {"passed": all(checks.values()), "checks": checks,
                                                  "clip": str(clip), "input": saved_motion["input"] if saved_motion else "authored synthetic; no physical XR"}
            record["runtime_pass"] = record["runtime_pass"] and all(checks.values())
            print("PHASE synthetic_motion_fixture=" + str(checks), flush=True)
            save()
            from motion_timeline import build as build_motion_timeline
            timeline = build_motion_timeline(output)
            record["network_motion"] = {"passed": timeline["passed"], "timeline": str(run / "motion-timeline.json"),
                                        "index": str(run / "index.html"), "checks": timeline["checks"]}
            record["runtime_pass"] = record["runtime_pass"] and timeline["passed"]
            print("PHASE network_motion=" + str(timeline["passed"]), flush=True)
        record["status"] = ("fire_reload_passed" if options.combat else "transport_passed") if record["runtime_pass"] else "evidence_failed"
    except BaseException as error:
        if options.lifecycle:
            record["lifecycle"] = verify_lifecycle(log_text(roles[0]), log_text(roles[1]), log_text(roles[2]), dual_weapons=options.dual_weapons)
        record["status"] = "failed"
        record["runtime_pass"] = False
        record["error"] = str(error)
        raise
    finally:
        # Only our Popen objects may be stopped. Never kill by process name/PID scan.
        cleanup_errors = []
        for role, process in reversed(list(zip(roles, processes))):
            try:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=5)
                    role["bounded_fixture_stop"] = True
                role["exit_code"] = process.returncode
            except OSError as error:
                cleanup_errors.append(f"{role['role']}: {error}")
            except subprocess.TimeoutExpired:
                cleanup_errors.append(f"{role['role']}: did not exit after bounded stop")
        try:
            if deployment:
                if all(process.poll() is not None for process in processes):
                    cleanup_errors += deployment.restore()
                else:
                    cleanup_errors.append("Native files retained because an owned process is still alive")
            if server_deployment:
                if all(process.poll() is not None for process in processes):
                    cleanup_errors += server_deployment.restore()
                else:
                    cleanup_errors.append("Server native files retained because an owned process is still alive")
            record["user_config_after"] = config_hashes(options.user_config)
            record["user_config_preserved"] = before == record["user_config_after"]
            if not record["user_config_preserved"] or cleanup_errors:
                record["runtime_pass"] = False
                record["status"] = "failed_cleanup"
            record["cleanup_errors"] = cleanup_errors
            record["finished_utc"] = datetime.now(timezone.utc).isoformat()
            save()
        finally:
            if locked:
                kernel.ReleaseMutex(mutex)
            if mutex:
                kernel.CloseHandle(mutex)
    return 0 if record["runtime_pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
