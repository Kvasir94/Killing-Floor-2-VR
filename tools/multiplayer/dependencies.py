"""Pinned bootstrap downloads; verify before extraction, including cached bytes."""
import hashlib
import json
from pathlib import Path
import subprocess
import urllib.request
import zipfile

PINS = json.loads((Path(__file__).resolve().parents[1] / "dependency-pins.json").read_text())


def verified_archive(name, path):
    pin = PINS[name]
    path = Path(path)
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_suffix(".download")
        urllib.request.urlretrieve(pin["url"], temporary)
        if hashlib.sha256(temporary.read_bytes()).hexdigest().upper() != pin["sha256"]:
            raise RuntimeError("Downloaded dependency differs from reviewed pin: " + name)
        temporary.replace(path)
    if hashlib.sha256(path.read_bytes()).hexdigest().upper() != pin["sha256"]:
        raise RuntimeError("Cached dependency differs from reviewed pin: " + name)
    return path


def extract_verified(name, path, destination):
    path = verified_archive(name, path)
    destination = Path(destination).resolve()
    with zipfile.ZipFile(path) as archive:
        for item in archive.infolist():
            if not (destination / item.filename).resolve().is_relative_to(destination):
                raise RuntimeError("Dependency contains a path outside extraction root")
        archive.extractall(destination)


def extract_msi(name, path, destination):
    """Administrative (file-only) extraction; installs nothing on the machine."""
    path = verified_archive(name, path).resolve()
    destination = Path(destination).resolve()
    result = subprocess.run(["msiexec", "/a", str(path), "/qn", "TARGETDIR=" + str(destination)])
    if result.returncode:
        raise RuntimeError(f"Could not extract {name} (msiexec exit {result.returncode})")
    return destination
