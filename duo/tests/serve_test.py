#!/usr/bin/env python3
"""Drive strata_ds4 --serve through a conversation that exercises feed_marks / feed_mark / restore, one process or Strata Duo
over loopback, and print each turn's output ids hash.

usage: serve_test.py single|duo LABEL CHUNK [PORT]     (environment variables are passed on to the engines)
environment: DUO_TEST_EXE (the engine; default build-duo/strata_ds4 of this checkout), DUO_TEST_PACK (a pack folder),
  DUO_TEST_TEXT (a UTF-8 text file of 80,000 characters or more: the prompts are cut from it), DUO_TEST_OUT (logs and
  results; default duo/tests/out), LINK (insecure, the default here | tls with DUO_TEST_CERTS).
Turns:  1  a ~1800-token prompt with marks=1000 (a restore point inside the read: feed_marks)
        2  turn 1's prompt + its answer + a ~500-token user message (continues the state: feed_mark over the new tokens)
        3  the first 1200 tokens of turn 1's prompt + other text (leaves the conversation: restore() to the kept point, then a read)
        4  turn 3's prompt + its answer + a short message (continues after a restore; a short read: windows)
STOP_TEST=1: before them, a 3000-token prompt with a STOP sent STOP_DELAY (1.5) seconds behind it (turn 0).  EXTRA: more engine flags.
Run with a Python that has the `regex` package (Strata's own Python does).
"""
import hashlib, json, os, subprocess, sys, time
from pathlib import Path

T = Path(__file__).resolve().parent
ROOT = T.parent.parent
sys.path.insert(0, str(ROOT / "tools"))   # strata_tokenizer.py (needs the `regex` package: Strata's own Python has it)


def env_path(name, default=None, what=""):
    v = os.environ.get(name)
    if not v and default is None:
        sys.exit("%s is not set (%s). See duo/tests/README.md." % (name, what))
    return Path(v or default).expanduser()


EXE = env_path("DUO_TEST_EXE", ROOT / "build-duo" / "strata_ds4")
PK = env_path("DUO_TEST_PACK", what="a DeepSeek V4.1 pack folder")
TEXT = env_path("DUO_TEST_TEXT", what="a UTF-8 text file of 80,000 characters or more")
OUT = env_path("DUO_TEST_OUT", T / "out")


def tokenizer(pack):
    import strata_tokenizer as ST
    t = pack / "tokenizer"
    vocab = json.loads((t / "vocab.json").read_text(encoding="utf-8"))
    tokens = [None] * len(vocab)
    for s, i in vocab.items():
        tokens[i] = s
    merges = (t / "merges.txt").read_text(encoding="utf-8").split("\n")
    types = json.loads((t / "token_type.json").read_text())
    cfg = {}
    try:
        cfg = json.loads((t / "tokenizer.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        pass
    return ST.Tokenizer(tokens, merges, types, cfg.get("pre") or "qwen35", cfg.get("special_ids") or None)


def main():
    mode, label, chunk = sys.argv[1], sys.argv[2], sys.argv[3]
    port = sys.argv[4] if len(sys.argv) > 4 else "50110"
    gen = int(os.environ.get("GEN_TOKENS", "24"))
    tok = tokenizer(PK)
    text = TEXT.read_text(encoding="utf-8")
    if len(text) < 80000:
        sys.exit("DUO_TEST_TEXT is shorter than 80,000 characters")
    body = tok.encode(text[:40000], parse_special=False)
    body2 = tok.encode(text[60000:80000], parse_special=False)
    head = tok.encode("<｜begin▁of▁sentence｜><｜User｜>Here is a design document.\n\n", parse_special=True)
    tail = tok.encode("\n\nIn two sentences, say what this text is about.<｜Assistant｜></think>", parse_special=True)
    p1 = head + body[:1800 - len(head) - len(tail)] + tail
    common = ["--max-context", "8192", "--ssd-cache", "0", "--profile-readonly", "--prefill-chunk", chunk, "--vram-experts",
              os.environ.get("VRAM", "0.0"), "--dspark", "none", "--vision", "off"]
    common += os.environ.get("EXTRA", "").split()   # EXTRA="--no-expert-cache": more engine flags, both hosts
    env = dict(os.environ)
    if chunk == "0":
        env["DS4_NO_CHUNKS"] = "1"
    logs = OUT / "logs"
    logs.mkdir(parents=True, exist_ok=True)
    link = ["--duo-certs", str(env_path("DUO_TEST_CERTS", T / "out" / "certs"))] if os.environ.get("LINK", "insecure") == "tls" else ["--duo-insecure"]
    worker = None
    if mode == "duo":
        wl = open(logs / f"{label}.worker.log", "w")
        worker = subprocess.Popen([str(EXE), "--pack", str(PK)] + common + ["--duo-cut", "20", "--duo-listen", f"127.0.0.1:{port}",
                                  "--duo-allow", "127.0.0.1"] + link, stdout=wl, stderr=subprocess.STDOUT, cwd=str(EXE.parent), env=env)
        for _ in range(600):
            if "waiting on" in (logs / f"{label}.worker.log").read_text(errors="replace") or worker.poll() is not None:
                break
            time.sleep(1)
        common += ["--duo-cut", "20", "--duo-connect", f"127.0.0.1:{port}"] + link
    el = open(logs / f"{label}.serve.log", "w")
    eng = subprocess.Popen([str(EXE), "--pack", str(PK), "--serve"] + common, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=el,
                           cwd=str(EXE.parent), env=env, text=True, encoding="utf-8", errors="replace")
    res = {"label": label, "mode": mode, "chunk": chunk, "env": {k: v for k, v in os.environ.items() if k.startswith("DS4_")},
           "extra": os.environ.get("EXTRA", ""), "stop_test": bool(os.environ.get("STOP_TEST")), "turns": []}
    try:
        for line in eng.stdout:
            if line.startswith("READY"):
                break

        def turn(name, keys, ids):
            eng.stdin.write(f"GEN {gen} temperature=0 top_k=1 {keys}{','.join(map(str, ids))}\n")
            eng.stdin.flush()
            out, done = [], None
            for line in eng.stdout:
                if line.startswith("T "):
                    out.append(int(line.split()[1]))
                elif line.startswith("DONE") or line.startswith("ERR"):
                    done = line.strip()
                    if line.startswith("DONE"):
                        break
            f = (done or "").split()
            rec = {"turn": name, "prompt_tokens": len(ids), "out_tokens": len(out),
                   "ids_sha": hashlib.sha256(",".join(map(str, out)).encode()).hexdigest()[:16], "done": done,
                   "prompt_ms": float(f[3]) if len(f) > 3 and f[0] == "DONE" else None,
                   "reused": int(f[8]) if len(f) > 8 and f[0] == "DONE" else None, "text": tok.decode(out)[:160]}
            res["turns"].append(rec)
            print(json.dumps(rec, ensure_ascii=False), flush=True)
            return out

        if os.environ.get("STOP_TEST"):   # a STOP right after a long prompt is sent: the request ends, then the same turns as without it
            long = head + body[:3000] + tail
            eng.stdin.write(f"GEN {gen} temperature=0 top_k=1 {','.join(map(str, long))}\n")
            eng.stdin.flush()
            t0 = time.time()
            time.sleep(float(os.environ.get("STOP_DELAY", "1.5")))   # (a STOP read before its GEN is taken up is dropped: the read is under way now)
            eng.stdin.write("STOP\n")
            eng.stdin.flush()
            for line in eng.stdout:
                if line.startswith("DONE") or line.startswith("ERR"):
                    rec = {"turn": "0 STOP while a %d-token prompt is read" % len(long), "done": line.strip(), "wall_s": round(time.time() - t0, 2), "ids_sha": "-"}
                    res["turns"].append(rec)
                    print(json.dumps(rec), flush=True)
                    if line.startswith("DONE"):
                        break
        o1 = turn("1 marks=1000, 1800 tokens (feed_marks)", "marks=1000 ", p1)
        more = tok.encode("<｜end▁of▁sentence｜><｜User｜>Now read this second part and name its main topic.\n\n", parse_special=True) \
            + body[2000:2500] + tok.encode("<｜Assistant｜></think>", parse_special=True)
        p2 = p1 + o1 + more
        turn("2 continues (+%d tokens, feed_mark)" % (len(p2) - len(p1) - len(o1)), "", p2)
        p3 = p1[:1200] + body2[:600] + tail
        o3 = turn("3 leaves at 1200 (restore, then a read)", "", p3)
        p4 = p3 + o3 + tok.encode("<｜end▁of▁sentence｜><｜User｜>Shorter, please.<｜Assistant｜></think>", parse_special=True)
        turn("4 continues after the restore (short: windows)", "", p4)
        eng.stdin.write("QUIT\n")
        eng.stdin.flush()
        eng.wait(timeout=120)
    finally:
        if eng.poll() is None:
            eng.kill()
        if worker is not None:
            try:
                worker.wait(timeout=60)
            except subprocess.TimeoutExpired:
                worker.kill()
    res["all_sha"] = hashlib.sha256("|".join(t["ids_sha"] for t in res["turns"]).encode()).hexdigest()[:16]
    with open(OUT / "serve_results.jsonl", "a", encoding="utf-8") as f:
        f.write(json.dumps(res, ensure_ascii=False) + "\n")
    print("all_sha", res["all_sha"])


if __name__ == "__main__":
    main()
