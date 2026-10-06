"""Per-launch native promo logging; never a saved graphics/profile preference."""
from pathlib import Path
import re
import uuid


def configure(roles, enabled):
    if not enabled:
        return None
    session = str(uuid.uuid4())
    for role in roles:
        if ((role["role"] == "driver" and role.get("native_adapter"))
                or (role["role"] == "server" and role.get("server_adapter"))):
            role["promo_session"] = session
            role["promo_log"] = str(Path(role["log"]).with_name("promo-events.jsonl"))
    return session


def environment(role):
    session = role.get("promo_session")
    if session is None:
        return {}
    if not isinstance(session, str) or not re.fullmatch(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", session):
        raise ValueError("Invalid promo session ID")
    name = role["role"]
    if not ((name == "driver" and role.get("native_adapter") and "-kf2vr-stereo" in role["args"])
            or (name == "server" and role.get("server_adapter"))):
        raise ValueError("Promo logging needs a live VR driver or its host authority")
    path = Path(role["log"]).with_name("promo-events.jsonl")
    if role.get("promo_log") != str(path):
        raise ValueError("Promo event output must stay beside this role's game log")
    return {"KF2VR_PROMO_SESSION": session, "KF2VR_PROMO_ROLE": name,
            "KF2VR_PROMO_LOG_PATH": str(path)}
