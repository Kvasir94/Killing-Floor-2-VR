"""Manifest-only Workshop copying and reversible, per-account Steam setup.

Adapted from OptimumBox's KF2VR Workshop distribution (68932aef).
"""
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil


def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest().upper()


def contained(root, name):
    root = Path(root).resolve()
    relative = PurePosixPath(name)
    if (not name or "\\" in name or ":" in name or relative.is_absolute()
            or any(p in ("", ".", "..") for p in name.split("/"))):
        raise ValueError(f"Invalid release path: {name}")
    path = root.joinpath(*relative.parts)
    if not path.resolve().is_relative_to(root):
        raise ValueError(f"Release path escapes its folder: {name}")
    return path


def package_path(item, name):
    """Shared game packages live once, under the item's BrewedPC."""
    if name.startswith("Packages/") and name.endswith((".u", ".upk")):
        folder = "Script" if name.endswith(".u") else "Packages"
        return contained(Path(item) / "BrewedPC" / folder, name[len("Packages/"):])
    return contained(Path(item) / "KF2VR/app", name)


def verified_files(app, *, item=None):
    app = Path(app)
    manifest = json.loads((app / "release.json").read_text(encoding="utf-8-sig"))
    files = {}
    for name, expected in manifest["files_sha256"].items():
        path = package_path(item, name) if item is not None else contained(app, name)
        if not path.is_file() or digest(path) != expected.upper():
            raise ValueError(f"Release file missing or changed: {name}")
        files[name] = path
    if not {"Packages/KF2VR.u", "Packages/KF2VRNet.u", "Packages/KF2VRHands.upk"} <= files.keys():
        raise ValueError("Release is missing its desktop game packages")
    return manifest, files


@contextmanager
def local_lock(path):
    """The OS releases this lock if a launcher is interrupted."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a+b") as stream:
        stream.seek(0)
        if os.name == "nt":
            import msvcrt
            if not path.stat().st_size:
                stream.write(b"0")
                stream.flush()
            stream.seek(0)
            try:
                msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
            except OSError as error:
                raise RuntimeError("Another Workshop launcher is using this copy.") from error
        else:
            import fcntl
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            yield
        finally:
            stream.seek(0)
            if os.name == "nt":
                msvcrt.locking(stream.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                fcntl.flock(stream, fcntl.LOCK_UN)


@contextmanager
def copy_lease(name="Local\\KF2VR_DevelopmentFixture"):
    """Reuse the launcher's session mutex only while updating its files."""
    import ctypes
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.CreateMutexW.restype = ctypes.c_void_p
    kernel.CreateMutexW.argtypes = (ctypes.c_void_p, ctypes.c_int, ctypes.c_wchar_p)
    kernel.WaitForSingleObject.argtypes = (ctypes.c_void_p, ctypes.c_uint)
    kernel.ReleaseMutex.argtypes = kernel.CloseHandle.argtypes = (ctypes.c_void_p,)
    handle = kernel.CreateMutexW(None, False, name)
    locked = bool(handle) and kernel.WaitForSingleObject(handle, 0) in (0, 0x80)
    try:
        if not locked:
            raise RuntimeError("Another KF2-VR session is active. Let it finish cleanup before updating.")
        yield
    finally:
        if locked:
            kernel.ReleaseMutex(handle)
        if handle:
            kernel.CloseHandle(handle)


def mirror(item, destination):
    """Replace only shipped files; leave profiles and interrupted sessions alone."""
    item, destination = Path(item).resolve(), Path(destination).resolve()
    if destination.is_relative_to(item) or item.is_relative_to(destination):
        raise ValueError("Workshop source and writable copy must be separate")
    app = destination / "app"
    manifest, files = verified_files(item / "KF2VR/app", item=item)
    previous = {}
    if (app / "release.json").is_file():
        previous = json.loads((app / "release.json").read_text(encoding="utf-8-sig")).get("files_sha256", {})
    # Validate old names before mutating anything. Remove only formerly shipped
    # files, never user settings, sessions, logs or cache directories.
    removed = [contained(app, name) for name in previous.keys() - files.keys()]
    for name, source in files.items():
        target = contained(app, name)
        target.parent.mkdir(parents=True, exist_ok=True)
        if not target.is_file() or digest(target) != manifest["files_sha256"][name].upper():
            temporary = target.with_name(target.name + ".kf2vr-new")
            shutil.copyfile(source, temporary)
            temporary.replace(target)
    for target in removed:
        if target.is_file():
            target.unlink()
    # Publish identity last. An interrupted copy is repaired by the next mirror.
    app.mkdir(parents=True, exist_ok=True)
    temporary = app / "release.json.kf2vr-new"
    temporary.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    temporary.replace(app / "release.json")
    verified_files(app)
    return app


_TOKEN = re.compile(r'\s+|//[^\r\n]*|"(?:[^"\\]|\\.)*"|[{}]|[^\s{}"]+')


def vdf_tree(text):
    """Parse token spans so edits preserve every unrelated VDF byte."""
    tokens = []
    offset = 0
    for match in _TOKEN.finditer(text):
        if match.start() != offset:
            raise ValueError("Malformed Steam config")
        offset = match.end()
        value = match.group()
        if value.isspace() or value.startswith("//"):
            continue
        if value.startswith('"'):
            value = re.sub(r'\\([\\"])', r'\1', value[1:-1])
        tokens.append((value, match.start(), match.end(), match.group().startswith('"')))
    if offset != len(text):
        raise ValueError("Malformed Steam config")
    index = 0

    def block(nested=False):
        nonlocal index
        result = {}
        while index < len(tokens):
            key, start, _, quoted_key = tokens[index]
            index += 1
            if key == "}" and not quoted_key:
                if nested:
                    return result, start
                raise ValueError("Unexpected closing brace in Steam config")
            if (key == "{" and not quoted_key) or index >= len(tokens) or key.lower() in result:
                raise ValueError("Malformed or duplicate Steam config key")
            value, begin, end, quoted = tokens[index]
            index += 1
            if value == "{" and not quoted:
                children, close = block(True)
                result[key.lower()] = (start, begin, close + 1, children)
            elif value == "}" and not quoted:
                raise ValueError("Missing Steam config value")
            else:
                result[key.lower()] = (start, begin, end, value)
        if nested:
            raise ValueError("Unclosed Steam config block")
        return result, len(text)

    return block()[0]


def _apps(text):
    tree = vdf_tree(text)
    for key in ("userlocalconfigstore", "software", "valve", "steam", "apps"):
        node = tree.get(key)
        if not node or not isinstance(node[3], dict):
            raise ValueError("Steam config has no recognized apps block")
        tree = node[3]
    return node


def launch_options(text):
    game = _apps(text)[3].get("232090")
    entry = game[3].get("launchoptions") if game and isinstance(game[3], dict) else None
    if entry and not isinstance(entry[3], str):
        raise ValueError("Malformed LaunchOptions")
    return entry[3] if entry else None


def set_launch_options(text, value):
    apps = _apps(text)
    game = apps[3].get("232090")
    escaped = '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"' if value is not None else None
    if not game:
        if value is None:
            return text
        at = apps[2] - 1
        return text[:at] + '\n"232090"\n{\n"LaunchOptions" ' + escaped + '\n}\n' + text[at:]
    if not isinstance(game[3], dict):
        raise ValueError("Malformed KF2 config block")
    entry = game[3].get("launchoptions")
    if entry:
        start = entry[1] if escaped is not None else entry[0]
        return text[:start] + (escaped or "") + text[entry[2]:]
    if escaped is None:
        return text
    at = game[2] - 1
    return text[:at] + '\n"LaunchOptions" ' + escaped + '\n' + text[at:]


def configure_account(config, play, *, remove=False):
    """Change exactly one account and restore its prior launch option value."""
    config = Path(config)
    state_path = config.with_name(config.name + ".kf2vr-launch.json")
    raw = config.read_bytes()
    text = raw.decode("utf-8-sig")
    old = launch_options(text)
    state = json.loads(state_path.read_text(encoding="utf-8")) if state_path.exists() else None
    if state and old not in (state["installed"], state["previous"]):
        raise ValueError("KF2 Launch Options changed since setup. Restore them manually before changing this setup.")
    if remove:
        if not state:
            raise ValueError("No saved KF2-VR Launch Options to restore for this account")
        value = state["previous"]
    else:
        previous = state["previous"] if state else old
        # Steam appends ordinary arguments to its game command; an existing
        # %command% wrapper remains the command passed to Play normally.
        command = previous if previous and "%command%" in previous else "%command%" + (" " + previous if previous else "")
        option = f'"{Path(play).resolve()}" {command}'
        value = option
        if not state:
            state = {"previous": old, "installed": option}
        state["installed"] = option
    updated = set_launch_options(text, value)
    if not remove:
        # Save the original state before the config write, including an absent key.
        state_path.write_text(json.dumps(state, indent=2), encoding="utf-8")
    temporary = config.with_name(config.name + ".kf2vr-new")
    temporary.write_bytes((b"\xef\xbb\xbf" if raw.startswith(b"\xef\xbb\xbf") else b"") + updated.encode("utf-8"))
    temporary.replace(config)
    if remove:
        state_path.unlink()
