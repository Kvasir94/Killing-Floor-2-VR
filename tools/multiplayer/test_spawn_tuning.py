"""Zed spawn overrides: UKFP settings, Solo/Host URLs, options and remembered choices; no game execution."""
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import patch

import friends
import launch_menu
import workshop_loadout
from session import read_ini


def solo_args(**fields):
    values = dict(solo=True, map="KF-Outpost", difficulty="hard", game_length="long", test_map=False, mods=[],
                  damage_popups=False, test_map_players=0, max_zeds=None, wave_zeds_percent=None,
                  spawn_rate_percent=None)
    values.update(fields)
    return SimpleNamespace(**values)


class SpawnTuningTests(unittest.TestCase):
    def test_host_uses_unofficial_patch_settings_and_enables_it(self):
        args = SimpleNamespace(map="KF-Outpost", mods=[], max_zeds=48, wave_zeds_percent=150, spawn_rate_percent=None)
        self.assertNotIn("UKFPMutator", launch_menu.host_url(args))
        self.assertEqual({"MaxMonsters": "48", "WaveCountMultiplier": "1.500000", "SpawnRateMultiplier": "1.000000"},
                         workshop_loadout.ukfp_spawn_settings(args))
        workshop_loadout.require_ukfp_for_spawns(args)
        self.assertEqual(["ukfp"], args.mods)
        self.assertIn("?Mutator=UnofficialKFPatch.UKFPMutator", launch_menu.host_url(args))

    def test_stock_values_leave_the_loadout_and_settings_stock(self):
        stock = SimpleNamespace(mods=[], max_zeds=0, wave_zeds_percent=100, spawn_rate_percent=100)
        workshop_loadout.require_ukfp_for_spawns(stock)
        self.assertEqual([], stock.mods)
        self.assertEqual({"MaxMonsters": "0", "WaveCountMultiplier": "1.000000", "SpawnRateMultiplier": "1.000000"},
                         workshop_loadout.ukfp_spawn_settings(SimpleNamespace()))

    def test_solo_loads_the_patch_only_for_an_override(self):
        stock = solo_args(max_zeds=0)
        workshop_loadout.require_ukfp_for_spawns(stock)
        self.assertEqual("KF-Outpost?Game=KFGameContent.KFGameInfo_Survival?Difficulty=1?GameLength=2",
                         launch_menu.solo_url(stock))
        args = solo_args(spawn_rate_percent=200)
        workshop_loadout.require_ukfp_for_spawns(args)
        url = launch_menu.solo_url(args, vr_demo=True)
        self.assertEqual(1, url.count("?Mutator="))
        self.assertIn("?Mutator=UnofficialKFPatch.UKFPMutator,KF2VR.VRBootstrap,KF2VR.VRDemo?", url)
        self.assertTrue(url.endswith("?VRNormalGame=1"))

    def test_solo_without_a_local_patch_fails_clearly_and_never_downloads(self):
        args = solo_args(mods=["ukfp"], cache_root=Path("cache"), prepare_only=False)
        missing = RuntimeError("Workshop 2875147606 is missing.")
        with patch("installed_map_catalog.catalog", return_value={}), \
                patch.object(workshop_loadout, "ensure_item", side_effect=missing) as ensure:
            with self.assertRaisesRegex(RuntimeError, "Solo zed spawn overrides need the Unofficial KF2 Patch"):
                workshop_loadout.prepare_content(args, Path("game"), Path("steam"))
        self.assertEqual("2875147606", ensure.call_args.args[0])
        self.assertFalse(ensure.call_args.kwargs["download"])

    def test_solo_writes_the_settings_into_its_own_session_config(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            game, user = root / "game", root / "user"
            (game / "KFGame/Config").mkdir(parents=True)
            user.mkdir()
            configs = root / "run" / "driver" / "Config"
            configs.mkdir(parents=True)
            role = {"role": "driver", "config_root": str(configs), "args": []}
            workshop_loadout.configure_mod_settings(role, solo_args(mods=["ukfp"], max_zeds=64, vr=True), game, user)
            for target in role["mod_config"]["destinations"]:
                self.assertIn("MaxMonsters=64", read_ini(Path(target["root"]) / "KFUnofficialPatch.ini"))

    def test_options_require_host_or_solo_and_stay_in_range(self):
        for argv in (["--max-zeds", "48"], ["--host", "--max-zeds", "129"],
                     ["--solo", "--wave-zeds-percent", "5"], ["--host", "--spawn-rate-percent", "501"]):
            with self.assertRaises(SystemExit):
                friends.parse_options(argv)
        args = friends.parse_options(["--solo", "--wave-zeds-percent", "200"])
        self.assertEqual((None, 200, None), (args.max_zeds, args.wave_zeds_percent, args.spawn_rate_percent))

    def test_choices_are_remembered_per_mode(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            workshop_loadout.save_preferences(SimpleNamespace(profile_root=root, solo=True, vr=True, map="KF-Outpost",
                                                              max_zeds=64, wave_zeds_percent=150, spawn_rate_percent=None))
            unset = dict(profile_root=root, mode_requested=True, vr=True, map=None, difficulty=None, game_length=None,
                         max_zeds=None, wave_zeds_percent=None, spawn_rate_percent=None)
            solo = SimpleNamespace(solo=True, **unset)
            workshop_loadout.load_preferences(solo)
            self.assertEqual((64, 150, 100), (solo.max_zeds, solo.wave_zeds_percent, solo.spawn_rate_percent))
            host = SimpleNamespace(host=True, mods=[], damage_popups=False, test_map_players=0, **unset)
            workshop_loadout.load_preferences(host)
            self.assertEqual((0, 100, 100), (host.max_zeds, host.wave_zeds_percent, host.spawn_rate_percent))


if __name__ == "__main__":
    unittest.main()
