#!/usr/bin/env python3
"""Bit-exact + SAIF-window check of the BP INT energy bench
(designs/payn/power/power_payn_array_bp_int.sv).

1. Runs sweeps/int_mode/bp/check_bp_trace.py, unchanged, on RUN_DIR: every
   drained tile and every combiner word against the numpy int64 reference
   (bpt_trace.txt, bpt_a.hex, bpt_w.hex), every (block, step) exactly once.
2. Checks bpe_saif.txt (written by the bench after $toggle_report) against the
   schedule: the configuration must match the trace header, and the active
   SAIF interval counts per class and the number of collection segments must
   be exactly what the window mode prescribes:
       data  = blocks * BW * NB                      (every mode)
       ring  = blocks * (BW - 1) * 8                 (modes 0, 2)
       drain = blocks * 8                            (mode 2)
       segments = blocks (mode 0), blocks * BW (mode 1), 1 (mode 2)
   and the edge bookkeeping (E_END = E0 + blocks * BW * (NB + 8), N_EDGES =
   E_END + 3) must agree.
3. The lap contract: the trace header's lap_ring_only (field 12) must equal
   the one the driver asked for (--lap-ring-only: shift_in on drain edges
   only, laps on ring_q alone; default: shift_in on lap edges too).
Writes one JSON (inner check plus window record) and exits 1 on any failure.

Opt-in (sweeps/int_mode/bp/sr/run_int_energy_prelayout_ab.sh; the defaults
check and print exactly what they did before):
  --lap-len G (1, 2, 4; default 8): the bench ran G-edge laps (BPE_LAP_LEN).
      Then ring = blocks * (BW - 1) * G, E_END = E0 + blocks * (BW*NB +
      G*(BW-1) + 8), and bpe_saif.txt must carry "BPELAP G PASS_LEN LAST_LEN
      BLK_LEN" with PASS_LEN = NB + G, LAST_LEN = NB + 8; with G = 8 that line
      must be absent.  The JSON gains "lap_len" only for G != 8.
  SAIF modes 3 / 4 (the dc / drc windows, classed by cause): the counts and
      segments of modes 1 / 0.

Usage:  check_bp_power_trace.py RUN_DIR [--json out.json] [--lap-ring-only] [--lap-len G]
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

CHECKER = Path(__file__).resolve().parent / "check_bp_trace.py"
PREC = {(8, 8): "INT8", (8, 4): "W4A8", (4, 4): "INT4", (4, 8): "W8A4"}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("run_dir", type=Path)
    ap.add_argument("--json", type=Path, dest="json_path")
    ap.add_argument("--lap-ring-only", action="store_true",
                    help="expect the per-PE lap-enable contract (shift_in on drain edges only)")
    ap.add_argument("--lap-len", type=int, default=8, choices=(1, 2, 4, 8),
                    help="lap length G the bench ran (BPE_LAP_LEN; default 8, the BP ring)")
    args = ap.parse_args()
    g = args.lap_len
    reasons: list[str] = []

    inner_json = args.run_dir / "bpt_check_inner.json"
    proc = subprocess.run([sys.executable, str(CHECKER), str(args.run_dir), "--json", str(inner_json)],
                          capture_output=True, text=True)
    inner = json.loads(inner_json.read_text()) if inner_json.exists() else None
    if proc.returncode != 0 or inner is None or inner.get("status") != "PASS":
        tail = (proc.stdout + proc.stderr).strip().splitlines()[-1:] or ["no output"]
        reasons.append(f"check_bp_trace.py failed (rc={proc.returncode}): {tail[0]}")

    lines = (args.run_dir / "bpe_saif.txt").read_text().splitlines()
    rec = {line.split()[0]: [int(x) for x in line.split()[1:]] for line in lines if line.strip()}
    if "BPECFG" not in rec or len(rec["BPECFG"]) != 12 or "SAIFWIN" not in rec or len(rec["SAIFWIN"]) != 5:
        raise SystemExit(f"{args.run_dir / 'bpe_saif.txt'}: malformed (need BPECFG x12, SAIFWIN x5)")
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
        # Field 12 (lap_ring_only, alias neg_no_lap_shift) is a contract choice.
        if inner.get("lap_ring_only") != int(args.lap_ring_only):
            reasons.append(f"trace header has lap_ring_only={inner.get('lap_ring_only')}; "
                           f"the driver expected {int(args.lap_ring_only)}")
        if inner.get("int_prec") != (1 if ba == 4 else 0):
            reasons.append(f"int_prec={inner.get('int_prec')} for BA={ba}")
    if mode not in (0, 1, 2, 3, 4):
        reasons.append(f"SAIF mode {mode} is not 0, 1, 2, 3 or 4")
    exp_e_end = e0 + nblk * ((bw - 1) * (nb + g) + nb + 8)
    if e_end != exp_e_end or n_edges != e_end + 3:
        reasons.append(f"edge bookkeeping E_END={e_end} N_EDGES={n_edges}, expected {exp_e_end} / {exp_e_end + 3}")
    lap = rec.get("BPELAP")
    if g == 8:
        if lap is not None:
            reasons.append(f"bpe_saif.txt has BPELAP {lap}, expected none for 8-edge laps")
    elif lap != [g, nb + g, nb + 8, (bw - 1) * (nb + g) + nb + 8]:
        reasons.append(f"bpe_saif.txt BPELAP {lap}, expected {[g, nb + g, nb + 8, (bw - 1) * (nb + g) + nb + 8]}")
    exp = dict(data=nblk * bw * nb,
               ring=nblk * (bw - 1) * g if mode in (0, 2, 4) else 0,
               drain=nblk * 8 if mode == 2 else 0)
    exp["active"] = exp["data"] + exp["ring"] + exp["drain"]
    exp["segments"] = {0: nblk, 1: nblk * bw, 2: 1, 3: nblk * bw, 4: nblk}.get(mode, -1)
    for key, val in exp.items():
        if win[key] != val:
            reasons.append(f"SAIF window {key}={win[key]}, expected {val}")

    mac_per_data_cycle = 64 * 128 // (ba * bw)
    macs_in_window = win["data"] * mac_per_data_cycle
    if inner is not None and macs_in_window != inner.get("macs"):
        reasons.append(f"window MACs {macs_in_window} != checked MACs {inner.get('macs')}")

    result = dict(
        status="FAIL" if reasons else "PASS", rejection_reasons=reasons,
        precision=PREC.get((ba, bw), "?"), ba=ba, bw=bw, L=L, mrows=mrows, ncols=ncols,
        blocks=nblk, nb=nb, saif_mode=mode, mode_at=mode_at, e0=e0, e_end=e_end, n_edges=n_edges,
        lap_ring_only=(inner or {}).get("lap_ring_only"),
        **({} if g == 8 else {"lap_len": g}),
        saif_window=win, expected_saif_window=exp, mac_per_data_cycle=mac_per_data_cycle,
        macs=macs_in_window,
        tiles_checked=(inner or {}).get("tiles_checked"),
        outputs_checked=(inner or {}).get("outputs_checked"),
        max_abs_tile=(inner or {}).get("max_abs_tile"),
        max_abs_output=(inner or {}).get("max_abs_output"),
        n_mismatch=(inner or {}).get("n_mismatch"),
        trace_check=inner,
    )
    text = json.dumps(result, indent=2) + "\n"
    if args.json_path:
        args.json_path.write_text(text)
    print(text, end="")
    if reasons:
        print(f"[FAIL] {result['precision']} L={L} blocks={nblk} mode={mode}: " + "; ".join(reasons))
        return 1
    print(f"[PASS] {result['precision']} L={L} blocks={nblk} mode={mode} "
          f"lap_ring_only={result['lap_ring_only']}{'' if g == 8 else f' lap_len={g}'}: "
          f"{result['tiles_checked']} tiles and {result['outputs_checked']} GEMM outputs bit-exact "
          f"({result['macs']} MACs, max|out| {result['max_abs_output']}); SAIF window "
          f"{win['active']} = {win['data']} data + {win['ring']} ring + {win['drain']} drain "
          f"in {win['segments']} segment(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
