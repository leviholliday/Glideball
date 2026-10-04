"""The daemon's event pipeline against a fake input device and a fake uinput."""

import types

import pytest

from glideball import config as c
from glideball import daemon as d
from glideball.engine import RecordingOutput


class FakeDev:
    def __init__(self, vendor=0x047D, product=0x1020, name="Kensington Expert Mouse"):
        self.info = types.SimpleNamespace(vendor=vendor, product=product)
        self.name = name
        self.path = "/dev/input/event99"
        self.fd = 99
        self.grabs = 0
        self.queue = []

    def grab(self):
        self.grabs += 1

    def ungrab(self):
        self.grabs -= 1

    def read(self):
        q, self.queue = self.queue, []
        return q

    def close(self):
        pass


def ev(type_, code, value):
    return types.SimpleNamespace(type=type_, code=code, value=value)


@pytest.fixture
def daemon(tmp_path, monkeypatch):
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path / "cfg"))
    monkeypatch.setenv("XDG_DATA_HOME", str(tmp_path / "data"))
    cfg = c.default_config()
    cfg["chords"] = []
    c.save(c.new_file(cfg))
    dm = d.Daemon(output=RecordingOutput())
    dev = FakeDev()
    t = d.Tracked(dev, "expertMouse")
    dm.devices[dev.path] = t
    dm._grab(t)
    return dm, t, dev


def test_motion_is_batched_per_report(daemon):
    dm, t, dev = daemon
    dev.queue = [ev(d.EV_REL, d.REL_X, 3), ev(d.EV_REL, d.REL_Y, -2), ev(d.EV_SYN, d.SYN_REPORT, 0)]
    dm._read(dev.path)
    rel = [e for e in dm.out.events if e[0] == "rel"]
    assert len(rel) == 1 and rel[0][1] > 0 and rel[0][2] < 0


def test_buttons_and_wheel(daemon):
    dm, t, dev = daemon
    dev.queue = [ev(d.EV_KEY, d.BTN_LEFT + 1, 1), ev(d.EV_SYN, 0, 0), ev(d.EV_KEY, d.BTN_LEFT + 1, 0),
                 ev(d.EV_REL, d.REL_WHEEL_HI_RES, 120), ev(d.EV_SYN, 0, 0)]
    dm._read(dev.path)
    assert dm.out.take(("button",)) == [("button", 1, True), ("button", 1, False)]


def test_error_ungrabs_and_releases(daemon, monkeypatch):
    dm, t, dev = daemon
    dev.queue = [ev(d.EV_KEY, d.BTN_LEFT + 1, 1)]
    dm._read(dev.path)
    assert dev.grabs == 1

    def boom(*a, **k):
        raise RuntimeError("bug")
    monkeypatch.setattr(dm.engine, "motion", boom)
    dev.queue = [ev(d.EV_REL, d.REL_X, 3), ev(d.EV_SYN, 0, 0)]
    dm._read(dev.path)
    assert dm.failed and dev.grabs == 0 and not t.grabbed
    assert ("button", 1, False) in dm.out.events          # nothing left held down
    dev.queue = [ev(d.EV_KEY, d.BTN_LEFT, 1)]               # pass-through: we ignore events now
    dm.out.events.clear()
    dm._read(dev.path)
    assert dm.out.events == []


def test_pause_ungrabs_and_resume_regrabs(daemon):
    dm, t, dev = daemon
    dm.command({"cmd": "pause"})
    assert not dm.enabled and dev.grabs == 0
    assert c.load()["config"]["enabled"] is False
    dm.command({"cmd": "toggle-pause"})
    assert dm.enabled and dev.grabs == 1


def test_status_and_bad_commands(daemon):
    dm, t, dev = daemon
    st = dm.command({"cmd": "status"})
    assert st["ok"] and st["devices"][0]["kind"] == "expertMouse"
    assert dm.command({"cmd": "nope"})["ok"] is False


def test_settings_file_changes_apply_live(daemon):
    dm, t, dev = daemon
    data = c.load()
    c.save(c.with_changes(data, scrollMode="native"))
    dm._settings_stamp = None
    dm.reload_settings()
    assert dm.engine.cfg.scrollMode == "native"
