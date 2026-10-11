"""Execute checkout ownership contracts without compilers or game processes."""
import base64
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


@unittest.skipUnless(os.name == "nt", "Windows named mutex contract")
class BuildLockTests(unittest.TestCase):
    helper = Path(__file__).resolve().parents[1] / "build-lock.ps1"

    def command(self, script):
        prefix = ". '" + str(self.helper).replace("'", "''") + "'; $ErrorActionPreference='Stop'; "
        encoded = base64.b64encode((prefix + script).encode("utf-16le")).decode()
        return ["powershell.exe", "-NoProfile", "-EncodedCommand", encoded]

    def run_script(self, script):
        return subprocess.run(self.command(script), text=True, capture_output=True,
                              creationflags=subprocess.CREATE_NO_WINDOW, timeout=30)

    @staticmethod
    def quote(path):
        return "'" + str(path).replace("'", "''") + "'"

    def attempt(self, path):
        return self.run_script(
            "$m=[Threading.Mutex]::new($false,(Get-KF2VRBuildMutexName " + self.quote(path) + ")); "
            "try { if($m.WaitOne(0)) { $m.ReleaseMutex(); 'acquired' } else { 'busy' } } finally {$m.Dispose()}")

    def test_same_checkout_excludes_but_independent_checkout_acquires(self):
        with tempfile.TemporaryDirectory(prefix="kf2vr-build-lock-") as temporary:
            first, second = Path(temporary) / "first", Path(temporary) / "second"
            first.mkdir(); second.mkdir()
            owner = subprocess.Popen(self.command(
                "$m=[Threading.Mutex]::new($false,(Get-KF2VRBuildMutexName " + self.quote(first) + ")); "
                "try { if(-not $m.WaitOne(0)){throw 'busy'}; 'ready'; [Console]::Out.Flush(); "
                "[Console]::ReadLine() | Out-Null; $m.ReleaseMutex() } finally {$m.Dispose()}"),
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                creationflags=subprocess.CREATE_NO_WINDOW)
            try:
                self.assertEqual(owner.stdout.readline().strip(), "ready")
                same = self.attempt(first)
                separate = self.attempt(second)
                self.assertEqual((same.returncode, same.stdout.strip()), (0, "busy"), same.stderr)
                self.assertEqual((separate.returncode, separate.stdout.strip()), (0, "acquired"), separate.stderr)
            finally:
                owner.communicate("release\n", timeout=30)
            self.assertEqual(self.attempt(first).stdout.strip(), "acquired")

    def test_same_thread_nested_ownership(self):
        with tempfile.TemporaryDirectory(prefix="kf2vr-build-lock-") as temporary:
            result = self.run_script(
                "$n=Get-KF2VRBuildMutexName " + self.quote(temporary) + "; "
                "$a=[Threading.Mutex]::new($false,$n); $b=[Threading.Mutex]::new($false,$n); "
                "try { if(-not $a.WaitOne(0)){throw 'outer'}; "
                "try {if(-not $b.WaitOne(0)){throw 'nested'}; $b.ReleaseMutex(); 'nested'} "
                "finally {$a.ReleaseMutex()} } finally {$a.Dispose();$b.Dispose()}")
            self.assertEqual((result.returncode, result.stdout.strip()), (0, "nested"), result.stderr)

    def test_checkout_alias_converges_and_output_alias_is_refused(self):
        with tempfile.TemporaryDirectory(prefix="kf2vr-build-lock-") as temporary:
            root = Path(temporary) / "root"
            alias = Path(temporary) / "alias"
            outside = Path(temporary) / "outside"
            root.mkdir(); outside.mkdir()
            result = self.run_script(
                "New-Item -ItemType Junction -Path " + self.quote(alias) + " -Target " + self.quote(root) + " | Out-Null; "
                "if((Get-KF2VRBuildMutexName " + self.quote(root) + ") -ne (Get-KF2VRBuildMutexName " + self.quote(alias) + ")){throw 'alias differs'}; "
                "Assert-KF2VRBuildOutput " + self.quote(alias / "build/native") + " " + self.quote(alias) + "; "
                "New-Item -ItemType Junction -Path " + self.quote(root / "build") + " -Target " + self.quote(outside) + " | Out-Null; "
                "try { Assert-KF2VRBuildOutput " + self.quote(root / "build/native") + " " + self.quote(root) + "; throw 'accepted output alias' } "
                "catch { if($_.Exception.Message -notlike '*linked output ancestors*'){throw}; 'refused' }")
            self.assertEqual((result.returncode, result.stdout.strip()), (0, "refused"), result.stderr)


if __name__ == "__main__":
    unittest.main()
