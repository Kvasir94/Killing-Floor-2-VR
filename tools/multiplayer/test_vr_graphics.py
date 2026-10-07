"""Production launch/config/profile round trips; no game or real profile."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import friends
import vr_config
import vr_graphics
import workshop_loadout
from session import read_ini, set_ini


class VrGraphicsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.profile = self.root / "profile"

    def configure(self, name, mode="solo", extra=()):
        flags = [] if mode == "join" else ["--" + mode]
        args = friends.parse_options(flags + ["--vr", "--prepare-only"] + list(extra))
        args.profile_root = self.profile
        args.cache_root = self.root / "cache"
        workshop_loadout.load_preferences(args)
        configs = self.root / name
        configs.mkdir()
        (configs / "KFEngine.ini").write_text("[Engine.Engine]\nbSmoothFrameRate=True\n", encoding="utf-16")
        (configs / "KFGame.ini").write_text(
            "[KFGame.KFGameEngine]\n[Engine.WorldInfo]\nEmitterPoolScale=1.0\n"
            "DestructionLifetimeScale=1\nbAllowExplosionLights=True\n"
            "[KFGame.KFGoreManager]\nMaxDeadBodies=15\nMaxBloodEffects=25\n", encoding="utf-16")
        (configs / "KFSystemSettings.ini").write_text(
            "[SystemSettings]\nMotionBlur=True\nDynamicShadows=True\nParticleLODBias=0\n"
            "Distortion=True\nMaxShadowResolution=1024\nBloom=True\nMaxAnisotropy=16\n"
            "TEXTUREGROUP_World=(MinLODSize=1,MaxLODSize=4096,LODBias=0,MinMagFilter=aniso,MipFilter=point)\n",
            encoding="utf-16")
        role = {"role": "driver", "args": ["join"], "log": str(self.root / "game.log"),
                "config_root": str(configs), "native_adapter": False}
        with patch.object(friends, "role_config", return_value=role):
            result = friends.configure_role(self.root, "driver", self.root / "user", self.root / "game", args)
        return configs, result

    def edit(self, configs, filename, section, values):
        path = configs / filename
        path.write_text(set_ini(read_ini(path), section, values), encoding="utf-16")

    def values(self, configs, filename="KFSystemSettings.ini", section="SystemSettings"):
        return vr_config.values(read_ini(configs / filename), section)

    def export(self, configs, mode="solo"):
        vr_config.export_preferences(configs, root=self.profile, network=mode != "solo")

    def saved(self):
        return json.loads((self.profile / vr_graphics.PROFILE_FILE).read_text())

    def test_manual_shadow_effect_and_script_changes_survive_all_player_modes(self):
        for store, mode in (("steam", "solo"), ("steam", "host"), ("steam", "join"), ("epic", "solo")):
            label = store + "-" + mode
            configs, role = self.configure("first-" + label, mode, ("--store", store))
            self.assertEqual("performance", role["vr_quality"])
            self.edit(configs, "KFSystemSettings.ini", "SystemSettings", {
                "ParticleLODBias": "2", "Distortion": "False", "MaxShadowResolution": "256"})
            self.edit(configs, "KFGame.ini", "Engine.WorldInfo", {"EmitterPoolScale": "0.25"})
            self.edit(configs, "KFGame.ini", "KFGame.KFGoreManager", {"MaxDeadBodies": "8"})
            self.export(configs, mode)
            following, _ = self.configure("second-" + label, mode, ("--store", store))
            native = self.values(following)
            self.assertEqual(("2", "False", "256"),
                             (native["ParticleLODBias"], native["Distortion"], native["MaxShadowResolution"]))
            self.assertEqual("0.25", self.values(following, "KFGame.ini", "Engine.WorldInfo")["EmitterPoolScale"])
            self.assertEqual("8", self.values(following, "KFGame.ini", "KFGame.KFGoreManager")["MaxDeadBodies"])

    def test_solo_and_network_share_graphics_and_do_not_export_unchanged_defaults(self):
        configs, _ = self.configure("first")
        self.export(configs)
        self.assertEqual({}, self.saved()["values"])
        self.edit(configs, "KFSystemSettings.ini", "SystemSettings", {"Bloom": "False"})
        self.export(configs)
        self.assertEqual({"KFSystemSettings.ini": {"SystemSettings": {"Bloom": "False"}}}, self.saved()["values"])
        configs, _ = self.configure("host", "host")
        self.assertEqual("False", self.values(configs)["Bloom"])
        self.export(configs, "host")
        configs, _ = self.configure("solo-again")
        self.assertEqual("False", self.values(configs)["Bloom"])

    def test_explicit_quality_and_headset_preset_replace_old_custom_edits_after_play(self):
        for index, extra in enumerate((("--vr-quality", "performance"), ("--headset-preset", "quest3"))):
            configs, _ = self.configure("custom" + str(index))
            self.edit(configs, "KFSystemSettings.ini", "SystemSettings", {"ParticleLODBias": "3", "Bloom": "False"})
            self.export(configs)
            old_profile = (self.profile / vr_graphics.PROFILE_FILE).read_bytes()
            configs, _ = self.configure("explicit" + str(index), extra=extra)
            self.assertEqual(("1", "True"), (self.values(configs)["ParticleLODBias"], self.values(configs)["Bloom"]))
            # Preparing an override is not playing it; do not discard preferences yet.
            self.assertEqual(old_profile, (self.profile / vr_graphics.PROFILE_FILE).read_bytes())
            self.edit(configs, "KFSystemSettings.ini", "SystemSettings", {"MaxShadowResolution": "512"})
            self.export(configs)
            configs, _ = self.configure("after-explicit" + str(index))
            self.assertEqual(("1", "True", "512"), (self.values(configs)["ParticleLODBias"],
                             self.values(configs)["Bloom"], self.values(configs)["MaxShadowResolution"]))

    def test_texture_edits_merge_only_changed_bias_and_filter_members(self):
        configs, _ = self.configure("texture")
        self.edit(configs, "KFSystemSettings.ini", "SystemSettings", {
            "MaxAnisotropy": "4",
            "TEXTUREGROUP_World": "(MinLODSize=2,MaxLODSize=8192,LODBias=2,MinMagFilter=linear,MipFilter=point)"})
        self.export(configs)
        saved = self.saved()["values"]["KFSystemSettings.ini"]["SystemSettings"]
        self.assertEqual({"LODBias": "2", "MinMagFilter": "linear"}, saved["TEXTUREGROUP_World"])
        configs, _ = self.configure("new-texture")
        members = vr_graphics.texture_members(self.values(configs)["TEXTUREGROUP_World"])
        self.assertEqual(("1", "4096", "2", "linear", "point"),
                         tuple(members[name] for name in ("minlodsize", "maxlodsize", "lodbias", "minmagfilter", "mipfilter")))
        self.assertEqual("4", self.values(configs)["MaxAnisotropy"])
        self.edit(configs, "KFSystemSettings.ini", "SystemSettings", {
            "TEXTUREGROUP_World": "(MinLODSize=1,MaxLODSize=4096,LODBias=2,MinMagFilter=linear,MipFilter=linear)"})
        self.export(configs)
        self.assertEqual({"LODBias": "2", "MinMagFilter": "linear", "MipFilter": "linear"},
                         self.saved()["values"]["KFSystemSettings.ini"]["SystemSettings"]["TEXTUREGROUP_World"])

    def test_profile_rejects_display_connection_comfort_unknown_and_invalid_values(self):
        self.profile.mkdir()
        vr_graphics.write_record(self.profile / vr_graphics.PROFILE_FILE, {"schema": 1, "values": {
            "KFEngine.ini": {"Engine.Engine": {"GameViewportClientClassName": "Other"}},
            "../outside.ini": {"SystemSettings": {"Bloom": "False"}},
            "KFSystemSettings.ini": {"SystemSettings": {
                "ResX": "8000", "ResY": "9000", "Fullscreen": "True", "MotionBlur": "True",
                "UseVsync": "True", "AmbientOcclusion": "True", "Bloom": "False",
                "ParticleLODBias": "1\nResX=8000", "MaxShadowResolution": "inf",
                "GlobalShadowDistanceScale": "nan", "MaxAnisotropy": "17",
                "TEXTUREGROUP_World": {"LODBias": "3", "MaxLODSize": "8192", "MinMagFilter": "evil"}}},
            "KFGame.ini": {"IpDrv.TcpNetDriver": {"Password": "secret"},
                           "KFGame.KFGoreManager": {"MaxDeadBodies": "1.5"}}}})
        configs, _ = self.configure("sanitized")
        native = self.values(configs)
        self.assertEqual("False", native["Bloom"])
        self.assertEqual("False", native["MotionBlur"])
        self.assertNotIn("ResX", native)
        self.assertEqual("1", native["ParticleLODBias"])
        self.assertEqual("1024", native["MaxShadowResolution"])
        self.assertEqual("16", native["MaxAnisotropy"])
        self.assertEqual("15", self.values(configs, "KFGame.ini", "KFGame.KFGoreManager")["MaxDeadBodies"])
        self.assertNotIn("Password", self.values(configs, "KFGame.ini", "IpDrv.TcpNetDriver"))
        self.assertFalse((self.root / "outside.ini").exists())
        self.export(configs)
        saved = self.saved()["values"]
        self.assertEqual({"KFSystemSettings.ini": {"SystemSettings": {
            "Bloom": "False", "TEXTUREGROUP_World": {"LODBias": "3"}}}}, saved)

    def test_runtime_serialization_format_does_not_turn_defaults_into_edits(self):
        configs, _ = self.configure("formats")
        self.edit(configs, "KFSystemSettings.ini", "SystemSettings", {"DynamicShadows": "false", "MaxShadowResolution": "1024.000"})
        self.edit(configs, "KFGame.ini", "Engine.WorldInfo", {"EmitterPoolScale": "1.000000"})
        self.export(configs)
        self.assertEqual({}, self.saved()["values"])

    def test_missing_snapshot_does_not_export_launch_values_and_corrupt_profile_falls_back(self):
        configs, _ = self.configure("missing")
        (configs / vr_graphics.SNAPSHOT_FILE).unlink()
        self.export(configs)
        self.assertFalse((self.profile / vr_graphics.PROFILE_FILE).exists())
        self.profile.mkdir(exist_ok=True)
        for index, text in enumerate(("{", "[]", '{"schema":99,"values":{}}')):
            (self.profile / vr_graphics.PROFILE_FILE).write_text(text)
            configs, _ = self.configure("corrupt" + str(index))
            self.assertEqual("1", self.values(configs)["ParticleLODBias"])


if __name__ == "__main__":
    unittest.main()
