"""Detached cleanup for an unexpectedly closed friend launcher (owned handles only)."""
from __future__ import annotations

import ctypes
import json
from pathlib import Path
import sys
import time

from native_fixture import NativeDeployment
from session import digest


def api():
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.OpenProcess.restype = ctypes.c_void_p
    kernel.OpenProcess.argtypes = (ctypes.c_uint, ctypes.c_int, ctypes.c_uint)
    kernel.WaitForSingleObject.argtypes = (ctypes.c_void_p, ctypes.c_uint)
    kernel.TerminateProcess.argtypes = (ctypes.c_void_p, ctypes.c_uint)
    kernel.CloseHandle.argtypes = (ctypes.c_void_p,)
    kernel.GetProcessTimes.argtypes = (ctypes.c_void_p,) + (ctypes.POINTER(ctypes.c_uint64),) * 4
    return kernel


def creation_time(kernel, handle):
    values = [ctypes.c_uint64() for _ in range(4)]
    if not kernel.GetProcessTimes(int(handle), *(ctypes.byref(v) for v in values)):
        raise OSError(ctypes.get_last_error(), "Cannot identify owned process")
    return values[0].value


def main():
    record_path, parent_pid = Path(sys.argv[1]), int(sys.argv[2])
    kernel = api()
    parent = kernel.OpenProcess(0x100000, False, parent_pid)
    children = {}
    record = {}
    def refresh():
        nonlocal record
        try:
            record = json.loads(record_path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return
        for role in record.get("roles", []):
            pid, created = role.get("pid"), role.get("creation_time")
            if not pid or not created or pid in children:
                continue
            handle = kernel.OpenProcess(0x100001 | 0x1000, False, pid)
            if handle:
                if creation_time(kernel, handle) == created:
                    children[pid] = handle
                else:
                    kernel.CloseHandle(handle)
    try:
        while parent and kernel.WaitForSingleObject(parent, 250) == 258:
            refresh()
        refresh()
        if record.get("cleanup_complete"):
            return
        errors = []
        for handle in children.values():
            if kernel.WaitForSingleObject(handle, 0) == 258:
                kernel.TerminateProcess(handle, 1)
                if kernel.WaitForSingleObject(handle, 5000) != 0:
                    errors.append("An owned game process did not exit")
        deployments = [record[key] for key in ("native_deployment", "server_native_deployment") if record.get(key)]
        if deployments and not errors:
            kernel.CreateMutexW.restype = ctypes.c_void_p
            kernel.CreateMutexW.argtypes = (ctypes.c_void_p, ctypes.c_int, ctypes.c_wchar_p)
            kernel.ReleaseMutex.argtypes = (ctypes.c_void_p,)
            mutex = kernel.CreateMutexW(None, False, "Local\\KF2VR_DevelopmentFixture")
            locked = bool(mutex) and kernel.WaitForSingleObject(mutex, 0) in (0, 0x80)
            try:
                if not locked:
                    errors.append("Another fixture is active; native recovery deferred")
                else:
                    for deployment in deployments:
                        deploy = NativeDeployment(Path(deployment["source"]), Path(deployment["destination"]),
                            Path(deployment["backup"]), deployment["receipt"], digest, server=deployment.get("server", False))
                        deploy.installed = list(deploy.files)
                        errors += deploy.restore()
            finally:
                if locked:
                    kernel.ReleaseMutex(mutex)
                if mutex:
                    kernel.CloseHandle(mutex)
        if record.get("vr"):
            try:
                from vr_config import export_preferences
                driver = next(r for r in record.get("roles", []) if r["role"] == "driver")
                if driver.get("pid"):
                    export_preferences(Path(driver["config_root"]), network=record.get("session_mode") != "solo")
                    record["preferences_saved"] = True
            except (OSError, ValueError, StopIteration) as error:
                errors.append("Could not save VR preferences: " + str(error))
        elif record.get("vr") is False and record.get("user_config_root"):
            try:
                from desktop_settings import export
                driver = next(r for r in record.get("roles", []) if r["role"] == "driver")
                if driver.get("pid"):
                    export(Path(driver["config_root"]), Path(record["user_config_root"]))
                    record["preferences_saved"] = True
            except (OSError, ValueError, StopIteration) as error:
                errors.append("Could not save desktop settings: " + str(error))
        record.update(status="launcher_closed_cleanup", cleanup_complete=not errors, cleanup_errors=errors)
        from friends import save_session_record
        save_session_record(record_path, record)
    finally:
        for handle in children.values():
            kernel.CloseHandle(handle)
        if parent:
            kernel.CloseHandle(parent)


if __name__ == "__main__":
    main()
