#!/usr/bin/env python3
"""Point a DeepSeek V4.1 pack at the model files of THIS Mac, or check what it points at.

A pack (the folder with ds4.txt and tensors.txt) holds no weights. ds4.txt names the folder of the model's GGUF files
(`model_dir /absolute/path`), and tensors.txt lists the files in it (`file N name`). The engine opens
model_dir + "/" + name for every listed file at start, including a drafter file it does not use. A name is usually a
plain file name, but a file kept outside the model folder appears as a relative path (`../shared/drafter.gguf`).
After a pack is copied to another Mac, model_dir (and such outside paths) must be made right for that Mac.

  pack_relocate.py PACK                         check: print every file the pack opens, with its size; exit 1 if one is missing
  pack_relocate.py PACK --model-dir DIR         set model_dir to DIR (absolute), then check
  pack_relocate.py PACK --map NAME=PATH ...     also rewrite the `file` line whose path ends in NAME to PATH
                                                (PATH relative to the model folder, or absolute; no spaces)
  pack_relocate.py PACK --model-dir DIR --pull-in
                                                rewrite every outside path to the plain file name when a file of that name
                                                is in DIR (you copied the outside file into the model folder)
  --dry-run                                     say what would change, write nothing

The first change of a file keeps the original beside it as NAME.orig. Nothing else in the pack is touched: the tensor
table refers to files by number. Standard library only; Python 3.9 or newer.
"""
import argparse, os, shutil, sys
from pathlib import Path


def read_ds4(pack):
    lines = (pack / "ds4.txt").read_text(encoding="utf-8").splitlines()
    md = [l[len("model_dir "):] for l in lines if l.startswith("model_dir ")]
    return lines, (md[0] if md else "")


def read_files(pack):
    """The `file N name` lines of tensors.txt, as the engine reads them: [(line number, N, name)]."""
    out = []
    with open(pack / "tensors.txt", "r", encoding="utf-8", errors="replace") as f:
        for no, line in enumerate(f):
            if line.startswith("file "):
                parts = line.split()
                if len(parts) >= 3:
                    out.append((no, int(parts[1]), parts[2]))
    return out


def outside(name):
    return os.path.isabs(name) or os.path.normpath(name).split(os.sep)[0] == ".."


def keep_original(path, dry):
    orig = path.with_name(path.name + ".orig")
    if not orig.exists() and not dry:
        shutil.copy2(path, orig)


def main():
    ap = argparse.ArgumentParser(description="check a DeepSeek V4.1 pack's file references, or point them at this Mac's files")
    ap.add_argument("pack", type=Path)
    ap.add_argument("--model-dir", help="the folder of the model's GGUF files on this Mac (absolute path)")
    ap.add_argument("--map", action="append", default=[], metavar="NAME=PATH", help="new path for the file line that ends in NAME")
    ap.add_argument("--pull-in", action="store_true", help="outside paths become plain names when the file is in the model folder")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    pack = a.pack.expanduser()
    for need in ("ds4.txt", "tensors.txt"):
        if not (pack / need).is_file():
            sys.exit("pack_relocate.py: %s has no %s: not a pack" % (pack, need))
    lines, model_dir = read_ds4(pack)
    files = read_files(pack)
    maps = {}
    for m in a.map:
        if "=" not in m:
            sys.exit("pack_relocate.py: --map wants NAME=PATH")
        k, v = m.split("=", 1)
        if not v or any(c.isspace() for c in v):
            sys.exit("pack_relocate.py: a file path in tensors.txt cannot hold spaces (the engine reads one word): %r" % v)
        maps[k] = v

    changed = False
    if a.model_dir:
        new = os.path.abspath(os.path.expanduser(a.model_dir))
        if not os.path.isdir(new):
            sys.exit("pack_relocate.py: %s is not a folder on this Mac" % new)
        if new != model_dir:
            print("ds4.txt: model_dir %s -> %s" % (model_dir or "(none)", new))
            out = [("model_dir " + new) if l.startswith("model_dir ") else l for l in lines]
            if not any(l.startswith("model_dir ") for l in lines):
                out.append("model_dir " + new)
            if not a.dry_run:
                keep_original(pack / "ds4.txt", False)
                tmp = pack / "ds4.txt.tmp"
                tmp.write_text("\n".join(out) + "\n", encoding="utf-8")
                os.replace(tmp, pack / "ds4.txt")
            model_dir, changed = new, True

    rewrite = {}   # line number -> new name
    for no, idx, name in files:
        new = None
        for k, v in maps.items():
            if name == k or name.endswith("/" + k):
                new = v
        if new is None and a.pull_in and outside(name) and model_dir and os.path.isfile(os.path.join(model_dir, os.path.basename(name))):
            new = os.path.basename(name)
        if new is not None and new != name:
            print("tensors.txt: file %d %s -> %s" % (idx, name, new))
            rewrite[no] = (idx, new)
    unused = [k for k in maps if not any(n == k or n.endswith("/" + k) for _, _, n in files)]
    if unused:
        sys.exit("pack_relocate.py: --map names no file of this pack: %s" % ", ".join(unused))
    if rewrite:
        changed = True
        if not a.dry_run:
            keep_original(pack / "tensors.txt", False)
            tmp = pack / "tensors.txt.tmp"
            with open(pack / "tensors.txt", "r", encoding="utf-8", errors="surrogateescape") as src, \
                    open(tmp, "w", encoding="utf-8", errors="surrogateescape") as dst:
                for no, line in enumerate(src):
                    if no in rewrite:
                        line = "file %d %s\n" % rewrite[no]
                    dst.write(line)
            os.replace(tmp, pack / "tensors.txt")
            files = read_files(pack)
        else:
            files = [(no, idx, rewrite[no][1] if no in rewrite else name) for no, idx, name in files]
    if a.dry_run and changed:
        print("(dry run: nothing was written)")

    print("pack      %s" % pack)
    print("model_dir %s%s" % (model_dir or "(none)", "" if model_dir and os.path.isdir(model_dir) else "   <-- NOT A FOLDER ON THIS MAC"))
    missing = 0
    for _, idx, name in files:
        p = os.path.join(model_dir, name)
        note = "   (outside the model folder: must exist at this path on this Mac)" if outside(name) else ""
        if os.path.isfile(p):
            print("  file %d  %15d bytes  %s%s" % (idx, os.path.getsize(p), name, note))
        else:
            missing += 1
            print("  file %d  MISSING                %s%s" % (idx, name, note))
    if missing or not files:
        print("%d of %d files missing: the engine cannot load this pack here" % (missing, len(files)))
        sys.exit(1)
    print("all %d files present (both Macs must show the same names and sizes: duo.sh doctor compares them)" % len(files))


if __name__ == "__main__":
    main()
