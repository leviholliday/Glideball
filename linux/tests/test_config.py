"""Settings files must round-trip with the Mac app's GlideSettingsFile."""

import json
import os

import pytest

from glideball import config as c
from glideball import devices, keymap

FIXTURES = os.path.join(os.path.dirname(__file__), "fixtures")


def read(name):
    with open(os.path.join(FIXTURES, name), encoding="utf-8") as f:
        return f.read()


def test_defaults_match_the_mac_file():
    mac = json.loads(read("mac_default.glide-settings"))["config"]
    ours = c.default_config()
    assert set(mac) == set(ours)
    for key in mac:
        if key == "chords":
            assert [(x["buttons"], x["action"]) for x in mac[key]] == [(x["buttons"], x["action"]) for x in ours[key]]
        else:
            assert mac[key] == ours[key], key


def test_mac_file_parses_and_round_trips(tmp_path):
    text = read("mac_example.glide-settings")
    data = c.parse_file(text)
    e = c.Effective(c.config_of(data))
    assert e.trackingSpeed == 12
    assert e.buttons[1] == ("modifiedClick", (0, keymap.CONTROL))
    assert e.buttons[3][0] == "holdShortcut"
    assert [ch.kind for ch in e.chords] == ["holdShortcut", "dragLock"]
    assert e.globalShortcuts["precision"]["keyCode"] == 35

    path = str(tmp_path / "settings.glide-settings")
    edited = c.with_changes(data, trackingSpeed=20.0)
    c.save(edited, path)
    back = json.loads(open(path).read())
    original = json.loads(text)
    # Everything the Mac wrote survives, including fields Linux doesn't use.
    assert back["config"]["appProfiles"] == original["config"]["appProfiles"]
    assert back["config"]["chords"] == original["config"]["chords"]
    assert back["config"]["globalShortcuts"] == original["config"]["globalShortcuts"]
    assert back["config"]["trackingSpeed"] == 20.0
    assert back["version"] == 1 and back["exportedAt"].endswith("Z")
    for k in original["config"]:
        if k != "trackingSpeed":
            assert back["config"][k] == original["config"][k]


def test_unknown_fields_are_kept(tmp_path):
    data = json.loads(read("mac_default.glide-settings"))
    data["config"]["someFutureSetting"] = {"x": 1}
    data["futureTopLevel"] = True
    data["config"]["buttons"]["1"] = {"teleport": {"where": "moon"}}
    parsed = c.parse_file(json.dumps(data))
    e = c.Effective(c.config_of(parsed))
    assert 1 not in e.buttons                 # unreadable action: skipped, not fatal
    path = str(tmp_path / "s.glide-settings")
    c.save(c.with_changes(parsed, reverseScroll=True), path)
    back = json.loads(open(path).read())
    assert back["config"]["someFutureSetting"] == {"x": 1}
    assert back["futureTopLevel"] is True
    assert back["config"]["buttons"]["1"] == {"teleport": {"where": "moon"}}


def test_lenient_values():
    e = c.Effective({"trackingSpeed": "fast", "scrollMode": "warp", "reverseScroll": 1, "buttons": None})
    assert e.trackingSpeed == 4.0 and e.scrollMode == "flywheel" and e.reverseScroll is False
    assert e.buttons[2][0] == "shortcut"      # null buttons -> defaults
    assert c.Effective({"buttons": [1, {"rightClick": {}}]}).buttons == {1: ("rightClick", None)}


def test_bad_files_are_rejected_or_set_aside(tmp_path):
    with pytest.raises(c.SettingsError):
        c.parse_file("{nope")
    with pytest.raises(c.SettingsError):
        c.parse_file(json.dumps({"version": 2, "config": {}}))
    p = tmp_path / "settings.glide-settings"
    p.write_text("garbage")
    data = c.load(str(p))
    assert data["config"]["trackingSpeed"] == 4.0
    assert (tmp_path / "settings.glide-settings.unreadable").exists()


def test_local_settings(tmp_path):
    p = str(tmp_path / "local.json")
    assert c.load_local(p)["betaProgram"] is False
    c.save_local({"betaProgram": True}, p)
    assert c.load_local(p)["betaProgram"] is True


def test_shortcut_translation():
    assert keymap.translate(c.PREVIOUS_SPACE) == ([keymap.KEY_LEFTCTRL, keymap.KEY_LEFTALT], 105)
    assert keymap.translate(keymap.shortcut(8, keymap.COMMAND, "C")) == ([keymap.KEY_LEFTCTRL], 46)
    assert keymap.translate(c.DEFAULT_PAUSE) == ([29, 56, 125], 34)   # Ctrl+Alt+Super+G
    assert keymap.translate({"keyCode": 999, "modifiers": 0}) is None
    rec = keymap.from_linux(34, [29, 56, 125])
    assert rec["keyCode"] == 5 and rec["modifiers"] == c.DEFAULT_PAUSE["modifiers"]
    assert keymap.display(c.DEFAULT_PAUSE) == "Ctrl+Alt+Super+G"


def test_device_support():
    assert devices.is_supported(0x047D, 0x1020, "Kensington Expert Mouse")
    assert not devices.is_supported(0x047D, 0x2041, "Kensington SlimBlade Trackball")
    assert devices.is_supported(0x047D, 0x2041, "Kensington SlimBlade Trackball", beta=True)
    assert not devices.is_supported(0x056E, 0x010C, "ELECOM TrackBall Mouse HUGE TrackBall", beta=True)
    assert not devices.is_supported(0x1209, 0x6762, devices.VIRTUAL_DEVICE_NAME, beta=True)
    assert devices.is_pointer({1: [0x110, 0x111], 2: [0, 1, 8]})
    assert not devices.is_pointer({1: [30, 31]})


def test_fly_reach_round_trips_present_and_absent(tmp_path):
    # Present (as the new Mac app writes it): kept and read.
    data = json.loads(read("mac_default.glide-settings"))
    assert data["config"]["flyReach"] == 0.5
    data["config"]["flyReach"] = 0.8
    parsed = c.parse_file(json.dumps(data))
    assert c.Effective(c.config_of(parsed)).flyReach == 0.8
    path = str(tmp_path / "a.glide-settings")
    c.save(c.with_changes(parsed, flyGlide=0.5), path)
    assert json.loads(open(path).read())["config"]["flyReach"] == 0.8
    c.save(c.with_changes(parsed, flyReach=0.25), path)
    assert json.loads(open(path).read())["config"]["flyReach"] == 0.25

    # Absent (a file from an older app): the default, and no key is invented on save.
    del data["config"]["flyReach"]
    old = c.parse_file(json.dumps(data))
    assert c.Effective(c.config_of(old)).flyReach == 0.5
    assert c.default_config()["flyReach"] == 0.5
    path = str(tmp_path / "b.glide-settings")
    c.save(old, path)
    assert "flyReach" not in json.loads(open(path).read())["config"]

    # Garbage falls back to the default.
    assert c.Effective({"flyReach": "far"}).flyReach == 0.5


def test_engine_scroller_gets_fly_reach():
    from glideball.scroller import ScrollSettings
    assert ScrollSettings.from_config(c.Effective({"flyReach": 0.2}).__dict__).flyReach == 0.2
    assert ScrollSettings().flyReach == 0.5
