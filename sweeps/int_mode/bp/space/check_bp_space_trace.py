#!/usr/bin/env python3
"""Bit-exact and timing check of the BP-space (T2) INT benches.

  designs/payn/tb/test_payn_array_bp_space.sv   single-PE top (header BPSCFG,
                                                 trace bps_trace.txt, with the
                                                 east-edge combiner words)
  designs/payn/tb/test_pe_grid_bp_space.sv      PE grid (header BPSGCFG,
                                                 trace bpg_trace.txt)

Independent numpy int64 reference.  S weight bits in space, P = BW/S passes,
CPE = 8/S output columns per PE.  Output block (ig, jg); PE (r, c), tile (h, v):

    i = (ig*P_R + r)*ROWS_PE + h // BA,  pa = h % BA,  sigma_a = -1 iff pa == BA-1
    jj, s = divmod(v, S),  j = (jg*P_C + c)*CPE + jj
    T(h, v) = sigma_a * sum_x a_pa[x] * F_s[x, j]

where F_s is weight-bit field s of W: bits P*s .. P*s+P-1 of the BW-bit
encoding, signed (top bit negative) iff s == S-1, so W = sum_s 2^(P*s) F_s.
T is also recomputed pass by pass in the hardware order (pass pi carries bit
q = p + P*s, p = P-1-pi, MSB pass first; Horner x2 between passes; the sign
path negates iff exactly one of (pa == BA-1), (q == BW-1)); the two references
must agree.  For S = BW (P = 1, "all weight bits in space") this is
T(h, q) = sigma_a * sigma_q * sum_x a_pa[x] * w_q[x, j]: no lap, one pass.

Combined outputs, formed here from the DRAINED tiles, must equal (A @ W)[i, j]:

    out(i, j) = sum_pa 2^pa * sum_s 2^(P*s) * T(il*BA + pa, jj*S + s)

Single-PE top, combiner words: every drained column's C record must equal the
unchanged combiner applied to that column (int_prec = 0: lo = sum_h 2^h T(h),
hi = 0; int_prec = 1: lo = sum_{h<4} 2^h T(h), hi = sum_{h>=4} 2^(h-4) T(h),
mod 2^32) and to the reference tiles; then the Horner accumulate over the drain
edges of one output, east-first (s = S-1 first),

    R <- (R << P) + word   (R cleared on the output's first column)

must equal (A @ W)[i, j] (lo) and, for INT4, (A @ W)[i+1, j] (hi), both with
unbounded integers and with a 32-bit wrapping R.

Timing: every (block, step) drained exactly once, on edge
D0 + t, D0 = E0 + blk*BLK_LEN + (P-1)*(NB+GAP) + NB + 1 + DS; the bench's
BLK_LEN must equal the mode's formula and, for the nominal schedule,
    P*NB + 8*(P-1) + (P_R+P_C-2) + 8*P_C
and the model's T2 (T1 for S = 1) period from
sweeps/int_mode/bp/model_lap_schedules.py; on multi-block runs the spacing of
consecutive drain starts in the trace must equal BLK_LEN (measured_periods).
Ring runs (ring_q of every PE, RTL only): none for P = 1; else (P-1) laps per
block, 8 edges each, from B + pi*(NB+GAP) + NB + LO + 1 + r + c.
Negative controls must FAIL with tile / output mismatches (the run script
requires n_mismatch > 0).

Usage:  check_bp_space_trace.py RUN_DIR [--json out.json] [--no-ring-monitor]
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np

OWIDTH = 24
OUT_W = 32
MODES = {0: "nominal", 1: "neg_wsign", 2: "neg_ring_stray", 3: "neg_drain_miss",
         4: "neg_drain_early", 5: "neg_block_overlap", 6: "neg_gap_short"}
PREC = {(8, 8): "INT8", (8, 4): "W4A8", (4, 4): "INT4", (4, 8): "W8A4"}


def model_period(S: int, prec: str, L: int, pr: int, pc: int):
    """The model's block period (T2 S, or T1 for S = 1); None if unavailable."""
    try:
        sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
        import model_lap_schedules as m   # noqa: E402
    except Exception as exc:   # pragma: no cover
        return None, f"model import failed: {exc}"
    sch = m.Sch("T1") if S == 1 else m.Sch("T2", S)
    if prec not in m.PREC or not m.applies(sch, prec):
        return None, "schedule not in the model"
    return m.block_terms(sch, prec, L, pr, pc)["period"], sch.name


def read_hex(path: Path, n: int) -> np.ndarray:
    vals = [int(x, 16) for x in path.read_text().split()]
    if len(vals) != n:
        raise SystemExit(f"{path}: {len(vals)} entries, expected {n}")
    v = np.array(vals, dtype=np.int64)
    return np.where(v >= 128, v - 256, v)


def wrap(x: int, bits: int) -> int:
    x &= (1 << bits) - 1
    return x - (1 << bits) if x >> (bits - 1) else x


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("run_dir", type=Path)
    ap.add_argument("--json", type=Path, dest="json_path")
    ap.add_argument("--no-ring-monitor", action="store_true",
                    help="trace has no R records (gate-level run): skip the ring-run check")
    args = ap.parse_args()

    p1_trace, grid_trace = args.run_dir / "bps_trace.txt", args.run_dir / "bpg_trace.txt"
    trace = p1_trace if p1_trace.exists() else grid_trace
    lines = trace.read_text().splitlines()
    if not lines:
        raise SystemExit(f"{trace}: empty")
    head = lines[0].split()
    cfg = [int(x) for x in head[1:]]
    if head[0] == "BPSCFG":
        if len(cfg) != 20:
            raise SystemExit(f"BPSCFG has {len(cfg)} fields, expected 20")
        (ba, bw, S, L, mrows, ncols, nblk, nb, P, cpe, blk_len, e0, ds, int_prec, junk,
         n_wsign, n_stray, n_miss, n_early, n_overlap) = cfg
        kind, pr, pc, gap, lo, sk = "single_pe_top", 1, 1, 8, 0, 0
        mode = (1 if n_wsign else 2 if n_stray else 3 if n_miss else 4 if n_early
                else 5 if n_overlap else 0)
        if sum((n_wsign, n_stray, n_miss, n_early, n_overlap)) > 1:
            raise SystemExit("more than one negative control in one run")
        if ds != (-1 if n_early else 0):
            raise SystemExit("BPSCFG drain offset inconsistent")
    elif head[0] == "BPSGCFG":
        if len(cfg) != 20:
            raise SystemExit(f"BPSGCFG has {len(cfg)} fields, expected 20")
        (pr, pc, ba, bw, S, L, mrows, ncols, nblk, nb, P, cpe, gap, lo, sk, ds, blk_len, e0,
         mode, junk) = cfg
        kind, int_prec = f"grid_{pr}x{pc}", int(ba == 4)
        if sk != pr + pc - 2:
            raise SystemExit("BPSGCFG skew inconsistent")
        if lo != (-1 if mode == 6 else 0) or gap != 8 + lo or ds != (sk - 1 if mode == 4 else sk):
            raise SystemExit("BPSGCFG lap / drain fields inconsistent with the mode")
    else:
        raise SystemExit(f"unknown trace header {head[0]!r}")
    rows_pe = 8 // ba
    if P != bw // S or cpe != 8 // S or nb != L // 128 or bw % S:
        raise SystemExit("header S / P / CPE / NB inconsistent")
    nig, njg = mrows // (pr * rows_pe), ncols // (pc * cpe)
    if nblk != nig * njg or mrows % (pr * rows_pe) or ncols % (pc * cpe):
        raise SystemExit("header shape fields inconsistent")
    prec = PREC[(ba, bw)]
    formula_nominal = P * nb + 8 * (P - 1) + sk + 8 * pc
    formula_mode = P * nb + gap * (P - 1) + ds + 8 * pc - (1 if mode == 5 else 0)
    mperiod, mname = model_period(S, prec, L, pr, pc)

    # ------------------------------------------------------------ parse --
    drains: dict[tuple[int, int, int], list[int]] = {}
    dedge: dict[tuple[int, int, int], int] = {}
    combs: dict[tuple[int, int], tuple[int, int]] = {}
    laps: dict[tuple[int, int], list[tuple[int, int]]] = {}
    dup = []
    for line in lines[1:]:
        f = line.split()
        if kind == "single_pe_top":
            if f[0] == "D":
                key = (int(f[1]), 0, int(f[2]))
                vals = [int(x) for x in f[3:]]
                if key in drains:
                    dup.append(("D",) + key)
                drains[key] = vals
            elif f[0] == "E":
                dedge[(int(f[1]), 0, int(f[2]))] = int(f[3])
            elif f[0] == "C":
                key = (int(f[1]), int(f[2]))
                if key in combs:
                    dup.append(("C",) + key)
                combs[key] = (int(f[3]), int(f[4]))
            elif f[0] == "R":
                laps.setdefault((0, 0), []).append((int(f[1]), int(f[2])))
            else:
                raise SystemExit(f"unknown trace record {f[0]!r}")
        else:
            if f[0] == "D":
                key = (int(f[1]), int(f[2]), int(f[3]))
                vals = [int(x) for x in f[5:]]
                if key in drains:
                    dup.append(("D",) + key)
                drains[key] = vals
                dedge[key] = int(f[4])
            elif f[0] == "R":
                laps.setdefault((int(f[1]), int(f[2])), []).append((int(f[3]), int(f[4])))
            else:
                raise SystemExit(f"unknown trace record {f[0]!r}")
        if f[0] == "D" and len(drains[key]) != 8:
            raise SystemExit(f"D record with {len(drains[key])} values")
    want = {(b, r, t) for b in range(nblk) for r in range(pr) for t in range(8 * pc)}
    coverage_ok = set(drains) == want and set(dedge) == want and not dup
    if kind == "single_pe_top":
        coverage_ok = coverage_ok and set(combs) == {(b, t) for b in range(nblk) for t in range(8)}

    # --------------------------------------------------------- reference --
    A = read_hex(args.run_dir / "bpt_a.hex", mrows * L).reshape(mrows, L)
    W = read_hex(args.run_dir / "bpt_w.hex", ncols * L).reshape(ncols, L).T   # (L, ncols)
    a_lo, a_hi = -(1 << (ba - 1)), (1 << (ba - 1)) - 1
    w_lo, w_hi = -(1 << (bw - 1)), (1 << (bw - 1)) - 1
    if A.min() < a_lo or A.max() > a_hi or W.min() < w_lo or W.max() > w_hi:
        raise SystemExit("operands outside the declared precision")
    Au, Wu = A & ((1 << ba) - 1), W & ((1 << bw) - 1)
    a_planes = np.stack([(Au >> p) & 1 for p in range(ba)])            # (ba, mrows, L)
    w_planes = np.stack([(Wu >> q) & 1 for q in range(bw)])            # (bw, L, ncols)
    fields = []
    for s in range(S):
        f = (Wu >> (P * s)) & ((1 << P) - 1)
        if s == S - 1:
            f = np.where(f >= (1 << (P - 1)), f - (1 << P), f)
        fields.append(f)
    if not np.array_equal(sum((1 << (P * s)) * fields[s] for s in range(S)), W):
        raise SystemExit("reference self-check failed: weight fields do not recompose W")
    gemm = A @ W

    exp_tiles: dict[tuple[int, int, int, int, int], int] = {}   # (blk, r, c, h, v)
    mismatches = []
    max_abs_tile = 0
    for blk in range(nblk):
        ig, jg = divmod(blk, njg)
        for r in range(pr):
            for c in range(pc):
                for v in range(8):
                    jj, s = divmod(v, S)
                    j = (jg * pc + c) * cpe + jj
                    for h in range(8):
                        il, pa = divmod(h, ba)
                        i = (ig * pr + r) * rows_pe + il
                        sig_a = -1 if pa == ba - 1 else 1
                        t_field = sig_a * int(a_planes[pa, i] @ fields[s][:, j])
                        acc = 0
                        for pi in range(P):
                            q = (P - 1 - pi) + P * s
                            sig_q = -1 if q == bw - 1 else 1
                            acc = 2 * acc + sig_a * sig_q * int(a_planes[pa, i] @ w_planes[q, :, j])
                        if acc != t_field:
                            raise SystemExit(f"reference self-check failed at block {blk} pe ({r},{c}) h{h} v{v}")
                        if abs(t_field) >= (1 << (OWIDTH - 1)):
                            raise SystemExit(f"tile value {t_field} overflows OWIDTH={OWIDTH}")
                        exp_tiles[(blk, r, c, h, v)] = t_field
                        max_abs_tile = max(max_abs_tile, abs(t_field))

    # Drained tiles.
    got_tiles: dict[tuple[int, int, int, int], list[int]] = {}   # (blk, r, c, v) -> 8 rows
    for (blk, r, t), vals in drains.items():
        if blk >= nblk or r >= pr or t >= 8 * pc:
            mismatches.append(dict(kind="unexpected_drain", block=blk, row=r, step=t))
            continue
        c, v = pc - 1 - t // 8, 7 - t % 8
        got_tiles[(blk, r, c, v)] = vals
        for h in range(8):
            exp = exp_tiles[(blk, r, c, h, v)]
            if vals[h] != exp:
                mismatches.append(dict(kind="tile", block=blk, pe=[r, c], h=h, v=v, got=vals[h], exp=exp))

    # Combined outputs from the drained tiles.
    n_out = max_abs_out = 0
    for blk in range(nblk):
        ig, jg = divmod(blk, njg)
        for r in range(pr):
            for c in range(pc):
                for jj in range(cpe):
                    j = (jg * pc + c) * cpe + jj
                    for il in range(rows_pe):
                        i = (ig * pr + r) * rows_pe + il
                        exp_out = int(gemm[i, j])
                        max_abs_out = max(max_abs_out, abs(exp_out))
                        n_out += 1
                        cols = [got_tiles.get((blk, r, c, jj * S + s)) for s in range(S)]
                        if any(col is None for col in cols):
                            continue
                        out = sum((1 << pa) * (1 << (P * s)) * cols[s][il * ba + pa]
                                  for s in range(S) for pa in range(ba))
                        if out != exp_out:
                            mismatches.append(dict(kind="combined", block=blk, pe=[r, c], row=i, col=j,
                                                   got=out, exp=exp_out))

    # Single-PE top: combiner words and the Horner accumulate across drain edges.
    n_words = n_horner = 0
    horner_bits = 0
    if kind == "single_pe_top":
        def comb_word(col):
            if int_prec:
                lo_w = sum((1 << h) * col[h] for h in range(4))
                hi_w = sum((1 << (h - 4)) * col[h] for h in range(4, 8))
            else:
                lo_w, hi_w = sum((1 << h) * col[h] for h in range(8)), 0
            return wrap(lo_w, OUT_W), wrap(hi_w, OUT_W)
        for blk in range(nblk):
            ig, jg = divmod(blk, njg)
            R = [0, 0]
            R32 = [0, 0]
            for t in range(8):
                v = 7 - t
                jj, s = divmod(v, S)
                j = jg * cpe + jj
                word = combs.get((blk, t))
                col_got = got_tiles.get((blk, 0, 0, v))
                col_exp = [exp_tiles[(blk, 0, 0, h, v)] for h in range(8)]
                if word is not None:
                    n_words += 1
                    if word != comb_word(col_exp):
                        mismatches.append(dict(kind="combiner_word", block=blk, step=t, got=list(word),
                                               exp=list(comb_word(col_exp))))
                    if col_got is not None and word != comb_word(col_got):
                        mismatches.append(dict(kind="combiner_vs_tiles", block=blk, step=t, got=list(word),
                                               from_tiles=list(comb_word(col_got))))
                if s == S - 1:
                    R, R32 = [0, 0], [0, 0]
                w2 = word if word is not None else (None, None)
                for k in range(2):
                    if w2[k] is None:
                        R[k] = R32[k] = None
                    elif R[k] is not None:
                        R[k] = (R[k] << P) + w2[k]
                        R32[k] = wrap((R32[k] << P) + w2[k], OUT_W)
                        horner_bits = max(horner_bits, abs(R[k]).bit_length() + 1)
                if s == 0:
                    i0 = ig * rows_pe
                    exp = [int(gemm[i0, j]), int(gemm[i0 + 1, j]) if rows_pe == 2 else 0]
                    n_horner += 1
                    for k in range(2):
                        if R[k] is None or R[k] != exp[k] or R32[k] != wrap(exp[k], OUT_W):
                            mismatches.append(dict(kind="horner", block=blk, col=j, half=k,
                                                   got=R[k], got32=R32[k], exp=exp[k]))

    # ------------------------------------------------------------ timing --
    drain_edge_errors = []
    for (blk, r, t), e in dedge.items():
        d0 = e0 + blk * blk_len + (P - 1) * (nb + gap) + nb + 1 + ds
        if e != d0 + t:
            drain_edge_errors.append(dict(block=blk, row=r, step=t, edge=e, exp=d0 + t))
    starts = [dedge[(b, 0, 0)] for b in range(nblk) if (b, 0, 0) in dedge]
    periods = sorted({b - a for a, b in zip(starts, starts[1:])})
    first_start_ok = bool(starts) and starts[0] == e0 + (P - 1) * (nb + gap) + nb + 1 + ds
    period_ok = (blk_len == formula_mode and (not periods or periods == [blk_len]) and first_start_ok)
    model_ok = mperiod is None or formula_nominal == mperiod
    if mode not in (4, 5, 6):
        period_ok = period_ok and blk_len == formula_nominal and model_ok

    lap_errors = []
    if not args.no_ring_monitor:
        for r in range(pr):
            for c in range(pc):
                exp_runs = [(e0 + b * blk_len + pi * (nb + gap) + nb + lo + 1 + r + c, 8)
                            for b in range(nblk) for pi in range(P - 1)]
                got_runs = sorted(laps.get((r, c), []))
                if got_runs != exp_runs:
                    lap_errors.append(dict(pe=[r, c], got=got_runs[:4], exp=exp_runs[:4],
                                           n_got=len(got_runs), n_exp=len(exp_runs)))

    outs_pe = rows_pe * cpe
    macs = nblk * pr * pc * outs_pe * L
    status = "PASS" if (not mismatches and coverage_ok and not drain_edge_errors and period_ok
                        and not lap_errors) else "FAIL"
    result = dict(
        status=status, kind=kind, mode=MODES.get(mode, mode), grid=f"{pr}x{pc}", precision=prec,
        ba=ba, bw=bw, S=S, P=P, cols_per_pe=cpe, outputs_per_pe=outs_pe, L=L, mrows=mrows,
        ncols=ncols, blocks=nblk, nb=nb, junk=junk, int_prec=int_prec,
        skew=sk, drain_skew=ds, block_len=blk_len,
        block_len_kind="scheduled; feasible iff the run is bit-exact, minimal iff the one-edge-short controls fail",
        measured_periods=periods, first_drain_start_ok=first_start_ok,
        formula_this_mode=formula_mode, formula_nominal=formula_nominal,
        model_schedule=mname, model_period=mperiod, model_matches_formula=model_ok,
        data_edges=P * nb, data_edge_utilization=round(P * nb / blk_len, 4),
        edges_per_output_per_pe=round(blk_len / outs_pe, 3),
        coverage_ok=coverage_ok, duplicates=[list(d) for d in dup[:8]],
        tiles_checked=len(exp_tiles), outputs_checked=n_out, combiner_words_checked=n_words,
        horner_outputs_checked=n_horner, horner_acc_bits_needed=horner_bits,
        macs=macs, max_abs_tile=max_abs_tile, max_abs_output=max_abs_out,
        n_mismatch=len(mismatches), mismatches=mismatches[:16],
        n_drain_edge_errors=len(drain_edge_errors), drain_edge_errors=drain_edge_errors[:8],
        period_ok=period_ok, n_lap_errors=len(lap_errors), lap_errors=lap_errors[:8],
        lap_runs_seen=sum(len(v) for v in laps.values()), ring_monitor=not args.no_ring_monitor,
    )
    text = json.dumps(result, indent=2) + "\n"
    if args.json_path:
        args.json_path.write_text(text)
    print(text, end="")
    tag = f"{kind} {prec} S={S} L={L} blocks={nblk} {MODES.get(mode, mode)}" + (" junk" if junk else "")
    if status != "PASS":
        print(f"[FAIL] {tag}: {len(mismatches)} mismatches, coverage_ok={coverage_ok}, "
              f"drain_edge_errors={len(drain_edge_errors)}, period_ok={period_ok}, "
              f"lap_errors={len(lap_errors)}")
        return 1
    meas = f"drain-start spacing {periods}" if periods else "single block"
    extra = (f", {n_words} combiner words + {n_horner} Horner outputs" if kind == "single_pe_top" else "")
    print(f"[PASS] {tag}: {len(exp_tiles)} tiles + {n_out} combined outputs bit-exact{extra} "
          f"({macs} MACs, max|out| {max_abs_out}); block period {blk_len} = formula = model {mname} "
          f"{mperiod} ({meas}); {result['lap_runs_seen']} lap runs; data utilization "
          f"{P * nb}/{blk_len} = {P * nb / blk_len:.1%}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
