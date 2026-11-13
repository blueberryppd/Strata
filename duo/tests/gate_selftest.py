#!/usr/bin/env python3
"""Self-test of the gate (duo/duo_gate.py) without a model, without a second Mac and without the real duo.sh.

It starts the real gate in front of two stand-ins that live in a temporary folder:
  - a stand-in duo.sh: `up` waits 2 s, creates a marker file and starts a sleeping stand-in "engine" process;
    `down` removes both. Every call is counted.
  - a stand-in API server (inside this script): answers /v1/models and /v1/chat/completions (plain and streamed) with
    the right key, and only while the marker file exists.
and checks: the key (401 without it), the model list while unloaded, loading on the first request, one load for two
requests that arrive together, a streamed answer arriving piece by piece, POST /duo/unload (409 while a request is in
flight, then 200), busy patterns (a request waits while a matching process runs), idle unload, and a failed load (503).

usage: gate_selftest.py [--gate-port 8090] [--backend-port 8091] [--link-port 50175]
About 30 seconds. Standard library only; Python 3.9 or newer. Exit status 0 when every check passed.
"""
import argparse, http.client, json, os, signal, socket, subprocess, sys, tempfile, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
GATE = HERE.parent / "duo_gate.py"
KEY = "selftest-key-0123456789abcdef"
checks = []


def check(name, ok, detail=""):
    checks.append(ok)
    print("%s  %s%s" % ("PASS" if ok else "FAIL", name, (": " + detail) if detail else ""), flush=True)


def request(port, method, path, key=KEY, body=None, header="Authorization", timeout=120):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    h = {}
    if key is not None:
        h[header] = ("Bearer " + key) if header == "Authorization" else key
    data = json.dumps(body).encode() if body is not None else None
    if data:
        h["Content-Type"] = "application/json"
    c.request(method, path, body=data, headers=h)
    r = c.getresponse()
    raw = r.read()
    c.close()
    try:
        return r.status, json.loads(raw)
    except ValueError:
        return r.status, raw


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--gate-port", type=int, default=8090)
    ap.add_argument("--backend-port", type=int, default=8091)
    ap.add_argument("--link-port", type=int, default=50175, help="only a number in the stand-in engine's command line; nothing listens on it")
    ap.add_argument("--keep", action="store_true", help="keep the temporary folder (the gate's log is in it)")
    a = ap.parse_args()
    tmp = Path(tempfile.mkdtemp(prefix="duo-gate-selftest-"))
    run = tmp / "run"
    run.mkdir()
    (run / "api_key").write_text(KEY + "\n")
    os.chmod(run / "api_key", 0o600)
    marker, calls, fail_flag = tmp / "loaded", tmp / "calls", tmp / "fail_next_up"
    refuse_once = tmp / "refuse_once"
    calls.write_text("")
    engine = tmp / "fake_ds4_stub"
    engine.write_text("#!/usr/bin/env python3\nimport time\ntime.sleep(3600)\n")
    busy_prog = tmp / "fake_busy_job"
    busy_prog.write_text("#!/usr/bin/env python3\nimport time\ntime.sleep(3600)\n")
    duo = tmp / "duo.sh"
    duo.write_text("""#!/bin/bash
# stand-in for duo.sh: a marker file and a sleeping process instead of a model
D=%(tmp)s
echo "$1" >> "$D/calls"
case "$1" in
up)
  [ -f "$D/fail_next_up" ] && { rm -f "$D/fail_next_up"; echo "stand-in: this load fails on purpose"; exit 1; }
  sleep 2
  nohup %(py)s "$D/fake_ds4_stub" --duo-listen 127.0.0.1:%(link)d > /dev/null 2>&1 < /dev/null &
  echo $! > "$D/engine.pid"
  touch "$D/loaded"; echo loaded ;;
down)
  [ -f "$D/engine.pid" ] && kill "$(cat "$D/engine.pid")" 2>/dev/null
  rm -f "$D/engine.pid" "$D/loaded"; echo unloaded ;;
esac
""" % {"tmp": "'%s'" % tmp, "py": sys.executable, "link": a.link_port})
    os.chmod(duo, 0o755)

    class Stub(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):
            pass

        def send_json(self, code, obj):
            body = json.dumps(obj).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_any(self):
            n = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(n)) if n else {}
            if self.headers.get("Authorization") != "Bearer " + KEY:
                return self.send_json(401, {"error": "stub: wrong key"})
            if not marker.exists():
                return self.send_json(503, {"error": "stub: not loaded"})
            if self.path == "/v1/models":
                return self.send_json(200, {"object": "list", "data": [{"id": "stub-model", "object": "model", "owned_by": "stub"}]})
            if self.path == "/v1/chat/completions":
                if refuse_once.exists():   # (a server whose engine has just died: it refuses, once)
                    refuse_once.unlink()
                    return self.send_json(503, {"error": "stub: the engine is gone"})
                time.sleep(float(body.get("stub_sleep", 0)))
                if body.get("stream"):
                    self.send_response(200)
                    self.send_header("Content-Type", "text/event-stream")
                    self.send_header("Connection", "close")
                    self.end_headers()
                    for i in range(5):
                        self.wfile.write(("data: " + json.dumps({"choices": [{"delta": {"content": "tok%d " % i}}]}) + "\n\n").encode())
                        self.wfile.flush()
                        time.sleep(0.3)
                    self.wfile.write(b"data: [DONE]\n\n")
                    self.close_connection = True
                    return
                return self.send_json(200, {"choices": [{"message": {"role": "assistant", "content": "stub answer"}}],
                                            "usage": {"prompt_tokens": 3, "completion_tokens": 2}})
            return self.send_json(404, {"error": "stub: no such path"})

        do_GET = do_POST = do_any

    stub = ThreadingHTTPServer(("127.0.0.1", a.backend_port), Stub)
    stub.daemon_threads = True
    threading.Thread(target=stub.serve_forever, daemon=True).start()

    gate_log = open(tmp / "gate.log", "w")
    gate = subprocess.Popen([sys.executable, str(GATE), "--listen", str(a.gate_port), "--backend", str(a.backend_port), "--idle-min", "0.1",
                             "--run-dir", str(run), "--duo-sh", str(duo), "--model-id", "selftest-model", "--engine-name", "fake_ds4_stub",
                             "--link-port", str(a.link_port), "--busy-poll-s", "1", "--busy-max-s", "60"],
                            stdout=gate_log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
    busy = None
    G = a.gate_port
    n_calls = lambda verb: calls.read_text().split().count(verb)
    chat = {"model": "selftest-model", "messages": [{"role": "user", "content": "hi"}]}
    try:
        for _ in range(50):
            try:
                socket.create_connection(("127.0.0.1", G), timeout=0.2).close()
                break
            except OSError:
                time.sleep(0.1)
        st, j = request(G, "GET", "/duo/status", key=None)
        check("status needs no key and says unloaded", st == 200 and j.get("loaded") is False, json.dumps(j))
        st, _ = request(G, "POST", "/v1/chat/completions", key=None, body=chat)
        check("no key: 401", st == 401, "HTTP %d" % st)
        st, _ = request(G, "POST", "/v1/chat/completions", key="wrong", body=chat)
        check("wrong key: 401", st == 401, "HTTP %d" % st)
        st, _ = request(G, "POST", "/duo/unload", key="wrong")
        check("unload with a wrong key: 401", st == 401, "HTTP %d" % st)
        check("a request without the key did not load the pair", n_calls("up") == 0 and not marker.exists())
        st, j = request(G, "GET", "/v1/models", key=KEY, header="x-api-key")
        check("model list while unloaded (x-api-key header), answered by the gate", st == 200 and j["data"][0]["id"] == "selftest-model"
              and j["data"][0]["status"]["value"] == "unloaded" and n_calls("up") == 0, json.dumps(j["data"][0]) if st == 200 else "HTTP %d" % st)

        # two requests arrive together while unloaded: one load, both answered
        res = []
        t0 = time.time()
        ths = [threading.Thread(target=lambda: res.append(request(G, "POST", "/v1/chat/completions", body=chat))) for _ in range(2)]
        for t in ths:
            t.start()
        for t in ths:
            t.join()
        dt = time.time() - t0
        check("on-demand load: two requests together, one load, both answered", [r[0] for r in res] == [200, 200] and n_calls("up") == 1
              and marker.exists() and dt >= 2.0, "HTTP %s, %d load(s), %.1f s" % ([r[0] for r in res], n_calls("up"), dt))
        st, j = request(G, "GET", "/duo/status", key=None)
        check("status says loaded", st == 200 and j.get("loaded") is True, json.dumps(j))
        st, j = request(G, "GET", "/v1/models")
        check("model list while loaded is the server's own", st == 200 and j["data"][0]["owned_by"] == "stub")

        # a streamed answer: the pieces arrive as they are written, not all at the end
        c = http.client.HTTPConnection("127.0.0.1", G, timeout=30)
        c.request("POST", "/v1/chat/completions", body=json.dumps(dict(chat, stream=True)).encode(),
                  headers={"Authorization": "Bearer " + KEY, "Content-Type": "application/json"})
        r = c.getresponse()
        times, text = [], b""
        while True:
            piece = r.read1(65536)
            if not piece:
                break
            times.append(time.time())
            text += piece
        c.close()
        check("streamed answer: 5 pieces and [DONE], spread over time", r.status == 200 and text.count(b"data: ") == 6 and b"[DONE]" in text
              and len(times) >= 4 and times[-1] - times[0] > 0.8 and r.getheader("Transfer-Encoding") == "chunked",
              "%d reads over %.1f s, Transfer-Encoding %s" % (len(times), times[-1] - times[0] if times else 0, r.getheader("Transfer-Encoding")))

        # unload on request: refused while a request is in flight, done when idle
        slow = threading.Thread(target=lambda: res.append(request(G, "POST", "/v1/chat/completions", body=dict(chat, stub_sleep=3))))
        slow.start()
        time.sleep(1)
        st, j = request(G, "POST", "/duo/unload")
        check("POST /duo/unload while a request is in flight: 409, still loaded", st == 409 and marker.exists(), "HTTP %d %s" % (st, json.dumps(j)))
        slow.join()
        check("the request in flight was answered", res[-1][0] == 200)
        st, j = request(G, "POST", "/duo/unload")
        check("POST /duo/unload when idle: 200, unloaded", st == 200 and j == {"unloaded": True} and not marker.exists() and n_calls("down") == 1,
              "HTTP %d %s" % (st, json.dumps(j)))

        # busy patterns: while a matching process runs the pair is not loaded and the request waits
        busy = subprocess.Popen([sys.executable, str(busy_prog)], stdin=subprocess.DEVNULL)
        (run / "busy_patterns").write_text("# a comment line\nfake_busy_job\n")
        ups = n_calls("up")
        t0 = time.time()
        waiter = threading.Thread(target=lambda: res.append(request(G, "POST", "/v1/chat/completions", body=chat)))
        waiter.start()
        time.sleep(4)
        state = json.loads((run / "gate_state.json").read_text()).get("state")
        check("busy pattern matches: after 4 s the pair is not loaded and the request waits", n_calls("up") == ups and waiter.is_alive() and not marker.exists(),
              "state file says %r" % state)
        busy.kill()
        busy.wait()
        waiter.join(timeout=30)
        check("busy process gone: the pair loads and the request is answered", res[-1][0] == 200 and n_calls("up") == ups + 1 and marker.exists(),
              "answered after %.1f s" % (time.time() - t0))
        (run / "busy_patterns").write_text("")

        # idle unload (--idle-min 0.1 = 6 s)
        t0 = time.time()
        downs = n_calls("down")
        while marker.exists() and time.time() - t0 < 20:
            time.sleep(0.5)
        check("idle unload after 0.1 idle minutes", not marker.exists() and n_calls("down") == downs + 1, "unloaded %.1f s after the last request" % (time.time() - t0))

        # a load that fails: the waiting request gets 503 with the reason
        fail_flag.write_text("")
        st, j = request(G, "POST", "/v1/chat/completions", body=chat)
        check("a failed load: 503 with the reason", st == 503 and "fails on purpose" in json.dumps(j), "HTTP %d" % st)
        st, j = request(G, "POST", "/v1/chat/completions", body=chat)
        check("the next request loads again", st == 200 and marker.exists(), "HTTP %d" % st)

        # a server that refuses one request (its engine died a moment ago): the gate looks again and sends it once more
        refuse_once.write_text("")
        t0 = time.time()
        st, j = request(G, "POST", "/v1/chat/completions", body=chat)
        check("a refused request is sent once more, not passed on as 503", st == 200 and not refuse_once.exists(), "HTTP %d after %.1f s" % (st, time.time() - t0))
    finally:
        gate.terminate()
        try:
            gate.wait(timeout=5)
        except subprocess.TimeoutExpired:
            gate.kill()
        if busy is not None and busy.poll() is None:
            busy.kill()
        subprocess.run([str(duo), "down"], capture_output=True)
        stub.shutdown()
        stub.server_close()
        gate_log.close()
    left = subprocess.run(["pgrep", "-f", str(tmp)], capture_output=True, text=True).stdout.split()
    check("nothing of the test is left running", not left, "pids %s" % left if left else "")
    print("gate log:")
    print("  " + (tmp / "gate.log").read_text().strip().replace("\n", "\n  "))
    if not a.keep:
        import shutil
        shutil.rmtree(tmp, ignore_errors=True)
    else:
        print("kept:", tmp)
    print("RESULT: %d of %d checks passed" % (sum(checks), len(checks)))
    sys.exit(0 if all(checks) else 1)


if __name__ == "__main__":
    main()
