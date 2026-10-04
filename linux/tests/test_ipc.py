import os
import selectors
import shutil
import tempfile
import threading

from glideball import ipc


def test_round_trip_and_bad_input():
    d = tempfile.mkdtemp(prefix="gb", dir="/tmp")   # short: AF_UNIX paths max ~104 bytes
    path = os.path.join(d, "s.sock")
    sel = selectors.DefaultSelector()
    server = ipc.Server(sel, lambda m: {"ok": True, "echo": m.get("cmd")}, path=path)
    stop = threading.Event()

    def loop():
        while not stop.is_set():
            for key, _ in sel.select(0.05):
                server.handle(key)
    t = threading.Thread(target=loop)
    t.start()
    try:
        c = ipc.Client(path)
        assert c.request({"cmd": "status"}) == {"ok": True, "echo": "status"}
        assert c.request({"cmd": "again"})["echo"] == "again"     # persistent connection
        c.sock.sendall(b"not json\n")
        assert c.request({"cmd": "x"}) is not None                # survived garbage
        c.close()
        assert ipc.request({"cmd": "one-shot"}, path)["echo"] == "one-shot"
    finally:
        stop.set()
        t.join()
        server.close()
        shutil.rmtree(d, ignore_errors=True)
    assert ipc.request({"cmd": "status"}, path) is None          # no server: None, no exception
