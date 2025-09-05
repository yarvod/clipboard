from pathlib import Path
from typing import Optional

from PySide6 import QtCore, QtGui, QtWidgets

from .config import APP_DIR, INTERNAL_MIME
from .history import HistoryStore


class ClipboardWatcher(QtCore.QObject):
    """Monitors the system clipboard for text and image changes."""

    def __init__(self, app: QtWidgets.QApplication, store: HistoryStore):
        super().__init__()
        self.app = app
        self.store = store
        self.clip = app.clipboard()
        self.clip.dataChanged.connect(self._on_changed)
        self.store.cleared.connect(self._sync_last_from_clipboard)

        self._last_text = self.clip.text() or ""
        self._last_img_sig = ''
        self._suppress_until_ms = 0

        self._timer = QtCore.QTimer(self)
        self._timer.setInterval(400)
        self._timer.timeout.connect(self._poll)
        self._timer.start()

    @QtCore.Slot()
    def _on_changed(self):
        if self._is_suppressed():
            self._sync_last_from_clipboard()
            return
        md = self.clip.mimeData()
        if not md:
            return
        # Ignore our own programmatic copies
        try:
            if md.hasFormat(INTERNAL_MIME):
                return
        except Exception:
            pass
        if md.hasText():
            txt = md.text()
            if txt and txt != self._last_text:
                self._last_text = txt
                self.store.add_text(txt)
        elif md.hasImage() or self.clip.image() is not None or self.clip.pixmap() is not None:
            self._capture_image()

    def _poll(self):
        if self._is_suppressed():
            return
        md = self.clip.mimeData()
        if md and md.hasFormat(INTERNAL_MIME):
            return
        try:
            txt = self.clip.text() or ""
        except Exception:
            txt = ""
        if txt and txt != self._last_text:
            self._last_text = txt
            self.store.add_text(txt)
        self._poll_image()

    def _poll_image(self):
        md = self.clip.mimeData()
        if md and md.hasFormat(INTERNAL_MIME):
            return
        try:
            img = self.clip.image()
        except Exception:
            img = None
        if img and not img.isNull():
            sig = self._image_signature(img)
            if sig and sig != self._last_img_sig:
                self._capture_image(img, sig)

    def _capture_image(self, qimage: Optional[QtGui.QImage] = None, sig: Optional[str] = None):
        try:
            if qimage is None:
                qimage = self.clip.image()
            if (qimage is None or qimage.isNull()) and self.clip.pixmap() is not None:
                qimage = self.clip.pixmap().toImage()
            if qimage is None or qimage.isNull():
                return
            if not sig:
                sig = self._image_signature(qimage)
            if sig and sig == self._last_img_sig:
                return
            # Set last signature early to avoid race duplicates
            self._last_img_sig = sig or ''
            img_dir = APP_DIR / 'images'
            img_dir.mkdir(parents=True, exist_ok=True)
            uuid = QtCore.QUuid.createUuid().toString().strip('{}')
            path = img_dir / f"{uuid}.png"
            qimage.save(str(path), "PNG")
            self.store.add_image_path(str(path))
        except Exception:
            pass

    def _image_signature(self, qimage: QtGui.QImage) -> str:
        # Hash PNG-encoded bytes + size for robust cross-format deduplication
        try:
            from hashlib import md5
            ba = QtCore.QByteArray()
            buf = QtCore.QBuffer(ba)
            buf.open(QtCore.QIODevice.OpenModeFlag.WriteOnly)
            qimage.save(buf, "PNG")
            h = md5(bytes(ba)).hexdigest()
            return f"{qimage.width()}x{qimage.height()}-{h}"
        except Exception:
            return f"{qimage.width()}x{qimage.height()}-{qimage.cacheKey()}"

    @QtCore.Slot()
    def _sync_last_from_clipboard(self):
        # On clear, remember current clipboard so it won't be re-added immediately
        try:
            self._last_text = self.clip.text() or ""
        except Exception:
            self._last_text = ''
        try:
            img = self.clip.image()
            self._last_img_sig = self._image_signature(img) if img and not img.isNull() else ''
        except Exception:
            self._last_img_sig = ''
        # Also suppress additions briefly to avoid races
        self._suppress_until_ms = QtCore.QTime.currentTime().msecsSinceStartOfDay() + 1200

    def _is_suppressed(self) -> bool:
        return QtCore.QTime.currentTime().msecsSinceStartOfDay() < self._suppress_until_ms
