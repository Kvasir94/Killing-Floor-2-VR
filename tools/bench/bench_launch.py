"""Run a KF2VR package's own Solo launcher with the KF2VRBench mutator added (#148 FPS A/B).

usage: <package>\\runtime\\python.exe bench_launch.py <package root> <shell name> <bench url options> -- <friends.py args...>

<bench url options> is appended to the map URL, e.g. "?BenchZeds=24?BenchWarmup=30?BenchMeasure=120".
The launch command's -ENGINEINI gets build/bench/Script added to the script paths, and
KF2VRBench.KF2VRBench joins the URL's single ?Mutator= list (or starts one). Nothing in the package changes.
"""
import os
import re
import subprocess
import sys
from pathlib import Path

BENCH_ROOT = Path(__file__).resolve().parents[2] / "build" / "bench"
BENCH_SCRIPT = BENCH_ROOT / "Script"
MUTATOR = "KF2VRBench.KF2VRBench"

root = Path(sys.argv[1]).resolve()
# The KF2VRBenchShell helper is compiled per build: build-bench.ps1 -ShellFor <Packages> -OutputRoot build/bench/shell-<name>.
SHELL = BENCH_ROOT / f"shell-{sys.argv[2]}" / "Load"
sys.argv.pop(2)
bench_options = sys.argv[2]
assert sys.argv[3] == "--"
if not (BENCH_SCRIPT / "KF2VRBench.u").is_file():
    sys.exit(f"missing {BENCH_SCRIPT / 'KF2VRBench.u'}; run tools/bench/build-bench.ps1")
if not (SHELL / "KF2VRBenchShell.u").is_file():
    sys.exit(f"missing {SHELL / 'KF2VRBenchShell.u'}; run tools/bench/build-bench.ps1 -ShellFor")
sys.path.insert(0, str(root / "tools" / "multiplayer"))
sys.argv = [str(root / "tools" / "multiplayer" / "friends.py")] + sys.argv[4:]

_Popen = subprocess.Popen


def patch_engine_ini(path: str) -> None:
    raw = Path(path).read_bytes()
    # The launcher writes these UTF-16 (with BOM); keep whatever encoding it used.
    encoding = "utf-16" if raw[:2] in (b"\xff\xfe", b"\xfe\xff") else "utf-8"
    text = raw.decode(encoding)
    if str(BENCH_SCRIPT) in text:
        return
    lines = "".join(f"{key}={folder}\r\n" for folder in (BENCH_SCRIPT, SHELL)
                    for key in ("Paths", "ScriptPaths", "SeekFreePCPaths", "BrewedPCPaths"))
    text, count = re.subn(r"(?m)^\[Core\.System\]\r?\n", lambda m: m.group(0) + lines, text, count=1)
    if not count:
        raise SystemExit(f"no [Core.System] in {path}")
    Path(path).write_bytes(text.encode(encoding))
    print("BENCH engine ini patched", path, flush=True)


def patch_system_settings(path: str, values: dict) -> None:
    raw = Path(path).read_bytes()
    encoding = "utf-16" if raw[:2] in (b"\xff\xfe", b"\xfe\xff") else "utf-8"
    text = raw.decode(encoding)
    head, sep, rest = text.partition("[SystemSettings]")
    body, nxt, tail = rest.partition("\n[")
    for key, value in values.items():
        body, count = re.subn(rf"(?m)^{re.escape(key)}=.*?(\r?)$", lambda m: f"{key}={value}{m.group(1)}", body)
        if not count:
            body = body.rstrip("\r\n") + f"\r\n{key}={value}\r\n"
    Path(path).write_bytes((head + sep + body + nxt + tail).encode(encoding))
    print("BENCH system settings", values, flush=True)


def patch_url(token: str) -> str:
    if MUTATOR in token:
        return token
    if "?Mutator=" in token:
        token = re.sub(r"\?Mutator=([^?\s]*)", lambda m: f"?Mutator={m.group(1)},{MUTATOR}", token, count=1)
    else:
        # Newer Solo launches load the VR stack through the viewport client, with no URL mutators.
        token += f"?Mutator={MUTATOR}"
    print("BENCH url patched", flush=True)
    return token + bench_options


class Popen(_Popen):
    def __init__(self, args, *a, **k):
        if isinstance(args, str) and "KFGame" in args and "?Game=" in args:
            ini = re.search(r'-ENGINEINI="?([^"]+?\.ini)"?(?=\s|$)', args)
            if ini:
                patch_engine_ini(ini.group(1))
                # Bisect settings: KF2VRBENCH_SYSSET="Key=Value,..." edits [SystemSettings].
                if os.environ.get("KF2VRBENCH_SYSSET"):
                    patch_system_settings(str(Path(ini.group(1)).with_name("KFSystemSettings.ini")),
                                          dict(kv.split("=", 1) for kv in os.environ["KF2VRBENCH_SYSSET"].split(",")))
            head, sep, rest = args.partition(" ")
            parts = rest.split(" ")
            parts = [patch_url(p) if "?Game=" in p else p for p in parts]
            # Bisect switches: KF2VRBENCH_DROP removes and KF2VRBENCH_ADD appends
            # space-separated game arguments, e.g. DROP=-kf2vr-single-pass.
            drop = set(os.environ.get("KF2VRBENCH_DROP", "").split())
            parts = [p for p in parts if p not in drop] + os.environ.get("KF2VRBENCH_ADD", "").split()
            if drop or os.environ.get("KF2VRBENCH_ADD"):
                print("BENCH args edited drop=", sorted(drop), "add=", os.environ.get("KF2VRBENCH_ADD", ""), flush=True)
            args = head + sep + " ".join(parts)
        super().__init__(args, *a, **k)


subprocess.Popen = Popen
import friends  # noqa: E402

friends.main()
