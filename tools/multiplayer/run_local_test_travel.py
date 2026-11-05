"""Opted-in Solo channel travel acceptance. Preparation is the default; --run launches.

Uses normal packaged play and game console travel, not diagnostic/synthetic input.
This verifies native channel handoff, not the in-headset Local Match button.
"""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import uuid

MAP = re.compile(r"KF-[A-Za-z0-9_-]+\Z")
SESSION = re.compile(r"[0-9a-f]{32}\Z")
CONSOLE_FAILURE = re.compile(
    r"command not recognized|failed to (?:load|find)|can't find (?:file|class|object)|"
    r"class\s+[^\r\n]*\s+not found|classnotfound", re.IGNORECASE)


def remaining_game_budget(duration, creation_time, now=None):
    """Reserve 20 seconds before the owned launcher's fixed process deadline."""
    started = int(creation_time) / 10_000_000 - 11_644_473_600
    current = time.time() if now is None else now
    if started <= 0 or started > current + 5:
        raise ValueError("Invalid owned process creation time")
    return max(0.0, duration - max(0.0, current - started) - 20)


def validate_negative_fixture(negative, absolute_probe, destination, packages):
    if negative == "drop-options":
        if not absolute_probe:
            raise ValueError("drop-options requires explicit --absolute-travel-probe; console open inherits URL options")
        if destination.casefold() != "kf-outpost":
            raise ValueError("The absolute travel fixture has a fixed KF-Outpost destination (--map)")
        if not any(package["name"].casefold() == "reloadstatetools.u" for package in packages):
            raise ValueError("--absolute-travel-probe requires compiled ReloadStateTools.u in --probe-package-root")
    elif absolute_probe:
        raise ValueError("--absolute-travel-probe is only used by --negative drop-options")


def check_console_output(text):
    for line in text.splitlines():
        if CONSOLE_FAILURE.search(line):
            raise RuntimeError("Before-travel console/load failure: " + line.strip())


def check_probe_log(text, commands, packages, failure_markers):
    """Ambient engine warnings are not replies to our console requests.

    Match asynchronous load failures only to explicitly requested script
    packages/classes. Probe-defined failure markers remain unconditional.
    """
    failed = [marker for marker in failure_markers if marker in text]
    if failed:
        raise RuntimeError("Before-travel probe failure marker: " + ", ".join(failed))
    targets = {Path(package["name"]).stem for package in packages}
    for command in commands:
        summon = re.match(r"\s*summon\s+([A-Za-z_]\w*(?:\.\w+)+)\b", command, re.IGNORECASE)
        if summon:
            targets.update((summon[1], summon[1].split(".")[0]))
    requested = {" ".join(command.casefold().split()) for command in commands}
    for line in text.splitlines():
        if not CONSOLE_FAILURE.search(line):
            continue
        unsupported = re.search(r"command not recognized:\s*(.*)", line, re.IGNORECASE)
        relevant = (unsupported is not None and " ".join(unsupported[1].casefold().split()) in requested)
        relevant = relevant or any(re.search(r"(?<![A-Za-z0-9_])" + re.escape(target)
                                            + r"(?![A-Za-z0-9_])", line, re.IGNORECASE) for target in targets)
        if relevant:
            raise RuntimeError("Before-travel requested package/class failure: " + line.strip())


def probe_packages(workspace, source, release, game):
    """Only explicit, ordinary extra script files from this workspace's build tree."""
    base = (Path(workspace).resolve() / "build").resolve()
    source = Path(source).absolute()
    if not source.is_dir() or not source.resolve().is_relative_to(base):
        raise ValueError("Probe package directory must be inside workspace/build")
    for path in (source, *source.parents):
        if path.is_symlink() or getattr(path.stat(), "st_file_attributes", 0) & 0x400:
            raise ValueError("Linked probe package paths are refused")
        if path == base:
            break
    from release_state import digest
    shipped = {p.name.casefold(): p for p in (Path(release) / "Packages").glob("*.u")}
    stock = {p.name.casefold() for p in (Path(game) / "KFGame/BrewedPC").glob("*.u")}
    extras = []
    for path in sorted(source.iterdir()):
        if path.suffix.casefold() != ".u":
            continue
        if (not path.is_file() or path.is_symlink() or path.stat().st_nlink != 1
                or getattr(path.stat(), "st_file_attributes", 0) & 0x400
                or not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*\.u", path.name, re.IGNORECASE)):
            raise ValueError("Invalid or linked probe package: " + path.name)
        key = path.name.casefold()
        if key in stock:
            raise ValueError("Probe package conflicts with installed stock package: " + path.name)
        if key in shipped:
            if digest(path) != digest(shipped[key]):
                raise ValueError("Probe package conflicts with selected release: " + path.name)
            continue
        extras.append({"name": path.name, "source": str(path), "sha256": digest(path)})
    if not extras:
        raise ValueError("Probe package directory contains no extra .u packages")
    return extras


def configure_probe_packages(role, run, packages):
    """Extend only this launch's disposable role configuration and record copies."""
    from session import config_hashes, read_ini, set_ini
    from release_state import digest
    root = Path(run).resolve()
    configs = Path(role["config_root"]).resolve()
    if not configs.is_relative_to(root) or role["role"] != "driver":
        raise ValueError("Probe packages require the owned driver session")
    target = configs.parent / "ProbePackages"
    target.mkdir()  # Never reuse or overwrite a previous run's package directory.
    copies = []
    for package in packages:
        source = Path(package["source"])
        if source.is_symlink() or source.stat().st_nlink != 1 or digest(source) != package["sha256"]:
            raise ValueError("Probe package changed before launch: " + package["name"])
        copied = target / package["name"]
        with copied.open("xb") as output, source.open("rb") as original:
            shutil.copyfileobj(original, output)
        if digest(copied) != package["sha256"]:
            raise ValueError("Probe package copy changed: " + package["name"])
        copies.append({**package, "session_path": str(copied)})
    engine = configs / "KFEngine.ini"
    text = read_ini(engine)
    core = re.search(r"(?ims)^\[Core\.System\][^\n]*\n(.*?)(?=^\[|\Z)", text)
    if not core:
        raise ValueError("Missing Core.System in owned probe configuration")
    paths = {key: re.findall(r"(?im)^" + key + r"=([^\r\n]*)", core[1]) + [str(target)]
             for key in ("Paths", "ScriptPaths", "SeekFreePCPaths", "BrewedPCPaths")}
    engine.write_text(set_ini(text, "Core.System", paths), encoding="utf-16")
    role["config_hashes"] = config_hashes(configs)
    role["probe_packages"] = copies


def parse_ready(text, session, pid=None):
    fields = text.rstrip("\n").split("\t")
    if len(fields) < 5 or fields[0] != session or not SESSION.fullmatch(session) or fields[2] != "test_unranked":
        raise ValueError("Readiness identity or session metadata missing")
    values = dict(field.split("=", 1) for field in fields[3:])
    result = {"session": fields[0], "pid": int(fields[1]),
              "start_tick_ms": int(values["start_tick_ms"]), "duration": values["duration"]}
    if result["pid"] <= 0 or (pid is not None and result["pid"] != pid):
        raise ValueError("Readiness process identity mismatch")
    if result["start_tick_ms"] < 0 or result["duration"] != "game_session":
        raise ValueError("Readiness does not carry game-session authority")
    return result


def parse_status(text, expected_map):
    lines = text.splitlines()
    if not lines or not lines[0].startswith("ok\t"):
        raise ValueError("Status request failed")
    fields = dict(field.split("=", 1) for field in lines[0].split("\t")[1:] if "=" in field)
    if fields.get("enabled") != "1" or fields.get("test_unranked") != "1" or fields.get("netmode") != "NM_Standalone":
        raise ValueError("Status is not enabled unranked standalone control")
    if fields.get("map", "").casefold() != expected_map.casefold():
        raise ValueError("Status did not come from the requested destination map")
    players = [int(parts[1]) for line in lines[1:] if len(parts := line.split("\t")) >= 2 and parts[0] == "player"]
    if len(players) != 1 or players[0] < 0:
        raise ValueError("Expected exactly one identifiable local player")
    return players[0]


def travel_command(destination, session=None):
    if not MAP.fullmatch(destination):
        raise ValueError("Invalid map name")
    url = (destination + "?Game=KFGameContent.KFGameInfo_Survival?Difficulty=0?GameLength=0"
           "?VRNormalGame=1?Mutator=KF2VR.VRBootstrap,KF2VR.VRDemo")
    if session is not None:
        if not SESSION.fullmatch(session):
            raise ValueError("Invalid session ID")
        url += (",KF2VR.VRLocalTestControl?KF2VRLocalTest=1"
                f"?KF2VRLocalTestSession={session}?KF2VRTestCapacity=1")
    return "open " + url


def audit_counts(text, action):
    rows = [line.split("\t") for line in text.splitlines()]
    return (sum(len(row) > 2 and row[0] == "accepted" and row[2] == action for row in rows),
            sum(len(row) > 1 and row[0] == "result" and row[1] == action for row in rows))


def checked_text(path):
    path = Path(path)
    if not path.is_file() or path.is_symlink() or path.stat().st_nlink != 1:
        raise RuntimeError(f"Missing or linked control file: {path.name}")
    return path.read_text(encoding="ascii")


def queue_duplicate_status(channel, session, action, player):
    """Freshly queue the identical read-only wire, preserving its original receipt.

    submit() normally returns that receipt locally, which cannot test native dedup.
    File timestamp is current so this goes through the normal post-travel floor.
    """
    from local_test_control import request_wire
    wire = request_wire(session, action, "status", player)
    parse_ready(checked_text(channel / "ready.tsv"), session)
    if checked_text(channel / f"{action}.intent") != wire:
        raise RuntimeError("Original status intent changed")
    receipt = checked_text(channel / f"{action}.receipt")
    if not receipt.startswith(session + "\t" + action + "\tok\t"):
        raise RuntimeError("Original status receipt is not successful")
    request = channel / f"{action}.request"
    if request.exists():
        raise RuntimeError("Original request is still pending; outcome uncertain")
    temporary = channel / f"{action}.writing"
    with temporary.open("x", encoding="ascii", newline="") as stream:
        stream.write(wire)
        stream.flush()
        os.fsync(stream.fileno())
    temporary.rename(request)
    return receipt


def launch_child(args):
    # Use the packaged launcher's own validation, deployment, mutex and cleanup.
    # profile_root is its existing internal override; no auth/settings are patched.
    sys.path.insert(0, str(args.release / "tools/multiplayer"))
    import friends
    options = friends.parse_options(["--solo", "--vr", "--local-test-control", "--store", "steam",
                                     "--game-root", str(args.game_root), "--map", args.map,
                                     "--duration", str(args.duration)])
    options.profile_root = args.profile_root
    friends.parse_options = lambda: options
    if args.probe_package_root is not None:
        packages = probe_packages(args.workspace, args.probe_package_root, args.release, args.game_root)
        original_configure = friends.configure_role
        def configure(run, name, user, game, options):
            role = original_configure(run, name, user, game, options)
            configure_probe_packages(role, run, packages)
            return role
        friends.configure_role = configure
    return friends.main()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--game-root", type=Path, required=True)
    parser.add_argument("--map", default="KF-Outpost")
    parser.add_argument("--destination", default="KF-BurningParis")
    parser.add_argument("--negative", choices=("disable", "drop-options"), default="disable")
    parser.add_argument("--absolute-travel-probe", action="store_true",
                        help="Explicitly use nonshipping ReloadStateTools absolute travel fixture for drop-options (fixed KF-Outpost)")
    parser.add_argument("--duration", type=int, default=360, help="Owned launcher/game lifetime, 180..600 seconds")
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--probe-package-root", type=Path,
                        help="Explicit extra .u directory inside workspace/build; copied into disposable session only")
    parser.add_argument("--before-travel-console", action="append", default=[],
                        help="Explicit existing game-console command, run once before travel; repeat for summon")
    parser.add_argument("--require-log-marker", action="append", default=[], help="Literal fresh game-log marker required before travel")
    parser.add_argument("--failure-log-marker", action="append", default=[], help="Literal fresh game-log marker that stops the run")
    parser.add_argument("--probe-timeout", type=int, default=90, help="Before-travel marker wait, 5..120 seconds")
    parser.add_argument("--launch-child", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--release", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--profile-root", type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    if not 180 <= args.duration <= 600 or not 5 <= args.probe_timeout <= 120 or not MAP.fullmatch(args.map) or not MAP.fullmatch(args.destination) or args.map == args.destination:
        parser.error("Use two distinct installed KF- maps and duration 180..600")
    if args.launch_child:
        if args.release is None or args.profile_root is None:
            parser.error("Owned launcher child requires release and isolated profile")
        return launch_child(args)

    from release_state import selected_release, verify_workspace, digest
    from vr_config import profile_root
    import local_test_control as control
    release, manifest = selected_release(args.workspace)
    verify_workspace(args.workspace, manifest)
    packages = (probe_packages(args.workspace, args.probe_package_root, release, args.game_root)
                if args.probe_package_root is not None else [])
    validate_negative_fixture(args.negative, args.absolute_travel_probe, args.map, packages)
    output = args.workspace / "build/multiplayer/local-test-travel" / datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S-%f")
    output.mkdir(parents=True)
    receipt_path = output / "acceptance.json"
    profile = output / "Profile"
    profile.mkdir()
    original_profile = profile_root()
    profile_before = {}
    for name in ("KFGame.ini", "launcher.json", "machine.json"):
        source = original_profile / name
        profile_before[name] = digest(source) if source.is_file() else None
        if source.is_file():
            if source.is_symlink():
                raise RuntimeError("Linked saved profile refused")
            shutil.copyfile(source, profile / name)
    record = {"schema": "kf2vr/local-test-travel/1", "status": "prepared", "passed": False,
              "release": release.name, "manifest_sha256": digest(release / "release.json"),
              "negative": args.negative, "absolute_travel_probe": args.absolute_travel_probe,
              "scope": "ordinary Solo console map travel and native channel, not menu-button or headset acceptance",
              "checks": {}, "actions": [], "profile_before": profile_before, "probe_packages": packages}
    command = [str(release / "runtime/python.exe"), str(Path(__file__).resolve()), "--launch-child",
               "--release", str(release), "--profile-root", str(profile), "--game-root", str(args.game_root),
               "--map", args.map, "--destination", args.destination, "--duration", str(args.duration)]
    command += ["--workspace", str(args.workspace)]
    if args.probe_package_root is not None:
        command += ["--probe-package-root", str(args.probe_package_root.resolve())]
    record["command"] = command
    def save():
        receipt_path.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
    save()
    print(f"Travel acceptance: {receipt_path}", flush=True)
    if not args.run:
        return 0
    existing = set((release / "sessions").glob("*/run.json"))
    launcher = None
    run_path = None
    started = time.monotonic()
    # Overall limit also bounds startup and cleanup; the launcher duration owns
    # only its game lifetime. Never kill unrelated processes or scan by name.
    absolute_end = started + args.duration + 150
    def wait_for(predicate, seconds, description):
        end = min(absolute_end, time.monotonic() + seconds)
        while time.monotonic() < end:
            value = predicate()
            if value:
                return value
            if launcher is not None and launcher.poll() is not None:
                raise RuntimeError("Owned launcher exited while waiting for " + description)
            time.sleep(0.25)
        raise TimeoutError("Timed out waiting for " + description)
    try:
        startup = subprocess.STARTUPINFO()
        startup.dwFlags = subprocess.STARTF_USESHOWWINDOW
        startup.wShowWindow = 0
        with (output / "launcher.log").open("wb") as log:
            launcher = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                                        startupinfo=startup, creationflags=subprocess.CREATE_NO_WINDOW)
        def find_run():
            paths = set((release / "sessions").glob("*/run.json")) - existing
            matches = []
            for path in paths:
                try:
                    if json.loads(path.read_text())["launcher_pid"] == launcher.pid:
                        matches.append(path)
                except (OSError, ValueError, KeyError):
                    continue
            if len(matches) > 1:
                raise RuntimeError("Multiple session records claim our launcher")
            return matches[0] if matches else None
        run_path = wait_for(find_run, 90, "owned launch record")
        record["run"] = str(run_path)
        def role_ready():
            run = json.loads(run_path.read_text())
            role = next(r for r in run["roles"] if r["role"] == "driver")
            return role if role.get("pid") else None
        role = wait_for(role_ready, 90, "owned game process")
        if packages:
            staged = [{key: entry[key] for key in ("name", "source", "sha256")}
                      for entry in role.get("probe_packages", [])]
            if staged != packages:
                raise RuntimeError("Probe packages changed between preparation and owned launch")
            record["checks"]["probe_package_hashes_preserved"] = True
            record["staged_probe_packages"] = role["probe_packages"]
        session = role["local_test_control"]["session"]
        channel = control.channel_path(session)
        ready = channel / "ready.tsv"
        wait_for(ready.is_file, 150, "explicit local control readiness (requires usable XR runtime)")
        before = parse_ready(checked_text(ready), session, role["pid"])
        record.update(session=session, channel=str(channel), readiness_before=before)
        save()
        def action(operation, player, argument="-", allow_uncertain=False):
            identity = uuid.uuid4().hex
            entry = {"id": identity, "operation": operation, "argument": argument}
            record["actions"].append(entry)
            save()  # Preserve identity before sending any effect.
            try:
                _, result = control.submit(session, operation, player, argument, action_id=identity, timeout=20)
                entry["result"] = result
            except TimeoutError as error:
                entry["result"] = "indeterminate: " + str(error)
                if not allow_uncertain:
                    raise
                result = entry["result"]
            save()
            if not allow_uncertain and not result.startswith("ok\t"):
                raise RuntimeError("Control action refused: " + result)
            return identity, result
        original_id, status = action("status", 0)
        player = parse_status(status, args.map)
        record["checks"]["initial_standalone"] = True
        if args.before_travel_console or args.require_log_marker:
            game_log = Path(role["log"])
            probe_offset = game_log.stat().st_size
            for command_text in args.before_travel_console:
                time.sleep(0.6)
                _, result = action("console", player, command_text)
                check_console_output(result)
            def probes_completed():
                with game_log.open("rb") as stream:
                    stream.seek(probe_offset)
                    text = stream.read().decode("utf-8", errors="replace")
                check_probe_log(text, args.before_travel_console, packages, args.failure_log_marker)
                return all(marker in text for marker in args.require_log_marker)
            wait_for(probes_completed, args.probe_timeout, "explicit before-travel probe markers")
            record["checks"]["before_travel_probes"] = True
            record["probe_markers"] = args.require_log_marker
            save()
        time.sleep(0.6)
        action("console", player, travel_command(args.destination, session), allow_uncertain=True)
        audit = channel / "audit.tsv"
        # Cold map loading plus the stock front-end can exceed 150 seconds.
        # Use only the owned game's remaining launch budget, reserving cleanup
        # time; neither its launch duration nor the native lease is extended.
        wait_for(lambda: "resumed\tsame_launch_session" in checked_text(audit) and ready.is_file(),
                 remaining_game_budget(args.duration, role["creation_time"]), "native travel resumption")
        after = parse_ready(checked_text(ready), session, role["pid"])
        record["readiness_after"] = after
        record["checks"]["same_pid_session_deadline"] = before == after
        record["checks"]["native_suspended_and_resumed"] = "suspended\tworld_closed" in checked_text(audit)
        time.sleep(0.6)
        _, status_after = action("status", 0)
        player_after = parse_status(status_after, args.destination)
        record["checks"]["destination_standalone"] = True
        time.sleep(0.6)
        counts_before = audit_counts(checked_text(audit), original_id)
        original_receipt = queue_duplicate_status(channel, session, original_id, 0)
        wait_for(lambda: audit_counts(checked_text(audit), original_id)[1] > counts_before[1], 10, "native duplicate receipt replay")
        counts_after = audit_counts(checked_text(audit), original_id)
        record["checks"]["native_duplicate_did_not_dispatch"] = (
            counts_before[0] == counts_after[0] == 1 and counts_after[1] == counts_before[1] + 1
            and checked_text(channel / f"{original_id}.receipt") == original_receipt)
        if args.negative == "disable":
            time.sleep(0.6)
            action("disable", player_after)
            wait_for(lambda: not ready.exists(), 10, "explicit disable")
            rejected_id = uuid.uuid4().hex
            try:
                control.submit(session, "status", 0, action_id=rejected_id, timeout=1)
            except RuntimeError as error:
                record["disable_rejection"] = str(error)
                record["checks"]["disabled_refuses_new_action"] = (
                    "test session is not ready; no request was sent" in str(error)
                    and not (channel / f"{rejected_id}.intent").exists()
                    and not (channel / f"{rejected_id}.request").exists())
            else:
                record["checks"]["disabled_refuses_new_action"] = False
        else:
            game_log = Path(role["log"])
            log_offset = game_log.stat().st_size
            time.sleep(0.6)
            absolute_command = "summon ReloadStateTools.VRAbsoluteTravelProbe"
            _, result = action("console", player_after, absolute_command)
            check_console_output(result)
            def stripped_world_loaded():
                with game_log.open("rb") as stream:
                    stream.seek(log_offset)
                    text = stream.read().decode("utf-8", errors="replace")
                check_probe_log(text, [absolute_command], packages, ["KF2VR_ABSOLUTE_TRAVEL failed="])
                loaded = re.findall(r"LoadMap: ([^\r\n]+)", text)
                return (text, loaded[-1]) if loaded and f"Bringing World {args.map}.".casefold() in text.casefold() else None
            text, loaded_url = wait_for(stripped_world_loaded,
                remaining_game_budget(args.duration, role["creation_time"]), "destination without opt-in options")
            # The stock absolute call requests removal; the loaded URL proves it.
            record["negative_loaded_url"] = loaded_url
            record["checks"]["absolute_travel_dispatched"] = "KF2VR_ABSOLUTE_TRAVEL dispatched=1" in text
            record["checks"]["absolute_options_removed"] = not any(
                key in loaded_url.casefold() for key in ("kf2vrlocaltest", "vrlocaltestcontrol", "kf2vrtestcapacity"))
            time.sleep(3)
            with game_log.open("rb") as stream:
                stream.seek(log_offset)
                text = stream.read().decode("utf-8", errors="replace")
            record["checks"]["no_control_without_destination_optin"] = (
                not ready.exists() and checked_text(audit).count("resumed\tsame_launch_session") == 1
                and "KF2VR_LOCAL_TEST enabled=1" not in text)
        save()
    except Exception as error:
        record["error"] = str(error)
        record["status"] = "failed"
        record["cleanup_pending"] = launcher is not None
        save()
        print("Travel acceptance failed; owned cleanup pending: " + str(error), flush=True)
    finally:
        if launcher is not None:
            try:
                launcher.wait(timeout=max(1, absolute_end-time.monotonic()))
            except subprocess.TimeoutExpired:
                record["launcher_forced_stop"] = True
                launcher.terminate()  # Only our child; its existing watchdog owns game/deployment cleanup.
                launcher.wait(timeout=10)
            record["launcher_exit_code"] = launcher.returncode
            record["checks"]["launcher_finished_normally"] = launcher.returncode == 0 and not record.get("launcher_forced_stop")
        if run_path is not None:
            cleanup_end = time.monotonic() + 35
            while time.monotonic() < cleanup_end:
                run = json.loads(run_path.read_text())
                if run.get("cleanup_complete"):
                    break
                time.sleep(0.25)
            record["checks"]["owned_cleanup_and_user_config"] = (
                run.get("cleanup_complete") is True and run.get("user_config_preserved") is True
                and run.get("cleanup_errors") == [])
            final_role = next((item for item in run.get("roles", []) if item.get("role") == "driver"), {})
            final_log = Path(final_role["log"]).read_text(encoding="utf-8", errors="replace") if final_role.get("log") else ""
            record["checks"]["no_runtime_crash"] = final_role.get("exit_code") in (0, 1) and not any(
                marker in final_log.casefold() for marker in ("fatal error", "critical:", "assertion failed"))
        profile_after = {name: digest(original_profile / name) if (original_profile / name).is_file() else None
                         for name in profile_before}
        record["checks"]["saved_profile_preserved"] = profile_before == profile_after
        record["passed"] = bool(args.run and not record.get("error") and record["checks"] and all(record["checks"].values()))
        record["status"] = "passed" if record["passed"] else "failed"
        record["cleanup_pending"] = False
        record["finished_utc"] = datetime.now(timezone.utc).isoformat()
        save()
    print(record["status"], flush=True)
    return 0 if record["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
