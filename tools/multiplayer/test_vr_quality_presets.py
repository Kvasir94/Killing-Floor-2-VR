"""Offline contract tests for the ordinary multiplayer VR quality presets."""
import argparse
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import friends


MANDATORY = {
    "MotionBlur": "False", "MotionBlurPause": "False", "MotionBlurQuality": "0",
    "DepthOfField": "False", "DepthOfFieldQuality": "0", "bAllowTemporalAA": "False",
    "PostProcessAA": "False", "UseVsync": "False", "AmbientOcclusion": "False",
    "HBAO": "False", "AllowRadialBlur": "False", "AllowScreenSpaceReflections": "False", "LensFlares": "False",
    "ImageGrainScaler": "0.500000",
}


class VrQualityPresetTests(unittest.TestCase):
    def options(self, quality, frame_timings=False, threaded_render=False):
        return argparse.Namespace(replay_teammate=False, avatar_preview=False, port=7777,
            query_port=27015, cache_root=Path("cache"), address="example.test", password="secret",
            vr=True, eye_render_percent=None, vr_quality=quality,
            frame_timings=frame_timings, threaded_render=threaded_render)

    def configure(self, quality, frame_timings=False, threaded_render=False):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            configs = root / "configs"
            configs.mkdir()
            (configs / "KFEngine.ini").write_text("[Engine.Engine]\nbSmoothFrameRate=True\n", encoding="utf-16")
            (configs / "KFSystemSettings.ini").write_text(
                "[SystemSettings]\nMotionBlur=True\nDynamicShadows=True\nMaxDrawDistanceScale=1.0\n", encoding="utf-16")
            (configs / "KFGame.ini").write_text("[KFGame.KFGameEngine]\n", encoding="utf-16")
            role = {"role": "driver", "args": ["join"], "log": str(root / "game.log"),
                    "config_root": str(configs), "native_adapter": False}
            with patch.object(friends, "role_config", return_value=role):
                result = friends.configure_role(root, "driver", root, root,
                                                self.options(quality, frame_timings, threaded_render))
            engine = friends.read_ini(configs / "KFEngine.ini")
            settings = friends.read_ini(configs / "KFSystemSettings.ini")
            return result, engine, settings

    def test_quality_has_only_mandatory_overrides(self):
        role, engine, settings = self.configure("quality")
        self.assertEqual("quality", role["vr_quality"])
        self.assertIn("bSmoothFrameRate=False", engine)
        for key, value in MANDATORY.items():
            self.assertIn(f"{key}={value}", settings)
        self.assertIn("DynamicShadows=True", settings)
        self.assertNotIn("SkeletalMeshLODBias=", settings)

    def test_balanced_reduces_only_distance_and_shadow_filter(self):
        _, _, settings = self.configure("balanced")
        self.assertIn("MaxDrawDistanceScale=0.9", settings)
        self.assertIn("ShadowFilterQualityBias=1", settings)
        self.assertIn("DynamicShadows=True", settings)

    def test_performance_has_the_documented_reductions(self):
        _, _, settings = self.configure("performance")
        for pair in ("MaxDrawDistanceScale=0.8", "ShadowFilterQualityBias=1",
                     "SkeletalMeshLODBias=1", "ParticleLODBias=1", "DynamicShadows=False",
                     "LightEnvironmentShadows=False", "StaticDecals=False"):
            self.assertIn(pair, settings)

    def test_quality_argument_is_vr_only_and_defaults_from_the_profile(self):
        import workshop_loadout as loadout
        args = friends.parse_options(["--vr"])
        self.assertIsNone(args.vr_quality)
        self.assertIsNone(args.vr_quality_requested)
        with tempfile.TemporaryDirectory() as tmp:
            args.profile_root = Path(tmp) / "profile"
            loadout.load_preferences(args)
        self.assertEqual("performance", args.vr_quality)
        with self.assertRaises(SystemExit):
            friends.parse_options(["--desktop", "--vr-quality", "balanced"])

    def test_headset_presets_resolve_for_solo_host_and_join(self):
        import workshop_loadout as loadout
        for mode in ("--solo", "--host", None):
            for name, expected in loadout.HEADSET_PRESETS.items():
                with self.subTest(mode=mode, preset=name), tempfile.TemporaryDirectory() as tmp:
                    args = friends.parse_options(([mode] if mode else []) + ["--vr", "--headset-preset", name])
                    args.profile_root = Path(tmp)
                    (Path(tmp) / "launcher.json").write_text('{"vr_quality":"quality"}')
                    loadout.load_preferences(args)
                    friends.validate_play_mode(args)
                    self.assertEqual(expected, (args.vr_quality, args.eye_render_percent))

    def test_headset_explicit_overrides_win_and_values_are_remembered(self):
        import workshop_loadout as loadout
        with tempfile.TemporaryDirectory() as tmp:
            args = friends.parse_options(["--solo", "--vr", "--headset-preset", "quest3",
                                          "--vr-quality", "balanced", "--eye-render-percent", "90"])
            args.profile_root = Path(tmp)
            loadout.load_preferences(args)
            self.assertEqual(("balanced", 90), (args.vr_quality, args.eye_render_percent))
            loadout.save_preferences(args)
            next_args = friends.parse_options(["--solo", "--vr"])
            next_args.profile_root = Path(tmp)
            loadout.load_preferences(next_args)
            self.assertEqual("balanced", next_args.vr_quality)
            self.assertIsNone(next_args.eye_render_percent)  # KFGame.ini owns saved scale.
            self.assertIsNone(next_args.headset_preset)

    def test_headset_preset_cannot_silently_disappear_in_desktop_profile(self):
        import workshop_loadout as loadout
        with self.assertRaises(SystemExit):
            friends.parse_options(["--desktop", "--headset-preset", "quest3"])
        with tempfile.TemporaryDirectory() as tmp:
            args = friends.parse_options(["--solo", "--headset-preset", "quest3"])
            args.profile_root = Path(tmp)
            (Path(tmp) / "launcher.json").write_text('{"vr":false}')
            loadout.load_preferences(args)
            with self.assertRaises(RuntimeError):
                friends.validate_play_mode(args)

    def test_frame_timings_is_opt_in_and_vr_only(self):
        role, _, _ = self.configure("quality")
        self.assertNotIn("-kf2vr-frame-timings", role["args"])
        role, _, _ = self.configure("quality", frame_timings=True)
        self.assertIn("-kf2vr-frame-timings", role["args"])
        self.assertNotIn("-kf2vr-vm-timings", role["args"])
        with self.assertRaises(SystemExit):
            friends.parse_options(["--desktop", "--frame-timings"])

    def test_threaded_render_is_remembered(self):
        import workshop_loadout as loadout
        self.assertIsNone(friends.parse_options(["--solo", "--vr"]).threaded_render)
        with tempfile.TemporaryDirectory() as tmp:
            args = friends.parse_options(["--solo", "--vr", "--threaded-render"])
            args.profile_root = Path(tmp)
            loadout.load_preferences(args)
            loadout.save_preferences(args)
            again = friends.parse_options(["--solo", "--vr"])
            again.profile_root = Path(tmp)
            loadout.load_preferences(again)
            self.assertTrue(again.threaded_render)
            off = friends.parse_options(["--solo", "--vr", "--no-threaded-render"])
            off.profile_root = Path(tmp)
            loadout.load_preferences(off)
            self.assertFalse(off.threaded_render)

    def test_threaded_render_replaces_onethread_and_is_vr_only(self):
        role, _, _ = self.configure("quality")
        self.assertIn("-onethread", role["args"])
        self.assertNotIn("-kf2vr-threaded-render", role["args"])
        role, _, _ = self.configure("quality", threaded_render=True)
        self.assertIn("-kf2vr-threaded-render", role["args"])
        self.assertNotIn("-onethread", role["args"])
        self.assertIn("-kf2vr-stereo", role["args"])
        with self.assertRaises(SystemExit):
            friends.parse_options(["--desktop", "--threaded-render"])


if __name__ == "__main__":
    unittest.main()
