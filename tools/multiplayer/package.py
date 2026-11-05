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
import stable_features
import game_install

from native_fixture import verify_native
from session import ROOT, digest, source_hashes
from release_state import workspace_sources, verify_release
from dependencies import extract_verified, verified_archive, PINS


# Only modules a player path loads: the import closure of launcher_gui, friends
# and the Epic entry points, plus workshop_distribution for the Workshop item's
# play.py and setup. The network diagnostic (session.py), its evidence
# verifiers, motion recording, highlight logging, sharing replay and local test
# control stay in the checkout; friends.py loads those only when asked.
LAUNCHER_MODULES = (
    "stable_features.py", "settings_registry.py", "machine_settings.py", "launcher_events.py", "friends.py", "launch_support.py", "native_fixture.py",
    "watchdog.py", "vr_config.py", "vr_graphics.py", "desktop_settings.py", "workshop_map.py", "workshop_loadout.py", "workshop_distribution.py",
    "release_state.py", "launch_menu.py", "range_map.py", "installed_map_catalog.py", "launcher_gui.py", "launcher_app.py", "launcher_ui_theme.py", "launcher_ui_widgets.py", "launcher_ui_pages.py", "launcher_ui_settings.py", "launcher_art.py", "launcher_settings.py", "settings_graphics.py", "launcher_updates.py", "launcher_compat.py",
    "recovery.py", "diagnostics.py", "dependencies.py", "join_code.py",
    "game_install.py", "epic_manual.py", "epic_launch.py", "epic_launch_options.py",
    "epic_broker.py", "epic_session.py", "epic_recovery.py",
)
# Release line the public GitHub tags use (v<RELEASE_VERSION>.<UTC date>); the
# launcher's update notice compares release.json's version against those tags,
# so bump this with every new public release line.
RELEASE_VERSION = "0.3.0-alpha"
# The ZIP's only top-level entries; everything else lives in app/.
START_FILE = "Start KF2-VR.cmd"
START_SCRIPT = ('@echo off\r\nstart "" "%~dp0app\\runtime\\pythonw.exe" '
                '"%~dp0app\\tools\\multiplayer\\launcher_gui.py"\r\n')
README_FILE = "READ ME FIRST.txt"


def player_document_root(root, *, public=False):
    """Use reviewed public overlays in private checkouts; exports are already clean."""
    root = Path(root)
    overlay = root / "docs/public-source"
    return overlay if public and overlay.is_dir() else root


def release_audience(public):
    return "public-alpha" if public else "private-alpha"


# Qt for Python (LGPL-3.0) for the launcher window. The wheels are pinned in
# tools/dependency-pins.json (URL + SHA-256, verified on every use); only the
# parts the launcher loads are copied, so WebEngine, Qml, Quick, translations,
# designer, examples and headers stay out of the package.
QT_WHEELS = ("pyside6_essentials-6.12.0-cp310-abi3-win_amd64.whl", "shiboken6-6.12.0-cp310-abi3-win_amd64.whl")
QT_MODULES = ("QtCore", "QtGui", "QtWidgets")
# vcruntime140.dll comes with the embedded Python; the rest are the MSVC pieces Qt needs.
QT_RUNTIME_DLLS = ("msvcp140.dll", "msvcp140_1.dll", "msvcp140_2.dll", "vcruntime140_1.dll")
# No styles plugin (the launcher forces Fusion) and no QtSvg.
QT_PLUGINS = ("platforms/qwindows.dll", "platforms/qoffscreen.dll", "imageformats/qjpeg.dll")
QT_NOTICE = """Qt for Python (PySide6) and Qt 6.12

The launcher window uses Qt 6.12 through PySide6 6.12.0 and shiboken6 6.12.0,
unmodified, from the official PyPI wheels (pinned in tools/dependency-pins.json).
Qt and Qt for Python are licensed under the GNU Lesser General Public License
version 3 (LGPL-3.0-only; Qt is also available under the GPL and a commercial
licence). The full texts are LGPL-3.0.txt and GPL-3.0.txt in this folder.

Qt is used as separate, replaceable dynamic libraries: the Qt6*.dll files,
the *.pyd bindings and plugins/ under runtime/PySide6, and shiboken6 under
runtime/shiboken6. You may replace them with your own build of Qt/PySide6
of the same version. KF2-VR itself is not derived from Qt and does not link
Qt statically.

Source code for Qt and Qt for Python is available from
https://code.qt.io/ and https://download.qt.io/official_releases/ (the
PySide6 source tree is at https://code.qt.io/cgit/pyside/pyside-setup.git/).
Qt bundles other third-party components (libpng, FreeType, HarfBuzz, PCRE2,
zlib and others) under their own licences; see
https://doc.qt.io/qt-6/licenses-used-in-qt.html.
"""


def qt_wanted(name):
    """Whether a wheel member belongs to the launcher's Qt payload."""
    wanted = {"PySide6/__init__.py", "PySide6/_config.py", "PySide6/_git_pyside_version.py", "PySide6/pyside6.abi3.dll",
              "PySide6/Qt6Core.dll", "PySide6/Qt6Gui.dll", "PySide6/Qt6Widgets.dll",
              "shiboken6/__init__.py", "shiboken6/_config.py", "shiboken6/_git_shiboken_module_version.py",
              "shiboken6/Shiboken.pyd", "shiboken6/shiboken6.abi3.dll"}
    wanted.update(f"PySide6/{module}.pyd" for module in QT_MODULES)
    wanted.update(f"PySide6/{dll}" for dll in QT_RUNTIME_DLLS)
    wanted.update(f"PySide6/plugins/{plugin}" for plugin in QT_PLUGINS)
    return name in wanted


def add_qt(runtime):
    """Unpack only the launcher's Qt payload into the embedded runtime (its path starts at the runtime folder)."""
    runtime = Path(runtime).resolve()
    for wheel in QT_WHEELS:
        path = verified_archive(wheel, ROOT / "build/multiplayer/qt-wheels" / wheel)
        with zipfile.ZipFile(path) as archive:
            names = [item for item in archive.infolist() if qt_wanted(item.filename)]
            for item in names:
                if not (runtime / item.filename).resolve().is_relative_to(runtime):
                    raise RuntimeError("Qt wheel contains a path outside extraction root")
            for item in names:
                archive.extract(item, runtime)
    present = {item.relative_to(runtime).as_posix() for item in runtime.rglob("*") if item.is_file()}
    missing = [name for name in ("PySide6/QtWidgets.pyd", "PySide6/Qt6Widgets.dll", "PySide6/plugins/platforms/qwindows.dll",
                                 "shiboken6/Shiboken.pyd") if name not in present]
    if missing:
        raise RuntimeError("Qt payload incomplete: " + ", ".join(missing))


def add_qt_notices(notices):
    """Licence texts and the Qt for Python notice, next to the other third-party licences."""
    notices = Path(notices)
    notices.mkdir(parents=True, exist_ok=True)
    for name in ("LGPL-3.0.txt", "GPL-3.0.txt"):
        shutil.copy2(ROOT / "third_party" / name, notices / name)
    (notices / "Qt-for-Python-NOTICE.txt").write_text(QT_NOTICE, encoding="utf-8")


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
    shutil.copy2(source_root / "tools/multiplayer/linux-desktop.sh", destination)
    (destination / "assets").mkdir(exist_ok=True)
    shutil.copy2(source_root / "tools/multiplayer/assets/kf2vr-icon.png", destination / "assets")
    shutil.copy2(source_root / "tools/multiplayer/epic_desktop_install.ps1", destination)
    epic = output / "tools/epic-pack"
    epic.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source_root / "tools/epic-pack/Install KF2VR for Epic.bat", epic)
    for name in ("install-multiplayer-server.ps1", "vr-defaults.json", "settings-definition.json", "dependency-pins.json"):
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


def copy_range_map(root, output, frozen=None):
    root, output = Path(root), Path(output)
    source = (Path(frozen) / "Packages" if frozen else root / "build/range") / "KF-VRRange.kfm"
    if not source.is_file():
        raise RuntimeError("Build KF-VRRange.kfm with tools/build-vr-range.ps1 before packaging.")
    if not frozen:
        record = json.loads((source.parent / "build.json").read_text(encoding="utf-8-sig"))
        expected = record.get("inputs_sha256", {})
        if (record.get("success") is not True or not expected
                or record.get("package_sha256") != digest(source)
                or any(not (root / name).is_file() or digest(root / name) != value
                       for name, value in expected.items())):
            raise RuntimeError("Range map inputs changed; rebuild with tools/build-vr-range.ps1.")
    shutil.copy2(source, output / "Packages" / source.name)


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


def portable_receipt(receipt):
    """Keep validated capability/dependency metadata while removing local paths."""
    return {key: value for key, value in receipt.items()
            if key.endswith("sha256") or key in ("success", "includes_vr_client", "schema",
                "started_utc", "finished_utc", "dlss_enabled", "ngx_sdk")}


def write_desktop_companions(output, full_zip, manifest):
    """Ship matching desktop paths and range without copying donor game binaries."""
    output, full_zip = Path(output), Path(full_zip)
    linux_zip = Path(str(output) + "-LinuxKit.zip")
    with zipfile.ZipFile(linux_zip, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.write(full_zip, full_zip.name)
        archive.write(output / "docs/LINUX-DESKTOP.md", "LINUX-DESKTOP.md")
        archive.write(output / "tools/multiplayer/linux-desktop.sh", "linux-desktop.sh")
    epic_zip = Path(str(output) + "-Epic-Desktop-Pack.zip")
    names = ("KF2VR.u", "KF2VRNet.u", "KF2VRHands.upk", "KF-VRRange.kfm")
    companion = {"schema": "kf2vr/desktop-companion/1", "build_id": manifest["build_id"],
                 "git_head": manifest["git_head"], "protocol_version": manifest["protocol_version"],
                 "package_revision": manifest["package_revision"],
                 "supported_epic_sha256": game_install.EPIC_SHA256,
                 "release": output.name, "release_manifest_sha256": digest(output / "release.json"),
                 "files_sha256": {"KF2VR/" + name: digest(output / "Packages" / name) for name in names}}
    companion["files_sha256"]["EPIC-DESKTOP.md"] = digest(output / "docs/EPIC-DESKTOP.md")
    installers = {"epic_desktop_install.ps1": output / "tools/multiplayer/epic_desktop_install.ps1",
                  "Install KF2VR for Epic.bat": output / "tools/epic-pack/Install KF2VR for Epic.bat"}
    companion["files_sha256"].update({name: digest(path) for name, path in installers.items()})
    with zipfile.ZipFile(epic_zip, "w", zipfile.ZIP_DEFLATED) as archive:
        for name in names:
            archive.write(output / "Packages" / name, "KF2VR/" + name)
        archive.write(output / "docs/EPIC-DESKTOP.md", "EPIC-DESKTOP.md")
        for name, path in installers.items():
            archive.write(path, name)
        archive.writestr("companion.json", json.dumps(companion, indent=2))
    return linux_zip, epic_zip


# The shipped script/asset set.
CORE_PACKAGES = frozenset({"KF2VR.u", "KF2VRNet.u", "KF2VRNetClient.u", "KF2VRHands.upk"})


def valid_script_inventory(packages):
    names = set(packages)
    return names == CORE_PACKAGES


def validate_native_inventory(root, native):
    if native.get("dlss_enabled") is not True:
        raise RuntimeError("Playable packages require DLSS support; rebuild with tools/build-kf2vr.ps1")
    if set(native["artifacts_sha256"]) != {"dinput8.dll", "openxr_loader.dll", "nvngx_dlss.dll"} or set(native["server_artifacts_sha256"]) != {"dinput8.dll"}:
        raise RuntimeError("Unexpected native distribution contents")
    if native.get("dlss_enabled"):
        pins = json.loads((Path(root) / "tools/ngx-pins.json").read_text(encoding="utf-8"))
        if native.get("ngx_sdk") != pins or native["artifacts_sha256"]["nvngx_dlss.dll"] != pins["files_sha256"]["lib/Windows_x86_64/rel/nvngx_dlss.dll"]:
            raise RuntimeError("NGX runtime or dependency receipt differs from official pin")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--public-release", action="store_true", help="Require clean source tree and matching successful build receipts")
    parser.add_argument("--no-select", action="store_true", help="Build a private candidate without changing the launcher selection")
    parser.add_argument("--breacher", action="store_true", help="Include the separately compiled optional Breacher package; gameplay remains OFF by default")
    parser.add_argument("--reuse-release", type=Path, help="Reuse verified compiled inputs from an unchanged frozen release for a packaging-only refresh")
    args = parser.parse_args(argv)
    if args.breacher and not stable_features.experimental_content_enabled():
        parser.error("Breacher is parked in this stable candidate")
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
    if not valid_script_inventory(receipt["packages_sha256"]):
        raise RuntimeError("Unexpected script/asset distribution contents")
    validate_native_inventory(ROOT, native)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    output = ROOT / "build/multiplayer/releases" / f"KF2VR-Multiplayer-{stamp}"
    output.mkdir(parents=True)
    for name in receipt["packages_sha256"]:
        destination = output / "Packages" / name
        destination.parent.mkdir(exist_ok=True)
        shutil.copy2(scripts / name, destination)
    copy_range_map(ROOT, output, frozen)
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
    add_qt(runtime)
    # Players see only the start file and READ ME FIRST (added to the ZIP);
    # Only player guides ship; source/developer references remain in the checkout.
    documents = player_document_root(ROOT, public=args.public_release)
    readme = documents / "docs/public-alpha/READ-ME-FIRST.txt"
    (output / "docs").mkdir(exist_ok=True)
    shutil.copy2(readme, output / "docs")
    shutil.copy2(documents / "docs/public-alpha/RELEASE-NOTES-DRAFT.md", output / "docs")
    shutil.copy2(documents / "docs/PLAYER-GUIDE.md", output / "docs")
    controls = (documents / "docs/VR_CONTROLS.md").read_text(encoding="utf-8")
    # Preserve the full controls guide, but do not ship broken links to
    # developer references which are deliberately absent from a player ZIP.
    player_controls = re.sub(r"\[([^]\n]+)\]\((?!#)[^)]+\)", r"\1", controls)
    (output / "docs/VR_CONTROLS.md").write_text(player_controls, encoding="utf-8")
    if args.breacher:
        shutil.copy2(documents / "docs/public-alpha/BREACHER.md", output / "docs")
    shutil.copy2(documents / "docs/public-alpha/FEEDBACK-QUESTIONS.md", output / "docs")
    shutil.copy2(documents / "docs/public-alpha/CONTROLS-CARD.txt", output / "docs")
    for name in ("LINUX-DESKTOP.md", "EPIC-DESKTOP.md"):
        shutil.copy2(ROOT / "docs" / name, output / "docs" / name)
    notices = output / "notices"
    notices.mkdir()
    if native.get("dlss_enabled"):
        for name in ("NVIDIA-DLSS-LICENSE.txt", "AMD-CAS-LICENSE.txt"):
            shutil.copy2(ROOT / "third_party" / name, notices / name)
        shutil.copy2(ROOT / "docs/DLSS.md", output / "docs/DLSS.md")
    shutil.copy2(ROOT / "third_party/openxr-sdk/LICENSE", notices / "OpenXR-LICENSE.txt")
    shutil.copy2(ROOT / "third_party/minhook/LICENSE.txt", notices / "MinHook-LICENSE.txt")
    shutil.copy2(ROOT / "third_party/KF2-Ranked-Patch-LICENSE.txt", notices / "KF2-Ranked-Patch-LICENSE.txt")
    shutil.copytree(ROOT / "third_party/openxr-sdk/LICENSES", notices / "OpenXR-LICENSES")
    add_qt_notices(notices)
    shutil.copy2(documents / "docs/public-alpha/THIRD-PARTY-NOTICES.txt", notices)
    shutil.copy2(documents / "LICENSE", notices / "KF2VR-LICENSE.txt")
    if frozen:
        copy_frozen_runtime_extras(frozen, output)
    install = json.loads((ROOT / "docs/intake/install_manifest.json").read_text(encoding="utf-8-sig"))
    net_types = (ROOT / "script/KF2VRNet/Classes/KF2VRNetTypes.uc").read_text()
    protocol = int(re.search(r"const ProtocolVersion = (\d+);", net_types)[1])
    revision = int(re.search(r"const PackageRevision = (\d+);", net_types)[1])
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    build_id = f"{RELEASE_VERSION}-{stamp}-{commit[:12]}-p{protocol}" + ("-dev" if status or not args.public_release else "")
    # Receipts remain traceable through source/artifact hashes; local log and SDK
    # paths do not belong in a distributable manifest.
    manifest = {"build_id": build_id, "version": f"{RELEASE_VERSION}.{stamp[:8]}", "protocol_version": protocol, "package_revision": revision,
        "breacher_protocol": 1,
        "player_launcher_protocol": 1,
        "store_launcher_protocol": 1,
        "supported_game_sha256": [game_install.STEAM_SHA256, game_install.EPIC_SHA256],
        "store_support": {"steam": "solo-host-join", "epic": "experimental-solo-menu-first-unaccepted"},
        "public_release": args.public_release, "audience": release_audience(args.public_release), "schema": "kf2vr/friend-release/1", "created_utc": datetime.now(timezone.utc).isoformat(),
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
    companions = write_desktop_companions(output, Path(str(output) + ".zip"), manifest)
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
    for companion in companions:
        print(companion, flush=True)


if __name__ == "__main__":
    main()
