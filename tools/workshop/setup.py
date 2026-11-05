"""Configure the Workshop Play chooser for one selected Steam account."""
from pathlib import Path
import subprocess
import sys

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "KF2VR/app/tools/multiplayer"))
from workshop_distribution import configure_account


def main():
    import winreg
    from PySide6.QtWidgets import QApplication
    import launcher_ui_theme as T
    from launcher_ui_widgets import Dialog, Dropdown, alert, ask
    application = QApplication(sys.argv[:1])
    T.apply(application)
    title = "KF2-VR setup"
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Valve\Steam") as key:
            steam = Path(winreg.QueryValueEx(key, "SteamPath")[0])
        configs = sorted((steam / "userdata").glob("*/config/localconfig.vdf"))
        if not configs:
            raise ValueError("Start Steam and sign in once, then run setup again.")
        if not (HERE / "Play.cmd").is_file() or not (HERE / "KF2VR/app/release.json").is_file():
            raise ValueError("Steam has not finished downloading KF2VR. Press Play on KF2 once, quit at the menu, wait for the download, then retry setup.")
        if len(configs) == 1:
            config = configs[0]
        else:
            dialog = Dialog(None, title, "Choose the Steam account to change.",
                            (("Cancel", None, "ghost"), ("Continue", True, "primary")))
            accounts = Dropdown([(index, f"Steam account {path.parent.parent.name}") for index, path in enumerate(configs)], 0)
            dialog.extra.addWidget(accounts)
            if not dialog.run():
                return
            config = configs[accounts.value()]
        state = config.with_name(config.name + ".kf2vr-launch.json")
        remove = state.exists()
        action = "Restore this account's previous KF2 Launch Options?" if remove else "Add the KF2-VR Play choice for this account? Previous Launch Options will be saved for removal."
        if not ask(None, title, action, yes="Continue", detail="Exit Steam normally before continuing."):
            return
        running = subprocess.check_output(["tasklist", "/FI", "IMAGENAME eq steam.exe", "/FO", "CSV", "/NH"],
                                          creationflags=0x08000000, text=True)
        if '"steam.exe"' in running.lower():
            raise ValueError("Steam is still running. Choose Steam > Exit and run setup again.")
        configure_account(config, HERE / "Play.cmd", remove=remove)
        alert(None, title, "Done. Open Steam normally. " + ("Your previous Launch Options are restored." if remove else "Press Play on KF2 for the VR/normal choice. Run this setup again to undo."), kind="info")
    except Exception as error:
        alert(None, title, str(error))


if __name__ == "__main__":
    main()
