# Repository workflow

These rules apply to every coding agent in this repository (Codex, Claude, Gemini and others). This file is the single source: CLAUDE.md and GEMINI.md only import it, so change rules here.

- Prefer main; branch/worktree only as needed. Check git status before edits and preserve unrelated work.
- Commit as you work, without being asked, so any one change can be unwound while several agents share this tree. Commit each coherent step once it compiles or its relevant check passes, and checkpoint before starting a risky or broad change. One logical change per commit, with a message stating what changed, why, and what was checked. Stage only your own files and hunks: other agents' edits, including anything they already staged, stay out (use pathspecs or partial staging). Never amend, rebase, reset or force over commits you did not just make; undo with `git revert`. Generated `build/` output stays out of Git. Push only when asked.
- Read only what the task needs. Start source searches in native/, script/ and tools/; use docs/DOCUMENTATION_INDEX.md when a reference would help. `.rgignore` excludes historical material from default ripgrep searches; use `rg --no-ignore <pattern> history` deliberately for history. Git searches need explicit path scope.
- Use Play-KF2VR.cmd and build/multiplayer/current-release.json. Preserve client/server files, assets, workshop cache, archives and history.
- Solo and multiplayer share the playable feature contract, defaults and launch setup, with mode-specific transport only where necessary.
- When changing public launch behavior in Play-KF2VR.cmd, tools/play-main.ps1 or packaged friends.py, update PLAY-MULTIPLAYER.md switches/defaults/constraints/examples and affected launcher tests.

## Iteration loop

The loop is: headset playtest -> short bug list -> fix -> `tools/build-kf2vr.ps1` -> headset. The headset and real online play are the acceptance test. Automated checks exist only to keep that loop fast and the launcher working.

- Build the affected artifacts; `tools/build-kf2vr.ps1` builds, runs the fast CPU gate (native CTest and launcher/package tests) and selects the package. A clean compile plus that gate is sufficient evidence for a commit. Documentation-only edits need no build.
- Builds run sequentially under the shared mutex, hidden. Visible windows are for sessions the user asked for.
- Routine runtime automation is the 1858/9mm network smoke only (`tools/test-online-play.ps1`); prepare it, and run it only when asked. No other runtime automation runs unless the user asks.

## Tests: what is allowed

Add or keep an automated test only when it covers one of:

1. Pure math or state logic in native code, as a CTest in native/adapter/tests (head aim, stereo views, menus, atlas, gamepad and similar).
2. A parser or analyzer in tools/ that turns logs or files into numbers.
3. The launch, package, config and profile path (tools/multiplayer/test_*.py, play-main and vr-user-profile tests): if that breaks, nobody can playtest.

Do not:

- Assert on source text: no reading `.uc`, `.cpp` or `.ps1` files to check that a line, call, order or constant exists. The compiler checks wiring; the headset checks behavior.
- Re-implement production math in Python to compare with itself.
- Turn a playtest report into a test. Fix it, build, and hand it back for a headset retest. Add a regression test only if the bug lived in one of the three categories above.
- Rewrite a test that broke only because it mirrored the implementation. Delete it.

## Replays, fixtures and evidence: off unless the user asks

The solo replay system (scripted synthetic-input runs, desktop capture modes, probes, test commandlets and their log/receipt parsers) was retired on 2026-09-27 and archived in history/replay-tooling-2026-09-27/. Do not build new replays, fixtures, probes, capture modes, synthetic-input scenarios, test commandlets, receipt/evidence verifiers or benchmark sweeps, and do not restore the archived ones, unless the user explicitly asks for that in the current conversation. Adding a weapon or feature does not imply adding a replay for it.

## Documents

- The commit message is the record of what changed and what was checked. Do not write verification, evidence, receipt or run narratives into docs, and do not create dated per-session docs.
- Update a doc only when player-facing behavior, launch switches or open work change. docs/OPEN_WORK.md owns unfinished work. docs/ai/HANDOFF.md is one short current snapshot, replaced rather than appended.
