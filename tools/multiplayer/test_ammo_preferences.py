"""Saved ammo choices and optional world-drop preferences across launches."""
from pathlib import Path
import tempfile
import unittest

import vr_config
from session import read_ini


class AmmoPreferencesTests(unittest.TestCase):
    section = "KF2VR.VRHandsBridge"

    def preferences(self, body, baseline=""):
        text = vr_config.apply_preferences(baseline, f"[{self.section}]\n{body}\n")
        result = vr_config.values(text, self.section)
        self.assertEqual(result, vr_config.values(text, vr_config.ALIASES[self.section]))
        return result

    def test_new_defaults_opt_in_to_independent_ammo_rules_all_off(self):
        result = vr_config.values(vr_config.apply_preferences(""), self.section)
        self.assertEqual("1", result["AmmoRuleSettingsRevision"])
        for key in vr_config.AMMO_OPTIONS:
            self.assertEqual("False", result[key])
        self.assertEqual("False", result["bPerkReloadMagnet"])
        self.assertEqual("True", result["bEmptyTriggerReloads"])
        self.assertEqual("True", result["bWorldWeaponDrops"])
        self.assertEqual("False", result["bExperimentalInteractions"])
        self.assertEqual("True", result["bSupportHandCarry"])
        self.assertEqual("0", result["ReloadPreset"])
        self.assertEqual("False", result["bFreeWeaponCycling"])
        self.assertEqual("False", result["bAllowOtherWeaponPickup"])
        self.assertEqual("False", result["bWorldDropRadialRecall"])
        self.assertEqual("0", result["WorldDropReturnPolicy"])
        self.assertEqual("5.0", result["WorldDropReturnSeconds"])

    def test_magazine_release_turns_on_once_then_keeps_the_choice(self):
        baseline = vr_config.apply_preferences("")
        self.assertEqual("True", vr_config.values(baseline, self.section)["bGrabReleasesMagazine"])
        # Saved before the default changed (#157): flipped on and stamped.
        old = self.preferences("bGrabReleasesMagazine=False", baseline)
        self.assertEqual(("True", "1"), (old["bGrabReleasesMagazine"], old["MagazineReleaseSettingsRevision"]))
        # Chosen off after it: kept, and still kept on the next launch.
        saved = f"[{self.section}]\nbGrabReleasesMagazine=False\nMagazineReleaseSettingsRevision=1\n"
        first = vr_config.apply_preferences("", saved)
        second = vr_config.apply_preferences("", first)
        for output in (first, second):
            self.assertEqual("False", vr_config.values(output, self.section)["bGrabReleasesMagazine"])

    def test_saved_reload_styles_align_their_magazine_options_once(self):
        baseline = vr_config.apply_preferences("")
        switches = ("bInteractiveReloads", "bFreeWeaponCycling", "bEmptyTriggerReloads")
        styles = {"Interactive": ("True", "False", "True"), "Advanced": ("True", "True", "False"),
                  "Custom": ("True", "True", "True"), "Classic": ("False", "False", "True")}
        expected = {"Interactive": ("True", "False"), "Advanced": ("False", "True"),
                    "Custom": ("True", "True"), "Classic": ("True", "True")}
        for name, values in styles.items():
            body = "\n".join(f"{key}={value}" for key, value in zip(switches, values))
            with self.subTest(style=name):
                # Saved before the styles set them (R43): the 11-02 flip left
                # NEW MAG on; full-mag eject was the player's.
                result = self.preferences(body + "\nbGrabReleasesMagazine=True\nbAllowFullMagazineEject=True"
                                          "\nMagazineReleaseSettingsRevision=1", baseline)
                self.assertEqual(expected[name], (result["bGrabReleasesMagazine"], result["bAllowFullMagazineEject"]))
                self.assertEqual("1", result["ReloadStyleAlignmentRevision"])
                # Aligned once: a later choice is kept.
                kept = self.preferences(body + "\nbGrabReleasesMagazine=False\nbAllowFullMagazineEject=False"
                                        "\nMagazineReleaseSettingsRevision=1\nReloadStyleAlignmentRevision=1", baseline)
                self.assertEqual(("False", "False"), (kept["bGrabReleasesMagazine"], kept["bAllowFullMagazineEject"]))

    def test_sharing_choice_survives_reenabled_drops_and_profile_round_trip(self):
        for choice in ("True", "False"):
            for section in (self.section, vr_config.ALIASES[self.section]):
                saved = f"[{section}]\nbWorldWeaponDrops=False\nbAllowOtherWeaponPickup={choice}\n"
                first = vr_config.apply_preferences("", saved)
                second = vr_config.apply_preferences("", first)
                for output in (first, second):
                    prefs = vr_config.values(output, self.section)
                    self.assertEqual("True", prefs["bWorldWeaponDrops"])
                    self.assertEqual(choice, prefs["bAllowOtherWeaponPickup"])

    def test_legacy_saved_choice_beats_fresh_session_defaults(self):
        baseline = vr_config.apply_preferences("")
        for legacy in ("True", "False"):
            with self.subTest(legacy=legacy):
                result = self.preferences(f"bRealisticAmmo={legacy}", baseline)
                self.assertEqual("1", result["AmmoRuleSettingsRevision"])
                for key in vr_config.AMMO_OPTIONS:
                    self.assertEqual(legacy, result[key])

    def test_interaction_opt_in_is_independent_of_reloads_and_world_weapons(self):
        for enabled in ("True", "False"):
            with self.subTest(enabled=enabled):
                result = self.preferences(f"bExperimentalInteractions={enabled}\nReloadPreset=2\n"
                    "bInteractiveReloads=True\nbKeepChamberedRound=True\nbRecoverMagazineAmmo=True\n"
                    "bWorldWeaponDrops=True\nbAllowOtherWeaponPickup=True")
                self.assertEqual(enabled, result["bExperimentalInteractions"])
                self.assertEqual("2", result["ReloadPreset"])
                for key in ("bInteractiveReloads", "bKeepChamberedRound", "bRecoverMagazineAmmo"):
                    self.assertEqual("True", result[key])
                self.assertEqual("True", result["bWorldWeaponDrops"])
                self.assertEqual("True", result["bAllowOtherWeaponPickup"])

    def test_legacy_session_choice_migrates_without_saved_profile(self):
        text = vr_config.apply_preferences(f"[{self.section}]\nbRealisticAmmo=False\n")
        result = vr_config.values(text, self.section)
        self.assertEqual("1", result["AmmoRuleSettingsRevision"])
        for key in vr_config.AMMO_OPTIONS:
            self.assertEqual("False", result[key])

    def test_ini_key_case_spacing_and_last_scalar_value_survive_migration(self):
        saved = (f"[{self.section.lower()}]\n"
                 "  BrealisticAmmo = True\nBREALISTICAMMO=False\n"
                 "bRealisticAmmo=True\n brealisticammo = False  \n"
                 " breloadhints = False  \n bfreeweaponcycling = True\n ReloadPreset = 3.0\n")
        text = vr_config.apply_preferences("", saved)
        for section in (self.section, vr_config.ALIASES[self.section]):
            result = vr_config.values(text, section)
            self.assertEqual("false", result["bRealisticAmmo"].lower())
            self.assertEqual("false", result["bReloadHints"].lower())
            self.assertEqual("true", result["bFreeWeaponCycling"].lower())
            self.assertEqual("3", result["ReloadPreset"])
            for key in vr_config.AMMO_OPTIONS:
                self.assertEqual("False", result[key])
            self.assertNotIn("brealisticammo", result)

    def test_repeated_scalar_revision_uses_the_last_value(self):
        result = self.preferences("AmmoRuleSettingsRevision=1\n"
                                  "ammorulesettingsrevision=0\nbRealisticAmmo=False\n")
        for key in vr_config.AMMO_OPTIONS:
            self.assertEqual("False", result[key])
        self.assertEqual("1", result["AmmoRuleSettingsRevision"])

    def test_numeric_revision_one_does_not_fill_partial_choices_from_legacy(self):
        baseline = (f"[{self.section}]\nAmmoRuleSettingsRevision=1\n"
                    "bLoseReloadAmmo=False\nbRecoverMagazineAmmo=True\n")
        for revision in ("1", "1.0", "1e0"):
            with self.subTest(revision=revision):
                result = self.preferences(f"AmmoRuleSettingsRevision={revision}\n"
                                          "bRealisticAmmo=False\nbKeepChamberedRound=True", baseline)
                self.assertEqual(("True", "False", "True"), tuple(result[key] for key in vr_config.AMMO_OPTIONS))

    def test_invalid_saved_reload_values_keep_the_shipped_fallback_policy(self):
        baseline = (f"[{self.section}]\nAmmoRuleSettingsRevision=1\nReloadPreset=3\n"
                    "bInteractiveReloads=True\nbFreeWeaponCycling=True\n")
        result = self.preferences("ReloadPreset=invalid\nbInteractiveReloads=invalid\n"
                                  "bFreeWeaponCycling=invalid", baseline)
        self.assertEqual("0", result["ReloadPreset"])
        for key in ("bInteractiveReloads", "bFreeWeaponCycling"):
            self.assertEqual("False", result[key])

    def test_scalar_repeats_do_not_turn_into_array_preferences(self):
        text = vr_config.apply_preferences("", f"[{self.section}]\n"
            "AmmoRuleSettingsRevision=1\nbLoseReloadAmmo=True\nbLoseReloadAmmo=False\n"
            "bKeepChamberedRound=False\nbKeepChamberedRound=True\n"
            "SelectorFavorites=One\nSelectorFavorites=Two\n")
        result = vr_config.items(text, self.section)
        self.assertEqual("False", result["bLoseReloadAmmo"])
        self.assertEqual("True", result["bKeepChamberedRound"])
        self.assertEqual(["One", "Two"], result["SelectorFavorites"])

    def test_formatted_custom_reload_profile_round_trips_solo_and_network(self):
        expected = {"ReloadPreset": "3", "AmmoRuleSettingsRevision": "1",
                    "bKeepChamberedRound": "True", "bLoseReloadAmmo": "False",
                    "bRecoverMagazineAmmo": "True", "bInteractiveReloads": "True", "bFreeWeaponCycling": "True"}
        for network in (False, True):
            with self.subTest(network=network), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                config = root / "Config"
                config.mkdir()
                section = vr_config.ALIASES[self.section] if network else self.section
                body = "\n".join(f"  {key.lower()} = {value}  " for key, value in expected.items())
                body += "\nbRealisticAmmo=False\nSelectorFavorites=One\nSelectorFavorites=Two\n"
                (config / "KFGame.ini").write_text(f"[{section.lower()}]\n{body}", encoding="utf-16")
                vr_config.export_preferences(config, root / "Profile", network=network)
                (config / "KFGame.ini").write_text(vr_config.apply_preferences(""), encoding="utf-16")
                vr_config.import_preferences(config, root=root / "Profile")
                text = read_ini(config / "KFGame.ini")
                for selected in (self.section, vr_config.ALIASES[self.section]):
                    result = vr_config.items(text, selected)
                    self.assertEqual(expected, {key: result[key] for key in expected})
                    self.assertEqual(["One", "Two"], result["SelectorFavorites"])

    def test_each_partial_independent_choice_preserves_explicit_value(self):
        for explicit in vr_config.AMMO_OPTIONS:
            for legacy in ("True", "False"):
                choice = "False" if legacy == "True" else "True"
                with self.subTest(explicit=explicit, legacy=legacy):
                    result = self.preferences(f"bRealisticAmmo={legacy}\n{explicit}={choice}")
                    self.assertEqual("1", result["AmmoRuleSettingsRevision"])
                    for key in vr_config.AMMO_OPTIONS:
                        self.assertEqual(choice if key == explicit else legacy, result[key])

    def test_partial_choice_inherits_effective_legacy_setting(self):
        baseline = f"[{self.section}]\nbRealisticAmmo=False\n"
        result = self.preferences("bKeepChamberedRound=True", baseline)
        self.assertEqual("True", result["bKeepChamberedRound"])
        self.assertEqual("False", result["bLoseReloadAmmo"])
        self.assertEqual("False", result["bRecoverMagazineAmmo"])
        result = self.preferences("bKeepChamberedRound=False")
        self.assertEqual("False", result["bKeepChamberedRound"])
        self.assertEqual("False", result["bLoseReloadAmmo"])
        self.assertEqual("False", result["bRecoverMagazineAmmo"])

    def test_partial_choice_keeps_existing_independent_rules(self):
        baseline = (f"[{self.section}]\nAmmoRuleSettingsRevision=1\nbRealisticAmmo=True\n"
                    "bKeepChamberedRound=True\nbLoseReloadAmmo=False\nbRecoverMagazineAmmo=True\n")
        result = self.preferences("bKeepChamberedRound=False", baseline)
        self.assertEqual(("False", "False", "True"), tuple(result[key] for key in vr_config.AMMO_OPTIONS))
        legacy = self.preferences("bRealisticAmmo=True\nbKeepChamberedRound=False", baseline)
        self.assertEqual(("False", "True", "True"), tuple(legacy[key] for key in vr_config.AMMO_OPTIONS))

    def test_revision_one_choices_do_not_recombine_with_legacy_switch(self):
        body = ("AmmoRuleSettingsRevision=1\nbRealisticAmmo=False\n"
                "bKeepChamberedRound=True\nbLoseReloadAmmo=False\nbRecoverMagazineAmmo=True")
        result = self.preferences(body)
        self.assertEqual(("True", "False", "True"), tuple(result[key] for key in vr_config.AMMO_OPTIONS))
        again = self.preferences(body, vr_config.apply_preferences(""))
        self.assertEqual(result, again)

    def test_drop_policy_and_timeout_bounds_and_bool_validation(self):
        for policy in ("0", "1", "2", "2.0"):
            self.assertEqual(str(int(float(policy))), self.preferences(f"WorldDropReturnPolicy={policy}")["WorldDropReturnPolicy"])
        for policy in ("-1", "3", "1.5", "nan", "inf", "invalid"):
            with self.subTest(policy=policy):
                self.assertEqual("0", self.preferences(f"WorldDropReturnPolicy={policy}")["WorldDropReturnPolicy"])
        for seconds in ("1", "5.5", "300"):
            self.assertEqual(seconds, self.preferences(f"WorldDropReturnSeconds={seconds}")["WorldDropReturnSeconds"])
        for seconds in ("0", "-1", "300.1", "nan", "inf", "invalid"):
            with self.subTest(seconds=seconds):
                self.assertEqual("5.0", self.preferences(f"WorldDropReturnSeconds={seconds}")["WorldDropReturnSeconds"])
        for key in (*vr_config.AMMO_OPTIONS, "bPerkReloadMagnet", "bFreeWeaponCycling", "bWorldWeaponDrops", "bAllowOtherWeaponPickup", "bWorldDropRadialRecall"):
            self.assertEqual(vr_config.DEFAULTS[self.section][key], self.preferences(f"{key}=invalid")[key])

    def test_reload_preset_is_validated_without_applying_gameplay_choices(self):
        choices = ("bSupportHandCarry=False\nbInteractiveReloads=False\nbFreeWeaponCycling=False\n"
                   "bWorldWeaponDrops=True\nbWorldDropRadialRecall=False\nWorldDropReturnPolicy=2\nWorldDropReturnSeconds=17\n"
                   "AmmoRuleSettingsRevision=1\nbKeepChamberedRound=False\n"
                   "bLoseReloadAmmo=False\nbRecoverMagazineAmmo=False")
        for preset in ("0", "1", "2", "3", "3.0"):
            with self.subTest(preset=preset):
                result = self.preferences(f"ReloadPreset={preset}\n{choices}")
                self.assertEqual(str(int(float(preset))), result["ReloadPreset"])
                for key in ("bSupportHandCarry", "bInteractiveReloads", "bFreeWeaponCycling", *vr_config.AMMO_OPTIONS):
                    self.assertEqual("False", result[key])
                self.assertEqual("True", result["bWorldWeaponDrops"])
                self.assertEqual("False", result["bWorldDropRadialRecall"])
                self.assertEqual("2", result["WorldDropReturnPolicy"])
                self.assertEqual("17", result["WorldDropReturnSeconds"])
        for preset in ("-1", "4", "1.5", "nan", "inf", "invalid"):
            with self.subTest(preset=preset):
                self.assertEqual("0", self.preferences(f"ReloadPreset={preset}")["ReloadPreset"])

    def test_legacy_support_carry_off_survives_new_default(self):
        result = self.preferences("bSupportHandCarry=False", vr_config.apply_preferences(""))
        self.assertEqual("False", result["bSupportHandCarry"])

    def test_world_weapons_preserve_sharing_reload_and_grip_preferences(self):
        old = (f"[{self.section}]\nbWorldWeaponDrops=True\nbAllowOtherWeaponPickup=True\n"
               "ReloadPreset=3\nbInteractiveReloads=True\n"
               "bFreeWeaponCycling=True\nbToggleGrip=True\nbHoldSupportGrip=False\n"
               "bRecoverMagazineAmmo=True\nbDisableGravityPull=False\nAmmoRuleSettingsRevision=1\n")
        for session, saved in ((old, ""), ("", old), (old, old)):
            text = vr_config.apply_preferences(session, saved)
            for section in (self.section, vr_config.ALIASES[self.section]):
                result = vr_config.values(text, section)
                self.assertEqual("True", result["bWorldWeaponDrops"])
                self.assertEqual("True", result["bAllowOtherWeaponPickup"])
                self.assertEqual("3", result["ReloadPreset"])
                for key in ("bInteractiveReloads", "bFreeWeaponCycling", "bToggleGrip", "bRecoverMagazineAmmo"):
                    self.assertEqual("True", result[key])
                self.assertEqual("False", result["bHoldSupportGrip"])
                self.assertEqual("False", result["bDisableGravityPull"])

    def test_return_preferences_remain_independent_and_legacy_pickup_only_survives(self):
        for policy in ("0", "1", "2"):
            for recall in ("True", "False"):
                with self.subTest(policy=policy, recall=recall):
                    result = self.preferences(f"WorldDropReturnPolicy={policy}\nbWorldDropRadialRecall={recall}\nWorldDropReturnSeconds=14")
                    self.assertEqual(policy, result["WorldDropReturnPolicy"])
                    self.assertEqual(recall, result["bWorldDropRadialRecall"])
                    self.assertEqual("14", result["WorldDropReturnSeconds"])
        legacy = self.preferences("WorldDropReturnPolicy=2", vr_config.apply_preferences(""))
        self.assertEqual("2", legacy["WorldDropReturnPolicy"])

    def test_export_import_preserves_independent_choices_in_both_modes(self):
        for network in (False, True):
            with self.subTest(network=network), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                config = root / "Config"
                config.mkdir()
                section = vr_config.ALIASES[self.section] if network else self.section
                body = ("AmmoRuleSettingsRevision=1\nbRealisticAmmo=False\n"
                        "bKeepChamberedRound=True\nbLoseReloadAmmo=False\nbRecoverMagazineAmmo=True\n"
                        "ReloadPreset=3\nbSupportHandCarry=False\nbFreeWeaponCycling=True\n"
                        "bWorldWeaponDrops=True\nbAllowOtherWeaponPickup=True\nbWorldDropRadialRecall=False\n"
                        "WorldDropReturnPolicy=2\nWorldDropReturnSeconds=27.5\nbExperimentalInteractions=True\n")
                (config / "KFGame.ini").write_text(f"[{section}]\n{body}", encoding="utf-16")
                vr_config.export_preferences(config, root / "Profile", network=network)
                (config / "KFGame.ini").write_text(vr_config.apply_preferences(""), encoding="utf-16")
                vr_config.import_preferences(config, root=root / "Profile")
                result = vr_config.values(read_ini(config / "KFGame.ini"), self.section)
                self.assertEqual(("True", "False", "True"), tuple(result[key] for key in vr_config.AMMO_OPTIONS))
                self.assertEqual("3", result["ReloadPreset"])
                self.assertEqual("False", result["bSupportHandCarry"])
                self.assertEqual("True", result["bFreeWeaponCycling"])
                self.assertEqual("True", result["bWorldWeaponDrops"])
                self.assertEqual("False", result["bAllowOtherWeaponPickup"])
                self.assertEqual("False", result["bWorldDropRadialRecall"])
                self.assertEqual("2", result["WorldDropReturnPolicy"])
                self.assertEqual("27.5", result["WorldDropReturnSeconds"])
                self.assertEqual("True", result["bExperimentalInteractions"])


if __name__ == "__main__":
    unittest.main()
