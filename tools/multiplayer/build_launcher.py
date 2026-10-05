"""Assemble the portable launcher for source auditing, without game/build inputs."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import shutil

from dependencies import extract_verified
from package import ROOT, START_FILE, START_SCRIPT, add_tkinter, check_portable_launchers, copy_launcher_tools
from release_state import digest


README = """KF2-VR launcher source audit build

This folder contains the launcher and its pinned Python/Tk runtime, without
native mod DLLs, compiled game packages or a playable release manifest.
It is for reviewing and modifying the launcher. To play, download the complete
playable ZIP from https://github.com/Kvasir94/Killing-Floor-2-VR/releases.
Do not copy this build over a playable release or bypass package checks.

Start KF2-VR.cmd opens the launcher UI. For the offline packaging self-check:
app\\runtime\\python.exe app\\tools\\multiplayer\\launcher_gui.py --self-check
No game, server or Workshop download is started by the build/self-check.
The build can download only the pinned official Python and Tcl/Tk archives.
See app/tools/dependency-pins.json and app/launcher-build.json for input hashes.
No local profiles, logs, caches or author identity are bundled.
"""


def build_launcher(output: Path):
    output = Path(output).resolve()
    if output == ROOT or output in ROOT.parents or output.exists():
        raise ValueError("Use a new output folder; existing files are never replaced.")
    app = output / "app"
    app.mkdir(parents=True)
    copy_launcher_tools(ROOT, app)
    shutil.copy2(ROOT / "LICENSE", app / "LICENSE")
    runtime = app / "runtime"
    archive_name = "python-3.14.3-embed-amd64.zip"
    extract_verified(archive_name, ROOT / "build/multiplayer" / archive_name, runtime)
    (runtime / "python314._pth").write_text("python314.zip\n.\n../tools/multiplayer\n", encoding="ascii")
    add_tkinter(runtime)
    (output / START_FILE).write_bytes(START_SCRIPT.encode("ascii"))
    (output / "READ ME FIRST.txt").write_text(README, encoding="utf-8")
    (app / "THIRD-PARTY-NOTICES.txt").write_text(
        "CPython 3.14.3 and Tcl/Tk 8.6.15 are from the official Python Software "
        "Foundation distribution. Retain runtime/LICENSE.txt and the Tcl/Tk "
        "license.terms files. Microsoft runtime components retain their terms.\n"
        "SteamCMD is not bundled; explicit hosting can download it from Valve "
        "using the pin in tools/dependency-pins.json.\n", encoding="utf-8")
    check_portable_launchers(app, runtime / "python.exe")
    # Relative filenames and content hashes only; no machine paths or Git identity.
    hashes = {path.relative_to(output).as_posix(): digest(path)
              for path in sorted(output.rglob("*")) if path.is_file()}
    (app / "launcher-build.json").write_text(json.dumps({
        "schema": "kf2vr/launcher-audit-build/1", "playable": False,
        "files_sha256": hashes,
    }, indent=2) + "\n", encoding="utf-8")
    return output


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="New audit-build folder (never overwritten)")
    args = parser.parse_args(argv)
    output = build_launcher(args.output)
    print("Launcher audit build ready:", output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
