#!/usr/bin/env python3
"""Independent per-element worst-case bound of every tile state reached by the
bit-plane Horner schedules (verify lens: arithmetic correctness).

Written from the design text in design_round1.json (key bitplane_throughput),
NOT from the architect's model.  For a tile accumulating one output, the tile
value at any instant is sum_e v_e(state) over reduction elements e.  With all
elements equal the bound L * max|v| is attained, so the OWIDTH=24 safe length is
  L_max = floor((2^23 - 1) / max_{a,w,state} |v|).

Schedules
  HW  (recommended INT8/W4A8/INT4): tile (h,v) holds sigma_h * a_h * (Horner over
      w planes, MSB first).  States: after any whole pass, after the doubling,
      and mid-pass (element done / not done).
  HB  (W4A8/INT4 option): both planes in time, Horner over s = p+q (MSB stage
      first), pairs within a stage in the order the design lists (p ascending;
      also every other order is tried for the worst case).
"""
import itertools

def bits(x, n):
    return [((x & ((1 << n) - 1)) >> i) & 1 for i in range(n)]

def sig(i, n):
    return -1 if i == n - 1 else 1

def hw_states(a, w, ba, bw):
    """All per-element values a tile (h) can hold, over all h."""
    ab, wb = bits(a, ba), bits(w, bw)
    out = []
    for h in range(ba):
        acc = 0
        for q in reversed(range(bw)):
            out.append(acc)                     # before this pass's element
            term = sig(h, ba) * sig(q, bw) * ab[h] * wb[q]
            acc = acc + term
            out.append(acc)                     # after it
            if q:
                acc = 2 * acc                   # ring lap
                out.append(acc)
        assert acc == sig(h, ba) * ab[h] * w, (a, w, h)
    return out

def hb_states(a, w, ba, bw, order):
    ab, wb = bits(a, ba), bits(w, bw)
    acc = 0
    out = [0]
    for s in reversed(range(ba + bw - 1)):
        pairs = [(p, s - p) for p in range(ba) if 0 <= s - p < bw]
        pairs = order(pairs)
        for (p, q) in pairs:
            acc += sig(p, ba) * sig(q, bw) * ab[p] * wb[q]
            out.append(acc)
        if s:
            acc *= 2
            out.append(acc)
    assert acc == a * w, (a, w, acc)
    return out

def rng(n):
    return range(-(1 << (n - 1)), 1 << (n - 1))

LIM = (1 << 23) - 1
print("== HW (w planes in time, MSB-first ring doubling) ==")
for name, ba, bw in [("INT8", 8, 8), ("W4A8", 8, 4), ("INT4", 4, 4)]:
    mx, arg = 0, None
    for a in rng(ba):
        for w in rng(bw):
            m = max(abs(v) for v in hw_states(a, w, ba, bw))
            if m > mx:
                mx, arg = m, (a, w)
    fin = max(abs(a * 1) for a in [1]) # placeholder
    print(f"  {name}: max per-element |tile| = {mx} at (a,w)={arg};  safe L <= {LIM // mx}")

print("\n== HB (both planes in time, Horner over s=p+q) ==")
orders = {"p-ascending (design)": lambda ps: ps,
          "p-descending": lambda ps: list(reversed(ps))}
for name, ba, bw in [("W4A8", 8, 4), ("INT4", 4, 4)]:
    fmax = max(abs(a * w) for a in rng(ba) for w in rng(bw))
    for oname, order in orders.items():
        mx, arg = 0, None
        for a in rng(ba):
            for w in rng(bw):
                m = max(abs(v) for v in hb_states(a, w, ba, bw, order))
                if m > mx:
                    mx, arg = m, (a, w)
        print(f"  {name} {oname:22s}: max |a*w| = {fmax}, max per-element |tile state| = {mx} "
              f"at (a,w)={arg};  safe L <= {LIM // mx}  (claimed safe L by |a*w| bound: {LIM // fmax})")
    # worst over all within-stage orders
    mx_all = 0
    for a in rng(ba):
        for w in rng(bw):
            ab, wb = bits(a, ba), bits(w, bw)
            acc_lo = acc_hi = 0      # track reachable extreme via per-stage sorting
            # exact: for each stage, worst prefix = most positive / most negative partial sum
            acc = 0
            for s in reversed(range(ba + bw - 1)):
                terms = [sig(p, ba) * sig(s - p, bw) * ab[p] * wb[s - p]
                         for p in range(ba) if 0 <= s - p < bw]
                pos = sum(t for t in terms if t > 0)
                neg = sum(t for t in terms if t < 0)
                mx_all = max(mx_all, abs(acc + pos), abs(acc + neg))
                acc += sum(terms)
                if s:
                    acc *= 2
                    mx_all = max(mx_all, abs(acc))
    print(f"  {name} worst over any within-stage order: {mx_all}; safe L <= {LIM // mx_all}")
