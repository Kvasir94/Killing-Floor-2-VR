"""Logs a player sends to the developer: recent session logs plus an allowlisted summary.

Personal identifiers are replaced in report copies before archiving. Originals stay local."""
from datetime import datetime
import json
from pathlib import Path
import platform
import re
import zipfile
import os
import ipaddress

from session import digest, read_ini
from vr_config import DEFAULTS, values


def hardware_context():
    result = {"logical_processors": os.cpu_count(), "gpus": [], "openxr_vendor": "unknown"}
    if platform.system() != "Windows":
        return result
    import ctypes
    import winreg
    memory = ctypes.c_ulonglong()
    if ctypes.windll.kernel32.GetPhysicallyInstalledSystemMemory(ctypes.byref(memory)):
        result["installed_memory_mib"] = memory.value // 1024
    try:
        with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, r"SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}") as base:
            for index in range(winreg.QueryInfoKey(base)[0]):
                name = winreg.EnumKey(base, index)
                if not re.fullmatch(r"\d{4}", name):
                    continue
                with winreg.OpenKey(base, name) as device:
                    label = winreg.QueryValueEx(device, "DriverDesc")[0]
                    if re.fullmatch(r"(?:NVIDIA|AMD|Intel)[A-Za-z0-9 ()_.+-]{1,100}", label):
                        try:
                            version = str(winreg.QueryValueEx(device, "DriverVersion")[0])
                        except OSError:
                            version = ""
                        result["gpus"].append(label + (f" driver {version}" if re.fullmatch(r"[0-9.]{1,32}", version) else ""))
    except OSError:
        pass
    try:
        with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\Khronos\OpenXR\1") as key:
            runtime = winreg.QueryValueEx(key, "ActiveRuntime")[0].lower()
            result["openxr_vendor"] = next((vendor for token, vendor in (
                ("oculus", "Meta"), ("steam", "SteamVR"), ("mixedreality", "WMR"),
                ("virtualdesktop", "Virtual Desktop")) if token in runtime), "other")
    except OSError:
        pass
    return result


def summarize(root):
    manifest = json.loads((root / "release.json").read_text(encoding="utf-8"))
    report = {key: manifest.get(key) for key in ("build_id", "version", "protocol_version", "git_head", "public_release")}
    report.update(manifest_sha256=digest(root / "release.json"), os=platform.system(),
                  os_version=platform.version(), architecture=platform.machine(),
                  hardware_at_collection=hardware_context(), sessions=[])
    # Do not copy arbitrary strings from session files: even exception messages
    # and server names can contain passwords, account IDs and personal paths.
    for path in sorted((root / "sessions").glob("*/run.json"))[-5:]:
        raw = json.loads(path.read_text(encoding="utf-8"))
        entry = {key: raw.get(key) for key in ("vr", "host", "cleanup_complete", "user_config_preserved",
            "mod_handshake_observed", "inventory_focus", "multiplayer_grabs_host_requested")
            if isinstance(raw.get(key), (bool, type(None)))}
        entry["mode"] = raw.get("session_mode") if raw.get("session_mode") in ("solo", "host", "join") else "unknown"
        entry["roles"] = []
        for role in raw.get("roles", []):
            item = {"role": role.get("role") if role.get("role") in ("driver", "server", "teammate") else "unknown"}
            config = Path(role.get("config_root", "")).resolve()
            if config.is_relative_to(path.parent.resolve()) and (config / "KFGame.ini").is_file():
                text = read_ini(config / "KFGame.ini")
                item["preferences"] = {}
                for section, defaults in DEFAULTS.items():
                    for key, value in values(text, section).items():
                        # Only shipped scalar controls, never player-defined strings/arrays.
                        if key in defaults and re.fullmatch(r"True|False|true|false|-?\d+(?:\.\d+)?", value):
                            item["preferences"][key] = value
            log = Path(role.get("log", "")).resolve()
            if log.is_relative_to(path.parent.resolve()) and log.is_file():
                text = log.read_text(encoding="utf-8", errors="replace")[-2_000_000:]
                item["error_signals"] = {label: len(re.findall(pattern, text, re.I)) for label, pattern in {
                    "fatal": r"Critical:|Fatal error", "script_warning": r"ScriptWarning:",
                    "version_mismatch": r"package/protocol mismatch|version mismatch",
                    "timeout": r"timed out|timeout", "connection_failure": r"connection failed|connection lost",
                    "native_ready": r"server_adapter ready=1", "charged_fist": r"kind=charged",
                    "fist": r"kind=fist", "grab": r"KF2VR_ZEDGRAB action=grab"}.items()}
                permission = re.findall(r"grab_permission=(True|False)", text, re.I)
                item["authoritative_grab_permission"] = permission[-1].lower() == "true" if permission else None
                item.update(native_digest(log.with_name("native.log")))
            peak = role.get("peak_working_set_mib")
            item["peak_working_set_mib"] = peak if isinstance(peak, int) and not isinstance(peak, bool) else None
            entry["roles"].append(item)
        report["sessions"].append(entry)
    return report


def native_digest(path):
    """Numbers and allowlisted identifiers from the adapter log: headset, runtime,
    eye scale and the 5-second frame-pacing lines (always on, lite mode)."""
    if not path.is_file():
        return {}
    text = path.read_text(encoding="utf-8", errors="replace")[-2_000_000:]
    digest = {}
    ready = re.search(r"Game XR ready [^\n]*?runtime=([A-Za-z0-9 ._()/-]{1,64}) version=([0-9.]{1,32}) "
                      r"system=([A-Za-z0-9 ._()/-]{1,64}) recommendedEye=(\d+)x(\d+)", text)
    if ready:
        digest["headset"] = {"runtime": ready[1].strip(), "runtime_version": ready[2], "system": ready[3].strip(),
                             "recommended_eye": f"{ready[4]}x{ready[5]}"}
    scale = re.findall(r"RenderPerformance eyeRenderPercent=(\d+)", text)
    if scale:
        digest["eye_render_percent"] = int(scale[-1])
    pacing = re.findall(r"FramePacing mode=(\w+) intervals=(\d+)[^\n]*? meanMs=([\d.]+) p50Ms=([\d.]+) p95Ms=([\d.]+)"
                        r"[^\n]*? over90=(\d+) over120=(\d+)[^\n]*? runtimePeriodMs=([\d.]+)", text)
    if pacing:
        intervals = sum(int(p[1]) for p in pacing)
        digest["frame_pacing"] = {
            "mode": pacing[-1][0], "windows": len(pacing), "intervals": intervals,
            "over90_total": sum(int(p[5]) for p in pacing), "over120_total": sum(int(p[6]) for p in pacing),
            "mean_ms_weighted": round(sum(float(p[2]) * int(p[1]) for p in pacing) / intervals, 3) if intervals else None,
            "p50_ms_last": float(pacing[-1][3]), "p95_ms_last": float(pacing[-1][4]),
            "p95_ms_worst": max(float(p[4]) for p in pacing), "runtime_period_ms": float(pacing[-1][7])}
    return digest


PASSWORD = re.compile(r"(?i)(password\"?\s*[=:]\s*\"?)[^\s\"?&,]+")
JOIN_CODE = re.compile(r"KF2VR1:[^\s\"]+")


class ReportScrubber:
    """Per-report aliases, without exporting the reverse mapping or changing originals."""
    PRIVATE_KEYS = {
        "password": "secret", "hostpassword": "secret", "gamepassword": "secret",
        "adminpassword": "secret", "passwd": "secret", "token": "secret",
        "accesstoken": "secret", "refreshtoken": "secret", "authtoken": "secret",
        "authorization": "secret", "apikey": "secret", "secret": "secret",
        "username": "user", "user": "user", "player": "player", "playername": "player", "name": "player",
        "nickname": "player", "displayname": "player", "steamid": "account",
        "steamid64": "account", "uniqueid": "account", "accountid": "account", "userid": "account",
        "address": "address", "host": "address", "hostname": "address",
        "servername": "server", "serveraddress": "address", "ip": "address", "ipaddress": "address",
        "computername": "user", "machinename": "user", "email": "email",
    }
    LABEL = re.compile(
        r'''(?ix)\b(password|host_password|gamepassword|adminpassword|passwd|token|access_token|
        refresh_token|auth_token|authorization|api_key|secret|username|user|playername|player_name|
        name|player|nickname|displayname|steamid64|steamid|uniqueid|accountid|userid|address|
        hostname|servername|serveraddress|ipaddress|computername|machinename|email)
        ("?\s*[=:]\s*|\s+)("[^"\r\n]*"|'[^'\r\n]*'|[^\s?&,;]+)''')

    def __init__(self, secrets=()):
        self.aliases = {}
        self.known = {}
        for secret in secrets:
            if secret:
                self.remember(str(secret), "secret")
        for key in ("USERNAME", "USER"):
            if os.environ.get(key):
                self.remember(os.environ[key], "user")
        if os.environ.get("COMPUTERNAME"):
            self.remember(os.environ["COMPUTERNAME"], "user")
        for key in ("USERPROFILE", "HOME", "HOMEPATH"):
            if os.environ.get(key):
                self.remember(os.environ[key], "path")

    @staticmethod
    def key_kind(key):
        normalized = re.sub(r"[^a-z0-9]", "", key.lower())
        if any(part in normalized for part in ("password", "token", "secret", "apikey")):
            return "secret"
        return ReportScrubber.PRIVATE_KEYS.get(normalized)

    def remember(self, value, kind):
        if value and not value.startswith("<"):
            self.known.setdefault(value, kind)

    def alias(self, value, kind):
        if kind == "secret":
            return "<removed>"
        key = (kind, str(value).casefold())
        if key not in self.aliases:
            count = 1 + sum(k[0] == kind for k in self.aliases)
            self.aliases[key] = f"<{kind}-{count}>"
        return self.aliases[key]

    def learn(self, value):
        if isinstance(value, dict):
            for key, item in value.items():
                kind = self.key_kind(key)
                if kind:
                    self.learn_private(item, kind)
                self.learn(item)
        elif isinstance(value, list):
            for item in value:
                self.learn(item)
        elif isinstance(value, str):
            for match in self.LABEL.finditer(value):
                self.remember(match[3].strip("\"'"), self.key_kind(match[1]))

    def learn_private(self, value, kind):
        if isinstance(value, dict):
            for item in value.values():
                self.learn_private(item, kind)
        elif isinstance(value, list):
            for item in value:
                self.learn_private(item, kind)
        elif isinstance(value, (str, int)) and not isinstance(value, bool):
            self.remember(str(value), kind)

    def private_value(self, value, kind):
        if isinstance(value, dict):
            return {self.text(key): self.private_value(item, kind) for key, item in value.items()}
        if isinstance(value, list):
            return [self.private_value(item, kind) for item in value]
        return self.alias(value, kind) if isinstance(value, (str, int)) and not isinstance(value, bool) else value

    def text(self, text):
        text = scrub(text)
        text = re.sub(r"(?i)\bBearer\s+[^\s\"',;<>]+", "Bearer <removed>", text)
        text = re.sub(r'''(?i)\b[a-z][a-z0-9+.-]*://[^\s"'<>]+''',
                      lambda m: self.alias(m[0], "address"), text)
        # Quoted paths first; unquoted paths may contain spaces, so consume to a delimiter.
        text = re.sub(r'''(["'])([A-Za-z]:[\\/][^"'\r\n]+|/(?:home|Users)/[^"'\r\n]+)\1''',
                      lambda m: m[1] + self.alias(m[2], "path") + m[1], text)
        text = re.sub(r'''(?i)(?<![\w])(?:[A-Z]:[\\/]|\\\\)[^\r\n"'<>|]+|/(?:home|Users)/[^\r\n"'<>|]+''',
                      lambda m: self.alias(m[0], "path"), text)
        text = self.LABEL.sub(lambda m: m[1] + m[2] + self.alias(m[3].strip("\"'"), self.key_kind(m[1])), text)
        text = re.sub(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b",
                      lambda m: self.alias(m[0], "email"), text)
        text = re.sub(r"\b7656119\d{10}\b|\bSTEAM_\d:[01]:\d+\b|\[U:1:\d+\]",
                      lambda m: self.alias(m[0], "account"), text)
        def address(match):
            try:
                ipaddress.ip_address(match[0])
            except ValueError:
                return match[0]
            return self.alias(match[0], "address")
        text = re.sub(r"(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?![\w.])", address, text)
        text = re.sub(r"(?<![\w:])[0-9a-fA-F]*:[0-9a-fA-F:]+(?:%[\w]+)?(?![\w:])", address, text)
        text = re.sub(r"(?i)\b(?:https?://)?(?:[a-z0-9-]+\.)+[a-z]{2,}(?::\d+)?\b",
                      lambda m: self.alias(m[0], "address"), text)
        for value, kind in sorted(self.known.items(), key=lambda item: len(item[0]), reverse=True):
            text = re.sub(r"(?<!\w)" + re.escape(value) + r"(?!\w)",
                          lambda m: self.alias(value, kind), text, flags=re.I)
        return text

    def value(self, value):
        if isinstance(value, dict):
            result = {}
            for key, item in value.items():
                kind = self.key_kind(key)
                if kind:
                    result[self.text(key)] = self.private_value(item, kind)
                else:
                    result[self.text(key)] = self.value(item)
            return result
        if isinstance(value, list):
            return [self.value(item) for item in value]
        return self.text(value) if isinstance(value, str) else value


def scrub(text, secrets=()):
    """Remove session passwords and join codes; a log sent to the developer keeps everything else."""
    text = PASSWORD.sub(r"\1<removed>", JOIN_CODE.sub("KF2VR1:<removed>", text))
    for secret in secrets:
        if secret and len(secret) >= 4:
            text = text.replace(secret, "<removed>")
    return text


def decode_log(data):
    if data[:2] in (b"\xff\xfe", b"\xfe\xff"):
        return data.decode("utf-16", errors="replace")
    return data.decode("utf-8", errors="replace")


def collect_logs(root, destination, sessions=3, limit=6_000_000):
    """Sanitize every report entry before writing it; never write raw copies to disk."""
    root, destination = Path(root), Path(destination)
    secrets = set()
    settings = root / "settings.json"
    if settings.exists():
        secrets.add(json.loads(settings.read_text(encoding="utf-8")).get("host_password") or "")
    files = []
    for number, run in enumerate(sorted((root / "sessions").glob("*/run.json"))[-sessions:], 1):
        # Do not collect arbitrary JSON, configurations, deployment backups or crash dumps.
        paths = [p for p in sorted(run.parent.rglob("*"))
                 if p.is_file() and not p.is_symlink() and (p.suffix == ".log" or p == run)]
        for index, path in enumerate(paths, 1):
            name = path.name if path.name in ("game.log", "native.log", "run.json") else "log" + path.suffix
            files.append((path, f"sessions/session-{number}/{index:03}-{name}"))
    for index, path in enumerate(sorted((root / "logs").glob("*.txt"))[-5:], 1):
        files.append((path, f"launcher/{index:03}.txt"))
    for index, path in enumerate(sorted((root / "build/multiplayer/steamcmd").glob("install-*.log"))[-2:], 1):
        files.append((path, f"installer/{index:03}.log"))
    sanitizer = ReportScrubber(secrets)
    contents = []
    for path, name in files:
        if path.is_symlink() or not path.resolve().is_relative_to(root.resolve()):
            continue
        text = decode_log(path.read_bytes())[-limit:]
        try:
            value = json.loads(text) if path.suffix == ".json" else text
        except ValueError:
            value = text
        sanitizer.learn(value)
        contents.append((name, value))
    try:
        summary = summarize(root)
    except (OSError, ValueError, KeyError):
        # Exception messages may embed identifiers; report only the failure category.
        summary = {"collection_warning": "Session summary unavailable"}
    target = destination / ("KF2-VR logs " + datetime.now().strftime("%Y-%m-%d %H-%M-%S") + ".zip")
    with zipfile.ZipFile(target, "x", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("summary.json", json.dumps(sanitizer.value(summary), indent=2))
        for name, value in contents:
            sanitized = sanitizer.value(value)
            archive.writestr(name, json.dumps(sanitized, indent=2) if isinstance(sanitized, (dict, list)) else sanitized)
    return target
