import sys
from pathlib import Path

from PySide6 import QtCore, QtGui, QtWidgets

from .history import HistoryStore, ClipItem
from .config import INTERNAL_MIME


# ---------- Утилиты UI ----------

class ClickableLabel(QtWidgets.QLabel):
    clicked = QtCore.Signal()

    def mousePressEvent(self, ev: QtGui.QMouseEvent) -> None:
        if ev.button() == QtCore.Qt.MouseButton.LeftButton:
            self.clicked.emit()
            ev.accept()
            return
        super().mousePressEvent(ev)


# (reverted) Removed model/delegate in favor of QWidget rows


class SmoothListWidget(QtWidgets.QListWidget):
    """
    Пиксельная прокрутка:
    - Тачпад/трекпад: Qt присылает pixelDelta → отдаем базовой реализации (инерция «нативная»).
    - Колесо мыши: angleDelta → конвертируем в фиксированный пиксельный шаг, независимый от высоты элементов.
    """
    def __init__(self, parent=None, notch_pixels: int = 40):
        super().__init__(parent)
        self._notch_px = notch_pixels
        self.setVerticalScrollMode(QtWidgets.QAbstractItemView.ScrollPerPixel)
        # Чуть более «живой» шаг для клавиш и программной прокрутки:
        self.verticalScrollBar().setSingleStep(16)
        self.verticalScrollBar().setPageStep(240)

    def wheelEvent(self, event: QtGui.QWheelEvent) -> None:
        pd = event.pixelDelta()
        if not pd.isNull():
            # Трекпад — пусть обрабатывается Qt (инерция/сглаживание нативные).
            return super().wheelEvent(event)

        ad = event.angleDelta()
        dy = ad.y()
        if dy == 0:
            return super().wheelEvent(event)

        sb = self.verticalScrollBar()
        # 120 — один «щелчок» колеса, масштабируем в пиксели:
        delta_px = int(self._notch_px * (dy / 120.0))
        sb.setValue(sb.value() - delta_px)
        event.accept()


# ---------- Сам диалог ----------

class PickerDialog(QtWidgets.QDialog):
    pasted = QtCore.Signal()

    def __init__(self, store: HistoryStore):
        super().__init__(None)
        self.setWindowTitle("Clipboard Commander")
        self.setWindowFlag(QtCore.Qt.WindowStaysOnTopHint, True)
        self.setWindowFlag(QtCore.Qt.WindowType.Tool, True)
        if sys.platform == "darwin":
            self.setAttribute(QtCore.Qt.WidgetAttribute.WA_MacAlwaysShowToolWindow, True)
        self.resize(640, 560)

        # Гладкий фон + лайтовые стили
        self.setAttribute(QtCore.Qt.WidgetAttribute.WA_TranslucentBackground, True)
        self.setStyleSheet(
            """
            QDialog { background: palette(window); border-radius: 14px; }
            QListWidget { background: transparent; border: none; }
            QListView { outline: 0; }
            QListView::item { margin: 0px; padding: 0px; background: transparent; }
            QListView::item:selected { background: transparent; }
            QListView::item:focus { outline: none; }
            QLineEdit { background: #ffffff; border: 1px solid #d1d5db; color: #111827; padding: 8px 12px; border-radius: 12px; }
            QLineEdit::placeholder { color: #9ca3af; }
            QPushButton { background: #ffffff; border: 1px solid #e5e7eb; color: #111827; padding: 6px 10px; border-radius: 10px; }
            QPushButton:hover { background: #f3f4f6; }
            QPushButton:pressed { background: #e5e7eb; }
            """
        )

        self.store = store

        self.search = QtWidgets.QLineEdit(self)
        self.search.setPlaceholderText("Поиск…")

        # Вернули QListWidget + row widgets
        self.list = SmoothListWidget(self, notch_pixels=40)
        self.list.setSelectionMode(QtWidgets.QAbstractItemView.SelectionMode.SingleSelection)
        # spacing=0, а ровные внешние отступы обеспечим на уровне строки-обёртки
        self.list.setSpacing(0)
        self.list.setViewportMargins(12, 0, 12, 0)
        self.list.setUniformItemSizes(False)
        self.list.itemActivated.connect(self._activate_current)
        self.search.textChanged.connect(self._refill)

        btn_clear = QtWidgets.QPushButton("Очистить историю")
        btn_clear.clicked.connect(self._clear)

        layout = QtWidgets.QVBoxLayout(self)
        layout.addWidget(self.search)
        layout.addWidget(self.list, 1)
        layout.addWidget(btn_clear)

        self.store.changed.connect(self._refill)
        self._refill()

    # ---------- Жизненный цикл ----------

    def showEvent(self, e: QtGui.QShowEvent) -> None:
        super().showEvent(e)
        if sys.platform == "darwin":
            try:
                from .mac import window_join_all_spaces_and_raise
                window_join_all_spaces_and_raise(self)
            except Exception:
                pass
        self.search.setFocus(QtCore.Qt.FocusReason.ActiveWindowFocusReason)
        if self.list.count() > 0:
            self.list.setCurrentRow(0)

    def keyPressEvent(self, event: QtGui.QKeyEvent) -> None:
        if event.key() in (QtCore.Qt.Key_Return, QtCore.Qt.Key_Enter):
            self._activate_current()
            return
        if event.key() == QtCore.Qt.Key_Escape:
            self.hide()
            return
        super().keyPressEvent(event)

    # ---------- Действия ----------

    def _clear(self):
        if QtWidgets.QMessageBox.question(self, "Подтверждение", "Очистить всю историю?") == QtWidgets.QMessageBox.Yes:
            self.store.clear()
            self._refill()

    def _refill(self):
        self.list.clear()
        q = self.search.text().strip().lower()
        for it in self.store.items:
            hay = (it.text or ("image " + Path(it.img).name if it.img else "image")).lower()
            if q and q not in hay:
                continue
            row_widget = self._make_row_widget(it)
            item = QtWidgets.QListWidgetItem()
            item.setSizeHint(row_widget.sizeHint())
            self.list.addItem(item)
            self.list.setItemWidget(item, row_widget)
        if self.list.count() > 0 and self.list.currentRow() < 0:
            self.list.setCurrentRow(0)

    # ---------- Карточка и строка ----------

    def _make_row_widget(self, it: ClipItem) -> QtWidgets.QWidget:
        """
        Ровный визуальный «gap» обеспечивается здесь — НЕ через QListWidget.spacing.
        """
        card = self._make_card_widget(it)

        row = QtWidgets.QWidget()
        v = QtWidgets.QVBoxLayout(row)
        # ЕДИНЫЕ внешние отступы «строки» — именно они формируют зазор между элементами
        v.setContentsMargins(0, 6, 0, 6)  # top/bottom = 6px; горизонтальные отступы делает viewportMargins
        v.setSpacing(0)
        v.addWidget(card)

        return row

    def _make_card_widget(self, it: ClipItem) -> QtWidgets.QWidget:
        class CardFrame(QtWidgets.QFrame):
            def __init__(self, parent: QtWidgets.QWidget = None):
                super().__init__(parent)
                self.setAttribute(QtCore.Qt.WidgetAttribute.WA_Hover, True)
                self._hover_factor = 0.0
                self._anim = QtCore.QVariantAnimation(self)
                self._anim.setStartValue(0.0)
                self._anim.setEndValue(1.0)
                self._anim.setDuration(160)
                self._anim.valueChanged.connect(self._on_anim)
                self.setCursor(QtCore.Qt.CursorShape.PointingHandCursor)
                self.setStyleSheet("QFrame{border:none; border-radius:12px; background:#ffffff;}")

            def _on_anim(self, v):
                try:
                    self._hover_factor = float(v)
                    self.update()
                except Exception:
                    pass

            def enterEvent(self, e):
                self._anim.stop()
                self._anim.setDirection(QtCore.QAbstractAnimation.Forward)
                self._anim.start()
                return super().enterEvent(e)

            def leaveEvent(self, e):
                self._anim.stop()
                self._anim.setDirection(QtCore.QAbstractAnimation.Backward)
                self._anim.start()
                return super().leaveEvent(e)

            def paintEvent(self, e: QtGui.QPaintEvent) -> None:
                super().paintEvent(e)
                p = QtGui.QPainter(self)
                p.setRenderHint(QtGui.QPainter.Antialiasing, True)
                r = QtCore.QRectF(self.rect()).adjusted(0.5, 0.5, -0.5, -0.5)
                radius = 12.0
                t = float(getattr(self, "_hover_factor", 0.0))
                base_col = QtGui.QColor(17, 24, 39, int(0.10 * 255))
                blue_col = QtGui.QColor(37, 99, 235)
                def lerp(a, b, f):
                    return int(a + (b - a) * f)
                col = QtGui.QColor(
                    lerp(base_col.red(), blue_col.red(), t),
                    lerp(base_col.green(), blue_col.green(), t),
                    lerp(base_col.blue(), blue_col.blue(), t),
                    lerp(base_col.alpha(), 255, t),
                )
                pen = QtGui.QPen(col)
                pen.setWidthF(1.5)
                p.setPen(pen)
                p.setBrush(QtCore.Qt.BrushStyle.NoBrush)
                path = QtGui.QPainterPath(); path.addRoundedRect(r, radius, radius)
                p.drawPath(path)
                if t > 0.0:
                    alpha = int(26 * t)
                    band_outer = r.adjusted(1.0, 1.0, -1.0, -1.0)
                    band_inner = r.adjusted(3.0, 3.0, -3.0, -3.0)
                    p_outer = QtGui.QPainterPath(); p_outer.addRoundedRect(band_outer, radius-1, radius-1)
                    p_inner = QtGui.QPainterPath(); p_inner.addRoundedRect(band_inner, radius-3, radius-3)
                    ring = p_outer.subtracted(p_inner)
                    p.fillPath(ring, QtGui.QColor(37, 99, 235, alpha))

        w = CardFrame()
        w.setFrameShape(QtWidgets.QFrame.NoFrame)
        w.setMinimumHeight(96)  # минимальная высота карточки для стабильного вида

        lay = QtWidgets.QVBoxLayout(w)
        lay.setContentsMargins(14, 12, 14, 12)
        lay.setSpacing(10)

        # Заголовок: иконка + «чип» времени
        header = QtWidgets.QHBoxLayout()
        header.setContentsMargins(0, 0, 0, 0)
        header.setSpacing(8)

        icon_lbl = QtWidgets.QLabel("📝" if it.kind == 'text' else "🖼️")
        icon_lbl.setAlignment(QtCore.Qt.AlignmentFlag.AlignCenter)
        icon_lbl.setFixedSize(22, 22)
        icon_lbl.setStyleSheet("QLabel{font-size:16px; border:none; background: transparent; color:#111827;}")
        header.addWidget(icon_lbl)
        header.addStretch(1)

        time_lbl = QtWidgets.QLabel(self._time_chip_text(it))
        time_lbl.setFixedHeight(22)
        time_lbl.setStyleSheet(
            "QLabel{color:#374151; font-size:11px; padding:2px 8px; border:1px solid #e5e7eb; border-radius:9px; background: #f3f4f6;}"
        )
        header.addWidget(time_lbl)
        lay.addLayout(header)

        # Превью картинки
        def _rounded_pixmap(src: QtGui.QPixmap, w_: int, h_: int, radius: int = 10) -> QtGui.QPixmap:
            if src.isNull():
                return src
            scaled = src.scaled(w_, h_, QtCore.Qt.AspectRatioMode.KeepAspectRatio,
                                QtCore.Qt.TransformationMode.SmoothTransformation)
            pm = QtGui.QPixmap(scaled.size())
            pm.fill(QtCore.Qt.GlobalColor.transparent)
            p = QtGui.QPainter(pm)
            p.setRenderHint(QtGui.QPainter.Antialiasing, True)
            path = QtGui.QPainterPath()
            path.addRoundedRect(QtCore.QRectF(0, 0, scaled.width(), scaled.height()), radius, radius)
            p.setClipPath(path)
            p.drawPixmap(0, 0, scaled)
            p.end()
            return pm

        if it.kind == 'image' and it.img and Path(it.img).exists():
            lbl_img = ClickableLabel()
            lbl_img.setAlignment(QtCore.Qt.AlignmentFlag.AlignLeft | QtCore.Qt.AlignmentFlag.AlignVCenter)
            lbl_img.setStyleSheet("QLabel{background: transparent; border:none;}")
            pm = QtGui.QPixmap(it.img)
            maxw, maxh = 360, 160
            if not pm.isNull():
                thumb = _rounded_pixmap(pm, maxw, maxh, 8)
                lbl_img.setPixmap(thumb)
                lbl_img.setMaximumHeight(thumb.height() + 2)
                lbl_img.setSizePolicy(QtWidgets.QSizePolicy.Preferred, QtWidgets.QSizePolicy.Fixed)
                lbl_img.setCursor(QtCore.Qt.CursorShape.PointingHandCursor)
                lay.addWidget(lbl_img)

                def _copy_image():
                    md = QtCore.QMimeData()
                    md.setImageData(pm.toImage())
                    try:
                        md.setData(INTERNAL_MIME, b"1")
                    except Exception:
                        pass
                    QtWidgets.QApplication.clipboard().setMimeData(md)
                lbl_img.clicked.connect(_copy_image)

        # Текст
        if it.text:
            lbl = QtWidgets.QLabel(it.text.strip())
            lbl.setWordWrap(True)
            lbl.setTextInteractionFlags(QtCore.Qt.TextInteractionFlag.TextSelectableByMouse)
            lbl.setStyleSheet("QLabel{font-size:13px; color:#111827; background: transparent; border:none;}")
            lbl.setMinimumHeight(20)
            lbl.setCursor(QtCore.Qt.CursorShape.IBeamCursor)
            lay.addWidget(lbl)

        return w

    # ---------- Вспомогательные методы ----------

    def _humanize_dt(self, it: ClipItem) -> str:
        secs = int((QtCore.QDateTime.currentDateTime().toSecsSinceEpoch()) - it.ts)
        if secs < 45:
            return "только что"
        mins = secs // 60
        if mins < 60:
            return f"{mins} мин назад"
        hrs = mins // 60
        if hrs < 24:
            return f"{hrs} ч назад"
        days = hrs // 24
        return f"{days} дн назад"

    def _time_chip_text(self, it: ClipItem) -> str:
        secs = int((QtCore.QDateTime.currentDateTime().toSecsSinceEpoch()) - it.ts)
        mins = secs // 60
        if secs < 45:
            return "только что"
        if mins < 60:
            return f"{mins} мин назад"
        return it.dt.strftime('%H:%M %d.%m.%Y')

    def _activate_current(self):
        row = self.list.currentRow()
        if row < 0 or row >= len(self.store.items):
            return
        chosen = self.store.items[row]
        cb = QtWidgets.QApplication.clipboard()
        md = QtCore.QMimeData()
        if chosen.kind == 'image' and chosen.img and Path(chosen.img).exists():
            pm = QtGui.QPixmap(chosen.img)
            if not pm.isNull():
                md.setImageData(pm.toImage())
            elif chosen.text:
                md.setText(chosen.text)
        else:
            md.setText(chosen.text)
        try:
            md.setData(INTERNAL_MIME, b"1")
        except Exception:
            pass
        cb.setMimeData(md)
        self.pasted.emit()
        self.hide()
