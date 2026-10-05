"""Offline launcher/protocol contracts. Does not enable or control a game."""
from argparse import ArgumentParser, Namespace
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import local_test_control as control


class LocalTestLaunchTests(unittest.TestCase):
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

    def test_combined_breacher_and_control_keep_both_explicit_mutators(self):
        import breacher
        import friends
        args = friends.parse_options(["--solo", "--vr", "--breacher", "--local-test-control"])
        args.breacher_content = {"protocol": 1, "sha256": "A" * 64}
        role = {"args": ["KF-Outpost?Mutator=KF2VR.VRBootstrap,KF2VR.VRDemo"]}
        role["args"][0] = breacher.add_mutator(role["args"][0], args)
        control.configure_role(role, args, "driver")
        mutators = role["args"][0].split("?Mutator=", 1)[1].split("?", 1)[0].split(",")
        self.assertEqual(mutators, ["KF2VR.VRBootstrap", "KF2VR.VRDemo",
                                   "KF2Breacher.BreacherMutator", "KF2VR.VRLocalTestControl"])
        self.assertEqual(role["args"].count("-kf2vr-local-test-control"), 1)
        default = friends.parse_options(["--solo", "--vr"])
        self.assertFalse(default.local_test_control)
        self.assertFalse(bool(default.breacher))

    @unittest.skipUnless(os.name == "nt", "Portable player GUI is Windows")
    def test_portable_gui_optin_defaults_off_and_reaches_existing_backend(self):
        import friends
        import launcher_gui as gui
        from tkinter import ttk
        window = gui.Launcher(art=False)
        window.withdraw()
        def checkbox():
            def children(widget):
                for child in widget.winfo_children():
                    yield child
                    yield from children(child)
            return next(w for w in children(window.body) if isinstance(w, ttk.Checkbutton)
                        and w.cget("text").startswith("Local agent test control"))
        try:
            with patch.object(window, "need_game", return_value=Path("C:/KF2VR-fixture-game")), \
                    patch("launch_menu.installed_solo_maps", return_value=["KF-Outpost"]), \
                    patch.object(window, "footer") as footer, patch.object(window, "run") as run:
                window.vr.set(True)
                window.options("solo")
                choice = checkbox()
                self.assertNotIn("disabled", choice.state())
                self.assertFalse(bool(window.getvar(choice.cget("variable"))))
                choice.invoke()
                footer.call_args.kwargs["start"]()
                args = friends.parse_options(run.call_args.args[0])
                self.assertTrue(args.solo and args.vr and args.local_test_control)
                self.assertEqual(bool(window.saved.breacher), args.breacher)
                window.options("solo")
                self.assertFalse(bool(window.getvar(checkbox().cget("variable"))))
                footer.call_args.kwargs["start"]()
                self.assertNotIn("--local-test-control", run.call_args.args[0])
        finally:
            window.destroy()

    @unittest.skipUnless(os.name == "nt", "Portable player GUI is Windows")
    def test_portable_gui_disables_and_rejects_host_and_desktop_control(self):
        import launcher_gui as gui
        from tkinter import ttk
        window = gui.Launcher(art=False)
        window.withdraw()
        def checkbox():
            def children(widget):
                for child in widget.winfo_children():
                    yield child
                    yield from children(child)
            return next(w for w in children(window.body) if isinstance(w, ttk.Checkbutton)
                        and w.cget("text").startswith("Local agent test control"))
        try:
            with patch.object(window, "need_game", return_value=Path("C:/KF2VR-fixture-game")), \
                    patch("launch_menu.installed_solo_maps", return_value=["KF-Outpost"]), \
                    patch("launch_menu.installed_maps", return_value=["KF-Outpost"]), \
                    patch.object(window, "footer") as footer, patch.object(window, "run") as run, \
                    patch.object(gui.messagebox, "showerror") as error:
                for kind, vr in (("host", True), ("solo", False)):
                    with self.subTest(kind=kind, vr=vr):
                        window.vr.set(vr)
                        window.options(kind)
                        choice = checkbox()
                        self.assertIn("disabled", choice.state())
                        choice.invoke()
                        self.assertFalse(bool(window.getvar(choice.cget("variable"))))
                        window.setvar(choice.cget("variable"), True)
                        footer.call_args.kwargs["start"]()
                        run.assert_not_called()
                        error.assert_called_with("Solo VR required", "Local agent test control is available in Solo VR only.")
        finally:
            window.destroy()

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
