#!/usr/bin/env python3
"""No-model security tests of the live gate: framing/auth, slow unload, timeout and failure tolerance."""
import argparse
import http.client
import importlib.util
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

HERE = Path(__file__).resolve().parent


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', type=Path, default=None, help='work folder (default: a temporary one, removed afterwards)')
    ap.add_argument('--port', type=int, default=8198)
    a = ap.parse_args()
    made = a.out is None
    if made:
        a.out = Path(tempfile.mkdtemp(prefix='duo-gate-security.'))
    a.out.mkdir(parents=True, exist_ok=True)
    run = a.out / 'run'
    run.mkdir(exist_ok=True)
    secret = 'security-test-secret-not-in-arguments'
    (run / 'api_key').write_text(secret)
    (run / 'api_key').chmod(0o600)
    stub = a.out / 'duo_stub.py'
    stub.write_text('''#!/usr/bin/env python3
import pathlib,sys,time
p=pathlib.Path(__file__).resolve().parent
with (p/'calls').open('a') as f: f.write(sys.argv[1]+'\\n')
if sys.argv[1]=='down':
    (p/'down_started').touch()
    time.sleep(3)
''')
    stub.chmod(0o700)
    log = (a.out / 'gate.log').open('w')
    cmd = [sys.executable, str(HERE.parent / 'duo_gate.py'), '--listen', str(a.port), '--backend', str(a.port + 1),
           '--run-dir', str(run), '--duo-sh', str(stub), '--idle-min', '0', '--link-port', '0', '--down-timeout', '5']
    gate = subprocess.Popen(cmd, stdout=log, stderr=log)
    failures = []

    def check(name, condition):
        print(('PASS  ' if condition else 'FAIL  ') + name, flush=True)
        if not condition:
            failures.append(name)

    def raw(method, path, headers='', auth=True):
        s = socket.create_connection(('127.0.0.1', a.port), timeout=2)
        s.settimeout(2)
        head = '%s %s HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n' % (method, path)
        if auth:
            head += 'Authorization: Bearer ' + secret + '\r\n'
        s.sendall((head + headers + '\r\n').encode())
        response = s.recv(65536)
        s.close()
        return int(response.split(b' ')[1])

    def request(path):
        c = http.client.HTTPConnection('127.0.0.1', a.port, timeout=10)
        c.request('POST', path, body=b'', headers={'Authorization': 'Bearer ' + secret})
        r = c.getresponse()
        result = r.status, r.read()
        c.close()
        return result

    try:
        for _ in range(50):
            try:
                if raw('GET', '/duo/status', auth=False) == 200:
                    break
            except OSError:
                time.sleep(.1)
        check('authenticate before waiting for an announced body', raw('POST', '/v1/chat/completions', 'Content-Length: 9999999\r\n', False) == 401)
        check('unauthenticated POST /duo/status cannot announce a blocking body', raw('POST', '/duo/status', 'Content-Length: -1\r\n', False) == 401)
        check('status GET never reads an announced body', raw('GET', '/duo/status', 'Content-Length: 99999\r\n', False) == 200)
        for name, headers, expected in [
            ('missing length', '', 411), ('negative length', 'Content-Length: -1\r\n', 411),
            ('malformed length', 'Content-Length: rubbish\r\n', 411),
            ('oversized length', 'Content-Length: 67108865\r\n', 413),
            ('duplicate lengths', 'Content-Length: 0\r\nContent-Length: 1\r\n', 411),
            ('chunked encoding', 'Transfer-Encoding: chunked\r\n', 501),
            ('encoding plus length', 'Transfer-Encoding: chunked\r\nContent-Length: 0\r\n', 501)]:
            check(name + ' refused without reading body', raw('POST', '/v1/chat/completions', headers) == expected)
        check('Expect does not invite unauthorized body', raw('POST', '/v1/chat/completions', 'Expect: 100-continue\r\nContent-Length: 10\r\n', False) == 401)
        check('Expect validates framing before 100 Continue', raw('POST', '/v1/chat/completions', 'Expect: 100-continue\r\nTransfer-Encoding: chunked\r\n') == 501)
        check('bad requests never load the pair', not (a.out / 'calls').exists())
        results = []
        th = threading.Thread(target=lambda: results.append(request('/duo/unload')))
        th.start()
        for _ in range(50):
            if (a.out / 'down_started').exists():
                break
            time.sleep(.05)
        t = time.monotonic()
        check('status remains responsive during slow unload', raw('GET', '/duo/status', auth=False) == 200 and time.monotonic() - t < .5)
        check('second unload while down runs returns 409', request('/duo/unload')[0] == 409)
        # An arriving request must wait for down, not run up concurrently with it.
        waiter_results = []
        wt = threading.Thread(target=lambda: waiter_results.append(request('/v1/chat/completions')))
        wt.start()
        time.sleep(.4)
        check('arriving request waits for unload', wt.is_alive() and (a.out / 'calls').read_text().split() == ['down'])
        th.join(10)
        wt.join(15)
        check('unload finishes then waiting arrival attempts up', bool(results) and results[0][0] == 200 and (a.out / 'calls').read_text().split() == ['down', 'up'])
        ps = subprocess.check_output(['ps', '-axww', '-o', 'command='], text=True)
        check('API key absent from all process arguments', secret not in ps)
    finally:
        gate.terminate()
        gate.wait(5)
        log.close()

    # Deterministic unit tests of the same functions: no real model or subprocess for health probes.
    spec = importlib.util.spec_from_file_location('tested_gate', HERE.parent / 'duo_gate.py')
    g = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(g)
    g.args = argparse.Namespace(duo_sh=stub, up_timeout=.2, down_timeout=.2)
    rc, text = g.run_duo('down')
    check('down subprocess has a deadline and group is reaped', rc == 124 and 'timed out' in text)
    g.forwarding = 1
    g.backend_ok = lambda *args, **kwargs: (_ for _ in ()).throw(AssertionError('must not probe in flight'))
    check('in-flight generation bypasses health probes and reload', g.ensure_loaded() == '')
    g.forwarding = 0
    calls = []
    def probe(*args, **kwargs):
        calls.append(1)
        return len(calls) == 3
    g.backend_ok = probe
    check('two failed probes followed by success do not reload', g.ensure_loaded() == '' and len(calls) == 3 and not g.loading)
    print('RESULT: ' + ('all security checks passed' if not failures else '%d failed: %s' % (len(failures), failures)))
    if made:
        shutil.rmtree(a.out, ignore_errors=True)
    return bool(failures)


if __name__ == '__main__':
    sys.exit(main())
