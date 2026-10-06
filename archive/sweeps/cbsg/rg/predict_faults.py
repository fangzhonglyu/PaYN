#!/usr/bin/env python3
"""Predict what the RG RTL bench (test_payn_array_cbsg_rg.sv) must report for a golden case under a negative
control, from the case's .mem files alone.

The model is cbsg_ref's RG block (cbsg_ref._rg_block), generalized to the RTL's state: the DUT phase register
(reset at slice_start as the bench drives it, and -- DRAIN_PHASE_RESET = 1 -- at the first block after reset
or after a drain), a per-cycle W mask phase, the W index counter carried in IDX_W bits, and the bench's cycle
policy.  With no fault it reproduces acc_exp / acc_blk / phase exactly
(the runner checks that too), so a negative control is accepted only when the RTL fails with exactly the
predicted counts.

  --policy  slice (correct) | nocall (NEG_NO_CALL_RESET) | call (NEG_NO_SLICE_RESET) | free (NEG_FREE_PHASE)
  --fault   none | lane_mask (FAULT=1) | w_idx_t (2) | no_len_gate (3) | phase_free (4) | j_no_restart (5)
            | pe_phase_early (6)
  --cycles  exact | full (FULL_CYCLES) | short (NEG_SHORT_BLOCK)
  --idx-w   W index counter width (7..9)
  --drain-reset  1 (default build: a drain or reset arms the phase reset) | 0 (slice_start only)
  --no-peek  drain-only run (+NO_PEEK, GL_SIM): block and phase counts are 0

Prints `PREDICT drain_bad=.. drain_total=.. blk_bad=.. blk_total=.. phase_bad=.. phase_total=..`.
pe_phase_early assumes the bench's default schedule (no STALL): a block not ending a slice is followed
back to back by the next one, whose phase the PE then sees in the block's last cycle.
"""
import argparse
import sys
from pathlib import Path

sys.dont_write_bytecode = True
REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / "sweeps" / "cbsg"))
import numpy as np            # noqa: E402
import cbsg_ref as R          # noqa: E402

FAULTS = ("none", "lane_mask", "w_idx_t", "no_len_gate", "phase_free", "j_no_restart", "pe_phase_early")


def s32(v):
    return np.where(v >= 1 << 31, v - (1 << 32), v)


def load_case(d):
    d = Path(d)
    rm = lambda n: R.read_mem(d / n)
    cfg = rm("cfg.mem")
    nb, nd = int(cfg[0]), int(cfg[1])
    return dict(
        nb=nb, nd=nd,
        am=rm("a_mag.mem").reshape(nb, 8, 8), an=rm("a_sgn.mem").reshape(nb, 8, 8).astype(bool),
        wm=rm("w_mag.mem").reshape(nb, 8, 8), wn=rm("w_sgn.mem").reshape(nb, 8, 8).astype(bool),
        L=rm("row_len.mem").reshape(nb, 8), ss=rm("slice_start.mem").astype(bool),
        cs=rm("call_start.mem").astype(bool), ph=rm("phase.mem"), cy=rm("cycles.mem"),
        dr=rm("drain.mem").astype(bool), ab=s32(rm("acc_blk.mem")).reshape(nb, 8, 8),
        ex=s32(rm("acc_exp.mem")).reshape(nd, 8, 8))


def rg_block(aB, aN, wB, wN, Lr, C, maskA, maskW, j0, idx_w, fault):
    """One block.  aB/aN (rows, lanes), wB/wN (lanes, cols), maskA (lanes,), maskW (C, lanes), j0 (rows, lanes)."""
    sgn = np.where(aN[:, :, None] ^ wN[None, :, :], -1, 1)
    j = j0.copy()
    acc = np.zeros((aB.shape[0], wB.shape[1]), np.int64)
    mod = 1 << idx_w
    for c in range(C):
        t = R.POS * c + R.POS_IDX
        rA = (R.XQ_BANK[c][None, :] ^ maskA[:, None]) >> 1
        a = rA[None, :, :] < aB[:, :, None]
        if fault != "no_len_gate":
            a &= t[None, None, :] < Lr[:, None, None]
        idx = (j[:, :, None] + (np.cumsum(a, axis=2) - a)) % mod
        if fault == "w_idx_t":
            idx = np.broadcast_to(t, idx.shape)
        rB = (R.sobol_gray(idx, R.DV_K) ^ maskW[c][None, :, None]) >> 1
        w = wB[None, :, :, None] > rB[:, :, None, :]
        acc += (sgn * (a[:, :, None, :] & w).sum(axis=3)).sum(axis=1)
        j = (j + a.sum(axis=2)) % mod
    return acc, j


def predict(case, policy="slice", fault="none", cycles="exact", idx_w=8, drain_reset=1, no_peek=False):
    nb = case["nb"]
    ss, cs = case["ss"], case["cs"]
    if policy == "nocall":
        ss_eff = ss & ~(cs & (np.arange(nb) > 0))
    elif policy == "call":
        ss_eff = cs.copy()
    elif policy == "free":
        ss_eff = np.arange(nb) == 0
    else:
        ss_eff = ss.copy()
    phases, p = np.zeros(nb, np.int64), 0
    for b in range(nb):                                  # DUT phase register (reset 0)
        armed = drain_reset and (b == 0 or bool(case["dr"][b - 1]))   # reset / drain since the last block
        p = 0 if ((ss_eff[b] or armed) and fault != "phase_free") else (p + 1) % 8
        phases[b] = p
    lane_bits = np.arange(8) if fault == "lane_mask" else R.BR3[np.arange(8)]
    mask = lambda ph: (lane_bits << 5) | (R.BR3[ph] << 2)
    j = np.zeros((8, 8), np.int64)
    acc = np.zeros((8, 8), np.int64)
    out = dict(drain_bad=0, drain_total=0, blk_bad=0, blk_total=0, phase_bad=0, phase_total=0)
    di = 0
    for b in range(nb):
        C = int(case["cy"][b])
        if cycles == "full":
            C = 8
        elif cycles == "short" and C > 1:
            C -= 1
        mA = mask(phases[b])
        mW = np.repeat(mA[None, :], C, axis=0)
        if fault == "pe_phase_early" and not case["dr"][b] and b + 1 < nb:
            mW[C - 1] = mask(phases[b + 1])
        j0 = j if fault == "j_no_restart" else np.zeros((8, 8), np.int64)
        blk, j = rg_block(case["am"][b], case["an"][b], case["wm"][b], case["wn"][b], case["L"][b], C,
                          mA, mW, j0, idx_w, fault)
        acc += blk
        out["phase_total"] += 1
        out["phase_bad"] += int(phases[b] != case["ph"][b])
        out["blk_total"] += 64
        out["blk_bad"] += int(np.count_nonzero(acc != case["ab"][b]))
        if case["dr"][b]:
            out["drain_total"] += 64
            out["drain_bad"] += int(np.count_nonzero(acc != case["ex"][di]))
            acc[:] = 0
            di += 1
    if no_peek:
        for k in ("blk_bad", "blk_total", "phase_bad", "phase_total"):
            out[k] = 0
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("case_dir")
    ap.add_argument("--policy", default="slice", choices=("slice", "nocall", "call", "free"))
    ap.add_argument("--fault", default="none", choices=FAULTS)
    ap.add_argument("--cycles", default="exact", choices=("exact", "full", "short"))
    ap.add_argument("--idx-w", type=int, default=8)
    ap.add_argument("--drain-reset", type=int, default=1, choices=(0, 1))
    ap.add_argument("--no-peek", action="store_true")
    args = ap.parse_args()
    o = predict(load_case(args.case_dir), args.policy, args.fault, args.cycles, args.idx_w, args.drain_reset,
                args.no_peek)
    print("PREDICT " + " ".join(f"{k}={v}" for k, v in o.items()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
