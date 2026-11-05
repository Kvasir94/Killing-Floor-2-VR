"""Exercise the shipped PowerShell installer using temporary package/game trees."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


INSTALLER = Path(__file__).with_name("epic_desktop_install.ps1")
POWERSHELL = shutil.which("powershell.exe") or shutil.which("pwsh")
PACKAGES = ("KF2VR.u", "KF2VRNet.u", "KF2VRHands.upk", "KF-VRRange.kfm")


@unittest.skipUnless(POWERSHELL, "PowerShell is needed for the standalone Windows installer")
class EpicInstallerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="kf2vr-epic-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.pack = self.root / "pack's extracted folder"
        self.game = self.root / "player's Epic game \u00e9\u6e38\u620f"
        self.pack.mkdir()
        self.executable = self.game / "Binaries/Win64/KFGame.exe"
        self.executable.parent.mkdir(parents=True)
        self.executable.write_bytes(b"supported temporary Epic executable")
        self.expected = hashlib.sha256(self.executable.read_bytes()).hexdigest().upper()
        self.brewed = self.game / "KFGame/BrewedPC"
        self.brewed.mkdir(parents=True)
        self.destination = self.brewed / "KF2VR"
        self.backup = self.game / "KF2VR-desktop-backup"
        self.staging = self.brewed / ".KF2VR-installing"
        self.manifest = {"schema": "kf2vr/desktop-companion/1", "build_id": "temporary-test",
                         "supported_epic_sha256": self.expected, "files_sha256": {}}
        for name in PACKAGES:
            path = self.pack / "KF2VR" / name
            path.parent.mkdir(exist_ok=True)
            path.write_bytes(("new " + name).encode())
            self.manifest["files_sha256"]["KF2VR/" + name] = hashlib.sha256(path.read_bytes()).hexdigest()
        self.save_manifest()

    def save_manifest(self):
        (self.pack / "companion.json").write_text(json.dumps(self.manifest), encoding="utf-8")

    def run_ps(self, body, *, succeeds=True, error_contains=None):
        script = self.root / "exercise.ps1"
        # No real KF2 is "running" unless a test says so: a game on this PC
        # (a replay fixture, another agent's run) must not fail the installer
        # tests. A test that needs one redefines Get-Process in its body.
        script.write_text("[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)\n"
                          ". $env:KF2VR_TEST_INSTALLER\n"
                          "function Get-Process([string]$Name, [string]$ErrorAction) {}\n" + body,
                          encoding="utf-8-sig")
        environment = dict(os.environ, KF2VR_TEST_INSTALLER=str(INSTALLER), KF2VR_TEST_PACK=str(self.pack),
                           KF2VR_TEST_GAME=str(self.game), KF2VR_TEST_HASH=self.expected,
                           KF2VR_TEST_ROOT=str(self.root))
        result = subprocess.run([POWERSHELL, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(script)],
                                env=environment, text=True, encoding="utf-8", capture_output=True, timeout=30)
        if succeeds:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            if error_contains:
                self.assertIn(error_contains, result.stdout + result.stderr)
        return result

    def install(self, prefix="", *, succeeds=True, error_contains=None):
        return self.run_ps(prefix + "\nInstall-KF2VRDesktopPack -PackRoot $env:KF2VR_TEST_PACK "
                           "-GameRoot $env:KF2VR_TEST_GAME -SupportedExecutableSha256 $env:KF2VR_TEST_HASH\n",
                           succeeds=succeeds, error_contains=error_contains)

    def add_existing(self):
        self.destination.mkdir()
        (self.destination / "old.u").write_bytes(b"previous installation plus personal file")

    def test_fresh_install_and_update_preserve_original_tree(self):
        self.add_existing()
        self.install()
        self.assertEqual((self.backup / "old.u").read_bytes(), b"previous installation plus personal file")
        self.assertFalse((self.destination / "old.u").exists())
        self.assertFalse(self.staging.exists())
        for name in PACKAGES:
            self.assertEqual((self.pack / "KF2VR" / name).read_bytes(), (self.destination / name).read_bytes())
        self.install(succeeds=False, error_contains="earlier install or backup already exists")
        self.assertEqual((self.backup / "old.u").read_bytes(), b"previous installation plus personal file")

    def test_fresh_install_needs_no_existing_backup(self):
        self.install()
        self.assertFalse(self.backup.exists())
        self.assertEqual(set(p.name for p in self.destination.iterdir()), set(PACKAGES))

    def test_changed_pack_or_game_never_changes_destination(self):
        self.add_existing()
        (self.pack / "KF2VR/KF-VRRange.kfm").write_bytes(b"changed")
        self.install(succeeds=False, error_contains="Companion file is missing or changed")
        self.assertTrue((self.destination / "old.u").exists())
        self.assertFalse(self.backup.exists())
        self.manifest["files_sha256"]["KF2VR/KF-VRRange.kfm"] = hashlib.sha256(b"changed").hexdigest()
        self.save_manifest()
        self.executable.write_bytes(b"unrecognized executable")
        self.install(succeeds=False, error_contains="Choose the supported Epic")
        self.assertTrue((self.destination / "old.u").exists())

    def test_running_game_is_rechecked_before_replacement(self):
        self.add_existing()
        self.install("""
$script:checks = 0
function Get-Process([string]$Name, [string]$ErrorAction) {
    $script:checks++
    if ($script:checks -eq 2) { return @{ ProcessName = 'KFGame' } }
}
""", succeeds=False, error_contains="Killing Floor 2 is running")
        self.assertTrue((self.destination / "old.u").exists())
        self.assertFalse(self.backup.exists())
        self.assertFalse(self.staging.exists())

    def test_failed_post_swap_validation_rolls_back_and_preserves_failed_copy(self):
        self.add_existing()
        self.install("""
$script:checks = 0
$script:realVerify = ${function:Assert-KF2VRInstalledFiles}
function Assert-KF2VRInstalledFiles($Destination, $Manifest) {
    $script:checks++
    if ($script:checks -eq 2) { throw 'mock verification failure after rename' }
    & $script:realVerify $Destination $Manifest
}
""", succeeds=False, error_contains="mock verification failure after rename")
        self.assertTrue((self.destination / "old.u").exists())
        self.assertFalse(self.backup.exists())
        self.assertEqual((self.staging / "KF2VR.u").read_bytes(), (self.pack / "KF2VR/KF2VR.u").read_bytes())

    def test_preexisting_staging_is_preserved(self):
        self.add_existing()
        self.staging.mkdir()
        (self.staging / "keep").write_bytes(b"recovery")
        self.install(succeeds=False, error_contains="earlier install or backup already exists")
        self.assertEqual((self.staging / "keep").read_bytes(), b"recovery")
        self.assertTrue((self.destination / "old.u").exists())

    def test_manifest_traversal_is_rejected_before_copy(self):
        self.manifest["files_sha256"]["../outside.u"] = "0" * 64
        self.save_manifest()
        self.install(succeeds=False, error_contains="Invalid companion file inventory")
        self.assertFalse(self.destination.exists())

    def test_discovery_parses_completed_epic_and_heroic_records(self):
        manifests = self.root / "manifests"
        manifests.mkdir()
        data = {"AppName": "Finch", "bIsIncompleteInstall": False,
                "LaunchExecutable": "Binaries\\Win64\\KFGame.exe", "InstallLocation": str(self.game)}
        (manifests / "good.item").write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
        (manifests / "incomplete.item").write_text(json.dumps(dict(data, bIsIncompleteInstall=True, InstallLocation="C:\\bad")))
        (manifests / "other.item").write_text(json.dumps(dict(data, AppName="Other", InstallLocation="C:\\other")))
        (manifests / "broken.item").write_text("{broken")
        heroic = self.root / "heroic.json"
        heroic.write_text(json.dumps({"Finch": {"install_path": str(self.game)}, "Other": {"install_path": "C:\\other"}},
                                    ensure_ascii=False), encoding="utf-8")
        result = self.run_ps("""
$found = @(Get-EpicDesktopCandidates (Join-Path $env:KF2VR_TEST_ROOT 'manifests') (Join-Path $env:KF2VR_TEST_ROOT 'heroic.json'))
if ($found.Count -ne 1 -or $found[0] -ne $env:KF2VR_TEST_GAME) { throw 'wrong discovery candidates' }
""")
        self.assertEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
