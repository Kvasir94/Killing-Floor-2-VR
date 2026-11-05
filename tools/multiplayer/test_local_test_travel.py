"""Pure readiness/status parsing and exact-id request transport; never launches KF2."""
from pathlib import Path
import tempfile
import unittest

import local_test_control as control
import run_local_test_travel as travel


class LocalTestTravelTests(unittest.TestCase):
    session = "a" * 32
    action = "b" * 32

    def ready(self, start=1000, duration="game_session", session=None, pid=42):
        return f"{session or self.session}\t{pid}\ttest_unranked\tstart_tick_ms={start}\tduration={duration}\n"

    def test_remaining_owned_game_budget_reserves_cleanup_without_extending_launch(self):
        created = (1_790_000_000 + 11_644_473_600) * 10_000_000
        self.assertEqual(460, travel.remaining_game_budget(540, created, 1_790_000_060))
        self.assertEqual(160, travel.remaining_game_budget(540, created, 1_790_000_360))
        self.assertEqual(0, travel.remaining_game_budget(540, created, 1_790_000_521))
        self.assertEqual(0, travel.remaining_game_budget(540, created, 1_790_000_600))
        with self.assertRaises(ValueError):
            travel.remaining_game_budget(540, created, 1_789_999_000)

    def test_drop_options_requires_explicit_absolute_fixture_and_fixed_map(self):
        package = [{"name": "ReloadStateTools.u"}]
        travel.validate_negative_fixture("disable", False, "KF-Manor", [])
        travel.validate_negative_fixture("drop-options", True, "KF-Outpost", package)
        for values in (("drop-options", False, "KF-Outpost", package),
                       ("drop-options", True, "KF-Outpost", []),
                       ("drop-options", True, "KF-Manor", package),
                       ("disable", True, "KF-Outpost", package)):
            with self.subTest(values=values), self.assertRaises(ValueError):
                travel.validate_negative_fixture(*values)

    def test_readiness_preserves_identity_and_game_session_duration(self):
        record = travel.parse_ready(self.ready(), self.session, 42)
        self.assertEqual((1000, "game_session"), (record["start_tick_ms"], record["duration"]))
        for text in (self.ready(duration="persistent"), self.ready(start=-1),
                     self.ready(session="c"*32), self.ready(pid=43), f"{self.session}\t42\ttest_unranked\n"):
            with self.subTest(text=text), self.assertRaises(ValueError):
                travel.parse_ready(text, self.session, 42)

    def test_status_requires_destination_standalone_unranked_and_exact_local_player(self):
        status = "ok\ttest_unranked=1\tenabled=1\tmap=KF-Outpost\tnetmode=NM_Standalone\nplayer\t7\thealth=100"
        self.assertEqual(7, travel.parse_status(status, "KF-Outpost"))
        for invalid in (status.replace("enabled=1", "enabled=0"), status.replace("test_unranked=1", "test_unranked=0"),
                        status.replace("NM_Standalone", "NM_Client"), status.replace("KF-Outpost", "KF-Manor"),
                        status + "\nplayer\t8", status.split("\n")[0]):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                travel.parse_status(invalid, "KF-Outpost")

    def test_travel_url_conserves_session_and_negative_omits_all_test_options(self):
        command = travel.travel_command("KF-Manor", self.session)
        self.assertIn("KF2VRLocalTestSession=" + self.session, command)
        self.assertIn("?Mutator=KF2VR.VRBootstrap,KF2VR.VRDemo,KF2VR.VRLocalTestControl", command)
        negative = travel.travel_command("KF-Manor")
        self.assertIn("?Mutator=KF2VR.VRBootstrap,KF2VR.VRDemo", negative)
        self.assertIn("?VRNormalGame=1", negative)
        for option in ("VRLocalTestControl", "KF2VRLocalTest", "KF2VRTestCapacity"):
            self.assertNotIn(option, negative)
        for destination in ("KF-Manor?x=1", "../KF-Manor", "KF-Manor quit"):
            with self.assertRaises(ValueError):
                travel.travel_command(destination, self.session)
        with self.assertRaises(ValueError):
            travel.travel_command("KF-Manor", "bad-session")

    def test_native_audit_distinguishes_cached_result_from_a_second_dispatch(self):
        wire = control.request_wire(self.session, self.action, "status", 0)
        audit = f"accepted\t{wire}\nresult\t{self.action}\tok\tenabled=1\n"
        self.assertEqual((1, 1), travel.audit_counts(audit, self.action))
        self.assertEqual((1, 2), travel.audit_counts(audit + f"result\t{self.action}\tok\tenabled=1\n", self.action))
        self.assertEqual((2, 1), travel.audit_counts(audit + f"accepted\t{wire}\n", self.action))
        self.assertEqual((0, 0), travel.audit_counts(audit, "c"*32))

    def test_duplicate_queue_retains_original_receipt_and_exact_status_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            channel = Path(directory)
            (channel / "ready.tsv").write_text(self.ready(), encoding="ascii")
            wire = control.request_wire(self.session, self.action, "status", 0)
            (channel / f"{self.action}.intent").write_text(wire, encoding="ascii")
            receipt = f"{self.session}\t{self.action}\tok\tenabled=1\n"
            (channel / f"{self.action}.receipt").write_text(receipt, encoding="ascii")
            with self.assertRaises(RuntimeError):
                travel.queue_duplicate_status(channel, self.session, self.action, 1)
            self.assertEqual(receipt, travel.queue_duplicate_status(channel, self.session, self.action, 0))
            self.assertEqual(wire, (channel / f"{self.action}.request").read_text())
            self.assertEqual(receipt, (channel / f"{self.action}.receipt").read_text())
            with self.assertRaises(RuntimeError):
                travel.queue_duplicate_status(channel, self.session, self.action, 0)

    def test_console_load_errors_fail_immediately_without_rejecting_success(self):
        travel.check_console_output("ok\tconsole_dispatched=1\nSpawned ReloadStateTools.VRFixtureReady")
        for output in ("Command not recognized: obj load file=Probe.u", "Failed to load 'Class Probe.Actor'",
                       "Can't find file for package Probe", "Class Probe.Actor not found", "classnotfound"):
            with self.subTest(output=output), self.assertRaises(RuntimeError):
                travel.check_console_output(output)

    def test_probe_log_ignores_ambient_font_and_unrelated_package_load_warnings(self):
        commands = ["summon ReloadStateTools.VRReloadStateProbe"]
        packages = [{"name": "ReloadStateTools.u"}]
        text = ("[0047.00] Warning: Warning, Failed to load 'Font None.KFMerged Regular': "
                "Failed to find object 'Font None.KFMerged Regular'\n"
                "Failed to load 'Class OtherPackage.Actor'\n"
                "Failed to load 'Class ReloadStateToolsExtra.Actor'\n"
                "Command not recognized: unrelated command\n")
        travel.check_probe_log(text, commands, packages, ["KF2VR_RELOAD_PROBE FAIL"])
        # The same failure in a direct console reply still rejects that action.
        with self.assertRaises(RuntimeError):
            travel.check_console_output(text.splitlines()[0])

    def test_probe_log_retains_requested_class_package_command_and_explicit_failures(self):
        commands = ["summon ReloadStateTools.VRReloadStateProbe"]
        for text in ("Failed to load 'Class ReloadStateTools.VRReloadStateProbe'",
                     "Can't find file for package ReloadStateTools",
                     "Class ReloadStateTools.VRReloadStateProbe not found",
                     "Command not recognized: summon ReloadStateTools.VRReloadStateProbe",
                     "KF2VR_RELOAD_PROBE FAIL reason=state_mismatch"):
            with self.subTest(text=text), self.assertRaises(RuntimeError):
                travel.check_probe_log(text, commands, [], ["KF2VR_RELOAD_PROBE FAIL"])
        # Package failures are caught even if an alternate console command loads it.
        with self.assertRaises(RuntimeError):
            travel.check_probe_log("Failed to load package ReloadStateTools", [],
                                   [{"name": "ReloadStateTools.u"}], [])
        with self.assertRaises(RuntimeError):
            travel.check_probe_log("Command not recognized: obj load file=Probe.u",
                                   ["obj load file=Probe.u"], [], [])

    def test_probe_packages_only_copy_extras_and_extend_disposable_config(self):
        from session import read_ini, config_hashes
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "build/fixtures/Script"
            release = root / "build/release"
            shipped = release / "Packages"
            stock = root / "game/KFGame/BrewedPC"
            configs = root / "run/driver/Config"
            for folder in (source, shipped, stock, configs):
                folder.mkdir(parents=True)
            (source / "Probe.u").write_bytes(b"fixture")
            (source / "skip.txt").write_text("not a package")
            (source / "KF2VR.u").write_bytes(b"release")
            (shipped / "KF2VR.u").write_bytes(b"release")
            original = "[Core.System]\nPaths=stock\nScriptPaths=stock\nSeekFreePCPaths=stock\nBrewedPCPaths=stock\n[Other]\nKeep=True\n"
            engine = configs / "KFEngine.ini"
            engine.write_text(original, encoding="utf-16")
            packages = travel.probe_packages(root, source, release, root / "game")
            self.assertEqual(["Probe.u"], [p["name"] for p in packages])
            role = {"role": "driver", "config_root": str(configs)}
            travel.configure_probe_packages(role, root / "run", packages)
            target = configs.parent / "ProbePackages"
            self.assertEqual(["Probe.u"], [p.name for p in target.iterdir()])
            self.assertEqual(b"fixture", (target / "Probe.u").read_bytes())
            text = read_ini(engine)
            for key in ("Paths", "ScriptPaths", "SeekFreePCPaths", "BrewedPCPaths"):
                self.assertIn(f"{key}=stock\n{key}={target}", text)
            self.assertIn("[Other]\nKeep=True", text)
            self.assertEqual(config_hashes(configs), role["config_hashes"])
            self.assertEqual(b"release", (shipped / "KF2VR.u").read_bytes())
            self.assertEqual([], list(stock.iterdir()))
            self.assertEqual(str(target / "Probe.u"), role["probe_packages"][0]["session_path"])

    def test_probe_packages_reject_outside_stock_conflict_release_conflict_and_stale_copy(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "build/fixtures"
            shipped = root / "release/Packages"
            stock = root / "game/KFGame/BrewedPC"
            for folder in (source, shipped, stock):
                folder.mkdir(parents=True)
            extra = source / "Probe.u"
            extra.write_bytes(b"fixture")
            with self.assertRaises(ValueError):
                travel.probe_packages(root, root, shipped.parent, root / "game")
            (stock / "Probe.u").write_bytes(b"stock")
            with self.assertRaises(ValueError):
                travel.probe_packages(root, source, shipped.parent, root / "game")
            (stock / "Probe.u").unlink()
            (shipped / "Probe.u").write_bytes(b"different")
            with self.assertRaises(ValueError):
                travel.probe_packages(root, source, shipped.parent, root / "game")
            (shipped / "Probe.u").unlink()
            packages = travel.probe_packages(root, source, shipped.parent, root / "game")
            extra.write_bytes(b"changed")
            configs = root / "run/driver/Config"
            configs.mkdir(parents=True)
            with self.assertRaises(ValueError):
                travel.configure_probe_packages({"role": "driver", "config_root": str(configs)}, root / "run", packages)
            self.assertEqual([], list((configs.parent / "ProbePackages").iterdir()))


if __name__ == "__main__":
    unittest.main()
