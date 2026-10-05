import base64
import json
import unittest

import friends
import join_code


class JoinCodeTests(unittest.TestCase):
    def setUp(self):
        self.details = dict(address="play.example.com", password="private-123", port=7777,
                            query_port=27015, build="0.1.0-alpha-test", mods=[], map="KF-BurningParis")

    def test_round_trip_connection_and_content(self):
        for mods in ([], ["ukfp", "friendlyhud"]):
            self.details["mods"] = mods
            code = join_code.encode(self.details)
            self.assertEqual(self.details, join_code.decode(code, self.details["build"]))
            args = friends.parse_options(["--vr", "--address", code])
            self.assertEqual(code, args.address)

    def test_wrong_package_has_actionable_error(self):
        with self.assertRaisesRegex(ValueError, "same ZIP"):
            join_code.decode(join_code.encode(self.details), "different-build")

    def test_rejects_malformed_and_unsafe_payloads(self):
        for key, value in (("address", "host?command=bad"), ("password", "bad?option"),
                           ("port", True), ("port", 80), ("query_port", 7787),
                           ("mods", ["arbitrary"]), ("mods", ["friendlyhud"]),
                           ("map", "../KF-Map"), ("build", None)):
            data = dict(self.details, **{key: value})
            code = join_code.PREFIX + base64.urlsafe_b64encode(json.dumps(data).encode()).decode().rstrip("=")
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                join_code.decode(code, self.details["build"])
        for code in ("KF2VR2:abcd", "KF2VR1:!", "KF2VR1:a", "KF2VR1:" + "a" * 2049):
            with self.subTest(code=code[:30]), self.assertRaises(ValueError):
                join_code.decode(code, self.details["build"])

    def test_public_address_requires_global_ipv4(self):
        self.assertIsNone(join_code.public_address('"ServerHost":"127.0.0.1"'))
        self.assertIsNone(join_code.public_address('Public IP 192.168.1.134'))
        self.assertIsNone(join_code.public_address('Public IP 999.1.1.1'))
        self.assertEqual("8.8.8.8", join_code.public_address('Successfully reuse cached Public IP 8.8.8.8 for Playfab Registration'))
        self.assertEqual("1.1.1.1", join_code.public_address('"ServerHost":"1.1.1.1"'))

    def test_share_address_is_host_only(self):
        self.assertEqual("host.example.com", friends.parse_options(["--host", "--share-address", "host.example.com"]).share_address)
        with self.assertRaises(SystemExit):
            friends.parse_options(["--share-address", "host.example.com"])


if __name__ == "__main__":
    unittest.main()
