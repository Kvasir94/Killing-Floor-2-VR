"""Assemble a portable friend package from matching, successful local builds."""
from __future__ import annotations

from datetime import datetime, timezone
import argparse
import re
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import urllib.request
import zipfile
import breacher

from native_fixture import verify_native
from session import ROOT, digest, source_hashes
from release_state import workspace_sources, verify_release
from dependencies import extract_msi, extract_verified, PINS


LAUNCHER_MODULES = (
    "friends.py", "session.py", "saved_motion.py", "motion_timeline.py", "motion_fixture_evidence.py", "abort_fixture.py", "native_fixture.py", "evidence.py", "avatar_evidence.py",
    "watchdog.py", "vr_config.py", "desktop_settings.py", "workshop_map.py", "workshop_loadout.py",
    "release_state.py", "acceptance.py", "launch_menu.py", "launch_state.py", "launcher_gui.py",
    "recovery.py", "diagnostics.py", "dependencies.py", "join_code.py", "local_test_control.py", "breacher.py",
)
# The ZIP's only top-level entries; everything else lives in app/.
START_FILE = "Start KF2-VR.cmd"
START_SCRIPT = ('@echo off\r\nstart "" "%~dp0app\\runtime\\pythonw.exe" '
                '"%~dp0app\\tools\\multiplayer\\launcher_gui.py"\r\n')
README_FILE = "READ ME FIRST.txt"


def add_tkinter(runtime):
    """Copy tkinter and Tcl/Tk from the pinned official installer component."""
    archive = ROOT / "build/multiplayer/python-3.14.3-tcltk-amd64.msi"
    with tempfile.TemporaryDirectory(prefix="kf2vr-tcltk-") as temporary:
        source = extract_msi(archive.name, archive, Path(temporary) / "x")
        for name in ("_tkinter.pyd", "tcl86t.dll", "tk86t.dll", "zlib1.dll"):
            shutil.copy2(source / "DLLs" / name, runtime / name)
        shutil.copytree(source / "Lib/tkinter", runtime / "tkinter", ignore=shutil.ignore_patterns("test*", "__pycache__"))
        for name in ("tcl8.6", "tk8.6"):
            shutil.copytree(source / "tcl" / name, runtime / "tcl" / name, ignore=shutil.ignore_patterns("demos", "tzdata"))


def write_zip(output, readme):
    name = output.name
    with zipfile.ZipFile(str(output) + ".zip", "x", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr(f"{name}/{START_FILE}", START_SCRIPT)
        archive.write(readme, f"{name}/{README_FILE}")
        for path in sorted(output.rglob("*")):
            if path.is_file():
                archive.write(path, f"{name}/app/{path.relative_to(output).as_posix()}")


def copy_launcher_tools(source_root, output):
    destination = output / "tools/multiplayer"
    destination.mkdir(parents=True, exist_ok=True)
    for name in LAUNCHER_MODULES:
        shutil.copy2(source_root / "tools/multiplayer" / name, destination / name)
    for name in ("install-multiplayer-server.ps1", "vr-defaults.json", "dependency-pins.json"):
        shutil.copy2(source_root / "tools" / name, output / "tools" / name)


def check_portable_launchers(output, python):
    """Execute shipped entry points without the checkout or user profile on PATH."""
    with tempfile.TemporaryDirectory(prefix="kf2vr-package-") as temporary:
        environment = {key: value for key, value in os.environ.items()
                       if not key.upper().startswith(("PYTHON", "KF2VR_"))}
        environment["LOCALAPPDATA"] = temporary
        environment["PATH"] = os.environ.get("SystemRoot", "C:/Windows") + "/System32"
        for entry, arguments in (
                ("friends.py", ["--help"]),
                ("session.py", ["--help"]),
                ("local_test_control.py", ["--help"]),
                ("motion_timeline.py", ["--help"]),
                ("abort_fixture.py", ["--help"]),
                ("launcher_gui.py", ["--self-check"])):
            result = subprocess.run([str(python), "-B", str(output / "tools/multiplayer" / entry)] + arguments,
                                    cwd=temporary, env=environment, stdin=subprocess.DEVNULL, text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)
            if result.returncode:
                raise RuntimeError(f"Portable launcher failed: {entry}\n{result.stdout}")


def select_candidate(root, output, *, select=True):
    """Keep an explicitly unselected candidate from changing launcher state."""
    if not select:
        return
    selection = {"schema": "kf2vr/current-release/1", "release": output.name,
                 "manifest_sha256": digest(output / "release.json")}
    pointer = root / "build/multiplayer/current-release.json"
    temporary = pointer.with_suffix(".tmp")
    temporary.write_text(json.dumps(selection, indent=2), encoding="utf-8")
    temporary.replace(pointer)


def copy_breacher_package(root, output):
    """Only explicitly requested experimental packages enter a release."""
    root, output = Path(root), Path(output)
    built = root / "build/breacher"
    record = json.loads((built / "build.json").read_text(encoding="utf-8-sig"))
    sources = root / "script/KF2Breacher"
    current = {p.relative_to(sources).as_posix(): digest(p) for p in sorted(sources.rglob("*.uc"))}
    contract = breacher.validate_descriptor(json.loads((built / "manifest.json").read_text(encoding="utf-8-sig")))
    localization = sources / "Localization/INT/KF2Breacher.int"
    if (not current or record.get("success") is not True or current != record.get("sources_sha256")
            or digest(built / "KF2Breacher.u") != contract["sha256"]
            or record.get("package_sha256") != contract["sha256"]
            or not localization.is_file()
            or record.get("localization_sha256") != digest(localization)
            or digest(built / "Localization/INT/KF2Breacher.int") != digest(localization)):
        raise RuntimeError("Compile current Breacher sources before packaging the optional mod.")
    destination = output / "optional/breacher"
    destination.mkdir(parents=True)
    for name in ("KF2Breacher.u", "manifest.json"):
        shutil.copy2(built / name, destination / name)
    shutil.copytree(built / "Localization", destination / "Localization")


def frozen_inputs(root, release):
    """Reuse an immutable payload only when every playable input still matches."""
    root, release = Path(root), Path(release)
    manifest = verify_release(release)
    current = workspace_sources(root)
    previous = manifest.get("workspace_sources_sha256", {})
    # Packaging itself is not imported by players. All gameplay, launch and
    # dependency inputs must match, including additions and removals.
    changed = sorted(name for name in current.keys() | previous.keys()
                     if name != "tools/multiplayer/package.py"
                     and current.get(name) != previous.get(name))
    if not previous or changed:
        raise RuntimeError("Frozen release sources differ: " + ", ".join(changed[:12]))
    native, scripts = manifest["native_build"], manifest["script_build"]
    if not native.get("success") or not scripts.get("success") or not scripts.get("includes_vr_client"):
        raise RuntimeError("Frozen release requires successful native and VR script receipts")
    for directory, hashes in (("Native", native["artifacts_sha256"]),
                              ("ServerNative", native["server_artifacts_sha256"]),
                              ("Packages", scripts["packages_sha256"])):
        for name, expected in hashes.items():
            if digest(release / directory / name) != expected:
                raise RuntimeError(f"Frozen build receipt mismatch: {directory}/{name}")
    return native, scripts


def copy_frozen_runtime_extras(release, output):
    """Keep declared runtime dependencies omitted by a newer package inventory."""
    release, output = Path(release), Path(output)
    for name in verify_release(release)["files_sha256"]:
        if name.startswith(("docs/", "notices/")):
            continue
        destination = output / name
        if not destination.exists():
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(release / name, destination)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--public-release", action="store_true", help="Require clean source tree and matching successful build receipts")
    parser.add_argument("--no-select", action="store_true", help="Build a private candidate without changing the launcher selection")
    parser.add_argument("--breacher", action="store_true", help="Include the separately compiled optional Breacher package; gameplay remains OFF by default")
    parser.add_argument("--reuse-release", type=Path, help="Reuse verified compiled inputs from an unchanged frozen release for a packaging-only refresh")
    args = parser.parse_args(argv)
    status = subprocess.check_output(["git", "status", "--porcelain", "--untracked-files=all"], cwd=ROOT, text=True).splitlines()
    if args.public_release and status:
        raise RuntimeError("Public release requires a clean source tree. Preserve existing work; commit reviewed changes before packaging.")
    frozen = args.reuse_release.resolve() if args.reuse_release else None
    if frozen:
        native, receipt = frozen_inputs(ROOT, frozen)
        scripts, native_dir, server_native_dir = frozen / "Packages", frozen / "Native", frozen / "ServerNative"
    else:
        scripts = ROOT / "build/multiplayer/script"
        receipt = json.loads((scripts / "build.json").read_text(encoding="utf-8-sig"))
        if not receipt.get("success") or source_hashes() != receipt["sources_sha256"]:
            raise RuntimeError("Compile the current network scripts first")
        native = verify_native(ROOT, receipt, digest)
        native_dir = ROOT / "build/multiplayer/native/native/adapter/Release"
        server_native_dir = ROOT / "build/multiplayer/native/native/adapter/server/Release"
    allowed_packages = {"KF2VR.u", "KF2VRNet.u", "KF2VRNetClient.u", "KF2VRHands.upk", "KF2VRPortal.upk"}
    if set(receipt["packages_sha256"]) != allowed_packages:
        raise RuntimeError("Unexpected script/asset distribution contents")
    if set(native["artifacts_sha256"]) != {"dinput8.dll", "openxr_loader.dll"} or set(native["server_artifacts_sha256"]) != {"dinput8.dll"}:
        raise RuntimeError("Unexpected native distribution contents")
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    output = ROOT / "build/multiplayer/releases" / f"KF2VR-Multiplayer-{stamp}"
    output.mkdir(parents=True)
    for name in receipt["packages_sha256"]:
        destination = output / "Packages" / name
        destination.parent.mkdir(exist_ok=True)
        shutil.copy2(scripts / name, destination)
    for name in native["artifacts_sha256"]:
        destination = output / "Native" / name
        destination.parent.mkdir(exist_ok=True)
        shutil.copy2(native_dir / name, destination)
    for name in native["server_artifacts_sha256"]:
        destination = output / "ServerNative" / name
        destination.parent.mkdir(exist_ok=True)
        shutil.copy2(server_native_dir / name, destination)
    copy_launcher_tools(ROOT, output)
    if args.breacher:
        if frozen:
            shutil.copytree(frozen / "optional/breacher", output / "optional/breacher")
        else:
            copy_breacher_package(ROOT, output)
    # CPython's official embeddable distribution includes its license and stdlib.
    # It is private to this folder; no PATH/registry or machine install changes.
    archive = ROOT / "build/multiplayer/python-3.14.3-embed-amd64.zip"
    source = PINS[archive.name]["url"]
    runtime = output / "runtime"
    extract_verified(archive.name, archive, runtime)
    (runtime / "python314._pth").write_text("python314.zip\n.\n../tools/multiplayer\n", encoding="ascii")
    add_tkinter(runtime)
    # Players see only the start file and READ ME FIRST (added to the ZIP);
    # Only player guides ship; source/developer references remain in the checkout.
    readme = ROOT / "docs/public-alpha/READ-ME-FIRST.txt"
    (output / "docs").mkdir(exist_ok=True)
    shutil.copy2(readme, output / "docs")
    shutil.copy2(ROOT / "docs/public-alpha/RELEASE-NOTES-DRAFT.md", output / "docs")
    controls = (ROOT / "docs/VR_CONTROLS.md").read_text(encoding="utf-8")
    # Preserve the full controls guide, but do not ship broken links to
    # developer references which are deliberately absent from a player ZIP.
    player_controls = re.sub(r"\[([^]\n]+)\]\((?!#)[^)]+\)", r"\1", controls)
    (output / "docs/VR_CONTROLS.md").write_text(player_controls, encoding="utf-8")
    shutil.copy2(ROOT / "docs/public-alpha/BREACHER.md", output / "docs")
    shutil.copy2(ROOT / "docs/public-alpha/FEEDBACK-QUESTIONS.md", output / "docs")
    shutil.copy2(ROOT / "docs/public-alpha/CONTROLS-CARD.txt", output / "docs")
    notices = output / "notices"
    notices.mkdir()
    shutil.copy2(ROOT / "third_party/openxr-sdk/LICENSE", notices / "OpenXR-LICENSE.txt")
    shutil.copy2(ROOT / "third_party/minhook/LICENSE.txt", notices / "MinHook-LICENSE.txt")
    shutil.copytree(ROOT / "third_party/openxr-sdk/LICENSES", notices / "OpenXR-LICENSES")
    shutil.copy2(ROOT / "docs/public-alpha/THIRD-PARTY-NOTICES.txt", notices)
    if frozen:
        copy_frozen_runtime_extras(frozen, output)
    install = json.loads((ROOT / "docs/intake/install_manifest.json").read_text(encoding="utf-8-sig"))
    protocol = int(re.search(r"const ProtocolVersion = (\d+);", (ROOT / "script/KF2VRNet/Classes/KF2VRNetTypes.uc").read_text())[1])
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    build_id = f"0.1.0-alpha-{stamp}-{commit[:12]}-p{protocol}" + ("-dev" if status or not args.public_release else "")
    # Receipts remain traceable through source/artifact hashes; local log and SDK
    # paths do not belong in a distributable manifest.
    def portable_receipt(receipt):
        return {key: value for key, value in receipt.items() if key.endswith("sha256") or key in ("success", "includes_vr_client", "schema", "started_utc", "finished_utc")}
    manifest = {"build_id": build_id, "version": "0.1.0-alpha", "protocol_version": protocol,
        "breacher_protocol": 1,
        "public_release": args.public_release, "audience": "private-alpha", "schema": "kf2vr/friend-release/1", "created_utc": datetime.now(timezone.utc).isoformat(),
        "git_head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "git_status": subprocess.check_output(["git", "status", "--short"], cwd=ROOT, text=True).splitlines(),
        "workspace_sources_sha256": workspace_sources(ROOT),
        "game_sha256": install["binaries"]["game"]["sha256"].upper(), "native_build": portable_receipt(native),
        "script_build": portable_receipt(receipt), "runtime_source": source, "runtime_archive_sha256": digest(archive),
        "files_sha256": {p.relative_to(output).as_posix(): digest(p) for p in output.rglob("*") if p.is_file()}}
    if frozen:
        manifest["reused_compiled_release"] = {"release": frozen.name,
                                              "manifest_sha256": digest(frozen / "release.json")}
    (output / "release.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    write_zip(output, readme)
    with tempfile.TemporaryDirectory(prefix="kf2vr-extracted-") as temporary:
        with zipfile.ZipFile(str(output) + ".zip") as archive:
            archive.extractall(temporary)
        extracted = Path(temporary) / output.name
        if sorted(p.name for p in extracted.iterdir()) != sorted([START_FILE, README_FILE, "app"]):
            raise RuntimeError("Unexpected top-level ZIP contents")
        check_portable_launchers(extracted / "app", extracted / "app/runtime/python.exe")
    # One local selection for every development launcher. Publish only after
    # the immutable package and archive have both been assembled successfully.
    select_candidate(ROOT, output, select=not args.no_select)
    print(output, flush=True)
    print(str(output) + ".zip", flush=True)


if __name__ == "__main__":
    main()
