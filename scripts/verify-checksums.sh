#!/bin/bash
# Compares SHA-256 of every file under SRC with the same relative path under DST.
# Paths are compared after Unicode NFC normalisation (AirBridge normalises names, SPEC §7).
# Usage: verify-checksums.sh SRC DST [subpath...]
set -euo pipefail
exec python3 -I - "$@" <<'PY'
import hashlib, os, sys, unicodedata
src, dst = sys.argv[1], sys.argv[2]
def walk(root):
    out = {}
    for d, dirs, files in os.walk(root):
        dirs[:] = [x for x in dirs if x != ".airbridge-partial"]
        for f in files:
            if f == ".DS_Store": continue
            p = os.path.join(d, f)
            h = hashlib.sha256()
            with open(p, "rb") as fh:
                for chunk in iter(lambda: fh.read(1 << 20), b""): h.update(chunk)
            out[unicodedata.normalize("NFC", os.path.relpath(p, root))] = h.hexdigest()
    return out
a, b = walk(src), walk(dst)
bad = 0
for k, v in sorted(a.items()):
    if k not in b: print("MISSING ", k); bad += 1
    elif b[k] != v: print("MISMATCH", k); bad += 1
for k in sorted(set(b) - set(a)): print("EXTRA   ", k); bad += 1
print(f"{len(a)} source files, {len(b)} destination files, {bad} problems")
sys.exit(1 if bad else 0)
PY
