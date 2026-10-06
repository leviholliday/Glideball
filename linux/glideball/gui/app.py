"""The settings window: GTK4 + libadwaita (needs libadwaita 1.4+).

Writes settings to the settings file (the daemon picks changes up within half
a second) and talks to the daemon over the socket for live status, pause,
and learning button presses.
"""

from __future__ import annotations

import collections
import json
import math
import os
import subprocess
import sys

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gio, GLib, Gtk  # noqa: E402

from .. import backup as backupmod  # noqa: E402
from .. import config as cfgmod  # noqa: E402
from .. import ipc, keymap, pointer, scroller  # noqa: E402
from ..strings import ACTION_PRESETS, APP_ID, APP_NAME, S, action_title  # noqa: E402

GRAPH_POINTS = 120   # 12 s at 10 Hz


class Settings:
    """Reads and writes the settings file, keeping unknown fields."""

    def __init__(self):
        self.data = cfgmod.load()
        self.backups = backupmod.BackupStore()
        self._pending = {}
        self._timer = 0

    @property
    def cfg(self) -> dict:
        return cfgmod.config_of(self.data)

    @property
    def eff(self) -> cfgmod.Effective:
        return cfgmod.Effective(self.cfg)

    def set(self, **changes):
        """Debounced: sliders write at most ~6 times a second."""
        self.cfg.update(changes)
        self._pending.update(changes)
        if not self._timer:
            self._timer = GLib.timeout_add(150, self._flush)

    def _flush(self):
        self._timer = 0
        changes, self._pending = self._pending, {}
        if changes:
            latest = cfgmod.load()   # never clobber what the daemon (pause) wrote meanwhile
            if cfgmod.load_local().get("autoBackups", True):
                self.backups.snapshot_if_due(cfgmod.config_of(latest))
            latest = cfgmod.with_changes(latest, **changes)
            cfgmod.save(latest)
            self.data = latest
        return False

    def replace(self, new_cfg: dict, kind: str):
        self._flush()
        self.backups.checkpoint(cfgmod.config_of(cfgmod.load()), kind)
        data = cfgmod.load()
        data["config"] = new_cfg
        cfgmod.save(data)
        self.data = data


def slider_row(title, subtitle, lo, hi, value, step, on_change, digits=2, log_scale=False,
               percent=False, low_label=None, high_label=None):
    row = Adw.ActionRow(title=title, subtitle=subtitle or "")
    if log_scale:
        adj = Gtk.Adjustment(lower=math.log(lo), upper=math.log(hi), step_increment=0.01, value=math.log(value))
    else:
        adj = Gtk.Adjustment(lower=lo, upper=hi, step_increment=step, value=value)
    scale = Gtk.Scale(orientation=Gtk.Orientation.HORIZONTAL, adjustment=adj, hexpand=True)
    scale.set_size_request(260, -1)
    scale.set_draw_value(True)
    scale.set_digits(digits)
    scale.set_valign(Gtk.Align.CENTER)
    if log_scale:
        scale.set_format_value_func(lambda _s, v: f"{math.exp(v):.1f}")
    elif percent:
        scale.set_format_value_func(lambda _s, v: f"{round(v * 100)}%")
    if low_label:
        scale.add_mark(lo, Gtk.PositionType.BOTTOM, low_label)
    if high_label:
        scale.add_mark(hi, Gtk.PositionType.BOTTOM, high_label)

    def changed(a):
        v = math.exp(a.get_value()) if log_scale else a.get_value()
        if step and not log_scale:
            v = round(v / step) * step
        on_change(round(v, 4))
    adj.connect("value-changed", changed)
    row.add_suffix(scale)

    def set_value(v):
        adj.handler_block_by_func(changed)
        adj.set_value(math.log(v) if log_scale else v)
        adj.handler_unblock_by_func(changed)
    row.set_value = set_value
    return row


def switch_row(title, subtitle, active, on_change):
    row = Adw.SwitchRow(title=title, subtitle=subtitle or "")
    row.set_active(active)
    row.connect("notify::active", lambda r, _p: on_change(r.get_active()))
    return row


class Graph(Gtk.DrawingArea):
    def __init__(self, color):
        super().__init__()
        self.values = collections.deque([0.0] * GRAPH_POINTS, maxlen=GRAPH_POINTS)
        self.color = color
        self.set_content_height(90)
        self.set_hexpand(True)
        self.set_draw_func(self._draw)

    def push(self, v):
        self.values.append(v)
        self.queue_draw()

    def _draw(self, _area, cr, w, h):
        top = max(max(self.values), 1e-6) * 1.15
        r, g, b = self.color
        cr.set_source_rgba(r, g, b, 0.18)
        cr.move_to(0, h)
        n = len(self.values)
        for i, v in enumerate(self.values):
            cr.line_to(i * w / (n - 1), h - v / top * (h - 4))
        cr.line_to(w, h)
        cr.close_path()
        cr.fill()
        cr.set_source_rgba(r, g, b, 1)
        cr.set_line_width(2)
        for i, v in enumerate(self.values):
            x, y = i * w / (n - 1), h - v / top * (h - 4)
            cr.line_to(x, y) if i else cr.move_to(x, y)
        cr.stroke()


class CurveView(Gtk.DrawingArea):
    """The Mac's response curve: cursor speed vs ball speed."""

    def __init__(self, get_speed, get_live):
        super().__init__()
        self.get_speed, self.get_live = get_speed, get_live
        self.set_content_height(180)
        self.set_hexpand(True)
        self.set_draw_func(self._draw)

    def _draw(self, _a, cr, w, h):
        t = self.get_speed()
        ymax = pointer.cursor_speed(6, 6)
        def pt(x, y):
            return x / 6 * w, h - min(y / ymax, 1) * (h - 2)
        cr.set_source_rgba(0.5, 0.5, 0.5, 0.6)
        cr.set_dash([4, 4])
        cr.move_to(*pt(0, 0))
        cr.line_to(*pt(6, 6))
        cr.stroke()
        cr.set_dash([])
        cr.set_source_rgba(0.45, 0.35, 0.95, 1)
        cr.set_line_width(3)
        for i in range(61):
            x = i / 10
            cr.line_to(*pt(x, pointer.cursor_speed(x, t)))
        cr.stroke()
        live = min(self.get_live(), 6)
        if live > 0.02:
            x, y = pt(live, pointer.cursor_speed(live, t))
            cr.set_source_rgba(0.1, 0.8, 0.9, 1)
            cr.arc(x, y, 6, 0, 2 * math.pi)
            cr.fill()


class Window(Adw.ApplicationWindow):
    def __init__(self, app):
        super().__init__(application=app, title=APP_NAME)
        self.set_default_size(820, 760)
        self.settings = Settings()
        self.client = ipc.Client(timeout=0.3)
        self.status = None
        self.last_stats = None
        self.toasts = Adw.ToastOverlay()

        stack = Adw.ViewStack()
        header = Adw.HeaderBar()
        switcher = Adw.ViewSwitcher(stack=stack, policy=Adw.ViewSwitcherPolicy.WIDE)
        header.set_title_widget(switcher)
        self.enable_switch = Gtk.Switch(valign=Gtk.Align.CENTER, tooltip_text=S["enable_sub"])
        self.enable_switch.connect("state-set", self._on_enable)
        header.pack_end(self.enable_switch)
        view = Adw.ToolbarView()
        view.add_top_bar(header)
        self.toasts.set_child(stack)
        view.set_content(self.toasts)
        self.set_content(view)

        stack.add_titled_with_icon(self._overview(), "overview", S["overview"], "go-home-symbolic")
        stack.add_titled_with_icon(self._pointer(), "pointer", S["pointer"], "input-mouse-symbolic")
        stack.add_titled_with_icon(self._scrolling(), "scrolling", S["scrolling"], "view-continuous-symbolic")
        stack.add_titled_with_icon(self._buttons(), "buttons", S["buttons"], "input-keyboard-symbolic")
        stack.add_titled_with_icon(self._backup(), "backup", S["backup"], "document-save-symbolic")

        self._poll()
        GLib.timeout_add(100, self._poll)

    def toast(self, text):
        self.toasts.add_toast(Adw.Toast(title=text, timeout=4))

    # ---- overview -----------------------------------------------------------

    def _overview(self):
        page = Adw.PreferencesPage()
        g = Adw.PreferencesGroup(title=S["status"])
        self.status_row = Adw.ActionRow(title="…")
        self.resume_button = Gtk.Button(label=S["resume"], valign=Gtk.Align.CENTER, visible=False)
        self.resume_button.connect("clicked", lambda _b: self.client.request({"cmd": "resume"}))
        self.status_row.add_suffix(self.resume_button)
        g.add(self.status_row)
        self.devices_group = Adw.PreferencesGroup(title=S["devices"])
        self.device_rows = []
        page.add(g)
        page.add(self.devices_group)

        a = Adw.PreferencesGroup(title=S["activity"])
        self.ball_graph = Graph((0.45, 0.35, 0.95))
        self.ring_graph = Graph((0.1, 0.75, 0.85))
        for title, graph in ((S["ball_speed"], self.ball_graph), (S["ring_speed"], self.ring_graph)):
            box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4, margin_top=8, margin_bottom=8,
                          margin_start=12, margin_end=12)
            box.append(Gtk.Label(label=title, xalign=0, css_classes=["caption-heading"]))
            box.append(graph)
            row = Gtk.ListBoxRow(activatable=False, child=box)
            a.add(row)
        self.clicks_row = Adw.ActionRow(title=S["today_clicks"])
        self.clicks_label = Gtk.Label(label="0", css_classes=["numeric"])
        self.clicks_row.add_suffix(self.clicks_label)
        a.add(self.clicks_row)
        page.add(a)

        m = Adw.PreferencesGroup(title=S["modes"])
        self.mode_rows = {}
        for mode in ("precision", "ballScroll", "dragLock"):
            row = Adw.SwitchRow(title=S["mode_" + mode])
            row.connect("notify::active", self._on_mode_row, mode)
            self.mode_rows[mode] = row
            m.add(row)
        page.add(m)

        b = Adw.PreferencesGroup()
        b.add(switch_row(S["beta"], S["beta_sub"], bool(cfgmod.load_local()["betaProgram"]), self._on_beta))
        b.add(Adw.ActionRow(title=S["panic"], subtitle=S["panic_sub"]))
        page.add(b)
        return page

    def _on_mode_row(self, row, _p, mode):
        if getattr(self, "_updating_modes", False):
            return
        current = (self.status or {}).get("modes", {}).get(mode)
        if current is not None and current != row.get_active():
            self.client.request({"cmd": "toggle-mode", "mode": mode})

    def _on_beta(self, on):
        cfgmod.save_local({"betaProgram": bool(on)})
        self.client.request({"cmd": "reload"})

    def _on_enable(self, _sw, state):
        if self.status is None:
            self.settings.set(enabled=state)
        elif state != self.status.get("enabled"):
            self.client.request({"cmd": "resume" if state else "pause"})
        return False

    def _poll(self):
        st = self.client.request({"cmd": "status"})
        self.status = st
        if st is None:
            self.status_row.set_title(S["no_daemon"])
            self.status_row.set_subtitle(S["no_daemon_sub"])
            self.resume_button.set_visible(False)
            return True
        if st.get("failed"):
            self.status_row.set_title(S["failed"])
            self.status_row.set_subtitle(S["failed_sub"].format(why=st["failed"]))
        elif not st.get("enabled"):
            self.status_row.set_title(S["paused"])
            self.status_row.set_subtitle(S["paused_sub"])
        elif not st.get("devices"):
            self.status_row.set_title(S["no_device"])
            self.status_row.set_subtitle(S["no_device_sub"])
        else:
            self.status_row.set_title(S["active"])
            self.status_row.set_subtitle("")
        self.resume_button.set_visible(bool(st.get("failed")) or not st.get("enabled"))
        self.enable_switch.handler_block_by_func(self._on_enable)
        self.enable_switch.set_active(bool(st.get("enabled")))
        self.enable_switch.set_state(bool(st.get("enabled")))
        self.enable_switch.handler_unblock_by_func(self._on_enable)

        names = [f'{d["name"]} — {d["path"]}' + ("" if d["grabbed"] else " (not grabbed)") for d in st["devices"]]
        if names != [r.get_title() for r in self.device_rows]:
            for r in self.device_rows:
                self.devices_group.remove(r)
            self.device_rows = [Adw.ActionRow(title=n) for n in names]
            for r in self.device_rows:
                self.devices_group.add(r)

        stats = st.get("stats", {})
        if self.last_stats is not None:
            notches = stats.get("notches", 0) - self.last_stats.get("notches", 0)
            self.ring_graph.push(max(notches, 0) * 10)
        self.ball_graph.push(float(st.get("ballSpeed", 0.0)) if stats != self.last_stats else 0.0)
        self.last_stats = stats
        self.clicks_label.set_label(str(stats.get("clicks", 0)))
        self._updating_modes = True
        for mode, row in self.mode_rows.items():
            row.set_active(bool(st.get("modes", {}).get(mode)))
        self._updating_modes = False
        if hasattr(self, "curve"):
            self.curve.queue_draw()
        if getattr(self, "learning", None) is not None and st.get("learned"):
            done, self.learning = self.learning, None
            done(st["learned"])
        return True

    # ---- pointer -----------------------------------------------------------------

    def _pointer(self):
        e = self.settings.eff
        page = Adw.PreferencesPage()
        g = Adw.PreferencesGroup(title=S["tracking_speed"], description=S["tracking_speed_sub"])
        self.speed_row = slider_row(S["tracking_speed"], "", pointer.SPEED_MIN, pointer.SPEED_MAX,
                                    min(max(e.trackingSpeed, pointer.SPEED_MIN), pointer.SPEED_MAX), 0.5,
                                    lambda v: self._set_speed(v), log_scale=True)
        g.add(self.speed_row)
        presets = Gtk.Box(spacing=6, halign=Gtk.Align.CENTER, margin_top=6, margin_bottom=6)
        for name, speed in pointer.PRESETS:
            b = Gtk.Button(label=name)
            b.connect("clicked", lambda _b, s=speed: (self._set_speed(s), self.speed_row.set_value(s)))
            presets.append(b)
        g.add(Gtk.ListBoxRow(activatable=False, child=presets))
        page.add(g)

        c = Adw.PreferencesGroup(title=S["response_curve"])
        self.curve = CurveView(lambda: self.settings.eff.trackingSpeed,
                               lambda: float((self.status or {}).get("ballSpeed", 0.0)))
        c.add(Gtk.ListBoxRow(activatable=False, child=self.curve))
        if os.environ.get("WAYLAND_DISPLAY"):
            c.set_description(S["wayland_accel_note"])
        page.add(c)

        p = Adw.PreferencesGroup()
        p.add(slider_row(S["precision_speed"], S["precision_speed_sub"], 0.1, 10, e.precisionSpeed, 0.1,
                         lambda v: self.settings.set(precisionSpeed=v), digits=1))
        page.add(p)
        return page

    def _set_speed(self, v):
        self.settings.set(trackingSpeed=round(v * 2) / 2 if v >= 1 else round(v, 1))
        self.curve.queue_draw() if hasattr(self, "curve") else None

    # ---- scrolling -------------------------------------------------------------------

    def _scrolling(self):
        e = self.settings.eff
        page = Adw.PreferencesPage()
        g = Adw.PreferencesGroup(title=S["scroll_mode"])
        modes = cfgmod.SCROLL_MODES
        row = Adw.ComboRow(title=S["scroll_mode"], model=Gtk.StringList.new([S["mode_" + m] for m in modes]))
        row.set_selected(modes.index(e.scrollMode))
        row.set_subtitle(S["mode_" + e.scrollMode + "_sub"])
        g.add(row)
        page.add(g)

        fly = Adw.PreferencesGroup(title=S["mode_flywheel"])
        rows = {
            "flyDistance": slider_row(S["fly_distance"], "pt", 1, 20, e.flyDistance, 0.5, lambda v: self.settings.set(flyDistance=v), 1),
            "flyAcceleration": slider_row(S["fly_acceleration"], "", 0, 1, e.flyAcceleration, 0.05, lambda v: self.settings.set(flyAcceleration=v)),
            "flyReach": slider_row(S["fly_reach"], "", 0, 1, e.flyReach, 0.01, lambda v: self.settings.set(flyReach=v), 2,
                                   percent=True, low_label=S["reach_short"], high_label=S["reach_far"]),
            "flyGlide": slider_row(S["fly_glide"], "", 0, 1, e.flyGlide, 0.05,
                                   lambda v: (self.settings.set(flyGlide=v),
                                              rows["flyGlide"].set_subtitle(f"{scroller.fly_tau(v) * 1000:.0f} ms"))),
        }
        rows["flyGlide"].set_subtitle(f"{scroller.fly_tau(e.flyGlide) * 1000:.0f} ms")
        for r in rows.values():
            fly.add(r)
        feel = Gtk.Button(label=S["kensington_feel"], halign=Gtk.Align.CENTER, margin_top=6, margin_bottom=6)

        def kensington(_b):
            self.settings.set(flyDistance=4.0, flyAcceleration=0.5, flyGlide=0.35, smoothScrolling=True)
            rows["flyDistance"].set_value(4.0)
            rows["flyAcceleration"].set_value(0.5)
            rows["flyGlide"].set_value(0.35)
            smooth.set_active(True)
        feel.connect("clicked", kensington)
        fly.add(Gtk.ListBoxRow(activatable=False, child=feel))
        page.add(fly)

        follow = Adw.PreferencesGroup(title=S["mode_follow"])
        follow.add(slider_row(S["scroll_distance"], "pt", 2, 40, e.scrollDistance, 1, lambda v: self.settings.set(scrollDistance=v), 0))
        follow.add(slider_row(S["scroll_smoothness"], "", 0, 1, e.scrollSmoothness, 0.05, lambda v: self.settings.set(scrollSmoothness=v)))
        follow.add(slider_row(S["scroll_acceleration"], "", 0, 1, e.scrollAcceleration, 0.05, lambda v: self.settings.set(scrollAcceleration=v)))
        follow.add(switch_row(S["throw_enabled"], "", e.throwEnabled, lambda v: self.settings.set(throwEnabled=v)))
        follow.add(slider_row(S["throw_amount"], "", 0, 1, e.throwAmount, 0.05, lambda v: self.settings.set(throwAmount=v)))
        page.add(follow)

        common = Adw.PreferencesGroup()
        smooth = switch_row(S["smooth_scrolling"], S["smooth_scrolling_sub"], e.smoothScrolling,
                            lambda v: self.settings.set(smoothScrolling=v))
        common.add(smooth)
        common.add(switch_row(S["reverse_scroll"], "", e.reverseScroll, lambda v: self.settings.set(reverseScroll=v)))
        common.add(slider_row(S["ball_scroll_speed"], "", 0.1, 5, e.ballScrollSpeed, 0.1,
                              lambda v: self.settings.set(ballScrollSpeed=v), 1))
        page.add(common)

        def show(mode):
            fly.set_visible(mode == "flywheel")
            follow.set_visible(mode == "follow")
            smooth.set_visible(mode != "native")

        def changed(r, _p):
            mode = modes[r.get_selected()]
            r.set_subtitle(S["mode_" + mode + "_sub"])
            self.settings.set(scrollMode=mode)
            show(mode)
        row.connect("notify::selected", changed)
        show(e.scrollMode)
        return page

    # ---- buttons -------------------------------------------------------------------

    def _buttons(self):
        page = Adw.PreferencesPage()
        g = Adw.PreferencesGroup(title=S["buttons"])
        names = S["button_names"]
        primary = Adw.ActionRow(title=names[0], subtitle=S["primary_locked"])
        g.add(primary)
        for n in range(1, len(names)):
            g.add(self._action_row(names[n], lambda n=n: self._button_action(n),
                                   lambda act, n=n: self._set_button(n, act)))
        page.add(g)

        self.combo_group = Adw.PreferencesGroup(title=S["combos"], description=S["combos_sub"])
        add = Gtk.Button(label=S["add_combo"], valign=Gtk.Align.CENTER)
        add.connect("clicked", self._add_combo)
        self.combo_group.set_header_suffix(add)
        self.combo_rows = []
        self._refresh_combos()
        page.add(self.combo_group)
        return page

    def _button_action(self, n):
        raw = self.settings.cfg.get("buttons")
        if isinstance(raw, dict) and str(n) in raw:
            return raw[str(n)]
        if raw is None or "buttons" not in self.settings.cfg:
            return cfgmod.default_config()["buttons"].get(str(n), cfgmod.action("system"))
        return cfgmod.action("system")

    def _set_button(self, n, act):
        raw = self.settings.cfg.get("buttons")
        buttons = dict(raw) if isinstance(raw, dict) else dict(cfgmod.default_config()["buttons"])
        if act == cfgmod.action("system"):
            buttons.pop(str(n), None)
        else:
            buttons[str(n)] = act
        self.settings.set(buttons=buttons)

    def _action_row(self, title, get, set_):
        """A row with a dropdown of presets plus 'Keyboard shortcut…'."""
        labels = [t for t, _ in ACTION_PRESETS] + [S["custom_shortcut"], S["hold_shortcut"]]
        current = get()
        cur_title = action_title(current)
        if cur_title not in labels:
            labels.append(cur_title)
        row = Adw.ComboRow(title=title, model=Gtk.StringList.new(labels))
        row.set_selected(labels.index(cur_title))
        state = {"last": row.get_selected()}

        def changed(r, _p):
            i = r.get_selected()
            if i < len(ACTION_PRESETS):
                set_(ACTION_PRESETS[i][1])
                state["last"] = i
            elif labels[i] in (S["custom_shortcut"], S["hold_shortcut"]):
                hold = labels[i] == S["hold_shortcut"]

                def done(sc):
                    if sc is None:
                        r.set_selected(state["last"])
                        return
                    act = cfgmod.shortcut_action(sc, hold=hold)
                    set_(act)
                    t = action_title(act)
                    model = r.get_model()
                    model.append(t)
                    labels.append(t)
                    state["last"] = len(labels) - 1
                    r.set_selected(state["last"])
                self._record_shortcut(done)
        row.connect("notify::selected", changed)
        return row

    def _record_shortcut(self, done):
        dialog = Adw.MessageDialog(transient_for=self, heading=S["record_title"], body=S["record_sub"])
        dialog.add_response("cancel", S["cancel"])
        ctrl = Gtk.EventControllerKey()
        ctrl.set_propagation_phase(Gtk.PropagationPhase.CAPTURE)   # before the dialog's buttons see keys
        result = {"sc": None, "done": False}

        def finish(*_a):
            if not result["done"]:
                result["done"] = True
                done(result["sc"])
            return False

        def key(_c, _keyval, keycode, state):
            code = keycode - 8   # X11/GDK hardware keycode -> evdev
            if code == 1:        # Esc
                dialog.close()
                return True
            if code in keymap.LINUX_MODIFIER_FLAGS:
                return True
            from gi.repository import Gdk
            flags = 0
            if state & Gdk.ModifierType.CONTROL_MASK:
                flags |= keymap.CONTROL
            if state & Gdk.ModifierType.ALT_MASK:
                flags |= keymap.OPTION
            if state & Gdk.ModifierType.SHIFT_MASK:
                flags |= keymap.SHIFT
            if state & Gdk.ModifierType.SUPER_MASK:
                flags |= keymap.COMMAND
            sc = keymap.from_linux(code, [])
            if sc is None:
                return True
            sc["modifiers"] = flags
            result["sc"] = sc
            dialog.close()
            return True
        ctrl.connect("key-pressed", key)
        dialog.add_controller(ctrl)
        dialog.connect("response", finish)
        dialog.connect("close-request", finish)
        dialog.present()

    def _chords(self):
        raw = self.settings.cfg.get("chords")
        return list(raw) if isinstance(raw, list) else list(cfgmod.default_config()["chords"])

    def _refresh_combos(self):
        for r in self.combo_rows:
            self.combo_group.remove(r)
        self.combo_rows = []
        names = S["button_names"]
        for i, chord in enumerate(self._chords()):
            if not isinstance(chord, dict) or not isinstance(chord.get("buttons"), list):
                continue
            title = " + ".join(names[b].split(" (")[0] if 0 <= b < len(names) else f"Button {b + 1}"
                               for b in chord["buttons"] if isinstance(b, int))
            row = self._action_row(title, lambda c=chord: c.get("action"),
                                   lambda act, i=i: self._set_chord_action(i, act))
            rm = Gtk.Button(icon_name="user-trash-symbolic", valign=Gtk.Align.CENTER, tooltip_text=S["remove"],
                            css_classes=["flat"])
            rm.connect("clicked", lambda _b, i=i: self._remove_chord(i))
            row.add_suffix(rm)
            self.combo_group.add(row)
            self.combo_rows.append(row)

    def _set_chord_action(self, i, act):
        chords = self._chords()
        chords[i] = dict(chords[i], action=act)
        self.settings.set(chords=chords)

    def _remove_chord(self, i):
        chords = self._chords()
        del chords[i]
        self.settings.set(chords=chords)
        self._refresh_combos()

    def _add_combo(self, _b):
        dialog = Adw.MessageDialog(transient_for=self, heading=S["learn_title"], body=S["learn"])
        dialog.add_response("cancel", S["cancel"])

        def learned(buttons):
            dialog.close()
            if len(buttons) < 2 or len(buttons) > 3:
                return
            chords = [c for c in self._chords() if sorted(c.get("buttons", [])) != sorted(buttons)]
            chords.append(cfgmod.new_chord(buttons, cfgmod.action("middleClick")))
            self.settings.set(chords=chords)
            self._refresh_combos()

        def closed(_d, _r):
            if self.learning is not None:
                self.learning = None
                self.client.request({"cmd": "learn-cancel"})
        dialog.connect("response", closed)
        self.learning = learned
        self.client.request({"cmd": "learn"})
        dialog.present()

    # ---- backup ----------------------------------------------------------------------

    def _backup(self):
        page = Adw.PreferencesPage()
        g = Adw.PreferencesGroup()
        box = Gtk.Box(spacing=8, halign=Gtk.Align.CENTER, margin_top=6, margin_bottom=6)
        exp = Gtk.Button(label=S["export"])
        exp.connect("clicked", self._export)
        imp = Gtk.Button(label=S["import"])
        imp.connect("clicked", self._import)
        box.append(exp)
        box.append(imp)
        g.add(Gtk.ListBoxRow(activatable=False, child=box))
        g.add(switch_row(S["auto_backups"], S["auto_backups_sub"], bool(cfgmod.load_local()["autoBackups"]),
                         lambda v: cfgmod.save_local({"autoBackups": bool(v)})))
        page.add(g)

        self.backup_group = Adw.PreferencesGroup(title=S["backup"])
        now = Gtk.Button(label=S["back_up_now"], valign=Gtk.Align.CENTER)
        now.connect("clicked", lambda _b: (self.settings.backups.checkpoint(self.settings.cfg, backupmod.MANUAL),
                                           self._refresh_backups()))
        folder = Gtk.Button(icon_name="folder-open-symbolic", valign=Gtk.Align.CENTER, tooltip_text=S["open_folder"])
        folder.connect("clicked", lambda _b: self._open_folder())
        suffix = Gtk.Box(spacing=6)
        suffix.append(folder)
        suffix.append(now)
        self.backup_group.set_header_suffix(suffix)
        self.backup_rows = []
        self._refresh_backups()
        page.add(self.backup_group)
        return page

    def _open_folder(self):
        os.makedirs(self.settings.backups.folder, exist_ok=True)
        Gio.AppInfo.launch_default_for_uri(GLib.filename_to_uri(self.settings.backups.folder, None), None)

    def _refresh_backups(self):
        for r in self.backup_rows:
            self.backup_group.remove(r)
        self.backup_rows = []
        items = self.settings.backups.scan()
        if not items:
            r = Adw.ActionRow(title=S["no_backups"])
            self.backup_group.add(r)
            self.backup_rows.append(r)
        for b in items:
            sub = "" if b.kind == backupmod.DAILY else b.kind
            r = Adw.ActionRow(title=b.date.strftime("%a %d %b %Y, %H:%M"), subtitle=sub)
            btn = Gtk.Button(label=S["restore"], valign=Gtk.Align.CENTER)
            btn.connect("clicked", lambda _x, b=b: self._restore(b))
            r.add_suffix(btn)
            self.backup_group.add(r)
            self.backup_rows.append(r)

    def _restore(self, b):
        cfg = self.settings.backups.load(b)
        if cfg is None:
            return
        cfg["enabled"] = self.settings.eff.enabled
        self.settings.replace(cfg, backupmod.BEFORE_RESTORE)
        self.toast(S["restored"])
        self._reload_ui()

    def _file_filter(self):
        f = Gtk.FileFilter()
        f.set_name(S["file_filter"])
        f.add_pattern("*." + cfgmod.FILE_EXTENSION)
        store = Gio.ListStore.new(Gtk.FileFilter)
        store.append(f)
        return store

    def _export(self, _b):
        dlg = Gtk.FileDialog(initial_name="Glideball." + cfgmod.FILE_EXTENSION, filters=self._file_filter())

        def done(d, res):
            try:
                f = d.save_finish(res)
            except GLib.Error:
                return
            data = cfgmod.new_file(dict(self.settings.cfg))
            cfgmod.atomic_write(f.get_path(), cfgmod.dumps(data) + "\n")
        dlg.save(self, None, done)

    def _import(self, _b):
        dlg = Gtk.FileDialog(filters=self._file_filter())

        def done(d, res):
            try:
                f = d.open_finish(res)
            except GLib.Error:
                return
            try:
                with open(f.get_path(), encoding="utf-8") as fh:
                    data = cfgmod.parse_file(fh.read())
            except (OSError, cfgmod.SettingsError) as e:
                self.toast(S["import_failed"].format(why=e))
                return
            cfg = dict(cfgmod.config_of(data))
            cfg["enabled"] = self.settings.eff.enabled
            self.settings.replace(cfg, backupmod.BEFORE_IMPORT)
            self.toast(S["import_done"])
            self._reload_ui()
        dlg.open(self, None, done)

    def _reload_ui(self):
        app = self.get_application()
        self.close()
        Window(app).present()


class App(Adw.Application):
    def __init__(self):
        super().__init__(application_id=APP_ID, flags=Gio.ApplicationFlags.FLAGS_NONE)
        act = Gio.SimpleAction.new("toggle-pause", None)
        act.connect("activate", lambda *_: ipc.request({"cmd": "toggle-pause"}))
        self.add_action(act)

    def do_activate(self):
        win = self.get_active_window() or Window(self)
        win.present()


def main(argv=None) -> int:
    return App().run([sys.argv[0]] + list(argv or []))
