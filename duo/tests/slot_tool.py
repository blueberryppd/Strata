#!/usr/bin/env python3
"""Slot files by hand, for the negative tests (no engine needed).
  slot_tool.py info FILE.bin|FILE.meta          what the file says of itself
  slot_tool.py adopt SRC.bin DST_DIR ID_FROM.meta    copy SRC.bin (and its .meta) into DST_DIR with the .meta's identity replaced
                                                by ID_FROM.meta's: the server of that identity then OFFERS the slot to the
                                                engine (a start removes a slot whose .meta names another identity), and
                                                Model::slot_load is what has to refuse it
  slot_tool.py recut FILE.bin K                 a Strata Duo blob's cut field rewritten to K (a pair's slot "of another cut")
"""
import shutil, struct, sys
from pathlib import Path


def meta_read(p):
    b = Path(p).read_bytes()
    magic, il = struct.unpack_from("<8sQ", b, 0)
    assert magic == b"DS4META2", magic
    ident = b[16:16 + il].decode()
    off = 16 + il
    nbytes, nt = struct.unpack_from("<QQ", b, off)
    off += 16
    toks = b[off:off + 4 * nt]
    off += 4 * nt
    (nc,) = struct.unpack_from("<Q", b, off)
    cks = struct.unpack_from("<%dq" % nc, b, off + 8)
    return ident, nbytes, toks, list(cks)


def meta_write(p, ident, nbytes, toks, cks):
    i = ident.encode()
    Path(p).write_bytes(b"DS4META2" + struct.pack("<Q", len(i)) + i + struct.pack("<QQ", nbytes, len(toks) // 4) + toks +
                        struct.pack("<Q", len(cks)) + struct.pack("<%dq" % len(cks), *cks) + b"DS4META2")


def info(p):
    if str(p).endswith(".meta"):
        ident, nbytes, toks, cks = meta_read(p)
        print(f"{Path(p).name}: meta, .bin of {nbytes} bytes, {len(toks) // 4} tokens, restore points {cks}\n  identity: ...{ident[-90:]}")
        return
    b = Path(p).read_bytes()
    if b[:8] == b"DS4DUOS1":
        _, cut, nl, pos, mine, theirs = struct.unpack_from("<6Q", b, 0)
        il = struct.unpack_from("<Q", b, 56)[0]
        print(f"{Path(p).name}: {len(b)} bytes, Strata Duo blob: cut {cut} of {nl} layers, position {pos}, suffix half {mine} bytes, prefix half {theirs} bytes, "
              f"ends {b[-8:]!r}\n  suffix half's identity: ...{b[64:64 + il].decode()[-60:]}")
    elif b[:8] == b"DS4SLOT1":
        il = struct.unpack_from("<Q", b, 8)[0]
        pos = struct.unpack_from("<Q", b, 16 + il)[0]
        print(f"{Path(p).name}: {len(b)} bytes, one host's slot: position {pos}, ends {b[-8:]!r}\n  identity: ...{b[16:16 + il].decode()[-60:]}")
    else:
        print(f"{Path(p).name}: not a slot ({b[:8]!r})")


if sys.argv[1] == "info":
    info(sys.argv[2])
elif sys.argv[1] == "adopt":
    src, dst, idf = Path(sys.argv[2]), Path(sys.argv[3]), sys.argv[4]
    dst.mkdir(parents=True, exist_ok=True)
    shutil.copy(src, dst / src.name)
    _, nbytes, toks, cks = meta_read(src.with_suffix(".meta"))
    meta_write(dst / src.with_suffix(".meta").name, meta_read(idf)[0], nbytes, toks, cks)
    info(dst / src.name)
    info(dst / src.with_suffix(".meta").name)
elif sys.argv[1] == "recut":
    p = Path(sys.argv[2])
    b = bytearray(p.read_bytes())
    assert b[:8] == b"DS4DUOS1"
    struct.pack_into("<Q", b, 8, int(sys.argv[3]))
    p.write_bytes(b)
    info(p)
