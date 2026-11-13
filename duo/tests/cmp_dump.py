"""Compare DS4_DUMP_L files: single-process run against the Duo worker's + coordinator's (records [layer, p0, T] int64 + T*hc*dim float32)."""
import sys, numpy as np, os
HD = 4 * 5120
def index(path):
    out, order = {}, []
    size = os.path.getsize(path); off = 0
    with open(path, 'rb') as f:
        while off + 24 <= size:
            f.seek(off); il, p0, T = np.frombuffer(f.read(24), dtype=np.int64)
            key = (int(il), int(p0), int(T))
            out[key] = off + 24; order.append(key)
            off += 24 + int(T) * HD * 4
    return out, order
s, order = index(sys.argv[1])
parts = [(p, index(p)[0]) for p in sys.argv[2:]]
mm = {p: np.memmap(p, dtype=np.uint8, mode='r') for p in [sys.argv[1]] + sys.argv[2:]}
def rec(p, off, T): return np.frombuffer(mm[p], dtype=np.float32, count=T * HD, offset=off).reshape(T, HD)
nd = 0
for key in order:
    il, p0, T = key
    hit = [(p, ix[key]) for p, ix in parts if key in ix]
    if not hit:
        print("missing", key); continue
    a = rec(sys.argv[1], s[key], T); b = rec(hit[0][0], hit[0][1], T)
    if not np.array_equal(a, b):
        d = np.abs(a - b); rows = np.nonzero(d.max(axis=1) > 0)[0]
        print(f"DIFF layer {il} p0 {p0} T {T}: max {d.max():.3g}, {len(rows)} rows differ, first {rows[:5]} last {rows[-3:]}")
        nd += 1
        if nd > 12: break
print("records", len(order), "differing shown", nd)
