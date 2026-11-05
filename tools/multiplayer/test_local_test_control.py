"""Offline launcher/protocol contracts. Does not enable or control a game."""
from argparse import ArgumentParser, Namespace
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import local_test_control as control


class LocalTestLaunchTests(unittest.TestCase):
    def test_console_transport_preserves_text_and_rejects_framing(self):
        for command in ('god', 'set Engine.GameInfo GameSpeed 0.5', 'exec "../test commands.txt"', 'x' * 384):
            wire = control.request_wire('a'*32, 'b'*32, 'console', 7, command)
            self.assertEqual(command, wire.split('\t')[4])
        for command in ('', '   ', 'x'*385, 'god\nquit', 'god\tquit', 'god\rquit', 'god\x00', '\u00e9'):
            with self.subTest(command=command), self.assertRaises(ValueError):
                control.request_wire('a'*32, 'b'*32, 'console', 7, command)
        with self.assertRaises(ValueError):
            control.request_wire('a'*32, 'b'*32, 'console', 7, 'god', 1)

    def options(self, enabled=False, **values):
        return Namespace(local_test_control=enabled, solo=True, vr=True,
                         replay_teammate=False, avatar_preview=False, **values)

    def test_default_off_never_adds_mutator_flag_session_or_channel(self):
        parser = ArgumentParser()
        control.add_options(parser)
        self.assertFalse(parser.parse_args([]).local_test_control)
        role = {"args": ["KF-Outpost?Mutator=KF2VR.VRDemo", "-kf2vr-stereo"]}
        before = repr(role)
        control.configure_role(role, self.options(), "driver")
        self.assertEqual(before, repr(role))

    def test_launch_optin_binds_one_unique_session_and_labels_consequences(self):
        args = self.options(True)
        role = {"args": ["KF-Outpost?Mutator=KF2VR.VRBootstrap,KF2VR.VRDemo?VRNormalGame=1"]}
        control.configure_role(role, args, "driver")
        self.assertIn("KF2VR.VRLocalTestControl", role["args"][0])
        self.assertIn(f"?KF2VRLocalTestSession={args.local_test_session}", role["args"][0])
        self.assertIn("?KF2VRTestCapacity=1", role["args"][0])
        self.assertIn("-kf2vr-local-test-control", role["args"])
        self.assertTrue(role["local_test_control"]["test_unranked"])
        self.assertFalse(role["local_test_control"]["hosted_lan_supported"])
        other = self.options(True)
        control.configure_role({"args": ["KF-Outpost?Mutator=KF2VR.VRDemo"]}, other, "driver")
        self.assertNotEqual(args.local_test_session, other.local_test_session)

    def test_diagnostic_requires_control_solo_and_live_vr(self):
        for enabled, solo, vr in ((False, True, True), (True, False, True), (True, True, False)):
            args = Namespace(local_test_control=enabled, local_test_diagnostic=True,
                             solo=solo, vr=vr, replay_teammate=False, avatar_preview=False)
            with self.subTest(enabled=enabled, solo=solo, vr=vr), self.assertRaises(RuntimeError):
                control.validate_options(args)

    def test_diagnostic_isolated_viewport_and_flag_only_in_explicit_copied_role(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "KFEngine.ini"
            config.write_text("[Engine.Engine]\nGameViewportClientClassName=KF2VR.VRGameViewportClient\n", encoding="utf-16")
            role = {"args": ["KF-Outpost?Mutator=KF2VR.VRDemo", "-kf2vr-stereo"], "config_root": directory}
            control.configure_role(role, self.options(True, local_test_diagnostic=True), "driver")
            self.assertIn("?KF2VRLocalDiagnostic=1", role["args"][0])
            self.assertIn("-kf2vr-local-test-diagnostic", role["args"])
            self.assertIn("KF2VR.VRLocalDiagnosticViewportClient", config.read_text(encoding="utf-16"))
            self.assertEqual(16, role["local_test_control"]["diagnostic"]["maximum_cases"])

    def test_diagnostic_protocol_fixed_cases_only_no_count_or_class_injection(self):
        for token in control.DIAGNOSTIC_CASES:
            self.assertIn(token, control.request_wire("a"*32, "b"*32, "diagnostic", 0, token))
        for token, count in (("case-deadbolt-left-manual", 1), ("case-anything-left-manual", 0),
                             ("KF2Breacher.BreacherDeadbolt", 0), ("fire-all", 0)):
            with self.subTest(token=token, count=count), self.assertRaises(ValueError):
                control.request_wire("a"*32, "b"*32, "diagnostic", 0, token, count)

    def test_refuses_network_client_server_desktop_and_missing_owned_chain(self):
        args = self.options(True)
        for key in ("solo", "vr"):
            previous = getattr(args, key)
            setattr(args, key, False)
            with self.assertRaises(RuntimeError):
                control.validate_options(args)
            setattr(args, key, previous)
        with self.assertRaises(RuntimeError):
            control.configure_role({"args": ["KF-Outpost?Mutator=KF2VR.VRDemo"]}, args, "server")
        with self.assertRaises(RuntimeError):
            control.configure_role({"args": ["KF-Outpost"]}, args, "driver")

    def test_portable_launcher_optin_defaults_off_and_reaches_existing_backend(self):
        import friends
        import launcher_app as app
        # Testing tools show only in developer mode (a checkout or --developer).
        with patch.object(app, "developer_tools_present", return_value=True):
            state = app.LauncherState(app.parse_context(["--developer"]))
        self.assertTrue(state.developer)
        game = Path("C:/KF2VR-fixture-game")
        state.vr, state.store = True, "steam"
        form = state.match_defaults("solo", ["KF-Outpost"])
        self.assertFalse(form["local_test_control"])
        args = friends.parse_options(state.match_arguments("solo", game, dict(form, local_test_control=True)))
        self.assertTrue(args.solo and args.vr and args.local_test_control)
        self.assertNotIn("--local-test-control", state.match_arguments("solo", game, form))

    def test_portable_launcher_rejects_host_and_desktop_control(self):
        import launcher_app as app
        state = app.LauncherState(app.parse_context(["--developer"]))
        state.store = "steam"
        for kind, vr in (("host", True), ("solo", False)):
            with self.subTest(kind=kind, vr=vr):
                state.vr = vr
                form = dict(state.match_defaults(kind, ["KF-Outpost"]), local_test_control=True)
                with self.assertRaisesRegex(PermissionError, "Solo VR only"):
                    state.match_arguments(kind, Path("C:/KF2VR-fixture-game"), form)

    def test_protocol_rejects_exec_class_injection_player_overflow_and_spawn_limits(self):
        session, action = "a" * 32, "b" * 32
        for operation, player, argument, count in (("exec", 0, "quit", 0), ("give-one", 0, "x;quit", 1),
                ("give-one", 0, "../class", 1), ("give-all", -1, "-", 0),
                ("status", 2147483648, "-", 0), ("spawn-zeds", 0, "boss", 1),
                ("spawn-zeds", 0, "scrake", 7), ("disable", 0, "reset", 0)):
            with self.subTest(operation=operation, argument=argument, count=count), self.assertRaises(ValueError):
                control.request_wire(session, action, operation, player, argument, count)
        self.assertEqual(6, len(control.request_wire(session, action, "give-one", 3,
            "KFGameContent.KFWeap_Shotgun_MB500", 1).split("\t")))

    def test_final_receipt_retrievable_when_off_but_conflicting_id_rejected(self):
        session, action = "a" * 32, "b" * 32
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            wire = control.request_wire(session, action, "disable", 3)
            (root / f"{action}.intent").write_text(wire, encoding="ascii")
            (root / f"{action}.receipt").write_text(f"{session}\t{action}\tok\tdisabled\n", encoding="ascii")
            with patch.object(control, "channel_path", return_value=root):
                self.assertEqual((action, "ok\tdisabled"), control.submit(session, "disable", 3, action_id=action))
                with self.assertRaises(RuntimeError):
                    control.submit(session, "give-all", 3, action_id=action)
                with self.assertRaises(RuntimeError):
                    control.submit(session, "status", 3, action_id="c" * 32)
            self.assertEqual(2, len(list(root.iterdir())))


if __name__ == "__main__":
    unittest.main()
