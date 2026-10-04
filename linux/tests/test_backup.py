"""Backup retention, mirroring BackupStore.expired on the Mac."""

import datetime as dt
import json
import os

from glideball import backup as b
from glideball import config as c

NOW = dt.datetime(2026, 10, 4, 12, 0, 0)


def bk(days_ago, kind=b.DAILY, hour=9, minute=0):
    d = NOW - dt.timedelta(days=days_ago)
    d = d.replace(hour=hour, minute=minute)
    return b.Backup(b.file_name(d, kind), d, kind, 100)


def kept(backups):
    gone = {x.path for x in b.expired(backups, NOW)}
    return [x for x in backups if x.path not in gone]


def test_dailies_kept_for_14_days():
    backups = [bk(i) for i in range(0, 20)]
    k = kept(backups)
    assert all(x in k for x in backups[:14])
    # days 14..19 are older: only the newest of their month stays
    older = [x for x in backups[14:] if x in k]
    months = {(x.date.year, x.date.month) for x in backups[14:]}
    assert len(older) == len(months)


def test_monthly_for_a_year_then_gone():
    backups = [bk(i) for i in range(0, 400, 7)]
    k = kept(backups)
    for x in k:
        age = (NOW.date() - x.date.date()).days
        assert age <= 365 or x == backups[0]
    monthly = [x for x in k if (NOW.date() - x.date.date()).days >= 14]
    assert len({(x.date.year, x.date.month) for x in monthly}) == len(monthly)


def test_newest_always_kept_even_if_ancient():
    old = [bk(800), bk(900)]
    assert kept(old) == [old[0]]


def test_checkpoints_capped_per_day():
    cps = [bk(1, b.BEFORE_IMPORT, hour=9, minute=m) for m in range(8)]
    k = kept(cps + [bk(0)])
    assert len([x for x in k if x.kind == b.BEFORE_IMPORT]) == 5


def test_names_round_trip():
    d = dt.datetime(2026, 10, 4, 9, 12, 30)
    assert b.file_name(d, b.DAILY) == "2026-10-04 09.12.30.glide-settings"
    assert b.parse_name("2026-10-04 09.12.30 before import") == (d, b.BEFORE_IMPORT)
    assert b.parse_name("2026-10-04 09.12.30") == (d, b.DAILY)
    assert b.parse_name("nonsense") is None


def test_store_writes_once_per_change(tmp_path):
    t = [NOW]
    store = b.BackupStore(str(tmp_path), now=lambda: t[0])
    cfg = c.default_config()
    store.snapshot_if_due(cfg)
    store.snapshot_if_due(cfg)
    assert len(store.scan()) == 1
    t[0] = NOW + dt.timedelta(days=1)
    store.snapshot_if_due(cfg)            # unchanged settings: nothing new
    assert len(store.scan()) == 1
    cfg2 = dict(cfg, trackingSpeed=9.0)
    store.snapshot_if_due(cfg2)
    assert len(store.scan()) == 2
    assert store.checkpoint(cfg2, b.MANUAL)   # Back Up Now always writes
    files = store.scan()
    assert len(files) == 3
    data = json.loads(open(files[0].path).read())
    assert data["version"] == 1 and data["config"]["trackingSpeed"] == 9.0
    assert store.load(files[0])["enabled"] is True
