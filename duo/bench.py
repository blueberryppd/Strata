#!/usr/bin/env python3
"""Sustained decode benchmark against an OpenAI-compatible server (the Strata Duo gate, or any Strata server).

Sends ROUNDS chat requests one after another (mixed English and Chinese prompts, N generated tokens each,
temperature 0) and prints one JSON line a request: tokens, wall time, tokens/s, and this Mac's page-ins.
The speed of a run is total tokens / total wall time (prompt reading included); the last line prints it.

usage: bench.py --key-file FILE [--url http://127.0.0.1:8080] [--model deepseek-v4.1-flash] [--n 400] [--rounds 5]
                [--label X] [--offset 0] [--out FILE.jsonl]
The API key is read from --key-file (or the file named by STRATA_DUO_KEY_FILE): it is never a command-line argument.
Standard library only; Python 3.9 or newer.
"""
import argparse, json, os, re, subprocess, sys, time, urllib.request

PROMPTS = [
    "Write a Python class implementing an LRU cache with get and put, with comments explaining each step.",
    "详细解释 TCP 三次握手和四次挥手的过程，并说明为什么需要这样设计。",
    "Write a bash script that finds the ten largest files under a directory and prints their sizes in human-readable form. Explain each line.",
    "用 Python 写一个简单的命令行待办事项程序，支持添加、列出、完成和删除，数据保存在 JSON 文件里。",
    "Explain how garbage collection works in Java, covering generations, minor and major collections, and common tuning flags.",
    "写一篇 300 字左右的短文，介绍雷雳 5 接口相比雷雳 4 的主要改进。",
    "Write a SQL schema and three example queries for a small library management system.",
    "解释什么是混合专家模型（MoE），以及它为什么能在保持质量的同时降低推理成本。",
]


def pageins():
    out = subprocess.run(["vm_stat"], capture_output=True, text=True).stdout
    m = re.search(r"Pageins:\s+(\d+)", out)
    return int(m.group(1)) if m else 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://127.0.0.1:8080", help="the server's base URL")
    ap.add_argument("--key-file", default=os.environ.get("STRATA_DUO_KEY_FILE", ""), help="file holding the API key")
    ap.add_argument("--model", default="deepseek-v4.1-flash")
    ap.add_argument("--n", type=int, default=400, help="tokens generated a request")
    ap.add_argument("--rounds", type=int, default=5)
    ap.add_argument("--label", default="")
    ap.add_argument("--offset", type=int, default=0, help="first prompt's index")
    ap.add_argument("--out", default="", help="append one JSON line a request to this file")
    ap.add_argument("--timeout", type=int, default=900)
    a = ap.parse_args()
    if not a.key_file:
        sys.exit("bench.py: --key-file FILE (or STRATA_DUO_KEY_FILE) is needed")
    with open(os.path.expanduser(a.key_file)) as f:
        key = f.read().strip()
    page = int(subprocess.run(["sysctl", "-n", "hw.pagesize"], capture_output=True, text=True).stdout or 16384)
    tokens, wall = 0, 0.0
    for i in range(a.rounds):
        p = PROMPTS[(i + a.offset) % len(PROMPTS)]
        body = json.dumps({"model": a.model, "messages": [{"role": "user", "content": p}],
                           "max_tokens": a.n, "temperature": 0}).encode()
        req = urllib.request.Request(a.url.rstrip("/") + "/v1/chat/completions", data=body,
                                     headers={"Content-Type": "application/json", "Authorization": "Bearer " + key})
        p0, t0 = pageins(), time.time()
        with urllib.request.urlopen(req, timeout=a.timeout) as resp:
            r = json.load(resp)
        dt = time.time() - t0
        pin = (pageins() - p0) * page / 1e6
        n = (r.get("usage") or {}).get("completion_tokens", 0)
        tokens, wall = tokens + n, wall + dt
        mem = (subprocess.run(["memory_pressure"], capture_output=True, text=True).stdout.strip().splitlines() or [""])[-1]
        rec = {"label": a.label, "round": i, "out": n, "wall_s": round(dt, 1), "tok_s": round(n / dt, 2),
               "pagein_mb": round(pin), "pagein_mb_per_tok": round(pin / max(1, n), 1),
               "free": mem.split(":")[-1].strip(), "ts": time.strftime("%H:%M:%S")}
        if a.out:
            with open(os.path.expanduser(a.out), "a", encoding="utf-8") as f:
                f.write(json.dumps(rec, ensure_ascii=False) + "\n")
        print(json.dumps(rec, ensure_ascii=False), flush=True)
    if wall > 0:
        print("overall: %d tokens in %.1f s = %.2f tokens/s over %d rounds" % (tokens, wall, tokens / wall, a.rounds))


if __name__ == "__main__":
    main()
