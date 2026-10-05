"""Companion configuration/session-path checks; no game, microphone or model inference."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / "playtest-dictation" / "process.py"
SPEC = importlib.util.spec_from_file_location("playtest_processor", SOURCE)
processor = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(processor)


class PlaytestConfigTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.checklist = self.root / "checklist.json"
        self.checklist.write_text('[{"weapon":"9mm","scenario":"Reload"}]', encoding="utf-8")
        self.config = {
            "notes_dir": str(self.root), "python": str(self.root / "python.exe"),
            "checklist": str(self.checklist), "vocabulary": str(self.root / "words.txt"),
            "cleanup_prompt": str(self.root / "prompt.txt"), "whisper": {"cpu_threads": 4},
            "llm": {"context": 16384, "max_output_tokens": 4096, "threads": 4,
                    "startup_timeout": 180, "request_timeout": 900},
        }

    def test_configuration_accepts_absolute_paths(self):
        processor.validate(self.config)

    def test_rejects_relative_output_path(self):
        self.config["notes_dir"] = "notes"
        with self.assertRaisesRegex(ValueError, "absolute"):
            processor.validate(self.config)

    def test_rejects_empty_checklist(self):
        self.checklist.write_text("[]", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "Checklist"):
            processor.validate(self.config)

    def test_rejects_output_budget_that_consumes_context(self):
        self.config["llm"]["max_output_tokens"] = 16000
        with self.assertRaisesRegex(ValueError, "context"):
            processor.validate(self.config)

    def test_last_session_ignores_new_empty_session(self):
        for sid, audio in (("2026-01-01", [{"file": "audio.wav"}]), ("2026-01-02", [])):
            processor.save(self.root / "raw" / sid / "session.json", {"started_utc": sid, "audio": audio})
        self.assertEqual(processor.latest_session(self.config).parent.name, "2026-01-01")

    def test_audio_path_cannot_escape_session(self):
        folder = self.root / "session"
        folder.mkdir()
        (self.root / "outside.wav").write_bytes(b"")
        with self.assertRaisesRegex(ValueError, "invalid"):
            processor.audio_path(folder, "../outside.wav")

    def test_configure_preserves_existing_preferences(self):
        path = self.root / "local.config.json"
        path.write_text('{"microphone":"chosen headset"}', encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "already exists"):
            processor.configure(path)
        self.assertEqual(json.loads(path.read_text())["microphone"], "chosen headset")

    def test_import_preserves_source_and_does_not_guess_release(self):
        source = self.root / "source.wav"
        source.write_bytes(b"source audio placeholder")
        path = processor.import_audio(self.config, source, None)
        session = processor.read(path)
        self.assertEqual(source.read_bytes(), (path.parent / session["audio"][0]["file"]).read_bytes())
        self.assertEqual(session["selected_release"], "unknown (imported recording)")


if __name__ == "__main__":
    unittest.main()
