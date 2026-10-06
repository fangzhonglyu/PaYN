#!/usr/bin/env python3
"""Bit-exact and timing check of the BP-hybrid grid bench
(designs/payn/tb/test_pe_grid_bp_hybrid.sv, trace bpg_trace.txt, header BPHGCFG).

Mapping: TA activation bits and TW weight bits in time per tile; GA = BA/TA
activation-bit groups on tile rows, GW = BW/TW weight-bit groups on tile
columns.  Tile row h: activation row i = (ig*P_R + r)*ROWS_PE + h // GA,
group g = h % GA.  Tile column v: output column j = (jg*P_C + c)*CPE + v // GW,
group s = v % GW.  Independent numpy int64 reference:

    T((i,g),(j,s)) = sum_x Afield_g[i,x] * Wfield_s[x,j]

(Afield_g = activation bits g*TA .. g*TA+TA-1, signed iff g == GA-1; Wfield_s
likewise), also recomputed pass by pass in the bench's Horner order (level
k = ta + q, highest first, x2 between levels; the sign path negates iff exactly
one of the two bits is its operand's MSB); both must agree.  Combined outputs
from the DRAINED tiles must equal (A @ W)[i, j]:

    out(i,j) = sum_g sum_s 2^(g*TA + s*TW) * T((i,g),(j,s))

Timing: every (block, row, step) drained exactly once on D0 + t with
D0 = E0 + blk*BLK_LEN + ACTIVE + 1 + DS; BLK_LEN must equal the mode's formula
and, nominally, TA*TW*NB + 8*(TA+TW-2) + (P_R+P_C-2) + 8*P_C; multi-block
drain-start spacing must equal BLK_LEN.  Ring runs: TA+TW-2 laps per block per
PE, 8 edges each, starting B + lev_end + LO + 1 + r + c.

Usage:  check_bp_hybrid_trace.py RUN_DIR [--json out.json]
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np

OWIDTH = 24
MODES = {0: "nominal", 1: "neg_asign_held", 4: "neg_drain_early", 5: "neg_block_overlap",
         6: "neg_gap_short"}
PREC = {(8, 8): "INT8", (8, 4): "W4A8", (4, 4): "INT4", (4, 8): "W8A4"}


def read_hex(path: Path, n: int) -> np.ndarray:
    vals = [int(x, 16) for x in path.read_text().split()]
    if len(vals) != n:
        raise SystemExit(f"{path}: {len(vals)} entries, expected {n}")
    v = np.array(vals, dtype=np.int64)
    return np.where(v >= 128, v - 256, v)


def field(Xu: np.ndarray, lo: int, width: int, signed: bool) -> np.ndarray:
    f = (Xu >> lo) & ((1 << width) - 1)
    if signed:
        f = np.where(f >= (1 << (width - 1)), f - (1 << width), f)
    return f


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("run_dir", type=Path)
    ap.add_argument("--json", type=Path, dest="json_path")
    args = ap.parse_args()

    lines = (args.run_dir / "bpg_trace.txt").read_text().splitlines()
    head = lines[0].split()
    if head[0] != "BPHGCFG" or len(head) != 22:
        raise SystemExit("bad trace header")
    (pr, pc, ba, bw, ta_n, tw_n, L, mrows, ncols, nblk, nb, npass, nlev, gap, lo, sk, ds,
     blk_len, e0, mode, junk) = [int(x) for x in head[1:]]
    ga, gw = ba // ta_n, bw // tw_n
    rows_pe, cpe = 8 // ga, 8 // gw
    if npass != ta_n * tw_n or nlev != ta_n + tw_n - 1 or nb != L // 128 or sk != pr + pc - 2:
        raise SystemExit("header inconsistent")
    nig, njg = mrows // (pr * rows_pe), ncols // (pc * cpe)
    if nblk != nig * njg:
        raise SystemExit("header block count inconsistent")

    # Pass table, as the bench builds it.
    passes, lev_end, off = [], [], 0
    for lv in range(nlev):
        k = nlev - 1 - lv
        for ta in range(ta_n - 1, -1, -1):
            q = k - ta
            if 0 <= q <= tw_n - 1:
                passes.append((ta, q, lv))
                off += nb
        lev_end.append(off)
        if lv < nlev - 1:
            off += gap
    active = off
    formula_nominal = ta_n * tw_n * nb + 8 * (ta_n + tw_n - 2) + sk + 8 * pc
    formula_mode = active + ds + 8 * pc - (1 if mode == 5 else 0)

    drains, dedge, laps, dup = {}, {}, {}, []
    for line in lines[1:]:
        f = line.split()
        if f[0] == "D":
            key = (int(f[1]), int(f[2]), int(f[3]))
            if key in drains:
                dup.append(key)
            drains[key] = [int(x) for x in f[5:]]
            dedge[key] = int(f[4])
        elif f[0] == "R":
            laps.setdefault((int(f[1]), int(f[2])), []).append((int(f[3]), int(f[4])))
        else:
            raise SystemExit(f"unknown record {f[0]}")
    want = {(b, r, t) for b in range(nblk) for r in range(pr) for t in range(8 * pc)}
    coverage_ok = set(drains) == want and not dup

    A = read_hex(args.run_dir / "bpt_a.hex", mrows * L).reshape(mrows, L)
    W = read_hex(args.run_dir / "bpt_w.hex", ncols * L).reshape(ncols, L).T
    Au, Wu = A & ((1 << ba) - 1), W & ((1 << bw) - 1)
    afld = [field(Au, g * ta_n, ta_n, g == ga - 1) for g in range(ga)]
    wfld = [field(Wu, s * tw_n, tw_n, s == gw - 1) for s in range(gw)]
    if not np.array_equal(sum((1 << (g * ta_n)) * afld[g] for g in range(ga)), A) or \
       not np.array_equal(sum((1 << (s * tw_n)) * wfld[s] for s in range(gw)), W):
        raise SystemExit("reference self-check failed: fields do not recompose the operands")
    apl = np.stack([(Au >> p) & 1 for p in range(ba)])
    wpl = np.stack([(Wu >> q) & 1 for q in range(bw)])
    gemm = A @ W
    Tref = {(g, s): afld[g] @ wfld[s] for g in range(ga) for s in range(gw)}   # (mrows, ncols)

    # Hardware-order self-check on a sample of (g, s): Horner over levels with the sign path.
    for g in range(ga):
        for s in range(gw):
            acc = np.zeros((mrows, ncols), np.int64)
            cur_lv = 0
            for ta, q, lv in passes:
                while cur_lv < lv:
                    acc *= 2
                    cur_lv += 1
                pa, pw = g * ta_n + ta, s * tw_n + q
                sig = -1 if ((pa == ba - 1) != (pw == bw - 1)) else 1
                acc += sig * (apl[pa] @ wpl[pw])
            while cur_lv < nlev - 1:
                acc *= 2
                cur_lv += 1
            if not np.array_equal(acc, Tref[(g, s)]):
                raise SystemExit(f"reference self-check failed: Horner order disagrees for g={g} s={s}")
    max_abs_tile = max(int(np.abs(t).max()) for t in Tref.values())
    if max_abs_tile >= (1 << (OWIDTH - 1)):
        raise SystemExit(f"tile value {max_abs_tile} overflows OWIDTH")

    mismatches = []
    got = {}
    for (blk, r, t), vals in drains.items():
        ig, jg = divmod(blk, njg)
        c, v = pc - 1 - t // 8, 7 - t % 8
        jj, s = divmod(v, gw)
        j = (jg * pc + c) * cpe + jj
        for h in range(8):
            il, g = divmod(h, ga)
            i = (ig * pr + r) * rows_pe + il
            exp = int(Tref[(g, s)][i, j])
            got[(i, j, g, s)] = vals[h]
            if vals[h] != exp:
                mismatches.append(dict(kind="tile", block=blk, pe=[r, c], h=h, v=v, got=vals[h], exp=exp))
    n_out = 0
    for i in range(mrows):
        for j in range(ncols):
            n_out += 1
            terms = [got.get((i, j, g, s)) for g in range(ga) for s in range(gw)]
            if any(x is None for x in terms):
                mismatches.append(dict(kind="missing", row=i, col=j))
                continue
            out = sum((1 << (g * ta_n + s * tw_n)) * got[(i, j, g, s)] for g in range(ga) for s in range(gw))
            if out != int(gemm[i, j]):
                mismatches.append(dict(kind="combined", row=i, col=j, got=out, exp=int(gemm[i, j])))

    drain_edge_errors = []
    for (blk, r, t), e in dedge.items():
        d0 = e0 + blk * blk_len + active + 1 + ds
        if e != d0 + t:
            drain_edge_errors.append(dict(block=blk, row=r, step=t, edge=e, exp=d0 + t))
    starts = [dedge[(b, 0, 0)] for b in range(nblk) if (b, 0, 0) in dedge]
    periods = sorted({b - a for a, b in zip(starts, starts[1:])})
    period_ok = blk_len == formula_mode and (not periods or periods == [blk_len])
    if mode not in (4, 5, 6):
        period_ok = period_ok and blk_len == formula_nominal

    lap_errors = []
    for r in range(pr):
        for c in range(pc):
            exp_runs = sorted((e0 + b * blk_len + lev_end[lv] + lo + 1 + r + c, 8)
                              for b in range(nblk) for lv in range(nlev - 1))
            got_runs = sorted(laps.get((r, c), []))
            if got_runs != exp_runs:
                lap_errors.append(dict(pe=[r, c], got=got_runs[:4], exp=exp_runs[:4]))

    outs_pe = rows_pe * cpe
    peak = 128 // (ba * bw)
    macs_pe_blk = outs_pe * L
    pct = macs_pe_blk / (64 * peak * blk_len)
    status = "PASS" if (not mismatches and coverage_ok and not drain_edge_errors and period_ok
                        and not lap_errors) else "FAIL"
    res = dict(status=status, grid=f"{pr}x{pc}", precision=PREC[(ba, bw)], ba=ba, bw=bw, TA=ta_n, TW=tw_n,
               GA=ga, GW=gw, rows_pe=rows_pe, cols_pe=cpe, outputs_per_pe=outs_pe, L=L, nb=nb,
               blocks=nblk, passes=npass, laps=nlev - 1, mode=MODES.get(mode, mode), junk=junk,
               block_len=blk_len, formula_nominal=formula_nominal, formula_mode=formula_mode,
               measured_periods=periods, pct_peak=round(100 * pct, 2),
               edges_per_8_outputs_per_pe=round(8 * blk_len / outs_pe, 3),
               max_abs_tile=max_abs_tile, max_abs_out=int(np.abs(gemm).max()),
               tiles_checked=len(drains) * 8, outputs_checked=n_out,
               n_mismatch=len(mismatches), mismatches=mismatches[:12], coverage_ok=coverage_ok,
               n_drain_edge_errors=len(drain_edge_errors), period_ok=period_ok,
               n_lap_errors=len(lap_errors), lap_errors=lap_errors[:4],
               lap_runs_seen=sum(len(x) for x in laps.values()))
    text = json.dumps(res, indent=2) + "\n"
    if args.json_path:
        args.json_path.write_text(text)
    print(text, end="")
    tag = f"grid {pr}x{pc} {PREC[(ba, bw)]} TA={ta_n} TW={tw_n} L={L} blocks={nblk} {MODES.get(mode, mode)}" + \
          (" junk" if junk else "")
    if status != "PASS":
        print(f"[FAIL] {tag}: {len(mismatches)} mismatches, coverage_ok={coverage_ok}, "
              f"drain_edge_errors={len(drain_edge_errors)}, period_ok={period_ok}, lap_errors={len(lap_errors)}")
        return 1
    print(f"[PASS] {tag}: {len(drains) * 8} tiles + {n_out} outputs bit-exact (max|tile| {max_abs_tile}, "
          f"max|out| {res['max_abs_out']}); block period {blk_len} = formula "
          f"({'spacing ' + str(periods) if periods else 'single block'}); {outs_pe} outputs/PE; "
          f"{res['edges_per_8_outputs_per_pe']} edges per 8 outputs/PE; {100 * pct:.1f}% of peak; "
          f"{res['lap_runs_seen']} lap runs")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
