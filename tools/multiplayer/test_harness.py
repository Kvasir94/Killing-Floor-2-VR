import struct
import unittest
from unittest.mock import patch
import tempfile
import os
import json
import subprocess
import sys
from pathlib import Path

from evidence import (parse_info, verify_transport, verify_fire_reload, verify_damage, verify_movement,
                      verify_room_movement, verify_room_clamp, verify_room_residual,
                      verify_vr_controls, verify_pose_dropout, verify_reconnect, verify_disconnect_cleanup)
from evidence import world_logs, verify_lifecycle
from session import set_ini, digest, unreal_command, replay_core_evidence
from native_fixture import NativeDeployment


class ReplayReadinessTests(unittest.TestCase):
    def test_waits_for_late_native_and_server_signals(self):
        from evidence import HELD_LEDGER_CASES, SERVER_PENDING_CASES
        server = ("KF2VRNet session world=7 netmode=1\n"
                  "KF2VRNet hello world=7 connection=2 accepted=true netmode=1\n"
                  "KF2VRNet authority world=7 connection=2 pawn=1 accepted=40 netmode=1\n")
        driver = "KF2VRNet status world=7 connection=2 pawn=1 hello=true received=30 netmode=3\n"
        def checks():
            return replay_core_evidence((server, driver, None), native_replay=True,
                                        server_adapter=True, paired_weapons=True)
        self.assertTrue(checks()["transport"]["passed"])
        self.assertFalse(all(c["passed"] for c in checks().values()))
        for kind, cases in (("held_ledger", HELD_LEDGER_CASES), ("server_pending", SERVER_PENDING_CASES)):
            server += "".join(f"KF2VRNet {kind} case={case} passed=true pawn=Pawn_1 netmode=1\n" for case in cases)
        for samples in ("29", "bad", ""):
            driver += f"KF2VRNet native_frame samples={samples} valid=3 calibrated=True connection=2\n"
            self.assertFalse(checks()["native_replay"]["passed"])
        driver += "KF2VRNet native_frame samples=30 valid=3 calibrated=True connection=2\n"
        self.assertTrue(all(c["passed"] for c in checks().values()))

class ClientStartupPhaseTests(unittest.TestCase):
    def alive(self):
        from types import SimpleNamespace
        return SimpleNamespace(poll=lambda: None)

    def test_slow_engine_startup_has_separate_finite_budget(self):
        from session import await_client_startup
        elapsed = [0.0]
        logs = iter(["Steam Client API initialized 1", "LoadMap: KFMainMenu", "Initializing Engine Completed"])
        def sleep(seconds): elapsed[0] += 37.0
        with patch("builtins.print"):
            result = await_client_startup({"role": "driver"}, self.alive(), self.alive(), 120,
                read_log=lambda role: next(logs), clock=lambda: elapsed[0], sleep=sleep)
        self.assertEqual(74.0, result)

    def test_startup_timeout_does_not_run_indefinitely(self):
        from session import await_client_startup
        elapsed = [0.0]
        def sleep(seconds): elapsed[0] += seconds
        with self.assertRaisesRegex(RuntimeError, "Engine-startup phase exceeded"):
            await_client_startup({"role": "driver"}, self.alive(), self.alive(), 1,
                read_log=lambda role: "", clock=lambda: elapsed[0], sleep=sleep)
        self.assertEqual(1.0, elapsed[0])

    def test_steam_failure_is_reported_before_generic_handshake_timeout(self):
        from session import await_client_startup
        with self.assertRaisesRegex(RuntimeError, "Steam client initialization failed"):
            await_client_startup({"role": "driver"}, self.alive(), self.alive(), 120,
                read_log=lambda role: "Steam Client API initialized 0", sleep=lambda seconds: self.fail("must stop immediately"))

    def test_lan_voice_override_cannot_be_used_for_online_server(self):
        import io
        import session
        with patch("sys.argv", ["session.py", "--lan-no-voice", "--online-server"]), patch("sys.stderr", new=io.StringIO()):
            with self.assertRaises(SystemExit) as result:
                session.main()
        self.assertEqual(2, result.exception.code)

    def test_owned_client_exit_preserves_role_and_exit_code(self):
        from session import await_client_startup
        from types import SimpleNamespace
        dead = SimpleNamespace(poll=lambda: 42)
        with self.assertRaisesRegex(RuntimeError, r"Owned driver exited during engine startup \(42\)"):
            await_client_startup({"role": "driver"}, self.alive(), dead, 120,
                read_log=lambda role: "", sleep=lambda seconds: self.fail("must stop immediately"))


class NativeDeploymentTests(unittest.TestCase):
    def fixture(self, root):
        source, destination = root / "source", root / "game"
        source.mkdir()
        destination.mkdir()
        for name in ("dinput8.dll", "openxr_loader.dll"):
            (source / name).write_bytes(b"test native artifact")
        receipt = {"artifacts_sha256": {p.name: digest(p) for p in source.iterdir()}}
        return NativeDeployment(source, destination, root / "backup", receipt, digest)

    def test_loader_restored_and_owned_proxy_removed(self):
        with tempfile.TemporaryDirectory() as tmp:
            deployment = self.fixture(Path(tmp))
            loader = deployment.destination / "openxr_loader.dll"
            loader.write_bytes(b"original loader")
            deployment.install()
            self.assertEqual(deployment.restore(), [])
            self.assertEqual(loader.read_bytes(), b"original loader")
            self.assertFalse((deployment.destination / "dinput8.dll").exists())

    def test_existing_proxy_refused_without_modification(self):
        with tempfile.TemporaryDirectory() as tmp:
            deployment = self.fixture(Path(tmp))
            proxy = deployment.destination / "dinput8.dll"
            proxy.write_bytes(b"another session")
            with self.assertRaises(RuntimeError):
                deployment.install()
            self.assertEqual(proxy.read_bytes(), b"another session")

    def test_changed_proxy_preserved_for_review(self):
        with tempfile.TemporaryDirectory() as tmp:
            deployment = self.fixture(Path(tmp))
            deployment.install()
            proxy = deployment.destination / "dinput8.dll"
            proxy.write_bytes(b"changed externally")
            self.assertEqual(len(deployment.restore()), 1)
            self.assertEqual(proxy.read_bytes(), b"changed externally")

    @unittest.skipUnless(os.name == "nt", "Windows owned-process handles")
    def test_detached_watcher_cleans_owned_process_after_launcher_exit(self):
        from watchdog import api, creation_time
        parent = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
        child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
        try:
            with tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                record = root / "run.json"
                client = self.fixture(root)
                client.install()
                server_source, server_target = root / "server-source", root / "server"
                server_source.mkdir()
                server_target.mkdir()
                (server_source / "dinput8.dll").write_bytes(b"server adapter")
                (server_target / "openxr_loader.dll").write_bytes(b"unrelated loader")
                server = NativeDeployment(server_source, server_target, root / "server-backup",
                    {"artifacts_sha256": {"dinput8.dll": digest(server_source / "dinput8.dll")}}, digest, server=True)
                server.install()
                def deployment_record(deployment, is_server=False):
                    return {"source": str(deployment.source), "destination": str(deployment.destination),
                            "backup": str(deployment.backup), "receipt": deployment.receipt, "server": is_server}
                record.write_text(json.dumps({"roles": [{"pid": child.pid,
                    "creation_time": creation_time(api(), child._handle)}],
                    "native_deployment": deployment_record(client),
                    "server_native_deployment": deployment_record(server, True)}), encoding="utf-8")
                watcher = subprocess.Popen([sys.executable, str(Path(__file__).with_name("watchdog.py")), str(record), str(parent.pid)])
                parent.terminate()
                parent.wait(timeout=5)
                self.assertEqual(watcher.wait(timeout=10), 0)
                self.assertIsNotNone(child.poll())
                self.assertTrue(json.loads(record.read_text())["cleanup_complete"])
                self.assertFalse((client.destination / "dinput8.dll").exists())
                self.assertFalse((server_target / "dinput8.dll").exists())
                self.assertEqual((server_target / "openxr_loader.dll").read_bytes(), b"unrelated loader")
        finally:
            for process in (parent, child):
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=5)

    @unittest.skipUnless(os.name == "nt", "Windows owned-process handles")
    def test_watcher_does_not_stop_reused_pid_identity(self):
        parent = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
        child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
        try:
            with tempfile.TemporaryDirectory() as tmp:
                record = Path(tmp) / "run.json"
                record.write_text(json.dumps({"roles": [{"pid": child.pid, "creation_time": 1}]}), encoding="utf-8")
                watcher = subprocess.Popen([sys.executable, str(Path(__file__).with_name("watchdog.py")), str(record), str(parent.pid)])
                parent.terminate()
                parent.wait(timeout=5)
                self.assertEqual(watcher.wait(timeout=10), 0)
                self.assertIsNone(child.poll())
        finally:
            for process in (parent, child):
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=5)


class UnrealCommandTests(unittest.TestCase):
    def test_quotes_ini_value_for_unreal_raw_command_parser(self):
        command = unreal_command(Path("C:/Game Folder/KFGame.exe"), ["127.0.0.1:7777", "-ENGINEINI=C:/Friend Folder/KFEngine.ini", "-Port=7777"])
        self.assertIn('-ENGINEINI="C:/Friend Folder/KFEngine.ini"', command)
        self.assertNotIn('"-ENGINEINI=', command)
        self.assertTrue(command.startswith('"' + str(Path("C:/Game Folder/KFGame.exe")) + '"'))
        self.assertIn("-Port=7777", command)

    def test_rejects_embedded_quote(self):
        with self.assertRaises(ValueError):
            unreal_command(Path("KFGame.exe"), ['-ABSLOG=broken"path'])


class NetworkEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.server = """Log: KF2VRNet session world=7 protocol=1 revision=1 netmode=1
Log: KF2VRNet hello world=7 connection=2 accepted=true protocol=1 revision=1 netmode=1
Log: KF2VRNet authority world=7 connection=2 pawn=1 accepted=40 rejected=0 netmode=1
"""
        self.driver = "Log: KF2VRNet status world=7 connection=2 pawn=1 hello=true accepted=40 received=30 netmode=3"

    def test_real_bidirectional_driver_transport(self):
        result = verify_transport(self.server, self.driver)
        self.assertTrue(result["passed"])
        self.assertFalse(result["two_client_evidence"])

    def test_host_or_standalone_is_not_client_proof(self):
        for mode in ("0", "2", "NM_Standalone", "NM_ListenServer"):
            with self.subTest(mode=mode):
                self.assertFalse(verify_transport(self.server, self.driver.replace("netmode=3", f"netmode={mode}"))["passed"])

    def test_client_receipt_without_server_ingress_fails(self):
        self.assertFalse(verify_transport(self.server.replace("accepted=40", "accepted=0"), self.driver)["passed"])

    def test_mixed_lifetime_receipts_fail(self):
        self.assertFalse(verify_transport(self.server, self.driver.replace("world=7", "world=8"))["passed"])

    def test_driver_cannot_count_as_second_observer(self):
        self.assertFalse(verify_transport(self.server, self.driver, self.driver + " remote_poses=1")["passed"])

    def test_two_connections_and_remote_snapshot_required(self):
        server = self.server + "Log: KF2VRNet hello world=7 connection=3 accepted=true protocol=1 revision=1 netmode=1\n"
        observer = self.driver.replace("connection=2", "connection=3") + " remote_poses=1"
        self.assertTrue(verify_transport(server, self.driver, observer)["two_client_evidence"])
        self.assertFalse(verify_transport(server, self.driver, observer.replace("remote_poses=1", "remote_poses=0"))["passed"])


class MovementEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.server = "KF2VRNet session world=7 netmode=1\nKF2VRNet hello world=7 connection=2 accepted=true netmode=1\nKF2VRNet authority world=7 connection=2 pawn=1 accepted=40 netmode=1\n"
        self.server += "KF2VRNet movement phase=server world=7 connection=2 pawn=1 distance=100 x=100 y=0 z=0 netmode=1\n"
        self.driver = "KF2VRNet status world=7 connection=2 pawn=1 hello=true received=30 netmode=3\n"
        self.driver += "KF2VRNet movement phase=client world=7 connection=2 pawn=1 distance=102 x=102 y=0 z=0 dispatches=60 netmode=3\n"

    def test_native_movement_and_server_agree(self):
        self.assertTrue(verify_movement(self.server, self.driver)["passed"])

    def test_unreplicated_local_movement_fails(self):
        self.assertFalse(verify_movement(self.server.replace("distance=100", "distance=0"), self.driver)["passed"])

    def test_wrong_pawn_lifetime_fails(self):
        self.assertFalse(verify_movement(self.server.replace("phase=server world=7 connection=2 pawn=1", "phase=server world=7 connection=2 pawn=2"), self.driver)["passed"])

    def test_missing_native_dispatch_or_positions_fails(self):
        self.assertFalse(verify_movement(self.server, self.driver.replace("dispatches=60", "dispatches=0"))["passed"])
        self.assertFalse(verify_movement(self.server, self.driver.replace("x=102", ""))["passed"])


class VRControlsEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.server = ("KF2VRNet session world=7 netmode=1\n"
                       "KF2VRNet hello world=7 connection=2 accepted=true netmode=1\n"
                       "KF2VRNet authority world=7 connection=2 pawn=1 accepted=40 netmode=1\n")
        self.driver = "KF2VRNet status world=7 connection=2 pawn=1 hello=true received=30 netmode=3\n"
        self.driver += ("KF2VRNet vr_controls phase=switch_complete wanted=KFWeap_Healer_Syringe "
                        "equipped=KFWeap_Healer_Syringe held=KFWeap_Healer_Syringe agrees=True "
                        "switches=1 failures=0 independent=True netmode=3\n")
        self.driver += ("KF2VRNet vr_controls phase=switch_complete wanted=KF2VRNet9mm "
                        "equipped=KF2VRNet9mm held=KF2VRNet9mm agrees=True "
                        "switches=2 failures=0 independent=True netmode=3\n")

    def test_two_way_switch_passes(self):
        self.assertTrue(verify_vr_controls(self.server, self.driver)["passed"])

    def test_single_direction_fails(self):
        self.assertFalse(verify_vr_controls(self.server, self.driver.replace("switches=2", "switches=1"))["passed"])

    def test_registry_disagreement_fails(self):
        # The stock manager equipped it but the VR layer never bound it, which
        # is exactly the desync the network contract exists to prevent.
        self.assertFalse(verify_vr_controls(self.server, self.driver.replace("agrees=True", "agrees=False"))["passed"])

    def test_refused_draw_fails(self):
        self.assertFalse(verify_vr_controls(self.server, self.driver.replace("failures=0", "failures=1"))["passed"])

    def test_legacy_path_fails(self):
        # A pass must mean the modern stack ran, not the legacy single-weapon path.
        self.assertFalse(verify_vr_controls(self.server, self.driver.replace("independent=True", "independent=False"))["passed"])


class RoomMovementEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.server = ("KF2VRNet session world=7 netmode=1\n"
                       "KF2VRNet hello world=7 connection=2 accepted=true netmode=1\n"
                       "KF2VRNet authority world=7 connection=2 pawn=1 accepted=40 netmode=1\n")
        self.server += "KF2VRNet room_server phase=accepted dx=2.5 dy=0.0 elapsed=0.016 accepted=600 rejected=0 x=142.0 y=0.0 z=0.0 netmode=1\n"
        self.driver = "KF2VRNet status world=7 connection=2 pawn=1 hello=true received=30 netmode=3\n"
        self.driver += "KF2VRNet room_client phase=walking leg=0 travelled=1800.0 peak=122.0 drift=45.0 sent=640 corrections=6 x=145.0 y=0.0 z=0.0 netmode=3\n"

    def test_replicated_room_walk_passes(self):
        self.assertTrue(verify_room_movement(self.server, self.driver)["passed"])

    def test_rubber_banded_walk_fails(self):
        # Travel keeps growing while the server drags the pawn back, so only
        # the peak displacement distinguishes this from a working walk.
        self.assertFalse(verify_room_movement(self.server, self.driver.replace("peak=122.0", "peak=20.0"))["passed"])

    def test_server_dropping_displacement_fails(self):
        self.assertFalse(verify_room_movement(self.server.replace("accepted=600", "accepted=0"), self.driver)["passed"])

    def test_occasional_refusal_still_passes(self):
        # Refusing a move for a pawn that is momentarily not walking is the
        # clamp working, not a transport fault.
        self.assertTrue(verify_room_movement(self.server.replace("rejected=0", "rejected=1"), self.driver)["passed"])

    def test_refusing_most_moves_fails(self):
        self.assertFalse(verify_room_movement(self.server.replace("rejected=0", "rejected=40"), self.driver)["passed"])

    def test_constant_correction_fails(self):
        # The server disagreeing on most moves is the rubber-banding failure,
        # measured by the engine's own per-move position test.
        self.assertFalse(verify_room_movement(self.server, self.driver.replace("corrections=6", "corrections=400"))["passed"])

    def test_client_that_never_moved_fails(self):
        self.assertFalse(verify_room_movement(self.server, self.driver.replace("travelled=1800.0", "travelled=0.0"))["passed"])

    def test_diverged_positions_fail(self):
        self.assertFalse(verify_room_movement(self.server, self.driver.replace("x=145.0", "x=400.0"))["passed"])


class RoomClampEvidenceTests(unittest.TestCase):
    """The clamps only count as proven once an oversize packet reached them."""

    def setUp(self):
        self.server = ("KF2VRNet session world=7 netmode=1\n"
                       "KF2VRNet hello world=7 connection=2 accepted=true netmode=1\n"
                       "KF2VRNet authority world=7 connection=2 pawn=1 accepted=40 netmode=1\n")
        self.server += "KF2VRNet room_server phase=accepted dx=2.5 dy=0.0 elapsed=0.016 accepted=400 rejected=4 x=142.0 y=0.0 z=0.0 netmode=1\n"
        self.server += "KF2VRNet room_server phase=rejected_over_distance dx=19.8 dy=0.0 elapsed=0.016 accepted=401 rejected=5 x=142.0 y=0.0 z=0.0 netmode=1\n"
        self.server += "KF2VRNet room_server phase=rejected_over_speed dx=12.5 dy=0.0 elapsed=0.016 accepted=401 rejected=6 x=142.0 y=0.0 z=0.0 netmode=1\n"
        self.driver = "KF2VRNet status world=7 connection=2 pawn=1 hello=true received=30 netmode=3\n"
        self.driver += "KF2VRNet room_probe phase=over_distance requested=20.00 applied=19.80 frame=0.016 probes=1 sent=430 netmode=3\n"
        self.driver += "KF2VRNet room_probe phase=over_speed requested=12.50 applied=12.50 frame=0.016 probes=2 sent=460 netmode=3\n"
        self.driver += "KF2VRNet room_client phase=walking leg=0 travelled=1800.0 peak=122.0 drift=45.0 sent=470 corrections=9 x=145.0 y=0.0 z=0.0 netmode=3\n"

    def test_both_clamps_fire_passes(self):
        self.assertTrue(verify_room_clamp(self.server, self.driver)["passed"])

    def test_sweep_that_never_arrived_oversize_fails(self):
        # A sweep the geometry stopped short is correctly accepted, so it
        # cannot stand as evidence that the distance limit refuses anything.
        self.assertFalse(verify_room_clamp(
            self.server, self.driver.replace("applied=19.80", "applied=14.00"))["passed"])

    def test_physics_refusal_is_not_a_clamp_refusal(self):
        self.assertFalse(verify_room_clamp(
            self.server.replace("rejected_over_distance", "rejected_not_walking"), self.driver)["passed"])

    def test_missing_speed_refusal_fails(self):
        self.assertFalse(verify_room_clamp(
            self.server.replace("rejected_over_speed", "rejected_over_distance"), self.driver)["passed"])

    def test_burst_inside_the_frame_budget_proves_nothing(self):
        # 12.5 UU across a 60 ms frame is 208 UU/s, inside the 300 UU/s ceiling.
        # A refusal alongside it would have to have come from something else.
        self.assertFalse(verify_room_clamp(
            self.server, self.driver.replace("frame=0.016 probes=2", "frame=0.060 probes=2"))["passed"])

    def test_broken_transport_refusing_everything_fails(self):
        # The counters are cumulative and ride on every room_server line, so a
        # genuinely broken transport reads a low accept on all of them. Editing
        # one line and leaving the rest is not that log; the transport header is
        # left intact so the failure can only come from the clamp evidence.
        broken = "".join(line + "\n" for line in self.server.splitlines()
                         if "room_server" not in line)
        broken += "KF2VRNet room_server phase=rejected_over_distance dx=19.8 dy=0.0 elapsed=0.016 accepted=5 rejected=399 x=142.0 y=0.0 z=0.0 netmode=1\n"
        broken += "KF2VRNet room_server phase=rejected_over_speed dx=12.5 dy=0.0 elapsed=0.016 accepted=5 rejected=400 x=142.0 y=0.0 z=0.0 netmode=1\n"
        self.assertFalse(verify_room_clamp(broken, self.driver)["passed"])

    def test_unenforced_refusal_fails(self):
        # Refusing without ever correcting the client leaves the client holding
        # the displacement anyway, which makes the limit advisory.
        self.assertFalse(verify_room_clamp(
            self.server, self.driver.replace("corrections=9", "corrections=0"))["passed"])


class RoomResidualEvidenceTests(unittest.TestCase):
    """Nothing queued may survive a recenter or a respawn."""

    def setUp(self):
        self.server = ("KF2VRNet session world=7 netmode=1\n"
                       "KF2VRNet hello world=7 connection=2 accepted=true netmode=1\n"
                       "KF2VRNet authority world=7 connection=2 pawn=1 accepted=40 netmode=1\n")
        self.driver = "KF2VRNet status world=7 connection=2 pawn=1 hello=true received=30 netmode=3\n"
        self.driver += "KF2VRNet room_reset phase=recenter pending=8.00 active=0.00 resets=1 netmode=3\n"
        self.driver += "KF2VRNet room_residual phase=recenter queued=8.00 pending=0.00 active=0.00 moved=0.00 resets=1 netmode=3\n"
        self.driver += "KF2VRNet room_residual phase=recenter_settled queued=8.00 pending=0.00 active=0.00 moved=0.31 resets=1 netmode=3\n"
        self.driver += "KF2VRNet room_residual phase=dead_queued queued=6.00 pending=6.00 active=0.00 moved=0.00 resets=1 netmode=3\n"
        self.driver += "KF2VRNet room_reset phase=restart pending=6.00 active=0.00 resets=2 netmode=3\n"
        self.driver += "KF2VRNet room_residual phase=respawn queued=6.00 pending=6.00 active=0.00 moved=0.00 resets=2 netmode=3\n"
        self.driver += "KF2VRNet room_residual phase=respawn_settled queued=6.00 pending=0.00 active=0.00 moved=0.42 resets=2 netmode=3\n"

    def test_both_paths_clean_passes(self):
        self.assertTrue(verify_room_residual(self.server, self.driver)["passed"])

    def test_request_surviving_the_recenter_fails(self):
        self.assertFalse(verify_room_residual(
            self.server,
            self.driver.replace("phase=recenter queued=8.00 pending=0.00",
                                "phase=recenter queued=8.00 pending=8.00"))["passed"])

    def test_request_surviving_the_respawn_fails(self):
        self.assertFalse(verify_room_residual(
            self.server,
            self.driver.replace("phase=respawn_settled queued=6.00 pending=0.00",
                                "phase=respawn_settled queued=6.00 pending=6.00"))["passed"])

    def test_new_pawn_stepping_on_its_own_fails(self):
        # The exact failure this exists to catch: pending reads clean because
        # the first move after respawn already spent it on the new body.
        self.assertFalse(verify_room_residual(
            self.server, self.driver.replace("moved=0.42", "moved=5.90"))["passed"])

    def test_nothing_stranded_proves_nothing(self):
        self.assertFalse(verify_room_residual(
            self.server,
            self.driver.replace("phase=dead_queued queued=6.00 pending=6.00",
                                "phase=dead_queued queued=0.00 pending=0.00"))["passed"])

    def test_clear_that_discarded_nothing_fails(self):
        # Without a reset recording a live request, a clean respawn could just
        # mean something else had already drained it.
        self.assertFalse(verify_room_residual(
            self.server, self.driver.replace("phase=restart pending=6.00", "phase=restart pending=0.00"))["passed"])

    def test_recenter_only_run_skips_the_respawn_half(self):
        recenter_only = "".join(line + "\n" for line in self.driver.splitlines()
                                if not any(mark in line for mark in
                                           ("respawn", "dead_queued", "phase=restart")))
        self.assertTrue(verify_room_residual(self.server, recenter_only, respawn_required=False)["passed"])
        self.assertFalse(verify_room_residual(self.server, recenter_only)["passed"])


class DamageEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.server = "KF2VRNet session world=7 netmode=1\nKF2VRNet hello world=7 connection=2 accepted=true netmode=1\nKF2VRNet authority world=7 connection=2 pawn=1 accepted=40 netmode=1\n"
        self.server += "KF2VRNet target_spawn target=w7-c2-p1 health=100 netmode=1\n"
        self.server += "KF2VRNet target_damage target=w7-c2-p1 receipt=1 before=100 after=0 damage=100 dead=true netmode=1\n"
        self.server += "KF2VRNet impact target=w7-c2-p1 netmode=1\n"
        self.server += "KF2VRNet target_death target=w7-c2-p1 accepted=true played=true netmode=1\n"
        self.driver = "KF2VRNet status world=7 connection=2 pawn=1 hello=true received=30 netmode=3\n"
        self.driver += "KF2VRNet local_hit target=w7-c2-p1 netmode=3\n"
        self.driver += "KF2VRNet target_state target=w7-c2-p1 receipt=1 health=0 dead=true netmode=3\n"
        self.driver += "KF2VRNet target_death target=w7-c2-p1 accepted=true played=true netmode=3\n"

    def test_real_hit_server_death_and_client_receipt(self):
        self.assertTrue(verify_damage(self.server, self.driver)["passed"])

    def test_local_actor_names_may_differ_across_three_processes(self):
        server = self.server.replace("target=w7-c2-p1", "target=w7-c2-p1 actor=Clot_0")
        driver = self.driver.replace("target=w7-c2-p1", "target=w7-c2-p1 actor=Clot_2")
        observer = ("KF2VRNet status world=7 connection=3 pawn=1 hello=true remote_poses=1 received=30 netmode=3\n"
                    + driver[driver.index("KF2VRNet target_state"):].replace("Clot_2", "Clot_9"))
        server += "KF2VRNet hello world=7 connection=3 accepted=true netmode=1\n"
        self.assertTrue(verify_damage(server, driver, observer)["passed"])
        self.assertFalse(verify_damage(server, driver, observer.replace("target=w7-c2-p1", "target=w7-c2-p2"))["passed"])

    def test_target_identity_must_match_driver_lifetime(self):
        for wrong in ("w8-c2-p1", "w7-c3-p1", "w7-c2-p2", "Clot_0", ""):
            with self.subTest(target=wrong):
                self.assertFalse(verify_damage(self.server.replace("w7-c2-p1", wrong),
                                               self.driver.replace("w7-c2-p1", wrong))["passed"])

    def test_same_actor_name_cannot_hide_wrong_target_identity(self):
        self.assertFalse(verify_damage(self.server.replace("target=w7-c2-p1", "target=w7-c2-p1 actor=Clot_0"),
            self.driver.replace("target=w7-c2-p1", "target=w7-c2-p2 actor=Clot_0"))["passed"])

    def test_server_death_without_client_receipt_fails(self):
        self.assertFalse(verify_damage(self.server, self.driver.replace("health=0", "health=1"))["passed"])

    def test_local_hit_without_server_impact_fails(self):
        self.assertFalse(verify_damage(self.server.replace("KF2VRNet impact", "unused"), self.driver)["passed"])

    def test_duplicate_damage_receipt_fails(self):
        self.assertFalse(verify_damage(self.server + "KF2VRNet target_damage target=w7-c2-p1 receipt=1 before=100 after=0 damage=100 dead=true netmode=1\n", self.driver)["passed"])

    def test_missing_health_is_not_zero_health(self):
        self.assertFalse(verify_damage(self.server.replace("after=0", ""), self.driver)["passed"])

    def test_zero_health_without_actual_client_death_fails(self):
        self.assertFalse(verify_damage(self.server, self.driver.replace("played=true", "played=false"))["passed"])


class FireReloadEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.server = "KF2VRNet session world=7 netmode=1\nKF2VRNet hello world=7 connection=2 accepted=true netmode=1\nKF2VRNet authority world=7 connection=2 pawn=1 accepted=40 netmode=1\n"
        self.driver = "KF2VRNet status world=7 connection=2 pawn=1 hello=true received=30 netmode=3\n"
        details = ["phase=equip ammo=15 spare=75"]
        details += [f"phase=shot pulse={i} ammo_before={16-i} ammo_after={15-i} start_calls={i} aim_calls={i}" for i in range(1, 6)]
        details += ["phase=reload ammo_before=10 spare_before=75", "phase=complete pulses=5 ammo=15 spare=70", "phase=stopped reason=complete"]
        self.driver += "\n".join("KF2VRNet fire_fixture world=7 connection=2 pawn=1 weapon=Test9mm netmode=3 " + d for d in details)

    def test_complete_cycle_is_not_damage_proof(self):
        result = verify_fire_reload(self.server, self.driver)
        self.assertTrue(result["passed"])
        self.assertFalse(result["damage_tested"])

    def test_connection_alone_is_not_firing(self):
        self.assertFalse(verify_fire_reload(self.server, self.driver.split("KF2VRNet fire_fixture", 1)[0])["passed"])

    def test_stock_aim_fallback_cannot_pass_pose_test(self):
        self.assertFalse(verify_fire_reload(self.server, self.driver.replace("aim_calls=3", "aim_calls=2"))["passed"])

    def test_no_ammo_consumption_cannot_pass(self):
        self.assertFalse(verify_fire_reload(self.server, self.driver.replace("ammo_after=14", "ammo_after=15"))["passed"])

    def test_reload_cannot_create_free_ammo(self):
        self.assertFalse(verify_fire_reload(self.server, self.driver.replace("spare=70", "spare=75"))["passed"])

    def test_old_pawn_completion_cannot_finish_current_pawn(self):
        self.assertFalse(verify_fire_reload(self.server, self.driver.replace("pawn=1 weapon=Test9mm netmode=3 phase=complete", "pawn=2 weapon=Test9mm netmode=3 phase=complete"))["passed"])

    def test_early_stop_or_missing_fields_fail(self):
        for changed in (self.driver.replace("reason=complete", "reason=weapon_changed"),
                        self.driver.replace("spare_before=75", "spare_before=unknown"),
                        self.driver.replace("ammo_after=14", "")):
            with self.subTest(log=changed):
                self.assertFalse(verify_fire_reload(self.server, changed)["passed"])


class RecoveryEvidenceTests(unittest.TestCase):
    def setUp(self):
        fire = FireReloadEvidenceTests()
        fire.setUp()
        self.server = fire.server + "KF2VRNet expiry world=7 connection=2 pawn=1\n"
        self.server += "KF2VRNet movement phase=server world=7 connection=2 pawn=1 distance=100 x=100 y=0 z=0 netmode=1\n"
        self.driver = "KF2VRNet dropout phase=paused world=7 connection=2 pawn=1 sequence=41 time=10 netmode=3\n"
        self.driver += fire.driver + "\n"
        self.driver += "KF2VRNet native_frame valid=3 calibrated=true connection=2 samples=100\n" * 2
        self.driver += "KF2VRNet movement phase=client world=7 connection=2 pawn=1 distance=102 x=102 y=0 z=0 dispatches=60 netmode=3\n"
        self.driver += "KF2VRNet dropout phase=resumed world=7 connection=2 pawn=1 sequence=41 time=28 netmode=3\n"
        self.observer = "KF2VRNet freshness world=7 connection=2 pawn=1 observer=3 fresh=true sequence=39 netmode=3\n"
        self.observer += "KF2VRNet freshness world=7 connection=2 pawn=1 observer=3 fresh=false sequence=40 netmode=3\n"
        self.observer += "KF2VRNet freshness world=7 connection=2 pawn=1 observer=3 fresh=true sequence=42 netmode=3\n"

    def test_complete_dropout_preserves_local_combat_and_recovers(self):
        self.assertTrue(verify_pose_dropout(self.server, self.driver, self.observer)["passed"])
        self.assertTrue(verify_pose_dropout(self.server, self.driver, self.observer.replace("sequence=42", "sequence=41"))["passed"])

    def test_input_outside_dropout_is_not_continuity_proof(self):
        moved = self.driver.replace("KF2VRNet dropout phase=resumed", "KF2VRNet dropout phase=ignored")
        moved = "KF2VRNet dropout phase=resumed world=7 connection=2 pawn=1 sequence=41 time=28 netmode=3\n" + moved
        self.assertFalse(verify_pose_dropout(self.server, moved, self.observer)["passed"])

    def test_wrong_observer_or_lifetime_and_no_recovery_fail(self):
        for changed in (self.observer.replace("observer=3", "observer=2"),
                        self.observer.replace("pawn=1", "pawn=2"),
                        self.observer.replace("fresh=true sequence=42", "fresh=false sequence=42"),
                        self.observer.replace("sequence=40", "sequence=10")):
            with self.subTest(log=changed):
                self.assertFalse(verify_pose_dropout(self.server, self.driver, changed)["passed"])

    def reconnect_logs(self):
        server = self.server + "KF2VRNet hello world=7 connection=3 accepted=true netmode=1\n"
        server += "KF2VRNet hello world=7 connection=4 accepted=true netmode=1\n"
        server += "KF2VRNet channel_destroyed world=7 connection=3 pawn=0 netmode=1\n"
        old = "KF2VRNet status world=7 connection=3 pawn=0 hello=true netmode=3\n"
        new = "KF2VRNet status world=7 connection=4 pawn=0 hello=true remote_poses=1 received=30 netmode=3\n"
        new += "KF2VRNet freshness world=7 connection=2 pawn=1 observer=4 fresh=true sequence=100 netmode=3\n"
        return server, old, new

    def test_reconnect_requires_new_handshake_and_old_channel_cleanup(self):
        server, old, new = self.reconnect_logs()
        self.assertTrue(verify_reconnect(server, self.driver, old, new)["passed"])
        self.assertFalse(verify_reconnect(server.replace("channel_destroyed", "ignored"), self.driver, old, new)["passed"])
        self.assertFalse(verify_reconnect(server, self.driver, old, new.replace("connection=4", "connection=3"))["passed"])

    def test_disconnect_requires_actual_remote_actor_removal(self):
        server, old, new = self.reconnect_logs()
        server += "KF2VRNet channel_destroyed world=7 connection=2 pawn=1 netmode=1\n"
        new += "KF2VRNet pose_destroyed world=7 connection=2 pawn=1 observer=4 netmode=3\n"
        new += "KF2VRNet status world=7 connection=4 pawn=0 hello=true public_poses=0 netmode=3\n"
        self.assertTrue(verify_disconnect_cleanup(server, self.driver, new)["passed"])
        self.assertFalse(verify_disconnect_cleanup(server, self.driver, new.replace("pose_destroyed", "ignored"))["passed"])
        self.assertFalse(verify_disconnect_cleanup(server, self.driver, new.replace("public_poses=0", "public_poses=1"))["passed"])


class LifecycleEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.server = "KF2VRNet session world=7 netmode=1\n"
        for detail in ("death_begin pawn=1 living=2", "dead pawn=0 living=1 health=-1 played=true",
                       "respawn pawn=2 trader=true", "trader_before pawn=2 armor=0 dosh=500",
                       "trader_after pawn=2 armor=10 dosh=470 menu=true", "trader_closed pawn=2 menu=false",
                       "travel_begin pawn=2 destination=KF-Outpost"):
            self.server += "KF2VRNet lifecycle world=7 connection=1 phase=" + detail + "\n"
        self.server += "KF2VRNet session world=8 netmode=1\nKF2VRNet lifecycle phase=travel_complete map=KF-Outpost\n"
        self.driver = "KF2VRNet status world=7\nKF2VRNet lifecycle phase=dead health=-1 played=true\n"
        self.driver += "KF2VRNet fire_fixture phase=complete pawn=1\nKF2VRNet fire_fixture phase=complete pawn=2\n"
        self.driver += "KF2VRNet lifecycle phase=trader_before armor=0 dosh=500 menu=true\n"
        self.driver += "KF2VRNet lifecycle phase=trader_after armor=10 dosh=470\nKF2VRNet lifecycle phase=trader_closed menu=false\n"
        self.driver += "KF2VRNet status world=8\n"
        self.observer = "KF2VRNet status world=7\nKF2VRNet pose_destroyed connection=1 pawn=1\n"
        self.observer += "KF2VRNet freshness connection=1 pawn=2 fresh=true\nKF2VRNet status world=8\n"

    def verify(self, server=None, driver=None, observer=None):
        # Combat validators have independent negative tests; isolate lifecycle
        # evidence here so missing death/purchase/travel cannot borrow a pass.
        with patch("evidence.verify_fire_reload", return_value={"passed": True}), \
             patch("evidence.verify_damage", return_value={"passed": True}), \
             patch("evidence.verify_movement", return_value={"passed": True}):
            return verify_lifecycle(server or self.server, driver or self.driver, observer or self.observer)

    def test_complete_lifecycle(self):
        self.assertTrue(self.verify()["passed"])

    def test_reused_pawn_or_world_fails(self):
        self.assertFalse(self.verify(server=self.server.replace("respawn pawn=2", "respawn pawn=1"))["passed"])
        self.assertFalse(self.verify(server=self.server.replace("world=8", "world=7"))["passed"])

    def test_missing_client_death_or_remote_cleanup_fails(self):
        self.assertFalse(self.verify(driver=self.driver.replace("played=true", "played=false"))["passed"])
        self.assertFalse(self.verify(observer=self.observer.replace("pose_destroyed", "ignored"))["passed"])

    def test_free_armor_or_unreplicated_purchase_fails(self):
        self.assertFalse(self.verify(server=self.server.replace("dosh=470", "dosh=500"))["passed"])
        self.assertFalse(self.verify(driver=self.driver.replace("armor=10", "armor=9"))["passed"])

    def test_world_sections_do_not_mix_reused_actor_names(self):
        server = "KF2VRNet session world=7\nactor=Clot_0 receipt=1\nKF2VRNet session world=8\nactor=Clot_0 receipt=2\n"
        client = "KF2VRNet status world=7\nold_hit\nKF2VRNet status world=8\nnew_hit\n"
        a, b, c = world_logs(server, client, client, "8")
        self.assertNotIn("receipt=1", a)
        self.assertIn("receipt=2", a)
        self.assertNotIn("old_hit", b)
        self.assertIn("new_hit", c)
        self.assertEqual(world_logs(server, client, None, "9"), ("", "", None))


class ConfigurationTests(unittest.TestCase):
    def test_replaces_vac_preserves_unrelated_configuration(self):
        original = "[Steam]\r\nbUseVAC=true\r\n+Paths=old\r\nProfile=keep\r\n[Other]\r\nbUseVAC=true\r\n"
        result = set_ini(original, "Steam", {"bUseVAC": "false", "Paths": [r"D:\name$literal", "stock"]})
        self.assertIn("bUseVAC=false", result)
        self.assertIn("Profile=keep", result)
        self.assertIn("[Other]\r\nbUseVAC=true", result)
        self.assertNotIn("+Paths=old", result)
        self.assertIn(r"Paths=D:\name$literal", result)

    def test_duplicate_sections_fail_without_guessing(self):
        with self.assertRaises(ValueError):
            set_ini("[Steam]\nbUseVAC=true\n[Steam]\nbUseVAC=false\n", "Steam", {"bUseVAC": "false"})

    def test_missing_section_and_no_final_newline(self):
        self.assertIn("[Network]\nPort=17777\n", set_ini("[Other]\nFoo=1", "Network", {"Port": "17777"}))
        self.assertEqual("[Network]\nPort=17777\n", set_ini("[Network]", "Network", {"Port": "17777"}))


class ServerQueryTests(unittest.TestCase):
    def packet(self, secure):
        return b"\xff\xff\xff\xffI\x11" + b"fixture\0KF-BurningParis\0kf2\0Killing Floor 2\0" + struct.pack("<H7B", 35482, 1, 6, 0, ord("d"), ord("w"), 1, secure) + b"1.0\0"

    def test_secure_and_insecure_flag_are_distinct(self):
        self.assertFalse(parse_info(self.packet(0))["secure"])
        self.assertTrue(parse_info(self.packet(1))["secure"])

    def test_missing_or_malformed_security_never_defaults_false(self):
        for packet in (b"", b"\xff\xff\xff\xffA1234", self.packet(0)[:20], self.packet(0)[:-7], self.packet(3)):
            with self.subTest(packet=packet):
                with self.assertRaises(ValueError):
                    parse_info(packet)


if __name__ == "__main__":
    unittest.main()
