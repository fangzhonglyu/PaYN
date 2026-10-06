#!/usr/bin/env python3
# Exhaustive check (L=1..128, 64 column masks, b=0..128) that the C-BSG A count kA has a closed form, so the
# A-side encoder needs no Sobol bank or counting.  Usage: python3 sweeps/cbsg/ka_closed_form.py
# kA = #{t < L : ((bitrev8(gray(t)) ^ bitrev8(d mod 64)) >> 1) < b}  (soren a_encoder / emulator k_table, q seed = identity)
def bitrev8(x): return int(f"{x & 0xff:08b}"[::-1], 2)
def gray(t): return t ^ (t >> 1)
def ka_brute(b, L, d):
    m = bitrev8(d % 64)
    return sum(1 for t in range(L) if ((bitrev8(gray(t)) ^ m) >> 1) < b)
def ka_closed(b, L, d):
    # split [0, L) into aligned dyadic blocks, largest first; in a block of 2^j samples the top j bits of
    # the 8-bit word take every value and the rest is a constant c, so the block contributes
    # clamp(ceil((b - c') / 2^(7-j)), 0, 2^j) with c' = (low part) >> 1.
    m = bitrev8(d % 64); k = 0; s = 0
    for j in range(7, -1, -1):
        if L >> j & 1:
            low = (bitrev8(gray(s)) ^ m) & ((1 << (8 - j)) - 1)   # bits below the j varying ones
            c = low >> 1; step = 1 << (7 - j)
            k += min(max(-(-(b - c) // step), 0), 1 << j)
            s += 1 << j
    return k
bad = [(b, L, d) for L in range(1, 129) for d in range(64) for b in range(129) if ka_brute(b, L, d) != ka_closed(b, L, d)]
print("cases:", 128 * 64 * 129, "mismatches:", len(bad), bad[:5])

# Hardware form: each dyadic block of L contributes (b >> s) + [(b mod 2^s) > c], s = 7 - j, c < 2^s.
# No subtractor, no clamp: one s-bit comparator per set bit of L, plus an adder of <= 8 terms.
def ka_hw(b, L, d):
    m = bitrev8(d % 64); k = 0; s0 = 0
    for j in range(7, -1, -1):
        if L >> j & 1:
            s = 7 - j
            c = ((bitrev8(gray(s0)) ^ m) & ((1 << (8 - j)) - 1)) >> 1
            k += (b >> s) + (1 if (b & ((1 << s) - 1)) > c else 0)
            s0 += 1 << j
    return k
bad_hw = [(b, L, d) for L in range(1, 129) for d in range(64) for b in range(129) if ka_brute(b, L, d) != ka_hw(b, L, d)]
print("hardware form, cases:", 128 * 64 * 129, "mismatches:", len(bad_hw), bad_hw[:5])
