"""Selected-release checks. Default to one short network smoke, per project policy."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import subprocess

from release_state import digest, selected_release, verify_release, verify_workspace

# Existing longer diagnostics remain opt-in. Do not expand smoke with an arsenal
# sweep, repetitions, or per-preset runs: visual acceptance is headset-led.
SCENARIOS = {
    "pistol_smoke": ["--native-replay", "--server-adapter", "--paired-weapons", "--duration", "30"],
    "two_vr_owners": ["--native-replay", "--dual-weapons", "--dual-vr-owners", "--duration", "45"],
    # The residual probe rides here because this is the only scenario with a
    # real death and respawn; it costs the run nothing extra.
    "dual_lifecycle": ["--native-replay", "--dual-weapons", "--lifecycle", "--room-residual", "--duration", "45"],
    "controls_room": ["--native-replay", "--vr-controls", "--room-movement", "--duration", "30"],
    # Its own run: refusing moves on purpose is incompatible with the
    # uncorrected-walk claim controls_room makes. The test map is not optional
    # here -- its safe spawn zone is what lets a 40-second walk finish.
    # --vr-controls for the same reason controls_room carries it: something has
    # to draw through the hand inventory or the presenter never calibrates and
    # native_replay_pass fails on an otherwise good run.
    "room_limits": ["--native-replay", "--vr-controls", "--room-clamp", "--test-map", "--duration", "40"],
    "recovery": ["--native-replay", "--recovery", "--duration", "45"],
}
OPTIONAL_HEADSET_FEEDBACK = [
    "Optional physical headset feedback: weapon attachment, comfort, reach and subjective feel.",
    "Optional physical tracked recorder capture; synthetic capture/playback is required runtime evidence.",
]
MANUAL_CHECKS = [
    "Real remote players: LAN/WAN authentication, latency, join in progress and active VR-player reconnect.",
    "Real online match: purchases/sales, upgrades/skins, death/drop/recovery, travel, grenades and melee.",
]


def scenarios(suite, test_map=False):
    names = ["pistol_smoke"] if suite == "smoke" else list(SCENARIOS)
    return [(name, SCENARIOS[name] + (["--test-map"] if test_map and name == "pistol_smoke" else [])) for name in names]


def passed_run(record, release_name, manifest_hash):
    return (record.get("runtime_pass") is True and record.get("user_config_preserved") is True
            and record.get("cleanup_errors") == [] and bool(record.get("finished_utc"))
            and record.get("release") == release_name and record.get("release_manifest_sha256") == manifest_hash)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace", type=Path, required=True)
    parser.add_argument("--game-root", type=Path, required=True)
    parser.add_argument("--server-root", type=Path, required=True)
    parser.add_argument("--user-config", type=Path, required=True)
    parser.add_argument("--suite", choices=("smoke", "online"), default="smoke")
    parser.add_argument("--test-map", action="store_true")
    parser.add_argument("--run", action="store_true")
    args = parser.parse_args(argv)
    release, manifest = selected_release(args.workspace)
    verify_workspace(args.workspace, manifest)
    manifest_hash = digest(release / "release.json")
    output = args.workspace / "build/multiplayer/acceptance" / datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S-%f")
    output.mkdir(parents=True)
    record = {"schema": "kf2vr/release-acceptance/1", "release": release.name,
              "release_manifest_sha256": manifest_hash, "suite": args.suite, "status": "prepared",
              "automated_pass": False, "headset_accepted": False, "headset_required": False,
              "verification_input": "authored synthetic headset/controller input; no physical XR",
              "optional_feedback": OPTIONAL_HEADSET_FEEDBACK, "manual_required": MANUAL_CHECKS, "scenarios": []}
    receipt = output / "acceptance.json"
    def save():
        receipt.write_text(json.dumps(record, indent=2), encoding="utf-8")
    for name, flags in scenarios(args.suite, args.test_map):
        command = [str(release / "runtime/python.exe"), str(release / "tools/multiplayer/session.py"),
                   "--release", str(release), "--game-root", str(args.game_root),
                   "--server-root", str(args.server_root), "--user-config", str(args.user_config),
                   "--cache-root", str(args.workspace / "build/workshop-cache"),
                   "--output-root", str(output / name), "--clients", "2", "--online-server"] + flags
        record["scenarios"].append({"name": name, "command": command, "status": "pending"})
    save()
    print(f"Acceptance receipt: {receipt}", flush=True)
    try:
        for case in record["scenarios"]:
            verify_release(release, manifest_hash)
            command = case["command"] + (["--run"] if args.run else [])
            print(("Running " if args.run else "Preparing ") + case["name"], flush=True)
            log = output / (case["name"] + ".log")
            with log.open("w", encoding="utf-8") as stream:
                result = subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT)
            receipts = sorted((output / case["name"]).glob("*/run.json"))
            case.update(exit_code=result.returncode, log=str(log))
            if len(receipts) != 1:
                raise RuntimeError(f"Expected one {case['name']} receipt; see {log}")
            run = json.loads(receipts[0].read_text())
            case["receipt"] = str(receipts[0])
            okay = passed_run(run, release.name, manifest_hash) if args.run else run.get("status") == "prepared"
            case["status"] = ("passed" if args.run else "prepared") if not result.returncode and okay else "failed"
            save()
            if case["status"] == "failed":
                raise RuntimeError(f"{case['name']} failed. Stop and inspect {log}; no automatic retries.")
        record["automated_pass"] = bool(args.run)
        record["status"] = "automated_passed_manual_pending" if args.run else "prepared"
        save()
        print(record["status"], flush=True)
        return 0
    except BaseException as error:
        record.update(status="failed", automated_pass=False, error=str(error))
        save()
        raise


if __name__ == "__main__":
    raise SystemExit(main())
