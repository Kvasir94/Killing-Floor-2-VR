"""Summarize recorded avatar-preview telemetry; never launch or modify a game."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path
import re

from evidence import events, is_true, verify_transport


IDENTITY_FIELDS = ("world", "connection", "pawn", "reference", "source")
ACQUISITION_SECONDS = 1.0
# Exact message/function pairs observed in accepted revision-4 driver logs:
# sessions/20260916-164810-228169 and 20260916-165040-349396.
# These remain visible and are exempt only during bounded startup/acquisition.
KNOWN_STARTUP_WARNINGS = {
    "KFGame.KFPawn_Human:UpdateActiveSkillsPath:0246": "Accessed None 'myGfxHUD'",
    "KFGame.KFPawn_Human:UpdateActiveSkillsPath:025A": "Accessed None",
    "KFGame.KFGFxMoviePlayer_HUD:UpdateObjectiveActive:00B7": "Accessed None 'KFGRI'",
    "KFGame.KFGFxHUD_ObjectiveConatiner:SetActive:01D9": "Accessed None",
    "KFGame.KFPlayerController:InitPerkLoadout:000A": "Accessed None 'CurrentPerk'",
    "KFGame.KFPlayerController:InitPerkLoadout:0035": "Accessed None 'CurrentPerk'",
    "KFGame.KFPlayerReplicationInfo:OnTalkerRegistered:02AD": "Accessed None 'VoiceInterface'",
}
KNOWN_STARTUP_PLATFORM_ERRORS = {"Error: WriteOnlineStats: SessionHasStats is FALSE"}


def finite(event, key):
    try:
        value = float(event[key])
        return value if math.isfinite(value) else None
    except (KeyError, TypeError, ValueError):
        return None


def identity(event):
    for key in IDENTITY_FIELDS[:3]:
        value = finite(event, key)
        if value is None or value <= 0 or int(value) != value:
            return None
    reference = finite(event, "reference")
    if reference is None or reference < 0 or int(reference) != reference or event.get("source") in (None, "", "None"):
        return None
    return tuple(event[key] for key in IDENTITY_FIELDS)


def inspect_stream(rows, counter, metrics, limits, min_reports, min_samples, min_span,
                   required_true, required_false=()):
    times = [finite(e, "time") for e in rows]
    counts = [finite(e, counter) for e in rows]
    valid_times = bool(rows) and all(v is not None and v >= 0 for v in times)
    valid_counts = bool(rows) and all(v is not None and v >= 0 and int(v) == v for v in counts)
    checks = {
        "minimum_reports": len(rows) >= min_reports,
        "ordered_distinct_times": valid_times and all(b > a for a, b in zip(times, times[1:])),
        "minimum_observation_span": valid_times and times[-1] - times[0] >= min_span,
        "increasing_sample_counter": valid_counts and all(b > a for a, b in zip(counts, counts[1:])),
        "minimum_new_samples": valid_counts and counts[-1] - counts[0] >= min_samples,
    }
    for key in required_true:
        checks[key] = bool(rows) and all(is_true(e.get(key)) for e in rows)
    for key in required_false:
        checks[key + "_disabled"] = bool(rows) and all(str(e.get(key)).lower() in ("false", "0") for e in rows)
    measured = {}
    for key in metrics:
        values = [finite(e, key) for e in rows]
        valid = bool(rows) and all(v is not None and v >= 0 for v in values)
        checks[key + "_finite"] = valid
        checks[key + "_within_limit"] = valid and max(values) <= limits[key]
        measured[key] = {"maximum": max(values) if valid else None, "limit": limits[key]}
    return {"passed": all(checks.values()), "checks": checks, "reports": len(rows),
            "first_time": times[0] if times else None, "last_time": times[-1] if times else None,
            "new_samples": counts[-1] - counts[0] if valid_counts else None,
            "metrics": measured,
            "not_ready_reports": sum(not is_true(e.get("ready")) for e in rows),
            "stale_reports": sum(str(e.get("fresh")).lower() in ("false", "0") for e in rows)}


def acquisition_window(streams):
    # Anchor once at the first ready body report. Neither late fading nor a
    # later contact acquisition can restart/extend this fixed window.
    first_ready = next((finite(e, "time") for e in streams["body"]
                        if is_true(e.get("ready")) and finite(e, "time") is not None), None)
    cutoff = first_ready + ACQUISITION_SECONDS if first_ready is not None else None
    steady, excluded, checks = {}, {}, {"first_ready_report": first_ready is not None}
    initial_empty = []
    tracking_acquired = False
    for event in streams["body"]:
        if is_true(event.get("fresh")) and event.get("flags") == "7":
            tracking_acquired = True
        elif (not tracking_acquired and cutoff is not None and finite(event, "time") is not None
              and first_ready <= finite(event, "time") < cutoff
              and str(event.get("fresh")).lower() in ("false", "0")
              and event.get("flags") == "0" and finite(event, "alpha") == 0):
            # A newly created visual rig can precede its first pose snapshot.
            # Only a fully hidden, wholly untracked initial report qualifies.
            # After ANY complete fresh pose, even an in-window loss must fail.
            initial_empty.append(event)
    for kind, rows in streams.items():
        excluded[kind] = [e for e in rows if cutoff is not None
                          and finite(e, "time") is not None and finite(e, "time") < cutoff]
        steady[kind] = [e for e in rows if e not in excluded[kind]]
        # Preserve ordering, isolation and finite measurements across ALL rows,
        # including acquisition. Only contact readiness/blend/geometry limits
        # get the bounded exception. Never-acquired hidden initial frames are
        # reported separately; tracking loss and unsafe components never qualify.
        metrics = (("left_error", "right_error", "left_solve_error", "right_solve_error", "head_degrees")
                   if kind == "body" else ("muzzle_error", "bore_error_deg"))
        required = (("noncolliding", "unique_tree", "source_unchanged")
                    if kind == "body" else ("noncolliding",))
        all_rows = inspect_stream(rows, "samples" if kind == "body" else "placements", metrics,
                                  {name: float("inf") for name in metrics}, 1, 0, 0,
                                  required, ("physics_asset",) if kind == "weapon" else ())
        for name in ("ordered_distinct_times", "increasing_sample_counter", *required):
            checks[kind + "_all_" + name] = all_rows["checks"][name]
        for name in metrics:
            checks[kind + "_all_" + name + "_finite"] = all_rows["checks"][name + "_finite"]
        if kind == "weapon":
            checks["weapon_all_physics_disabled"] = all_rows["checks"]["physics_asset_disabled"]
        else:
            checks["body_all_fresh"] = bool(rows) and all(is_true(e.get("fresh")) or e in initial_empty for e in rows)
            checks["body_all_tracking_valid"] = bool(rows) and all(e.get("flags") == "7" or e in initial_empty for e in rows)
            checks["body_all_blend_finite"] = bool(rows) and all(finite(e, "alpha") is not None
                and 0 <= finite(e, "alpha") <= 1 for e in rows)
    times = [finite(e, "time") for rows in excluded.values() for e in rows]
    report = {"first_ready_time": first_ready, "steady_from_time": cutoff,
              "maximum_window_seconds": ACQUISITION_SECONDS,
              "first_excluded_time": min(times) if times else None,
              "last_excluded_time": max(times) if times else None,
              "observed_excluded_span_seconds": max(times) - min(times) if times else 0,
              "initial_never_acquired_reports": initial_empty,
              "initial_never_acquired_count": len(initial_empty),
              "reports": excluded,
              "scope": "Only reports strictly before first ready body time + 1 second are excluded from steady geometry/contact limits. Hidden initial fresh=false/flags=0/alpha=0 frames may precede the first complete fresh pose within that same window. After tracking acquisition, freshness/tracking are never exempt. All reports retain isolation, finite-value and ordered time/sample checks."}
    return steady, report, checks


def classify_warnings(log):
    """Retain warning messages/stacks and account for every occurrence by line."""
    lines = log.splitlines()
    anchor = next((i for i, line in enumerate(lines) if "KF2VRNet avatar_preview_bound " in line), None)
    if anchor is None:
        anchor = next((i for i, line in enumerate(lines) if "KF2VRNet avatar_preview_frame " in line), None)
    def timestamp(line):
        match = re.match(r"^\[(\d+(?:\.\d+)?)\]", line)
        return float(match[1]) if match else None
    anchor_time = timestamp(lines[anchor]) if anchor is not None else None
    groups = {}
    pattern = re.compile(r"ScriptWarning|ScriptError|Warning:|\bError:|Critical:|Fatal error|Assertion failed|Accessed None", re.I)
    for index, line in enumerate(lines):
        if not pattern.search(line):
            continue
        context = []
        for following in lines[index + 1:index + 9]:
            if not following.startswith(("\t", " ")):
                break
            context.append(following.strip())
        functions = [m[1] for row in context if (m := re.match(r"Function\s+(\S+)", row))]
        message = re.sub(r"^\[[^]]+\]\s*", "", line).strip()
        at = timestamp(line)
        startup = anchor is not None and (index < anchor or (anchor_time is not None and at is not None
            and anchor_time <= at <= anchor_time + ACQUISITION_SECONDS))
        script_message = re.match(r"ScriptWarning:\s*(.*)$", message)
        # The object can be a derived KF2VRNetPlayerController executing a stock
        # function. Only the exact executing Function context is allowlisted.
        known = bool(script_message and functions) and all(
            KNOWN_STARTUP_WARNINGS.get(function) == script_message[1] for function in functions)
        avatar = bool(re.search(r"KF2VRNetAvatar|avatar_preview|avatar_weapon_preview", "\n".join([message, *context]), re.I))
        net_function = any(function.startswith(("KF2VRNet.", "KF2VRNetClient.")) for function in functions)
        spawn_failure = bool(re.search(r"SpawnActor failed", message, re.I))
        # Severity is the channel at the start of the stripped line. A
        # DevOnline diagnostic containing the word "error" is not Error:.
        hard_error = bool(re.search(r"^(?:ScriptError|Error|Critical):|Fatal error|Assertion failed", message, re.I))
        if avatar or net_function or spawn_failure:
            category, blocking = "avatar_or_mod_warning", True
        elif message in KNOWN_STARTUP_PLATFORM_ERRORS and startup and not functions:
            category, blocking = "known_stock_startup_platform_error", False
        elif hard_error:
            category, blocking = "unclassified_error", True
        elif known and startup:
            category, blocking = "known_stock_startup_warning", False
        elif script_message or "Accessed None" in message:
            category, blocking = "late_or_unknown_script_warning", True
        else:
            # Preserve ordinary engine/resource warnings without upgrading their
            # previous severity policy. No unknown error enters this category.
            category, blocking = "other_engine_warning", False
        key = (category, message, tuple(context))
        if key not in groups:
            groups[key] = {"classification": category, "blocking": blocking,
                           "message": message, "context": context, "functions": functions,
                           "line_numbers": [], "timestamps": []}
        groups[key]["line_numbers"].append(index + 1)
        groups[key]["timestamps"].append(at)
    records = list(groups.values())
    for record in records:
        record["count"] = len(record["line_numbers"])
    return {"first_bound_log_line": anchor + 1 if anchor is not None else None,
            "first_bound_log_time": anchor_time,
            "known_startup_deadline_log_time": anchor_time + ACQUISITION_SECONDS if anchor_time is not None else None,
            "occurrences": sum(item["count"] for item in records),
            "blocking_occurrences": sum(item["count"] for item in records if item["blocking"]),
            "known_stock_startup_occurrences": sum(item["count"] for item in records
                if item["classification"] == "known_stock_startup_warning"),
            "known_stock_startup_platform_error_occurrences": sum(item["count"] for item in records
                if item["classification"] == "known_stock_startup_platform_error"),
            "records": records}


def summarize_log(log, *, min_reports=3, min_samples=60, min_span=2.0,
                  max_control_error=2.0, max_muzzle_error=2.0, max_bore_error=1.0,
                  max_head_error=1.0):
    body_rows = events(log, "avatar_preview_frame")
    weapon_rows = events(log, "avatar_weapon_preview")
    groups = {}
    invalid = []
    for kind, rows in (("body", body_rows), ("weapon", weapon_rows)):
        for event in rows:
            key = identity(event)
            if key is None:
                invalid.append({"kind": kind, "event": event})
            else:
                groups.setdefault(key, {"body": [], "weapon": []})[kind].append(event)
    lifetimes = []
    for key, streams in sorted(groups.items()):
        streams, acquisition, all_report_checks = acquisition_window(streams)
        body_metrics = {"left_error": max_control_error, "right_error": max_control_error,
                        "left_solve_error": max_control_error, "right_solve_error": max_control_error,
                        "head_degrees": max_head_error}
        body = inspect_stream(streams["body"], "samples", tuple(body_metrics), body_metrics,
            min_reports, min_samples, min_span,
            ("ready", "fresh", "noncolliding", "unique_tree", "source_unchanged", "right_contact"))
        body["checks"]["all_devices_tracked"] = bool(streams["body"]) and all(e.get("flags") == "7" for e in streams["body"])
        body["checks"]["evaluated_bones_recorded"] = bool(streams["body"]) and all(
            finite(e, "saved_atoms") is not None and finite(e, "saved_atoms") > 0 for e in streams["body"])
        body["checks"]["full_weight_after_acquisition"] = bool(streams["body"]) and all(
            finite(e, "alpha") is not None and 0.999 <= finite(e, "alpha") <= 1 for e in streams["body"])
        body["diagnostic_metrics"] = {}
        for name in ("head_position_error", "left_reach_clamp", "right_reach_clamp"):
            values = [finite(e, name) for e in streams["body"]]
            valid = bool(values) and all(v is not None and v >= 0 for v in values)
            body["diagnostic_metrics"][name] = {"maximum": max(values) if valid else None,
                                               "finite": valid, "threshold_applied": False}
            body["checks"][name + "_finite"] = valid
        body["passed"] = all(body["checks"].values())
        weapon = inspect_stream(streams["weapon"], "placements", ("muzzle_error", "bore_error_deg"),
            {"muzzle_error": max_muzzle_error, "bore_error_deg": max_bore_error},
            min_reports, min_samples, min_span, ("ready", "effective_muzzle", "noncolliding"), ("physics_asset",))
        lifetimes.append({"identity": dict(zip(IDENTITY_FIELDS, key)), "body": body, "weapon": weapon,
                          "acquisition": acquisition, "all_report_checks": all_report_checks,
                          "passed": body["passed"] and weapon["passed"] and all(all_report_checks.values())})
    warnings = classify_warnings(log)
    errors = [record["message"] for record in warnings["records"] if record["blocking"]]
    stale_events = events(log, "avatar_preview_stale")
    return {"telemetry_passed": bool(lifetimes) and not invalid and not errors and not stale_events
            and all(item["passed"] for item in lifetimes),
            "lifetimes": lifetimes, "invalid_identity_reports": invalid,
            "script_error_count": warnings["blocking_occurrences"], "script_errors": errors[:40],
            "warning_classification": warnings,
            "stale_events": stale_events,
            "thresholds": {"min_reports_per_stream": min_reports, "min_new_samples": min_samples,
                           "min_span_seconds": min_span, "max_control_error_uu": max_control_error,
                           "max_muzzle_error_uu": max_muzzle_error, "max_bore_error_degrees": max_bore_error,
                           "max_head_error_degrees": max_head_error},
            "scope": "Logged finite control/muzzle errors and reported collision isolation for matching lifetimes only.",
            "visual_acceptance_verified": False, "damage_accuracy_verified": False}


def read_snapshot(path):
    raw = path.read_bytes()
    encoding = "utf-16" if raw.startswith((b"\xff\xfe", b"\xfe\xff")) else "utf-8-sig"
    return raw.decode(encoding, errors="replace"), hashlib.sha256(raw).hexdigest().upper()


def summarize_session(path, **options):
    raw, run_hash = read_snapshot(path)
    run = json.loads(raw)
    roles = {role["role"]: role for role in run.get("roles", [])}
    logs, inputs = {}, {"run": {"path": str(path.resolve()), "sha256": run_hash}}
    for name in ("server", "driver", "teammate"):
        log_path = Path(roles.get(name, {}).get("log", ""))
        if not log_path.is_absolute():
            log_path = path.parent / log_path
        if log_path.is_file():
            logs[name], fingerprint = read_snapshot(log_path)
            inputs[name] = {"path": str(log_path.resolve()), "sha256": fingerprint}
        else:
            logs[name] = ""
            inputs[name] = {"path": str(log_path), "missing": True}
    summary = summarize_log(logs["driver"], **options)
    # In this fixture the replay teammate is the pose producer; the live driver
    # is its independent observer. Do not count the producer as its observer.
    transport = verify_transport(logs["server"], logs["teammate"], logs["driver"])
    producers = {(e.get("world"), e.get("connection"), e.get("pawn"))
                 for e in events(logs["teammate"], "status") if is_true(e.get("hello"))}
    checks = {
        "avatar_preview_requested": run.get("avatar_preview") is True,
        "separate_replay_requested": run.get("replay_teammate") is True,
        "native_replay_role": roles.get("teammate", {}).get("native_adapter") is True
            and "-kf2vr-hand-replay" in roles.get("teammate", {}).get("args", []),
        "server_query_vac_off": run.get("server_query", {}).get("secure") is False,
        "finished_session": run.get("status") == "closed",
        "handshake_observed": run.get("mod_handshake_observed") is True,
        "user_config_preserved": run.get("user_config_preserved") is True,
        "cleanup_complete": run.get("cleanup_complete") is True and run.get("cleanup_errors") == [],
        "two_client_pose_transport": transport["passed"],
        "preview_lifetimes_match_replay": bool(summary["lifetimes"]) and all(
            tuple(item["identity"][k] for k in IDENTITY_FIELDS[:3]) in producers for item in summary["lifetimes"]),
    }
    summary.update(schema="kf2vr/avatar-preview-evidence/1", created_utc=datetime.now(timezone.utc).isoformat(),
                   inputs=inputs, session_checks=checks, transport=transport,
                   session_telemetry_passed=summary["telemetry_passed"] and all(checks.values()),
                   session_status=run.get("status"), live_vr_requested=run.get("vr") is True)
    return summary


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("session", type=Path, help="Completed friend-launcher sessions/<id>/run.json")
    parser.add_argument("--output", type=Path, help="Write a separate JSON receipt; never overwrite inputs")
    parser.add_argument("--min-reports", type=int, default=3)
    parser.add_argument("--min-samples", type=int, default=60)
    parser.add_argument("--min-span", type=float, default=2.0)
    parser.add_argument("--max-control-error", type=float, default=2.0)
    parser.add_argument("--max-muzzle-error", type=float, default=2.0)
    parser.add_argument("--max-bore-error", type=float, default=1.0)
    parser.add_argument("--max-head-error", type=float, default=1.0)
    args = parser.parse_args(argv)
    options = {name: getattr(args, name) for name in ("min_reports", "min_samples", "min_span",
               "max_control_error", "max_muzzle_error", "max_bore_error", "max_head_error")}
    if args.min_reports < 3 or args.min_samples < 1 or any(not math.isfinite(v) or v <= 0 for v in options.values()):
        parser.error("Require at least 3 reports and positive finite sample/time/error thresholds")
    summary = summarize_session(args.session, **options)
    encoded = json.dumps(summary, indent=2, allow_nan=False) + "\n"
    if args.output:
        protected = {Path(item["path"]).resolve() for item in summary["inputs"].values()}
        if args.output.resolve() in protected:
            parser.error("Receipt output must not replace the session or any input log")
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(encoded, encoding="utf-8")
    print(encoded, end="")
    return 0 if summary["session_telemetry_passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
