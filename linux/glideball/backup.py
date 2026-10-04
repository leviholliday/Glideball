"""Automatic, tiny, self-pruning settings backups (port of BackupStore.swift).

Each backup is an ordinary ``.glide-settings`` file (compact JSON) in
``~/.local/share/glideball/backups/``, named like the Mac's:
``2026-10-04 09.12.30.glide-settings`` or ``... before import.glide-settings``.

When: once a day (the first time the daemon or GUI runs that day, before any
change), plus a checkpoint before an import or restore, and on Back Up Now.
Nothing is written if the settings match the newest backup.

Retention (``expired``): everything from the last 14 days (dailies all,
checkpoints up to 5 per day), then the newest backup of each month up to a
year, and the newest backup always.
"""

from __future__ import annotations

import datetime as dt
import os
from typing import Callable, List, NamedTuple, Optional

from . import config as cfgmod

DAILY_WINDOW_DAYS = 14
KEEP_DAYS = 365
CHECKPOINTS_PER_DAY = 5

DAILY = "daily"
BEFORE_IMPORT = "before import"
BEFORE_RESTORE = "before restore"
MANUAL = "saved by you"
KINDS = (BEFORE_IMPORT, BEFORE_RESTORE, MANUAL)

STAMP = "%Y-%m-%d %H.%M.%S"


class Backup(NamedTuple):
    path: str
    date: dt.datetime
    kind: str
    size: int


def backups_dir() -> str:
    base = os.environ.get("XDG_DATA_HOME") or os.path.join(os.path.expanduser("~"), ".local", "share")
    return os.path.join(base, "glideball", "backups")


def file_name(date: dt.datetime, kind: str) -> str:
    stamp = date.strftime(STAMP)
    name = stamp if kind == DAILY else f"{stamp} {kind}"
    return f"{name}.{cfgmod.FILE_EXTENSION}"


def parse_name(name: str):
    if len(name) < 19:
        return None
    try:
        date = dt.datetime.strptime(name[:19], STAMP)
    except ValueError:
        return None
    rest = name[19:].strip()
    if not rest:
        return date, DAILY
    if rest in KINDS:
        return date, rest
    return None


def expired(backups: List[Backup], now: dt.datetime) -> List[Backup]:
    """The backups the retention rules no longer keep. Pure, for testing."""
    ordered = sorted(backups, key=lambda b: b.date, reverse=True)
    if not ordered:
        return []
    today = now.date()
    keep = {ordered[0].path}
    checkpoints_by_day: dict = {}
    months_seen = set()
    for b in ordered:   # newest first, so "first seen" = newest of its group
        day = b.date.date()
        age = max((today - day).days, 0)
        if age < DAILY_WINDOW_DAYS:
            if b.kind == DAILY:
                keep.add(b.path)
            else:
                n = checkpoints_by_day.get(day, 0)
                if n < CHECKPOINTS_PER_DAY:
                    keep.add(b.path)
                checkpoints_by_day[day] = n + 1
        elif age <= KEEP_DAYS:
            month = (b.date.year, b.date.month)
            if month not in months_seen:
                months_seen.add(month)
                keep.add(b.path)
    return [b for b in ordered if b.path not in keep]


class BackupStore:
    def __init__(self, folder: Optional[str] = None, now: Callable[[], dt.datetime] = dt.datetime.now):
        self.folder = folder or backups_dir()
        self.now = now
        self.last_error: Optional[str] = None

    def scan(self) -> List[Backup]:
        try:
            names = os.listdir(self.folder)
        except OSError:
            return []
        out = []
        suffix = "." + cfgmod.FILE_EXTENSION
        for n in names:
            if n.startswith(".") or not n.endswith(suffix):
                continue
            parsed = parse_name(n[: -len(suffix)])
            if parsed is None:
                continue
            p = os.path.join(self.folder, n)
            try:
                size = os.path.getsize(p)
            except OSError:
                size = 0
            out.append(Backup(p, parsed[0], parsed[1], size))
        return sorted(out, key=lambda b: b.date, reverse=True)

    def load(self, backup: Backup) -> Optional[dict]:
        try:
            with open(backup.path, encoding="utf-8") as f:
                data = cfgmod.parse_file(f.read())
        except (OSError, cfgmod.SettingsError):
            return None
        c = dict(cfgmod.config_of(data))
        c["enabled"] = True
        return c

    def prune(self) -> None:
        for b in expired(self.scan(), self.now()):
            try:
                os.remove(b.path)
            except OSError:
                pass

    def write(self, config: dict, kind: str, force: bool = False) -> bool:
        config = dict(config)
        config["enabled"] = True   # the pause switch isn't worth restoring
        existing = self.scan()
        if not force and existing:
            saved = self.load(existing[0])
            if saved is not None and cfgmod.configs_equal(saved, config):
                return False
        try:
            os.makedirs(self.folder, exist_ok=True)
            now = self.now()
            path = os.path.join(self.folder, file_name(now, kind))
            if os.path.exists(path):   # two in the same second
                path = os.path.join(self.folder, file_name(now + dt.timedelta(seconds=1), kind))
            data = cfgmod.new_file(config)
            cfgmod.atomic_write(path, cfgmod.dumps(data, compact=True))
            self.last_error = None
        except OSError as e:
            self.last_error = str(e)
            return False
        self.prune()
        return True

    def snapshot_if_due(self, config: dict) -> None:
        """Today's daily backup, unless today already has one or nothing changed."""
        today = self.now().date()
        if any(b.kind == DAILY and b.date.date() == today for b in self.scan()) \
                or not self.write(config, DAILY):
            self.prune()   # a new day ages everything, even when nothing is written

    def checkpoint(self, config: dict, kind: str) -> bool:
        return self.write(config, kind, force=(kind == MANUAL))
