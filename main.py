import sys

from PySide6 import QtCore, QtGui, QtWidgets

from clipboard_commander.app import AppController
from clipboard_commander.config import APP_DIR, APP_NAME, INSTANCE_LOCK_PATH
from clipboard_commander.mac import set_app_accessory_policy


def main():
    if sys.platform != "darwin":
        print("ClipboardCommander supports macOS only.")
        sys.exit(1)

    app = QtWidgets.QApplication(sys.argv)
    app.setApplicationName(APP_NAME)
    app.setWindowIcon(QtGui.QIcon.fromTheme("clipboard"))
    app.setQuitOnLastWindowClosed(False)

    # Use native system theme (no forced palette)

    APP_DIR.mkdir(parents=True, exist_ok=True)
    lock = QtCore.QLockFile(str(INSTANCE_LOCK_PATH))
    lock.setStaleLockTime(5000)
    if not lock.tryLock(1):
        QtWidgets.QMessageBox.information(None, APP_NAME, "Приложение уже запущено.")
        return 0

    try:
        set_app_accessory_policy()
    except Exception:
        pass

    controller = AppController(app)
    rc = app.exec()
    del lock
    sys.exit(rc)


if __name__ == "__main__":
    main()
