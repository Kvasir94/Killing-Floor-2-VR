"""OptimumBox's Steam Play chooser, using the unified manifest and launcher."""
import ctypes
import os
from pathlib import Path
import subprocess
import sys

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "app/tools/multiplayer"))
from workshop_distribution import copy_lease, local_lock, mirror

LOCAL = Path(os.environ.get("LOCALAPPDATA", str(Path.home()))) / "KF2VR/Workshop/KF2VR"


def main():
    from PySide6.QtWidgets import QApplication, QWidget
    import launcher_ui_theme as T
    from launcher_ui_widgets import Button, label, vbox
    application = QApplication(sys.argv[:1])
    T.apply(application)
    window = QWidget()
    window.setWindowTitle("Killing Floor 2")
    status = label("", "help", wrap=True)

    def normal():
        if not sys.argv[1:]:
            status.setText("Start this choice from Steam to play normally.")
            return
        subprocess.Popen(sys.argv[1:], cwd=str(Path(sys.argv[1]).parent))
        window.close()

    def mod():
        try:
            # Keep the copy locked through the launcher's session cleanup.
            with local_lock(LOCAL.parent / "launcher.lock"):
                status.setText("Updating the local KF2-VR copy...")
                application.processEvents()
                with copy_lease():
                    app = mirror(HERE.parent, LOCAL)
                ctypes.windll.user32.AllowSetForegroundWindow(-1)
                window.hide()
                subprocess.run([str(app / "runtime/pythonw.exe"), str(app / "tools/multiplayer/launcher_gui.py")],
                               cwd=app, check=True)
            window.close()
        except Exception as error:
            window.show()
            status.setText(str(error))

    window.setLayout(vbox(label("How do you want to play?", "h2"), T.S2,
                          Button("Play in VR (KF2-VR)", mod, kind="primary", size="lg"),
                          Button("Play normally", normal, size="lg"), status,
                          spacing=T.S3, margins=(T.S8, T.S6, T.S8, T.S6)))
    window.setFixedWidth(420)
    window.show()
    application.exec()


if __name__ == "__main__":
    main()
