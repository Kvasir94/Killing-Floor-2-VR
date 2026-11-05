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
    def test_retired_flex_cannot_be_restored_by_a_saved_choice_or_override(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / 'launcher.json'
            for value in (None, [], 2, 'invalid'):
                path.write_text(json.dumps({'flex': value, 'mods': ['ukfp']}))
                args = friends.parse_options(['--solo', '--desktop'])
                args.profile_root = root
                settings.load_preferences(args)
                self.assertEqual(args.flex, 'off')
            for mode in ('off', 'gibs', 'fluids'):
                args = friends.parse_options(['--solo', '--vr', '--flex', mode])
                args.profile_root = root
                settings.load_preferences(args)
                settings.save_preferences(args)
                joined = friends.parse_options(['--desktop'])
                joined.profile_root = root
                settings.load_preferences(joined)
                self.assertEqual(joined.flex, 'off')
                joined.flex = 'gibs'
                settings.save_dlss_preferences(joined)
                self.assertNotIn('flex', json.loads(path.read_text()))
                self.assertEqual(json.loads(path.read_text())['mods'], ['ukfp'])
            with self.assertRaises(SystemExit):
                friends.parse_options(['--flex', 'invalid'])

    def test_legacy_and_invalid_values_default_safely(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)
            for saved in ({}, {"dlss":"unknown","dlss_sharpness":True}, {"dlss":[],"dlss_sharpness":101}):
                (root/'launcher.json').write_text(json.dumps(saved))
                args=SimpleNamespace(profile_root=root,solo=True)
                settings.load_preferences(args)
                self.assertEqual((args.dlss,args.dlss_sharpness,args.hide_bile_lens),("auto",50,True))
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

    def test_join_saves_only_an_explicit_quality_preset(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / 'launcher.json'
            original = {'vr_quality': 'quality', 'mods': ['ukfp'], 'difficulty': 'hard',
                        'map': 'KF-Outpost', 'last_session': 'host'}
            path.write_text(json.dumps(original))
            for flags, expected in (([], 'quality'), (['--vr-quality', 'balanced'], 'balanced')):
                args = friends.parse_options(['--vr'] + flags)
                args.profile_root = root
                settings.load_preferences(args)
                self.assertEqual(args.vr_quality, expected)
                settings.save_dlss_preferences(args)
                saved = json.loads(path.read_text())
                self.assertEqual(saved['vr_quality'], expected)
                self.assertEqual({key: saved[key] for key in original if key != 'vr_quality'},
                                 {key: value for key, value in original.items() if key != 'vr_quality'})
            # A window resolved before a newer choice cannot overwrite it on Keep.
            args.vr_quality_requested = None
            args.vr_quality = 'performance'
            settings.save_dlss_preferences(args)
            self.assertEqual(json.loads(path.read_text())['vr_quality'], 'balanced')

    def test_typed_transport_rejects_injection_and_wrong_types(self):
        self.assertEqual(graphics_payload("quality",100,False),"quality\n100\n0\n1\n")
        self.assertEqual(graphics_payload("off",0,True,False),"off\n0\n1\n0\n")
        for values in (("off\nEVIL=1",0,True),("off",True,True),("off",101,True),("off",0,"1")):
            with self.assertRaises(ValueError):graphics_payload(*values)
        with self.assertRaises(ValueError):graphics_payload("off",0,True,"1\nEVIL=1")

    def test_effect_preferences_round_trip_without_changing_host_loadout(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);path=root/'launcher.json'
            path.write_text(json.dumps({"mods":["ukfp"],"difficulty":"hard"}))
            args=SimpleNamespace(profile_root=root,solo=True)
            settings.load_preferences(args)
            self.assertEqual((args.single_pass,args.hbao,args.reflections,args.hide_blood_lens),(True,True,True,True))
            args.hbao=args.reflections=True
            args.hide_blood_lens=False
            settings.save_preferences(args)
            joined=friends.parse_options(['--vr'])
            joined.profile_root=root
            settings.load_preferences(joined)
            self.assertEqual((joined.single_pass,joined.hbao,joined.reflections,joined.hide_blood_lens),(True,True,True,False))
            joined.hide_blood_lens=True
            settings.save_dlss_preferences(joined)
            saved=json.loads(path.read_text())
            self.assertEqual(saved['mods'],['ukfp'])
            self.assertTrue(saved['hbao'] and saved['reflections'] and saved['hide_blood_lens'])

    def test_saved_effect_choices_and_explicit_overrides_survive_new_defaults(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)
            for saved in (False, True):
                (root/'launcher.json').write_text(json.dumps(dict(hbao=saved,reflections=saved)))
                for flags,expected in (([],saved),(['--hbao','--reflections'],True),
                                       (['--no-hbao','--no-reflections'],False)):
                    args=friends.parse_options(['--solo','--vr']+flags); args.profile_root=root
                    settings.load_preferences(args)
                    self.assertTrue(args.single_pass)
                    self.assertEqual((args.hbao,args.reflections),(expected,)*2)

    def test_epic_uses_single_pass_whatever_was_saved(self):
        from epic_manual import validate_options
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)
            for saved in ({},{'single_pass':False}):
                (root/'launcher.json').write_text(json.dumps(saved))
                args=friends.parse_options(['--solo','--vr','--store','epic']); args.profile_root=root
                settings.load_preferences(args)
                self.assertEqual((args.single_pass,args.hbao,args.reflections),(True,True,True))
                validate_options(args)

    def test_role_isolation_and_cli_bounds(self):
        environment={"KF2VR_DLSS":"quality","KF2VR_HIDE_BILE_LENS":"1","PATH":"kept"}
        self.assertNotIn("KF2VR_DLSS",friends.role_environment(environment,{"role":"server","native_adapter":False}))
        role={"log":"session/game.log","role":"driver","native_adapter":True,"dlss":"quality","dlss_sharpness":50,"hide_bile_lens":True}
        result=friends.role_environment(environment,role)
        self.assertEqual(result['KF2VR_DLSS'],'quality');self.assertEqual(result['KF2VR_HIDE_BILE_LENS'],'1')
        for argv in (["--desktop","--dlss","quality"],["--vr","--dlss-sharpness","101"]):
            with self.assertRaises(SystemExit):friends.parse_options(argv)
        role['hide_blood_lens']=True
        self.assertEqual(friends.role_environment(environment,role)['KF2VR_HIDE_BLOOD_LENS'],'1')
        self.assertNotIn('KF2VR_HIDE_BLOOD_LENS',friends.role_environment(
            {'KF2VR_HIDE_BLOOD_LENS':'1'},{'role':'server','native_adapter':False}))
        for option in ('--hbao','--reflections','--hide-blood-lens'):
            with self.assertRaises(SystemExit):friends.parse_options(['--desktop',option])

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
            for enabled in (None, False):
                with self.subTest(dlss_enabled=enabled), self.assertRaisesRegex(RuntimeError, "require DLSS support"):
                    validate_native_inventory(root,{"dlss_enabled":enabled,"artifacts_sha256":{"dinput8.dll":"a","openxr_loader.dll":"b"},"server_artifacts_sha256":{"dinput8.dll":"c"}})
