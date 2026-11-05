"""Stage a fresh, manifest-only KF2VR Workshop payload; never upload it."""
import argparse
from pathlib import Path
import shutil
import sys

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path.insert(0, str(REPO / "tools/multiplayer"))
from workshop_distribution import verified_files


def stage(release, output, changenote):
    release, output = Path(release).resolve(), Path(output).resolve()
    app = release / "app" if (release / "app/release.json").is_file() else release
    if output.is_relative_to(app) or app.is_relative_to(output):
        raise ValueError("Staging output must be separate from the release")
    if any(c in changenote for c in '"\\\r\n'):
        raise ValueError("Change note cannot contain quotes, backslashes or newlines")
    manifest, files = verified_files(app)
    # A fresh directory avoids deleting an unrelated or previously pinned build.
    output.mkdir(parents=True, exist_ok=False)
    upload = output / "Upload"
    for name, source in files.items():
        if name.startswith("Packages/") and name.endswith((".u", ".upk")):
            folder = "Script" if name.endswith(".u") else "Packages"
            target = upload / "BrewedPC" / folder / name[len("Packages/"):]
        else:
            target = upload / "KF2VR/app" / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
    shutil.copyfile(app / "release.json", upload / "KF2VR/app/release.json")
    for source, target in ((HERE / "item/play.py", upload / "KF2VR/play.py"),
                           (HERE / "item/Play.cmd", upload / "Play.cmd"),
                           (HERE / "setup.py", upload / "setup.py"),
                           (HERE / "KF2VR-Setup.ps1", upload / "KF2VR-Setup.ps1")):
        shutil.copyfile(source, target)
    (upload / "Setup KF2VR.cmd").write_bytes(
        b'@echo off\r\npowershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0KF2VR-Setup.ps1"\r\n')
    readme = release / "READ ME FIRST.txt"
    if readme.is_file():
        shutil.copyfile(readme, upload / "KF2VR/READ ME FIRST.txt")
    shutil.copyfile(HERE / "item/preview.jpg", output / "preview.jpg")
    vdf = (HERE / "item/workshop_item.vdf").read_text(encoding="utf-8-sig")
    vdf = (vdf.replace("__CONTENT__", upload.as_posix())
           .replace("__PREVIEW__", (output / "preview.jpg").as_posix())
           .replace("__CHANGENOTE__", changenote))
    (output / "workshop_item.vdf").write_text(vdf, encoding="utf-8")
    # The split layout must reconstruct precisely the original app inventory.
    verified_files(upload / "KF2VR/app", item=upload)
    return manifest


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True, help="New staging folder; existing folders are preserved")
    parser.add_argument("--changenote", required=True)
    args = parser.parse_args(argv)
    manifest = stage(args.release, args.out, args.changenote)
    print(f"Staged {manifest['build_id']} in {args.out.resolve()}; no upload performed.")


if __name__ == "__main__":
    main()
