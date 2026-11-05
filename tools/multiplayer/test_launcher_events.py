"""The window's event channel: framing, error codes and real backend messages."""
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import launcher_events as events


class LauncherEventTests(unittest.TestCase):
    def test_emit_and_read_skip_partial_and_malformed_lines(self):
        with tempfile.TemporaryDirectory() as folder, patch.dict(os.environ, {}, clear=False):
            path = Path(folder) / "events.jsonl"
            events.configure(path)
            events.phase("checking")
            events.emit(progress=42.5)
            with open(path, "a", encoding="utf-8") as stream:
                stream.write("not json\n[1,2]\n{\"phase\": \"conn")
            found, offset = events.read(path)
            self.assertEqual([{"phase": "checking"}, {"progress": 42.5}], found)
            with open(path, "a", encoding="utf-8") as stream:
                stream.write("ecting\"}\n")
            found, _ = events.read(path, offset)
            self.assertEqual([{"phase": "connecting"}], found)
            os.environ.pop("KF2VR_EVENTS", None)

    def test_emit_without_a_channel_is_silent(self):
        with patch.dict(os.environ, {}, clear=True):
            events.emit(phase="checking")

    def test_backend_messages_map_to_codes(self):
        cases = {
            "No usable active OpenXR runtime. Enable your headset runtime, then retry.": "HEADSET_RUNTIME",
            "Package file changed or missing: Packages/KF2VR.u. Extract a fresh copy.": "PACKAGE_DAMAGED",
            "Start standard KF2 once, then close it and run this launcher again.": "STOCK_CONFIG_MISSING",
            "Map KF-X is not installed on both client and server. Use --menu to choose an available map.": "MAP_MISSING",
            "Not enough free disk space for the dedicated server; free 35 GB and try again.": "DISK_FULL",
            "The disk ran out of space while installing; free space and try again.": "DISK_FULL",
            "The dedicated server could not be installed (exit 3); see the details below.": "SERVER_INSTALL",
            "This join code uses a different KF2-VR build. Extract the same ZIP as your host.": "JOIN_BUILD",
            "This package has no DLSS runtime. Choose DLSS Off or use a DLSS-enabled package.": "DLSS_UNAVAILABLE",
            "Something nobody anticipated": events.UNKNOWN,
        }
        for message, code in cases.items():
            with self.subTest(code=code):
                self.assertEqual(code, events.classify(message))

    def test_catalog_codes_and_phases_are_unique(self):
        codes = [code for code, _, _ in events.ERRORS]
        self.assertEqual(len(codes), len(set(codes)))
        self.assertEqual(len(events.PHASES), len(events.PHASE_TEXT))
        with self.assertRaises(AssertionError):
            events.phase("not-a-phase")


if __name__ == "__main__":
    unittest.main()
