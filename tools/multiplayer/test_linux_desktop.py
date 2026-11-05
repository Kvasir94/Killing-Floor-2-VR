"""Run the desktop shell launcher against temporary Steam libraries and wrappers."""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile


SCRIPT = Path(__file__).with_name("linux-desktop.sh")
GIT_BASH = Path(os.environ.get("ProgramFiles", "C:/Program Files")) / "Git/bin/bash.exe"
BASH = str(GIT_BASH) if os.name == "nt" and GIT_BASH.is_file() else shutil.which("bash")


def shell_path(path):
    value = Path(path).resolve().as_posix()
    return "/" + value[0].lower() + value[2:] if os.name == "nt" else value


@unittest.skipUnless(BASH, "bash is required for Linux launcher checks")
class LinuxDesktopTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.package = self.root / "release with spaces/app"
        for name, content in (("release.json", "{}"), ("runtime/python.exe", "fixture"),
                              ("tools/multiplayer/friends.py", "fixture"),
                              ("tools/multiplayer/linux-desktop.sh", SCRIPT.read_text())):
            target = self.package / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(content, encoding="utf-8", newline="\n")
        self.environment = dict(os.environ, HOME=shell_path(self.home), STEAM_COMPAT_CLIENT_INSTALL_PATH="")
        # Git Bash on Windows can find the Store python3 alias instead of the
        # interpreter running these tests. Supply the same interpreter explicitly.
        commands = self.root / "commands"
        commands.mkdir()
        python = commands / "python3"
        python.write_text('#!/bin/bash\nexec ' + shlex.quote(sys.executable.replace("\\", "/")) + ' "$@"\n', newline="\n")
        python.chmod(0o755)
        self.environment["PATH"] = str(commands) + os.pathsep + self.environment["PATH"]

    def game(self, library):
        game = library / "steamapps/common/killingfloor2"
        executable = game / "Binaries/Win64/KFGame.exe"
        executable.parent.mkdir(parents=True)
        executable.write_text("fixture")
        return game

    def run_helper(self, *arguments, script=SCRIPT):
        return subprocess.run([BASH, shell_path(script), *arguments], env=self.environment,
                              text=True, capture_output=True, timeout=20)

    def test_setup_discovers_external_library_and_prints_quoted_options(self):
        steam = self.home / ".local/share/Steam"
        (steam / "steamapps").mkdir(parents=True)
        library = self.root / "external library"
        game = self.game(library)
        (steam / "steamapps/libraryfolders.vdf").write_text(
            '"libraryfolders"\n{\n "0"\n {\n "path" "' + shell_path(library) + '"\n }\n}\n')
        result = self.run_helper("--setup", "--package", shell_path(self.package))
        self.assertEqual(result.returncode, 0, result.stderr)
        command = shlex.split(result.stdout.splitlines()[-1])
        self.assertEqual(command, ["bash", shell_path(self.package / "tools/multiplayer/linux-desktop.sh"),
                                   "--package", shell_path(self.package), "--game-root", shell_path(game),
                                   "--launch", "%command%"])
        self.assertFalse((self.package / "logs").exists())

    def test_ambiguous_installations_require_explicit_game_root(self):
        first = self.game(self.home / ".local/share/Steam")
        self.game(self.home / ".steam/steam")
        args = ("--setup", "--package", shell_path(self.package))
        result = self.run_helper(*args)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("set --game-root explicitly", result.stderr)
        result = self.run_helper(*args, "--game-root", shell_path(first))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_setup_extracts_adjacent_full_zip_and_never_overwrites_it(self):
        kit = self.root / "kit"
        kit.mkdir()
        helper = kit / "linux-desktop.sh"
        helper.write_text(SCRIPT.read_text(), newline="\n")
        archive = kit / "matching-full.zip"
        with zipfile.ZipFile(archive, "w") as zipped:
            for path in self.package.rglob("*"):
                if path.is_file():
                    zipped.write(path, "matching/app/" + path.relative_to(self.package).as_posix())
        game = self.game(self.home / ".local/share/Steam")
        args = ("--setup", "--game-root", shell_path(game))
        result = self.run_helper(*args, script=helper)
        self.assertEqual(result.returncode, 0, result.stderr)
        extracted = kit / "matching-full-linux/matching/app"
        self.assertEqual(json.loads((extracted / "release.json").read_text()), {})
        sentinel = extracted / "keep-profile.txt"
        sentinel.write_text("keep")
        result = self.run_helper(*args, script=helper)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("already exists", result.stderr)
        self.assertEqual(sentinel.read_text(), "keep")

    def test_setup_rejects_unsafe_archive_before_extraction(self):
        kit = self.root / "kit"
        kit.mkdir()
        helper = kit / "linux-desktop.sh"
        helper.write_text(SCRIPT.read_text(), newline="\n")
        with zipfile.ZipFile(kit / "unsafe.zip", "w") as zipped:
            zipped.writestr("app/release.json", "{}")
            zipped.writestr("../outside.txt", "escape")
        result = self.run_helper("--setup", script=helper)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unsafe path", result.stderr)
        self.assertFalse((kit / "unsafe-linux").exists())
        self.assertFalse((self.root / "outside.txt").exists())

    def test_join_preserves_proton_wrapper_and_normal_forwards_unchanged(self):
        game = self.game(self.home / ".local/share/Steam")
        trace = self.root / "trace.txt"
        self.environment["TRACE"] = shell_path(trace)
        wrapper = self.root / "proton-wrapper.sh"
        wrapper.write_text('printf "%s\\n" "$@" > "$TRACE"\n', newline="\n")
        original = ["/usr/bin/bash" if os.name == "nt" else BASH, shell_path(wrapper),
                    shell_path(game / "Binaries/Win64/KFGame.exe"), "stock-option"]
        result = self.run_helper("--package", shell_path(self.package), "--join", "KF2VR1:fixture", "--launch", *original)
        self.assertEqual(result.returncode, 0, result.stderr)
        arguments = trace.read_text().splitlines()
        self.assertEqual(arguments[0], shell_path(self.package / "runtime/python.exe"))
        self.assertEqual(arguments[-2:], ["--address", "KF2VR1:fixture"])
        self.assertNotIn("KF2VR1:fixture", (self.package / "logs/linux-desktop.log").read_text())
        result = self.run_helper("--normal", "--launch", *original)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(trace.read_text().splitlines(), original[2:])


if __name__ == "__main__":
    unittest.main()
