"""Exact release identity and source provenance for play and acceptance."""
import hashlib
import json
from pathlib import Path


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest().upper()


def workspace_sources(root):
    root = Path(root)
    paths = set()
    for folder in ("script/KF2VR", "script/KF2VRNet", "script/KF2VRNetClient", "script/KF2Breacher"):
        paths.update((root / folder).rglob("*.uc"))
    for folder in ("native/adapter", "native/vrcore", "native/xr", "native/portal"):
        paths.update(p for p in (root / folder).rglob("*") if p.is_file()
                     and (p.suffix in (".h", ".hpp", ".cpp", ".asm") or p.name == "CMakeLists.txt"))
    # Offline tests are not shipped or imported by play. Their edits must not
    # invalidate an otherwise matching playable package.
    paths.update(p for p in (root / "tools/multiplayer").glob("*.py")
                 if not p.name.startswith("test_"))
    paths.update(root / name for name in ("CMakeLists.txt", "third_party/xr-sdks.cmake", "Play-KF2VR.cmd", "Play-KF2VR-TestMap.cmd",
        "tools/play-main.ps1", "tools/play-gui.ps1", "tools/vr-defaults.json", "tools/vr-defaults.ps1", "tools/test-online-play.ps1",
        "tools/dependency-pins.json", "tools/install-multiplayer-server.ps1", "tools/build-kf2vr.ps1", "tools/build-multiplayer-native.ps1", "tools/build-multiplayer-scripts.ps1"))
    for name in ("tools/ngx-pins.json", "third_party/NVIDIA-DLSS-LICENSE.txt", "third_party/AMD-CAS-LICENSE.txt",
                 "script/KF2Breacher/Localization/INT/KF2Breacher.int",
                 "tools/test-emulated-motion.ps1", "tools/test-saved-network-motion.ps1",
                 "tools/create-motion-contact-sheet.ps1"):
        if (root / name).is_file():
            paths.add(root / name)
    return {p.relative_to(root).as_posix(): digest(p) for p in sorted(paths)}


def verify_release(path, expected_hash=None):
    path = Path(path).resolve()
    manifest_path = path / "release.json"
    if expected_hash and digest(manifest_path) != expected_hash:
        raise RuntimeError("Selected release manifest has changed")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8-sig"))
    for name, expected in manifest["files_sha256"].items():
        file = (path / name).resolve()
        if not file.is_relative_to(path) or digest(file) != expected:
            raise RuntimeError(f"Release file missing or changed: {name}")
    return manifest


def selected_release(root):
    base = Path(root) / "build/multiplayer"
    selection = json.loads((base / "current-release.json").read_text(encoding="utf-8-sig"))
    path = (base / "releases" / selection["release"]).resolve()
    if path.parent != (base / "releases").resolve():
        raise RuntimeError("Invalid selected release path")
    return path, verify_release(path, selection["manifest_sha256"])


def verify_workspace(root, manifest):
    built = manifest.get("workspace_sources_sha256", {})
    current = workspace_sources(root)
    changed = sorted(name for name in built.keys() | current.keys() if built.get(name) != current.get(name))
    if not built or changed:
        raise RuntimeError("Selected package differs from current source; run tools/build-kf2vr.ps1. "
                           + "Changed: " + ", ".join(changed[:12]))


def main(argv=None):
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--workspace", type=Path, required=True)
    parser.add_argument("--allow-stale", action="store_true",
                        help="Allow source differences; still verify all selected package files")
    parser.add_argument("--menu", action="store_true",
                        help="Offer to continue with a stale build or cancel")
    args = parser.parse_args(argv)
    path, manifest = selected_release(args.workspace)
    try:
        verify_workspace(args.workspace, manifest)
    except RuntimeError as error:
        if not args.allow_stale:
            if not args.menu:
                raise RuntimeError(str(error) + " Use -AllowStale to intentionally play the selected older build.") from error
            print(f"\n=== KF2-VR launcher: selected build is older than source ===\n{path.name}")
            print("Package integrity verified. Newer source edits are not included.")
            print("  1. Play this build anyway (allow stale), then choose game options")
            print("  Q / Enter. Quit")
            try:
                while True:
                    choice = input("Selection: ").strip().lower()
                    if choice == "1":
                        break
                    if choice in ("", "q"):
                        print("Launch cancelled.")
                        return 2
                    print("Choose 1 to continue, or Q to quit.")
            except (EOFError, KeyboardInterrupt):
                print("\nLaunch cancelled.")
                return 2
        print(f"WARNING: Launching stale package by request: {path.name}")
        print(str(error))
        print("Package integrity verified. Current source edits are not included in this playtest.")
        return
    print(f"Selected source and package match: {path.name}")


if __name__ == "__main__":
    raise SystemExit(main())
