#!/usr/bin/env python3
import os
from pathlib import Path
import shutil
import subprocess

from PySide6 import QtCore, QtGui
from PySide6.QtGui import QGuiApplication

ASSETS_DIR = Path("assets")
ICON_PNG = ASSETS_DIR / "icon.png"
ICONSET_DIR = ASSETS_DIR / "icon.iconset"
ICON_ICNS = ASSETS_DIR / "app.icns"


def ensure_assets_dir():
    ASSETS_DIR.mkdir(parents=True, exist_ok=True)


def draw_clipboard_png(path: Path, size: int = 512) -> None:
    img = QtGui.QImage(size, size, QtGui.QImage.Format.Format_ARGB32)
    img.fill(QtGui.QColor(0, 0, 0, 0))
    p = QtGui.QPainter()
    try:
        p.begin(img)
        p.setRenderHints(QtGui.QPainter.Antialiasing | QtGui.QPainter.TextAntialiasing)

        # Rounded background
        rect = QtCore.QRectF(size * 0.0625, size * 0.0625, size * 0.875, size * 0.875)
        p.setPen(QtGui.QPen(QtGui.QColor(75, 85, 99), max(2, int(size * 0.015))))
        p.setBrush(QtGui.QBrush(QtGui.QColor(236, 239, 244)))
        r = size * 0.125
        p.drawRoundedRect(rect, r, r)

        # Emoji clipboard in center
        f = QtGui.QFont()
        f.setPointSizeF(size * 0.5)
        p.setFont(f)
        p.setPen(QtGui.QPen(QtGui.QColor(51, 65, 85)))
        p.drawText(img.rect(), int(QtCore.Qt.AlignCenter), "📋")
    finally:
        p.end()
    img.save(str(path), "PNG")


def build_icns_from_png(png_path: Path, iconset_dir: Path, icns_path: Path) -> None:
    # Requires macOS tools: sips, iconutil
    if iconset_dir.exists():
        shutil.rmtree(iconset_dir)
    iconset_dir.mkdir(parents=True, exist_ok=True)

    sizes_1x = [16, 32, 64, 128, 256, 512]
    sizes_2x = [32, 64, 128, 256, 512, 1024]

    for sz in sizes_1x:
        out = iconset_dir / f"icon_{sz}x{sz}.png"
        subprocess.run(
            ["sips", "-z", str(sz), str(sz), str(png_path), "--out", str(out)],
            check=False,
            stdout=subprocess.DEVNULL,
        )

    for sz in sizes_2x:
        base = sz // 2
        out = iconset_dir / f"icon_{base}x{base}@2x.png"
        subprocess.run(
            ["sips", "-z", str(sz), str(sz), str(png_path), "--out", str(out)],
            check=False,
            stdout=subprocess.DEVNULL,
        )

    subprocess.run(
        ["iconutil", "-c", "icns", str(iconset_dir), "-o", str(icns_path)],
        check=False,
        stdout=subprocess.DEVNULL,
    )


def main():
    ensure_assets_dir()
    print(f"[icons] Generating base PNG at {ICON_PNG}")
    draw_clipboard_png(ICON_PNG, 512)
    print(f"[icons] Building ICNS at {ICON_ICNS}")
    build_icns_from_png(ICON_PNG, ICONSET_DIR, ICON_ICNS)
    print("[icons] Done")


if __name__ == "__main__":
    app = QGuiApplication([])
    try:
        main()
    finally:
        app.quit()
