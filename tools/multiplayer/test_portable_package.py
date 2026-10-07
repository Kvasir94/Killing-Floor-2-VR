"""Run distribution entry points using only the files selected by packaging."""
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

from package import check_portable_launchers, copy_launcher_tools, select_candidate, frozen_inputs, copy_frozen_runtime_extras, player_document_root, release_audience
from release_state import digest


class PortablePackageTests(unittest.TestCase):
    def test_public_documents_and_audience_use_reviewed_overlays_without_changing_private_docs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.assertEqual(root, player_document_root(root, public=True))
            overlay = root/'docs/public-source'
            overlay.mkdir(parents=True)
            (root/'README.md').write_text('private original')
            (overlay/'README.md').write_text('public guide')
            self.assertEqual('public guide', (player_document_root(root, public=True)/'README.md').read_text())
            self.assertEqual('private original', (player_document_root(root)/'README.md').read_text())
            self.assertEqual('public-alpha', release_audience(True))
            self.assertEqual('private-alpha', release_audience(False))

    def frozen_release(self, root):
        release = root / "frozen"
        files = {}
        for name in ("Native/client.dll", "Native/nvngx_dlss.dll", "ServerNative/server.dll", "Packages/client.u"):
            path = release / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(name.encode())
            files[name] = digest(path)
        sources = {"native/adapter/Adapter.cpp": "native-source", "script/KF2VR/Classes/Hands.uc": "script-source",
                   "tools/multiplayer/package.py": "old-packager"}
        native = {"success": True, "artifacts_sha256": {"client.dll": files["Native/client.dll"], "nvngx_dlss.dll": files["Native/nvngx_dlss.dll"]},
                  "server_artifacts_sha256": {"server.dll": files["ServerNative/server.dll"]}}
        scripts = {"success": True, "includes_vr_client": True,
                   "packages_sha256": {"client.u": files["Packages/client.u"]}}
        (release / "release.json").write_text(json.dumps({"files_sha256": files,
            "workspace_sources_sha256": sources, "native_build": native, "script_build": scripts}))
        return release, sources, native, scripts

    def test_frozen_refresh_allows_packager_change_and_keeps_receipts(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            release, sources, native, scripts = self.frozen_release(root)
            sources["tools/multiplayer/package.py"] = "new-packager"
            with patch("package.workspace_sources", return_value=sources):
                self.assertEqual((native, scripts), frozen_inputs(root, release))

    def test_frozen_refresh_rejects_changed_added_or_removed_playable_input(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            release, sources, _, _ = self.frozen_release(root)
            for current in ({**sources, "native/adapter/Adapter.cpp": "changed"},
                            {**sources, "script/KF2VR/Classes/New.uc": "new"},
                            {k: v for k, v in sources.items() if not k.startswith("script/")}):
                with patch("package.workspace_sources", return_value=current), self.assertRaisesRegex(RuntimeError, "sources differ"):
                    frozen_inputs(root, release)

    def test_frozen_refresh_rejects_corrupt_artifact(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            release, sources, _, _ = self.frozen_release(root)
            (release / "Native/nvngx_dlss.dll").write_bytes(b"corrupt")
            with patch("package.workspace_sources", return_value=sources), self.assertRaisesRegex(RuntimeError, "missing or changed"):
                frozen_inputs(root, release)

    def test_frozen_refresh_preserves_declared_runtime_extras_without_old_docs_or_local_data(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            release, _, _, _ = self.frozen_release(root)
            manifest = json.loads((release / "release.json").read_text())
            for name in ("tools/optional.ps1", "docs/old.md"):
                path = release / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(name.encode())
                manifest["files_sha256"][name] = digest(path)
            (release / "private.log").write_text("unmanifested local data")
            (release / "release.json").write_text(json.dumps(manifest))
            output = root / "new"
            copy_frozen_runtime_extras(release, output)
            self.assertEqual(b"tools/optional.ps1", (output / "tools/optional.ps1").read_bytes())
            self.assertFalse((output / "docs").exists())
            self.assertFalse((output / "private.log").exists())

    def test_unselected_candidate_preserves_existing_and_missing_pointer(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            pointer = root / "build/multiplayer/current-release.json"
            output = root / "candidate"
            select_candidate(root, output, select=False)
            self.assertFalse(pointer.exists())
            pointer.parent.mkdir(parents=True)
            pointer.write_bytes(b"previous selection\n")
            select_candidate(root, output, select=False)
            self.assertEqual(pointer.read_bytes(), b"previous selection\n")
            self.assertFalse(pointer.with_suffix(".tmp").exists())

    def test_selected_candidate_uses_manifest_digest(self):
        import hashlib
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            output = root / "candidate"
            output.mkdir()
            manifest = b'{"build_id":"candidate"}'
            (output / "release.json").write_bytes(manifest)
            pointer = root / "build/multiplayer/current-release.json"
            pointer.parent.mkdir(parents=True)
            select_candidate(root, output)
            selection = json.loads(pointer.read_text())
            self.assertEqual(selection["release"], "candidate")
            self.assertEqual(selection["manifest_sha256"].lower(), hashlib.sha256(manifest).hexdigest())

    def test_exported_launchers_start_outside_checkout(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "extracted package"
            copy_launcher_tools(Path(__file__).resolve().parents[2], output)
            (output / "release.json").write_text(json.dumps({"build_id": "package-test"}))
            check_portable_launchers(output, Path(sys.executable))


if __name__ == "__main__":
    unittest.main()
