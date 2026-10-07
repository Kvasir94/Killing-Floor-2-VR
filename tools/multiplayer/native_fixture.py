"""Receipt-checked, reversible native client deployment for an owned fixture."""
from __future__ import annotations

import json
from pathlib import Path
import shutil


def verify_native(root: Path, script_receipt: dict, digest) -> dict:
    if not script_receipt.get("includes_vr_client"):
        raise RuntimeError("Compile scripts with -IncludeVRClient first")
    for package, expected in script_receipt["companion_sources_sha256"].items():
        base = root / "script" / package
        actual = {p.relative_to(base).as_posix(): digest(p) for p in sorted(base.rglob("*.uc"))}
        if actual != expected:
            raise RuntimeError(f"Stale VR script package: {package}")
    for name, expected in script_receipt["packages_sha256"].items():
        if digest(root / "build/multiplayer/script" / name) != expected:
            raise RuntimeError(f"VR package receipt mismatch: {name}")
    build = root / "build/multiplayer/native"
    receipt = json.loads((build / "build.json").read_text(encoding="utf-8-sig"))
    files = [root / "CMakeLists.txt", root / "third_party/xr-sdks.cmake"]
    for directory in ("adapter", "vrcore", "xr", "portal"):
        files += [p for p in (root / "native" / directory).rglob("*")
                  if p.is_file() and (p.suffix in (".h", ".hpp", ".cpp", ".asm") or p.name == "CMakeLists.txt")]
    actual = {p.relative_to(root).as_posix(): digest(p) for p in files}
    if not receipt.get("success") or actual != receipt.get("sources_sha256"):
        raise RuntimeError("Native build is stale; run tools/build-multiplayer-native.ps1")
    if receipt.get("dlss_enabled"):
        pins = json.loads((root / "tools/ngx-pins.json").read_text(encoding="utf-8"))
        if receipt.get("ngx_sdk") != pins:
            raise RuntimeError("NGX receipt differs from pinned SDK")
        for name, expected in pins["files_sha256"].items():
            if digest(root / "third_party/ngx" / name) != expected:
                raise RuntimeError("NGX dependency differs: " + name)
    for name, expected in receipt["artifacts_sha256"].items():
        if digest(build / "native/adapter/Release" / name) != expected:
            raise RuntimeError(f"Native artifact receipt mismatch: {name}")
    for name, expected in receipt["server_artifacts_sha256"].items():
        if digest(build / "native/adapter/server/Release" / name) != expected:
            raise RuntimeError(f"Server native artifact receipt mismatch: {name}")
    return receipt


class NativeDeployment:
    def __init__(self, source: Path, destination: Path, backup: Path, receipt: dict, digest, *, server=False):
        self.source, self.destination, self.backup = source, destination, backup
        self.receipt, self.digest = receipt, digest
        self.installed = []
        self.files = ("dinput8.dll",) if server else ("openxr_loader.dll", "dinput8.dll")

    @property
    def journal_path(self):
        return self.backup / "deployment.json"

    def _save(self, journal):
        import os
        temporary = self.journal_path.with_suffix(".tmp")
        with temporary.open("w", encoding="utf-8") as stream:
            json.dump(journal, stream, indent=2)
            stream.flush()
            os.fsync(stream.fileno())
        temporary.replace(self.journal_path)

    def install(self):
        # Caller holds the shared mutex and has checked for running games.
        if (self.destination / "dinput8.dll").exists():
            raise RuntimeError("Existing proxy belongs to another session; use Recover Interrupted Session")
        self.backup.mkdir(parents=True)
        journal = {"schema": "kf2vr/native-deployment/1", "destination": str(self.destination.resolve()),
                   "files": {}, "complete": False}
        self._save(journal)
        for name in self.files:
            target, prior = self.destination / name, self.backup / name
            expected = self.receipt["artifacts_sha256"][name]
            if self.digest(self.source / name) != expected:
                raise RuntimeError(f"Deployment source changed: {name}")
            original = self.digest(target) if target.exists() else None
            if original:
                shutil.copy2(target, prior)
                if self.digest(prior) != original:
                    raise RuntimeError(f"Backup verification failed: {name}")
            # Journal the ownership intent BEFORE changing a destination. A crash
            # either leaves the original bytes or the complete installed bytes.
            journal["files"][name] = {"original": original, "installed": expected, "restored": False}
            self._save(journal)
            self.installed.append(name)
            staging = self.backup / (name + ".install")
            shutil.copy2(self.source / name, staging)
            if self.digest(staging) != expected:
                raise RuntimeError(f"Staged DLL verification failed: {name}")
            # Backups live on the package volume, which may differ from the game.
            # Copy to a uniquely owned sibling, then atomically replace on-volume.
            import tempfile, os
            fd, temp = tempfile.mkstemp(prefix=".kf2vr-", suffix=".tmp", dir=self.destination)
            try:
                with os.fdopen(fd, "wb") as out, staging.open("rb") as incoming:
                    shutil.copyfileobj(incoming, out)
                    out.flush(); os.fsync(out.fileno())
                if (self.digest(target) if target.exists() else None) != original:
                    raise RuntimeError(f"Destination changed during installation; preserved: {target}")
                Path(temp).replace(target)
            finally:
                Path(temp).unlink(missing_ok=True)

    def restore(self) -> list[str]:
        if not self.journal_path.exists():
            # No journal means installation did not begin, or a legacy session
            # needs manual inspection. Never infer ownership from a filename.
            return ["No durable ownership journal; preserve files for manual review"] if self.installed else []
        journal = json.loads(self.journal_path.read_text(encoding="utf-8"))
        if journal.get("schema") != "kf2vr/native-deployment/1" or journal.get("destination") != str(self.destination.resolve()):
            return ["Deployment ownership journal does not match destination"]
        errors = []
        for name, item in reversed(list(journal["files"].items())):
            if name not in self.files or item["installed"] != self.receipt["artifacts_sha256"].get(name):
                errors.append("Unexpected deployment journal entry; preserved")
                continue
            target, prior = self.destination / name, self.backup / name
            if target.is_symlink() or prior.is_symlink():
                errors.append(f"Linked native file preserved: {target}")
                continue
            current = self.digest(target) if target.exists() else None
            if item.get("restored"):
                if current != item["original"]:
                    errors.append(f"File changed after restoration; preserved: {target}")
                continue
            if current == item["original"]:
                item["restored"] = True
            elif current == item["installed"]:
                if item["original"]:
                    if not prior.exists() or self.digest(prior) != item["original"]:
                        errors.append(f"Original backup missing/changed; preserved: {target}")
                        continue
                    # A interrupted restore retains both a verified backup and
                    # journal; a subsequent call can identify either outcome.
                    import os, tempfile
                    fd, temp = tempfile.mkstemp(prefix=".kf2vr-restore-", suffix=".tmp", dir=self.destination)
                    try:
                        with os.fdopen(fd, "wb") as out, prior.open("rb") as incoming:
                            shutil.copyfileobj(incoming, out)
                            out.flush(); os.fsync(out.fileno())
                        Path(temp).replace(target)
                    finally:
                        Path(temp).unlink(missing_ok=True)
                else:
                    target.unlink()
                item["restored"] = True
            else:
                errors.append(f"Native file changed or missing; preserved for review: {target}")
            self._save(journal)
        journal["complete"] = not errors
        self._save(journal)
        return errors
