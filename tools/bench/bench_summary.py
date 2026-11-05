"""Summarise a KF2VRBench run (#148 FPS A/B) from a launcher session folder.

usage: python bench_summary.py <session dir> [<session dir> ...]

Selects the native.log 5 s windows inside the mutator's measured window
(KF2VRBENCH measure-begin .. measure-end in game.log, aligned on each log's
first line) and reports presents/s, frame pacing, game-thread CPU and the
sampled GPU stereo span.
"""
import datetime
import re
import statistics
import sys
from pathlib import Path

GAME_TIME = re.compile(r"^\[(\d+\.\d+)\]")
TICK = re.compile(r"^tick_ms=(\d+) thread=\d+ (\w+) (.*)$")
CLOSED = re.compile(r"Log file closed, (\d+/\d+/\d+ \d+:\d+:\d+)")
FIELD = re.compile(r"(\w+)=([-\d.]+)")


def fields(text):
    return {k: float(v) for k, v in FIELD.findall(text)}


def summarise(session: Path) -> dict:
    driver = session / "driver"
    game = (driver / "game.log").read_text(errors="replace").splitlines()
    begin = end = first = None
    samples = []
    for line in game:
        t = GAME_TIME.match(line)
        closed = CLOSED.search(line)
        if t and closed:
            # Wall clock of game time 0, from the closing line's stamp.
            first = datetime.datetime.strptime(closed.group(1), "%m/%d/%y %H:%M:%S").timestamp() - float(t.group(1))
        if not t or "KF2VRBENCH" not in line:
            continue
        if "phase=measure-begin" in line:
            begin = float(t.group(1))
        elif "phase=measure-end" in line:
            end = float(t.group(1))
        elif "phase=sample" in line and begin is not None:
            samples.append(fields(line[line.index("phase=sample"):]))
    if begin is None or end is None:
        return {"session": str(session), "error": f"measure window missing (begin={begin} end={end})"}
    if first is None:
        return {"session": str(session), "error": "game.log has no closing wall-clock line"}
    native = driver / "native.log"
    lines = native.read_text(errors="replace").splitlines()
    last_tick = max(int(m.group(1)) for m in map(TICK.match, lines) if m)
    native_end = native.stat().st_mtime
    windows, gpu, pacing, cpu = [], [], [], []
    for line in lines:
        m = TICK.match(line)
        if not m:
            continue
        tick = int(m.group(1))
        # Both logs on game time: native ticks via native.log's last write.
        rel = native_end - (last_tick - tick) / 1000.0 - first
        kind, rest = m.group(2), m.group(3)
        if kind == "GpuTiming" and "stereoSpanMs" in rest:
            if begin <= rel <= end:
                gpu.append(fields(rest)["stereoSpanMs"])
            continue
        # A 5 s window counts when it lies wholly inside the measured span.
        if not (begin + 5.0 <= rel <= end):
            continue
        if kind == "FrameTiming":
            windows.append(fields(rest))
        elif kind == "FramePacing":
            pacing.append(fields(rest))
        elif kind == "ThreadCpu":
            cpu.append(fields(rest))
    if not windows:
        return {"session": str(session), "error": "no FrameTiming windows in the measured span"}
    fps = [w["presents"] / (w["elapsedMs"] / 1000.0) for w in windows]
    per_frame = lambda key: statistics.mean(w[key] / max(w["presents"], 1) for w in windows if key in w)
    out = {
        "session": str(session),
        "measured_s": round(end - begin, 1),
        "windows": len(windows),
        "fps_mean": round(statistics.mean(fps), 1),
        "fps_min_window": round(min(fps), 1),
        "frame_ms_p50": round(statistics.mean(p["p50Ms"] for p in pacing), 2) if pacing else None,
        "frame_ms_p95": round(statistics.mean(p["p95Ms"] for p in pacing), 2) if pacing else None,
        "frame_ms_p99": round(statistics.mean(p["p99Ms"] for p in pacing), 2) if pacing else None,
        "menu_windows": sum(1 for p in pacing if p.get("lastMenu") == 1),
        "over_120hz_frames_pct": round(100 * sum(p["over120"] for p in pacing) / max(sum(p["intervals"] for p in pacing), 1), 1) if pacing else None,
        "gpu_stereo_ms_mean": round(statistics.mean(gpu), 2) if gpu else None,
        "gpu_stereo_ms_p95": round(sorted(gpu)[int(0.95 * (len(gpu) - 1))], 2) if gpu else None,
        "gpu_samples": len(gpu),
        "game_thread_cpu_ms_per_frame": round(statistics.mean(c["presentThreadCpuMs"] / max(w["presents"], 1) for c, w in zip(cpu, windows)), 2) if cpu else None,
        "zeds_alive_mean": round(statistics.mean(s.get("alive", 0) for s in samples), 1) if samples else None,
        "monsters_mean": round(statistics.mean(s.get("monsters", 0) for s in samples), 1) if samples else None,
    }
    for key in ("controllerMs", "simulationMs", "leftMs", "rightMs", "worldMs", "xrBeginMs", "xrSubmitMs", "otherMs", "presentMs"):
        if any(key in w for w in windows):
            out["per_frame_" + key] = round(per_frame(key), 3)
    return out


if __name__ == "__main__":
    for arg in sys.argv[1:]:
        result = summarise(Path(arg))
        print("\n".join(f"{k}: {v}" for k, v in result.items()))
        print()
