"""Personal graphics migration, typed transport and packaged runtime checks."""
import copy
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import friends
import workshop_loadout as settings
from epic_broker import graphics_payload
from package import validate_native_inventory, portable_receipt

class DlssSettingsTests(unittest.TestCase):
    def test_legacy_and_invalid_values_default_safely(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)
            for saved in ({}, {"dlss":"unknown","dlss_sharpness":True}, {"dlss":[],"dlss_sharpness":101}):
                (root/'launcher.json').write_text(json.dumps(saved))
                args=SimpleNamespace(profile_root=root,solo=True)
                settings.load_preferences(args)
                self.assertEqual((args.dlss,args.dlss_sharpness,args.hide_bile_lens),("off",0,True))
            (root/'launcher.json').write_text('{broken')
            args=SimpleNamespace(profile_root=root,solo=True)
            settings.load_preferences(args)
            with self.assertRaises(ValueError):settings.save_dlss_preferences(args)
            self.assertEqual((root/'launcher.json').read_text(),'{broken')

    def test_join_preserves_loadout_and_updates_personal_choices(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);path=root/'launcher.json'
            path.write_text(json.dumps({"mods":["ukfp"],"difficulty":"hard","unknown":42}))
            settings.save_dlss_preferences(SimpleNamespace(profile_root=root,dlss="quality",dlss_sharpness=17,hide_bile_lens=False))
            saved=json.loads(path.read_text());self.assertEqual(saved['mods'],['ukfp']);self.assertEqual(saved['unknown'],42)
            self.assertEqual((saved['dlss'],saved['dlss_sharpness'],saved['hide_bile_lens']),("quality",17,False))

    def test_typed_transport_rejects_injection_and_wrong_types(self):
        self.assertEqual(graphics_payload("quality",100,False),"quality\n100\n0\n")
        for values in (("off\nEVIL=1",0,True),("off",True,True),("off",101,True),("off",0,"1")):
            with self.assertRaises(ValueError):graphics_payload(*values)

    def test_role_isolation_and_cli_bounds(self):
        environment={"KF2VR_DLSS":"quality","KF2VR_HIDE_BILE_LENS":"1","PATH":"kept"}
        self.assertNotIn("KF2VR_DLSS",friends.role_environment(environment,{"role":"server","native_adapter":False}))
        role={"log":"session/game.log","role":"driver","native_adapter":True,"dlss":"quality","dlss_sharpness":50,"hide_bile_lens":True}
        result=friends.role_environment(environment,role)
        self.assertEqual(result['KF2VR_DLSS'],'quality');self.assertEqual(result['KF2VR_HIDE_BILE_LENS'],'1')
        for argv in (["--desktop","--dlss","quality"],["--vr","--dlss-sharpness","101"]):
            with self.assertRaises(SystemExit):friends.parse_options(argv)

    def test_runtime_inventory_requires_pinned_receipt(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);(root/'tools').mkdir()
            pins={"commit":"pin","files_sha256":{"lib/Windows_x86_64/rel/nvngx_dlss.dll":"runtime-hash"}}
            (root/'tools/ngx-pins.json').write_text(json.dumps(pins))
            native={"dlss_enabled":True,"ngx_sdk":pins,"artifacts_sha256":{"dinput8.dll":"adapter","openxr_loader.dll":"loader","nvngx_dlss.dll":"runtime-hash"},"server_artifacts_sha256":{"dinput8.dll":"server"}}
            portable=portable_receipt({**native, "local_log":"private-path"})
            self.assertTrue(portable["dlss_enabled"])
            self.assertEqual(portable["ngx_sdk"],pins)
            self.assertNotIn("local_log",portable)
            validate_native_inventory(root,portable)
            validate_native_inventory(root,native)
            for change in ('runtime','missing','receipt'):
                broken=copy.deepcopy(native)
                if change=='runtime':broken['artifacts_sha256']['nvngx_dlss.dll']='wrong'
                elif change=='missing':del broken['artifacts_sha256']['nvngx_dlss.dll']
                else:broken['ngx_sdk']['commit']='other'
                with self.assertRaises(RuntimeError):validate_native_inventory(root,broken)
            validate_native_inventory(root,{"artifacts_sha256":{"dinput8.dll":"a","openxr_loader.dll":"b"},"server_artifacts_sha256":{"dinput8.dll":"c"}})
