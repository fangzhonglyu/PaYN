#!/usr/bin/env python3
"""A/B check for the INT->SC transition: int_to_sc_A and int_to_sc_B differ only in
the raw planes launched on the last INT edge (B: random, A: zero).  The SC suffix
(same seed, same junk) ends with an 8-edge SC drain; if the INT mode leaves nothing
behind in the SC datapath, the drained SC columns must be identical.
Usage: bpv_ab_sc_tail.py DIR_A DIR_B   (exit 0 identical, 1 different)"""
import sys
from pathlib import Path
a, b = Path(sys.argv[1]), Path(sys.argv[2])
ta = (a / "bpv_trace.txt").read_text().split("\n")
tb = (b / "bpv_trace.txt").read_text().split("\n")
va = (a / "bpv_vec.hex").read_text().split("\n")
n = int(va[0])
recs = [int(x, 16) for x in va[1:1 + n]]
# SC-drain edges: int_mode (bit 1) = 0 and shift_in (bit 4) = 1, the last 8 of them
drains = [i for i, r in enumerate(recs) if not (r >> 1) & 1 and (r >> 4) & 1][-8:]
diff = [(i, ta[i].split()[2], tb[i].split()[2]) for i in drains if ta[i].split()[2] != tb[i].split()[2]]
OW = 24
def tiles(h):
    v = int(h, 16)
    return [((v >> (k * OW)) & 0xFFFFFF) - (1 << OW) * (((v >> (k * OW)) >> 23) & 1) for k in range(8)]
for i, x, y in diff[:3]:
    print(f"  SC drain edge {i}: A {tiles(x)}\n                   B {tiles(y)}")
print(f"{'[DIFF]' if diff else '[SAME]'} {len(diff)}/{len(drains)} SC drain columns differ")
sys.exit(1 if diff else 0)
