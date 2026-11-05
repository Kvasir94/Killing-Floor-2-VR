"""Test-mode launch URL contract; no game execution."""
from types import SimpleNamespace
import unittest

import launch_menu


class TestModeUrlTests(unittest.TestCase):
    def test_off_leaves_the_host_url_unchanged(self):
        args = SimpleNamespace(map="KF-Outpost", mods=[])
        url = launch_menu.host_url(args)
        self.assertNotIn("KF2VRTestMode", url)
        self.assertNotIn(launch_menu.TEST_MODE_MUTATOR, url)

    def test_joins_the_existing_mutator_list(self):
        args = SimpleNamespace(map="KF-Outpost", mods=["ukfp"], test_mode=True)
        url = launch_menu.host_url(args)
        self.assertEqual(1, url.count("?Mutator="))
        self.assertIn("?Mutator=UnofficialKFPatch.UKFPMutator," + launch_menu.TEST_MODE_MUTATOR + "?", url)
        self.assertTrue(url.endswith("?KF2VRTestMode=1"))

    def test_adds_a_mutator_list_when_none_exists(self):
        url = launch_menu.with_test_mode("KF-Outpost?Game=KFGameContent.KFGameInfo_Survival",
                                         SimpleNamespace(test_mode=True))
        self.assertEqual("KF-Outpost?Game=KFGameContent.KFGameInfo_Survival?Mutator="
                         + launch_menu.TEST_MODE_MUTATOR + "?KF2VRTestMode=1", url)

    def test_add_mutator_does_not_duplicate(self):
        url = "X?Mutator=KF2VR.VRBootstrap,KF2VR.VRDemo?VRNormalGame=1"
        once = launch_menu.add_mutator(url, launch_menu.TEST_MODE_MUTATOR)
        self.assertEqual("X?Mutator=KF2VR.VRBootstrap,KF2VR.VRDemo," + launch_menu.TEST_MODE_MUTATOR
                         + "?VRNormalGame=1", once)
        self.assertEqual(once, launch_menu.add_mutator(once, launch_menu.TEST_MODE_MUTATOR))


if __name__ == "__main__":
    unittest.main()
