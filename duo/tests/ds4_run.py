#!/usr/bin/env python3
"""Run strata_ds4 one-shot (--ids/--n) and report the output ids, their hash, the text and the timing.

usage: ds4_run.py --exe EXE --pack PACK [--n 48] [--label X] [--out results.jsonl] [--long-file TEXT --long-tokens N]
                  [--env K=V ...] [--ids-out FILE] [-- extra engine flags]
--long-file TEXT --long-tokens N builds a prompt of about N tokens (the file's text cut to fit, then a question);
without it a short built-in prompt is used.  --env K=V sets the engine's environment.
Run with a Python that has the `regex` package (Strata's own Python does); the tokenizer is tools/strata_tokenizer.py
of this checkout.  Results go to --out (default: $DUO_TEST_OUT/results.jsonl, or duo/tests/out/results.jsonl).
"""
import argparse, hashlib, json, os, re, subprocess, sys, tempfile, time
from pathlib import Path

T = Path(__file__).resolve().parent
ROOT = T.parent.parent
sys.path.insert(0, str(ROOT / "tools"))   # strata_tokenizer.py (needs the `regex` package: Strata's own Python has it)


def env_path(name, default=None, what=""):
    v = os.environ.get(name)
    if not v and default is None:
        sys.exit("%s is not set (%s). See duo/tests/README.md." % (name, what))
    return Path(v or default).expanduser()


OUT = env_path("DUO_TEST_OUT", T / "out")
PROMPTS = {
    "code": "<｜begin▁of▁sentence｜><｜User｜>Write a Python function that merges two sorted lists into one sorted list. Include a short docstring and handle empty inputs.<｜Assistant｜></think>",
    "zh": "<｜begin▁of▁sentence｜><｜User｜>用三句话解释为什么海水是咸的。<｜Assistant｜></think>",
}


def tokenizer(pack: Path):
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
    argv = sys.argv[1:]
    extra = []
    if "--" in argv:
        k = argv.index("--")
        argv, extra = argv[:k], argv[k + 1:]
    ap = argparse.ArgumentParser()
    ap.add_argument("--exe", required=True)
    ap.add_argument("--pack", required=True)
    ap.add_argument("--n", type=int, default=48)
    ap.add_argument("--prompt", default="code", choices=list(PROMPTS))
    ap.add_argument("--label", default="")
    ap.add_argument("--out", default=str(OUT / "results.jsonl"))
    ap.add_argument("--timeout", type=int, default=3600)
    ap.add_argument("--long-file", default="")
    ap.add_argument("--long-tokens", type=int, default=3200)
    ap.add_argument("--env", action="append", default=[])
    ap.add_argument("--ids-out", default="")
    a = ap.parse_args(argv)
    pack = Path(a.pack)
    tok = tokenizer(pack)
    if a.long_file:
        head = tok.encode("<｜begin▁of▁sentence｜><｜User｜>Here is a design document.\n\n", parse_special=True)
        tail = tok.encode("\n\nIn three sentences, say what this document is about.<｜Assistant｜></think>", parse_special=True)
        body = tok.encode(Path(a.long_file).read_text(encoding="utf-8")[:60000], parse_special=False)
        ids = head + body[:max(0, a.long_tokens - len(head) - len(tail))] + tail
    else:
        ids = tok.encode(PROMPTS[a.prompt], parse_special=True)
    if a.ids_out:
        Path(a.ids_out).write_text(",".join(str(i) for i in ids), encoding="ascii")
    env = dict(os.environ)
    for kv in a.env:
        k, _, v = kv.partition("=")
        env[k] = v
    with tempfile.TemporaryDirectory() as d:
        f = Path(d) / "ids.txt"
        f.write_text(",".join(str(i) for i in ids), encoding="ascii")
        cmd = [a.exe, "--pack", str(pack), "--ids", "@" + str(f), "--n", str(a.n), "--dspark", "none", "--vision", "off"] + extra
        t0 = time.time()
        r = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=a.timeout,
                           cwd=str(Path(a.exe).parent), env=env)
        wall = time.time() - t0
    err = (r.stderr or "").strip().splitlines()
    out_lines = (r.stdout or "").strip().splitlines()
    out = [int(x) for x in re.findall(r"-?\d+", out_lines[-1])] if out_lines else []
    speed = [l for l in err if re.search(r"tok/s|tokens/s|t/s|^duo |^forward_chunks|^ds4 prompt stream", l)]
    rec = {"label": a.label, "exe": Path(a.exe).name, "pack": pack.name, "prompt": a.prompt, "n": a.n, "extra": extra, "rc": r.returncode,
           "wall_s": round(wall, 1), "prompt_tokens": len(ids), "out_tokens": len(out),
           "ids_sha": hashlib.sha256(",".join(map(str, out)).encode()).hexdigest()[:16],
           "text": tok.decode(out)[:400] if out else "", "speed_lines": [l[:400] for l in speed[-12:]], "env": a.env, "stderr_tail": err[-12:]}
    Path(a.out).parent.mkdir(parents=True, exist_ok=True)
    with open(a.out, "a", encoding="utf-8") as fo:
        fo.write(json.dumps(rec, ensure_ascii=False) + "\n")
    print(json.dumps({k: rec[k] for k in ("label", "rc", "wall_s", "out_tokens", "ids_sha", "text", "speed_lines")}, ensure_ascii=False, indent=1))
    if r.returncode != 0:
        print("\n".join(err[-12:]))


if __name__ == "__main__":
    main()
