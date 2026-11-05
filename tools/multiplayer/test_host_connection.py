"""Host connection publication and the launcher following a session, without a game or window."""
import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

import friends
import join_code
import launcher_app


class HostConnectionTests(unittest.TestCase):
    def test_host_publishes_current_code_before_readiness(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / "JOIN-SERVER.txt"
            path.write_text("previous host", encoding="utf-8")
            args = friends.parse_options(["--host", "--share-address", "192.168.1.20", "--password", "fresh", "--map", "KF-BurningParis"])
            args.mods = []
            output = []

            def capture(message, **kwargs):
                output.append(message)
                if message.startswith("Host ready"):
                    self.assertIn("KF2VR1:", path.read_text(encoding="utf-8"))
                    self.assertNotIn("previous host", path.read_text(encoding="utf-8"))

            with patch.object(friends, "ROOT", root), patch("builtins.print", side_effect=capture):
                friends.announce_host(args, {"build_id": "test"}, "")
            code = next(line for line in "\n".join(output).splitlines() if line.startswith(join_code.PREFIX))
            details = join_code.decode(code, "test")
            self.assertEqual((details["address"], details["password"]), ("192.168.1.20", "fresh"))

    def test_unknown_address_removes_previous_instructions(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / "JOIN-SERVER.txt"
            path.write_text("previous host", encoding="utf-8")
            args = friends.parse_options(["--host", "--password", "fresh"])
            with patch.object(friends, "ROOT", root), contextlib.redirect_stdout(io.StringIO()) as output:
                friends.announce_host(args, {"build_id": "test"}, "")
            self.assertFalse(path.exists())
            self.assertIn("Public address unavailable.", output.getvalue())

    def test_launcher_shows_only_this_sessions_code_from_its_events(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "JOIN-SERVER.txt").write_text("KF2VR1:OLD", encoding="utf-8")
            channel = root / "events.jsonl"
            channel.write_text("", encoding="utf-8")
            process = Mock()
            process.poll.return_value = None
            session = launcher_app.SessionTracker(process, root / "launcher.txt", channel, "host", "Hosting")

            def emit(**event):
                with channel.open("a", encoding="utf-8") as stream:
                    stream.write(json.dumps(event) + "\n")
            emit(phase="connecting")
            self.assertEqual({"phase"}, session.poll())
            self.assertIsNone(session.join_code)
            self.assertEqual("connecting", session.phase)
            emit(join_code="KF2VR1:NEW")
            emit(phase="host-ready")
            self.assertEqual({"phase", "join_code"}, session.poll())
            self.assertEqual(set(), session.poll())
            self.assertEqual("KF2VR1:NEW", session.join_code)
            emit(join_code="KF2VR1:LATER")
            session.poll()
            self.assertEqual("KF2VR1:NEW", session.join_code)
            self.assertEqual([("checking", "done"), ("server-install", "done"), ("connecting", "done"),
                              ("host-ready", "active"), ("game-starting", "waiting")], session.steps())
            emit(error="SERVER_EXITED", message="Dedicated server exited.")
            process.poll.return_value = 1
            process.returncode = 1
            self.assertEqual({"error", "finished"}, session.poll())
            self.assertEqual("SERVER_EXITED", session.error_code)
            self.assertFalse(session.succeeded)
            self.assertIn("game server stopped", session.problem())

    def test_host_without_public_address_has_no_code(self):
        with tempfile.TemporaryDirectory() as temporary:
            channel = Path(temporary) / "events.jsonl"
            channel.write_text(json.dumps({"join_code": None}) + "\n", encoding="utf-8")
            session = launcher_app.SessionTracker(Mock(**{"poll.return_value": None}), Path(temporary) / "log.txt",
                                                  channel, "host", "Hosting")
            self.assertEqual({"join_code"}, session.poll())
            self.assertEqual("none", session.join_code)

    def test_closing_stops_only_a_run_that_is_still_getting_ready(self):
        # Closing the window mid-download stops it; once the server starts, files are deployed and the game keeps going.
        with tempfile.TemporaryDirectory() as temporary:
            channel = Path(temporary) / "events.jsonl"
            channel.write_text("", encoding="utf-8")
            session = launcher_app.SessionTracker(Mock(pid=4242, **{"poll.return_value": None}),
                                                  Path(temporary) / "log.txt", channel, "host", "Hosting")
            for phase, preparing in ((None, True), ("checking", True), ("server-download", True),
                                     ("server-starting", False), ("host-ready", False)):
                session.phase = phase
                self.assertEqual(preparing, session.preparing(), phase)
            with patch.object(launcher_app.subprocess, "run") as run:
                session.stop()
            self.assertEqual(["taskkill", "/PID", "4242", "/T", "/F"], run.call_args.args[0])

if __name__ == "__main__":
    unittest.main()
