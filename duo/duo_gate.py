#!/usr/bin/env python3
"""Strata Duo gate: the address clients use (127.0.0.1:8080 by default), in front of the two-Mac pair.

- A request that arrives while the pair is unloaded starts it (duo.sh up) and waits for it, then goes through.
- After --idle-min minutes without a request the pair is unloaded (duo.sh down): both Macs get their memory back.
- GET /v1/models is answered here, so a client sees the model whether it is loaded or not.
- POST /duo/unload (with the key) unloads the pair now, unless a request is in flight or a load is under way (409).
  Another program that needs the memory calls it before it starts.
- GET /duo/status (no key) says whether the pair is loaded.
- Busy patterns: while a process matching one of them runs (pgrep -f), the pair is not loaded and a request waits
  (at most --busy-max-s seconds; then the pair is loaded anyway. 0: wait without a limit). The patterns are read from
  <run-dir>/busy_patterns (one a line), which duo.sh writes from BUSY_PATTERNS in duo.conf.

The gate holds no model and uses a few MB. It checks the same API key as the server behind it (<run-dir>/api_key), so
nothing without the key can make the pair load. Standard library only; Python 3.9 or newer (macOS's /usr/bin/python3).

usage: duo_gate.py [--listen 8080] [--backend 8081] [--idle-min 30] [--run-dir DIR] [--duo-sh PATH] [--model-id NAME]
                   [--engine-role prefix|suffix] [--link-port 50090] [--busy-max-s 2400]
Defaults: --run-dir is run/ beside this file, --duo-sh is duo.sh beside this file.
"""
import argparse, hmac, http.client, json, os, socket, subprocess, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
HOP = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailers", "transfer-encoding", "upgrade",
       "content-length", "host"}

lock = threading.Lock()
cond = threading.Condition(lock)
active = 0                 # requests in flight (through or waiting)
last_done = time.time()    # when the last request ended
loading = False            # duo.sh up is running
load_error = ""            # why the last start failed (shown to the requests that waited for it)
args = None


def log(msg):
    print(time.strftime("%F %T"), msg, flush=True)


def key():
    try:
        return (args.run_dir / "api_key").read_text().strip()
    except OSError:
        return ""


def pgrep(pattern):
    """True when a process other than this gate matches the pattern (pgrep -f)."""
    r = subprocess.run(["pgrep", "-f", pattern], capture_output=True, text=True)
    mine = {str(os.getpid()), str(os.getppid())}
    return any(p not in mine for p in r.stdout.split())


def engine_running():
    """This Mac's engine of the pair, by its role and link port (--link-port 0: not checked)."""
    if args.link_port <= 0:
        return True
    flag = "--duo-listen" if args.engine_role == "prefix" else "--duo-connect"
    return pgrep(r"%s .*%s [0-9.]*:%d( |$)" % (args.engine_name, flag, args.link_port))


def backend_ok(timeout=3.0):
    """The pair is loaded: this Mac's engine runs, and the server behind the gate says the model is there."""
    if not engine_running():
        return False
    try:
        c = http.client.HTTPConnection("127.0.0.1", args.backend, timeout=timeout)
        c.request("GET", "/v1/models", headers={"Authorization": "Bearer " + key()})
        r = c.getresponse()
        body = r.read()
        c.close()
        return r.status == 200 and b'"id"' in body
    except (OSError, http.client.HTTPException):
        return False


def write_state(state):
    try:
        (args.run_dir / "gate_state.json").write_text(json.dumps({"state": state, "since": time.strftime("%F %T"), "idle_min": args.idle_min}))
    except OSError:
        pass


def run_duo(verb):
    try:
        r = subprocess.run([str(args.duo_sh), verb], capture_output=True, text=True, stdin=subprocess.DEVNULL)
    except OSError as e:
        return 127, "cannot run %s: %s" % (args.duo_sh, e)
    tail = "\n".join((r.stdout + r.stderr).strip().splitlines()[-6:])
    return r.returncode, tail


def busy():
    """The first busy pattern that matches a running process ("" when none does)."""
    try:
        lines = (args.run_dir / "busy_patterns").read_text().splitlines()
    except OSError:
        return ""
    for pat in lines:
        pat = pat.strip()
        if pat and not pat.startswith("#") and pgrep(pat):
            return pat
    return ""


def ensure_loaded():
    """Called by a request: returns "" once the pair answers, or the reason it could not be started."""
    global loading, load_error
    if backend_ok():
        return ""
    with cond:
        if not loading:
            loading, load_error = True, ""
            threading.Thread(target=loader, daemon=True).start()
        while loading:
            cond.wait(timeout=5)
        return load_error


def loader():
    global loading, load_error
    log("a request while unloaded: starting the pair")
    waited = 0
    while True:   # (one big job at a time on this Mac: the other one first)
        pat = busy()
        if not pat or (args.busy_max_s > 0 and waited >= args.busy_max_s):
            if pat:
                log("still busy after %d s (%s): loading the pair anyway" % (waited, pat))
            break
        if waited == 0:
            log("busy (a process matches '%s'): the pair loads when it is gone" % pat)
            write_state("waiting")
        time.sleep(args.busy_poll_s)
        waited += args.busy_poll_s
    write_state("loading")
    t0 = time.time()
    rc, tail = run_duo("up")
    ok = rc == 0 and backend_ok(10)
    with cond:
        loading = False
        load_error = "" if ok else ("the pair did not start: " + tail[-600:])
        cond.notify_all()
    write_state("loaded" if ok else "unloaded")
    log("the pair is %s after %.0f s" % ("ready" if ok else "NOT ready", time.time() - t0) + ("" if ok else ": " + tail.replace("\n", " | ")[-300:]))


def idle_watch():
    global last_done
    limit = args.idle_min * 60
    every = min(30.0, max(1.0, limit / 4)) if limit > 0 else 30.0
    while True:
        time.sleep(every)
        if limit <= 0:
            continue
        with lock:
            quiet = active == 0 and not loading and time.time() - last_done >= limit
        if not quiet or not backend_ok():
            continue
        with lock:   # (again under the lock: a request may have come in while the backend was asked)
            if active or loading or time.time() - last_done < limit:
                continue
            log("no request for %g minutes: unloading the pair" % args.idle_min)
            rc, tail = run_duo("down")   # (held under the lock: a request that comes now waits, then loads the pair again)
            last_done = time.time()
        write_state("unloaded")
        log("unloaded" if rc == 0 else "unload failed: " + tail.replace("\n", " | ")[-300:])


class Gate(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *a):
        pass

    def authed(self):
        k = key()
        got = self.headers.get("Authorization", "")
        got = got[7:] if got.lower().startswith("bearer ") else self.headers.get("x-api-key", "")
        return bool(k) and hmac.compare_digest(got.strip().encode(), k.encode())

    def reply(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def handle_any(self):
        global active, last_done
        path = self.path.split("?")[0]
        try:
            n = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            n = -1
        if n < 0 or n > args.max_body_mb * 1048576:
            self.close_connection = True
            return self.reply(413 if n > 0 else 400, {"error": {"type": "invalid_request_error", "message": "bad or too large Content-Length"}})
        body = self.rfile.read(n) if n else b""
        if path == "/duo/status":   # (no key needed: says only whether the pair is loaded)
            with lock:
                idle = int(time.time() - last_done)
                st = {"loaded": None, "loading": loading, "active": active, "idle_s": idle, "idle_min": args.idle_min}
            st["loaded"] = backend_ok()
            return self.reply(200, st)
        if not self.authed():
            return self.reply(401, {"error": {"type": "authentication_error", "message": "missing or wrong API key"}})
        if path == "/duo/unload" and self.command == "POST":
            with lock:
                if active or loading:
                    return self.reply(409, {"error": {"type": "busy", "message": "a request is in flight"}})
                rc, tail = run_duo("down")
                last_done = time.time()
            write_state("unloaded")
            log("unloaded on request" if rc == 0 else "unload on request failed: " + tail.replace("\n", " | ")[-300:])
            return self.reply(200 if rc == 0 else 500, {"unloaded": rc == 0})
        if self.command == "GET" and path in ("/v1/models", "/models"):
            if backend_ok():
                return self.forward(body)   # (loaded: the server's own answer; does not count as use)
            return self.reply(200, {"object": "list", "data": [{"id": args.model_id, "object": "model", "owned_by": "strata-duo",
                                                                "status": {"value": "unloaded"}}]})
        with lock:
            active += 1
        try:
            err = ensure_loaded()
            if err:
                return self.reply(503, {"error": {"type": "unavailable", "message": err}})
            self.forward(body)
        finally:
            with lock:
                active -= 1
                last_done = time.time()

    def forward(self, body):
        up = http.client.HTTPConnection("127.0.0.1", args.backend, timeout=3600)
        headers = {k: v for k, v in self.headers.items() if k.lower() not in HOP}
        if body or self.command in ("POST", "PUT", "PATCH"):
            headers["Content-Length"] = str(len(body))
        try:
            up.request(self.command, self.path, body=body or None, headers=headers)
            r = up.getresponse()
        except (OSError, http.client.HTTPException) as e:
            up.close()
            return self.reply(502, {"error": {"type": "bad_gateway", "message": "the server behind the gate did not answer: %s" % e}})
        try:
            self.send_response(r.status, r.reason)
            length = r.getheader("Content-Length")
            for k, v in r.getheaders():
                if k.lower() not in HOP:
                    self.send_header(k, v)
            if length is not None:
                self.send_header("Content-Length", length)
                self.end_headers()
                while True:
                    chunk = r.read(65536)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
            else:   # a stream (SSE): each piece on as it comes, chunked
                self.send_header("Transfer-Encoding", "chunked")
                self.end_headers()
                while True:
                    chunk = r.read1(65536)
                    if not chunk:
                        break
                    self.wfile.write(b"%x\r\n" % len(chunk) + chunk + b"\r\n")
                    self.wfile.flush()
                self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, socket.timeout):
            self.close_connection = True   # (the client left: closing the upstream below ends the generation there)
        finally:
            up.close()

    do_GET = do_POST = do_PUT = do_DELETE = do_PATCH = do_OPTIONS = do_HEAD = handle_any


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, request, client_address):
        e = sys.exc_info()[1]
        if isinstance(e, (ConnectionResetError, BrokenPipeError, socket.timeout)):
            return   # (the client went away)
        log("request failed: %s: %s" % (type(e).__name__, e))


def main():
    global args
    ap = argparse.ArgumentParser(description="Strata Duo gate: on-demand load and idle unload in front of the pair")
    ap.add_argument("--listen", type=int, default=8080, help="port on 127.0.0.1 that clients use")
    ap.add_argument("--backend", type=int, default=8081, help="port on 127.0.0.1 where the pair's API server answers")
    ap.add_argument("--idle-min", type=float, default=30, help="unload after this many idle minutes (0: never)")
    ap.add_argument("--run-dir", type=Path, default=HERE / "run", help="folder with api_key and busy_patterns; the state file goes here")
    ap.add_argument("--duo-sh", type=Path, default=HERE / "duo.sh", help="the script run with 'up' and 'down'")
    ap.add_argument("--model-id", default="deepseek-v4.1-flash", help="the model name listed while the pair is unloaded")
    ap.add_argument("--engine-role", choices=("prefix", "suffix"), default="prefix", help="this Mac's role in the pair")
    ap.add_argument("--link-port", type=int, default=50090, help="the pair's link port (0: do not look for the engine process)")
    ap.add_argument("--engine-name", default="strata_ds4", help="the engine's program name (tests use a stand-in)")
    ap.add_argument("--busy-max-s", type=int, default=2400, help="longest wait for a busy pattern to clear (0: no limit)")
    ap.add_argument("--busy-poll-s", type=int, default=5, help="seconds between looks at the busy patterns")
    ap.add_argument("--max-body-mb", type=int, default=64, help="largest request body passed on")
    args = ap.parse_args()
    args.run_dir = args.run_dir.expanduser()
    args.busy_poll_s = max(1, args.busy_poll_s)
    srv = Server(("127.0.0.1", args.listen), Gate)
    threading.Thread(target=idle_watch, daemon=True).start()
    write_state("loaded" if backend_ok() else "unloaded")
    log("gate on 127.0.0.1:%d -> 127.0.0.1:%d; unload after %g idle minutes" % (args.listen, args.backend, args.idle_min))
    srv.serve_forever()


if __name__ == "__main__":
    main()
