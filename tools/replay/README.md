# Explicit reload diagnostics

For authored input of any kind (either hand, movement, drops, console commands,
screenshots and probes) write a `.kfs` script instead; see [SCRIPTS.md](SCRIPTS.md).

Use this harness only when replay work or a run has been requested. It uses the
real offline game and native tracking ingress. A headset is optional: it works
without one, or with a headset connected through Virtual Desktop or another
runtime and left unworn. It does not require live OpenXR poses or start, stop,
reconnect or change SteamVR, Virtual Desktop or the headset.

Steam must already be signed in and the installed game must be initialized.
Executable batches check for a live Steam client in the same Windows session
before building or compiling, and again before deployment. This checks process
readiness; the game log determines whether Steam authentication succeeds.
The runner uses disposable configs and the verified, explicitly named candidate;
it preserves the selected package, saved profile and installed native files.
It owns `Local\KFVR_GameTest` and `Local\KF2VR_DevelopmentFixture`, refuses an
existing KFGame/KFServer/KFEditor process, filters physical desktop input and
leaves F10 available to abort. Keep the computer available for the bounded run.

## Automatic batches and subsets

One command can build an unselected candidate, prepare isolated configs, compile
the observer and run several weapon cases sequentially in one game process.
`-CasesPerLaunch` controls grouping (default 8, range 2..16); legacy geometry runs last.
Repeated trials on the same weapon/mode use separate launches so paid payloads
and ammunition from an earlier case cannot contaminate the next baseline.
Each case has its own observer, observed ammo baseline, native input epoch,
identity checks and bounded deadline. For example, cycle four single weapons:

```powershell
./tools/replay/reload.ps1 -Batch -Build -Run -Weapons 9mm,deagle,ar15,thompson -Tests hold -Cases normal -Scope solo
```

Reuse an already built candidate for only the hip/contact and contention tests:

```powershell
./tools/replay/reload.ps1 -Batch -Candidate <absolute-release-directory> -Run -Weapons 9mm -Tests geometry
```

Use `-Plan` to inspect selections without creating files or launching anything.
Omit `-Run` to prepare and compile only. `-Output` names a fresh directory under
`build/`; otherwise the runner creates one. `-FailFast` stops after the first
failed case; startup crashes, F10 aborts and cleanup/preservation failures always
stop further launches. The summary retains the exact fatal message and exit code.

The equivalent Python entry is `python tools/replay/run.py --batch`. Its
`--weapons`, `--tests` and `--cases` accept spaces or comma-separated names and
`all`. `geometry` combines `tactical-hip` and `dual-contention` in one real input
sequence. Select either name individually when needed.

`magazine-hip` selects generic occupied-hand magazine reloads. Choose
`-KeepChamber on/off/both` and `-LoseAmmo on/off/both` to expand option trials;
`-RecoverMags on` is currently required for this path. For example:

```powershell
./tools/replay/reload.ps1 -Batch -Candidate <absolute-release-directory> -Run -Weapons 9mm,deagle -Tests magazine-hip -Cases normal,dual -KeepChamber both -LoseAmmo both
```

`revolver-hip` selects registered cylinder profiles in single/supported paired
modes. With ammo loss On, the production path exports the old paid load and
pays for the full replacement; the ledger must retain those old rounds in
escrow. With loss Off, it retains loaded rounds and pays the deficit. The
bounded replacement verdict requires recovery On; recovery-Off discard
accounting remains unsupported. The chamber setting does not add a chamber to
an action-less cylinder. `hold` and legacy `geometry` require the all-ON
baseline and explicitly skip nondefault option selections.

`-Scope solo`, `network` or `both` separates the real standalone and LAN routes.
`-Tests all` selects the implemented tests in that scope. `replication` reuses
the existing real server/client 1858â†’9mm smoke; both guns must be selected.
`network-reload` reuses the real server/owner/observer physical 9mm sequence.
Those network routes have fixed weapon coverage; other combinations remain
unsupported. They do not require a worn headset or use a live XR session.

Canonical registered class names are accepted as weapon selections, for example
`KFGameContent.KFWeap_AssaultRifle_SCAR`. The runtime production registry admits
the exact class; the actual instance must support the requested contract.
Each suite writes `weapon-catalog.json` from the real registry, with reload-family
and capability data. Pass `-Catalog <that-file> -Weapons all` to plan across that
registry. Without a catalog, `all` expands only the reference aliases. Discovery
is capability data and never counts as execution or a reload pass.

| Test | Executable weapon/mode subsets | Scope |
| --- | --- | --- |
| `hold` | Registered magazine instances admitted by the carry recipe in `normal` | Physical entry and held/disarmed/release checks; no completed insertion claim |
| `magazine-hip` | Registered one-handed magazine profiles in `normal` or supported `dual` | Actual shots, removal/payload/chamber accounting, hip contact, real payment and full retry; chamber/loss option matrix |
| `revolver-hip` | Registered covered revolver profiles in `normal` or supported `dual` | Actual shots, open/contact/close/payment, shared reserve accounting and full retry |
| `tactical-hip` | Paired 9mm in `dual` | Stock-capacity top-up, actual hip seats, payment and true-full retry |
| `dual-contention` | Paired 9mm in `dual` | Same contact sequence, requiring the actual transient backend wait and distinct removal receipts |

Unsupported weapon/test combinations appear as `SKIPPED-UNSUPPORTED` with their
reason, never as passes. Other catalog families still need executable lifecycle
contracts; selecting `all` does not manufacture coverage for them.
The old dual hold tape assumes a stock-capacity gun cannot top up. That conflicts
with the retained-chamber contract, so batches skip it and use the geometry
cases for paired reloads instead.

Read `summary.md` after the batch. It lists every selected case, its result,
observed sample counts, startup diagnosis and links to prepare/compiler/runner,
game/native logs and the receipt. `batch.json` contains the same structured
index. Logs and summaries stay under the batch directory, including failures.
An incomplete/failed runtime returns a nonzero exit code. A bounded success
does not establish general reload, headset or network acceptance.

Solo suites request named engine screenshots automatically at readiness,
transitions, periodic observations and failures. `captures/index.html` and
`index.json` link the original image, a lossless PNG, case/event, game-log line,
event/request game times and file-write UTC. Images during critical geometry
motion are deferred and labelled accordingly. Missing, stale or uniformly blank
images fail the capture requirement. An image request is not proof that a useful
frame was saved, and file-write time is not an exact GPU frame timestamp.
KF2 may save these images under its installed or user screenshot directory;
the collector copies only exact run names within the run's time bounds and
keeps those originals intact.

The watchdog reports the last actual stage, elapsed time, physical reload,
await-ammo/rack and geometry progress. Intentional held-reload checks have their
declared hold duration; a missing completion, lost context, stuck setup or global
process deadline cannot silently pass. Failures leave logs and images and shut
down only the runner's owned processes before restoration.

## Paired 9mm geometry input

`--geometry-input` supports `hip-tactical-at-capacity` and
`dual-removal-backend-busy`, with `--case dual --weapon 9mm`. Both use the same
finite sequence: two actual 15-round paired members, simultaneous reload input,
distinct removal receipts, smooth movement of each magazine bone into its real
hip loader, paid 16-round completion, then a full-capacity reload rejection.
Lose-ammo is ON; both exported 14-round payloads remain in the real ledger.
The diagnostic supplies world wrist goals through the existing native reload
input ingress. It never writes ammo, payment results, guide progress or reload
state. Passive hooks witness transient admission waits and real seat contacts.

Build the current DLSS candidate without selecting it:

```powershell
./tools/build-kf2vr.ps1 -NoSelect -Parallel 2
```

Use that build's absolute release directory and a fresh run directory:

```powershell
python tools/replay/ammo_prepare.py --candidate <absolute-release-directory> --case dual --weapon 9mm --lifecycle-case dual-removal-backend-busy --geometry-input --no-voice --output <absolute-fresh-run-directory>
./tools/replay/build-observer.ps1 -ProductionScriptRoot <run-directory>/Packages -OutputRoot <run-directory>/Observer
python tools/replay/run.py --record <run-directory>/run.json --source-root . --input tools/replay/geometry-neutral.input --reload-case dual --timeout 300 --startup-timeout 240
```

Compile sequentially under the shared compiler/SDK lease. Preparation and observer
compilation do not launch gameplay. The native geometry switch is restricted to
offline input replay with one thread; it rejects stereo and network launches.
The neutral tape is only the boot/readiness carrier. Running it alone performs
no reload.

The run receipt includes startup diagnosis, physical-input isolation, real
callback order and a bounded geometry outcome. Missing callbacks, contacts,
ledger samples, isolation or zero samples cannot pass. `OBSERVED-BOUNDED` only
describes that finite authored sequence; full reload, headset and multiplayer
acceptance stay false. The generic lifecycle trace remains observation-only.

Lose-ammo OFF, reversed completion order, cancellation, mixed Deagle/9mm setup,
late recovered-insert cancellation and paid finishing-action swaps remain separate
coverage gaps. Their scenario plans do not become executable reproductions merely
because the paired geometry case succeeds. Network and headset feel require
their own acceptance checks.
