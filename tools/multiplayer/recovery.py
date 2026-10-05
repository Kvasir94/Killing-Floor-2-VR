"""Explicit, idempotent restoration of positively identified deployments."""
import ctypes
import json
from pathlib import Path
import re
import subprocess

from native_fixture import NativeDeployment
from session import digest
from vr_config import export_preferences
from watchdog import api, creation_time


def recover_record(path):
    record = json.loads(path.read_text(encoding="utf-8"))
    if record.get("cleanup_complete"):
        return []
    errors = []
    for key in ("native_deployment", "server_native_deployment"):
        entry = record.get(key)
        if not entry:
            continue
        backup = Path(entry["backup"]).resolve()
        if not backup.is_relative_to(path.parent.resolve()):
            errors.append("Backup outside session folder; inspect manually")
            continue
        deployment = NativeDeployment(Path(entry["source"]), Path(entry["destination"]), backup,
                                      entry["receipt"], digest, server=entry.get("server", False))
        if not deployment.journal_path.exists():
            errors.append("No durable ownership journal (legacy or unstarted deployment); inspect manually")
            continue
        errors.extend(deployment.restore())
    if record.get("vr") and any(r.get("pid") for r in record.get("roles", [])):
        try:
            driver = next(r for r in record["roles"] if r["role"] == "driver")
            export_preferences(Path(driver["config_root"]), network=record.get("session_mode") != "solo")
            record["preferences_saved"] = True
        except (OSError, ValueError, StopIteration) as error:
            errors.append("Preferences could not be saved: " + str(error))
    elif record.get("vr") is False and record.get("user_config_root") and any(r.get("pid") for r in record.get("roles", [])):
        try:
            from desktop_settings import export
            driver = next(r for r in record["roles"] if r["role"] == "driver")
            export(Path(driver["config_root"]), Path(record["user_config_root"]))
            record["preferences_saved"] = True
        except (OSError, ValueError, StopIteration) as error:
            errors.append("Desktop settings could not be saved: " + str(error))
    record.update(cleanup_complete=not errors, cleanup_errors=errors, status="recovered" if not errors else "recovery_incomplete")
    from friends import save_session_record
    save_session_record(path, record)
    return errors


def recover_all(root):
    # Restoration never terminates a process. Require both the normal shared
    # lease and absence of running KF2 processes, including unrelated games.
    kernel = api()
    kernel.CreateMutexW.restype = ctypes.c_void_p
    kernel.CreateMutexW.argtypes = (ctypes.c_void_p, ctypes.c_int, ctypes.c_wchar_p)
    kernel.ReleaseMutex.argtypes = (ctypes.c_void_p,)
    mutex = kernel.CreateMutexW(None, False, "Local\\KF2VR_DevelopmentFixture")
    locked = bool(mutex) and kernel.WaitForSingleObject(mutex, 0) in (0, 0x80)
    try:
        if not locked:
            raise RuntimeError("Another session is active. Close its launcher before recovery.")
        listing = subprocess.check_output(["tasklist", "/FO", "CSV", "/NH"], text=True)
        if re.search(r'"KF(?:Game|Editor|Server)\.exe"', listing, re.I):
            raise RuntimeError("Close KF2, its editor and servers before recovery. No processes were terminated.")
        for path in sorted((Path(root) / "sessions").glob("*/run.json")):
            record = json.loads(path.read_text(encoding="utf-8"))
            # A live recorded launcher also prevents old-profile replay.
            pid, created = record.get("launcher_pid"), record.get("launcher_creation_time")
            if pid and created:
                handle = kernel.OpenProcess(0x1000 | 0x100000, False, pid)
                if handle:
                    try:
                        if creation_time(kernel, handle) == created and kernel.WaitForSingleObject(handle, 0) == 258:
                            raise RuntimeError("Recorded launcher is still running; close it before recovery")
                    finally:
                        kernel.CloseHandle(handle)
            errors = recover_record(path)
            print(path.parent.name + ": " + ("; ".join(errors) if errors else "restored / already clean"))
    finally:
        if locked:
            kernel.ReleaseMutex(mutex)
        if mutex:
            kernel.CloseHandle(mutex)
