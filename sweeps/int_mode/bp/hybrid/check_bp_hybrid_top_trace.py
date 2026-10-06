#!/usr/bin/env python3
"""Bit-exact and timing check of the BP-hybrid single-PE top bench
(designs/payn/tb/test_payn_array_bp_hybrid.sv, trace bph_trace.txt, header BPHTCFG).

Mapping: TA activation bits and TW weight bits in time per tile; GA = BA/TA
activation-bit groups on tile rows, GW = BW/TW weight-bit groups on tile
columns.  Tile row h: activation row i = ig*ROWS_PE + h // GA, group g = h % GA.
Tile column v: output column j = jg*CPE + v // GW, group s = v % GW.
Independent numpy int64 reference, also recomputed pass by pass in the bench's
Horner order (as check_bp_hybrid_trace.py):

    T((i,g),(j,s)) = sum_x Afield_g[i,x] * Wfield_s[x,j]
    out(i,j)       = sum_g sum_s 2^(g*TA + s*TW) * T

Checks:
  * D records (drained tiles) vs T; combined outputs from the D records vs A @ W;
  * C records (the top's unchanged PaynBpCombiner) equal that combiner's function
    of the drained column (int_prec = 0: lo = sum_h 2^h T(h); 1: two 4-plane
    halves; mod 2^32), and whether they equal the H combine of the column (only
    for TA = 1, the T1 activation mapping);
  * Y records (sidecar PaynBpHybridCombiner) equal sum_g 2^(g*TA) T(il*GA + g) for
    il < 8/GA (others 0); then the column Horner R <- (R << TW) + Y over the GW
    drained columns of an output, east-first (s = GW-1 first), must equal A @ W,
    unbounded and with a 32-bit wrapping R;
  * timing: every (block, step) drained once, on D0 + t, D0 = E0 + blk*BLK_LEN +
    ACTIVE + 1 + DS; BLK_LEN = the mode's formula and, nominally,
    TA*TW*NB + 8*(TA+TW-2) + 8 (the model's H period on 1 PE); multi-block
    drain-start spacing = BLK_LEN; ring_q runs: TA+TW-2 laps per block, 8 edges
    each, from B + lev_end + LO + 1.

Usage:  check_bp_hybrid_top_trace.py RUN_DIR [--json out.json]
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np

OWIDTH = 24
PREC = {(8, 8): "INT8", (8, 4): "W4A8", (4, 4): "INT4", (4, 8): "W8A4"}


def read_hex(path: Path, n: int) -> np.ndarray:
    vals = [int(x, 16) for x in path.read_text().split()]
    if len(vals) != n:
        raise SystemExit(f"{path}: {len(vals)} entries, expected {n}")
    v = np.array(vals, dtype=np.int64)
    return np.where(v >= 128, v - 256, v)


def field(Xu, lo, width, signed):
    f = (Xu >> lo) & ((1 << width) - 1)
    return np.where(f >= (1 << (width - 1)), f - (1 << width), f) if signed else f


def wrap(x: int, bits: int = 32) -> int:
    x &= (1 << bits) - 1
    return x - (1 << bits) if x >> (bits - 1) else x


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("run_dir", type=Path)
    ap.add_argument("--json", type=Path, dest="json_path")
    args = ap.parse_args()

    lines = (args.run_dir / "bph_trace.txt").read_text().splitlines()
    head = lines[0].split()
    if head[0] != "BPHTCFG" or len(head) != 21:
        raise SystemExit("bad trace header")
    (ba, bw, ta_n, tw_n, L, mrows, ncols, nblk, nb, npass, nlev, lo, ds, blk_len, e0, int4,
     junk, neg_ah, neg_gs, neg_ov) = [int(x) for x in head[1:]]
    ga, gw = ba // ta_n, bw // tw_n
    rows_pe, cpe = 8 // ga, 8 // gw
    if npass != ta_n * tw_n or nlev != ta_n + tw_n - 1 or nb != L // 128:
        raise SystemExit("header inconsistent")
    nig, njg = mrows // rows_pe, ncols // cpe
    if nblk != nig * njg:
        raise SystemExit("header block count inconsistent")
    mode = ("neg_asign_held" if neg_ah else "neg_gap_short" if neg_gs else "neg_block_overlap" if neg_ov
            else "neg_drain_early" if ds == -1 else "nominal")

    passes, lev_end, off = [], [], 0
    for lv in range(nlev):
        k = nlev - 1 - lv
        for ta in range(ta_n - 1, -1, -1):
            if 0 <= k - ta <= tw_n - 1:
                passes.append((ta, k - ta, lv))
                off += nb
        lev_end.append(off)
        if lv < nlev - 1:
            off += 8 + lo
    active = off
    formula_nominal = ta_n * tw_n * nb + 8 * (ta_n + tw_n - 2) + 8
    formula_mode = active + ds + 8 - (1 if neg_ov else 0)

    D, E, C, Y, R, dup = {}, {}, {}, {}, [], []
    for line in lines[1:]:
        f = line.split()
        key = (int(f[1]), int(f[2])) if f[0] in "DECY" else None
        if f[0] == "D":
            dup += [key] if key in D else []
            D[key] = [int(x) for x in f[3:]]
        elif f[0] == "E":
            E[key] = int(f[3])
        elif f[0] == "C":
            C[key] = (int(f[3]), int(f[4]))
        elif f[0] == "Y":
            Y[key] = [int(x) for x in f[3:]]
        elif f[0] == "R":
            R.append((int(f[1]), int(f[2])))
        else:
            raise SystemExit(f"unknown record {f[0]}")
    want = {(b, t) for b in range(nblk) for t in range(8)}
    coverage_ok = set(D) == want and set(C) == want and set(Y) == want and not dup

    A = read_hex(args.run_dir / "bpt_a.hex", mrows * L).reshape(mrows, L)
    W = read_hex(args.run_dir / "bpt_w.hex", ncols * L).reshape(ncols, L).T
    Au, Wu = A & ((1 << ba) - 1), W & ((1 << bw) - 1)
    afld = [field(Au, g * ta_n, ta_n, g == ga - 1) for g in range(ga)]
    wfld = [field(Wu, s * tw_n, tw_n, s == gw - 1) for s in range(gw)]
    gemm = A @ W
    Tref = {(g, s): afld[g] @ wfld[s] for g in range(ga) for s in range(gw)}
    apl = np.stack([(Au >> p) & 1 for p in range(ba)])
    wpl = np.stack([(Wu >> q) & 1 for q in range(bw)])
    for g in range(ga):                      # hardware-order self-check
        for s in range(gw):
            acc, cur = np.zeros((mrows, ncols), np.int64), 0
            for ta, q, lv in passes:
                while cur < lv:
                    acc *= 2
                    cur += 1
                pa, pw = g * ta_n + ta, s * tw_n + q
                acc += (-1 if ((pa == ba - 1) != (pw == bw - 1)) else 1) * (apl[pa] @ wpl[pw])
            acc *= 1 << (nlev - 1 - cur)
            if not np.array_equal(acc, Tref[(g, s)]):
                raise SystemExit(f"reference self-check failed (g={g}, s={s})")
    max_abs_tile = max(int(np.abs(t).max()) for t in Tref.values())

    mm = []
    got = {}
    for (blk, t), vals in D.items():
        ig, jg = divmod(blk, njg)
        v = 7 - t
        jj, s = divmod(v, gw)
        j = jg * cpe + jj
        for h in range(8):
            il, g = divmod(h, ga)
            i = ig * rows_pe + il
            got[(i, j, g, s)] = vals[h]
            if vals[h] != int(Tref[(g, s)][i, j]):
                mm.append(dict(kind="tile", block=blk, t=t, h=h, got=vals[h], exp=int(Tref[(g, s)][i, j])))
    for i in range(mrows):
        for j in range(ncols):
            terms = [got.get((i, j, g, s)) for g in range(ga) for s in range(gw)]
            if any(x is None for x in terms):
                mm.append(dict(kind="missing", row=i, col=j))
                continue
            out = sum((1 << (g * ta_n + s * tw_n)) * got[(i, j, g, s)] for g in range(ga) for s in range(gw))
            if out != int(gemm[i, j]):
                mm.append(dict(kind="combined", row=i, col=j, got=out, exp=int(gemm[i, j])))

    # Top combiner (unchanged PaynBpCombiner): its function of the drained column.
    comb_bad = 0
    comb_is_output = True
    for key, (clo, chi) in C.items():
        col = D.get(key)
        if col is None:
            comb_bad += 1
            continue
        if int4:
            lo_w = wrap(sum(col[h] << h for h in range(4)))
            hi_w = wrap(sum(col[h] << (h - 4) for h in range(4, 8)))
        else:
            lo_w, hi_w = wrap(sum(col[h] << h for h in range(8))), 0
        comb_bad += (clo, chi) != (lo_w, hi_w)
    # Does it equal the H combine of the column (sum_g 2^(g*TA) T per activation row)?  Only at TA = 1
    # (the T1 mapping: one or two activation rows per column); for TW < BW the column Horner follows.
    for key, (clo, chi) in C.items():
        col = D.get(key, [0] * 8)
        hyb = [sum(col[il * ga + g] << (g * ta_n) for g in range(ga)) for il in range(rows_pe)]
        want_c = (wrap(hyb[0]), wrap(hyb[1]) if rows_pe == 2 else 0) if rows_pe <= 2 else None
        if want_c is None or (clo, chi) != want_c:
            comb_is_output = False
    if comb_bad:
        mm.append(dict(kind="top_combiner", n=comb_bad))

    # Sidecar hybrid combiner, then the column Horner over the GW groups (east-first).
    y_bad = 0
    R_unb, R_w = {}, {}
    out_mm = 0
    for (blk, t), words in sorted(Y.items()):
        col = D.get((blk, t), [0] * 8)
        exp = [sum(col[il * ga + g] << (g * ta_n) for g in range(ga)) for il in range(rows_pe)] + [0] * (8 - rows_pe)
        if [wrap(x) for x in exp] != words:
            y_bad += 1
        ig, jg = divmod(blk, njg)
        v = 7 - t
        jj, s = divmod(v, gw)
        j = jg * cpe + jj
        for il in range(rows_pe):
            i = ig * rows_pe + il
            k = (i, j)
            if s == gw - 1:
                R_unb[k], R_w[k] = words[il], wrap(words[il])
            else:
                R_unb[k] = (R_unb[k] << tw_n) + words[il]
                R_w[k] = wrap((R_w[k] << tw_n) + words[il])
            if s == 0:
                out_mm += R_unb[k] != int(gemm[i, j]) or R_w[k] != wrap(int(gemm[i, j]))
    if y_bad:
        mm.append(dict(kind="hybrid_combiner_word", n=y_bad))
    if out_mm or len(R_unb) != mrows * ncols:
        mm.append(dict(kind="hybrid_combiner_output", n=out_mm, outputs=len(R_unb)))

    edge_err = [k for k, e in E.items() if e != e0 + k[0] * blk_len + active + 1 + ds + k[1]]
    starts = [E[(b, 0)] for b in range(nblk) if (b, 0) in E]
    periods = sorted({b - a for a, b in zip(starts, starts[1:])})
    period_ok = blk_len == formula_mode and (not periods or periods == [blk_len])
    if mode == "nominal":
        period_ok = period_ok and blk_len == formula_nominal
    exp_runs = sorted((e0 + b * blk_len + lev_end[lv] + lo + 1, 8) for b in range(nblk) for lv in range(nlev - 1))
    lap_ok = sorted(R) == exp_runs

    outs_pe = rows_pe * cpe
    pct = outs_pe * L / (64 * (128 // (ba * bw)) * blk_len)
    status = "PASS" if (not mm and coverage_ok and not edge_err and period_ok and lap_ok) else "FAIL"
    res = dict(status=status, grid="1x1", top=True, precision=PREC[(ba, bw)], ba=ba, bw=bw, TA=ta_n, TW=tw_n,
               GA=ga, GW=gw, rows_pe=rows_pe, cols_pe=cpe, outputs_per_pe=outs_pe, L=L, nb=nb, blocks=nblk,
               mode=mode, junk=junk, block_len=blk_len, formula_nominal=formula_nominal,
               formula_mode=formula_mode, measured_periods=periods, pct_peak=round(100 * pct, 2),
               max_abs_tile=max_abs_tile, max_abs_out=int(np.abs(gemm).max()), tiles_checked=8 * len(D),
               outputs_checked=mrows * ncols, top_combiner_words=len(C), top_combiner_matches_h_combine=comb_is_output,
               hybrid_combiner_words=len(Y), n_mismatch=len(mm), mismatches=mm[:12], coverage_ok=coverage_ok,
               n_drain_edge_errors=len(edge_err), period_ok=period_ok, lap_ok=lap_ok, lap_runs_seen=len(R))
    text = json.dumps(res, indent=2) + "\n"
    if args.json_path:
        args.json_path.write_text(text)
    print(text, end="")
    tag = f"top 1x1 {PREC[(ba, bw)]} TA={ta_n} TW={tw_n} L={L} blocks={nblk} {mode}" + (" junk" if junk else "")
    if status != "PASS":
        print(f"[FAIL] {tag}: {len(mm)} mismatches, coverage_ok={coverage_ok}, drain_edge_errors={len(edge_err)}, "
              f"period_ok={period_ok}, lap_ok={lap_ok}")
        return 1
    print(f"[PASS] {tag}: {8 * len(D)} tiles + {mrows * ncols} outputs bit-exact (max|tile| {max_abs_tile}); "
          f"hybrid combiner {len(Y)} words + column Horner exact; top combiner = its own function on every word, "
          f"{'equal to' if comb_is_output else 'NOT'} the H combine; block period {blk_len} = formula "
          f"({'spacing ' + str(periods) if periods else 'single block'}); {outs_pe} outputs/PE; {100 * pct:.1f}% of peak; "
          f"{len(R)} lap runs")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
