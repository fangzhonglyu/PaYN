#!/usr/bin/env python3
"""Bit-exact check of the bit-plane INT bench's drained accumulators.

Independent numpy reference for designs/payn/power/power_payn_array_int_bitplane.sv.
For every output block (ig, jg) the bench drains the 8x8 tile matrix after
BW weight passes with a x2 ring lap between passes.  Tile (h, v) must hold

    T(h, v) = sigma_p * sum_kk a_p[kk] * W[kk, j],
    i = ig*ROWS_PE + h // BA,  p = h % BA,  j = jg*8 + v,
    a_p = bit p of A[i, kk] in BA-bit two's complement,
    sigma_p = -1 for the MSB plane (p == BA-1), else +1,

and the east-edge combiner's result sum_p 2^p * T(il*BA + p, v) must equal the
int64 GEMM A[i] @ W[:, j].  T is also recomputed pass by pass (MSB-first Horner
over weight planes with sigma_q = -1 for q == BW-1), which is what the
hardware does, and the two references must agree.  The SAIF window interval
counts in the trace are checked against the schedule.

Usage:  check_bitplane_drain.py RUN_DIR [--json out.json]
RUN_DIR holds intb_trace.txt, intb_a.hex, intb_w.hex.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np

OWIDTH = 24


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

    lines = (args.run_dir / "intb_trace.txt").read_text().splitlines()
    cfg = [int(x) for x in lines[0].split()[1:]] if lines[0].startswith("INTBCFG") else None
    if cfg is None or len(cfg) != 9:
        raise SystemExit("missing INTBCFG header")
    ba, bw, L, mrows, ncols, nblk, nb, mode, n_edges = cfg
    rows_pe = 8 // ba
    njg = ncols // 8
    win = None
    drains = {}
    for line in lines[1:]:
        f = line.split()
        if f[0] == "SAIFWIN":
            win = dict(zip(("active", "data", "ring", "drain", "segments"), map(int, f[1:])))
        elif f[0] == "DRAIN":
            vals = [int(x) for x in f[2:]]
            if len(vals) != 64:
                raise SystemExit(f"DRAIN line with {len(vals)} values")
            drains[int(f[1])] = np.array(vals, dtype=np.int64).reshape(8, 8)
    if win is None or sorted(drains) != list(range(nblk)):
        raise SystemExit(f"trace incomplete: SAIFWIN={win}, blocks={sorted(drains)[:5]}...")

    exp_win = dict(data=nblk * bw * nb,
                   ring=nblk * (bw - 1) * 8 if mode in (0, 2) else 0,
                   drain=nblk * 8 if mode == 2 else 0)
    exp_win["active"] = exp_win["data"] + exp_win["ring"] + exp_win["drain"]
    win_ok = all(win[k] == v for k, v in exp_win.items())

    A = read_hex(args.run_dir / "intb_a.hex", mrows * L).reshape(mrows, L)
    W = read_hex(args.run_dir / "intb_w.hex", ncols * L).reshape(ncols, L).T   # (L, ncols)
    a_lo, a_hi = -(1 << (ba - 1)), (1 << (ba - 1)) - 1
    w_lo, w_hi = -(1 << (bw - 1)), (1 << (bw - 1)) - 1
    if A.min() < a_lo or A.max() > a_hi or W.min() < w_lo or W.max() > w_hi:
        raise SystemExit("operands outside the declared precision")
    a_u = A & ((1 << ba) - 1)
    w_u = W & ((1 << bw) - 1)
    a_planes = np.stack([(a_u >> p) & 1 for p in range(ba)])          # (ba, mrows, L)
    w_planes = np.stack([(w_u >> q) & 1 for q in range(bw)])          # (bw, L, ncols)
    gemm = A @ W

    mismatches = []
    max_abs_tile = 0
    max_abs_out = 0
    n_tiles = 0
    for blk in range(nblk):
        ig, jg = divmod(blk, njg)
        got = drains[blk]
        exp = np.zeros((8, 8), dtype=np.int64)
        for h in range(8):
            il, p = divmod(h, ba)
            i = ig * rows_pe + il
            sig_p = -1 if p == ba - 1 else 1
            for v in range(8):
                j = jg * 8 + v
                t_direct = sig_p * int(a_planes[p, i] @ W[:, j])
                # pass-by-pass Horner, MSB pass first, x2 between passes
                acc = 0
                for q in reversed(range(bw)):
                    sig_q = -1 if q == bw - 1 else 1
                    acc = 2 * acc + sig_p * sig_q * int(a_planes[p, i] @ w_planes[q, :, j])
                if acc != t_direct:
                    raise SystemExit(f"reference self-check failed at block {blk} h{h} v{v}")
                if abs(t_direct) >= (1 << (OWIDTH - 1)):
                    raise SystemExit(f"tile value {t_direct} overflows OWIDTH={OWIDTH}")
                exp[h, v] = t_direct
        max_abs_tile = max(max_abs_tile, int(np.abs(exp).max()))
        bad = np.argwhere(got != exp)
        for h, v in bad[:8]:
            mismatches.append(dict(block=blk, h=int(h), v=int(v),
                                   got=int(got[h, v]), exp=int(exp[h, v])))
        n_tiles += 64
        # east-edge combine and the GEMM itself
        for il in range(rows_pe):
            i = ig * rows_pe + il
            for v in range(8):
                j = jg * 8 + v
                out = sum((1 << p) * int(got[il * ba + p, v]) for p in range(ba))
                max_abs_out = max(max_abs_out, abs(out))
                if out != int(gemm[i, j]):
                    mismatches.append(dict(block=blk, combine_row=i, col=j,
                                           got=out, exp=int(gemm[i, j])))

    macs = nblk * rows_pe * 8 * L
    result = dict(
        status="PASS" if not mismatches and win_ok else "FAIL",
        ba=ba, bw=bw, L=L, mrows=mrows, ncols=ncols, blocks=nblk, nb=nb,
        saif_mode=mode, n_edges=n_edges, saif_window=win, expected_saif_window=exp_win,
        tiles_checked=n_tiles, outputs_checked=nblk * rows_pe * 8, macs=macs,
        max_abs_tile=max_abs_tile, max_abs_output=max_abs_out,
        mismatches=mismatches[:16], n_mismatch_records=len(mismatches),
    )
    text = json.dumps(result, indent=2) + "\n"
    if args.json_path:
        args.json_path.write_text(text)
    print(text, end="")
    if result["status"] != "PASS":
        print("[FAIL] bit-plane drain mismatch or SAIF window mismatch")
        return 1
    print(f"[PASS] {n_tiles} tile values and {nblk * rows_pe * 8} GEMM outputs bit-exact "
          f"({macs} MACs, BA={ba} BW={bw} L={L}, blocks={nblk})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
