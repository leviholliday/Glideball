"""glideball [gui|daemon|ctl ...]"""

from __future__ import annotations

import json
import sys

USAGE = """usage: glideball [gui]              open the settings window
       glideball daemon            run the background service (systemd starts this)
       glideball ctl COMMAND       talk to the running service:
           status | pause | resume | toggle-pause
           toggle-mode precision|ballScroll|dragLock | reload
"""


def ctl(args) -> int:
    from . import ipc
    if not args:
        print(USAGE, end="")
        return 2
    msg = {"cmd": args[0]}
    if args[0] == "toggle-mode":
        if len(args) < 2:
            print(USAGE, end="")
            return 2
        msg["mode"] = args[1]
    reply = ipc.request(msg)
    if reply is None:
        print("glideball: the service isn't running (systemctl --user start glideball)", file=sys.stderr)
        if args[0] in ("pause", "toggle-pause"):
            return 1
        return 1
    print(json.dumps(reply, indent=2))
    return 0 if reply.get("ok") else 1


def main(argv=None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    cmd = argv[0] if argv else "gui"
    if cmd in ("-h", "--help", "help"):
        print(USAGE, end="")
        return 0
    if cmd == "daemon":
        from .daemon import main as daemon_main
        return daemon_main(argv[1:])
    if cmd == "ctl":
        return ctl(argv[1:])
    if cmd == "gui":
        from .gui.app import main as gui_main
        return gui_main(argv[1:])
    print(USAGE, end="", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
