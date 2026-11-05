"""Read-only startup diagnosis. Activity is evidence, never a readiness gate."""
import ctypes
import os
import re

from ammo_timing import readiness_seen, startup_milestones


def startup_state(log, case):
    milestones = startup_milestones(log)
    steam_rows = re.findall(r'Steam Client API initialized ([01])(?:\s|$)', log)
    steam = bool(int(steam_rows[-1])) if steam_rows else None
    required = 'STEAM is required to play the game.' in log
    ready = readiness_seen(log, case)
    if ready:
        phase = 'observer-ready'
    elif required and steam is False:
        phase = 'steam-client-unavailable'
    elif 'engine_playable' in milestones:
        phase = 'observer-setup'
    elif 'world_loaded' in milestones:
        phase = 'world-loaded'
    elif 'Initializing Engine Completed' in log:
        phase = 'engine-initialized'
    elif steam:
        phase = 'engine-startup'
    else:
        phase = 'pre-steam-startup'
    return dict(phase=phase, ready=ready, steam_client_initialized=steam,
                steam_required_error=required, milestones_log_seconds=milestones)


def process_counters(handle):
    """Query only the runner's owned process handle; unavailable stays unknown."""
    if os.name != 'nt' or handle is None:
        return None
    from ctypes import wintypes

    class IOCounters(ctypes.Structure):
        _fields_ = [(name, ctypes.c_ulonglong) for name in
                    ('read_ops', 'write_ops', 'other_ops', 'read_bytes', 'write_bytes', 'other_bytes')]

    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.GetProcessIoCounters.argtypes = (wintypes.HANDLE, ctypes.POINTER(IOCounters))
    kernel.GetProcessIoCounters.restype = wintypes.BOOL
    kernel.GetProcessTimes.argtypes = (wintypes.HANDLE,) + (ctypes.POINTER(wintypes.FILETIME),) * 4
    kernel.GetProcessTimes.restype = wintypes.BOOL
    io = IOCounters()
    times = [wintypes.FILETIME() for _ in range(4)]
    if not kernel.GetProcessIoCounters(int(handle), ctypes.byref(io)):
        return None
    if not kernel.GetProcessTimes(int(handle), *(ctypes.byref(t) for t in times)):
        return None
    value = lambda t: (t.dwHighDateTime << 32) | t.dwLowDateTime
    return dict(read_bytes=io.read_bytes, write_bytes=io.write_bytes,
                kernel_100ns=value(times[2]), user_100ns=value(times[3]))


class StartupProgress:
    def __init__(self, case):
        if case not in ('normal', 'dual'):
            raise ValueError('Unknown replay case')
        self.case = case
        self.last_sizes = (0, 0)
        self.last_log_change = None
        self.last_counters = None
        self.last_process_change = None

    def observe(self, elapsed, game_log, native_log='', counters=None):
        if elapsed < 0:
            raise ValueError('Elapsed time must be nonnegative')
        state = startup_state(game_log, self.case)
        sizes = (len(game_log), len(native_log))
        if self.last_sizes != sizes:
            self.last_sizes = sizes
            self.last_log_change = elapsed
        if counters is not None and counters != self.last_counters:
            changed = self.last_counters is not None or any(value > 0 for value in counters.values())
            self.last_counters = dict(counters)
            if changed:
                self.last_process_change = elapsed
        log_quiet = (max(0, elapsed - self.last_log_change)
                     if self.last_log_change is not None else None)
        process_quiet = (max(0, elapsed - self.last_process_change)
                         if counters is not None and self.last_process_change is not None else None)
        if state['ready']:
            diagnosis = 'ready'
        elif state['phase'] == 'steam-client-unavailable':
            diagnosis = 'explicit-steam-client-failure'
        elif log_quiet is not None and log_quiet < 30:
            diagnosis = 'not-ready-log-progress-observed'
        elif process_quiet is not None and process_quiet < 30:
            diagnosis = 'not-ready-process-activity-observed'
        elif self.last_log_change is None and self.last_process_change is None:
            diagnosis = 'not-ready-awaiting-first-observation'
        else:
            diagnosis = 'not-ready-no-recent-observed-progress'
        return dict(state, elapsed_seconds=round(elapsed, 2), diagnosis=diagnosis,
                    game_log_characters=sizes[0], native_log_characters=sizes[1],
                    log_quiet_seconds=round(log_quiet, 2) if log_quiet is not None else None,
                    process_quiet_seconds=round(process_quiet, 2) if process_quiet is not None else None,
                    process_counters=counters, hang_proven=False)
