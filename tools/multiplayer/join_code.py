"""Portable, bounded connection details for a friend's matching release."""
import base64
import binascii
import ipaddress
import json
import re
import breacher

from workshop_loadout import parse_mods

PREFIX = "KF2VR1:"


def validate(details):
    required = {"address", "password", "port", "query_port", "build", "mods", "map"}
    if not isinstance(details, dict) or set(details) not in (required, required | {"breacher"}):
        raise ValueError("Invalid join code fields")
    for key, pattern in (("address", r"[A-Za-z0-9.-]{1,253}"),
                         ("password", r"[A-Za-z0-9_-]{1,64}"),
                         ("build", r"[A-Za-z0-9._-]{1,160}"),
                         ("map", r"KF-[A-Za-z0-9_-]{1,128}")):
        if not isinstance(details[key], str) or not re.fullmatch(pattern, details[key]):
            raise ValueError("Invalid join code " + key)
    ports = [details[key] for key in ("port", "query_port")]
    if any(type(port) is not int or not 1024 <= port <= 65000 for port in ports):
        raise ValueError("Invalid join code ports")
    if len({port + offset for port in ports for offset in (0, 10)}) != 4:
        raise ValueError("Join code ports overlap")
    mods = details["mods"]
    if not isinstance(mods, list) or any(not isinstance(mod, str) for mod in mods):
        raise ValueError("Invalid join code mods")
    if parse_mods(",".join(mods) or "none") != mods:
        raise ValueError("Invalid join code mods")
    if "breacher" in details:
        breacher.validate_descriptor(details["breacher"])
    return details


def encode(details):
    raw = json.dumps(validate(details), separators=(",", ":")).encode("utf-8")
    return PREFIX + base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def decode(code, build):
    if len(code) > 2048 or not re.fullmatch(re.escape(PREFIX) + r"[A-Za-z0-9_-]+", code):
        raise ValueError("Invalid join code. Copy the whole code from your host.")
    try:
        payload = code[len(PREFIX):]
        details = validate(json.loads(base64.b64decode(payload + "=" * (-len(payload) % 4), altchars=b"-_", validate=True)))
    except (ValueError, TypeError, UnicodeError, binascii.Error) as error:
        raise ValueError("Invalid join code. Copy the whole code from your host.") from error
    if details["build"] != build:
        raise ValueError("This join code uses a different KF2-VR build. Extract the same ZIP as your host.")
    return details


def public_address(log):
    """Read the address reported by the owned server's PlayFab registration."""
    candidates = re.findall(r'"ServerHost"\s*:\s*"([0-9.]+)"|Public IP ([0-9.]+)', log)
    for pair in reversed(candidates):
        try:
            address = ipaddress.ip_address(pair[0] or pair[1])
            if address.version == 4 and address.is_global:
                return str(address)
        except ValueError:
            pass
    return None
