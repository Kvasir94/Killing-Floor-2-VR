import json
import tempfile
import unittest
from pathlib import Path

import promo_events as promo
import promo_shots as shots

SESSION = "01234567-89ab-cdef-0123-456789abcdef"
HZ = 1000


class Log:
    def __init__(self):
        self.rows, self.seq = [], 0

    def add(self, event, second, role="driver", **fields):
        self.seq += 1
        tick = 1000 + int(second * HZ)
        row = dict(schema=promo.SCHEMA, session_id=SESSION, role=role, event=event,
                   event_id=self.seq, qpc_ticks=tick, t_us=tick)
        row.update(fields)
        self.rows.append(row)
        return self

    def kill(self, second, victim, **fields):
        base = dict(player_id=1, world_epoch=1, victim_id=victim, hit_id=self.seq + 1,
                    kill_evidence="lethal_health_transition", cause="ballistic", weapon="other",
                    enemy="alpha_clot", zed_time=False)
        base.update(fields)
        return self.add("kill", second, role="server", **base)

    def action(self, second, name, **fields):
        base = dict(action=name, weapon="none", enemy="none", value=0, zed_time=False)
        base.update(fields)
        return self.add("action", second, **base)

    def events(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "promo-events.jsonl"
            path.write_text("\n".join(json.dumps(r) for r in self.rows) + "\n")
            return promo.read_events(shots.inputs([tmp]))


def started():
    return Log().add("session_start", 0, qpc_frequency=HZ)


class PromoShotTests(unittest.TestCase):
    def test_reader_keeps_actions_and_drops_unknown_values(self):
        log = started().action(1, "reload", weapon="9mm", value=7).action(2, "chat", weapon="9mm")
        log.action(3, "parry", weapon="private name", enemy="gorefast")
        actions = [e for e in log.events() if e["event"] == "action"]
        self.assertEqual(["reload", "parry"], [e["action"] for e in actions])
        self.assertNotIn("weapon", actions[1])
        self.assertIs(False, actions[0]["zed_time"])

    def test_9mm_reload_then_headshot_ranks_first_and_uses_video_time(self):
        log = started().add("sync", 10, marker_id=1, source="desktop_backbuffer")
        log.action(20, "reload", weapon="9mm", value=14).kill(22, 1, weapon="9mm",
                                                              headshot_evidence="stock_timestamp_advanced")
        log.action(60, "reload", weapon="9mm", value=14)
        events = log.events()
        ranked = shots.best(shots.Finder(events, shots.Clock(events, sync=5.0)).find(), 5)["01-02"]
        self.assertEqual(2, len(ranked))
        self.assertAlmostEqual(15.0, ranked[0]["moment"])
        self.assertAlmostEqual(10.0, ranked[0]["start"])
        self.assertAlmostEqual(19.0, ranked[0]["end"])
        self.assertIn("headshot", ranked[0]["summary"])

    def test_actions_become_their_shots(self):
        log = started()
        log.action(5, "zed_throw", enemy="alpha_clot", value=900).kill(6, 1, cause="grab_slam")
        log.action(20, "grenade_throw", value=800).kill(22, 2, weapon="grenade").kill(22.5, 3, weapon="grenade")
        log.action(40, "gun_release", weapon="ak12", value=700)
        log.add("hit", 41, role="server", player_id=1, world_epoch=1, victim_id=4, hit_id=99,
                weapon="thrown_weapon", enemy="slasher", cause="bludgeon")
        log.action(41.2, "gun_release", weapon="ak12", value=100)
        log.action(60, "parry", weapon="melee", enemy="gorefast").kill(62, 5, cause="slashing")
        log.kill(80, 6, enemy="scrake", zed_time=True).kill(81, 7, zed_time=True)
        log.action(90, "tomahawk_recall", weapon="tomahawk").action(90.1, "tomahawk_recall", weapon="tomahawk")
        events = log.events()
        ranked = shots.best(shots.Finder(events, shots.Clock(events)).find(), 5)
        self.assertIn("1 slam kill", ranked["17"][0]["summary"])
        self.assertIn("2 kill(s)", ranked["21"][0]["summary"])
        self.assertEqual(1, len(ranked["14"]))
        self.assertIn("parry (gorefast)", ranked["20"][0]["summary"])
        self.assertIn("2 Zed Time kill(s)", ranked["26"][0]["summary"])
        self.assertEqual(1, len(ranked["16"]))
        self.assertEqual([], ranked["01-02"])

    def test_overlapping_candidates_and_separate_launches(self):
        log = started()
        for i in range(4):
            log.kill(10 + i, 10 + i)
        events = log.events()
        ranked = shots.best(shots.Finder(events, shots.Clock(events)).find(), 5)["streak"]
        self.assertEqual(1, len(ranked))
        other = dict(events[0], session_id="11111111-89ab-cdef-0123-456789abcdef", event_id=500)
        with self.assertRaises(ValueError):
            shots.Clock(events + [other])
        with self.assertRaises(ValueError):
            shots.Clock(events, sync=3.0)

    def test_outputs_and_clip_commands(self):
        log = started().add("sync", 1, marker_id=1, source="desktop_backbuffer").action(30, "welder_taken", weapon="welder")
        events = log.events()
        ranked = shots.best(shots.Finder(events, shots.Clock(events, sync=2.0)).find(), 5)
        self.assertIn("| 1 | 0:29.5–0:39.0 | 0:31.0 |", shots.markdown(ranked, "video time"))
        self.assertIn("23,1,29.50,39.00,31.00,1,", shots.table(ranked))
        command = shots.clip_commands(ranked, "take.mkv", "out")[0]
        self.assertEqual(["-ss", "29.50", "-i", "take.mkv", "-t", "9.50"], command[5:11])
        self.assertTrue(command[-1].endswith("23_1_0m31s0.mkv"))


if __name__ == "__main__":
    unittest.main()
