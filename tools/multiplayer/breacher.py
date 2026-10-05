"""Opt-in local Breacher package contract; never downloads or installs content."""
from pathlib import Path
import hashlib
import json
import re

PROTOCOL = 1
MUTATOR = "KF2Breacher.BreacherMutator"


def validate_descriptor(value):
    if (not isinstance(value, dict) or set(value) != {"protocol", "sha256"}
            or type(value["protocol"]) is not int or value["protocol"] != PROTOCOL
            or not isinstance(value["sha256"], str)
            or not re.fullmatch(r"[0-9A-F]{64}", value["sha256"])):
        raise ValueError("Breacher content contract is invalid or unsupported; use the host's matching experimental package.")
    return value


def prepare(args, root, release):
    args.breacher_content = None
    if not getattr(args, "breacher", False):
        return None
    if release.get("breacher_protocol") != PROTOCOL:
        raise RuntimeError("Breacher requires the experimental core build; this release has no Breacher compatibility support.")
    folder = Path(root) / "optional/breacher"
    package, manifest = folder / "KF2Breacher.u", folder / "manifest.json"
    if not package.is_file() or not manifest.is_file() or not (folder / "Localization/INT/KF2Breacher.int").is_file():
        raise RuntimeError("Breacher package is missing. Supply the compiled experimental optional/breacher package or turn Breacher OFF. No automatic download is available.")
    descriptor = validate_descriptor(json.loads(manifest.read_text(encoding="utf-8-sig")))
    with package.open("rb") as stream:
        if stream.read(4) != b"\xc1\x83\x2a\x9e":
            raise RuntimeError("Breacher package is not an Unreal package.")
        stream.seek(0)
        digest = hashlib.file_digest(stream, "sha256").hexdigest().upper()
    if digest != descriptor["sha256"]:
        raise RuntimeError("Breacher package hash differs from its manifest. Restore the matching compiled package.")
    expected = getattr(args, "breacher_expected", None)
    if expected is not None and descriptor != validate_descriptor(expected):
        raise RuntimeError("Breacher package differs from the host. Get the same compiled experimental package before joining.")
    if not (getattr(args, "host", False) or getattr(args, "solo", False)) and expected is None:
        raise RuntimeError("Breacher joins require the host's complete join code; manual address joining cannot verify its content contract.")
    args.breacher_content = dict(descriptor, root=str(folder.resolve()))
    return descriptor


def descriptor(args):
    content = getattr(args, "breacher_content", None)
    return {key: content[key] for key in ("protocol", "sha256")} if content else None


def options(args):
    if not getattr(args, "breacher", False):
        return ""
    contract = descriptor(args)
    if contract is None:
        raise RuntimeError("Breacher package must be validated before preparing a launch URL.")
    return f"?BreacherProtocol={contract['protocol']}?BreacherPackage={contract['sha256']}"


def add_mutator(url, args):
    if not getattr(args, "breacher", False):
        return url
    # Validate before exposing the option, even when a caller supplied a URL.
    options(args)
    parts = url.split("?")
    indexes = [i for i, part in enumerate(parts) if part.lower().startswith("mutator=")]
    if len(indexes) > 1:
        raise ValueError("Multiple Mutator URL options are ambiguous.")
    if indexes:
        index = indexes[0]
        mutators = [item for item in parts[index].partition("=")[2].split(",") if item]
        if MUTATOR not in mutators:
            mutators.append(MUTATOR)
        parts[index] = "Mutator=" + ",".join(mutators)
    else:
        parts.append("Mutator=" + MUTATOR)
    return "?".join(parts)


def configure_content(configs, args):
    content = getattr(args, "breacher_content", None)
    from session import read_ini, set_ini
    path = Path(configs) / "KFEngine.ini"
    enabled = bool(getattr(args, "breacher", False) and content)
    if not path.is_file() and not enabled:
        return
    text = read_ini(path)
    section = re.search(r"(?ims)^\[Core\.System\][^\n]*\n(.*?)(?=^\[|\Z)", text)
    if not section:
        if not enabled:
            return
        raise RuntimeError("Missing Core.System for Breacher content")
    values = {}
    for key in ("Paths", "ScriptPaths", "SeekFreePCPaths", "BrewedPCPaths", "LocalizationPaths"):
        existing = re.findall(r"(?im)^" + key + r"=([^\r\n]*)", section[1])
        # A prior optional release must not leak its package through copied role settings.
        retained = [value for value in existing if not re.search(r"(?:^|[/\\])optional[/\\]breacher(?:[/\\]Localization)?[/\\]?$", value, re.I)]
        prefix = ([str(Path(content["root"]) / "Localization") if key == "LocalizationPaths" else content["root"]] if enabled else [])
        values[key] = list(dict.fromkeys(prefix + retained))
    if not enabled and all(values[key] == re.findall(r"(?im)^" + key + r"=([^\r\n]*)", section[1]) for key in values):
        return
    path.write_text(set_ini(text, "Core.System", values), encoding="utf-16")
