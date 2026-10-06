import tempfile
import unittest
from pathlib import Path
import friends
import promo_session


class PromoSessionTests(unittest.TestCase):
    def roles(self, root):
        return [dict(role="driver", native_adapter=True, args=["-kf2vr-stereo"], log=str(root/"driver/game.log")),
                dict(role="server", native_adapter=False, server_adapter=True, args=[], log=str(root/"server/game.log")),
                dict(role="teammate", native_adapter=True, args=["-kf2vr-hand-replay"], log=str(root/"teammate/game.log"))]

    def test_off_by_default_and_inherited_controls_cleared(self):
        with tempfile.TemporaryDirectory() as tmp:
            roles = self.roles(Path(tmp))
            self.assertIsNone(promo_session.configure(roles, False))
            for role in roles:
                env = friends.role_environment({"Path":"ok", "KF2VR_PROMO_LOG_PATH":"other-session",
                                                "kf2vr_promo_session":"old"}, role)
                self.assertEqual("ok", env["Path"])
                self.assertFalse(any("PROMO" in key.upper() for key in env))

    def test_one_session_shared_by_live_roles_and_output_is_scoped(self):
        with tempfile.TemporaryDirectory() as tmp:
            roles = self.roles(Path(tmp)); session = promo_session.configure(roles, True)
            self.assertEqual(session, roles[0]["promo_session"])
            self.assertEqual(session, roles[1]["promo_session"])
            self.assertNotIn("promo_session", roles[2])
            for role in roles[:2]:
                env = friends.role_environment({}, role)
                self.assertEqual(session, env["KF2VR_PROMO_SESSION"])
                self.assertEqual(role["role"], env["KF2VR_PROMO_ROLE"])
                self.assertEqual(str(Path(role["log"]).with_name("promo-events.jsonl")), env["KF2VR_PROMO_LOG_PATH"])
            self.assertNotEqual(session, promo_session.configure(self.roles(Path(tmp)), True))

    def test_forged_sessions_outputs_and_roles_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            roles = self.roles(Path(tmp)); promo_session.configure(roles, True)
            for changes in ({"promo_session":"private-chat\""}, {"promo_log":"other.jsonl"},
                            {"native_adapter":False}, {"args":["-kf2vr-hand-replay"]}):
                with self.subTest(changes=changes), self.assertRaises(ValueError):
                    promo_session.environment({**roles[0], **changes})

    def test_switch_is_session_only_and_requires_live_vr(self):
        args = friends.parse_options(["--solo", "--vr", "--promo-events"])
        self.assertTrue(args.promo_events)
        self.assertFalse(friends.parse_options(["--solo", "--vr"]).promo_events)
        for flags in (["--solo", "--desktop", "--promo-events"],
                      ["--host", "--vr", "--replay-teammate", "--promo-events"]):
            with self.subTest(flags=flags), self.assertRaises(RuntimeError):
                friends.validate_play_mode(friends.parse_options(flags))


if __name__ == "__main__":
    unittest.main()
