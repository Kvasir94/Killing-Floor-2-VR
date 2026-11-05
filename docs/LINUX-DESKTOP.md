# Linux desktop joining

This helper joins a matching KF2-VR host using Steam KF2 through Proton, with a
mouse and keyboard or controller. Linux support is best-effort and awaits local
online acceptance. This workflow supports desktop joining; use Windows for VR.

1. Install KF2 in Steam. In **Properties > Compatibility**, select a Steam Play
   compatibility tool, such as Proton. Start ordinary KF2 once, reach the menu,
   then quit.
2. If you downloaded LinuxKit, extract the kit and run this in its directory:

   ```sh
   bash linux-desktop.sh --setup
   ```

   Setup finds the single adjacent full playable ZIP and extracts it into a new
   `<ZIP-name>-linux` folder. This convenience needs `python3`; you can instead
   extract the full ZIP yourself. Setup refuses to overwrite an existing folder.
   If your host supplied a full playable ZIP directly, extract it and run
   `bash app/tools/multiplayer/linux-desktop.sh --setup` from its top directory.
   Keep the whole `app` directory together.
3. Setup prints the exact Steam Launch Options. In **Properties > General >
   Launch Options**, save your previous text, then paste the printed line. Setup
   does not edit Steam settings. You can also enter the line manually:

   ```text
   bash "/path/KF2VR-release/app/tools/multiplayer/linux-desktop.sh" --game-root "/path/steamapps/common/killingfloor2" --launch %command%
   ```

4. Press Play and paste the host's `KF2VR1:` code into the prompt. Cancel or leave
   it empty to start ordinary KF2. The helper preserves Steam's Proton wrapper
   and starts the packaged desktop launcher, which verifies package integrity
   and the exact Steam executable before starting the game.

Without `--game-root`, the helper searches Steam's usual Linux and Flatpak roots
and their configured libraries. It requires exactly one KF2 installation. If it
finds none or more than one, specify `--game-root "/path/to/killingfloor2"` during
setup or in Launch Options. `--package "/path/release/app"` selects an already
extracted release for setup. Ordinary launching needs no system Python; Proton
runs the release's packaged Python.

Install a desktop dialog tool through your normal Linux setup if neither Zenity
nor KDialog is available. A launch from a terminal can use its terminal prompt.
Keep join codes private: they contain the session password. The helper never
writes the code into Steam's settings.

The launcher uses its existing isolated session configuration and cleanup. Keep
it running until KF2 exits. It saves normal package preferences and session logs;
the helper does not replace your KF2 profile, install native VR files, or modify
Steam's registry or compatibility settings.

To update, extract the host's new full ZIP into a fresh folder and change the
Launch Options path. Every player needs matching compiled packages. To remove
the helper, restore your previous Steam Launch Options. Add `--normal` before
`--launch` to keep the wrapper configured while starting ordinary KF2.

For troubleshooting, inspect `app/logs/linux-desktop.log` and the newest
`app/sessions` directory. Review logs for personal details before sharing them.
Flatpak or other sandboxed Steam installations must be able to access both
explicit paths. A version or package mismatch requires the matching game update
and release; changing the executable or bypassing validation is unnecessary.

The workflow adapts the desktop Proton approach in the
[donor release](https://github.com/optimumbox/Killing-Floor-2-VR/releases/tag/v0.5.0-alpha.20261011).
