#!/usr/bin/env python3
"""Search a runtime preset of the two shared 16x8-bit Sobol buses that makes the
UNCHANGED pe_peripheral.sv comparators emit Booth 2x8 digit-grid patterns:
for every k, A codes give ones on {}, R0_k (the 8 lowest thresholds) or all 16;
W codes give ones on the first c pairs of W's threshold ranking, and every W
pair holds one R0_k and one non-R0_k position, so |A & W| = |d_a| * |d_w|.
Simulated annealing over the 32 preset bytes; cost 0 = valid preset.
The preset found with seed 1 (first restart) is embedded and exhaustively
verified in model_weight_outer_horner.py.  Rerun if SCRAMBLE strides, salts,
K or M change.  Usage: python3 sweeps/int_mode/search_booth_comparator_preset.py [seed]
"""
import random, sys
K, M = 8, 16
SK, SM = 159, 99
def mask(k, m, salt): return (k*SK + m*SM + salt) & 255
MA = [[mask(k, m, 0) for m in range(M)] for k in range(K)]
MW = [[mask(k, m, 128) for m in range(M)] for k in range(K)]

def cost(rA, rW):
    c = 0
    for k in range(K):
        ta = [rA[m] ^ MA[k][m] for m in range(M)]
        tw = [rW[m] ^ MW[k][m] for m in range(M)]
        sa = sorted(range(M), key=lambda m: ta[m])
        R0 = set(sa[:8])
        if ta[sa[7]] == ta[sa[8]]: c += 4
        if max(ta) == 255: c += 4
        if max(tw) == 255: c += 4
        sw = sorted(range(M), key=lambda m: tw[m])
        for p in range(8):
            x, y = sw[2*p], sw[2*p+1]
            if (x in R0) == (y in R0): c += 1
            if p < 7 and tw[sw[2*p+1]] == tw[sw[2*p+2]]: c += 2
    return c

seed = int(sys.argv[1]) if len(sys.argv) > 1 else 1
rng = random.Random(seed)
best = None
for restart in range(200):
    rA = [rng.randrange(256) for _ in range(M)]
    rW = [rng.randrange(256) for _ in range(M)]
    c = cost(rA, rW)
    T = 2.0
    for it in range(40000):
        side = rng.random() < 0.5
        r = rA if side else rW
        m = rng.randrange(M)
        old = r[m]
        if rng.random() < 0.5:
            r[m] = rng.randrange(256)
        else:
            r[m] ^= 1 << rng.randrange(8)
        c2 = cost(rA, rW)
        if c2 <= c or rng.random() < pow(2.718, (c - c2) / T):
            c = c2
        else:
            r[m] = old
        T = max(0.05, T * 0.9997)
        if c == 0:
            break
    if best is None or c < best[0]:
        best = (c, rA[:], rW[:])
    print("restart", restart, "cost", c, flush=True)
    if c == 0:
        print("FOUND rA", rA, "rW", rW)
        break
print("best", best)
