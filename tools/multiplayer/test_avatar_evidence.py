"""A preview receipt must not turn missing or contradictory telemetry green."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from avatar_evidence import classify_warnings, summarize_log, summarize_session


def preview_log():
    lines = []
    for time, samples in ((0, 0), (1, 10), (4, 40), (7, 70)):
        common = f"world=17 connection=2 pawn=1 reference=0 source=Human_0 time={time}"
        lines.append("KF2VRNet avatar_preview_frame " + common
            + f" ready=true fresh=true noncolliding=true unique_tree=true source_unchanged=true samples={samples}"
            + " flags=7 alpha=1 saved_atoms=70 right_contact=true left_error=0.8 right_error=0.9"
            + " left_solve_error=0.5 right_solve_error=0.5 head_degrees=0.3 head_position_error=4"
            + " left_reach_clamp=0 right_reach_clamp=0")
        lines.append("KF2VRNet avatar_weapon_preview " + common
            + f" ready=true effective_muzzle=true noncolliding=true physics_asset=false placements={samples} muzzle_error=0.2 bore_error_deg=0.4")
    return "\n".join(lines)


class AvatarEvidenceTests(unittest.TestCase):
    def test_hidden_never_acquired_initial_frame_is_retained_in_acquisition(self):
        lines = preview_log().splitlines()
        lines[0] = lines[0].replace("fresh=true", "fresh=false").replace("flags=7", "flags=0").replace("alpha=1", "alpha=0")
        result = summarize_log("\n".join(lines))
        self.assertTrue(result["telemetry_passed"])
        acquisition = result["lifetimes"][0]["acquisition"]
        self.assertEqual(1, acquisition["initial_never_acquired_count"])
        self.assertEqual("0", acquisition["initial_never_acquired_reports"][0]["flags"])

    def test_loss_after_first_tracking_is_not_exempt_even_in_first_second(self):
        lines = preview_log().splitlines()
        loss = lines[0].replace("time=0", "time=0.5").replace("samples=0", "samples=5")
        loss = loss.replace("fresh=true", "fresh=false").replace("flags=7", "flags=0").replace("alpha=1", "alpha=0")
        lines.insert(2, loss)
        result = summarize_log("\n".join(lines))
        self.assertFalse(result["telemetry_passed"])
        self.assertEqual(0, result["lifetimes"][0]["acquisition"]["initial_never_acquired_count"])

    def test_initial_empty_exception_needs_hidden_full_blank_and_bounded_time(self):
        for changes in (("alpha=1", "alpha=0.2"), ("flags=7", "flags=3")):
            lines = preview_log().splitlines()
            lines[0] = lines[0].replace("fresh=true", "fresh=false")
            lines[0] = lines[0].replace(*changes)
            self.assertFalse(summarize_log("\n".join(lines))["telemetry_passed"])
        never_acquired = preview_log().replace("fresh=true", "fresh=false").replace("flags=7", "flags=0").replace("alpha=1", "alpha=0")
        result = summarize_log(never_acquired)
        self.assertFalse(result["telemetry_passed"])
        self.assertEqual(1, result["lifetimes"][0]["acquisition"]["initial_never_acquired_count"])

    def test_known_stock_warning_keeps_stack_and_only_gets_fixed_startup_window(self):
        warning = "[{time:07.2f}] ScriptWarning: Accessed None\n\tKFGFxHUD_ObjectiveConatiner Transient.HUD_0\n\tFunction KFGame.KFGFxHUD_ObjectiveConatiner:SetActive:01D9\n"
        bound = "[0100.00] ScriptLog: KF2VRNet avatar_preview_bound world=17 connection=2 pawn=1\n"
        result = classify_warnings(warning.format(time=99) + bound + warning.format(time=100.5) + warning.format(time=101.01))
        self.assertEqual(3, result["occurrences"])
        self.assertEqual(2, result["known_stock_startup_occurrences"])
        self.assertEqual(1, result["blocking_occurrences"])
        self.assertEqual(101, result["known_startup_deadline_log_time"])
        self.assertTrue(all(record["context"] for record in result["records"]))

    def test_known_function_does_not_exempt_unknown_message_or_mod_stack(self):
        bound = "[0100.00] ScriptLog: KF2VRNet avatar_preview_bound world=17 connection=2 pawn=1\n"
        for message, function in (("Accessed None 'DifferentField'", "KFGame.KFGFxHUD_ObjectiveConatiner:SetActive:01D9"),
                                  ("Accessed None", "KF2VRNet.KF2VRNetPlayerController:Tick:0001"),
                                  ("Accessed None", "KF2VRNet.KF2VRNetAvatarPreview:Tick:0001")):
            result = classify_warnings("[0099.00] ScriptWarning: " + message + "\n\tFunction " + function + "\n" + bound)
            self.assertEqual(1, result["blocking_occurrences"])
        self.assertEqual(1, classify_warnings("[0099.00] ScriptWarning: Accessed None\n" + bound)["blocking_occurrences"])

    def test_spawn_failure_and_unknown_errors_block_even_before_binding(self):
        log = ("[0099.00] Warning: SpawnActor failed because class KF2VRNetAvatarCamera has bNoDelete\n"
               "[0099.10] Error: Unrecognized native failure\n"
               "[0100.00] ScriptLog: KF2VRNet avatar_preview_bound world=17 connection=2 pawn=1\n")
        result = classify_warnings(log)
        self.assertEqual(2, result["blocking_occurrences"])
        self.assertEqual(0, result["known_stock_startup_occurrences"])

    def test_resource_warnings_remain_reported_with_existing_severity_policy(self):
        result = classify_warnings("[0001.00] Warning: Failed to load a font\n[0001.10] Warning: Failed to load a font\n")
        self.assertEqual(2, result["occurrences"])
        self.assertEqual(0, result["blocking_occurrences"])
        self.assertEqual([1, 2], result["records"][0]["line_numbers"])

    def test_verified_platform_error_has_only_fixed_startup_exception(self):
        log = ("[0099.00] Error: WriteOnlineStats: SessionHasStats is FALSE\n"
               "[0099.10] DevOnline: [EOS Users] Query external account mappings error: 22\n"
               "[0100.00] ScriptLog: KF2VRNet avatar_preview_bound world=17 connection=2 pawn=1\n"
               "[0101.01] Error: WriteOnlineStats: SessionHasStats is FALSE\n")
        result = classify_warnings(log)
        self.assertEqual(3, result["occurrences"])
        self.assertEqual(1, result["known_stock_startup_platform_error_occurrences"])
        self.assertEqual(1, result["blocking_occurrences"])

    def test_first_second_contact_and_blend_acquisition_is_visible(self):
        lines = preview_log().splitlines()
        lines[0] = lines[0].replace("alpha=1", "alpha=0.2").replace("right_contact=true", "right_contact=false").replace("head_degrees=0.3", "head_degrees=30").replace("right_error=0.9", "right_error=20")
        lines[1] = lines[1].replace("ready=true", "ready=false").replace("effective_muzzle=true", "effective_muzzle=false")
        result = summarize_log("\n".join(lines))
        self.assertTrue(result["telemetry_passed"])
        acquisition = result["lifetimes"][0]["acquisition"]
        self.assertEqual(1, acquisition["steady_from_time"])
        self.assertEqual("30", acquisition["reports"]["body"][0]["head_degrees"])
        self.assertEqual(3, result["lifetimes"][0]["body"]["reports"])
        self.assertEqual(60, result["lifetimes"][0]["body"]["new_samples"])

    def test_late_fade_contact_loss_and_bad_geometry_are_never_excluded(self):
        for old, new in (("alpha=1", "alpha=0.8"), ("right_contact=true", "right_contact=false"),
                         ("right_error=0.9", "right_error=20")):
            lines = preview_log().splitlines()
            lines[2] = lines[2].replace(old, new)  # Exactly first-ready + 1 second.
            result = summarize_log("\n".join(lines))
            self.assertFalse(result["telemetry_passed"])
            self.assertEqual(1, len(result["lifetimes"][0]["acquisition"]["reports"]["body"]))

    def test_acquisition_cannot_count_toward_steady_minimum(self):
        self.assertFalse(summarize_log("\n".join(preview_log().splitlines()[:-2]))["telemetry_passed"])
        self.assertFalse(summarize_log(preview_log().replace("alpha=1", "alpha=0.5"))["telemetry_passed"])

    def test_acquisition_does_not_excuse_unsafe_stale_or_nonfinite_reports(self):
        for old, new in (("noncolliding=true", "noncolliding=false"),
                         ("fresh=true", "fresh=false"),
                         ("source_unchanged=true", "source_unchanged=false"),
                         ("left_error=0.8", "left_error=nan")):
            lines = preview_log().splitlines()
            lines[0] = lines[0].replace(old, new)
            self.assertFalse(summarize_log("\n".join(lines))["telemetry_passed"])

    def test_matching_finite_measurements_are_only_telemetry_evidence(self):
        result = summarize_log(preview_log())
        self.assertTrue(result["telemetry_passed"])
        self.assertFalse(result["damage_accuracy_verified"])
        self.assertFalse(result["visual_acceptance_verified"])
        self.assertEqual(60, result["lifetimes"][0]["body"]["new_samples"])

    def test_missing_body_or_weapon_cannot_pass(self):
        for kind in ("avatar_preview_frame ", "avatar_weapon_preview "):
            with self.subTest(kind=kind):
                log = "\n".join(line for line in preview_log().splitlines() if kind not in line)
                self.assertFalse(summarize_log(log)["telemetry_passed"])
        self.assertFalse(summarize_log("")["telemetry_passed"])

    def test_one_lifetime_cannot_complete_another(self):
        changed = preview_log().replace("avatar_weapon_preview world=17 connection=2 pawn=1",
                                        "avatar_weapon_preview world=17 connection=2 pawn=2")
        self.assertFalse(summarize_log(changed)["telemetry_passed"])
        changed = preview_log().replace("reference=0 source=Human_0 time=7", "reference=1 source=Human_0 time=7")
        self.assertFalse(summarize_log(changed)["telemetry_passed"])

    def test_repeated_report_is_not_new_samples(self):
        for changed in (preview_log().replace("time=4", "time=1"),
                        preview_log().replace("samples=40", "samples=10"),
                        "\n".join(preview_log().splitlines()[-2:])):
            self.assertFalse(summarize_log(changed)["telemetry_passed"])

    def test_zero_placeholder_muzzle_without_effective_pose_fails(self):
        changed = preview_log().replace("effective_muzzle=true", "effective_muzzle=false").replace("muzzle_error=0.2", "muzzle_error=0")
        self.assertFalse(summarize_log(changed)["telemetry_passed"])

    def test_missing_collision_flags_and_actual_physics_fail(self):
        for old, new in (("noncolliding=true", "noncolliding=false"),
                         ("noncolliding=true", ""),
                         ("physics_asset=false", "physics_asset=true"),
                         ("unique_tree=true", "unique_tree=false"),
                         ("source_unchanged=true", "source_unchanged=false")):
            with self.subTest(new=new):
                self.assertFalse(summarize_log(preview_log().replace(old, new))["telemetry_passed"])

    def test_nonfinite_or_large_error_and_missing_identity_fail(self):
        for old, new in (("left_error=0.8", "left_error=nan"),
                         ("left_error=0.8", "left_error=20"),
                         ("bore_error_deg=0.4", "bore_error_deg=inf"),
                         ("world=17", "world=0"),
                         ("reference=0", "")):
            with self.subTest(new=new):
                self.assertFalse(summarize_log(preview_log().replace(old, new))["telemetry_passed"])

    def test_stale_or_script_error_is_visible_and_fails(self):
        stale = summarize_log(preview_log().replace("fresh=true", "fresh=false"))
        self.assertFalse(stale["telemetry_passed"])
        self.assertEqual(3, stale["lifetimes"][0]["body"]["stale_reports"])
        failed = summarize_log(preview_log() + "\nScriptWarning: Accessed None in avatar Tick")
        self.assertFalse(failed["telemetry_passed"])
        self.assertEqual(1, failed["script_error_count"])
        stopped = summarize_log(preview_log() + "\nKF2VRNet avatar_preview_stale world=17 connection=2 pawn=1 reference=0 time=8 age=0.4 samples=72 fresh=false hidden=true")
        self.assertFalse(stopped["telemetry_passed"])
        self.assertEqual(1, len(stopped["stale_events"]))

    def test_preparation_or_unclean_session_cannot_be_runtime_evidence(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "driver.log").write_text(preview_log())
            (root / "server.log").write_text("")
            (root / "teammate.log").write_text("KF2VRNet status world=17 connection=2 pawn=1 hello=true")
            data = {"roles": [{"role": name, "log": str(root / (name + ".log")),
                              "native_adapter": name == "teammate",
                              "args": ["-kf2vr-hand-replay"] if name == "teammate" else []}
                              for name in ("driver", "server", "teammate")],
                    "avatar_preview": True, "replay_teammate": True, "status": "prepared",
                    "server_query": {"secure": False},
                    "mod_handshake_observed": True, "user_config_preserved": True,
                    "cleanup_complete": True, "cleanup_errors": []}
            path = root / "run.json"
            with patch("avatar_evidence.verify_transport", return_value={"passed": True}):
                path.write_text(json.dumps(data))
                result = summarize_session(path)
                self.assertTrue(result["telemetry_passed"])
                self.assertFalse(result["session_telemetry_passed"])
                data["status"] = "closed"
                data["cleanup_errors"] = ["native file differs"]
                path.write_text(json.dumps(data))
                self.assertFalse(summarize_session(path)["session_telemetry_passed"])
                data["cleanup_errors"] = []
                path.write_text(json.dumps(data))
                self.assertTrue(summarize_session(path)["session_telemetry_passed"])


if __name__ == "__main__":
    unittest.main()
