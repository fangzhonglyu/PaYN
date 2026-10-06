#!/usr/bin/env python3
"""Bit-exact and timing check of the BP PE-grid INT bench (designs/payn/tb/test_pe_grid_bp.sv).

Independent numpy int64 reference.  Output block (ig, jg) of a P_R x P_C grid:
PE (r, c), tile (h, v) must hold

    T = sigma_p * sum_x a_p[x] * W[x, j],
    i = (ig*P_R + r)*ROWS_PE + h // BA,  p = h % BA,  j = (jg*P_C + c)*8 + v,
    sigma_p = -1 iff p == BA-1,

also recomputed pass by pass (MSB-first Horner over the weight planes, the
hardware order); the two references must agree.  Drain step t of PE row r
delivers PE column P_C-1-t//8, tile column 7-t%8.  The combined outputs,
out = sum_p 2^p T(il*BA + p) per activation row il of the PE, are formed here
from the DRAINED tiles and must equal (A @ W)[i, j] exactly.

Timing:
  * every (block, row, step) drained exactly once, on edge
    E0 + blk*BLK_LEN + (BW-1)*(NB+GAP) + NB + 1 + DS + t (DS = S, or S-1 for
    NEG_DRAIN_EARLY);
  * block period: BLK_LEN is the bench's SCHEDULE (BPGCFG header), and it must
    equal the mode's formula:
        per-PE laps:       BW*NB + 8*(BW-1) + S + 8*P_C
        global laps, wait: BW*NB + (8+S)*(BW-1) + S + 8*P_C
    (tightness controls: GAP = 7, DS = S-1, or BLK_LEN-1).  The RTL run shows
    the schedule is feasible (bit-exact tiles); on multi-block runs the spacing
    of consecutive drain starts in the trace must also equal BLK_LEN
    (measured_periods; empty for single-block runs).  The tightness controls in
    run_bp_grid_checks.sh show that no term of the formula can shrink by one;
  * lap runs (ring_q of every PE, recorded from the RTL): every PE laps (BW-1)
    times per block, 8 edges each, starting at
    B + pi*(NB+GAP) + NB + LO + 1 + (r + c for per-PE laps, 0 for global laps).
Lap runs are checked against the schedule the mode drives (global for the
global-lap modes 1, 4 and 8, per-PE otherwise).  Negative controls must FAIL with tile
mismatches (run_bp_grid_checks.sh requires n_mismatch > 0).

Usage:  check_bp_grid_trace.py RUN_DIR [--json out.json]
RUN_DIR holds bpg_trace.txt, bpt_a.hex, bpt_w.hex.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np

OWIDTH = 24
MODES = {0: "per_pe_laps", 1: "global_lap_wait", 2: "neg_ring_no_row_skew",
         3: "neg_ring_no_col_skew", 4: "neg_global_lap", 5: "neg_gap_short",
         6: "neg_drain_early", 7: "neg_block_overlap", 8: "oldc_unforced"}


def read_hex(path: Path, n: int) -> np.ndarray:
    vals = [int(x, 16) for x in path.read_text().split()]
    if len(vals) != n:
        raise SystemExit(f"{path}: {len(vals)} entries, expected {n}")
    v = np.array(vals, dtype=np.int64)
    return np.where(v >= 128, v - 256, v)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("run_dir", type=Path)
    ap.add_argument("--json", type=Path, dest="json_path")
    args = ap.parse_args()

    lines = (args.run_dir / "bpg_trace.txt").read_text().splitlines()
    if not lines or not lines[0].startswith("BPGCFG"):
        raise SystemExit("missing BPGCFG header")
    cfg = [int(x) for x in lines[0].split()[1:]]
    if len(cfg) != 16:
        raise SystemExit(f"BPGCFG has {len(cfg)} fields, expected 16")
    (pr, pc, ba, bw, L, mrows, ncols, nblk, nb, gap, lo, S, blk_len, e0, mode, junk) = cfg
    rows_pe = 8 // ba
    nig, njg = mrows // (pr * rows_pe), ncols // (pc * 8)
    if nblk != nig * njg or nb != L // 128 or S != pr + pc - 2:
        raise SystemExit("BPGCFG shape fields are inconsistent")
    global_laps = mode in (1, 4, 8)
    exp_lo = S if mode in (1, 8) else (-1 if mode == 5 else 0)
    if lo != exp_lo or gap != 8 + lo:
        raise SystemExit("BPGCFG lap fields are inconsistent with the mode")
    ds = S - 1 if mode == 6 else S          # drain skew
    formula = bw * nb + gap * (bw - 1) + ds + 8 * pc - (1 if mode == 7 else 0)
    formula_per_pe = bw * nb + 8 * (bw - 1) + S + 8 * pc
    formula_global = bw * nb + (8 + S) * (bw - 1) + S + 8 * pc

    drains: dict[tuple[int, int, int], tuple[int, list[int]]] = {}
    laps: dict[tuple[int, int], list[tuple[int, int]]] = {}
    dup = []
    for line in lines[1:]:
        f = line.split()
        if f[0] == "D":
            key = (int(f[1]), int(f[2]), int(f[3]))
            vals = [int(x) for x in f[5:]]
            if len(vals) != 8:
                raise SystemExit(f"D line with {len(vals)} values")
            if key in drains:
                dup.append(key)
            drains[key] = (int(f[4]), vals)
        elif f[0] == "R":
            laps.setdefault((int(f[1]), int(f[2])), []).append((int(f[3]), int(f[4])))
        else:
            raise SystemExit(f"unknown trace record {f[0]!r}")
    want = {(b, r, t) for b in range(nblk) for r in range(pr) for t in range(8 * pc)}
    coverage_ok = set(drains) == want and not dup

    A = read_hex(args.run_dir / "bpt_a.hex", mrows * L).reshape(mrows, L)
    W = read_hex(args.run_dir / "bpt_w.hex", ncols * L).reshape(ncols, L).T   # (L, ncols)
    a_planes = np.stack([((A & ((1 << ba) - 1)) >> p) & 1 for p in range(ba)])   # (ba, mrows, L)
    w_planes = np.stack([((W & ((1 << bw) - 1)) >> q) & 1 for q in range(bw)])   # (bw, L, ncols)
    gemm = A @ W

    mismatches = []
    drain_edge_errors = []
    n_tiles = n_out = 0
    max_abs_out = 0
    for blk in range(nblk):
        ig, jg = divmod(blk, njg)
        d0 = e0 + blk * blk_len + (bw - 1) * (nb + gap) + nb + 1 + ds
        for r in range(pr):
            for t in range(8 * pc):
                c, v = pc - 1 - t // 8, 7 - t % 8
                j = (jg * pc + c) * 8 + v
                rec = drains.get((blk, r, t))
                if rec is not None and rec[0] != d0 + t:
                    drain_edge_errors.append(dict(block=blk, row=r, step=t, edge=rec[0], exp=d0 + t))
                got = rec[1] if rec is not None else None
                tiles = []
                for h in range(8):
                    il, p = divmod(h, ba)
                    i = (ig * pr + r) * rows_pe + il
                    sig_p = -1 if p == ba - 1 else 1
                    t_direct = sig_p * int(a_planes[p, i] @ W[:, j])
                    acc = 0
                    for q in reversed(range(bw)):
                        sig_q = -1 if q == bw - 1 else 1
                        acc = 2 * acc + sig_p * sig_q * int(a_planes[p, i] @ w_planes[q, :, j])
                    if acc != t_direct:
                        raise SystemExit(f"reference self-check failed at block {blk} r{r} c{c} h{h} v{v}")
                    if abs(t_direct) >= (1 << (OWIDTH - 1)):
                        raise SystemExit(f"tile value {t_direct} overflows OWIDTH={OWIDTH}")
                    tiles.append(t_direct)
                    n_tiles += 1
                    if got is not None and got[h] != t_direct:
                        mismatches.append(dict(kind="tile", block=blk, pe=[r, c], h=h, v=v,
                                               got=got[h], exp=t_direct))
                # Combined outputs from the drained tiles (the east-edge combiner's job).
                for il in range(rows_pe):
                    i = (ig * pr + r) * rows_pe + il
                    exp_out = int(gemm[i, j])
                    max_abs_out = max(max_abs_out, abs(exp_out))
                    n_out += 1
                    if got is not None:
                        out = sum((1 << p) * got[il * ba + p] for p in range(ba))
                        if out != exp_out:
                            mismatches.append(dict(kind="combined", block=blk, pe=[r, c], v=v,
                                                   row=i, col=j, got=out, exp=exp_out))

    # Block period: the schedule must match the formula; on multi-block runs the
    # spacing of consecutive drain starts recorded in the trace must equal it.
    starts = [drains[(b, 0, 0)][0] for b in range(nblk) if (b, 0, 0) in drains]
    periods = sorted({b - a for a, b in zip(starts, starts[1:])})
    first_start_ok = bool(starts) and starts[0] == e0 + (bw - 1) * (nb + gap) + nb + 1 + ds
    period_ok = blk_len == formula and (not periods or periods == [blk_len]) and first_start_ok

    # Lap runs of every PE.
    lap_errors = []
    for r in range(pr):
        for c in range(pc):
            off = 0 if global_laps else r + c
            exp_runs = [(e0 + b * blk_len + pi * (nb + gap) + nb + lo + 1 + off, 8)
                        for b in range(nblk) for pi in range(bw - 1)]
            got_runs = sorted(laps.get((r, c), []))
            if got_runs != exp_runs:
                lap_errors.append(dict(pe=[r, c], got=got_runs[:4], exp=exp_runs[:4],
                                       n_got=len(got_runs), n_exp=len(exp_runs)))

    prec = {(8, 8): "INT8", (8, 4): "W4A8", (4, 4): "INT4", (4, 8): "W8A4"}[(ba, bw)]
    macs = nblk * pr * pc * rows_pe * 8 * L
    data_edges = bw * nb
    status = "PASS" if (not mismatches and coverage_ok and not drain_edge_errors and period_ok
                        and not lap_errors) else "FAIL"
    result = dict(
        status=status, mode=MODES.get(mode, mode), grid=f"{pr}x{pc}", precision=prec,
        ba=ba, bw=bw, L=L, mrows=mrows, ncols=ncols, blocks=nblk, nb=nb, junk=junk & 1,
        ring_gate_junk=(junk >> 1) & 1,
        skew=S, drain_skew=ds, block_len=blk_len, block_len_kind="scheduled (feasibility shown by the bit-exact run)",
        measured_periods=periods, first_drain_start_ok=first_start_ok,
        formula_this_mode=formula, formula_per_pe_laps=formula_per_pe,
        formula_global_laps=formula_global,
        per_pass_global_bubbles=(blk_len - formula_per_pe) // max(bw - 1, 1),
        data_edge_utilization=round(data_edges / blk_len, 4),
        coverage_ok=coverage_ok, duplicates=[list(d) for d in dup[:8]],
        tiles_checked=n_tiles, outputs_checked=n_out, macs=macs, max_abs_output=max_abs_out,
        n_mismatch=len(mismatches), mismatches=mismatches[:16],
        n_drain_edge_errors=len(drain_edge_errors), drain_edge_errors=drain_edge_errors[:8],
        period_ok=period_ok, n_lap_errors=len(lap_errors), lap_errors=lap_errors[:8],
        lap_runs_checked=sum(len(v) for v in laps.values()),
    )
    text = json.dumps(result, indent=2) + "\n"
    if args.json_path:
        args.json_path.write_text(text)
    print(text, end="")
    tag = f"{pr}x{pc} {prec} L={L} blocks={nblk} {MODES.get(mode, mode)}" + (" ring_gate_junk" if junk & 2 else "")
    if status != "PASS":
        print(f"[FAIL] {tag}: {len(mismatches)} mismatches, coverage_ok={coverage_ok}, "
              f"drain_edge_errors={len(drain_edge_errors)}, period_ok={period_ok}, "
              f"lap_errors={len(lap_errors)}")
        return 1
    meas = (f"drain-start spacing {periods}" if periods else "single block")
    print(f"[PASS] {tag}: {n_tiles} tiles + {n_out} combined outputs bit-exact ({macs} MACs, "
          f"max|out| {max_abs_out}); scheduled block period {blk_len} = formula ({meas}), "
          f"{result['lap_runs_checked']} lap runs on schedule, data utilization "
          f"{data_edges}/{blk_len} = {data_edges / blk_len:.1%}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
