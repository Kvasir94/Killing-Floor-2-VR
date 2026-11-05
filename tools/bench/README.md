# VR FPS benchmark (tools/bench)

A fixed-load, in-match VR benchmark that runs unattended in any KF2VR package,
including releases built before the scripted-replay ScriptRunner existed (for
example optimumbox's 10-14 public release). Built for #148.

- `script/KF2VRBench` is a stock-only mutator. It presses the stock Ready
  callback, puts the player at the map's first PlayerStart by name with god
  mode, stops stock wave spawning, keeps a fixed Zed list alive, and quits after
  a warm-up and a measured window. URL options are `BenchZeds` (24),
  `BenchWarmup` (30 s) and `BenchMeasure` (120 s).
- `shell/KF2VRBenchShell` dismisses KF2VR's arrival VR menu page. It depends on
  KF2VR, so it is compiled once per build against that build's `KF2VR.u`.
- `bench_launch.py` runs a package's own `friends.py` with the mutator added to
  the map URL and both script folders added to the session's engine ini.
- `dismiss-ini-prompt.ps1` answers KF2's hidden "Your ini ... is outdated"
  startup boxes with No, which otherwise stall every launch.
- `bench_summary.py` reads a session's `native.log` inside the measured window.

## Rerunning the A/B against a new candidate

Shut down every other KFGame/KFServer first, and have the headset connected in
Virtual Desktop.

```powershell
./tools/bench/build-bench.ps1                                   # stock-only mutator, once
./tools/bench/build-bench.ps1 -ShellFor <candidate>\Packages -OutputRoot build\bench\shell-<name>
./tools/bench/build-bench.ps1 -ShellFor build\optimumbox-v052\KF2VR-Multiplayer-20261014\app\Packages -OutputRoot build\bench\shell-optimumbox
```

Each run (start `dismiss-ini-prompt.ps1` in the background first):

```powershell
<package>\runtime\python.exe tools\bench\bench_launch.py <package> <name> "?BenchWarmup=30?BenchMeasure=120" -- `
  --solo --vr --store steam --map KF-BurningParis --game-length short --vr-quality quality --dlss quality `
  --hbao --reflections --frame-timings --eye-render-percent 100 --duration 420
python tools\bench\bench_summary.py <package>\sessions\<newest session>
```

`<package>` is the package root (`...\app` for optimumbox's release, the
release folder for ours). The launcher saves some switches into
`%LOCALAPPDATA%\KF2VR\Profile`; back it up before a batch and restore it after
each run. Alternate the builds (A, B, A, B) and report warm runs only.

A run counts only with `menu_windows: 0` and the expected `zeds_alive_mean`.
Compare `gpu_stereo_ms_mean` and `game_thread_cpu_ms_per_frame`, not just FPS:
Virtual Desktop holds a missed 120 Hz frame at 60, which hides a gap.

To bisect one default, set before the run: `KF2VRBENCH_DROP` (game arguments to
remove, such as `-kf2vr-single-pass`), `KF2VRBENCH_ADD` (arguments to append) or
`KF2VRBENCH_SYSSET` (`Key=Value,...` in `[SystemSettings]`).
