"""DS4_DUMP_Y files: list each file's expert sets (row0, rows, experts) of a layer, to compare how two runs batch them."""
import sys, os, struct
FF, D = 2304, 5120
def sets(path):
    out = []; size = os.path.getsize(path); off = 0
    with open(path, 'rb') as f:
        while off + 48 <= size:
            f.seek(off); il, row0, rows, n_exp, kind, mx = struct.unpack('6q', f.read(48))
            out.append((row0, rows, n_exp, kind))
            off += 48 + (n_exp + 1) * 4 + rows * FF * 2 + rows * D * 4
    return out
a, b = sets(sys.argv[1]), sets(sys.argv[2])
print(len(a), "sets in", sys.argv[1], "|", len(b), "in", sys.argv[2])
for i in range(max(len(a), len(b))):
    x = a[i] if i < len(a) else None; y = b[i] if i < len(b) else None
    print(i, x, y, "" if x == y else "<-- differ")
