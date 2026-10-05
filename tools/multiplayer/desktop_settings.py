"""A desktop player's own KF2 settings, kept across KF2-VR sessions.

The player client runs from copies of the player's KF2 config, whose originals
stay untouched and hash-checked. After a desktop session, every section the
player changed in-game (sensitivity, bindings, resolution, FOV and so on) is
saved to the KF2-VR profile with the stock text it replaced, and replayed into
the next session's copies. If the player has since changed that section in
stock KF2, stock wins and the saved copy is dropped. Sections the launcher
manages for the connection, and KF2VR's own sections, are never recorded.
"""
import json
from pathlib import Path
import re
import shutil

from session import read_ini
from vr_config import profile_root

PROFILE_FILE = "desktop-settings.json"
SNAPSHOT = "LaunchConfig"
HEADER = re.compile(r"^[ \t]*\[([^\]\r\n]+)\][ \t]*$")


def sections(text):
    """Section name -> normalized body; a section repeated in one file maps to None."""
    found, current = {}, None
    for line in text.split("\n"):
        match = HEADER.match(line)
        if match:
            current = match[1]
            found[current] = None if current in found else []
        elif current is not None and found[current] is not None and line.strip():
            found[current].append(line.rstrip())
    return {name: None if body is None else "\n".join(body) for name, body in found.items()}


def replace_section(text, section, body):
    pattern = re.compile(r"(?ims)^[ \t]*\[" + re.escape(section) + r"\][^\r\n]*(?:\r?\n|$).*?(?=^[ \t]*\[|\Z)")
    block = f"[{section}]\n" + (body + "\n" if body else "") + "\n"
    if pattern.search(text):
        return pattern.sub(lambda _: block, text, count=1)
    return text.rstrip() + "\n\n" + block


def owned_by_player(section):
    return not section.startswith("KF2VR")


def read_sections(path):
    return sections(read_ini(path)) if path.exists() else {}


def load(root=None):
    path = (root or profile_root()) / PROFILE_FILE
    try:
        saved = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return saved if isinstance(saved, dict) else {}


def apply(config_root, user, root=None):
    """Replay saved sections into a prepared desktop session, then snapshot it."""
    configs = Path(config_root)
    for name, saved in load(root).items():
        path = configs / name
        if not path.exists() or not isinstance(saved, dict):
            continue
        text = read_ini(path)
        stock, session = read_sections(Path(user) / name), sections(text)
        for section, entry in saved.items():
            base = stock.get(section, "")
            # The launcher already rewrote this section for the connection, or
            # the player changed it in stock KF2 since: neither is replaced.
            if (not isinstance(entry, dict) or entry.get("base") != base or base is None
                    or session.get(section, "") != base or not owned_by_player(section)):
                continue
            text = replace_section(text, section, entry.get("value", ""))
        path.write_text(text, encoding="utf-16")
    snapshot = configs.parent / SNAPSHOT
    shutil.rmtree(snapshot, ignore_errors=True)
    shutil.copytree(configs, snapshot)


def export(config_root, user, root=None):
    """Save the sections the player changed during this desktop session."""
    configs = Path(config_root)
    snapshot = configs.parent / SNAPSHOT
    if not snapshot.is_dir():
        return
    saved = load(root)
    for path in sorted(configs.glob("*.ini")):
        stock, launch = read_sections(Path(user) / path.name), read_sections(snapshot / path.name)
        final = read_sections(path)
        previous = saved.get(path.name) if isinstance(saved.get(path.name), dict) else {}
        # An entry stock KF2 has since overtaken is no longer the player's choice.
        kept = {section: entry for section, entry in previous.items()
                if isinstance(entry, dict) and entry.get("base") == stock.get(section, "")}
        for section, body in final.items():
            before, base = launch.get(section, ""), stock.get(section, "")
            if body is None or before is None or base is None or body == before or not owned_by_player(section):
                continue
            replayed = kept.get(section, {}).get("value")
            if before != base and before != replayed:
                continue
            if body == base:
                kept.pop(section, None)
            else:
                kept[section] = {"base": base, "value": body}
        if kept:
            saved[path.name] = kept
        else:
            saved.pop(path.name, None)
    directory = root or profile_root()
    directory.mkdir(parents=True, exist_ok=True)
    target = directory / PROFILE_FILE
    temporary = target.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(saved, indent=2), encoding="utf-8")
    temporary.replace(target)
