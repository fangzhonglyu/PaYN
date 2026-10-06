#!/usr/bin/env python3
"""Checker for the independent BP PE-grid harness (gen_vg_stim.py + tb_vg_player.sv).

Compares the recorded trace with the generator's first-principles reference:
  * every drained column (all PE rows, 8 tile rows each) on every sample edge,
    bit-exact mod 2^24 (tile mismatches counted per tile);
  * combined INT outputs out(i,j) = sum_p 2^p T(p) formed from the DRAINED
    tiles vs A @ W (int64);
  * every PE's ring_q on every edge after the first reset vs the intended
    per-PE lap windows (offset r+c, or the global windows of the old
    contract), and ring_q == 0 throughout SC blocks;
  * no X on sampled columns or on ring_q after reset;
  * measured drain-start period of consecutive INT blocks vs
    BW*NB + 8*(BW-1) + (P_R+P_C-2) + 8*P_C.
Exit 0 only if all of that holds.  JSON (--json) carries the counts, so a
negative control can require n_tile_mismatch > 0.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np

OW, NH = 24, 8


def sgn(v: int) -> int:
    v &= (1 << OW) - 1
    return v - (1 << OW) if v >> (OW - 1) else v


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("run_dir", type=Path)
    ap.add_argument("--json", type=Path, dest="json_path")
    a = ap.parse_args()
    d = a.run_dir
    meta = json.loads((d / "meta.json").read_text())
    ex = np.load(d / "expect.npz")
    pr, pc, S, n = meta["pr"], meta["pc"], meta["S"], meta["n_edges"]

    ring_tr: dict[int, str] = {}
    dr: dict[int, str] = {}
    ended = False
    for ln in (d / "trace.txt").read_text().splitlines():
        f = ln.split()
        if not f:
            continue
        if f[0] == "T":
            ring_tr[int(f[1])] = f[2]
        elif f[0] == "D":
            dr[int(f[1])] = f[2]
        elif f[0] == "END":
            ended = True
    errs: list[str] = []
    if not ended:
        errs.append("trace incomplete (no END)")

    # ---------------------------------------------------------- drained tiles
    samples, exp_vals = ex["samples"], ex["exp_vals"]
    n_tile_mm = n_x = 0
    meas = {}
    mm_pes: set = set()
    first_mm = []
    for idx, (e, bid, t) in enumerate(samples):
        e, bid, t = int(e), int(bid), int(t)
        hx = dr.get(e)
        if hx is None:
            errs.append(f"missing drain sample at edge {e}")
            continue
        if any(ch in "xXzZ" for ch in hx):
            n_x += 1
            continue
        val = int(hx, 16)
        c, v = pc - 1 - t // 8, 7 - t % 8
        for r in range(pr):
            got = [sgn(val >> ((r * NH + h) * OW)) for h in range(NH)]
            meas[(bid, r, c, v)] = got
            want = [int(x) for x in exp_vals[idx, r]]
            for h in range(NH):
                if got[h] != want[h]:
                    n_tile_mm += 1
                    mm_pes.add((bid, r, c))
                    if len(first_mm) < 8:
                        first_mm.append(f"blk {bid} PE ({r},{c}) tile ({h},{v}) edge {e}: got {got[h]} want {want[h]}")
    # ---------------------------------------------------------- combined outs
    n_out = n_out_mm = 0
    for bid, b in enumerate(meta["blocks"]):
        if b["kind"] != "int" or not b["checked"]:
            continue
        BA, rows_pe = b["BA"], b["rows_pe"]
        slot_i, slot_j, AWm = ex[f"slot_i{bid}"], ex[f"slot_j{bid}"], ex[f"AW{bid}"]
        for r in range(pr):
            for il in range(rows_pe):
                i = int(slot_i[r * rows_pe + il])
                if i < 0:
                    continue
                for c in range(pc):
                    for v in range(8):
                        j = int(slot_j[c * 8 + v])
                        if j < 0 or (bid, r, c, v) not in meas:
                            continue
                        T = meas[(bid, r, c, v)]
                        out = sum((1 << p) * T[il * BA + p] for p in range(BA))
                        n_out += 1
                        if out != int(AWm[i, j]):
                            n_out_mm += 1
    # ---------------------------------------------------------- ring pattern
    exp_ring = ex["exp_ring"]
    reset = ex["reset"]
    n_ring_mm = n_ring_x = 0
    first_ring = []
    for e in range(meta["reset0"] + 1, n):
        hx = ring_tr.get(e)
        if hx is None:
            errs.append(f"missing ring sample at edge {e}")
            break
        if any(ch in "xXzZ" for ch in hx):
            n_ring_x += 1
            continue
        mask = int(hx, 16)
        for r in range(pr):
            for c in range(pc):
                got = (mask >> (r * pc + c)) & 1
                if got != int(exp_ring[e, r, c]):
                    n_ring_mm += 1
                    if len(first_ring) < 6:
                        first_ring.append(f"edge {e} PE ({r},{c}) ring_q {got} want {int(exp_ring[e, r, c])}")
    # SC blocks: ring_q all zero inside the block
    # (covered by exp_ring == 0 there; report the count of SC edges checked)
    # ---------------------------------------------------------- periods
    # measured: base-to-base distance (the drain start is fixed relative to the base)
    per_bad = []
    for b0, b1 in zip(meta["blocks"], meta["blocks"][1:]):
        if b0["kind"] == "int" and b0["checked"]:
            meas_p = b1["base"] - b0["base"]
            form = b0["period_formula"] if b0["lap"] == "pe" else b0["period_global"]
            if meas_p != form and "f_" not in meta["scenario"]:
                per_bad.append((b0["base"], meas_p, form))
    if per_bad:
        errs.append(f"block period differs from formula: {per_bad}")

    ok = (not errs and n_tile_mm == 0 and n_out_mm == 0 and n_ring_mm == 0 and n_x == 0 and n_ring_x == 0)
    res = dict(status="PASS" if ok else "FAIL", scenario=meta["scenario"], grid=f"{pr}x{pc}",
               n_edges=n, n_samples=len(samples), n_tile_mismatch=n_tile_mm, n_out=n_out, n_out_mismatch=n_out_mm,
               n_ring_mismatch=n_ring_mm, n_x=n_x, n_ring_x=n_ring_x, mismatch_pes=sorted(mm_pes)[:40],
               first_mismatches=first_mm, first_ring_mismatches=first_ring, errors=errs,
               periods=[dict(BW=b0["BW"], NB=b0["NB"], lap=b0["lap"], base_to_base=b1["base"] - b0["base"],
                             formula=(b0["period_formula"] if b0["lap"] == "pe" else b0["period_global"]))
                        for b0, b1 in zip(meta["blocks"], meta["blocks"][1:]) if b0["kind"] == "int" and b0["checked"]],
               notes=meta["notes"])
    if a.json_path:
        a.json_path.write_text(json.dumps(res, indent=1, default=int))
    for m in first_mm + first_ring + errs:
        print("  " + m)
    print(f"[{res['status']}] {meta['scenario']} {pr}x{pc}: edges={n} samples={len(samples)} tile_mm={n_tile_mm} "
          f"outs={n_out} out_mm={n_out_mm} ring_mm={n_ring_mm} x={n_x}/{n_ring_x} mm_PEs={len(mm_pes)}")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
