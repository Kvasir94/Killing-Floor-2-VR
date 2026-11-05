"""Runtime catalog file/parser and canonical weapon selection contracts."""
import unittest
from weapons import catalog_from_log, select_weapons, weapon_path


class WeaponCatalogTests(unittest.TestCase):
    def test_registry_discovery_is_capability_data_not_execution(self):
        log = ('KF2VR_REPLAY_CATALOG index=1 weapon=KFGameContent.KFWeap_Pistol_9mm family=detachable hold=True dual=True secondary=False executed=False\n'
               'KF2VR_REPLAY_CATALOG index=2 weapon=KFGameContent.KFWeap_AssaultRifle_SCAR family=detachable hold=True dual=False secondary=False executed=False\n'
               'KF2VR_REPLAY_CATALOG_SUMMARY count=2 missing=0')
        result = catalog_from_log(log)
        self.assertTrue(result['complete'], result)
        self.assertFalse(result['execution_accepted'])
        self.assertEqual(['9mm', 'KFGameContent.KFWeap_AssaultRifle_SCAR'], select_weapons(['all'], result['weapons']))
        for broken in ('', log.replace('index=2', 'index=3'), log.replace('missing=0', 'missing=1'),
                       log.replace('count=2', 'count=1'), log.replace('hold=True', 'hold=Unknown')):
            self.assertFalse(catalog_from_log(broken)['complete'])

    def test_aliases_and_registered_paths_deduplicate_by_class(self):
        self.assertEqual(['9mm', 'deagle'], select_weapons(['9mm,KFGameContent.KFWeap_Pistol_9mm,deagle']))
        self.assertEqual('KFGameContent.KFWeap_AssaultRifle_SCAR', weapon_path('KFGameContent.KFWeap_AssaultRifle_SCAR'))
        for invalid in ('../file', 'Something.Bad', '9mm|False', 'KFGameContent.KFWeap_Test\nCases=other'):
            with self.assertRaises(ValueError): weapon_path(invalid)


if __name__ == '__main__':
    unittest.main()
