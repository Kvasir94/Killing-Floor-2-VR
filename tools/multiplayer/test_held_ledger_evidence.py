import unittest

from evidence import (HELD_LEDGER_CASES, SERVER_PENDING_CASES, HELD_NETWORK_CASES,
                      DUAL_WEAPON_PHASES, verify_held_ledger, verify_server_pending, verify_held_network, verify_dual_weapons, verify_dual_damage, verify_remote_weapons, verify_dual_vr_owners)
from native_fixture import NativeDeployment
from session import digest
from pathlib import Path
import tempfile


def probe(pawn="Pawn_1", cases=HELD_LEDGER_CASES, mode="1"):
    return "\n".join(f"KF2VRNet held_ledger case={case} passed=true pawn={pawn} netmode={mode}"
                     for case in cases)


class HeldLedgerEvidenceTests(unittest.TestCase):
    def test_second_active_owner_damage_failure_rejects_session(self):
        server, clients = [], [[], []]
        for index, connection in enumerate((1, 2)):
            identity = f"world=100 connection={connection} pawn=1"
            clients[index].extend(f"KF2VRNet dual_weapon phase={phase} passed=true {identity} netmode=3"
                                  for phase in DUAL_WEAPON_PHASES)
            server.extend(f"KF2VRNet dual_weapon_server phase={phase} {identity} left_ammo=10 right_ammo=6 "
                          "client_left=10 client_right=6 native_fault=0 netmode=1" for phase in DUAL_WEAPON_PHASES[1:])
            for hand, name, weapon in ((0, "left", "KF2VRNet9mm"), (1, "right", "KFWeap_Shotgun_MB500")):
                target = f"w100-c{connection}-p1-{name}"
                server.append(f"KF2VRNet target_damage target={target} weapon={weapon}_0 "
                              "receipt=1 before=100 after=50 damage=50 netmode=1")
                clients[1 - index].append(f"KF2VRNet target_state target={target} receipt=1 health=50 netmode=3")
                clients[1 - index].append(f"KF2VRNet remote_weapon {identity} hand={hand} weapon={weapon} "
                    "ready=true muzzle_error=0.001 bore_error=0.01 shots=1 shot_sequence=2 reloads=1 netmode=3")
        driver, observer = ("\n".join(lines) for lines in clients)
        self.assertTrue(verify_dual_vr_owners("\n".join(server), driver, observer)["passed"])
        missing_second_damage = "\n".join(line for line in server if "target=w100-c2-" not in line)
        result = verify_dual_vr_owners(missing_second_damage, driver, observer)
        self.assertTrue(result["driver_damage"]["passed"])
        self.assertTrue(result["observer_combat"]["passed"])
        self.assertFalse(result["observer_damage"]["passed"])
        self.assertFalse(result["passed"])

    def test_remote_weapons_need_both_aligned_animated_guns_on_same_pawn(self):
        driver = "KF2VRNet dual_weapon phase=ready world=100 connection=1 pawn=1"
        observer = "\n".join(f"KF2VRNet remote_weapon world=100 connection=1 pawn=1 hand={hand} "
                             f"weapon={weapon} ready=true muzzle_error=0.001 bore_error=0.01 shots=1 shot_sequence=2 reloads=1 netmode=3"
                             for hand, weapon in ((0, "KF2VRNet9mm"), (1, "KFWeap_Shotgun_MB500")))
        self.assertTrue(verify_remote_weapons(driver, observer)["passed"])
        for bad in (None, observer.splitlines()[0], observer.replace("pawn=1", "pawn=2"),
                    observer.replace("muzzle_error=0.001", "muzzle_error=nan"),
                    observer.replace("shots=1", "shots=0"), observer.replace("reloads=1", "reloads=0"),
                    observer.replace("shot_sequence=2", "shot_sequence=1")):
            self.assertFalse(verify_remote_weapons(driver, bad)["passed"])

    def test_dual_damage_correlates_weapon_target_and_remote_health(self):
        driver = "KF2VRNet dual_weapon phase=ready passed=true world=100 connection=1 pawn=1 netmode=3"
        server = "\n".join(f"KF2VRNet target_damage target=w100-c1-p1-{hand} weapon={weapon}_0 "
                           "receipt=1 before=100 after=50 damage=50 netmode=1"
                           for hand, weapon in (("left", "KF2VRNet9mm"), ("right", "KFWeap_Shotgun_MB500")))
        observer = "\n".join(f"KF2VRNet target_state target=w100-c1-p1-{hand} receipt=1 health=50 netmode=3"
                             for hand in ("left", "right"))
        self.assertTrue(verify_dual_damage(server, driver, observer)["passed"])
        self.assertFalse(verify_dual_damage(server.replace("KF2VRNet9mm", "KFWeap_Shotgun_MB500"), driver, observer)["passed"])
        self.assertFalse(verify_dual_damage(server, driver, observer.replace("health=50", "health=100"))["passed"])
        self.assertFalse(verify_dual_damage(server.replace("before=100", "before=50"), driver, observer)["passed"])

    def test_dual_gameplay_evidence_requires_server_ammo_agreement(self):
        identity = "world=100 connection=1 pawn=1"
        driver = "\n".join(f"KF2VRNet dual_weapon phase={phase} passed=true {identity} netmode=3"
                           for phase in DUAL_WEAPON_PHASES)
        server = "\n".join(f"KF2VRNet dual_weapon_server phase={phase} {identity} left_ammo=10 right_ammo=6 "
                           "client_left=10 client_right=6 native_fault=0 netmode=1" for phase in DUAL_WEAPON_PHASES[1:])
        self.assertTrue(verify_dual_weapons(server, driver)["passed"])
        for wrong in ("", server.replace("client_left=10", "client_left=9"),
                      server.replace("left_ammo=10", ""), server.replace("connection=1", "connection=2")):
            self.assertFalse(verify_dual_weapons(wrong, driver)["passed"])
        self.assertFalse(verify_dual_weapons(server, driver.replace("phase=both_fire passed=true", "phase=both_fire passed=false"))["passed"])

    def test_network_evidence_needs_matching_real_server_and_client(self):
        identity = "world=100 connection=1 pawn=1"
        driver = "\n".join(f"KF2VRNet held_network case={case} passed=true {identity} request={request} netmode=3"
                           for case, request in zip(HELD_NETWORK_CASES, (0, 2, 3, 4, 5, 6)))
        server = "\n".join(f"KF2VRNet held_command {identity} request={request} accepted={str(request != 3).lower()} netmode=1"
                           for request in range(1, 7))
        self.assertTrue(verify_held_network(server, driver)["passed"])
        for wrong in ("", server.replace("connection=1", "connection=2"), server.replace("netmode=1", "netmode=3")):
            self.assertFalse(verify_held_network(wrong, driver)["passed"])
        self.assertFalse(verify_held_network(server, driver.replace("case=hand_swap passed=true", "case=hand_swap passed=false"))["passed"])
        self.assertFalse(verify_held_network(server, driver + "\n" + driver)["passed"])

    def test_complete_server_probe(self):
        self.assertTrue(verify_held_ledger(probe())["passed"])

    def test_missing_duplicate_reordered_or_failed_rows_rejected(self):
        for case in HELD_LEDGER_CASES:
            with self.subTest(case=case):
                self.assertFalse(verify_held_ledger(probe(cases=[c for c in HELD_LEDGER_CASES if c != case]))["passed"])
                self.assertFalse(verify_held_ledger(probe() + "\n" + probe(cases=[case]))["passed"])
                self.assertFalse(verify_held_ledger(probe().replace(f"case={case} passed=true", f"case={case} passed=false"))["passed"])
        self.assertFalse(verify_held_ledger(probe(cases=reversed(HELD_LEDGER_CASES)))["passed"])

    def test_no_evidence_or_client_only_rejected(self):
        self.assertFalse(verify_held_ledger("")["passed"])
        self.assertFalse(verify_held_ledger(probe(mode="3"))["passed"])

    def test_different_pawns_cannot_fill_gaps(self):
        self.assertFalse(verify_held_ledger(probe(cases=HELD_LEDGER_CASES[:6]) + "\n"
                                          + probe("Pawn_2", HELD_LEDGER_CASES[6:]))["passed"])
        self.assertFalse(verify_held_ledger(probe() + "\n" + probe("Pawn_2", HELD_LEDGER_CASES[:6]))["passed"])

    def test_server_pending_requires_all_real_server_cases(self):
        log = probe(cases=SERVER_PENDING_CASES).replace("held_ledger", "server_pending")
        self.assertTrue(verify_server_pending(log)["passed"])
        self.assertFalse(verify_server_pending(log.replace("netmode=1", "netmode=3"))["passed"])
        for case in SERVER_PENDING_CASES:
            with self.subTest(case=case):
                self.assertFalse(verify_server_pending(log.replace(f"case={case} passed=true", f"case={case} passed=false"))["passed"])
                self.assertFalse(verify_server_pending("\n".join(line for line in log.splitlines() if f"case={case} " not in line))["passed"])
        self.assertFalse(verify_server_pending(log + "\n" + log)["passed"])

    def test_server_deployment_only_touches_server_proxy(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source, destination = root / "source", root / "server"
            source.mkdir()
            destination.mkdir()
            (source / "dinput8.dll").write_bytes(b"server adapter")
            (destination / "openxr_loader.dll").write_bytes(b"unrelated")
            receipt = {"artifacts_sha256": {"dinput8.dll": digest(source / "dinput8.dll")}}
            deployment = NativeDeployment(source, destination, root / "backup", receipt, digest, server=True)
            deployment.install()
            self.assertEqual((destination / "dinput8.dll").read_bytes(), b"server adapter")
            self.assertEqual(deployment.restore(), [])
            self.assertFalse((destination / "dinput8.dll").exists())
            self.assertEqual((destination / "openxr_loader.dll").read_bytes(), b"unrelated")
