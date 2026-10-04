"""GUI smoke test (CI, under xvfb-run): build every page, then quit.

Not a pytest file: it needs GTK 4, libadwaita and a display.
Run: xvfb-run -a python3 tests/gui_smoke.py
"""

import os
import sys
import tempfile

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))
home = tempfile.mkdtemp()
os.environ["XDG_CONFIG_HOME"] = os.path.join(home, "config")
os.environ["XDG_DATA_HOME"] = os.path.join(home, "data")
os.environ["XDG_RUNTIME_DIR"] = os.path.join(home, "run")

from gi.repository import GLib  # noqa: E402

from glideball.gui import app as guiapp  # noqa: E402

result = {"ok": False}


class SmokeApp(guiapp.App):
    def do_activate(self):
        win = guiapp.Window(self)
        win.present()

        def done():
            win._poll()                      # no daemon: must show the "not running" state
            assert "isn't running" in win.status_row.get_title()
            result["ok"] = True
            self.quit()
            return False
        GLib.timeout_add(500, done)


SmokeApp().run([sys.argv[0]])
print("GUI smoke test:", "OK" if result["ok"] else "FAILED")
sys.exit(0 if result["ok"] else 1)
