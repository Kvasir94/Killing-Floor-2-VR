import json
import tempfile
import unittest
from pathlib import Path
import promo_events as promo

SESSION = "01234567-89ab-cdef-0123-456789abcdef"


def row(event="kill", seq=1, tick=1000, victim=1, **extra):
    result = dict(schema=promo.SCHEMA, session_id=SESSION, role="server", event=event,
                  event_id=seq, qpc_ticks=tick, t_us=tick,
                  player_id=3, world_epoch=1, victim_id=victim, hit_id=seq,
                  kill_evidence="lethal_health_transition", cause="ballistic")
    result.update(extra)
    return result


class PromoEventTests(unittest.TestCase):
    def test_export_drops_private_and_unrecognized_text(self):
        event = promo.sanitize(row(username="PrivateTester", ip="192.0.2.7", path="C:/Users/PrivateTester",
                                   chat="private conversation", enemy="private name", cause="private path"))
        text = json.dumps(event)
        for private in ("PrivateTester", "192.0.2.7", "C:/Users/PrivateTester", "private conversation", "private name", "private path"):
            self.assertNotIn(private, text)
        self.assertNotIn("enemy", event)
        self.assertNotIn("cause", event)

    def test_schema_identity_and_measurements_checked(self):
        for changed in ({"schema":"other"}, {"session_id":"private"}, {"role":"private"},
                        {"event":"chat"}, {"event_id":True}, {"qpc_ticks":float("nan")},
                        {"kill_evidence":"predicted"}, {"victim_id":-1}):
            self.assertIsNone(promo.sanitize(row(**changed)))
        self.assertEqual(-1, promo.sanitize(row(zeds_remaining=-1))["zeds_remaining"])

    def test_duplicate_files_and_duplicate_deaths_not_counted(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)/"events.jsonl"
            path.write_text("\n".join(json.dumps(event) for event in
                                      (row(), row(), row(seq=2), row(seq=3,victim=2), row(event="hit",seq=4,victim=3)))+"\ninvalid\n")
            events = promo.read_events([path,path])
            self.assertEqual(2, sum(event["event"]=="kill" for event in events))
            self.assertEqual(1, sum(event["event"]=="hit" for event in events))

    def test_bursts_use_kills_and_real_clock_with_separate_evidence(self):
        events = [row(event="session_start",seq=10,qpc_frequency=100),
                  row(seq=1,tick=1000,victim=1,headshot_evidence="stock_timestamp_advanced"),
                  row(seq=2,tick=1100,victim=2,cause="explosive_damage",headshot_evidence="same_game_tick_inferred"),
                  row(seq=3,tick=1200,victim=3,physical_melee_evidence="vr_fist_damage_type"),
                  row(event="hit",seq=4,tick=1250,victim=4),
                  row(seq=5,tick=1700,victim=5)]
        bursts = promo.kill_bursts(events)
        self.assertEqual(3, bursts[0]["kills"])
        self.assertEqual(1, bursts[0]["headshot_signals"])
        self.assertEqual(1, bursts[0]["explosive_cause_kills"])
        self.assertEqual(1, bursts[0]["physical_kills"])
        self.assertEqual(12.5, promo.video_time(row(tick=1250), row(event="sync",tick=1000),10,100))
        with self.assertRaises(ValueError):
            promo.video_time(row(session_id="other"),row(event="sync"),10,100)


if __name__ == "__main__":
    unittest.main()
