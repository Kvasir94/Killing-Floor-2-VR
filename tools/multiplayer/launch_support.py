"""Launch and config helpers the player launcher needs.

Player-facing modules import these from here, so the player ZIP can leave out
the network diagnostic (session.py) and its evidence verifiers, which re-export
them unchanged.
"""
from __future__ import annotations

import hashlib
from pathlib import Path
import re
import shutil
import socket
import struct
import subprocess
import time

from vr_config import DEFAULTS, import_preferences


ROOT = Path(__file__).resolve().parents[2]


# Bytes/second per connection, for both the hosted server and every client.
NET_RATE = "150000"


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


def refresh_ini_versions(configs: Path, game: Path) -> None:
    """Restamp [IniVersion] in copied session inis so -NOAUTOINIUPDATE starts
    without the modal "Your ini is outdated" dialog. KF2 stamps each source
    Base/Default ini as its UTC mtime shifted by the difference between the
    current local offset and the offset on the file's date, so every daylight
    saving change makes copied inis look an hour outdated (2026-11-01: every
    launch stalled behind a hidden dialog from 07:00 UTC). A stamp is matched
    to its source by true mtime, allowing for the hour either way."""
    sources = {int(p.stat().st_mtime) for d in (game / "KFGame/Config", game / "KFGame/Config/Eos", game / "Engine/Config")
               if d.is_dir() for p in d.glob("*.ini")}
    now = time.localtime().tm_gmtoff

    def expected(stamp: int) -> int:
        for true in (stamp, stamp + 3600, stamp - 3600):
            if true in sources:
                return true + now - time.localtime(true).tm_gmtoff
        return stamp

    for path in Path(configs).glob("*.ini"):
        text = read_ini(path)
        section = re.search(r"(?ims)^\[IniVersion\][^\n]*\n(.*?)(?=^\[|\Z)", text)
        if not section:
            continue
        body = re.sub(r"(?m)^(\w+)=(\d+)(\.\d+)?", lambda m: f"{m[1]}={expected(int(m[2]))}{m[3] or ''}", section[1])
        if body != section[1]:
            raw = path.read_bytes()
            encoding = "utf-16" if raw.startswith((b"\xff\xfe", b"\xfe\xff")) else "utf-8"
            path.write_text(text[:section.start(1)] + body + text[section.end(1):], encoding=encoding)


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
    # The 120 Hz pose streams need more room than the stock 10 kB/s internet
    # cap. The client asks for ConfiguredInternetSpeed (LanSpeed for a
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
        engine = set_ini(engine, "IpDrv.TcpNetDriver", {"HandShakeTimeOutSec": "60",
            "NetServerMaxTickRate": "120", "LanServerMaxTickRate": "120"})
    native_driver = native_replay and (role == "driver" or (dual_vr_owners and role == "observer"))
    if native_replay and role != "server":
        engine = set_ini(engine, "Engine.Engine", {"GameViewportClientClassName": "KF2VRNetClient.KF2VRNetViewportClient"})
        engine = set_ini(engine, "KF2VRNetClient.KF2VRNetViewportClient", {"bDiagnosticInputIsolation": "true"})
    engine_path.write_text(engine, encoding="utf-16")
    game_path = configs / "KFGame.ini"
    game_ini = read_ini(game_path) if game_path.exists() else ""
    game_ini = set_ini(game_ini, "KF2VRNet.KF2VRNetPlayerController", {
        "bDiagnosticSyntheticAutoStart": "true" if role == "driver" and not native_driver else "false",
        "bDiagnosticSharingReplay": "false",
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
        args += ["-kf2vr-probe", "-kf2vr-network", "-kf2vr-hand-replay", "-onethread"]
    for kind in CONFIG_KINDS:
        name = {"SYSTEMSETTINGS": "KFSystemSettings"}.get(kind, "KF" + kind.title())
        args.append(f"-{kind}INI={configs / (name + '.ini')}")
    refresh_ini_versions(configs, game)
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


def check_port(port: int) -> None:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.bind(("127.0.0.1", port))


def events(log: str, kind: str) -> list[dict[str, str]]:
    result = []
    for line in log.splitlines():
        marker = f"KF2VRNet {kind} "
        if marker in line:
            result.append(dict(re.findall(r"(\w+)=([^\s]+)", line.split(marker, 1)[1])))
    return result


def parse_info(packet: bytes) -> dict:
    """Parse the fixed A2S_INFO prefix through VAC. Reject malformed/split packets."""
    if not packet.startswith(b"\xff\xff\xff\xffI") or len(packet) < 6:
        raise ValueError("Not a complete uncompressed A2S_INFO response")
    offset = 6
    strings = []
    for _ in range(4):
        end = packet.find(b"\0", offset)
        if end < 0:
            raise ValueError("Truncated A2S string")
        strings.append(packet[offset:end].decode("utf-8", errors="replace"))
        offset = end + 1
    if len(packet) < offset + 9:
        raise ValueError("Truncated A2S status")
    appid, players, maximum, bots, server_type, environment, visibility, vac = struct.unpack_from("<H7B", packet, offset)
    if vac not in (0, 1) or visibility not in (0, 1):
        raise ValueError("Invalid A2S security fields")
    return dict(name=strings[0], map=strings[1], folder=strings[2], game=strings[3],
                appid=appid, players=players, maximum=maximum, bots=bots,
                server_type=chr(server_type), environment=chr(environment), password=bool(visibility), secure=bool(vac))


def query_server(host: str, port: int, timeout: float = 1.0) -> dict:
    request = b"\xff\xff\xff\xffTSource Engine Query\0"
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.settimeout(timeout)
        sock.connect((host, port))
        sock.send(request)
        packet = sock.recv(65535)
        if packet.startswith(b"\xff\xff\xff\xffA"):
            if len(packet) != 9:
                raise ValueError("Malformed A2S challenge")
            sock.send(request + packet[5:9])
            packet = sock.recv(65535)
        return parse_info(packet)
