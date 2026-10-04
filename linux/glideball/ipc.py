"""GUI/ctl <-> daemon: one JSON object per line over a Unix socket.

Settings themselves travel through the settings file (the daemon watches
it), so this socket only carries live things: status and activity, pause,
mode toggles, and "press a button to learn it".
"""

from __future__ import annotations

import json
import os
import selectors
import socket
from typing import Callable, Optional


def socket_path() -> str:
    base = os.environ.get("XDG_RUNTIME_DIR") or f"/tmp/glideball-{os.getuid()}"
    os.makedirs(base, mode=0o700, exist_ok=True)
    return os.path.join(base, "glideball.sock")


class Server:
    def __init__(self, sel: selectors.BaseSelector, handler: Callable[[dict], dict], path: Optional[str] = None):
        self.sel = sel
        self.handler = handler
        self.path = path or socket_path()
        try:
            os.unlink(self.path)
        except FileNotFoundError:
            pass
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.bind(self.path)
        os.chmod(self.path, 0o600)
        self.sock.listen(8)
        self.sock.setblocking(False)
        self.buffers = {}
        sel.register(self.sock, selectors.EVENT_READ, ("listen", None))

    def handle(self, key) -> None:
        kind, _ = key.data
        if kind == "listen":
            try:
                conn, _ = self.sock.accept()
            except OSError:
                return
            conn.setblocking(False)
            self.buffers[conn] = b""
            self.sel.register(conn, selectors.EVENT_READ, ("client", None))
            return
        conn = key.fileobj
        try:
            chunk = conn.recv(65536)
        except BlockingIOError:
            return
        except OSError:
            chunk = b""
        if not chunk:
            self._close(conn)
            return
        buf = self.buffers.get(conn, b"") + chunk
        if len(buf) > 1 << 20:
            self._close(conn)
            return
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            try:
                msg = json.loads(line.decode("utf-8"))
                reply = self.handler(msg if isinstance(msg, dict) else {})
            except Exception as e:  # a bad request must never hurt the daemon
                reply = {"ok": False, "error": str(e)}
            # Never block the input loop on a slow client: replies are small and
            # fit the socket buffer; a client that isn't reading gets dropped.
            data = (json.dumps(reply) + "\n").encode()
            try:
                if conn.send(data) != len(data):
                    raise OSError("short write")
            except OSError:
                self._close(conn)
                return
        self.buffers[conn] = buf

    def _close(self, conn) -> None:
        self.buffers.pop(conn, None)
        try:
            self.sel.unregister(conn)
        except (KeyError, ValueError):
            pass
        conn.close()

    def close(self) -> None:
        for c in list(self.buffers):
            self._close(c)
        try:
            self.sel.unregister(self.sock)
        except (KeyError, ValueError):
            pass
        self.sock.close()
        try:
            os.unlink(self.path)
        except OSError:
            pass


class Client:
    """A persistent connection (the GUI polls status ~10x a second)."""

    def __init__(self, path: Optional[str] = None, timeout: float = 1.0):
        self.path = path or socket_path()
        self.timeout = timeout
        self.sock = None
        self.buf = b""

    def request(self, msg: dict) -> Optional[dict]:
        for _ in range(2):
            try:
                if self.sock is None:
                    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                    s.settimeout(self.timeout)
                    s.connect(self.path)
                    self.sock, self.buf = s, b""
                self.sock.sendall((json.dumps(msg) + "\n").encode())
                while b"\n" not in self.buf:
                    chunk = self.sock.recv(65536)
                    if not chunk:
                        raise ConnectionError("closed")
                    self.buf += chunk
                line, self.buf = self.buf.split(b"\n", 1)
                return json.loads(line.decode())
            except (OSError, ValueError, ConnectionError):
                self.close()
        return None

    def close(self) -> None:
        if self.sock is not None:
            try:
                self.sock.close()
            except OSError:
                pass
        self.sock = None


def request(msg: dict, path: Optional[str] = None) -> Optional[dict]:
    c = Client(path)
    try:
        return c.request(msg)
    finally:
        c.close()
