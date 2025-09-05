import sys
from typing import Optional

from PySide6 import QtCore, QtGui, QtWidgets

from .config import APP_NAME, INSTANCE_LOCK_PATH
from .history import HistoryStore
from .watcher import ClipboardWatcher
from .ui import PickerDialog

if sys.platform == "darwin":
    from .mac import window_join_all_spaces_and_raise


class TrayApp(QtWidgets.QSystemTrayIcon):
    def __init__(self, icon: QtGui.QIcon, parent=None):
        super().__init__(icon, parent)
        menu = QtWidgets.QMenu()
        self.action_open = menu.addAction("Открыть историю (⌘⇧V)")
        self.action_clear = menu.addAction("Очистить историю")
        menu.addSeparator()
        self.action_quit = menu.addAction("Выход")
        self.setContextMenu(menu)


def _make_fallback_tray_icon() -> QtGui.QIcon:
    size = 22
    pm = QtGui.QPixmap(size, size)
    pm.fill(QtCore.Qt.GlobalColor.transparent)
    p = QtGui.QPainter(pm)
    p.setRenderHint(QtGui.QPainter.Antialiasing)
    rect = QtCore.QRectF(1.0, 1.0, size - 2.0, size - 2.0)
    p.setPen(QtGui.QPen(QtGui.QColor(80, 80, 80), 1.2))
    p.setBrush(QtGui.QBrush(QtGui.QColor(240, 240, 240)))
    p.drawRoundedRect(rect, 4, 4)
    f = QtGui.QFont()
    f.setPointSizeF(9.5)
    f.setBold(True)
    p.setFont(f)
    p.setPen(QtGui.QPen(QtGui.QColor(40, 40, 40)))
    p.drawText(pm.rect(), QtCore.Qt.AlignmentFlag.AlignCenter, "⌘V")
    p.end()
    return QtGui.QIcon(pm)


class AppController(QtCore.QObject):
    show_picker = QtCore.Signal()

    def __init__(self, app: QtWidgets.QApplication):
        super().__init__()
        self.app = app
        self.store = HistoryStore()
        self.clipwatch = ClipboardWatcher(app, self.store)
        icon = QtGui.QIcon.fromTheme("edit-paste")
        if not icon or icon.isNull():
            icon = app.windowIcon()
        if not icon or icon.isNull():
            icon = _make_fallback_tray_icon()
        self.tray = TrayApp(icon)
        self.tray.setToolTip(APP_NAME)
        self.tray.show()

        self.tray.action_open.triggered.connect(self._on_hotkey)
        self.tray.action_clear.triggered.connect(self.store.clear)
        self.tray.action_quit.triggered.connect(self._quit)

        self.show_picker.connect(self._on_hotkey)

        self._last_front_app_name = None
        self._picker: Optional[PickerDialog] = None

        # Always use pynput-based hotkey listener (stable, no keyboard freeze)
        self._listener = None
        try:
            from pynput import keyboard
            self._pressed_keys = set()
            self._listener = keyboard.Listener(
                on_press=self._on_key_press,
                on_release=self._on_key_release,
                suppress=False,
            )
            self._listener.start()
        except Exception:
            self._listener = None

    def _emit_hotkey(self):
        QtCore.QMetaObject.invokeMethod(self, "_on_hotkey", QtCore.Qt.QueuedConnection)

    # Fallback hotkey detection using pynput
    def _on_key_press(self, key):
        try:
            from pynput import keyboard
            self._pressed_keys.add(key)
            is_v = False
            if isinstance(key, keyboard.KeyCode):
                ch = (key.char or "").lower()
                if ch == 'v':
                    is_v = True
                elif getattr(key, 'vk', None) in (9, 0x09):
                    is_v = True
            cmd_down = any(k in self._pressed_keys for k in (keyboard.Key.cmd, getattr(keyboard.Key, 'cmd_l', None), getattr(keyboard.Key, 'cmd_r', None)))
            shift_down = any(k in self._pressed_keys for k in (keyboard.Key.shift, getattr(keyboard.Key, 'shift_l', None), getattr(keyboard.Key, 'shift_r', None)))
            if is_v and cmd_down and shift_down:
                self._emit_hotkey()
        except Exception:
            pass

    def _on_key_release(self, key):
        try:
            if key in getattr(self, '_pressed_keys', set()):
                self._pressed_keys.remove(key)
        except Exception:
            self._pressed_keys = set()

    @QtCore.Slot()
    def _on_hotkey(self):
        if self._picker is None:
            self._picker = PickerDialog(self.store)
            self._picker.pasted.connect(self._paste_into_previous)
            self._picker.setAttribute(QtCore.Qt.WidgetAttribute.WA_DeleteOnClose, False)

        if self._picker.isVisible():
            self._picker.hide()
            return

        # Position near mouse cursor but keep within screen bounds
        pos = QtGui.QCursor.pos()
        screen = QtGui.QGuiApplication.screenAt(pos) or QtGui.QGuiApplication.primaryScreen()
        avail = screen.availableGeometry() if screen else QtGui.QGuiApplication.primaryScreen().availableGeometry()
        geom = self._picker.frameGeometry()
        geom.moveCenter(pos)
        x = max(avail.left(), min(geom.left(), avail.right() - geom.width()))
        y = max(avail.top(), min(geom.top(), avail.bottom() - geom.height()))
        self._picker.move(x, y)

        if not self._picker.isVisible():
            self._picker.show()
        QtCore.QTimer.singleShot(1, lambda: window_join_all_spaces_and_raise(self._picker) if sys.platform == "darwin" else self._picker.raise_())

    @QtCore.Slot()
    def _paste_into_previous(self):
        from .mac import send_cmd_v
        QtCore.QTimer.singleShot(80, send_cmd_v)

    def _quit(self):
        try:
            if self._listener:
                self._listener.stop()
        except Exception:
            pass
        QtWidgets.QApplication.quit()
