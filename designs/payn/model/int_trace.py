#!/usr/bin/env python3
"""Schedule models and trace checkers of the INT-mode benches of payn_array (both INT schedules).

INT mode streams raw two's-complement bit planes through the AF bypass into 8x8 tiles of 24-bit accumulators per
PE.  A data cycle carries K*M = 128 reduction elements (K8/M16 or K16/M8: element x = 128*b + M*k + m), so a pass
over L elements is NB = L / 128 data cycles whichever the shape.  A lap is one ring_q edge that doubles every tile in
place (mod 2^24); a drain edge reads the east tile column and shifts the tiles east.  Every reference below is an
independent numpy int64 computation from the operand files (int_workload.py); none depends on the lane packing.

Bit-plane schedule (bp).  A bits in space: tile row h of PE row r holds plane p = h % BA of activation row
i = (ig*P_R + r)*ROWS_PE + h // BA (ROWS_PE = 8 // BA); W bits in time, BW passes MSB first, one lap between
passes.  Tile (h, v) of block (ig, jg) must end at

    T = sigma_p * sum_x a_p[x] * W[x, j],   j = (jg*P_C + c)*8 + v,   sigma_p = -1 iff p == BA-1,

cross-checked against the MSB-first Horner over the weight planes (sign sigma_p * sigma_q, the hardware order).
The east combiner forms out = sum_p 2^p T(il*BA + p) per activation row il, which must equal (A @ W)[i, j].
Block period BW*NB + (BW-1) + (P_R+P_C-2) + 8*P_C.

All-bits-in-time schedule (abit).  Tile (h, v) of block (ig, jg) holds C[ig*8 + h, jg*8 + v] (raw acc_out_east
readout); one pass of NB captures per bit pair (p, q), W sign (p == BA-1) XOR (q == BW-1), levels p+q MSB first in
steps of one, passes of a level contiguous with no lap, one bubble and one lap (on the next level's first capture)
per level step, drain S = P_R+P_C-2 edges after the edge following the last capture, the last drain edge being the
next block's first capture.  Block period BA*BW*NB + (BA+BW-2) + (P_R+P_C-2) + 8*P_C.

Subcommands (RUN_DIR holds the bench's trace and bpt_a.hex / bpt_w.hex):
  bp          single-PE functional bench (+MODE=int, and each INT segment of +MODE=switch), bpt_trace.txt: every
              drained tile and combiner word bit-exact, every (block, step) exactly once
  bp-grid     P_R x P_C grid bench, bpg_trace.txt: drained tiles and combined outputs bit-exact, drain edges, lap runs
              of every PE, scheduled and measured block period for the bench's lap mode
  bp-power    INT energy bench: bp on the trace plus bpe_saif.txt (SAIF window counts per class and segments,
              edge bookkeeping, the lap contract: --lap-ring-only = shift_in on drain edges only)
  abit        single-PE functional bench (+MODE=abit), abit_trace.txt: drained values vs the GEMM, schedule rules
              on the logged stimulus, measured block periods, and the edge replay of the logged stimulus
  abit-grid   abit grid bench, abit_grid_trace.txt: as abit (no replay) plus drain edges and the per-PE lap wave
  abit-power  abit INT energy bench: abit plus D-record edges and abit_saif.txt window counts
Each prints a JSON record (also written to --json) and one [PASS] / [FAIL] line, exit 1 on failure.  abit and
abit-grid take --expect-fail for negative controls: [CAUGHT] (exit 0) only when the drained values differ from the
GEMM (abit: while the RTL still equals the replay, i.e. the hardware did what the wrong schedule says).
--shape k8m16|k16m8 (default k8m16) names the data-cycle shape; a non-default shape is recorded in the JSON.

Usage:  int_trace.py {bp,bp-grid,bp-power,abit,abit-grid,abit-power} RUN_DIR [--json out.json] [--shape S]
            [--lap-ring-only (bp-power)] [--expect-fail (abit, abit-grid)]
"""
from __future__ import annotations

import argparse
import json
from collections import defaultdict
from pathlib import Path

import numpy as np

from int_workload import OWIDTH, SHAPES, elements_per_cycle, read_operands

MOD = 1 << OWIDTH
OUT_W = 32                                       # bit-plane combiner word
BPT_FIELDS = ("ba", "bw", "L", "mrows", "ncols", "nblk", "nb", "int_prec", "junk", "neg_no_ring", "neg_prec",
              "lap_ring_only", "neg_mag", "mode_at", "neg_ring_stray")
BPG_FIELDS = ("pr", "pc", "ba", "bw", "L", "mrows", "ncols", "nblk", "nb", "gap", "lo", "S", "blk_len", "e0",
              "mode", "junk", "lap_len")
GRID_MODES = {0: "per_pe_laps", 1: "global_lap_wait", 2: "neg_ring_no_row_skew", 3: "neg_ring_no_col_skew",
              4: "neg_global_lap", 5: "neg_gap_short", 6: "neg_drain_early", 7: "neg_block_overlap",
              8: "oldc_unforced"}
ABIT_FIELDS = ("ba", "bw", "L", "mrows", "ncols", "nblk", "nb", "e0", "e_end", "blk_len", "d0", "formula_bench",
               "nlev", "junk", "mode_at", "neg_no_lap", "neg_extra_lap", "neg_sign", "neg_order", "neg_no_bubble",
               "neg_drain_early", "neg_overlap", "park_cyc0")
ABITG_FIELDS = ("pr", "pc", "ba", "bw", "L", "mrows", "ncols", "nblk", "nb", "e0", "e_end", "blk_len", "d0", "ds",
                "formula_bench", "nlev", "junk", "neg_row", "neg_col", "neg_no_bubble", "neg_drain_early",
                "neg_overlap", "neg_no_lap", "neg_extra_lap", "neg_sign", "neg_order")


# ----------------------------------------------------------------------------------------------- shared model --
def precision_name(ba: int, bw: int) -> str:
    return f"INT{ba}" if ba == bw else f"W{bw}A{ba}"


def bp_period(bw: int, nb: int, pr: int = 1, pc: int = 1, lap_len: int = 1) -> int:
    """Bit-plane block period with per-PE laps of lap_len edges (1: the in-place doubling lap)."""
    return bw * nb + lap_len * (bw - 1) + (pr + pc - 2) + 8 * pc


def abit_period(ba: int, bw: int, nb: int, pr: int = 1, pc: int = 1) -> int:
    return ba * bw * nb + (ba + bw - 2) + (pr + pc - 2) + 8 * pc


def wrap(v):
    """Signed OWIDTH-bit value of an integer (or int64 array)."""
    v = np.asarray(v, dtype=np.int64) % MOD
    return np.where(v >= MOD // 2, v - MOD, v)


def bit_planes(x: np.ndarray, bits: int) -> list[np.ndarray]:
    return [((x & ((1 << bits) - 1)) >> p) & 1 for p in range(bits)]


def header(path: Path, tag: str) -> tuple[list[int], list[str]]:
    lines = path.read_text().splitlines()
    if not lines or not lines[0].startswith(tag):
        raise SystemExit(f"missing {tag} header")
    return [int(x) for x in lines[0].split()[1:]], lines[1:]


def bp_tiles(A: np.ndarray, W: np.ndarray, ba: int, bw: int) -> list[np.ndarray]:
    """[T_p] with T_p[i, j] = sigma_p * a_p[i] @ W[:, j], each equal to the MSB-first Horner over the W planes."""
    a_pl, w_pl, out = bit_planes(A, ba), bit_planes(W, bw), []
    for p in range(ba):
        sig_p = -1 if p == ba - 1 else 1
        direct = sig_p * (a_pl[p] @ W)
        acc = np.zeros_like(direct)
        for q in reversed(range(bw)):
            acc = 2 * acc + sig_p * (-1 if q == bw - 1 else 1) * (a_pl[p] @ w_pl[q])
        if not np.array_equal(acc, direct):
            raise SystemExit(f"reference self-check failed at activation plane {p}")
        out.append(direct)
    return out


def tile_value(T: list[np.ndarray], i: int, p: int, j: int) -> int:
    t = int(T[p][i, j])
    if abs(t) >= (1 << (OWIDTH - 1)):
        raise SystemExit(f"tile value {t} overflows OWIDTH={OWIDTH}")
    return t


def emit(result: dict, json_path: Path | None, line: str, ok: bool, shape: str) -> int:
    if shape != "k8m16":
        result["shape"] = shape
    text = json.dumps(result, indent=2) + "\n"
    if json_path:
        json_path.write_text(text)
    print(text, end="")
    print(line)
    return 0 if ok else 1


# ------------------------------------------------------------------------------------------- bit-plane: 1 PE --
def check_bp(run_dir: Path, dc: int = 128) -> dict:
    cfg, body = header(run_dir / "bpt_trace.txt", "BPTCFG")
    # 15 fields from the functional bench; the energy bench writes 14 (no neg_ring_stray).
    if len(cfg) not in (14, 15):
        raise SystemExit(f"BPTCFG has {len(cfg)} fields, expected 14 or 15")
    c = dict(zip(BPT_FIELDS, cfg + [0]))
    ba, bw, L, mrows, ncols, nblk, nb = (c[k] for k in BPT_FIELDS[:7])
    rows_pe, njg = 8 // ba, ncols // 8
    if nblk != (mrows // rows_pe) * njg or nb != L // dc:
        raise SystemExit("BPTCFG shape fields are inconsistent")
    drains: dict[tuple[int, int], list[int]] = {}
    combs: dict[tuple[int, int], tuple[int, int]] = {}
    dup = []
    for line in body:
        f = line.split()
        if f[0] == "D":
            key, vals = (int(f[1]), int(f[2])), [int(x) for x in f[3:]]
            if len(vals) != 8:
                raise SystemExit(f"D line with {len(vals)} values")
            if key in drains:
                dup.append(("D",) + key)
            drains[key] = vals
        elif f[0] == "C":
            key = (int(f[1]), int(f[2]))
            if key in combs:
                dup.append(("C",) + key)
            combs[key] = (int(f[3]), int(f[4]))
        else:
            raise SystemExit(f"unknown trace record {f[0]!r}")
    want = {(b, t) for b in range(nblk) for t in range(8)}
    coverage_ok = set(drains) == want and set(combs) == want and not dup

    A, W = read_operands(run_dir, ba, bw, mrows, ncols, L)
    gemm = A @ W
    if np.abs(gemm).max() >= (1 << (OUT_W - 1)):
        raise SystemExit("GEMM output exceeds the 32-bit combiner word; workload invalid")
    T = bp_tiles(A, W, ba, bw)
    mismatches = []
    max_abs_tile = max_abs_out = 0
    for blk in range(nblk):
        ig, jg = divmod(blk, njg)
        for t in range(8):                       # drain step t carries tile column v = 7 - t
            v = 7 - t
            j = jg * 8 + v
            got_tiles = drains.get((blk, t))
            for h in range(8):
                il, p = divmod(h, ba)
                exp = tile_value(T, ig * rows_pe + il, p, j)
                max_abs_tile = max(max_abs_tile, abs(exp))
                if got_tiles is not None and got_tiles[h] != exp:
                    mismatches.append(dict(kind="tile", block=blk, step=t, h=h, v=v, got=got_tiles[h], exp=exp))
            exp_lo = int(gemm[ig * rows_pe, j])
            exp_hi = int(gemm[ig * rows_pe + 1, j]) if rows_pe == 2 else 0
            max_abs_out = max(max_abs_out, abs(exp_lo), abs(exp_hi))
            got = combs.get((blk, t))
            if got is not None and got != (exp_lo, exp_hi):
                mismatches.append(dict(kind="combiner", block=blk, step=t, col=j, got=list(got),
                                       exp=[exp_lo, exp_hi]))
            if got is not None and got_tiles is not None:
                g = [sum((1 << p) * got_tiles[il * ba + p] for p in range(ba)) for il in range(rows_pe)]
                g += [0] * (2 - rows_pe)
                if list(got) != g:
                    mismatches.append(dict(kind="combiner_vs_tiles", block=blk, step=t, got=list(got),
                                           from_tiles=g))
    return dict(
        status="PASS" if not mismatches and coverage_ok else "FAIL",
        precision=precision_name(ba, bw), ba=ba, bw=bw, L=L, mrows=mrows, ncols=ncols, blocks=nblk, nb=nb,
        int_prec=c["int_prec"], junk=c["junk"], neg_no_ring=c["neg_no_ring"], neg_prec=c["neg_prec"],
        lap_ring_only=c["lap_ring_only"], neg_no_lap_shift=c["lap_ring_only"], neg_ring_stray=c["neg_ring_stray"],
        neg_mag=c["neg_mag"], mode_at=c["mode_at"],
        coverage_ok=coverage_ok, duplicates=dup[:8],
        tiles_checked=nblk * 64, outputs_checked=nblk * rows_pe * 8, macs=nblk * rows_pe * 8 * L,
        max_abs_tile=max_abs_tile, max_abs_output=max_abs_out,
        n_mismatch=len(mismatches), mismatches=mismatches[:16],
    )


def bp_verdict(r: dict) -> tuple[bool, str]:
    tag = f"{r['precision']} L={r['L']} blocks={r['blocks']}"
    if r["status"] != "PASS":
        return False, f"[FAIL] {tag}: {r['n_mismatch']} mismatches, coverage_ok={r['coverage_ok']}"
    return True, (f"[PASS] {tag}: {r['tiles_checked']} tiles and {r['outputs_checked']} GEMM outputs bit-exact "
                  f"({r['macs']} MACs, max|out| {r['max_abs_output']})")


# ---------------------------------------------------------------------------------------- bit-plane: energy --
def check_bp_power(run_dir: Path, lap_ring_only: bool, dc: int = 128) -> tuple[dict, list[str]]:
    """bp on the trace, then bpe_saif.txt against the schedule (one-edge laps):
         data  = blocks * BW * NB              (every mode)
         ring  = blocks * (BW - 1)             (modes 0, 2, 4)
         drain = blocks * 8                    (mode 2)
         segments = blocks (modes 0, 4), blocks * BW (modes 1, 3), 1 (mode 2)
       (modes 3 / 4: the windows of 1 / 0 classed by cause), E_END = E0 + blocks * period, N_EDGES = E_END + 3,
       BPELAP 1 (NB+1) (NB+8) period, and the trace header's lap_ring_only as the driver expects."""
    g, reasons = 1, []
    try:
        inner = check_bp(run_dir, dc)
        ok, line = bp_verdict(inner)
    except SystemExit as e:
        inner, ok, line = None, False, str(e.code)
    if not ok:
        reasons.append(f"int_trace.py bp failed (rc=1): {line}")
    path = run_dir / "bpe_saif.txt"
    rec = {s.split()[0]: [int(x) for x in s.split()[1:]] for s in path.read_text().splitlines() if s.strip()}
    if len(rec.get("BPECFG", [])) != 12 or len(rec.get("SAIFWIN", [])) != 5:
        raise SystemExit(f"{path}: malformed (need BPECFG x12, SAIFWIN x5)")
    ba, bw, L, mrows, ncols, nblk, nb, mode, mode_at, e0, e_end, n_edges = rec["BPECFG"]
    win = dict(zip(("active", "data", "ring", "drain", "segments"), rec["SAIFWIN"]))
    if inner is not None:
        for key, val in (("ba", ba), ("bw", bw), ("L", L), ("mrows", mrows), ("ncols", ncols),
                         ("blocks", nblk), ("nb", nb), ("mode_at", mode_at)):
            if inner.get(key) != val:
                reasons.append(f"bpe_saif.txt {key}={val} disagrees with the trace header ({inner.get(key)})")
        for key in ("junk", "neg_no_ring", "neg_prec", "neg_mag", "neg_ring_stray"):
            if inner.get(key) != 0:
                reasons.append(f"trace header has {key}={inner.get(key)}; an energy run must have 0")
        if inner.get("lap_ring_only") != int(lap_ring_only):
            reasons.append(f"trace header has lap_ring_only={inner.get('lap_ring_only')}; "
                           f"the driver expected {int(lap_ring_only)}")
        if inner.get("int_prec") != (1 if ba == 4 else 0):
            reasons.append(f"int_prec={inner.get('int_prec')} for BA={ba}")
    if mode not in (0, 1, 2, 3, 4):
        reasons.append(f"SAIF mode {mode} is not 0, 1, 2, 3 or 4")
    blk_len = bp_period(bw, nb, lap_len=g)
    exp_e_end = e0 + nblk * blk_len
    if e_end != exp_e_end or n_edges != e_end + 3:
        reasons.append(f"edge bookkeeping E_END={e_end} N_EDGES={n_edges}, expected {exp_e_end} / {exp_e_end + 3}")
    want_lap = [g, nb + g, nb + 8, blk_len]
    if rec.get("BPELAP") != want_lap:
        reasons.append(f"bpe_saif.txt BPELAP {rec.get('BPELAP')}, expected {want_lap}")
    exp = dict(data=nblk * bw * nb, ring=nblk * (bw - 1) * g if mode in (0, 2, 4) else 0,
               drain=nblk * 8 if mode == 2 else 0)
    exp["active"] = exp["data"] + exp["ring"] + exp["drain"]
    exp["segments"] = {0: nblk, 1: nblk * bw, 2: 1, 3: nblk * bw, 4: nblk}.get(mode, -1)
    for key, val in exp.items():
        if win[key] != val:
            reasons.append(f"SAIF window {key}={win[key]}, expected {val}")
    mac_per_data_cycle = 64 * dc // (ba * bw)
    macs = win["data"] * mac_per_data_cycle
    if inner is not None and macs != inner.get("macs"):
        reasons.append(f"window MACs {macs} != checked MACs {inner.get('macs')}")
    inner_ = inner or {}
    result = dict(
        status="FAIL" if reasons else "PASS", rejection_reasons=reasons,
        precision=precision_name(ba, bw), ba=ba, bw=bw, L=L, mrows=mrows, ncols=ncols,
        blocks=nblk, nb=nb, saif_mode=mode, mode_at=mode_at, e0=e0, e_end=e_end, n_edges=n_edges,
        lap_ring_only=inner_.get("lap_ring_only"), lap_len=g,
        saif_window=win, expected_saif_window=exp, mac_per_data_cycle=mac_per_data_cycle, macs=macs,
        tiles_checked=inner_.get("tiles_checked"), outputs_checked=inner_.get("outputs_checked"),
        max_abs_tile=inner_.get("max_abs_tile"), max_abs_output=inner_.get("max_abs_output"),
        n_mismatch=inner_.get("n_mismatch"), trace_check=inner,
    )
    return result, reasons


def bp_power_verdict(r: dict, reasons: list[str]) -> tuple[bool, str]:
    tag = f"{r['precision']} L={r['L']} blocks={r['blocks']} mode={r['saif_mode']}"
    if reasons:
        return False, f"[FAIL] {tag}: " + "; ".join(reasons)
    w = r["saif_window"]
    return True, (f"[PASS] {tag} lap_ring_only={r['lap_ring_only']} lap_len={r['lap_len']}: {r['tiles_checked']} "
                  f"tiles and {r['outputs_checked']} GEMM outputs bit-exact ({r['macs']} MACs, max|out| "
                  f"{r['max_abs_output']}); SAIF window {w['active']} = {w['data']} data + {w['ring']} ring + "
                  f"{w['drain']} drain in {w['segments']} segment(s)")


# ------------------------------------------------------------------------------------------ bit-plane: grid --
def check_bp_grid(run_dir: Path, dc: int = 128) -> dict:
    """Drained tiles of PE row r, step t (PE column P_C-1-t//8, tile column 7-t%8) on edge
    E0 + blk*BLK_LEN + (BW-1)*(NB+GAP) + NB + 1 + DS + t (GAP = LAP_LEN + LO, DS = S, or S-1 for neg_drain_early);
    BLK_LEN (the bench's schedule) equal to the mode's formula and to the measured drain-start spacing; PE (r, c)
    laps (BW-1) times per block, LAP_LEN edges each, from B + pi*(NB+GAP) + NB + LO + 1 + (r + c, or 0 for the
    global-lap modes 1, 4, 8).  Negative controls must fail with tile mismatches (the driver requires them)."""
    cfg, body = header(run_dir / "bpg_trace.txt", "BPGCFG")
    if len(cfg) != 17:
        raise SystemExit(f"BPGCFG has {len(cfg)} fields, expected 17")
    pr, pc, ba, bw, L, mrows, ncols, nblk, nb, gap, lo, S, blk_len, e0, mode, junk, lap_len = cfg
    rows_pe = 8 // ba
    njg = ncols // (pc * 8)
    if nblk != (mrows // (pr * rows_pe)) * njg or nb != L // dc or S != pr + pc - 2:
        raise SystemExit("BPGCFG shape fields are inconsistent")
    global_laps = mode in (1, 4, 8)
    if lo != (S if mode in (1, 8) else (-1 if mode == 5 else 0)) or gap != lap_len + lo:
        raise SystemExit("BPGCFG lap fields are inconsistent with the mode")
    ds = S - 1 if mode == 6 else S
    formula = bw * nb + gap * (bw - 1) + ds + 8 * pc - (1 if mode == 7 else 0)
    formula_per_pe = bp_period(bw, nb, pr, pc, lap_len)
    formula_global = bp_period(bw, nb, pr, pc, lap_len + S)

    drains: dict[tuple[int, int, int], tuple[int, list[int]]] = {}
    laps: dict[tuple[int, int], list[tuple[int, int]]] = {}
    dup = []
    for line in body:
        f = line.split()
        if f[0] == "D":
            key, vals = (int(f[1]), int(f[2]), int(f[3])), [int(x) for x in f[5:]]
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

    A, W = read_operands(run_dir, ba, bw, mrows, ncols, L)
    gemm = A @ W
    T = bp_tiles(A, W, ba, bw)
    mismatches, drain_edge_errors = [], []
    n_tiles = n_out = max_abs_out = 0
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
                for h in range(8):
                    il, p = divmod(h, ba)
                    exp = tile_value(T, (ig * pr + r) * rows_pe + il, p, j)
                    n_tiles += 1
                    if got is not None and got[h] != exp:
                        mismatches.append(dict(kind="tile", block=blk, pe=[r, c], h=h, v=v, got=got[h], exp=exp))
                for il in range(rows_pe):        # the combiner's job, from the drained tiles
                    i = (ig * pr + r) * rows_pe + il
                    exp_out = int(gemm[i, j])
                    max_abs_out = max(max_abs_out, abs(exp_out))
                    n_out += 1
                    if got is not None:
                        out = sum((1 << p) * got[il * ba + p] for p in range(ba))
                        if out != exp_out:
                            mismatches.append(dict(kind="combined", block=blk, pe=[r, c], v=v, row=i, col=j,
                                                   got=out, exp=exp_out))
    starts = [drains[(b, 0, 0)][0] for b in range(nblk) if (b, 0, 0) in drains]
    periods = sorted({b - a for a, b in zip(starts, starts[1:])})
    first_start_ok = bool(starts) and starts[0] == e0 + (bw - 1) * (nb + gap) + nb + 1 + ds
    period_ok = blk_len == formula and (not periods or periods == [blk_len]) and first_start_ok
    lap_errors = []
    for r in range(pr):
        for c in range(pc):
            off = 0 if global_laps else r + c
            exp_runs = [(e0 + b * blk_len + pi * (nb + gap) + nb + lo + 1 + off, lap_len)
                        for b in range(nblk) for pi in range(bw - 1) if lap_len > 0]
            got_runs = sorted(laps.get((r, c), []))
            if got_runs != exp_runs:
                lap_errors.append(dict(pe=[r, c], got=got_runs[:4], exp=exp_runs[:4], n_got=len(got_runs),
                                       n_exp=len(exp_runs)))
    ok = not mismatches and coverage_ok and not drain_edge_errors and period_ok and not lap_errors
    return dict(
        status="PASS" if ok else "FAIL", mode=GRID_MODES.get(mode, mode), grid=f"{pr}x{pc}",
        precision=precision_name(ba, bw), ba=ba, bw=bw, L=L, mrows=mrows, ncols=ncols, blocks=nblk, nb=nb,
        junk=junk & 1, ring_gate_junk=(junk >> 1) & 1, neg_ring_stray=(junk >> 2) & 1, lap_len=lap_len,
        skew=S, drain_skew=ds, block_len=blk_len,
        block_len_kind="scheduled (feasibility shown by the bit-exact run)",
        measured_periods=periods, first_drain_start_ok=first_start_ok,
        formula_this_mode=formula, formula_per_pe_laps=formula_per_pe, formula_global_laps=formula_global,
        formula_bp_ring_per_pe_laps=bp_period(bw, nb, pr, pc, 8),
        per_pass_global_bubbles=(blk_len - formula_per_pe) // max(bw - 1, 1),
        data_edge_utilization=round(bw * nb / blk_len, 4),
        coverage_ok=coverage_ok, duplicates=[list(d) for d in dup[:8]],
        tiles_checked=n_tiles, outputs_checked=n_out, macs=nblk * pr * pc * rows_pe * 8 * L,
        max_abs_output=max_abs_out, n_mismatch=len(mismatches), mismatches=mismatches[:16],
        n_drain_edge_errors=len(drain_edge_errors), drain_edge_errors=drain_edge_errors[:8],
        period_ok=period_ok, n_lap_errors=len(lap_errors), lap_errors=lap_errors[:8],
        lap_runs_checked=sum(len(v) for v in laps.values()),
    )


def bp_grid_verdict(r: dict) -> tuple[bool, str]:
    tag = (f"{r['grid']} {r['precision']} L={r['L']} blocks={r['blocks']} lap_len={r['lap_len']} {r['mode']}"
           + (" ring_gate_junk" if r["ring_gate_junk"] else "") + (" neg_ring_stray" if r["neg_ring_stray"] else ""))
    if r["status"] != "PASS":
        return False, (f"[FAIL] {tag}: {r['n_mismatch']} mismatches, coverage_ok={r['coverage_ok']}, "
                       f"drain_edge_errors={r['n_drain_edge_errors']}, period_ok={r['period_ok']}, "
                       f"lap_errors={r['n_lap_errors']}")
    meas = f"drain-start spacing {r['measured_periods']}" if r["measured_periods"] else "single block"
    data, blk = r["bw"] * r["nb"], r["block_len"]
    return True, (f"[PASS] {tag}: {r['tiles_checked']} tiles + {r['outputs_checked']} combined outputs bit-exact "
                  f"({r['macs']} MACs, max|out| {r['max_abs_output']}); scheduled block period {blk} = formula "
                  f"({meas}), {r['lap_runs_checked']} lap runs on schedule, data utilization {data}/{blk} = "
                  f"{data / blk:.1%}")


# ------------------------------------------------------------------------------------ all-bits-in-time model --
def parse_abit_records(lines: list[str]) -> dict:
    """P (e blk j p q sign), K (e blk j u), L e, X (e blk t), M e, D blk t [e] v0..v7, C blk t lo hi."""
    rec = dict(P=[], K=[], L=[], X=[], M=[], D={}, C={}, Dedge={}, dup=[])
    for line in lines:
        f = line.split()
        if not f:
            continue
        t = f[0]
        if t in ("P", "K", "X"):
            rec[t].append(tuple(int(x) for x in f[1:{"P": 7, "K": 5, "X": 4}[t]]))
        elif t in ("L", "M"):
            rec[t].append(int(f[1]))
        elif t == "D":
            vals, key = [int(x) for x in f[3:]], (int(f[1]), int(f[2]))
            if len(vals) == 9:                   # energy bench: the drain edge first
                rec["Dedge"][key] = vals[0]
                vals = vals[1:]
            if len(vals) != 8:
                raise SystemExit(f"D line with {len(vals)} values")
            if key in rec["D"]:
                rec["dup"].append(("D",) + key)
            rec["D"][key] = vals
        elif t == "C":
            key = (int(f[1]), int(f[2]))
            if key in rec["C"]:
                rec["dup"].append(("C",) + key)
            rec["C"][key] = (int(f[3]), int(f[4]))
        else:
            raise SystemExit(f"unknown trace record {t!r}")
    return rec


def abit_gemm_tiles(A: np.ndarray, W: np.ndarray, nblk: int, njg: int, pr: int = 1, pc: int = 1):
    """{(blk, r, t): 8 expected drained values} (PE row r, drain step t = PE column pc-1-t//8, tile column
    7-t%8; tile row h = output row (ig*pr + r)*8 + h) and the GEMM itself."""
    C = A @ W
    out = {}
    for blk in range(nblk):
        ig, jg = divmod(blk, njg)
        for r in range(pr):
            for t in range(8 * pc):
                j = (jg * pc + pc - 1 - t // 8) * 8 + 7 - t % 8
                out[(blk, r, t)] = [int(C[(ig * pr + r) * 8 + h, j]) for h in range(8)]
    return out, C


def check_abit_schedule(cfg: dict, rec: dict, pr: int = 1, pc: int = 1) -> dict:
    """The schedule rules on the logged stimulus (PE (0,0) time for a grid); measured period of a block = next
    block's first capture - its first capture (the last block: its last drain edge - its first capture)."""
    ba, bw, nb, nblk, e0 = cfg["ba"], cfg["bw"], cfg["nb"], cfg["nblk"], cfg["e0"]
    S, nd = pr + pc - 2, 8 * pc
    want_formula = abit_period(ba, bw, nb, pr, pc)
    errors: list[str] = []
    passes, caps, drains = defaultdict(list), defaultdict(list), defaultdict(list)
    for e, blk, j, p, q, s in rec["P"]:
        passes[blk].append((e, j, p, q, s))
    for e, blk, j, u in rec["K"]:
        caps[(blk, j)].append((e, u))
    for e, blk, t in rec["X"]:
        drains[blk].append((e, t))
    laps = sorted(rec["L"])
    lapset = set(laps)
    if len(lapset) != len(laps):
        errors.append("a lap edge is logged twice")
    pairs = {(p, q) for p in range(ba) for q in range(bw)}
    used_laps, starts, last_drain, periods = set(), {}, {}, []
    for blk in range(nblk):
        pl = sorted(passes.get(blk, []))
        if {(p, q) for _, _, p, q, _ in pl} != pairs or len(pl) != ba * bw:
            errors.append(f"block {blk}: passes are not every (p, q) pair exactly once ({len(pl)} passes)")
            continue
        spans = []
        for e, j, p, q, s in pl:
            want_s = int((p == ba - 1) ^ (q == bw - 1))
            if s != want_s:
                errors.append(f"block {blk} pass ({p},{q}) at edge {e}: W sign {s}, expected {want_s}")
        for e, j, p, q, s in pl:
            cl = sorted(caps.get((blk, j), []))
            if cl != [(e + u, u) for u in range(nb)]:
                errors.append(f"block {blk} pass ({p},{q}): captures {cl[:3]}... are not u = 0..{nb-1} from edge {e}")
            spans.append((e, e + nb - 1, p + q))
        if pl[0][2] + pl[0][3] != ba + bw - 2:
            errors.append(f"block {blk}: first pass level {pl[0][2] + pl[0][3]}, expected {ba + bw - 2} (MSB first)")
        for (f0, l0, k0), (f1, l1, k1) in zip(spans, spans[1:]):
            inside = [x for x in laps if l0 < x <= f1]
            if k1 == k0:
                if f1 != l0 + 1 or inside:
                    errors.append(f"block {blk}: passes of level {k0} at {f0}..{l0} and {f1}.. not contiguous "
                                  f"or lapped ({len(inside)} laps between)")
            elif k1 == k0 - 1:
                if f1 != l0 + 2 or inside != [f1]:
                    errors.append(f"block {blk}: level {k0} -> {k1} step at edges {l0} -> {f1}: needs one bubble and "
                                  f"one lap on {l0 + 2}, got first capture {f1} and laps {inside}")
            else:
                errors.append(f"block {blk}: level {k0} followed by level {k1} (must not increase or skip)")
            used_laps.update(inside)
        dl = sorted(drains.get(blk, []))
        d0 = spans[-1][1] + 2 + S
        if dl != [(d0 + t, t) for t in range(nd)]:
            errors.append(f"block {blk}: drain edges {dl[:2]}..{dl[-1:]} , expected {nd} edges from {d0}")
        starts[blk] = spans[0][0]
        last_drain[blk] = dl[-1][0] if dl else d0 + nd - 1
    stray = sorted(lapset - used_laps)
    if stray:
        errors.append(f"{len(stray)} lap edge(s) outside the level steps, e.g. {stray[:3]}")
    if len(laps) != nblk * (ba + bw - 2):
        errors.append(f"{len(laps)} laps, expected {nblk * (ba + bw - 2)}")
    if starts:
        if starts.get(0) != e0:
            errors.append(f"block 0 starts at edge {starts.get(0)}, header E0 = {e0}")
        for blk in range(nblk):
            if blk not in starts:
                continue
            end = starts[blk + 1] if blk + 1 in starts else last_drain[blk]
            if blk + 1 in starts and starts[blk + 1] != last_drain[blk]:
                errors.append(f"block {blk + 1} starts at {starts[blk + 1]}, not on block {blk}'s last drain edge "
                              f"{last_drain[blk]}")
            periods.append(end - starts[blk])
    if rec["M"] != [e0 + 1]:
        errors.append(f"first MAC edge {rec['M']}, expected [{e0 + 1}]")
    period_ok = bool(periods) and all(p == want_formula for p in periods)
    if not period_ok:
        errors.append(f"measured block periods {sorted(set(periods))} != formula {want_formula}")
    return dict(errors=errors, periods=periods, formula=want_formula, period_ok=period_ok,
                laps=len(laps), passes=sum(len(v) for v in passes.values()))


def abit_replay(cfg: dict, rec: dict, A: np.ndarray, W: np.ndarray, dc: int = 128) -> dict:
    """Single-PE edge model of the LOGGED stimulus -> {(blk, t): 8 drained values}: a lap edge doubles every tile
    (mod 2^24), a drain edge reads the east column and shifts east with 0 entering, otherwise (mac_en) the data
    cycle captured on the previous edge is added with the W sign in force at its capture."""
    ba, bw, njg = cfg["ba"], cfg["bw"], cfg["ncols"] // 8
    a_pl, w_pl = bit_planes(A, ba), bit_planes(W, bw)
    pq = {(blk, j): (p, q) for e, blk, j, p, q, s in rec["P"]}
    sign_at = {e: s for e, blk, j, p, q, s in rec["P"]}
    cap = {e: (blk, j, u) for e, blk, j, u in rec["K"]}
    lap = set(rec["L"])
    drn = {e: (blk, t) for e, blk, t in rec["X"]}
    mac0 = rec["M"][0] if rec["M"] else 1 << 62
    T = np.zeros((8, 8), dtype=np.int64)
    sign, sample_sign, out = 0, {}, {}
    for e in range(max([0] + list(cap) + list(lap) + list(drn)) + 1):
        if e in drn:
            out[drn[e]] = [int(x) for x in wrap(T[:, 7])]
        if e in lap:
            T = wrap(2 * T)
        elif e in drn:
            T = np.concatenate([np.zeros((8, 1), np.int64), T[:, :7]], axis=1)
        elif e >= mac0 and (e - 1) in cap:
            blk, j, u = cap[e - 1]
            ig, jg = divmod(blk, njg)
            p, q = pq[(blk, j)]
            xs = slice(u * dc, (u + 1) * dc)
            cnt = a_pl[p][ig * 8:(ig + 1) * 8, xs] @ w_pl[q][xs, jg * 8:(jg + 1) * 8]
            T = wrap(T + (-cnt if sample_sign[e - 1] else cnt))
        if e in sign_at:
            sign = sign_at[e]
        sample_sign[e] = sign
    return out


# ---------------------------------------------------------------------------------- all-bits-in-time checks --
def check_abit(run_dir: Path, dc: int = 128) -> tuple[dict, dict]:
    vals, body = header(run_dir / "abit_trace.txt", "ABITCFG")
    if len(vals) < 13:
        raise SystemExit(f"ABITCFG has {len(vals)} fields")
    cfg = dict(zip(ABIT_FIELDS, vals))
    ba, bw, L, mrows, ncols, nblk, nb = (cfg[k] for k in ABIT_FIELDS[:7])
    njg = ncols // 8
    if nblk != (mrows // 8) * njg or nb != L // dc:
        raise SystemExit("ABITCFG shape fields are inconsistent")
    rec = parse_abit_records(body)
    A, W = read_operands(run_dir, ba, bw, mrows, ncols, L)
    exp, C = abit_gemm_tiles(A, W, nblk, njg)
    if abs(C).max() >= (1 << (OWIDTH - 1)):
        raise SystemExit("GEMM output exceeds the 24-bit tile; workload invalid")
    want = {(b, t) for b in range(nblk) for t in range(8)}
    coverage_ok = set(rec["D"]) == want and set(rec["C"]) == want and not rec["dup"]
    mism = [dict(block=b, step=t, h=h, v=7 - t, got=got[h], exp=exp[(b, 0, t)][h])
            for (b, t), got in sorted(rec["D"].items()) if (b, 0, t) in exp
            for h in range(8) if got[h] != exp[(b, 0, t)][h]]
    sched = check_abit_schedule(cfg, rec)
    rep = abit_replay(cfg, rec, A, W, dc)
    rep_mism = [dict(block=b, step=t, got=rec["D"][(b, t)], replay=rep.get((b, t)))
                for (b, t) in sorted(rec["D"]) if rep.get((b, t)) != rec["D"][(b, t)]]
    if set(rep) != set(rec["D"]):
        rep_mism.append(dict(note=f"replay drained {len(rep)} columns, RTL {len(rec['D'])}"))
    status = "PASS" if (not mism and coverage_ok and not sched["errors"] and not rep_mism) else "FAIL"
    negs = {k: cfg.get(k, 0) for k in ABIT_FIELDS[15:22]}
    result = dict(
        status=status, precision=precision_name(ba, bw), ba=ba, bw=bw, L=L, mrows=mrows, ncols=ncols,
        blocks=nblk, nb=nb, junk=cfg.get("junk"), mode_at=cfg.get("mode_at"), park_cyc0=cfg.get("park_cyc0"),
        negative_controls=negs, negative_run=any(v not in (0, -1) for v in negs.values()),
        negative_caught=status == "FAIL" and bool(mism) and not rep_mism,
        coverage_ok=coverage_ok, duplicates=rec["dup"][:8],
        values_checked=len(rec["D"]) * 8, outputs_checked=nblk * 64, macs=nblk * 64 * L,
        max_abs_output=int(abs(C).max()),
        n_mismatch=len(mism), mismatches=mism[:16],
        n_replay_mismatch=len(rep_mism), replay_mismatches=rep_mism[:4],
        schedule_errors=sched["errors"][:16], n_schedule_errors=len(sched["errors"]),
        formula=sched["formula"], measured_periods=sorted(set(sched["periods"])), period_ok=sched["period_ok"],
        bench_block_len=cfg.get("blk_len"), laps=sched["laps"], passes=sched["passes"],
        data_edges_per_block=ba * bw * nb,
        data_utilization=round(ba * bw * nb / sched["formula"], 4),
    )
    return result, rec


def abit_verdict(r: dict, expect_fail: bool) -> tuple[bool, str]:
    tag = f"{r['precision']} L={r['L']} blocks={r['blocks']}"
    if expect_fail:
        if r["negative_caught"]:
            return True, (f"[CAUGHT] {tag}: {r['n_mismatch']} of {r['values_checked']} drained values differ from "
                          f"the GEMM, RTL equals the replay of the logged schedule; {r['n_schedule_errors']} "
                          f"schedule-rule errors (periods {r['measured_periods']} vs formula {r['formula']})")
        return False, (f"[NOT-CAUGHT] {tag}: status {r['status']}, {r['n_mismatch']} GEMM mismatches, "
                       f"{r['n_replay_mismatch']} replay mismatches")
    if r["status"] != "PASS":
        return False, (f"[FAIL] {tag}: {r['n_mismatch']} GEMM mismatches, {r['n_replay_mismatch']} replay "
                       f"mismatches, {r['n_schedule_errors']} schedule errors, coverage_ok={r['coverage_ok']}, "
                       f"periods {r['measured_periods']} vs {r['formula']}")
    return True, (f"[PASS] {tag}: {r['values_checked']} drained values = {r['outputs_checked']} GEMM outputs "
                  f"bit-exact ({r['macs']} MACs, max|out| {r['max_abs_output']}); replay identical; schedule rules "
                  f"hold ({r['passes']} passes, {r['laps']} laps); measured block period {r['measured_periods']} "
                  f"= formula {r['formula']} (data utilization {r['data_utilization']:.1%})")


def check_abit_grid(run_dir: Path, dc: int = 128) -> dict:
    """D blk r t e v0..v7 per PE row against A @ W, the schedule rules on the logged virtual (PE (0,0)) schedule
    with S = P_R+P_C-2 and 8*P_C drain edges, every D on its scheduled drain edge, and the lap runs: PE (r, c)
    laps exactly on the virtual lap edges + r + c, one edge each, and nowhere else."""
    vals, lines = header(run_dir / "abit_grid_trace.txt", "ABITGCFG")
    cfg = dict(zip(ABITG_FIELDS, vals))
    pr, pc, ba, bw, L, mrows, ncols, nblk, nb = (cfg[k] for k in ABITG_FIELDS[:9])
    njg = ncols // (pc * 8)
    if nblk != (mrows // (pr * 8)) * njg or nb != L // dc:
        raise SystemExit("ABITGCFG shape fields are inconsistent")
    body, runs, drains, dup = [], {}, {}, []
    for line in lines:
        f = line.split()
        if f and f[0] == "R":
            runs.setdefault((int(f[1]), int(f[2])), []).append((int(f[3]), int(f[4])))
        elif f and f[0] == "D":
            key = (int(f[1]), int(f[2]), int(f[3]))
            if key in drains:
                dup.append(key)
            drains[key] = (int(f[4]), [int(x) for x in f[5:]])
        else:
            body.append(line)
    rec = parse_abit_records(body)
    A, W = read_operands(run_dir, ba, bw, mrows, ncols, L)
    exp, C = abit_gemm_tiles(A, W, nblk, njg, pr, pc)
    if abs(C).max() >= (1 << (OWIDTH - 1)):
        raise SystemExit("GEMM output exceeds the 24-bit tile; workload invalid")
    coverage_ok = set(drains) == set(exp) and not dup
    mism = [dict(block=key[0], pe_row=key[1], step=key[2], h=h, got=got[h], exp=exp[key][h])
            for key, (e, got) in sorted(drains.items()) if key in exp and len(got) == 8
            for h in range(8) if got[h] != exp[key][h]]
    sched = check_abit_schedule(cfg, rec, pr, pc)
    xedge = {(b, t): e for e, b, t in rec["X"]}
    edge_err = [dict(block=b, row=r, step=t, edge=e, scheduled=xedge.get((b, t)))
                for (b, r, t), (e, _) in sorted(drains.items()) if xedge.get((b, t)) != e]
    lap_err, vlaps = [], sorted(rec["L"])
    for r in range(pr):
        for c in range(pc):
            want_runs, got_runs = [(x + r + c, 1) for x in vlaps], sorted(runs.get((r, c), []))
            if got_runs != want_runs:
                lap_err.append(dict(pe=[r, c], got=got_runs[:4], exp=want_runs[:4], n_got=len(got_runs),
                                    n_exp=len(want_runs)))
    ok = not mism and coverage_ok and not sched["errors"] and not edge_err and not lap_err
    return dict(status="PASS" if ok else "FAIL", grid=f"{pr}x{pc}", precision=precision_name(ba, bw), ba=ba,
                bw=bw, L=L, mrows=mrows, ncols=ncols, blocks=nblk, nb=nb, junk=cfg["junk"],
                negative_controls={k: cfg[k] for k in ABITG_FIELDS[17:]},
                coverage_ok=coverage_ok, duplicates=[list(d) for d in dup[:8]],
                values_checked=8 * len(drains), outputs_checked=nblk * pr * pc * 64, macs=nblk * pr * pc * 64 * L,
                max_abs_output=int(abs(C).max()), n_mismatch=len(mism), mismatches=mism[:16],
                n_schedule_errors=len(sched["errors"]), schedule_errors=sched["errors"][:16],
                formula=sched["formula"], measured_periods=sorted(set(sched["periods"])),
                period_ok=sched["period_ok"], bench_block_len=cfg["blk_len"],
                n_drain_edge_errors=len(edge_err), drain_edge_errors=edge_err[:8],
                n_lap_errors=len(lap_err), lap_errors=lap_err[:8],
                lap_runs_checked=sum(len(v) for v in runs.values()),
                data_utilization=round(ba * bw * nb / sched["formula"], 4))


def abit_grid_verdict(r: dict, expect_fail: bool) -> tuple[bool, str]:
    tag = f"{r['grid']} {r['precision']} L={r['L']} blocks={r['blocks']}"
    if expect_fail:
        if r["n_mismatch"]:
            return True, (f"[CAUGHT] {tag}: {r['n_mismatch']} of {r['values_checked']} drained values differ from "
                          f"the GEMM; {r['n_lap_errors']} PEs off the lap schedule, {r['n_schedule_errors']} "
                          f"schedule-rule errors, periods {r['measured_periods']} vs formula {r['formula']}")
        return False, f"[NOT-CAUGHT] {tag}: status {r['status']}, no GEMM mismatch"
    if r["status"] != "PASS":
        return False, (f"[FAIL] {tag}: {r['n_mismatch']} mismatches, coverage_ok={r['coverage_ok']}, "
                       f"{r['n_schedule_errors']} schedule errors, {r['n_drain_edge_errors']} drain-edge errors, "
                       f"{r['n_lap_errors']} lap errors, periods {r['measured_periods']} vs {r['formula']}")
    return True, (f"[PASS] {tag}: {r['values_checked']} drained values = {r['outputs_checked']} GEMM outputs "
                  f"bit-exact ({r['macs']} MACs, max|out| {r['max_abs_output']}); {r['lap_runs_checked']} lap runs "
                  f"on the per-PE wave; measured block period {r['measured_periods']} = formula {r['formula']} "
                  f"(data utilization {r['data_utilization']:.1%})")


def check_abit_power(run_dir: Path, dc: int = 128) -> tuple[dict, list[str]]:
    """abit on the trace (negative-control, junk and park fields at their defaults, every D record on its X edge),
    then abit_saif.txt: data = blocks*BA*BW*NB (every mode), lap = blocks*(BA+BW-2) (modes 0, 2), drain =
    blocks*8 (mode 2), segments blocks / blocks*(BA+BW-1) / 1 (modes 0 / 1 / 2), E_END = E0 + blocks*period,
    N_EDGES = E_END + 3.  The JSON carries what the energy row writer reads (saif_window "ring" = laps, lap_len 1)."""
    reasons: list[str] = []
    inner, rec = check_abit(run_dir, dc)
    if inner["status"] != "PASS":
        reasons.append(f"trace check FAIL: {inner['n_mismatch']} GEMM mismatches, {inner['n_replay_mismatch']} "
                       f"replay mismatches, {inner['n_schedule_errors']} schedule errors, "
                       f"coverage_ok={inner['coverage_ok']}")
    if inner["negative_run"] or inner["junk"] or inner["park_cyc0"]:
        reasons.append("trace header has negative-control / junk / park fields set; an energy run must have none")
    xedge = {(b, t): e for e, b, t in rec["X"]}
    bad_edges = [k for k, e in rec["Dedge"].items() if xedge.get(k) != e]
    if bad_edges or len(rec["Dedge"]) != len(rec["D"]):
        reasons.append(f"{len(bad_edges)} D records off their scheduled drain edge")
    srec = {s.split()[0]: [int(x) for x in s.split()[1:]]
            for s in (run_dir / "abit_saif.txt").read_text().splitlines() if s.strip()}
    if len(srec.get("ABITSAIF", [])) != 14 or len(srec.get("SAIFWIN", [])) != 5:
        raise SystemExit("abit_saif.txt malformed (need ABITSAIF x14, SAIFWIN x5)")
    ba, bw, L, mrows, ncols, nblk, nb, mode, mode_at, e0, e_end, n_edges, blk_len, d0 = srec["ABITSAIF"]
    win = dict(zip(("active", "data", "lap", "drain", "segments"), srec["SAIFWIN"]))
    for key, val in (("ba", ba), ("bw", bw), ("L", L), ("mrows", mrows), ("ncols", ncols), ("blocks", nblk),
                     ("nb", nb), ("mode_at", mode_at)):
        if inner.get(key) != val:
            reasons.append(f"abit_saif.txt {key}={val} disagrees with the trace header ({inner.get(key)})")
    blk = abit_period(ba, bw, nb)
    if blk_len != blk or e_end != e0 + nblk * blk or n_edges != e_end + 3:
        reasons.append(f"edge bookkeeping BLK_LEN={blk_len} E_END={e_end} N_EDGES={n_edges}, expected {blk} / "
                       f"{e0 + nblk * blk} / {e0 + nblk * blk + 3}")
    if mode not in (0, 1, 2):
        reasons.append(f"SAIF mode {mode} is not 0, 1 or 2")
    exp = dict(data=nblk * ba * bw * nb, lap=nblk * (ba + bw - 2) if mode in (0, 2) else 0,
               drain=nblk * 8 if mode == 2 else 0)
    exp["active"] = exp["data"] + exp["lap"] + exp["drain"]
    exp["segments"] = {0: nblk, 1: nblk * (ba + bw - 1), 2: 1}.get(mode, -1)
    for key, val in exp.items():
        if win[key] != val:
            reasons.append(f"SAIF window {key}={win[key]}, expected {val}")
    macs = nblk * 64 * L
    if win["data"] * 64 * dc != macs * ba * bw:
        reasons.append(f"window data cycles {win['data']} x {64 * dc}/(BA*BW) != {macs} MACs")
    result = dict(
        status="FAIL" if reasons else "PASS", rejection_reasons=reasons, schedule="abit",
        precision=precision_name(ba, bw), ba=ba, bw=bw, L=L, mrows=mrows, ncols=ncols,
        blocks=nblk, nb=nb, saif_mode=mode, mode_at=mode_at, e0=e0, e_end=e_end, n_edges=n_edges,
        lap_ring_only=1, lap_len=1, block_period=blk, formula=inner["formula"],
        measured_periods=inner["measured_periods"],
        saif_window=dict(active=win["active"], data=win["data"], ring=win["lap"], drain=win["drain"],
                         segments=win["segments"]),
        expected_saif_window=exp, mac_per_data_cycle=64 * dc / (ba * bw), macs=macs,
        tiles_checked=inner["values_checked"], outputs_checked=inner["outputs_checked"],
        max_abs_tile=inner["max_abs_output"], max_abs_output=inner["max_abs_output"],
        n_mismatch=inner["n_mismatch"], trace_check=inner,
    )
    return result, reasons


def abit_power_verdict(r: dict, reasons: list[str]) -> tuple[bool, str]:
    tag = f"{r['precision']} L={r['L']} blocks={r['blocks']} mode={r['saif_mode']}"
    if reasons:
        return False, f"[FAIL] {tag}: " + "; ".join(reasons)
    w = r["saif_window"]
    return True, (f"[PASS] {tag} abit: {r['tiles_checked']} drained values = {r['outputs_checked']} GEMM outputs "
                  f"bit-exact ({r['macs']} MACs, max|out| {r['max_abs_output']}); replay identical; block period "
                  f"{r['measured_periods']} = formula {r['formula']}; SAIF window {w['active']} = {w['data']} data "
                  f"+ {w['ring']} lap + {w['drain']} drain in {w['segments']} segment(s)")


# ---------------------------------------------------------------------------------------------------- CLI --
def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="check", required=True)
    for name, what in (("bp", "bit-plane single-PE functional trace"), ("bp-grid", "bit-plane grid trace"),
                       ("bp-power", "bit-plane INT energy trace + SAIF window"),
                       ("abit", "all-bits-in-time single-PE functional trace"),
                       ("abit-grid", "all-bits-in-time grid trace"),
                       ("abit-power", "all-bits-in-time INT energy trace + SAIF window")):
        p = sub.add_parser(name, help=what)
        p.add_argument("run_dir", type=Path)
        p.add_argument("--json", type=Path, dest="json_path")
        p.add_argument("--shape", default="k8m16", choices=SHAPES, help="data-cycle shape K x M (default k8m16)")
        if name == "bp-power":
            p.add_argument("--lap-ring-only", action="store_true",
                           help="expect the per-PE lap-enable contract (shift_in on drain edges only)")
        if name in ("abit", "abit-grid"):
            p.add_argument("--expect-fail", action="store_true")
    args = ap.parse_args()
    dc = elements_per_cycle(args.shape)
    if args.check == "bp":
        r = check_bp(args.run_dir, dc)
        ok, line = bp_verdict(r)
    elif args.check == "bp-grid":
        r = check_bp_grid(args.run_dir, dc)
        ok, line = bp_grid_verdict(r)
    elif args.check == "bp-power":
        r, reasons = check_bp_power(args.run_dir, args.lap_ring_only, dc)
        ok, line = bp_power_verdict(r, reasons)
    elif args.check == "abit":
        r = check_abit(args.run_dir, dc)[0]
        ok, line = abit_verdict(r, args.expect_fail)
    elif args.check == "abit-grid":
        r = check_abit_grid(args.run_dir, dc)
        ok, line = abit_grid_verdict(r, args.expect_fail)
    else:
        r, reasons = check_abit_power(args.run_dir, dc)
        ok, line = abit_power_verdict(r, reasons)
    return emit(r, args.json_path, line, ok, args.shape)


if __name__ == "__main__":
    raise SystemExit(main())
