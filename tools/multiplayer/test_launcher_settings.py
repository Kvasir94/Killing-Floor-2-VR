"""Settings page model: headset preferences and launch graphics round-trip to their stores."""
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import launcher_settings as model
import vr_config
import workshop_loadout
from session import read_ini


class LauncherSettingsTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.profile = Path(temporary.name) / "profile"
        for target in ("vr_config.profile_root", "workshop_loadout.profile_root"):
            patcher = patch(target, return_value=self.profile)
            patcher.start()
            self.addCleanup(patcher.stop)

    def saved(self, **values):
        return SimpleNamespace(eye_render_percent=None, **values)

    def test_empty_profile_shows_shipped_defaults(self):
        values = model.load(self.saved())
        self.assertEqual("100", values["eye_render_percent"])
        self.assertEqual("auto", values["dlss"])
        self.assertTrue(values["hbao"])
        self.assertTrue(values["reflections"])
        self.assertEqual("False", values["bDisableSupportHandAim"])  # "support hand aims gun" on
        self.assertTrue(values["bDisableGravityPull"])  # shown as "gravity pull on"
        self.assertEqual("True", values["bSnapTurn"])
        self.assertEqual("Relaxed", values["ActiveControllerFitProfile"])
        self.assertEqual(set(model.BY_KEY), set(values))

    def test_physical_reload_switch_preserves_independent_ammo_and_empty_trigger_choices(self):
        choices = {"bKeepChamberedRound": True, "bLoseReloadAmmo": False,
                   "bRecoverMagazineAmmo": True, "bEmptyTriggerReloads": True}
        model.save(choices)
        for physical in (True, False, True):
            model.save({"bInteractiveReloads": physical})
            values = model.load(self.saved())
            self.assertEqual(physical, values["bInteractiveReloads"])
            for key, value in choices.items():
                self.assertEqual(value, values[key])

    def test_hand_defaults_and_saved_reload_choices_survive_each_session_mode(self):
        for fit, pitch in (("Relaxed", "-20.6"), ("Neutral", "0.0"), ("Quest2", "-8.6")):
            model.save({"ActiveControllerFitProfile": fit})
            saved = read_ini(self.profile / "KFGame.ini")
            from session import set_ini
            saved = set_ini(saved, model.HANDS, {"bInteractiveReloads": "True", "ReloadPreset": "2", "bFreeWeaponCycling": "True"})
            for network in (False, True):
                with self.subTest(fit=fit, network=network):
                    session = vr_config.apply_preferences("", saved)
                    section = vr_config.ALIASES[model.HANDS] if network else model.HANDS
                    hands = vr_config.values(session, section)
                    expected = {"ActiveControllerFitProfile": fit, "FirearmAimPitchDegrees": pitch,
                                "ChestGrenadeOffset": "(X=10.5,Y=9.5,Z=6.0)", "bChestGrenadeCentered": "True",
                                "bInteractiveReloads": "True", "ReloadPreset": "2", "bFreeWeaponCycling": "True"}
                    self.assertEqual(expected, {key: hands[key] for key in expected})
                    source = self.profile / "session"
                    source.mkdir(exist_ok=True)
                    (source / "KFGame.ini").write_text(session, encoding="utf-16")
                    vr_config.export_preferences(source, root=self.profile, network=network)
                    exported = vr_config.values(read_ini(self.profile / "KFGame.ini"), model.HANDS)
                    self.assertEqual(expected, {key: exported[key] for key in expected})

    def test_saving_writes_each_value_to_its_own_store(self):
        model.save({"bSnapTurn": "False", "bDisableGravityPull": False, "bReloadHints": False,
                    "eye_render_percent": "75", "dlss": "quality", "hbao": False})
        text = read_ini(self.profile / "KFGame.ini")
        for section in ("KF2VR.VRSessionUI", "KF2VRNetClient.KF2VRNetSessionUI"):
            session = vr_config.values(text, section)
            self.assertEqual(("False", "75"), (session["bSnapTurn"], session["EyeRenderPercent"]))
        hands = vr_config.values(text, "KF2VR.VRHandsBridge")
        self.assertEqual(("True", "False"), (hands["bDisableGravityPull"], hands["bReloadHints"]))
        launcher = json.loads((self.profile / "launcher.json").read_text())
        self.assertEqual({"dlss": "quality", "hbao": False}, launcher)
        values = model.load(self.saved(dlss="quality", hbao=False))
        self.assertEqual(("False", "75", False), (values["bSnapTurn"], values["eye_render_percent"],
                                                 values["bDisableGravityPull"]))

    def test_named_aim_profile_replaces_custom_axes_only_when_chosen(self):
        self.profile.mkdir(parents=True)
        (self.profile / "KFGame.ini").write_text(
            "[KF2VR.VRHandsBridge]\nActiveControllerFitProfile=Neutral\nFirearmAimPitchDegrees=-13.25\n"
            "FirearmAimYawDegrees=4.5\n", encoding="utf-16")
        model.save({"bStickCrouch": False})
        hands = vr_config.values(read_ini(self.profile / "KFGame.ini"), "KF2VR.VRHandsBridge")
        self.assertEqual(("-13.25", "4.5"), (hands["FirearmAimPitchDegrees"], hands["FirearmAimYawDegrees"]))
        model.save({"ActiveControllerFitProfile": "Relaxed"})
        hands = vr_config.values(read_ini(self.profile / "KFGame.ini"), "KF2VR.VRHandsBridge")
        self.assertEqual(("Relaxed", "-20.6", "0.0"), (hands["ActiveControllerFitProfile"],
                                                       hands["FirearmAimPitchDegrees"], hands["FirearmAimYawDegrees"]))

    def test_weapon_assistance_choices_persist_in_both_session_modes(self):
        self.assertEqual("1", model.load(self.saved())["AimAssistPreset"])
        self.assertEqual("False", model.load(self.saved())["bLaserFromBore"])
        for mode in ("0", "1", "2"):
            model.save({"AimAssistPreset": mode, "bLaserFromBore": "True"})
            saved = read_ini(self.profile / "KFGame.ini")
            for network in (False, True):
                with self.subTest(mode=mode, network=network):
                    session = vr_config.apply_preferences("", saved)
                    settings = vr_config.values(session, model.ASSIST)
                    self.assertEqual((mode, "True"), (settings["AimAssistPreset"], settings["bLaserFromBore"]))
                    source = self.profile / "session"
                    source.mkdir(exist_ok=True)
                    (source / "KFGame.ini").write_text(session, encoding="utf-16")
                    vr_config.export_preferences(source, root=self.profile, network=network)
                    self.assertEqual(mode, model.load(self.saved())["AimAssistPreset"])

    def test_invalid_aim_assistance_uses_gamepad(self):
        for value in ("-1", "3", "0.5", "nan", "bad"):
            with self.subTest(value=value):
                merged = vr_config.apply_preferences("", f"[{model.ASSIST}]\nAimAssistPreset={value}\n")
                self.assertEqual("1", vr_config.values(merged, model.ASSIST)["AimAssistPreset"])

    def test_old_aim_choice_migrates_before_seeded_defaults_and_only_once(self):
        baseline = vr_config.apply_preferences("")
        for old, preset, maximum in (("0", "1", 100), ("1", "2", 25), ("2", "0", 100)):
            with self.subTest(old=old):
                saved = f"[{model.ASSIST}]\naimassistmode={old}\n"
                result = vr_config.apply_preferences(baseline, saved)
                assist = vr_config.values(result, model.ASSIST)
                self.assertEqual(preset, assist["AimAssistPreset"])
                self.assertEqual("1", assist["AimAssistSettingsRevision"])
                self.assertEqual(maximum, float(assist["CustomAimCorrectionMaxRangeMeters"]))
                self.assertEqual(assist, vr_config.values(vr_config.apply_preferences(result), model.ASSIST))

    def test_explicit_new_aim_values_win_over_legacy_and_migration(self):
        saved = (f"[{model.ASSIST}]\nAimAssistMode=1\nAimAssistPreset=0\n"
                 "CustomAimCorrectionStrength=0.375\nCustomAimCorrectionMaxRangeMeters=43.2\n")
        assist = vr_config.values(vr_config.apply_preferences("", saved), model.ASSIST)
        self.assertEqual(("0", "0.375", "43.2"), tuple(assist[key] for key in
                         ("AimAssistPreset", "CustomAimCorrectionStrength", "CustomAimCorrectionMaxRangeMeters")))

    def test_custom_aim_tuning_survives_presets_and_both_session_modes(self):
        tuning = {"CustomAimCorrectionStrength": "0.375",
                  "CustomAimCorrectionTolerance": "0.625", "CustomAimCorrectionMinRangeMeters": "8.25",
                  "CustomAimCorrectionMaxRangeMeters": "44.75"}
        model.save(dict(tuning, AimAssistPreset="2"))
        for preset in ("0", "1", "2"):
            model.save({"AimAssistPreset": preset})
            loaded = model.load(self.saved())
            self.assertEqual(tuning, {key: loaded[key] for key in tuning})
            for network in (False, True):
                session = self.profile / "session"
                session.mkdir(exist_ok=True)
                (session / "KFGame.ini").write_text(vr_config.apply_preferences("", read_ini(self.profile / "KFGame.ini")), encoding="utf-16")
                vr_config.export_preferences(session, root=self.profile, network=network)
                loaded = model.load(self.saved())
                self.assertEqual(tuning, {key: loaded[key] for key in tuning})
                self.assertEqual(preset, loaded["AimAssistPreset"])
                self.assertEqual(preset == "2", model.visible(model.BY_KEY["CustomAimCorrectionStrength"], loaded))

    def test_custom_aim_ranges_clamp_the_edited_bound(self):
        model.save({"CustomAimCorrectionMinRangeMeters": "10", "CustomAimCorrectionMaxRangeMeters": "40"})
        model.save({"CustomAimCorrectionMinRangeMeters": "60"})
        loaded = model.load(self.saved())
        self.assertEqual(("40", "40"), (loaded["CustomAimCorrectionMinRangeMeters"], loaded["CustomAimCorrectionMaxRangeMeters"]))
        model.save({"CustomAimCorrectionMaxRangeMeters": "20"})
        loaded = model.load(self.saved())
        self.assertEqual(("40", "40"), (loaded["CustomAimCorrectionMinRangeMeters"], loaded["CustomAimCorrectionMaxRangeMeters"]))
        # A malformed pair loaded together resolves deterministically by lowering minimum.
        saved = f"[{model.ASSIST}]\nCustomAimCorrectionMinRangeMeters=80\nCustomAimCorrectionMaxRangeMeters=20\n"
        assist = vr_config.values(vr_config.apply_preferences("", saved), model.ASSIST)
        self.assertEqual(("20", "20"), (assist["CustomAimCorrectionMinRangeMeters"], assist["CustomAimCorrectionMaxRangeMeters"]))

    def test_numeric_aim_controls_accept_fine_values_and_reject_invalid_values(self):
        for key, displayed, stored in (("CustomAimCorrectionStrength", "37.125", "0.37125"),
                                        ("CustomAimCorrectionTolerance", "62.5", "0.625"),
                                        ("CustomAimCorrectionMaxRangeMeters", "43.275", "43.275")):
            setting = model.BY_KEY[key]
            self.assertEqual(stored, model.number_value(setting, displayed))
            self.assertEqual(displayed, model.number_display(setting, stored))
        for key in ("CustomAimCorrectionStrength", "CustomAimCorrectionTolerance",
                    "CustomAimCorrectionMinRangeMeters", "CustomAimCorrectionMaxRangeMeters"):
            for invalid in ("nan", "inf", "-inf", "bad", "-1", "101"):
                with self.subTest(key=key, invalid=invalid):
                    with self.assertRaises(ValueError):
                        model.number_value(model.BY_KEY[key], invalid)
            for invalid in ("nan", "inf", "-inf", "bad", "-1", "101"):
                with self.subTest(profile_key=key, invalid=invalid):
                    saved = f"[{model.ASSIST}]\n{key}={invalid}\n"
                    assist = vr_config.values(vr_config.apply_preferences("", saved), model.ASSIST)
                    self.assertEqual(vr_config.DEFAULTS[model.ASSIST][key], assist[key])
        with self.assertRaises(ValueError):
            model.save({"CustomAimCorrectionStrength": "nan", "hbao": False})
        self.assertFalse((self.profile / "launcher.json").exists())

    def test_zed_grab_choice_carries_the_headset_revision_stamp(self):
        model.save({"bZedGrabEnabled": False})
        hands = vr_config.values(read_ini(self.profile / "KFGame.ini"), "KF2VR.VRHandsBridge")
        self.assertEqual(("False", "1"), (hands["bZedGrabEnabled"], hands["ZedGrabSettingsRevision"]))

    def test_aim_mode_is_one_choice_over_the_two_saved_switches(self):
        self.assertEqual("sight", model.load(self.saved())["AimMode"])
        self.assertEqual("sight", model.aim_mode({}))
        for mode, sight, converge in (("sight", "True", "False"), ("bore", "False", "False"), ("converge", "False", "True")):
            with self.subTest(mode=mode):
                model.save({"AimMode": mode})
                hands = vr_config.values(read_ini(self.profile / "KFGame.ini"), "KF2VR.VRHandsBridge")
                self.assertEqual((sight, converge), (hands["bSightPointAim"], hands["bSightLineConvergence"]))
                self.assertEqual(mode, model.load(self.saved())["AimMode"])
                session = vr_config.apply_preferences("", read_ini(self.profile / "KFGame.ini"))
                for section in (model.HANDS, vr_config.ALIASES[model.HANDS]):
                    applied = vr_config.values(session, section)
                    self.assertEqual((sight, converge), (applied["bSightPointAim"], applied["bSightLineConvergence"]))

    def test_changed_weapon_fit_shows_as_custom_until_a_profile_is_chosen(self):
        self.profile.mkdir(parents=True)
        (self.profile / "KFGame.ini").write_text(
            "[KF2VR.VRHandsBridge]\nActiveControllerFitProfile=Relaxed\nFirearmAimPitchDegrees=-13.25\n", encoding="utf-16")
        value = model.load(self.saved())["ActiveControllerFitProfile"]
        self.assertEqual(model.CUSTOM_FIT + "Relaxed", value)
        self.assertEqual("Custom fit (from Relaxed wrist)",
                         model.labels(model.BY_KEY["ActiveControllerFitProfile"], value)[value])
        model.save({"ActiveControllerFitProfile": "Relaxed"})
        self.assertEqual("Relaxed", model.load(self.saved())["ActiveControllerFitProfile"])

    def test_unlisted_stored_value_is_shown_not_replaced(self):
        values = model.load(self.saved(dlss_sharpness=35))
        self.assertEqual("35", values["dlss_sharpness"])
        self.assertEqual("35", model.labels(model.BY_KEY["dlss_sharpness"], 35)[35])

    def test_launch_graphics_lines_reach_the_session_but_never_the_profile(self):
        import friends
        args = friends.parse_options(["--solo", "--vr", "--dlss", "quality", "--dlss-sharpness", "30",
                                      "--no-hbao", "--flex", "gibs"])
        args.reflections, args.single_pass = True, False
        lines = friends.launch_graphics_summary(args)
        self.assertEqual("QUALITY PRESET  DLSS QUALITY  SHARPEN 30", lines["LaunchGraphicsSummary"])
        self.assertEqual("AO OFF  REFLECTIONS ON  SINGLE-PASS OFF", lines["LaunchEffectsSummary"])
        session = Path(self.profile.parent) / "session"
        session.mkdir()
        text = vr_config.apply_preferences("")
        from session import set_ini
        text = set_ini(text, "KF2VR.VRSessionUI", dict(lines, EyeRenderPercent="80"))
        (session / "KFGame.ini").write_text(text, encoding="utf-16")
        vr_config.export_preferences(session, root=self.profile, network=False)
        saved = read_ini(self.profile / "KFGame.ini")
        self.assertEqual("80", vr_config.values(saved, "KF2VR.VRSessionUI")["EyeRenderPercent"])
        self.assertNotIn("LaunchGraphicsSummary", saved)
        self.assertNotIn("LaunchEffectsSummary", saved)

    def test_a_change_in_either_mode_section_survives_the_export(self):
        # A Host/Join process also runs Solo, which writes the base section.
        for network in (False, True):
            with self.subTest(network=network):
                model.save({"bToggleGrip": "False", "bFreeWeaponCycling": "True"})
                session = self.profile.parent / ("session-%d" % network)
                session.mkdir()
                vr_config.import_preferences(session, root=self.profile)
                path = session / "KFGame.ini"
                own = vr_config.ALIASES[model.HANDS] if network else model.HANDS
                other = model.HANDS if network else vr_config.ALIASES[model.HANDS]
                from session import set_ini
                text = set_ini(read_ini(path), other, {"bToggleGrip": "True"})
                text = set_ini(text, own, {"bFreeWeaponCycling": "False"})
                path.write_text(text, encoding="utf-16")
                vr_config.export_preferences(session, root=self.profile, network=network)
                values = model.load(self.saved())
                self.assertEqual(("True", "False"), (str(values["bToggleGrip"]), str(values["bFreeWeaponCycling"])))
                saved = read_ini(self.profile / "KFGame.ini")
                self.assertEqual(vr_config.values(saved, model.HANDS)["bToggleGrip"],
                                 vr_config.values(saved, vr_config.ALIASES[model.HANDS])["bToggleGrip"])

    def test_options_do_not_apply_while_their_prerequisite_is_off(self):
        values = model.load(self.saved())
        recover = model.BY_KEY["bRecoverMagazineAmmo"]
        self.assertTrue(model.visible(recover, dict(values, bInteractiveReloads=True, bLoseReloadAmmo=True)))
        self.assertFalse(model.visible(recover, dict(values, bInteractiveReloads=True, bLoseReloadAmmo=False)))
        self.assertFalse(model.visible(recover, dict(values, bInteractiveReloads=False, bLoseReloadAmmo=True)))


if __name__ == "__main__":
    unittest.main()
