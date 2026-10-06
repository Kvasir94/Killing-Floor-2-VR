"""Allowlist promo event exports and rank kill clusters from recorded JSONL.

This consumes event files only. It never launches, controls or records a game.
Video alignment requires a visibly recorded sync marker and its video PTS.
"""
import json
import re
import math

SCHEMA = "kf2vr/promo-events/1"
EVENTS = {"session_start", "sync_anchor", "sync", "local_player", "hit", "kill", "overflow", "log_limit"}
CAUSES = {"other", "grab_slam", "fist", "charged_fist", "glove_fist", "charged_glove",
          "explosive_damage", "ballistic", "bludgeon", "slashing", "fire", "toxic", "emp"}
ENEMIES = {"other", "cyst", "alpha_clot", "slasher", "crawler", "stalker", "gorefast",
           "bloat", "siren", "husk", "scrake", "quarterpound", "fleshpound"}
HEADS = {"unknown", "same_game_tick_inferred", "stock_timestamp_advanced"}
PHYSICAL = {"unknown", "vr_scaled_hit_scope", "vr_grab_damage_type", "vr_fist_damage_type"}
NUMBERS = {"event_id", "qpc_ticks", "t_us", "utc_unix_us", "qpc_frequency", "anchor_read_span_us",
           "hit_id", "world_epoch", "player_id", "victim_id", "damage", "wave", "zeds_remaining",
           "session_kills", "marker_id", "width", "height", "frame_sample", "dropped", "limit_bytes"}


def sanitize(row):
    """Reject unknown schemas/identity; drop private/unrecognized fields."""
    if not isinstance(row, dict) or row.get("schema") != SCHEMA or not isinstance(row.get("event"), str) or row["event"] not in EVENTS:
        return None
    session = row.get("session_id")
    if not isinstance(session, str) or not re.fullmatch(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", session):
        return None
    if not isinstance(row.get("role"), str) or row["role"] not in {"driver", "server"}:
        return None
    result = {key: row[key] for key in ("schema", "session_id", "role", "event")}
    for key in NUMBERS:
        value = row.get(key)
        # JSON booleans are ints in Python. They are not measurements or IDs.
        if type(value) is int and (-1 if key in {"wave", "zeds_remaining"} else 0) <= value <= 2**64-1:
            result[key] = value
    if not all(result.get(key, 0) > 0 for key in ("event_id", "qpc_ticks")) or "t_us" not in result:
        return None
    for key, values in (("cause", CAUSES), ("enemy", ENEMIES), ("headshot_evidence", HEADS),
                        ("physical_melee_evidence", PHYSICAL)):
        if isinstance(row.get(key), str) and row[key] in values:
            result[key] = row[key]
    if row.get("source") == "desktop_backbuffer":
        result["source"] = "desktop_backbuffer"
    if row.get("kill_evidence") == "lethal_health_transition":
        result["kill_evidence"] = "lethal_health_transition"
    if result["event"] == "kill" and (result.get("kill_evidence") != "lethal_health_transition"
            or not all(key in result for key in ("player_id", "world_epoch", "victim_id", "hit_id"))):
        return None
    return result


def read_events(paths):
    """A repeat export does not duplicate IDs or deaths. Invalid rows stay out."""
    events, ids, deaths = [], set(), set()
    for path in paths:
        with open(path, encoding="utf-8") as stream:
            for line in stream:
                if len(line)>8192:
                    continue
                try:
                    row = sanitize(json.loads(line))
                except (ValueError, TypeError):
                    continue
                if row is None:
                    continue
                key = tuple(row[field] for field in ("session_id", "role", "event_id"))
                if key in ids:
                    continue
                ids.add(key)
                if row["event"] == "kill":
                    death = tuple(row[field] for field in ("session_id", "role", "world_epoch", "victim_id"))
                    if death in deaths:
                        continue
                    deaths.add(death)
                events.append(row)
    return events


def kill_bursts(events, seconds=5, player_id=None):
    """Return overlapping candidate windows; an editor chooses clips visually.

QPC comparison is only within the same launcher session on one PC. Independent
remote hosts have different session IDs and are never silently aligned here.
"""
    if not 0 < seconds <= 60:
        raise ValueError("Burst window must be greater than zero and at most 60 seconds")
    anchors = {}
    for row in events:
        if row["event"] == "session_start" and row.get("qpc_frequency", 0) > 0:
            anchors[(row["session_id"], row["role"])] = row
    groups = {}
    for row in events:
        if row["event"] != "kill" or (player_id is not None and row.get("player_id") != player_id):
            continue
        key = (row["session_id"], row["role"])
        if key in anchors:
            groups.setdefault(key, []).append(row)
    result = []
    for key, kills in groups.items():
        kills.sort(key=lambda row: row["qpc_ticks"])
        anchor = anchors[key]
        frequency = anchor["qpc_frequency"]
        end = 0
        for index, start in enumerate(kills):
            end = max(end, index)
            while end < len(kills) and kills[end]["qpc_ticks"]-start["qpc_ticks"] <= seconds*frequency:
                end += 1
            window = kills[index:end]
            result.append({"session_id": key[0], "role": key[1],
                           "start_qpc_ticks": start["qpc_ticks"],
                           "end_qpc_ticks": window[-1]["qpc_ticks"], "window_seconds": seconds,
                           "kills": len(window),
                           "headshot_signals": sum(row.get("headshot_evidence") == "stock_timestamp_advanced" for row in window),
                           "physical_kills": sum(row.get("physical_melee_evidence", "unknown") != "unknown" for row in window),
                           "explosive_cause_kills": sum(row.get("cause") == "explosive_damage" for row in window)})
    return sorted(result, key=lambda row: (row["kills"], row["physical_kills"], row["headshot_signals"]), reverse=True)


def video_time(event, marker, marker_video_seconds, qpc_frequency):
    if event["session_id"] != marker["session_id"] or marker["event"] != "sync" or qpc_frequency <= 0 or not math.isfinite(marker_video_seconds):
        raise ValueError("Event and video marker must belong to one local launcher session")
    return marker_video_seconds + (event["qpc_ticks"]-marker["qpc_ticks"])/qpc_frequency
