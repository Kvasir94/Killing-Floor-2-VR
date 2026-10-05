"""Evidence checks for real KF2 network roles; synthetic pose input is explicit."""
from __future__ import annotations

import re
import socket
import struct
import math


def events(log: str, kind: str) -> list[dict[str, str]]:
    result = []
    for line in log.splitlines():
        marker = f"KF2VRNet {kind} "
        if marker in line:
            result.append(dict(re.findall(r"(\w+)=([^\s]+)", line.split(marker, 1)[1])))
    return result


def is_true(value: str | None) -> bool:
    return str(value).lower() in ("true", "1")


def mode_is(value: str | None, name: str) -> bool:
    return str(value).lower() in ({"dedicated": ("1", "nm_dedicatedserver"), "client": ("3", "nm_client")}[name])


def number(event: dict, key: str) -> int:
    try:
        return int(event.get(key, "0"))
    except (TypeError, ValueError):
        return 0


def quantity(event: dict, key: str) -> float:
    """A logged UnrealScript float. A missing or malformed reading is not-a-number
    so every comparison against it fails, rather than passing as a silent zero."""
    try:
        return float(event[key])
    except (KeyError, TypeError, ValueError):
        return float("nan")


HELD_LEDGER_CASES = (
    "identities", "first_draw", "second_draw", "stale_state",
    "occupied_other_hand", "wrong_identity", "stale_item", "idempotent_draw",
    "release_one", "replace_one", "conservation", "revoked_primary",
    "reacquired_identity", "stale_acquisition", "shutdown",
)
SERVER_PENDING_CASES = (
    "length", "initial_zero", "first_only", "simultaneous", "stop_one",
    "clear_all_one", "mode_boundary", "stock_unchanged", "native_routes", "stock_removal",
)
HELD_NETWORK_CASES = (
    "local_prediction", "server_pair", "rejected_pair", "hand_swap", "release_one", "release_all",
)
DUAL_WEAPON_PHASES = ("draw", "rapid_replace", "ready", "fresh_trigger", "right_fire", "both_fire", "left_reload_right_fire", "right_reload", "menu_cancel", "complete")


def verify_ordered_server_probe(server: str, kind: str, cases: tuple[str, ...], scope: str) -> dict:
    """Require every real server probe to finish; never pool different pawns."""
    probes: dict[str, list[dict]] = {}
    for event in events(server, kind):
        if mode_is(event.get("netmode"), "dedicated"):
            probes.setdefault(event.get("pawn", ""), []).append(event)
    checks = {
        pawn: bool(pawn) and [row.get("case") for row in rows] == list(cases)
        and all(is_true(row.get("passed")) for row in rows)
        for pawn, rows in probes.items()
    }
    return {"checks": checks, "passed": bool(checks) and all(checks.values()),
            "scope": scope}


def verify_held_ledger(server: str) -> dict:
    return verify_ordered_server_probe(server, "held_ledger", HELD_LEDGER_CASES,
                                      "server exact-item ledger only; no dual firing or client reconciliation")


def verify_server_pending(server: str) -> dict:
    return verify_ordered_server_probe(server, "server_pending", SERVER_PENDING_CASES,
                                      "real stock pending-fire calls and removal callback; no combat or hit validation")


def verify_held_network(server: str, driver: str) -> dict:
    rows = [e for e in events(driver, "held_network") if mode_is(e.get("netmode"), "client")]
    checks = {"client_scenario": [e.get("case") for e in rows] == list(HELD_NETWORK_CASES)
              and all(is_true(e.get("passed")) for e in rows)}
    identity = tuple(rows[0].get(k) for k in ("world", "connection", "pawn")) if rows else None
    checks["one_pawn"] = bool(identity and all(identity) and all(
        tuple(e.get(k) for k in ("world", "connection", "pawn")) == identity for e in rows))
    commands = [e for e in events(server, "held_command") if mode_is(e.get("netmode"), "dedicated")
                and tuple(e.get(k) for k in ("world", "connection", "pawn")) == identity]
    checks["server_receipts"] = ([number(e, "request") for e in commands] == list(range(1, 7))
                                 and [is_true(e.get("accepted")) for e in commands]
                                 == [True, True, False, True, True, True])
    checks["acknowledged"] = [number(e, "request") for e in rows[1:]] == list(range(2, 7))
    return {"checks": checks, "passed": all(checks.values()),
            "scope": "real owner RPC, immediate desired-state prediction and replicated reconciliation; no weapon activation"}


def verify_dual_weapons(server: str, driver: str, pawn: str | None = None) -> dict:
    rows = [e for e in events(driver, "dual_weapon") if mode_is(e.get("netmode"), "client")
            and (pawn is None or e.get("pawn") == pawn)]
    identity = tuple(rows[0].get(k) for k in ("world", "connection", "pawn")) if rows else None
    if identity and not all(identity):
        identity = None
    receipts = [e for e in events(server, "dual_weapon_server") if mode_is(e.get("netmode"), "dedicated")
                and (pawn is None or e.get("pawn") == pawn)
                and (identity is None or tuple(e.get(k) for k in ("world", "connection", "pawn")) == identity)]
    checks = {
        "local_gameplay": [e.get("phase") for e in rows] == list(DUAL_WEAPON_PHASES)
            and all(is_true(e.get("passed")) for e in rows),
        "server_phases": [e.get("phase") for e in receipts] == list(DUAL_WEAPON_PHASES[1:]),
        "same_pawn": bool(identity and all(identity) and all(
            tuple(e.get(k) for k in ("world", "connection", "pawn")) == identity for e in rows + receipts)),
        "ammo_agreement": bool(receipts) and all(all(k in e for k in ("left_ammo", "right_ammo", "client_left", "client_right"))
            and number(e, "left_ammo") == number(e, "client_left")
            and number(e, "right_ammo") == number(e, "client_right") for e in receipts),
        "native_healthy": bool(receipts) and all(e.get("native_fault") == "0" for e in receipts),
    }
    return {"checks": checks, "passed": all(checks.values()),
            "scope": "two local presenters, real hand input and stock firing/reload with server ammo; no damage/observer/headset acceptance"}


def verify_remote_weapons(driver: str, observer: str | None, pawn: str | None = None) -> dict:
    ready = next((e for e in events(driver, "dual_weapon") if e.get("phase") == "ready"
                  and (pawn is None or e.get("pawn") == pawn)), {})
    rows = [e for e in events(observer or "", "remote_weapon") if ready
            and all(e.get(k) == ready.get(k) for k in ("world", "connection", "pawn"))
            and mode_is(e.get("netmode"), "client")]
    checks = {}
    for hand, weapon in (("0", "KF2VRNet9mm"), ("1", "KFWeap_Shotgun_MB500")):
        samples = [e for e in rows if e.get("hand") == hand and e.get("weapon") == weapon]
        def aligned(e):
            try:
                return (is_true(e.get("ready")) and 0 <= float(e["muzzle_error"]) <= 0.1
                        and 0 <= float(e["bore_error"]) <= 0.1)
            except (KeyError, ValueError):
                return False
        checks[f"hand_{hand}_placement"] = bool(samples) and all(aligned(e) for e in samples)
        # An observer that loads after the first shot must not replay that old
        # flash. Require live animation plus the final replicated shot state.
        checks[f"hand_{hand}_actions"] = any(number(e, "shots") >= 1 and number(e, "shot_sequence") >= 2
                                               and number(e, "reloads") >= 1 for e in samples)
    return {"passed": all(checks.values()), "checks": checks,
            "scope": "remote stock meshes, optical socket alignment and independent gun animations; not arm/hand animation or headset acceptance"}


def verify_dual_damage(server: str, driver: str, observer: str | None, pawn: str | None = None) -> dict:
    ready = [e for e in events(driver, "dual_weapon") if e.get("phase") == "ready"
             and is_true(e.get("passed")) and mode_is(e.get("netmode"), "client")
             and (pawn is None or e.get("pawn") == pawn)]
    checks = {"client_ready": len(ready) == 1}
    if not ready:
        return {"passed": False, "checks": checks}
    prefix = "w{world}-c{connection}-p{pawn}".format(**ready[0])
    for hand, weapon in (("left", "KF2VRNet9mm_"), ("right", "KFWeap_Shotgun_MB500_")):
        target = f"{prefix}-{hand}"
        hits = [e for e in events(server, "target_damage") if e.get("target") == target
                and mode_is(e.get("netmode"), "dedicated") and weapon in e.get("weapon", "")
                and number(e, "before") > number(e, "after") and number(e, "damage") > 0]
        checks[f"{hand}_aimed_damage"] = bool(hits)
        if observer is not None:
            checks[f"{hand}_observer_health"] = bool(hits) and any(
                e.get("target") == target and mode_is(e.get("netmode"), "client")
                and number(e, "receipt") >= number(hits[-1], "receipt")
                and number(e, "health") == number(hits[-1], "after")
                for e in events(observer, "target_state"))
    return {"passed": all(checks.values()), "checks": checks,
            "scope": "two fixed distinct hand rays, stock impacts/damage on separate targets and observer health; not remote weapon animation"}


def verify_dual_vr_owners(server: str, driver: str, observer: str) -> dict:
    """Both active owners must pass combat, damage and the opposite view."""
    checks = {
        "driver_combat": verify_dual_weapons(server, driver),
        "observer_combat": verify_dual_weapons(server, observer),
        "driver_damage": verify_dual_damage(server, driver, observer),
        "observer_damage": verify_dual_damage(server, observer, driver),
        "driver_remote": verify_remote_weapons(driver, observer),
        "observer_remote": verify_remote_weapons(observer, driver),
    }
    return {**checks, "passed": all(result["passed"] for result in checks.values())}


def verify_transport(server: str, driver: str, observer: str | None = None) -> dict:
    checks = {}
    sessions = [e for e in events(server, "session") if mode_is(e.get("netmode"), "dedicated")]
    world = sessions[-1].get("world") if sessions else None
    checks["dedicated_world"] = bool(sessions and number(sessions[-1], "world") > 0)
    hellos = {e.get("connection") for e in events(server, "hello")
              if e.get("world") == world and is_true(e.get("accepted")) and mode_is(e.get("netmode"), "dedicated")}
    drivers = [e for e in events(driver, "status") if e.get("world") == world
               and mode_is(e.get("netmode"), "client") and is_true(e.get("hello"))]
    driver_ids = {e.get("connection") for e in drivers} & hellos
    checks["real_driver_handshake"] = bool(driver_ids)
    accepted = [e for e in events(server, "authority") if e.get("world") == world
                and e.get("connection") in driver_ids and mode_is(e.get("netmode"), "dedicated")
                and number(e, "pawn") > 0 and number(e, "accepted") >= 10]
    checks["server_received_client_poses"] = bool(accepted)
    checks["driver_received_public_state"] = any(number(e, "received") > 0 and number(e, "pawn") > 0 for e in drivers)
    if observer is not None:
        observers = [e for e in events(observer, "status") if e.get("world") == world
                     and mode_is(e.get("netmode"), "client") and is_true(e.get("hello"))
                     and e.get("connection") in hellos and e.get("connection") not in driver_ids]
        checks["separate_observer_connection"] = bool(observers)
        checks["observer_received_remote_pose"] = any(number(e, "remote_poses") > 0 and number(e, "received") > 0 for e in observers)
    return {"checks": checks, "passed": all(checks.values()), "world": world,
            "client_connections": sorted(hellos), "two_client_evidence": observer is not None and all(checks.values()),
            "scope": "real actor replication; separate native, combat and movement checks establish their own acceptance"}


def world_logs(server: str, driver: str, observer: str | None, world: str) -> tuple:
    """UE actor names repeat after travel; never combine their damage receipts."""
    def section(log, kind):
        if log is None:
            return None
        lines = log.splitlines()
        start = None
        for i, line in enumerate(lines):
            markers = events(line, kind)
            if not markers or "world" not in markers[0]:
                continue
            if markers[0]["world"] == world and start is None:
                start = i
            elif start is not None and markers[0]["world"] != world:
                return "\n".join(lines[start:i])
        return "\n".join(lines[start:]) if start is not None else ""
    return section(server, "session"), section(driver, "status"), section(observer, "status")


def verify_lifecycle(server: str, driver: str, observer: str, *, dual_weapons: bool = False) -> dict:
    sessions = [e for e in events(server, "session") if mode_is(e.get("netmode"), "dedicated")]
    worlds = list(dict.fromkeys(e.get("world") for e in sessions))
    first = worlds[0] if worlds else ""
    second = worlds[1] if len(worlds) > 1 else ""
    s1, d1, o1 = world_logs(server, driver, observer, first)
    s2, d2, o2 = world_logs(server, driver, observer, second)
    phases = events(s1, "lifecycle")
    def phase(name, log=s1):
        return next((e for e in events(log, "lifecycle") if e.get("phase") == name), {})
    dead, spawn, begin = phase("dead"), phase("respawn"), phase("death_begin")
    client_dead = phase("dead", d1)
    trader = [phase(name, log) for log in (s1, d1) for name in ("trader_before", "trader_after", "trader_closed")]
    def numeric(e, k):
        try:
            return float(e[k])
        except (KeyError, ValueError):
            return float("nan")
    purchase = all(numeric(after, "armor") > numeric(before, "armor")
                   and numeric(after, "dosh") < numeric(before, "dosh")
                   and closed.get("menu", "").lower() == "false"
                   for before, after, closed in (trader[:3], trader[3:]))
    same_purchase = all(numeric(trader[i], k) == numeric(trader[i + 3], k)
                        for i in (0, 1) for k in ("armor", "dosh"))
    respawn_combat = {"fire_reload": verify_fire_reload(s1, d1), "damage": verify_damage(s1, d1, o1),
                      "movement": verify_movement(s1, d1)}
    travel_combat = {"fire_reload": verify_fire_reload(s2, d2), "damage": verify_damage(s2, d2, o2),
                     "movement": verify_movement(s2, d2)}
    completes = events(d1, "fire_fixture")
    if dual_weapons:
        respawn_combat = {}
        for name, pawn in (("initial", begin.get("pawn")), ("respawn", spawn.get("pawn"))):
            respawn_combat[f"{name}_weapons"] = verify_dual_weapons(s1, d1, pawn)
            respawn_combat[f"{name}_damage"] = verify_dual_damage(s1, d1, o1, pawn)
            respawn_combat[f"{name}_remote"] = verify_remote_weapons(d1, o1, pawn)
        travel_combat = {"weapons": verify_dual_weapons(s2, d2), "damage": verify_dual_damage(s2, d2, o2),
                         "remote": verify_remote_weapons(d2, o2)}
        completes = events(d1, "dual_weapon")
    checks = {
        "two_distinct_worlds": len(worlds) == 2 and all(int(w or 0) > 0 for w in worlds),
        "stock_death_with_living_teammate": number(begin, "living") >= 2 and number(dead, "living") >= 1
            and number(dead, "pawn") == 0 and numeric(dead, "health") <= 0 and is_true(dead.get("played")),
        "client_observed_stock_death": numeric(client_dead, "health") <= 0 and is_true(client_dead.get("played")),
        "same_connection_new_pawn_at_trader": bool(spawn) and spawn.get("connection") == begin.get("connection")
            and number(spawn, "pawn") > number(begin, "pawn") > 0 and is_true(spawn.get("trader")),
        "old_pose_removed_on_other_client": any(e.get("connection") == begin.get("connection")
            and e.get("pawn") == begin.get("pawn") for e in events(o1, "pose_destroyed")),
        "respawn_pose_visible_to_other_client": any(e.get("connection") == spawn.get("connection")
            and e.get("pawn") == spawn.get("pawn") and is_true(e.get("fresh")) for e in events(o1, "freshness")),
        "combat_completed_on_both_pawns": all(any(e.get("phase") == "complete" and e.get("pawn") == p
            for e in completes) for p in (begin.get("pawn"), spawn.get("pawn"))) and bool(spawn),
        "respawn_dual_combat" if dual_weapons else "respawn_combat_and_movement": all(e["passed"] for e in respawn_combat.values()),
        "stock_trader_purchase_replicated": purchase and same_purchase and is_true(trader[3].get("menu"))
            and is_true(trader[1].get("menu")),
        "ordered_server_lifecycle": [e.get("phase") for e in phases] == ["death_begin", "dead", "respawn",
            "trader_before", "trader_after", "trader_closed", "travel_begin"],
        "arrived_at_outpost": phase("travel_complete", s2).get("map", "").lower() == "kf-outpost",
        "native_combat_after_map_travel": all(e["passed"] for e in travel_combat.values()),
    }
    if dual_weapons:
        drops = []
        for s, d, pawn in ((s1, d1, begin.get("pawn")), (s1, d1, spawn.get("pawn")),
                           (s2, d2, phase("travel_complete", s2).get("pawn"))):
            local = [e for e in events(d, "dual_drop") if e.get("pawn") == pawn
                     and mode_is(e.get("netmode"), "client")]
            authority = [e for e in events(s, "dual_drop_server") if e.get("pawn") == pawn
                         and mode_is(e.get("netmode"), "dedicated")]
            drops.append(len(local) == len(authority) == 1
                and all(is_true(e.get("passed")) for e in local + authority)
                and all(local[0].get(k) == authority[0].get(k) for k in ("world", "connection", "pawn", "left_ammo")))
        checks["stock_drop_preserves_other_hand_fire"] = all(drops)
        trades = [e for e in events(d1, "dual_trade") if e.get("pawn") == spawn.get("pawn")
                  and e.get("connection") == spawn.get("connection") and mode_is(e.get("netmode"), "client")]
        checks["stock_weapon_purchase_and_sale"] = [e.get("phase") for e in trades] == [
            "purchase", "draw", "sale", "survivor_fire"] and all(is_true(e.get("passed")) for e in trades)
    return {"passed": all(checks.values()), "checks": checks, "worlds": worlds,
            "respawn_combat": respawn_combat, "travel_combat": travel_combat,
            "scope": "two active local connections; diagnostic suicide and wave completion; stock respawn, armor purchase and server travel"}


def verify_paired_smoke(server: str, driver: str) -> dict:
    """Two representative families; missing or failed phases never become a pass."""
    phases = ("ready", "left_fire", "right_fire", "reload", "restore")
    checks = {}
    for role, log, mode in (("server", server, "dedicated"), ("owner", driver, "client")):
        records = events(log, "paired_case")
        checks[role + "_no_failed_phases"] = bool(records) and all(is_true(e.get("passed")) for e in records)
        for index, family in ((0, "1858"), (1, "9mm")):
            case = [e for e in records if e.get("index") == str(index) and mode_is(e.get("netmode"), mode)]
            checks[role + "_" + family] = [e.get("phase") for e in case] == list(phases)
    contract = events(driver, "playable_contract")
    for phase in ("settings", "comfort_signals", "chest_anchor"):
        records = [e for e in contract if e.get("phase") == phase]
        checks[phase] = len(records) == 1 and is_true(records[0].get("passed")) and mode_is(records[0].get("netmode"), "client")
    checks["no_pair_transaction_failure"] = "KF2VR_PAIR phase=failure" not in server + driver
    return {"passed": all(checks.values()), "checks": checks,
            "scope": "1858/9mm owning-client input, authority ammo, restoration and shared presentation signals; headset visuals pending"}


def verify_pose_dropout(server: str, driver: str, observer: str) -> dict:
    """Pose telemetry loss must not stop native local combat or movement."""
    pauses = [e for e in events(driver, "dropout") if e.get("phase") == "paused"]
    resumes = [e for e in events(driver, "dropout") if e.get("phase") == "resumed"]
    pause = pauses[-1] if pauses else {}
    resume = resumes[-1] if resumes else {}
    identity = ("world", "connection", "pawn")
    def matches(e):
        return bool(pause) and all(e.get(k) == pause.get(k) for k in identity)
    freshness = [e for e in events(observer, "freshness") if matches(e)
                 and mode_is(e.get("netmode"), "client") and e.get("observer") != pause.get("connection")
                 and number(e, "observer") > 0]
    # A stale sample immediately preceding the next unsent sequence belongs to
    # this pause, rather than an unrelated startup/loading hiccup.
    stale = [i for i, e in enumerate(freshness) if not is_true(e.get("fresh"))
             and 1 <= ((number(pause, "sequence") - number(e, "sequence")) & 65535) <= 3]
    recovered = any(is_true(e.get("fresh")) and ((number(e, "sequence") - number(resume, "sequence")) & 65535) < 32768
                    for i in stale for e in freshness[i + 1:])
    start = driver.find("KF2VRNet dropout phase=paused ")
    end = driver.find("KF2VRNet dropout phase=resumed ", start + 1) if start >= 0 else -1
    during = driver[start:end] if end > start >= 0 else ""
    try:
        duration = float(resume.get("time", "nan")) - float(pause.get("time", "nan"))
    except ValueError:
        duration = float("nan")
    checks = {
        "one_pause_and_resume_same_lifetime": len(pauses) == len(resumes) == 1 and matches(resume)
            and all(number(pause, k) > 0 for k in identity) and mode_is(pause.get("netmode"), "client")
            and mode_is(resume.get("netmode"), "client")
            and all(re.fullmatch(r"\d+", e.get("sequence", "")) for e in (pause, resume)),
        "eighteen_second_upload_gap": 18 <= duration < 25 and pause.get("sequence") == resume.get("sequence"),
        "server_expired_that_pose": any(matches(e) for e in events(server, "expiry")),
        "separate_observer_expired_and_recovered": bool(stale) and recovered,
        "native_tracking_continued": len([e for e in events(during, "native_frame")
            if e.get("valid") == "3" and e.get("connection") == "2" and is_true(e.get("calibrated"))]) >= 2,
        "full_local_combat_during_upload_gap": verify_fire_reload(server, driver)["passed"]
            and [e.get("phase") for e in events(during, "fire_fixture") if e.get("phase") != "stopped"]
                == ["equip"] + ["shot"] * 5 + ["reload", "complete"],
        "local_movement_during_upload_gap": verify_movement(server, driver)["passed"]
            and any(e.get("phase") == "client" and matches(e) for e in events(during, "movement")),
    }
    return {"checks": checks, "passed": all(checks.values()), "upload_gap_seconds": duration if math.isfinite(duration) else None,
            "scope": "cosmetic pose upload interrupted; reliable gameplay traffic remains available"}


def verify_reconnect(server: str, driver: str, original: str, rejoined: str) -> dict:
    transport = verify_transport(server, driver, rejoined)
    world = transport["world"]
    def ids(log):
        return {e.get("connection") for e in events(log, "status") if e.get("world") == world
                and mode_is(e.get("netmode"), "client") and is_true(e.get("hello"))}
    old, new, driver_ids = ids(original), ids(rejoined), ids(driver)
    destroyed = {e.get("connection") for e in events(server, "channel_destroyed")
                 if e.get("world") == world and mode_is(e.get("netmode"), "dedicated")}
    fresh = [e for e in events(rejoined, "freshness") if e.get("world") == world
             and e.get("connection") in driver_ids and e.get("observer") in new
             and number(e, "pawn") > 0 and is_true(e.get("fresh")) and mode_is(e.get("netmode"), "client")]
    checks = {"real_rejoined_transport": transport["passed"],
              "new_connection_identity": len(old) == len(new) == 1 and old.isdisjoint(new)
                  and (old | new).isdisjoint(driver_ids),
              "old_channel_removed_on_server": bool(old) and old <= destroyed,
              "rejoined_observer_received_live_driver": bool(fresh)}
    return {"checks": checks, "passed": all(checks.values()),
            "old_connections": sorted(old), "new_connections": sorted(new)}


def verify_disconnect_cleanup(server: str, driver: str, observer: str) -> dict:
    statuses = [e for e in events(driver, "status") if is_true(e.get("hello")) and number(e, "pawn") > 0]
    identity = statuses[-1] if statuses else {}
    def matches(e):
        return bool(identity) and all(e.get(k) == identity.get(k) for k in ("world", "connection", "pawn"))
    checks = {
        "driver_channel_removed_on_server": any(matches(e) and mode_is(e.get("netmode"), "dedicated")
            for e in events(server, "channel_destroyed")),
        "driver_pose_removed_on_observer": any(matches(e) and mode_is(e.get("netmode"), "client")
            and number(e, "observer") > 0 and e.get("observer") != identity.get("connection")
            for e in events(observer, "pose_destroyed")),
        "observer_has_no_remaining_pose": bool(events(observer, "status"))
            and events(observer, "status")[-1].get("world") == identity.get("world")
            and events(observer, "status")[-1].get("public_poses") == "0",
    }
    return {"checks": checks, "passed": all(checks.values())}


def verify_fire_reload(server: str, driver: str) -> dict:
    """Require real client input, pose callbacks and a complete stock ammo cycle.

    Firing into the map is not damage evidence. This check deliberately makes no
    claim about enemy health, kill replication or a second player's presentation.
    """
    transport = verify_transport(server, driver)
    fixture = events(driver, "fire_fixture")
    equips = [e for e in fixture if e.get("phase") == "equip" and mode_is(e.get("netmode"), "client")]
    equip = equips[-1] if equips else {}
    identity = ("world", "connection", "pawn", "weapon")
    cycle = [e for e in fixture if equip and all(e.get(k) == equip.get(k) for k in identity)
             and mode_is(e.get("netmode"), "client")]
    active = [e for e in cycle if e.get("phase") != "stopped"]
    shots = [e for e in active if e.get("phase") == "shot"]
    reloads = [e for e in active if e.get("phase") == "reload"]
    completes = [e for e in active if e.get("phase") == "complete"]
    reload = reloads[-1] if reloads else {}
    complete = completes[-1] if completes else {}
    required = {"equip": ("ammo", "spare"), "shot": ("pulse", "ammo_before", "ammo_after", "start_calls", "aim_calls"),
                "reload": ("ammo_before", "spare_before"), "complete": ("pulses", "ammo", "spare")}
    fields_valid = bool(active) and all(
        all(re.fullmatch(r"\d+", e.get(k, "")) for k in required.get(e.get("phase"), ())) for e in active)
    authority = [e for e in events(server, "authority") if mode_is(e.get("netmode"), "dedicated")
                 and all(e.get(k) == equip.get(k) for k in identity[:3]) and number(e, "accepted") >= 10]
    checks = {
        "real_client_pose_transport": transport["passed"],
        "same_pawn_on_server": bool(authority) and equip.get("world") == transport["world"]
            and all(number(equip, k) > 0 for k in identity[:3]),
        "exact_scenario_order": [e.get("phase") for e in active] == ["equip"] + ["shot"] * 5 + ["reload", "complete"],
        "complete_ammo_fields": fields_valid,
        "five_distinct_pulses": [number(e, "pulse") for e in shots] == list(range(1, 6)),
        "stock_ammo_consumed": bool(shots) and fields_valid and all(
            0 <= number(e, "ammo_after") < number(e, "ammo_before") for e in shots),
        "continuous_ammo_history": bool(shots) and fields_valid
            and number(shots[0], "ammo_before") == number(equip, "ammo")
            and all(number(a, "ammo_after") == number(b, "ammo_before") for a, b in zip(shots, shots[1:]))
            and number(reload, "ammo_before") == number(shots[-1], "ammo_after"),
        "each_shot_uses_local_pose": bool(shots) and all(
            number(e, k) > (number(shots[i - 1], k) if i else 0)
            for i, e in enumerate(shots) for k in ("start_calls", "aim_calls")),
        "stock_reload_completed": bool(complete and reload) and fields_valid and number(complete, "pulses") == 5
            and number(complete, "ammo") > number(reload, "ammo_before"),
        "reload_conserves_ammunition": bool(complete and reload) and fields_valid
            and number(equip, "spare") == number(reload, "spare_before")
            and number(complete, "ammo") + number(complete, "spare")
                == number(reload, "ammo_before") + number(reload, "spare_before"),
        "no_early_stop": all(e.get("reason") == "complete" for e in cycle if e.get("phase") == "stopped"),
    }
    return {"checks": checks, "passed": all(checks.values()),
            "identity": {k: equip.get(k) for k in identity}, "damage_tested": False,
            "scope": "local weapon-pose callbacks, stock firing and reload; shared damage and remote animation require separate checks"}


def verify_movement(server: str, driver: str) -> dict:
    transport = verify_transport(server, driver)
    clients = [e for e in events(driver, "movement") if e.get("phase") == "client"
               and mode_is(e.get("netmode"), "client") and e.get("world") == transport["world"]]
    client = clients[-1] if clients else {}
    servers = [e for e in events(server, "movement") if e.get("phase") == "server"
               and mode_is(e.get("netmode"), "dedicated")
               and all(e.get(k) == client.get(k) for k in ("world", "connection", "pawn"))]
    authority = servers[-1] if servers else {}
    def value(event, key):
        try:
            return float(event[key])
        except (KeyError, ValueError):
            return float("nan")
    error = math.sqrt(sum((value(client, k) - value(authority, k)) ** 2 for k in ("x", "y", "z")))
    checks = {"real_transport": transport["passed"], "native_axis_dispatch": number(client, "dispatches") >= 10,
              "client_moved": 25 <= value(client, "distance") <= 1000,
              "server_moved_same_pawn": bool(servers) and 25 <= value(authority, "distance") <= 1000,
              "settled_positions_match": math.isfinite(error) and error <= 20}
    return {"passed": all(checks.values()), "checks": checks,
            "position_error": error if math.isfinite(error) else None,
            "scope": "native viewport stick input, local movement and matching dedicated-server position"}


def verify_vr_controls(server: str, driver: str) -> dict:
    """The modern control stack actually switching weapons on a network client.

    The recorded fixture otherwise runs the legacy single-weapon path, so
    without this the network weapon contract -- SetCurrentWeapon, the real
    putdown and bringup, and the registry re-binding afterwards -- is only ever
    compile-checked. A switch is counted only when the stock manager, the
    server's current weapon and the VR registry all name the same actor.
    """
    transport = verify_transport(server, driver)
    events_seen = events(driver, "vr_controls")
    walking = [e for e in events_seen if mode_is(e.get("netmode"), "client")]
    last = walking[-1] if walking else {}
    completes = [e for e in walking if e.get("phase") == "switch_complete"]
    checks = {
        "real_transport": transport["passed"],
        "modern_stack_active": any(is_true(e.get("independent")) for e in walking),
        # Both directions, so a pass cannot come from the spawn state alone.
        "switched_both_ways": number(last, "switches") >= 2,
        "no_failed_switches": number(last, "failures") == 0,
        # The registry and the replicated weapon must name the same actor.
        "registry_agrees": bool(completes) and all(is_true(e.get("agrees")) for e in completes),
    }
    return {"passed": all(checks.values()), "checks": checks,
            "switches": number(last, "switches"), "failures": number(last, "failures"),
            "scope": "network weapon contract driven through the selector's own draw path"}


def verify_room_movement(server: str, driver: str) -> dict:
    """Room-scale displacement survives the move round trip without correction.

    Pawn.MoveSmooth is not an input axis, so the server's MoveAutonomous replay
    cannot reproduce it. The saved-move transport carries it explicitly; the
    proof is that the client keeps its displacement while corrections stay at
    the idle baseline and the two positions still agree.
    """
    transport = verify_transport(server, driver)
    clients = [e for e in events(driver, "room_client") if e.get("phase") == "walking"
               and mode_is(e.get("netmode"), "client")]
    client = clients[-1] if clients else {}
    servers = [e for e in events(server, "room_server") if e.get("phase") == "accepted"
               and mode_is(e.get("netmode"), "dedicated")]
    authority = servers[-1] if servers else {}

    def value(event, key):
        try:
            return float(event[key])
        except (KeyError, ValueError):
            return float("nan")

    error = math.sqrt(sum((value(client, k) - value(authority, k)) ** 2 for k in ("x", "y")))
    sent = number(client, "sent")
    accepted = number(authority, "accepted")
    rejected = number(authority, "rejected")
    corrections = number(client, "corrections")
    checks = {
        "real_transport": transport["passed"],
        # A physical walk with no stick input must keep producing swept
        # displacement, which net drift cannot show because the legs alternate.
        "client_walked": value(client, "travelled") >= 50,
        # The rubber-banding failure looks exactly like success on travelled
        # alone: the client keeps sweeping while the server drags it back, so
        # travel grows and net displacement never does. Peak drift is what
        # separates "walked" from "kept what it walked".
        "client_kept_displacement": value(client, "peak") >= 50,
        "moves_carried_displacement": sent >= 20,
        # The server must have applied them rather than silently dropping them.
        "server_accepted": accepted >= sent // 2,
        # A refusal is not automatically a fault. Refusing to teleport a pawn
        # that is momentarily not walking is the clamp doing its job, and a
        # blocked sweep produces exactly that. What must not happen is refusals
        # at a rate that means the transport is not working.
        "server_refusals_rare": rejected * 200 <= max(accepted, 1),
        # This is the agreement test, and it is the server's own: ServerMove
        # compares the client's reported location every single move and corrects
        # beyond MAXPOSITIONERRORSQUARED, about 1.73 UU. Comparing two logged
        # positions instead cannot work here -- the logs have independent
        # clocks and the walk oscillates about 150 UU per leg, so samples taken
        # at unrelated moments differ by more than any useful bound.
        "client_position_accepted": corrections * 20 <= max(sent, 1),
        # Gross divergence only: the pawns must at least be in the same place,
        # which a phase-skewed sample can still show.
        "not_grossly_diverged": math.isfinite(error) and error <= 200,
    }
    return {"passed": all(checks.values()), "checks": checks,
            "position_error": error if math.isfinite(error) else None,
            "client_sent": sent, "server_accepted": accepted,
            "server_rejected": rejected,
            "peak_drift": value(client, "peak"),
            "corrections_during_walk": corrections,
            "scope": "injected room-scale displacement, saved-move transport and dedicated-server agreement"}


def verify_room_clamp(server: str, driver: str) -> dict:
    """The server's own distance and speed limits refuse an unclamped client.

    Every refusal seen before this was a physics refusal, and could only have
    been: the client clamps its own request before packing it, so no packet had
    ever reached the limits the server keeps for a client that does not clamp.
    The fixture drops that local clamp and delivers displacement past each limit
    in turn, on top of the ordinary walk -- the dense move stream is what keeps
    the server's speed budget one frame wide instead of an idle client's
    accumulated gap, and it is what makes the speed case reachable at all.
    """
    transport = verify_transport(server, driver)
    probes = [e for e in events(driver, "room_probe") if mode_is(e.get("netmode"), "client")]
    room = [e for e in events(server, "room_server") if mode_is(e.get("netmode"), "dedicated")]
    # The server judges what the move delivered, not what the fixture asked
    # for: a sweep blocked by geometry carries less than it requested and is
    # correctly accepted. Only bursts that actually arrived oversize count.
    oversize = [e for e in probes if e.get("phase") == "over_distance"
                and quantity(e, "applied") > 15.01]
    # Kept under the distance limit on purpose, so a refusal for this one can
    # only be the speed clamp -- and only when it also beats the frame's budget.
    overspeed = [e for e in probes if e.get("phase") == "over_speed"
                 and 0 < quantity(e, "applied") <= 15.01
                 and quantity(e, "applied") > 300.0 * quantity(e, "frame") + 0.01]
    reasons = [e.get("phase") for e in room]
    # Counters ride on every room_server line, refusals included, so the running
    # totals do not depend on where the throttled accept log happened to land.
    accepted = max((number(e, "accepted") for e in room), default=0)
    rejected = max((number(e, "rejected") for e in room), default=0)
    walking = [e for e in events(driver, "room_client") if e.get("phase") == "walking"
               and mode_is(e.get("netmode"), "client")]
    corrections = number(walking[-1], "corrections") if walking else 0
    checks = {
        "real_transport": transport["passed"],
        "delivered_over_distance": bool(oversize),
        "refused_over_distance": "rejected_over_distance" in reasons,
        "delivered_over_speed": bool(overspeed),
        "refused_over_speed": "rejected_over_speed" in reasons,
        # A run whose transport is simply broken refuses everything, and would
        # otherwise satisfy both clamp checks for entirely the wrong reason.
        "ordinary_moves_accepted": accepted >= 20,
        "transport_survived_refusals": accepted > rejected,
        # A limit nobody enforces is advisory. A refused burst leaves the client
        # ahead of the server, which is what ServerMove's own per-move position
        # test corrects, so the correction is the enforcement.
        "refusals_enforced": corrections > 0,
    }
    return {"passed": all(checks.values()), "checks": checks,
            "delivered_over_distance": len(oversize), "delivered_over_speed": len(overspeed),
            "server_accepted": accepted, "server_rejected": rejected,
            "refusal_reasons": sorted({r for r in reasons if str(r).startswith("rejected_")}),
            "corrections_during_walk": corrections,
            "scope": "unclamped client displacement against the dedicated server's distance and speed limits"}


def verify_room_residual(server: str, driver: str, *, respawn_required: bool = True) -> dict:
    """A recenter or a respawn leaves nothing queued to apply afterwards.

    PendingRoomRequest is the one piece of pending movement that ClientRestart's
    own CleanOutSavedMoves does not cover, and nothing drains it while the pawn
    is gone, because ProcessMove only runs in state PlayerWalking. The fixture
    deliberately strands a request the client would otherwise have carried, puts
    each path through, and requires both that nothing survived it and that the
    body did not take the step. The reset log is the causal half: it records what
    was still queued at the moment the rule discarded it, so a pass cannot come
    from a request that something else had already drained.
    """
    transport = verify_transport(server, driver)
    residual = [e for e in events(driver, "room_residual") if mode_is(e.get("netmode"), "client")]
    resets = [e for e in events(driver, "room_reset") if mode_is(e.get("netmode"), "client")]

    def phase(name):
        found = [e for e in residual if e.get("phase") == name]
        return found[-1] if found else {}

    def discarded(reason):
        return any(quantity(e, "pending") > 0.01 for e in resets if e.get("phase") == reason)

    def settled(name):
        return quantity(phase(name), "moved") < 2.0

    def cleared(name):
        event = phase(name)
        return quantity(event, "pending") < 0.01 and quantity(event, "active") < 0.01

    recenter = phase("recenter")
    checks = {
        "real_transport": transport["passed"],
        # With nothing queued the rest of the recenter check proves nothing.
        "recenter_had_request": quantity(recenter, "queued") > 0.01,
        "recenter_cleared": cleared("recenter"),
        "recenter_discarded_request": discarded("recenter"),
        "recenter_left_no_step": settled("recenter_settled"),
    }
    if respawn_required:
        checks.update({
            "respawn_stranded_request": quantity(phase("dead_queued"), "pending") > 0.01,
            # Read after the settle window, not at the respawn sample. The
            # client's pawn arrives by replication and state Dead only calls
            # ClientRestart from the ReplicatedEvent that follows, so there is
            # a tick where the body exists and the request has not been
            # discarded yet. Nothing can move in it -- ProcessMove needs
            # PlayerWalking -- so the instant that matters is the later one,
            # which is also where the step is measured.
            "respawn_cleared": cleared("respawn_settled"),
            "respawn_discarded_request": discarded("restart"),
            "respawn_left_no_step": settled("respawn_settled"),
        })
    return {"passed": all(checks.values()), "checks": checks,
            "respawn_required": respawn_required,
            "recenter_queued": quantity(recenter, "queued"),
            "recenter_moved": quantity(phase("recenter_settled"), "moved"),
            "respawn_queued": quantity(phase("dead_queued"), "pending"),
            "respawn_moved": quantity(phase("respawn_settled"), "moved"),
            "scope": "queued room displacement across a recenter and a death/respawn"}


def verify_damage(server: str, driver: str, observer: str | None = None) -> dict:
    transport = verify_transport(server, driver, observer)
    spawns = [e for e in events(server, "target_spawn") if mode_is(e.get("netmode"), "dedicated")]
    target = spawns[-1].get("target") if spawns else None
    # Revision 4 uses an authority-assigned identity, not the process-local
    # UObject name. Require the target's lifetime to belong to this driver.
    identity = re.fullmatch(r"w([1-9]\d*)-c([1-9]\d*)-p([1-9]\d*)", target or "")
    def same_lifetime(e):
        return bool(identity) and tuple(e.get(k) for k in ("world", "connection", "pawn")) == identity.groups()
    target_lifetime = bool(identity) and identity[1] == transport["world"] and any(
        same_lifetime(e) and is_true(e.get("hello")) and mode_is(e.get("netmode"), "client")
        for e in events(driver, "status")) and any(
        same_lifetime(e) and mode_is(e.get("netmode"), "dedicated") for e in events(server, "authority"))
    damage = [e for e in events(server, "target_damage") if target and e.get("target") == target
              and mode_is(e.get("netmode"), "dedicated")]
    hits = [e for e in events(driver, "local_hit") if target and e.get("target") == target
            and mode_is(e.get("netmode"), "client")]
    impacts = [e for e in events(server, "impact") if target and e.get("target") == target
               and mode_is(e.get("netmode"), "dedicated")]
    final = damage[-1] if damage else {}
    def received(log):
        return bool(damage) and any(e.get("target") == target and mode_is(e.get("netmode"), "client")
            and e.get("receipt") == final.get("receipt") and e.get("health") == final.get("after")
            and is_true(e.get("dead")) for e in events(log, "target_state"))
    def death_callback(log, mode):
        return any(e.get("target") == target and mode_is(e.get("netmode"), mode)
            and is_true(e.get("accepted")) and is_true(e.get("played")) for e in events(log, "target_death"))
    checks = {
        "real_transport": transport["passed"],
        "target_lifetime_matches_driver": target_lifetime,
        "complete_health_fields": bool(damage) and all(
            all(re.fullmatch(r"-?\d+", e.get(k, "")) for k in ("before", "after", "damage", "receipt"))
            for e in damage),
        "stock_enemy_spawned": bool(spawns) and number(spawns[-1], "health") > 0,
        "immediate_client_hit_path": bool(hits),
        "matching_stock_server_impacts": bool(damage) and len(impacts) == len(damage) == len(hits),
        "one_damage_receipt_per_hit": [number(e, "receipt") for e in damage] == list(range(1, len(damage) + 1)),
        "continuous_health": bool(damage) and number(damage[0], "before") == number(spawns[-1], "health")
            and all(number(a, "after") == number(b, "before") for a, b in zip(damage, damage[1:])),
        "health_reduced": bool(damage) and all(number(e, "after") < number(e, "before") for e in damage),
        "server_death": bool(damage) and number(final, "after") <= 0 and is_true(final.get("dead")),
        "stock_server_death_callback": death_callback(server, "dedicated"),
        "stock_driver_death_callback": death_callback(driver, "client"),
        "driver_received_final_health": received(driver),
    }
    if observer is not None:
        checks["observer_received_final_health"] = received(observer)
        checks["stock_observer_death_callback"] = death_callback(observer, "client")
    return {"passed": all(checks.values()), "checks": checks, "target": target,
            "scope": "stock stationary clot damage/death through real client impact RPC; diagnostic replicated health receipts",
            "damage_receipts": len(damage)}


def parse_info(packet: bytes) -> dict:
    """Parse the fixed A2S_INFO prefix through VAC. Reject malformed/split packets."""
    if not packet.startswith(b"\xff\xff\xff\xffI") or len(packet) < 6:
        raise ValueError("Not a complete uncompressed A2S_INFO response")
    offset = 6
    strings = []
    for _ in range(4):
        end = packet.find(b"\0", offset)
        if end < 0:
            raise ValueError("Truncated A2S string")
        strings.append(packet[offset:end].decode("utf-8", errors="replace"))
        offset = end + 1
    if len(packet) < offset + 9:
        raise ValueError("Truncated A2S status")
    appid, players, maximum, bots, server_type, environment, visibility, vac = struct.unpack_from("<H7B", packet, offset)
    if vac not in (0, 1) or visibility not in (0, 1):
        raise ValueError("Invalid A2S security fields")
    return dict(name=strings[0], map=strings[1], folder=strings[2], game=strings[3],
                appid=appid, players=players, maximum=maximum, bots=bots,
                server_type=chr(server_type), environment=chr(environment), password=bool(visibility), secure=bool(vac))


def local_lan_readiness(log: str, port: int, expected_map: str) -> dict:
    """Observe stock LAN startup; this is not a Steam A2S/VAC query result."""
    advertised = dict(re.findall(r"Advertising: (\w+)=([^\r\n]*)", log))
    bindings = re.findall(r"\[FSocketWin::Bind\] Binding to ([0-9.]+):" + str(port) + r"\b", log)
    checks = {
        "loopback_game_socket": bool(bindings) and bindings[-1] == "127.0.0.1",
        "lan_beacon": "Listening for lan beacon requests on " in log,
        "stock_lan_auth_mode": "Disabling all authentication, due to bIsLanMatch being set to true" in log,
        "lan_setting": advertised.get("bIsLanMatch") == "True",
        "anti_cheat_setting_off": advertised.get("bAntiCheatProtected") == "False",
        "password_required": advertised.get("bRequiresPassword") == "True",
        "expected_map": advertised.get("MapName", "").lower() == expected_map.lower(),
    }
    return {"passed": all(checks.values()), "checks": checks,
            "scope": "owned loopback LAN server startup logs; not Steam registration or WAN acceptance"}


def query_loopback(port: int, timeout: float = 1.0) -> dict:
    return query_server("127.0.0.1", port, timeout)


def query_server(host: str, port: int, timeout: float = 1.0) -> dict:
    request = b"\xff\xff\xff\xffTSource Engine Query\0"
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.settimeout(timeout)
        sock.connect((host, port))
        sock.send(request)
        packet = sock.recv(65535)
        if packet.startswith(b"\xff\xff\xff\xffA"):
            if len(packet) != 9:
                raise ValueError("Malformed A2S challenge")
            sock.send(request + packet[5:9])
            packet = sock.recv(65535)
        return parse_info(packet)
