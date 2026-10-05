"""Bounded owned Solo command-channel acceptance; no XR session or user input."""
import argparse
import ctypes
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
import uuid
import winreg

import friends
import local_test_control as control
from native_fixture import NativeDeployment, verify_native
from session import config_hashes, digest, log_text, read_ini, set_ini, unreal_command
from workshop_loadout import load_preferences

ROOT = Path(__file__).resolve().parents[2]


def configure_fixture_voice(run_root, role, disabled=False):
    """Apply the optional diagnostic override only to this run's copied config."""
    configs = Path(role["config_root"]).resolve()
    try:
        configs.relative_to(Path(run_root).resolve())
    except ValueError as error:
        raise RuntimeError("Fixture config must remain inside its disposable run") from error
    if disabled:
        path = configs / "KFEngine.ini"
        if path.is_symlink() or path.resolve().parent != configs:
            raise RuntimeError("Fixture engine config must be a local copied file")
        path.write_text(set_ini(read_ini(path), "VoIP", {"bHasVoiceEnabled": "false"}), encoding="utf-16")
        role["test_override"] = "Optional voice disabled only in disposable Solo fixture config; voice coexistence unverified"
    role["config_hashes"] = config_hashes(configs)


def launch_owned_fixture(executable, role, parent_environment):
    environment = friends.role_environment(parent_environment, role)
    environment.update(SteamAppId="232090", SteamGameId="232090", KF2VR_LOG_PATH=str(Path(role["log"]).with_name("native.log")))
    startup = subprocess.STARTUPINFO()
    startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
    startup.wShowWindow = subprocess.SW_HIDE
    role["console_log"] = str(Path(role["log"]).with_name("console.log"))
    # Same owned child launch as the successful network harness. Keep early
    # startup output without inheriting the tool host's pipes.
    with Path(role["console_log"]).open("wb") as console:
        return subprocess.Popen(unreal_command(executable, role["args"]),
            cwd=executable.parent, env=environment, startupinfo=startup,
            stdin=subprocess.DEVNULL, stdout=console, stderr=subprocess.STDOUT)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true", help="Launch only these owned isolated fixture processes")
    parser.add_argument("--fixture-no-voice", action="store_true",
                        help="Disable optional voice only in copied Solo fixture configs; does not test voice coexistence")
    args = parser.parse_args()
    if not args.run:
        print(f"Prepared scope: two owned Solo sessions, commands bounded by allowlist, fixture_no_voice={args.fixture_no_voice}; use --run to execute.")
        return 0
    game = Path(json.loads((ROOT / "docs/intake/install_manifest.json").read_text())["game_root"])
    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders") as key:
        user = Path(os.path.expandvars(winreg.QueryValueEx(key, "Personal")[0])) / "My Games/KillingFloor2/KFGame/Config"
    before = config_hashes(user)
    if not before:
        raise RuntimeError("Initialized user configuration is required; fixture does not create one")
    script = json.loads((ROOT / "build/multiplayer/script/build.json").read_text(encoding="utf-8-sig"))
    native = verify_native(ROOT, script, digest)
    run = ROOT / "build/local-test-runtime" / datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S-%f")
    run.mkdir(parents=True)
    packages = run / "Packages"
    packages.mkdir()
    for name, expected in script["packages_sha256"].items():
        source = ROOT / "build/multiplayer/script" / name
        if digest(source) != expected:
            raise RuntimeError(f"Compiled package changed: {name}")
        shutil.copy2(source, packages / name)
    record = {"schema": "kf2vr/local-test-runtime/1", "input": "synthetic_stock_ready_callback_no_physical_HMD",
              "script_build": script, "native_build": native, "user_config_before": before, "phases": [], "passed": False,
              "fixture_no_voice": args.fixture_no_voice, "voice_coexistence_verified": False}
    output = run / "run.json"

    def save():
        output.write_text(json.dumps(record, indent=2), encoding="utf-8")

    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.CreateMutexW.restype = ctypes.c_void_p
    kernel.CreateMutexW.argtypes = (ctypes.c_void_p, ctypes.c_int, ctypes.c_wchar_p)
    kernel.WaitForSingleObject.argtypes = (ctypes.c_void_p, ctypes.c_uint)
    kernel.ReleaseMutex.argtypes = (ctypes.c_void_p,)
    kernel.CloseHandle.argtypes = (ctypes.c_void_p,)
    mutex = kernel.CreateMutexW(None, False, "Local\\KF2VR_DevelopmentFixture")
    locked = bool(mutex) and kernel.WaitForSingleObject(mutex, 0) in (0, 0x80)
    if not locked:
        if mutex:
            kernel.CloseHandle(mutex)
        raise RuntimeError("Another fixture owns the engine/deployment slot")
    deployment = NativeDeployment(ROOT / "build/multiplayer/native/native/adapter/Release",
        game / "Binaries/Win64", run / "NativeBackup", native, digest)
    owned = None
    try:
        deployment.install()
        friends.ROOT = run
        for enabled in (False, True):
            phase = {"enabled": enabled, "checks": {}, "receipts": []}
            record["phases"].append(phase)
            flags = ["--solo", "--vr", "--mods", "none", "--map", "KF-Outpost", "--prepare-only"]
            if enabled:
                flags.append("--local-test-control")
            launch = friends.parse_options(flags)
            launch.profile_root = run / "Profile"
            launch.cache_root = run / "Cache"
            launch.address, launch.password = "127.0.0.1", "fixture"
            load_preferences(launch)
            launch.workshop_content = []
            role = friends.configure_role(run / ("enabled" if enabled else "off"), "driver", user, game, launch)
            # The stock fixture chooses a perk and Ready through supported menu
            # callbacks. It never grants weapons, enables cheats, or injects input.
            role["args"][0] = role["args"][0].replace("KF2VR.VRDemo", "KF2VR.VRDemo,KF2VR.VRNormalGameReplay")
            if not enabled:
                role["args"][0] = role["args"][0].replace("KF2VR.VRNormalGameReplay", "KF2VR.VRNormalGameReplay,KF2VR.VRLocalTestControl")
            role["args"] = [item for item in role["args"] if item not in ("-kf2vr-stereo", "-kf2vr-threaded-render")]
            role["args"] += ["-kf2vr-hand-replay", "-onethread", "-NOINI", "-unattended", "-nopause", "-FORCELOGFLUSH"]
            role.pop("eye_render_percent", None)
            role["args"] = [item for item in role["args"] if not item.startswith(("-ResX=", "-ResY="))]
            role["args"] += ["-ResX=640", "-ResY=360"]
            configs = Path(role["config_root"])
            path = configs / "KFSystemSettings.ini"
            path.write_text(set_ini(read_ini(path), "SystemSettings", {"ResX": "640", "ResY": "360", "DynamicShadows": "False"}), encoding="utf-16")
            configure_fixture_voice(run, role, args.fixture_no_voice)
            phase["role"] = role
            session = launch.local_test_session if enabled else uuid.uuid4().hex
            phase["session"] = session
            owned = launch_owned_fixture(game / "Binaries/Win64/KFGame.exe", role, os.environ)
            phase["pid"] = owned.pid
            print(f"PHASE enabled={enabled} pid={owned.pid} awaiting normal Solo Ready", flush=True)
            save()
            deadline = time.monotonic() + 120
            while time.monotonic() < deadline:
                if owned.poll() is not None:
                    raise RuntimeError(f"Owned fixture exited during startup: {owned.returncode}")
                if "KF2VR_NORMAL_REPLAY phase=complete passed=True" in log_text(role):
                    break
                time.sleep(0.5)
            else:
                raise RuntimeError("Stock Ready/normal-game startup evidence missing after 120 seconds")
            phase["checks"]["normal_game_ready"] = True
            if not enabled:
                try:
                    control.submit(session, "status", 0)
                except RuntimeError:
                    phase["checks"]["controls_off_request_rejected"] = True
                else:
                    raise RuntimeError("Opt-out unexpectedly accepted an IPC request")
                phase["checks"]["no_channel_created"] = not control.channel_path(session).exists()
                phase["checks"]["no_enabled_marker"] = "KF2VR_LOCAL_TEST enabled=1" not in log_text(role)
            else:
                def send(operation, player=0, argument="-", count=0, action=None, expect_ok=True):
                    time.sleep(0.6)
                    action, receipt = control.submit(session, operation, player, argument, count, action, 45)
                    phase["receipts"].append({"action_id": action, "operation": operation, "result": receipt})
                    print(f"RECEIPT operation={operation} result={receipt.splitlines()[0]}", flush=True)
                    save()
                    if expect_ok and not receipt.startswith("ok\t"):
                        raise RuntimeError(f"{operation} failed: {receipt.splitlines()[0]}")
                    return action, receipt
                _, status = send("status")
                players = [line.split("\t") for line in status.splitlines() if line.startswith("player\t")]
                if len(players) != 1:
                    raise RuntimeError("Exactly one verified local test player is required")
                player = int(players[0][1])
                _, catalog = send("catalog", player)
                weapons = [line.split("\t")[1] for line in catalog.splitlines() if line.startswith("weapon\t")]
                phase["checks"]["catalog_has_all_resolved_profiles"] = "missing=0" in catalog.splitlines()[0] and len(weapons) > 100
                phase["checks"]["pump_shotgun_mapping"] = "KFGameContent.KFWeap_Shotgun_MB500" in weapons
                _, error = send("give-one", player, "KFGameContent.NotAnAllowlistedWeapon", 1, expect_ok=False)
                phase["checks"]["unknown_weapon_rejected"] = error.startswith("error\t")
                grant_id, grant = send("give-all", player)
                duplicate_id, duplicate = send("give-all", player, action=grant_id)
                phase["checks"]["duplicate_id_identical_receipt"] = duplicate_id == grant_id and duplicate == grant
                _, no_op = send("give-all", player)
                phase["checks"]["all_existing_no_refill_no_grants"] = "granted=0" in no_op.splitlines()[0] and "failed=0" in no_op.splitlines()[0]
                _, after = send("status", player)
                inventory = {line.split("\t")[2] for line in after.splitlines() if line.startswith(f"inventory\t{player}\t")}
                phase["checks"]["all_catalog_weapons_in_inventory"] = set(weapons).issubset(inventory)
                phase["checks"]["carry_saturated_without_cheats"] = "carry=255" in after and "cheat_manager=0" in after
                _, spawned = send("spawn-zeds", player, "cyst", 2)
                phase["checks"]["bounded_zeds_spawned"] = "requested=2" in spawned and "granted=2" in spawned and "failed=0" in spawned
                _, disabled = send("disable", player)
                phase["checks"]["disabled"] = "disabled" in disabled and not (control.channel_path(session) / "ready.tsv").exists()
                try:
                    control.submit(session, "give-all", player)
                except RuntimeError:
                    phase["checks"]["disabled_new_action_rejected"] = True
                else:
                    raise RuntimeError("Disabled session accepted a new request")
                phase["audit"] = str(control.channel_path(session) / "audit.tsv")
            if not all(phase["checks"].values()):
                raise RuntimeError("One or more acceptance checks failed")
            owned.terminate()
            owned.wait(timeout=10)
            owned = None
            save()
        record["passed"] = True
    except Exception as error:
        record["error"] = str(error)
        print(f"BLOCKER {error}", flush=True)
    finally:
        if owned is not None and owned.poll() is None:
            owned.terminate()
            owned.wait(timeout=10)
        record["restoration_errors"] = deployment.restore()
        record["user_config_after"] = config_hashes(user)
        record["user_config_preserved"] = before == record["user_config_after"]
        record["passed"] = record["passed"] and record["user_config_preserved"] and not record["restoration_errors"]
        save()
        kernel.ReleaseMutex(mutex)
        kernel.CloseHandle(mutex)
        print(f"GATE_RELEASED processes_stopped=1 receipt={output} passed={record['passed']}", flush=True)
    return 0 if record["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
