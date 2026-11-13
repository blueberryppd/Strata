#!/usr/bin/env python3
"""Conversation slots (a conversation set aside and taken back) through strata_ds4 --serve: one process, or a Strata Duo
pair over loopback.  Prints each turn's output-ids hash, the tokens reused, and the engine's lines about slots.

usage: slots_test.py single|duo LABEL SCENARIO [PORT]
SCENARIO  inter    A1, B1, A2 (continues A), B2 (continues B), A3 (A's first MARK tokens + other text: the kept A comes back
                   at its restore point MARK), B3 (continues B)
          persist1 A1, then QUIT (the conversation is written to the folder)
          persist2 A2 with a fresh engine (or pair) and the same folder  (reads <out>/logs/STATE.a1.json: STATE= names
                   the persist1 run whose answer A2 continues, default LABEL with 2 -> 1)
          shared   C1 with shared=MARK (the start kept apart: slot_save at a restore point), D1 (unrelated), E1 (C's start +
                   other text: the kept start comes back), E2 (continues E)
environment: LONG (A's first prompt's tokens, 1400), LONGB (B's, 1300), MARK (1000), KEEP (1: STRATA_DS4_SLOT_KEEP=1; 0: slots off),
  SLOT_DIR (<out>/slots/LABEL), LINK (insecure | tls with DUO_TEST_CERTS), CHUNK (1024), EXTRA (more engine flags),
  WORKER_ENV ("K=V ..." for the prefix host only), GEN_TOKENS (24);
  DUO_TEST_EXE (the engine; default build-duo/strata_ds4 of this checkout), DUO_TEST_PACK (a pack folder), DUO_TEST_TEXT
  (a UTF-8 text file of 135,000 characters or more), DUO_TEST_OUT (logs, results, slot folders; default duo/tests/out).
The test refuses to run when this Mac's swap has grown by more than 500 MB since its first run (<out>/swap_base.txt):
two engines on one Mac are heavy, and a Mac that is already swapping gives slow and misleading runs.
Run with a Python that has the `regex` package (Strata's own Python does).
"""
import hashlib, json, os, re, subprocess, sys, time
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
TEXT = env_path("DUO_TEST_TEXT", what="a UTF-8 text file of 135,000 characters or more")
OUT = env_path("DUO_TEST_OUT", T / "out")
SWAP_BASE = OUT / "swap_base.txt"


def swap_used():
    return float(re.search(r"used = ([0-9.]+)M", subprocess.check_output(["sysctl", "-n", "vm.swapusage"], text=True)).group(1))


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
    mode, label, scen = sys.argv[1], sys.argv[2], sys.argv[3]
    port = sys.argv[4] if len(sys.argv) > 4 else "50140"
    OUT.mkdir(parents=True, exist_ok=True)
    used = swap_used()
    if not SWAP_BASE.exists():
        SWAP_BASE.write_text(str(used))
    base = float(SWAP_BASE.read_text())
    # swap_ack.txt: the reading testing was resumed at, by hand, after a stop and a five-minute wait in which it did not grow
    ack = float((OUT / "swap_ack.txt").read_text()) if (OUT / "swap_ack.txt").exists() else base
    print(f"swap used {used:.0f} MB (first reading {base:.0f} MB, resumed at {ack:.0f} MB)", flush=True)
    if used - max(base, ack) > 500:
        sys.exit("swap grew by more than 500 MB: not running")
    import threading
    peak, stop_sampling = [used], threading.Event()

    pids, mem = [], {}

    def sample():   # (the swap in use, and this run's engines' memory as top counts it)
        while not stop_sampling.wait(3):
            peak[0] = max(peak[0], swap_used())
            for pid in pids:
                try:
                    v = subprocess.check_output(["top", "-l", "1", "-pid", str(pid), "-stats", "mem"], text=True).split()[-1]
                    mb = float(v[:-1]) * {"K": 1 / 1024, "M": 1, "G": 1024}.get(v[-1], 0)
                    mem[pid] = max(mem.get(pid, 0), mb)
                except (subprocess.CalledProcessError, ValueError, IndexError):
                    pass
    threading.Thread(target=sample, daemon=True).start()
    gen = int(os.environ.get("GEN_TOKENS", "24"))
    la, lb, mark = int(os.environ.get("LONG", "1400")), int(os.environ.get("LONGB", "1300")), int(os.environ.get("MARK", "1000"))
    chunk = os.environ.get("CHUNK", "1024")
    keep = os.environ.get("KEEP", "1") != "0"
    tok = tokenizer(PK)
    text = TEXT.read_text(encoding="utf-8")
    if len(text) < 135000:
        sys.exit("DUO_TEST_TEXT is shorter than 135,000 characters")
    body = tok.encode(text[:60000], parse_special=False)
    body2 = tok.encode(text[60000:110000], parse_special=False)
    body3 = tok.encode(text[110000:130000], parse_special=False)
    sp = lambda s: tok.encode(s, parse_special=True)
    head = sp("<｜begin▁of▁sentence｜><｜User｜>Here is a design document.\n\n")
    headb = sp("<｜begin▁of▁sentence｜><｜User｜>Read these notes.\n\n")
    tail = sp("\n\nIn two sentences, say what this text is about.<｜Assistant｜></think>")
    ask = lambda s: sp("<｜end▁of▁sentence｜><｜User｜>" + s + "<｜Assistant｜></think>")
    a1 = head + body[:la - len(head) - len(tail)] + tail
    b1 = headb + body2[:lb - len(headb) - len(tail)] + tail
    common = ["--max-context", "8192", "--ssd-cache", "0", "--profile-readonly", "--prefill-chunk", chunk, "--vram-experts", "0.0",
              "--dspark", "none", "--vision", "off"] + os.environ.get("EXTRA", "--no-expert-cache").split()
    env = dict(os.environ)
    env.setdefault("DS4_SUM_BY_EXPERT", "1")
    env.setdefault("DS4_SPEC_WASTE", "1e9")
    slot_dir = Path(os.environ.get("SLOT_DIR", OUT / "slots" / label))
    for k in ("STRATA_DS4_SLOT_KEEP", "STRATA_DS4_SLOT_DIR"):
        env.pop(k, None)
    if keep:
        slot_dir.mkdir(parents=True, exist_ok=True)
        env["STRATA_DS4_SLOT_KEEP"], env["STRATA_DS4_SLOT_DIR"] = "1", str(slot_dir)
    link = ["--duo-certs", str(env_path("DUO_TEST_CERTS", T / "out" / "certs"))] if os.environ.get("LINK", "insecure") == "tls" else ["--duo-insecure"]
    logs = OUT / "logs"
    logs.mkdir(parents=True, exist_ok=True)
    worker = None
    if mode == "duo":
        wenv = dict(env)
        for kv in os.environ.get("WORKER_ENV", "").split():
            wenv[kv.split("=", 1)[0]] = kv.split("=", 1)[1]
        wl = open(logs / f"{label}.worker.log", "w")
        worker = subprocess.Popen([str(EXE), "--pack", str(PK)] + common + ["--duo-cut", os.environ.get("WCUT", "20"), "--duo-listen", f"127.0.0.1:{port}",
                                  "--duo-allow", "127.0.0.1"] + link, stdout=wl, stderr=subprocess.STDOUT, cwd=str(EXE.parent), env=wenv)
        for _ in range(600):
            if "waiting on" in (logs / f"{label}.worker.log").read_text(errors="replace") or worker.poll() is not None:
                break
            time.sleep(1)
        common += ["--duo-cut", os.environ.get("CUT", "20"), "--duo-connect", f"127.0.0.1:{port}"] + link
    el = open(logs / f"{label}.serve.log", "w")
    eng = subprocess.Popen([str(EXE), "--pack", str(PK), "--serve"] + common, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=el,
                           cwd=str(EXE.parent), env=env, text=True, encoding="utf-8", errors="replace")
    pids.extend([eng.pid] + ([worker.pid] if worker is not None else []))
    res = {"label": label, "mode": mode, "scenario": scen, "chunk": chunk, "keep": keep, "link": link[0], "exe": EXE.name,
           "env": {k: v for k, v in env.items() if k.startswith("DS4_")}, "turns": [], "notes": []}
    try:
        for line in eng.stdout:
            if line.startswith("NOTE"):
                res["notes"].append(line.strip())
                print("   " + line.strip(), flush=True)
            if line.startswith("READY"):
                break

        def turn(name, ids, keys=""):
            t0 = time.time()
            eng.stdin.write(f"GEN {gen} temperature=0 top_k=1 {keys}{','.join(map(str, ids))}\n")
            eng.stdin.flush()
            out, done, notes = [], None, []
            for line in eng.stdout:
                if line.startswith("T "):
                    out.append(int(line.split()[1]))
                elif line.startswith("NOTE"):
                    notes.append(line.strip())
                elif line.startswith("DONE") or line.startswith("ERR"):
                    done = line.strip()
                    if line.startswith("DONE"):
                        break
            f = (done or "").split()
            rec = {"turn": name, "prompt_tokens": len(ids), "out_tokens": len(out),
                   "ids_sha": hashlib.sha256(",".join(map(str, out)).encode()).hexdigest()[:16],
                   "reused": int(f[8]) if len(f) > 8 and f[0] == "DONE" else None,
                   "prompt_ms": float(f[3]) if len(f) > 3 and f[0] == "DONE" else None, "wall_s": round(time.time() - t0, 2),
                   "done": done, "notes": notes, "text": tok.decode(out)[:100]}
            res["turns"].append(rec)
            print(json.dumps(rec, ensure_ascii=False), flush=True)
            return out

        more_a = ask("Now name the main topic of this second part.\n\n" + text[130000:131500])
        if scen == "inter":
            oa1 = turn("A1", a1, f"marks={mark} ")
            ob1 = turn("B1", b1)
            a2 = a1 + oa1 + more_a
            oa2 = turn("A2 continues A", a2)
            b2 = b1 + ob1 + ask("Shorter, please.")
            ob2 = turn("B2 continues B", b2)
            a3 = a1[:mark] + body3[:300] + tail
            turn(f"A3 leaves A at {mark}", a3)
            turn("B3 continues B", b2 + ob2 + ask("And in one word?"))
        elif scen == "persist1":
            oa1 = turn("A1", a1, f"marks={mark} ")
            (logs / f"{label}.a1.json").write_text(json.dumps(oa1))
        elif scen == "persist2":
            state = os.environ.get("STATE", label.replace("2", "1"))
            oa1 = json.loads((logs / f"{state}.a1.json").read_text())
            oa2 = turn("A2 continues A (fresh engine)", a1 + oa1 + more_a)
            turn(f"A3 leaves A at {mark}", a1[:mark] + body3[:300] + tail)
        elif scen == "shared":
            c1 = a1[:mark] + body3[300:300 + la - mark - len(tail)] + tail
            turn(f"C1 shared={mark}", c1, f"shared={mark} ")
            turn("D1 unrelated", b1)
            e1 = a1[:mark] + body3[900:1200] + tail
            oe1 = turn("E1 behind C's start", e1, f"shared={mark} ")
            turn("E2 continues E", e1 + oe1 + ask("Shorter, please."))
        elif scen == "fail":   # (the prefix host refuses or fails, WORKER_ENV=DS4_DUO_SLOT_TEST=n: the answers are what they are without slots)
            oa1 = turn("A1", a1, f"marks={mark} ")
            ob1 = turn("B1", b1)
            turn("A2 continues A", a1 + oa1 + more_a)
            turn("B2 continues B", b1 + ob1 + ask("Shorter, please."))
        elif scen == "cont":   # every conversation the folder's .meta files name, continued (CONT: the .meta files, in order)
            import struct
            for mp in os.environ["CONT"].split():
                bts = Path(mp).read_bytes()
                il = struct.unpack_from("<Q", bts, 8)[0]
                nt = struct.unpack_from("<Q", bts, 24 + il)[0]
                ids = list(struct.unpack_from("<%di" % nt, bts, 32 + il))
                turn(f"continues {Path(mp).name} ({nt} tokens)", ids + ask("Shorter, please."))
        else:
            sys.exit("unknown scenario")
        eng.stdin.write("QUIT\n")
        eng.stdin.flush()
        for line in eng.stdout:
            if line.startswith("NOTE"):
                res["notes"].append(line.strip())
                print("   " + line.strip(), flush=True)
        eng.wait(timeout=180)
    finally:
        if eng.poll() is None:
            eng.kill()
        if worker is not None:
            try:
                worker.wait(timeout=60)
            except subprocess.TimeoutExpired:
                worker.kill()
    res["rc"] = [eng.returncode, worker.returncode if worker is not None else None]
    res["all_sha"] = hashlib.sha256("|".join(t["ids_sha"] for t in res["turns"]).encode()).hexdigest()[:16]
    if keep:
        res["slot_files"] = {p.name: [p.stat().st_size, hashlib.sha256(p.read_bytes()).hexdigest()[:16]] for p in sorted(slot_dir.glob("slot-*.bin"))}
        print("slot files", json.dumps(res["slot_files"]))
    stop_sampling.set()
    res["swap"] = {"before": used, "peak": peak[0], "after": swap_used(), "engine_mem_peak_mb": [round(mem.get(q, 0)) for q in pids]}
    print("swap MB", json.dumps(res["swap"]))
    with open(OUT / "slots_results.jsonl", "a", encoding="utf-8") as f:
        f.write(json.dumps(res, ensure_ascii=False) + "\n")
    print("rc", res["rc"], "all_sha", res["all_sha"])


if __name__ == "__main__":
    main()
