"""Preset/config persistence and player calibration ownership; no game processes."""
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import launcher_settings as settings
import settings_graphics
import vr_config
import workshop_loadout
import friends
from session import read_ini, set_ini

class SettingsPresetTests(unittest.TestCase):
    def setUp(self):
        temporary=tempfile.TemporaryDirectory(); self.addCleanup(temporary.cleanup)
        self.root=Path(temporary.name)
        for name in ('vr_config.profile_root','workshop_loadout.profile_root'):
            replacement=patch(name,return_value=self.root);replacement.start();self.addCleanup(replacement.stop)
        self.saved=SimpleNamespace(eye_render_percent=None,vr_quality='quality')

    def test_reload_styles_round_trip_without_touching_hands_or_recovery(self):
        settings.save({'PreferredWeaponHand':'0','WorldDropReturnSeconds':'27','ActiveControllerFitProfile':'Neutral'})
        # Player-owned reload preferences and the ammo rules survive every style
        # (PHYSICAL_RELOAD_SPEC R19, R44); the styles set the two magazine
        # options and Button leaves them as the last style set them (R47, R48).
        owned={'bKeepChamberedRound':True,'bReloadHints':False,'bReloadStopsSprint':True}
        settings.save(owned)
        for name,physical,racking,empty,newmag,fulleject in (('Manual',True,False,True,True,False),
                ('Realistic',True,True,False,False,True),('Button',False,False,False,False,True)):
            settings.save(settings.RELOAD_PRESETS[name])
            actual=settings.load(self.saved)
            self.assertEqual(name,settings.preset_name('reload_mode',actual))
            self.assertEqual((physical,racking,empty),(actual['bInteractiveReloads'],actual['bFreeWeaponCycling'],actual['bEmptyTriggerReloads']))
            self.assertEqual((newmag,fulleject),(actual['bGrabReleasesMagazine'],actual['bAllowFullMagazineEject']))
            self.assertEqual(owned,{key:actual[key] for key in owned})
            self.assertEqual(('0','27','Neutral'),(actual['PreferredWeaponHand'],actual['WorldDropReturnSeconds'],actual['ActiveControllerFitProfile']))
        # RELOAD BY HAND also cycles by hand; there is no separate cycling switch (R50).
        settings.save(settings.RELOAD_PRESETS['Manual'])
        self.assertEqual('Manual',settings.preset_name('reload_mode',settings.load(self.saved)))
        settings.save({'bEmptyTriggerReloads':False})
        self.assertEqual('Custom',settings.preset_name('reload_mode',settings.load(self.saved)))
        # A magazine option a style sets also counts toward its name (R42).
        for name,key in (('Manual','bGrabReleasesMagazine'),('Realistic','bAllowFullMagazineEject')):
            settings.save(settings.RELOAD_PRESETS[name])
            settings.save({key:not settings.RELOAD_PRESETS[name][key]})
            self.assertEqual('Custom',settings.preset_name('reload_mode',settings.load(self.saved)))

    def test_ammo_rules_preset_names_follow_the_three_rules(self):
        for name in ('Standard','Realistic'):
            settings.save(settings.AMMO_PRESETS[name])
            self.assertEqual(name,settings.ammo_preset_name(settings.load(self.saved)))
        settings.save({'bLoseReloadAmmo':False})
        self.assertEqual('Custom',settings.ammo_preset_name(settings.load(self.saved)))
        self.assertEqual('Standard',settings.ammo_preset_name(settings.defaults()))

    def test_comfort_selection_keeps_tuning_and_fit(self):
        settings.save({'SmoothTurnScale':'0.65','SnapTurnDegrees':'45','MovementHand':'1','bSeatedPlay':'True','BlinkScale':'0.0'})
        for name,target in settings.LOCOMOTION_PRESETS.items():
            settings.save(target)
            actual=settings.load(self.saved)
            self.assertEqual(name,settings.preset_name('locomotion',actual))
            self.assertEqual(('0.65','45','1','True','0.0'),tuple(actual[k] for k in ('SmoothTurnScale','SnapTurnDegrees','MovementHand','bSeatedPlay','BlinkScale')))

    def test_player_reset_keeps_custom_calibration_and_session_setup(self):
        text=vr_config.apply_preferences('')
        text=set_ini(text,settings.HANDS,{'ActiveControllerFitProfile':'Relaxed','FirearmAimPitchDegrees':'-12.75','AmmoPouchAdjustment':'(X=2,Y=3,Z=4)','GrenadeZoneScale':'1.25','WristwatchScale':'1.4'})
        text=set_ini(text,settings.SESSION,{'SpatialMenuDistance':'2.15','LocalMap':'KF-Outpost'})
        (self.root/'KFGame.ini').write_text(text,encoding='utf-16')
        settings.save(settings.defaults())
        actual=vr_config.values(read_ini(self.root/'KFGame.ini'),settings.HANDS)
        self.assertEqual(('-12.75','(X=2,Y=3,Z=4)','1.25','1.4'),tuple(actual[k] for k in ('FirearmAimPitchDegrees','AmmoPouchAdjustment','GrenadeZoneScale','WristwatchScale')))
        session=vr_config.values(read_ini(self.root/'KFGame.ini'),settings.SESSION)
        self.assertEqual(('2.15','KF-Outpost'),(session['SpatialMenuDistance'],session['LocalMap']))
        self.assertEqual('1.00',session['SmoothTurnScale'])

    def test_graphics_selection_preserves_bloom_and_corpse_rules(self):
        settings.save({'Bloom':'0','MaxDeadBodies':'26','bAllowRagdollAndGoreOnDeadBodies':False})
        settings_graphics.save(settings_graphics.TIERS['performance'],self.root)
        actual=settings.load(self.saved)
        self.assertEqual(('0','26',False),(actual['Bloom'],actual['MaxDeadBodies'],actual['bAllowRagdollAndGoreOnDeadBodies']))
        self.assertEqual(('1','0','3'),(actual['CharacterDetail'],actual['EffectsQuality'],actual['TextureFiltering']))
        # Low FX keeps footsteps and corpse reaction tuning in a separate owner.
        data=settings_graphics.read(self.root,'performance')
        self.assertEqual('True',data['KFGame.ini']['KFGame.KFPawn']['bAllowFootstepSounds'])

    def test_audio_and_stock_changes_queue_only_the_edited_shared_values(self):
        settings.save({'Master':'67.5','MusicVocals':True,'ClassicColors':'True'})
        text=read_ini(self.root/'KFGame.ini')
        audio=vr_config.values(text,'KF2VR.VRPlayerAudio')
        stock=vr_config.values(text,'KF2VR.VRStockPreferences')
        self.assertEqual(('67.5','33'),(audio['Master'],audio['PendingMask']))
        self.assertEqual(('True','16'),(stock['ClassicColors'],stock['PendingMask']))

    def test_gore_default_and_shared_profile_use_the_raw_restriction_level(self):
        option=settings.BY_KEY['GoreIntensity']
        defaults=settings.defaults('Graphics & HUD')
        self.assertEqual('0',defaults['GoreIntensity'])
        self.assertEqual('High',settings.labels(option,'0')['0'])
        settings.save({'GoreIntensity':'0'})
        stock=vr_config.values(read_ini(self.root/'KFGame.ini'),'KF2VR.VRStockPreferences')
        self.assertEqual(('0','1'),(stock['GoreIntensity'],stock['PendingMask']))
        settings.save({'GoreIntensity':'2'})
        current=settings.load(self.saved)['GoreIntensity']
        self.assertEqual('Low',settings.labels(option,current)[current])

    def test_invalid_integer_edit_does_not_write_either_store(self):
        with self.assertRaises(ValueError):settings.save({'dlss_sharpness':'12.5','dlss':'off'})
        self.assertFalse((self.root/'launcher.json').exists())
        self.assertFalse((self.root/'vr-graphics.json').exists())

    def test_calibration_axis_edits_preserve_other_axes_and_survive_reset(self):
        settings.save({'WristwatchOffset.X':'2.5','WristwatchOffset.Y':'-3','WristwatchRotation.Yaw':'8192',
                       'AmmoPouchAdjustment.Y':'4','ChestGrenadeOffset.Z':'12','HandWristAdjust.X':'1.5'})
        settings.save({'WristwatchOffset.Z':'-1','AmmoPouchAdjustment.X':'2'})
        actual=settings.load(self.saved)
        self.assertEqual(('2.5','-3','-1','8192','4','12','1.5'),tuple(actual[key] for key in
            ('WristwatchOffset.X','WristwatchOffset.Y','WristwatchOffset.Z','WristwatchRotation.Yaw','AmmoPouchAdjustment.Y','ChestGrenadeOffset.Z','HandWristAdjust.X')))
        settings.save(settings.defaults())
        self.assertEqual('2.5',settings.load(self.saved)['WristwatchOffset.X'])
        self.assertEqual('8192',settings.load(self.saved)['WristwatchRotation.Yaw'])
        with self.assertRaises(ValueError):settings.save({'AmmoPouchAdjustment.Y':'26'})

    def test_shadow_override_changes_matching_until_a_tier_is_selected(self):
        self.assertEqual('3',settings.load(self.saved)['ShadowQuality'])
        settings.save({'MaxShadowResolution':'2048'})
        self.assertEqual('custom',settings.load(self.saved)['ShadowQuality'])
        settings_graphics.save(settings_graphics.TIERS['balanced'],self.root)
        actual=settings.load(self.saved)
        self.assertEqual(('1','1024'),(actual['ShadowQuality'],actual['MaxShadowResolution']))

    def test_workshop_availability_distinguishes_unknown_mismatch_and_match(self):
        package=self.root/'release';package.mkdir()
        self.assertIsNone(workshop_loadout.desktop_workshop_availability(package,self.root))
        (package/'release.json').write_text(json.dumps({'script_build':{'packages_sha256':{'KF2VR.u':'AAAA'}}}))
        item=self.root/workshop_loadout.KF2VR_WORKSHOP_ID;item.mkdir()
        (item/'content.json').write_text(json.dumps({'files_sha256':{'BrewedPC/KF2VR.u':'BBBB'}}))
        self.assertFalse(workshop_loadout.desktop_workshop_availability(package,self.root))
        (item/'content.json').write_text(json.dumps({'files_sha256':{'BrewedPC/kf2vr.u':'aaaa'}}))
        self.assertTrue(workshop_loadout.desktop_workshop_availability(package,self.root))

    def test_legacy_effect_capability_cannot_override_graphics_controls(self):
        configs=self.root/'session';configs.mkdir()
        for filename in ('KFEngine.ini','KFSystemSettings.ini','KFGame.ini'):
            (configs/filename).write_text('',encoding='utf-16')
        text=''
        for section in (settings.HANDS,vr_config.ALIASES[settings.HANDS]):
            text=set_ini(text,section,{'bVRScreenEffects':'False'})
        (self.root/'KFGame.ini').write_text(text,encoding='utf-16')
        args=friends.parse_options(['--solo','--vr','--vr-quality','balanced'])
        args.profile_root=self.root
        workshop_loadout.load_preferences(args)
        role={'role':'driver','args':['join'],'config_root':str(configs),'native_adapter':False}
        with patch.object(friends,'role_config',return_value=role):
            friends.configure_role(self.root,'driver',self.root,self.root,args)
        actual=read_ini(configs/'KFGame.ini')
        for section in (settings.HANDS,vr_config.ALIASES[settings.HANDS]):
            self.assertEqual('True',vr_config.values(actual,section)['bVRScreenEffects'])

    def test_each_session_starts_private_with_fun_modifiers_off(self):
        (self.root/'KFGame.ini').write_text('[KF2VR.VRHandsBridge]\nbAllowOtherWeaponPickup=True\nbBoxingGloves=True\nbSuperStrength=True\n',encoding='utf-16')
        config=self.root/'session'; config.mkdir()
        vr_config.import_preferences(config,root=self.root)
        text=read_ini(config/'KFGame.ini')
        for section in (settings.HANDS,vr_config.ALIASES[settings.HANDS]):
            values=vr_config.values(text,section)
            self.assertEqual(('False',)*3,tuple(values[k] for k in ('bAllowOtherWeaponPickup','bBoxingGloves','bSuperStrength')))

    def test_solo_and_host_remember_match_choices_separately(self):
        for mode,map_name,difficulty,length in (('solo','KF-Outpost','hard','long'),('host','KF-BurningParis','normal','medium')):
            args=friends.parse_options(['--'+mode,'--vr','--map',map_name,'--difficulty',difficulty,'--game-length',length])
            args.profile_root=self.root;workshop_loadout.load_preferences(args);workshop_loadout.save_preferences(args)
        for mode,expected in (('solo',('KF-Outpost','hard','long')),('host',('KF-BurningParis','normal','medium'))):
            args=friends.parse_options(['--'+mode,'--vr']);args.profile_root=self.root;workshop_loadout.load_preferences(args)
            self.assertEqual(expected,(args.map,args.difficulty,args.game_length))

if __name__=='__main__':unittest.main()
