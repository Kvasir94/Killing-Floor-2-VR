"""Explicit, session-only Solo test control. No profile saves or process access."""
import argparse
import os
from pathlib import Path
import re
import tempfile
import time
import uuid

HEX_ID = re.compile(r"[0-9a-f]{32}\Z")
TOKEN = re.compile(r"[A-Za-z0-9_.-]{1,96}\Z")
ZEDS = ("cyst", "alpha", "slasher", "crawler", "gorefast", "bloat", "husk", "scrake", "fleshpound")
OPERATIONS = ("status", "catalog", "give-all", "give-one", "spawn-zeds", "disable")


def add_options(parser):
    parser.add_argument("--local-test-control", action="store_true", default=False,
                        help="Solo VR only, this launch: UNRANKED local agent control and test capacity bypass; not saved")


def validate_options(args):
    if not getattr(args, "local_test_control", False):
        return
    if not getattr(args, "solo", False) or not getattr(args, "vr", False):
        raise RuntimeError("Local agent test control currently requires Solo VR. Hosted LAN server control is not implemented.")
    if getattr(args, "replay_teammate", False) or getattr(args, "avatar_preview", False):
        raise RuntimeError("Local agent test control cannot be combined with network replay/preview modes.")


def configure_role(role, args, role_name):
    if not getattr(args, "local_test_control", False):
        return
    validate_options(args)
    if role_name != "driver":
        raise RuntimeError("Local agent test control requires the standalone local driver authority.")
    session = getattr(args, "local_test_session", None)
    if session is None:
        session = args.local_test_session = uuid.uuid4().hex
    if not HEX_ID.fullmatch(session):
        raise RuntimeError("Invalid local test session ID")
    url = role["args"][0]
    marker = "?Mutator="
    if marker not in url:
        raise RuntimeError("Owned VR mutator chain is missing; test control remains off")
    start = url.index(marker) + len(marker)
    end = url.find("?", start)
    if end < 0:
        end = len(url)
    mutators = url[start:end].split(",")
    if "KF2VR.VRLocalTestControl" not in mutators:
        mutators.append("KF2VR.VRLocalTestControl")
    role["args"][0] = (url[:start] + ",".join(mutators) + url[end:]
                        + f"?KF2VRLocalTest=1?KF2VRLocalTestSession={session}?KF2VRTestCapacity=1")
    role["args"].append("-kf2vr-local-test-control")
    role["local_test_control"] = {"session": session, "test_unranked": True, "capacity_bypass": True,
                                  "scope": "standalone_local_authority", "hosted_lan_supported": False}


def channel_path(session):
    if not HEX_ID.fullmatch(session):
        raise ValueError("Session must be 32 lowercase hex digits")
    # Match native GetTempPathW; no caller-provided arbitrary root path.
    base = Path(os.environ.get("TMP") or os.environ.get("TEMP") or tempfile.gettempdir())
    if not base.is_absolute() or str(base).startswith(("\\\\", "//")):
        raise ValueError("Local test channels require an absolute local temporary directory")
    path = base / "KF2VRLocalTest" / session
    for component in (path, *path.parents):
        if component.exists() and (component.is_symlink() or (hasattr(component, "is_junction") and component.is_junction())):
            raise ValueError("Reparse paths are not allowed")
    return path


def request_wire(session, action_id, operation, player_id, argument="-", count=0):
    if not HEX_ID.fullmatch(session) or not HEX_ID.fullmatch(action_id):
        raise ValueError("Session and action ID must be 32 lowercase hex digits")
    if operation not in OPERATIONS or not isinstance(player_id, int) or not 0 <= player_id <= 2147483647:
        raise ValueError("Invalid operation or local player ID")
    if not TOKEN.fullmatch(argument) or ".." in argument:
        raise ValueError("Argument must be a bounded protocol token")
    if operation in ("status", "disable") and (argument != "-" or count != 0):
        raise ValueError("Status/disable accepts no argument or count")
    if operation in ("catalog", "give-all") and count != 0:
        raise ValueError("Catalog/give-all accepts no count")
    if operation == "give-one" and (argument == "-" or count != 1):
        raise ValueError("Give-one requires an allowlisted full class path and count 1")
    if operation == "spawn-zeds" and (argument not in ZEDS or not 1 <= count <= 6):
        raise ValueError("Spawn-zeds requires an allowlisted type and count 1..6")
    wire = f"{session}\t{action_id}\t{operation}\t{player_id}\t{argument}\t{count}"
    if len(wire) > 512:
        raise ValueError("Request exceeds protocol limit")
    return wire


def submit(session, operation, player_id, argument="-", count=0, action_id=None, timeout=45):
    if not 1 <= timeout <= 120:
        raise ValueError("Timeout must be 1..120 seconds")
    action_id = action_id or uuid.uuid4().hex
    wire = request_wire(session, action_id, operation, player_id, argument, count)
    root = channel_path(session)
    ready = root / "ready.tsv"
    request = root / f"{action_id}.request"
    receipt = root / f"{action_id}.receipt"
    intent = root / f"{action_id}.intent"
    for file in (ready, request, receipt, intent):
        if file.exists() and (file.is_symlink() or file.stat().st_nlink != 1):
            raise RuntimeError("Linked channel files are not allowed")
    if intent.exists():
        if intent.read_text(encoding="ascii") != wire:
            raise RuntimeError("Action ID already belongs to a different request")
    else:
        if not ready.is_file() or ready.read_text(encoding="ascii").split("\t")[0] != session:
            raise RuntimeError("The explicitly enabled test session is not ready; no request was sent")
        with intent.open("x", encoding="ascii", newline="") as output:
            output.write(wire)
            output.flush()
            os.fsync(output.fileno())
    deadline = time.monotonic() + timeout
    if not receipt.exists():
        if not ready.is_file() or ready.read_text(encoding="ascii").split("\t")[0] != session:
            raise RuntimeError("The explicitly enabled test session is not ready; no request was sent")
        if request.exists():
            if request.read_text(encoding="ascii") != wire:
                raise RuntimeError("Queued action ID belongs to a different request")
        else:
            temporary = root / f"{action_id}.writing"
            with temporary.open("x", encoding="ascii", newline="") as output:
                output.write(wire)
                output.flush()
                os.fsync(output.fileno())
            try:
                # Rename fails if the action is already queued; no overwrite.
                temporary.rename(request)
            finally:
                if temporary.exists():
                    temporary.unlink()
    while time.monotonic() < deadline:
        if receipt.is_file():
            text = receipt.read_text(encoding="ascii")
            prefix = f"{session}\t{action_id}\t"
            if not text.startswith(prefix):
                raise RuntimeError("Receipt identity mismatch")
            result = text[len(prefix):].rstrip("\n")
            if not result.startswith("pending\t"):
                return action_id, result
        time.sleep(0.1)
    raise TimeoutError(f"No final receipt for action {action_id}; do not retry with a new ID. Inspect audit.tsv.")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--session", required=True)
    parser.add_argument("--player", type=int, required=True, help="Exact local PlayerReplicationInfo.PlayerID; status lists IDs")
    parser.add_argument("--action-id", help="Reuse only to inspect/retry the identical action")
    parser.add_argument("--timeout", type=int, default=45)
    parser.add_argument("operation", choices=OPERATIONS)
    parser.add_argument("--argument", default="-", help="Catalog/give-all perk class name, give-one full class path, or zed type")
    parser.add_argument("--count", type=int, default=0)
    args = parser.parse_args(argv)
    try:
        action_id, result = submit(args.session, args.operation, args.player, args.argument, args.count, args.action_id, args.timeout)
    except (ValueError, RuntimeError, TimeoutError, OSError) as error:
        parser.exit(2, f"{error}\n")
    print(f"action_id={action_id}\n{result}")
    return 0 if result.startswith("ok\t") else 1


if __name__ == "__main__":
    raise SystemExit(main())
