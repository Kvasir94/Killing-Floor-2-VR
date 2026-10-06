"""Execute the real root launcher against isolated portable launcher stubs."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from release_state import digest

ROOT = Path(__file__).resolve().parents[2]
RUNTIME = ROOT/'build/multiplayer/releases/KF2VR-Multiplayer-20261006-001928/runtime'


@unittest.skipUnless(os.name == 'nt' and RUNTIME.is_dir(), 'Windows rollback runtime required')
class RootStoreDispatchTests(unittest.TestCase):
    def dispatch(self, store, protocol):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            release = root/'build/multiplayer/releases/KF2VR-Multiplayer-20260101-000000'
            tools = root/'tools'
            (tools/'multiplayer').mkdir(parents=True)
            (release/'tools/multiplayer').mkdir(parents=True)
            shutil.copy2(ROOT/'tools/play-main.ps1', tools/'play-main.ps1')
            manifest = release/'release.json'
            manifest.write_text(json.dumps({'player_launcher_protocol': 1, 'store_launcher_protocol': protocol}))
            (root/'build/multiplayer/current-release.json').write_text(json.dumps({
                'schema': 'kf2vr/current-release/1', 'release': release.name, 'manifest_sha256': digest(manifest)}))
            (tools/'multiplayer/release_state.py').write_text('print("Package verified in launcher fixture")\n')
            (release/'tools/multiplayer/friends.py').write_text(
                'import json,os,sys\nfrom pathlib import Path\n'
                'Path(os.environ["KF2VR_DISPATCH_ARGS"]).write_text(json.dumps(sys.argv[1:]))\n')
            output = root/'arguments.json'
            environment = dict(os.environ, LOCALAPPDATA=str(root/'profile'),
                               PSModulePath=str(Path(os.environ.get('SystemRoot', 'C:/Windows'))/'System32/WindowsPowerShell/v1.0/Modules'),
                               KF2VR_TEST_LINK=str(release/'runtime'), KF2VR_TEST_RUNTIME=str(RUNTIME),
                               KF2VR_DISPATCH_ARGS=str(output))
            linked = subprocess.run(['powershell.exe', '-NoProfile', '-Command',
                'New-Item -ItemType Junction -Path $env:KF2VR_TEST_LINK -Value $env:KF2VR_TEST_RUNTIME | Out-Null'],
                env=environment, capture_output=True, text=True, creationflags=0x08000000)
            self.assertEqual(0, linked.returncode, linked.stderr)
            try:
                result = subprocess.run(['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
                    str(tools/'play-main.ps1'), '-Solo', '-Desktop', '-PrepareOnly', '-Store', store],
                    env=environment, capture_output=True, text=True, timeout=30, creationflags=0x08000000)
                arguments = json.loads(output.read_text()) if output.exists() else None
                return result, arguments
            finally:
                # Remove only the junction itself before TemporaryDirectory cleanup.
                # Its external runtime target is immutable and must be preserved.
                os.rmdir(release/'runtime')

    def test_selected_steam_rollback_does_not_receive_new_store_flag(self):
        result, args = self.dispatch('Steam', None)
        self.assertEqual(0, result.returncode, result.stdout+result.stderr)
        self.assertNotIn('--store', args)
        self.assertIn('--prepare-only', args)

    def test_epic_on_old_selection_stops_without_running_portable_launcher(self):
        result, args = self.dispatch('Epic', None)
        self.assertNotEqual(0, result.returncode)
        self.assertIsNone(args)
        self.assertIn('selected package supports Steam only', result.stderr)

    def test_new_selection_forwards_explicit_store(self):
        result, args = self.dispatch('Epic', 1)
        self.assertEqual(0, result.returncode, result.stdout+result.stderr)
        self.assertEqual('epic', args[args.index('--store')+1])


if __name__ == '__main__':
    unittest.main()
