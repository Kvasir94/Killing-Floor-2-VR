"""Update notice: version comparison and silent failure, without touching the network."""
import unittest
from unittest.mock import patch

import launcher_updates as updates


class LauncherUpdateTests(unittest.TestCase):
    def test_versions_compare_numerically_across_tag_styles(self):
        self.assertEqual((0, 1, 0), updates.parse("0.1.0-alpha"))
        self.assertEqual((0, 10, 2), updates.parse("v0.10.2-alpha.20261014"))
        self.assertIsNone(updates.parse("nightly"))
        self.assertTrue(updates.newer("v0.2.0-alpha", "0.1.0-alpha"))
        self.assertTrue(updates.newer("v0.10.0", "0.9.9"))
        self.assertFalse(updates.newer("v0.1.0-alpha", "0.1.0-alpha"))
        self.assertFalse(updates.newer("v0.0.9", "0.1.0-alpha"))
        self.assertFalse(updates.newer("nightly", "0.1.0-alpha"))
        self.assertFalse(updates.newer("v9.0.0", ""))
        self.assertTrue(updates.newer("v0.2.0-alpha.20261024", "v0.2.0-alpha.20261011"))
        self.assertFalse(updates.newer("v0.2.0-alpha.20261011", "v0.2.0-alpha.20261024"))
        self.assertTrue(updates.newer("v0.2.0", "v0.2.0-alpha.20261024"))

    def test_failure_or_odd_replies_mean_no_notice(self):
        with patch.object(updates.urllib.request, "urlopen", side_effect=OSError("offline")):
            self.assertIsNone(updates.available_update("0.1.0-alpha"))
        for reply in (b"not json", b"[]", b'{"tag_name": 5}'):
            response = unittest.mock.MagicMock()
            response.__enter__.return_value.read.return_value = reply
            with self.subTest(reply=reply), patch.object(updates.urllib.request, "urlopen", return_value=response):
                self.assertIsNone(updates.available_update("0.1.0-alpha"))

    def test_newer_release_returns_tag_and_only_a_github_page(self):
        response = unittest.mock.MagicMock()
        response.__enter__.return_value.read.return_value = (
            b'{"tag_name": "v0.2.0-alpha", "html_url": "https://example.com/phish"}')
        with patch.object(updates.urllib.request, "urlopen", return_value=response):
            self.assertEqual(("v0.2.0-alpha", updates.RELEASES_PAGE), updates.available_update("0.1.0-alpha"))

    def test_release_older_than_the_installed_build_is_not_offered(self):
        build = "0.1.0-alpha-20261104-005158-ab2299ec1f32-p21"
        for tag, offered in (("v0.2.0-alpha.20261011", False), ("v0.3.0-alpha.20261104", False),
                             ("v0.3.1-alpha.20261104", True), ("v0.4.0-alpha.20261120", True)):
            response = unittest.mock.MagicMock()
            response.__enter__.return_value.read.return_value = f'{{"tag_name": "{tag}"}}'.encode()
            with self.subTest(tag=tag), patch.object(updates.urllib.request, "urlopen", return_value=response):
                found = updates.available_update("0.3.0-alpha.20261104", build=build)
                self.assertEqual(offered, found is not None)
                if tag == "v0.2.0-alpha.20261011":
                    self.assertIsNone(updates.available_update("0.1.0-alpha", build=build))


if __name__ == "__main__":
    unittest.main()
