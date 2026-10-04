#!/usr/bin/env python3
"""Can the unchanged SC edge comparator emit exact unary (thermometer) codes?

The PaYN edge peripheral (designs/payn/pe_peripheral.sv) computes, per lane
(row-or-col, k) and position m,

    bit[k][m] = mag[k] > (r[m] ^ MASK(k, m, salt))

where r[m] is the shared Sobol value of lane m and MASK is a compile-time
constant (SCRAMBLE_ENABLE=1).  Every Sobol lane of a bank holds
LANE_SHIFT[m] ^ S(t), with S(t) common to all lanes (sobol.sv: one shared
direction table and count).  Hence, for a fixed k, the 16 thresholds are
distinct at every Sobol state iff LANE_SHIFT[m] ^ MASK(k, m) are distinct.

If they are, popcount_m(bit[k][m]) = #{m : thr(k, m) < mag[k]} can take every
value 0..16 by choosing mag[k] from a per-k table, i.e. an exact unary code with
no hardware change, as long as the Sobol is parked at a known state (rng_en=0).
The comparator output over m is always a prefix of that lane's threshold
ranking, so only 17 distinct 16-bit patterns per lane exist (log2 17 = 4.09
bits of information per lane per cycle).

This script reports, for both banks and the parameters of
payn_array_signed_segmented_csa.sv, distinctness per k, the state where 255 is
a threshold (which breaks the mag=255 'all ones' broadcast), the Sobol return
period, and the per-k mag table for 0..16 at the reset state.
No EDA tools are involved.
"""
from __future__ import annotations

WIDTH = 8
LEVELS = 1 << WIDTH
K = 8
M = 16
SK = ((LEVELS * 79) // 128) | 1   # SCRAMBLE_K_STRIDE
SM = ((LEVELS * 49) // 128) | 1   # SCRAMBLE_M_STRIDE

# payn_array_signed_segmented_csa.sv defaults
BANKS = {
    "A": dict(salt=0, base=0x17, stride=0x53,
              dv=[1 << (WIDTH - 1 - j) for j in range(WIDTH)]),
    "W": dict(salt=1 << (WIDTH - 1), base=0x9D, stride=0x2B,
              dv=[128, 64, 32, 16, 72, 4, 82, 255]),
}


def mask(k: int, m: int, salt: int) -> int:
    return (k * SK + m * SM + salt) & (LEVELS - 1)


def lane_shift(m: int, base: int, stride: int) -> int:
    return (base ^ ((stride * m) & (LEVELS - 1))) & (LEVELS - 1)


def sobol_states(dv: list[int], steps: int, full_period_wrap: bool = False):
    """Common XOR part S(t) for t = 0..steps (t=0 is the reset state)."""
    cnt, s = 0, 0
    out = [s]
    for _ in range(steps):
        j = 0
        while j < WIDTH and ((cnt >> j) & 1):
            j += 1
        if j < WIDTH:
            s ^= dv[j]
        elif full_period_wrap:
            s ^= dv[-1]
        cnt = (cnt + 1) & (LEVELS - 1)
        out.append(s)
    return out


def main() -> None:
    print(f"SCRAMBLE_K_STRIDE={SK} SCRAMBLE_M_STRIDE={SM}")
    for name, p in BANKS.items():
        base_thr = [[lane_shift(m, p["base"], p["stride"]) ^ mask(k, m, p["salt"])
                     for m in range(M)] for k in range(K)]
        distinct = [len(set(row)) for row in base_thr]
        print(f"\n== bank {name}: salt={p['salt']} base=0x{p['base']:02x} "
              f"stride=0x{p['stride']:02x}")
        print(f"distinct thresholds per k (need 16): {distinct}")

        states = sobol_states(p["dv"], 3 * LEVELS)
        # first return of S to 0 after reset
        ret = next((t for t in range(1, len(states)) if states[t] == 0), None)
        print(f"first t>0 with S(t)=0 (legacy no-wrap): {ret}")
        bad = [t for t in range(LEVELS)
               if any((thr ^ states[t]) == LEVELS - 1
                      for row in base_thr for thr in row)]
        print(f"Sobol states t in [0,255] where some threshold == 255: "
              f"{len(bad)} of 256; t=0 bad? {0 in bad}")

        # Reachable unary counts per k at any Sobol state (distinctness and
        # ranking are independent of the common S(t)).
        print("reachable popcounts per k (any mag 0..255), S=0:")
        for k in range(K):
            reach = sorted({sum(1 for t in base_thr[k] if mg > t)
                            for mg in range(LEVELS)})
            missing = [v for v in range(M) if v not in reach]
            print(f"  k={k}: missing values in 0..15: {missing}")

    # Runtime override of the shared random_values bus (16 x 8 bits per side):
    # find r[m] so that, for every k, r[m]^MASK(k,m) are 16 distinct values
    # below 255.  Then a per-k table gives exact unary counts 0..16 and
    # mag=255 / mag=0 give an exact all-ones / all-zeros broadcast.
    import random
    rng = random.Random(1)
    for name, p in BANKS.items():
        tries = 0
        while True:
            tries += 1
            r = [rng.randrange(LEVELS) for _ in range(M)]
            thr = [[r[m] ^ mask(k, m, p["salt"]) for m in range(M)]
                   for k in range(K)]
            if all(len(set(row)) == M and max(row) < LEVELS - 1 for row in thr):
                break
        print(f"\n== override search bank {name}: found after {tries} random tries")
        print("  r =", [hex(x) for x in r])
        for k in range(K):
            srt = sorted(thr[k])
            table = [0] + [srt[v - 1] + 1 for v in range(1, M + 1)]
            for v in range(M + 1):
                assert sum(1 for t in thr[k] if table[v] > t) == v
            assert sum(1 for t in thr[k] if 255 > t) == M
            print(f"  k={k}: unary mag table v=0..16: {table}")

    # The lead's ramp: r[m] = m on the shared bus.  The masks still apply, so
    # thresholds are m ^ MASK(k, m), not m; report distinctness and the per-k
    # mag tables (operand pre-encoding) that make the count exactly unary.
    for name, p in BANKS.items():
        thr = [[m ^ mask(k, m, p["salt"]) for m in range(M)] for k in range(K)]
        d = [len(set(row)) for row in thr]
        n255 = sum(1 for row in thr if max(row) == LEVELS - 1)
        print(f"\n== ramp r[m]=m, bank {name}: distinct per k {d}; "
              f"lanes with a 255 threshold: {n255}")
        for k in range(K):
            srt = sorted(thr[k])
            table = [0] + [srt[v - 1] + 1 for v in range(1, M)]
            for v in range(M):
                assert sum(1 for t in thr[k] if table[v] > t) == v
            print(f"  k={k}: unary mag table v=0..15: {table}")

    # Structured override: is there r with thr(k,m) = 16*pi_k(m) + c (top
    # nibble a permutation, same low nibble) for all k?  Needs the low nibble
    # of MASK(k,m) to be k-independent, which fails because SK is odd.
    lows = {(mask(k, 0, 0) & 15) for k in range(K)}
    print(f"\nlow nibbles of MASK(k,0) over k: {sorted(lows)} "
          f"(k-independent? {len(lows) == 1})")


def search_lane_shift_params() -> None:
    """Parameter-only alternative: Sobol (base, stride) pairs whose lane
    shifts already give 16 distinct thresholds for every k (and no 255 at the
    reset state).  Changing them changes every SC stream, so SC accuracy and
    the existing bit-exact evidence would have to be redone."""
    for name, p in BANKS.items():
        good = good0 = 0
        examples = []
        for base in range(LEVELS):
            for stride in range(LEVELS):
                ls = [lane_shift(m, base, stride) for m in range(M)]
                if len(set(ls)) < M:   # identical Sobol lanes would wreck SC
                    continue
                rows = [[ls[m] ^ mask(k, m, p["salt"]) for m in range(M)]
                        for k in range(K)]
                if all(len(set(r)) == M for r in rows):
                    good += 1
                    if all(max(r) < LEVELS - 1 for r in rows):
                        good0 += 1
                        if len(examples) < 4:
                            examples.append((hex(base), hex(stride)))
        cur = (p["base"], p["stride"])
        print(f"bank {name}: (base,stride) pairs (distinct lane shifts) with distinct "
              f"thresholds for all k: {good}/65536; also no 255 at reset: {good0}; "
              f"current {tuple(hex(x) for x in cur)} qualifies: False; "
              f"examples {examples}")

if __name__ == "__main__":
    main()
    print()
    search_lane_shift_params()
