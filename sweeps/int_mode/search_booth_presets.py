#!/usr/bin/env python3
"""Find constants for the shared Sobol random_values bus that make the UNCHANGED
edge comparators (designs/payn/pe_peripheral.sv) emit the Booth 2x8 digit-grid
patterns used by sweeps/int_mode/model_spatial_fixed_weight.py.

Comparator: bit[k][m] = code[k] > (r[m] ^ MASK(k, m, salt)), MASK fixed at
compile time.  Required, for every lane k = 0..7:
  3-level side (radix-4 digit |da| in 0..2): a strict gap between the 8th and
    9th smallest threshold, max threshold <= 254 (so code 255 lights all 16);
    L_k = the 8 lowest positions = "row 0" of the 2x8 grid.
  9-level side (radix-16 digit |dw| in 0..8): strict gaps after ranks 2,4,..,14,
    max <= 254, and every consecutive rank pair (2c-1, 2c) holds exactly one
    position of L_k (= one cell per grid row in column c).
Then popcount(a & w) = |da| * |dw| exactly (certified in the model, part 0).

Also reports two negative results:
  * no native Sobol state (t = 0..599, both banks stepping together) works,
    so a preset is required;
  * a k-independent "binned" code (code = 32*|dw|, |da| -> 128) is not found,
    so per-lane code tables are required on the 9-level side.
No EDA tools.  Usage: python3 sweeps/int_mode/search_booth_presets.py [--binned]
"""
import math
import random
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from check_comparator_unary import BANKS, lane_shift, sobol_states  # noqa: E402

K, M = 8, 16
SK, SM = ((256 * 79) // 128) | 1, ((256 * 49) // 128) | 1


def mask(k, m, salt):
    return (k * SK + m * SM + salt) & 255


def violations(r3, r9, s3, s9):
    c = 0
    for k in range(K):
        t3 = [r3[m] ^ mask(k, m, s3) for m in range(M)]
        t9 = [r9[m] ^ mask(k, m, s9) for m in range(M)]
        o3 = sorted(range(M), key=lambda m: t3[m])
        o9 = sorted(range(M), key=lambda m: t9[m])
        c += (t3[o3[7]] >= t3[o3[8]]) + (max(t3) >= 255) + (max(t9) >= 255)
        low = set(o3[:8])
        c += sum(t9[o9[2 * n - 1]] >= t9[o9[2 * n]] for n in range(1, 8))
        c += sum((o9[2 * j] in low) == (o9[2 * j + 1] in low) for j in range(8))
    return c


def binned_violations(r3, r9, s3, s9):
    c = 0
    for k in range(K):
        t3 = [r3[m] ^ mask(k, m, s3) for m in range(M)]
        t9 = [r9[m] ^ mask(k, m, s9) for m in range(M)]
        low = [t < 128 for t in t3]
        c += abs(sum(low) - 8) + sum(t == 255 for t in t3 + t9)
        bins = [[] for _ in range(8)]
        for m in range(M):
            bins[t9[m] >> 5].append(low[m])
        c += sum(abs(len(b) - 2) + (len(b) == 2 and b[0] == b[1]) for b in bins)
    return c


def anneal(cost, s3, s9, seed, iters):
    rng = random.Random(seed)
    r3 = [rng.randrange(256) for _ in range(M)]
    r9 = [rng.randrange(256) for _ in range(M)]
    cur, best, temp = cost(r3, r9, s3, s9), None, 2.0
    best = cur
    for it in range(iters):
        arr = r3 if rng.random() < 0.5 else r9
        m = rng.randrange(M)
        old = arr[m]
        arr[m] = rng.randrange(256) if rng.random() < 0.3 else old ^ (1 << rng.randrange(8))
        new = cost(r3, r9, s3, s9)
        if new <= cur or rng.random() < math.exp((cur - new) / temp):
            cur = new
            best = min(best, cur)
            if cur == 0:
                return r3, r9, it, 0
        else:
            arr[m] = old
        temp = max(0.05, temp * 0.99997)
    return None, None, iters, best


def main():
    a, w = BANKS["A"], BANKS["W"]
    sa, sw = sobol_states(a["dv"], 600), sobol_states(w["dv"], 600)
    best_native = min(
        violations([lane_shift(m, a["base"], a["stride"]) ^ sa[t] for m in range(M)],
                   [lane_shift(m, w["base"], w["stride"]) ^ sw[t] for m in range(M)], 0, 128)
        for t in range(600))
    print(f"native Sobol states t=0..599 (A 3-level, W 9-level): fewest violations "
          f"{best_native} (0 needed) -> a preset is required")
    for label, s3, s9 in (("A 3-level / W 9-level", 0, 128), ("W 3-level / A 9-level", 128, 0)):
        r3, r9, it, best = anneal(violations, s3, s9, seed=0, iters=200000)
        assert r3 is not None, f"{label}: no preset found (best {best})"
        print(f"{label}: found after {it} moves\n  3-level bank r = {r3}\n"
              f"  9-level bank r = {r9}")
    if "--binned" in sys.argv:
        for seed in range(4):
            r3, r9, it, best = anneal(binned_violations, 0, 128, seed, 400000)
            print(f"binned (k-independent code) seed {seed}: "
                  f"{'FOUND' if r3 else 'not found, best ' + str(best)}")


if __name__ == "__main__":
    main()
