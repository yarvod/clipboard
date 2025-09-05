import json
from dataclasses import dataclass, asdict
from datetime import datetime
from pathlib import Path
from typing import List

from PySide6 import QtCore

from .config import APP_DIR, HISTORY_PATH, MAX_ITEMS


@dataclass
class ClipItem:
    id: str
    kind: str  # 'text' | 'image'
    ts: float  # epoch seconds
    text: str = ''
    img: str = ''  # path to image file when kind == 'image'

    @property
    def dt(self) -> datetime:
        return datetime.fromtimestamp(self.ts)


class HistoryStore(QtCore.QObject):
    changed = QtCore.Signal()
    cleared = QtCore.Signal()

    def __init__(self):
        super().__init__()
        self.items: List[ClipItem] = []
        APP_DIR.mkdir(parents=True, exist_ok=True)
        self._load()

    def add_text(self, text: str):
        t = (text or '').strip()
        if not t:
            return
        if self.items and self.items[0].kind == 'text' and self.items[0].text == t:
            return
        self.items.insert(0, ClipItem(id=QtCore.QUuid.createUuid().toString(), kind='text', text=t, ts=datetime.now().timestamp()))
        del self.items[MAX_ITEMS:]
        self._save()
        self.changed.emit()

    def add_image_path(self, path: str):
        if not path:
            return
        if self.items and self.items[0].kind == 'image' and self.items[0].img == path:
            return
        self.items.insert(0, ClipItem(id=QtCore.QUuid.createUuid().toString(), kind='image', img=path, ts=datetime.now().timestamp()))
        del self.items[MAX_ITEMS:]
        self._save()
        self.changed.emit()

    def clear(self):
        # remove stored images
        try:
            img_dir = APP_DIR / 'images'
            if img_dir.exists():
                for p in img_dir.glob('*'):
                    try:
                        p.unlink()
                    except Exception:
                        pass
        finally:
            pass
        self.items.clear()
        self._save()
        self.cleared.emit()
        self.changed.emit()

    def delete_indices(self, rows: List[int]):
        for r in sorted(rows, reverse=True):
            if 0 <= r < len(self.items):
                it = self.items.pop(r)
                if it.kind == 'image' and it.img:
                    try:
                        Path(it.img).unlink(missing_ok=True)
                    except Exception:
                        pass
        self._save()
        self.changed.emit()

    def _save(self):
        data = [asdict(i) for i in self.items]
        with open(HISTORY_PATH, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)

    def _load(self):
        if not HISTORY_PATH.exists():
            return
        try:
            with open(HISTORY_PATH, "r", encoding="utf-8") as f:
                data = json.load(f)
            items: List[ClipItem] = []
            for d in data:
                if 'kind' not in d:
                    items.append(ClipItem(id=d.get('id', ''), kind='text', text=d.get('text', ''), ts=d.get('ts', 0.0)))
                else:
                    items.append(ClipItem(
                        id=d.get('id', ''),
                        kind=d.get('kind', 'text'),
                        ts=d.get('ts', 0.0),
                        text=d.get('text', ''),
                        img=d.get('img', ''),
                    ))
            self.items = items
        except Exception:
            self.items = []

