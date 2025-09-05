from pathlib import Path

APP_NAME = "ClipboardCommander"
APP_DIR = Path.home() / "Library" / "Application Support" / APP_NAME
HISTORY_PATH = APP_DIR / "history.json"
MAX_ITEMS = 300
INSTANCE_LOCK_PATH = APP_DIR / "instance.lock"
INTERNAL_MIME = "application/x-clipboardcommander-internal"
