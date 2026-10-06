# Contributor workflow

These instructions apply to automated contributors as well as human changes.

- Check Git status before editing and preserve unrelated work. Keep each change
  focused, commit it with the reason and relevant checks, and push only when asked.
- Read the relevant source in `native/`, `script/` and `tools/`. Generated `build/`
  output, game extracts, user profiles, logs and caches stay out of Git.
- Solo and multiplayer share gameplay defaults and launch setup; keep transport
  differences limited to what each mode needs.
- Changes to launcher switches/defaults also update `PLAY-MULTIPLAYER.md` and the
  affected launcher/package tests.
- Build affected artifacts and run native CTest plus launcher/package checks.
  Use the source setup in [BUILDING](docs/BUILDING.md). Run builds sequentially;
  the build tools share a mutex. Close game/editor/server processes first.
- Headset play and real online sessions establish gameplay acceptance. Run game
  automation only when explicitly requested; do not infer acceptance from compilation.
- Add tests for native math/state, file/log parsers, or launch/package/config/profile
  behavior. Do not assert that source text contains a particular call or constant,
  or duplicate production math in a second implementation.
- Keep player/contributor documentation current. Describe changes and checks in
  commit messages; documentation is not a session log or verification ledger.
