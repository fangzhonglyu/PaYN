#!/usr/bin/env python3
"""Bit-exact check of the RG streaming power bench (designs/payn/power/power_payn_array_cbsg_rg.sv).

Reads cbsg_rg_streaming_rtl.txt and recomputes the drained accumulators with sweeps/cbsg/cbsg_ref.py:
  * kernel: kernel_acc_chunked (chunk_d = 8 * CHUNK_BLOCKS columns, per-(row, chunk) rung table for the
    ladder workload, stoc_len 128) summed over chunks -- the bench drains once, after the window, so the
    tiles hold the sum of the per-chunk partials;
  * hardware model: hw_rg_acc with slice_len = chunk_d (phase restarts every chunk), summed over slices.
Workloads (CBSGRG_STREAMCFG field 7): 0 uniform L = 128; 1 ladder_rowmix, the rung-table worst case with
per-row L mixed inside a tile; 2 ladder_rowgrouped, one ladder L per chunk shared by all rows of the tile.
The drain must equal both.  Also checked: the operand mapping b = round(|q| * 128/127), |q| <= 127, the
per-block cycle count ceil(max L / 16), slice_start on chunk starts, L constant within a chunk, the
gapless generation schedule, and the window length (sum of the block cycle counts).

  python3 sweeps/cbsg/rg/check_power_trace.py <trace> [--json out.json]
"""
import argparse
import json
import sys
from pathlib import Path

sys.dont_write_bytecode = True
REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / "sweeps" / "cbsg"))
import numpy as np            # noqa: E402
import cbsg_ref as R          # noqa: E402


# 1 = rung-table worst case (per-row L mixed inside a tile); 2 = one L per chunk shared by the tile's rows.
WORKLOADS = ["uniform_L128", "ladder_rowmix", "ladder_rowgrouped"]


def parse(path):
    lines = Path(path).read_text().split("\n")
    cfg, ladder, blocks, window, drain = None, None, [], None, None
    cur = None
    for ln in lines:
        tok = ln.split()
        if not tok:
            continue
        key, vals = tok[0], tok[1:]
        if key == "CBSGRG_STREAMCFG":
            k, m, nh, nw, ow, nb, wl, cb, seed = map(int, vals)
            cfg = dict(K=k, M=m, N_H=nh, N_W=nw, OWIDTH=ow, N_BLOCKS=nb, WORKLOAD=wl, CHUNK_BLOCKS=cb, SEED=seed)
        elif key == "LADDER":
            ladder = [int(v) for v in vals]
        elif key == "BLOCK":
            cur = dict(b=int(vals[0]), C=int(vals[1]), ss=int(vals[2]), g=int(vals[3]))
            blocks.append(cur)
        elif key in ("L", "AQ", "AMAG", "ASIGN", "WQ", "WMAG", "WSIGN"):
            cur[key] = np.array([int(v) for v in vals], np.int64)
        elif key == "WINDOW":
            window = tuple(int(v) for v in vals)
        elif key == "DRAIN":
            drain = np.array([int(v) for v in vals], np.int64)
    return cfg, ladder, blocks, window, drain


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("trace")
    ap.add_argument("--json")
    args = ap.parse_args()
    cfg, ladder, blocks, window, drain = parse(args.trace)
    errs = []
    if cfg is None or drain is None or window is None:
        print("[FAIL] trace incomplete (no STREAMCFG, WINDOW or DRAIN line)")
        return 1
    K, NH, NW, NB, CB = cfg["K"], cfg["N_H"], cfg["N_W"], cfg["N_BLOCKS"], cfg["CHUNK_BLOCKS"]
    if (K, cfg["M"]) != (R.LANES, R.POS) or NH != R.TILE_R or NW != R.TILE_R:
        errs.append(f"shape K{K} M{cfg['M']} {NH}x{NW} is not the 8x8 K8 M16 C-BSG tile")
    if len(blocks) != NB:
        errs.append(f"{len(blocks)} BLOCK records, cfg says {NB}")
    D = K * NB
    cd = K * CB
    nch = -(-NB // CB)
    ba = np.zeros((NH, D), np.int64); sa = np.zeros((NH, D), np.int64)
    bb = np.zeros((NW, D), np.int64); sb = np.zeros((NW, D), np.int64)
    Lrc = np.zeros((NH, nch), np.int64)
    gen = 0
    for i, blk in enumerate(blocks):
        b = blk["b"]
        if b != i:
            errs.append(f"block record {i} is numbered {b}")
        for q, mag, what in ((blk["AQ"], blk["AMAG"], "A"), (blk["WQ"], blk["WMAG"], "W")):
            if q.min() < 0 or q.max() > R.Q_MAX:
                errs.append(f"block {b}: {what} |q| outside 0..127")
            if not np.array_equal(mag, np.rint(q * 128 / 127).astype(np.int64)):
                errs.append(f"block {b}: {what} magnitude is not round(|q| * 128/127)")
        L = blk["L"]
        ch = b // CB
        if b % CB == 0:
            Lrc[:, ch] = L
        elif not np.array_equal(Lrc[:, ch], L):
            errs.append(f"block {b}: L changed inside chunk {ch}")
        if L.min() < 1 or L.max() > R.L_MAX:
            errs.append(f"block {b}: L outside 1..128")
        if cfg["WORKLOAD"] == 0 and not np.all(L == 128):
            errs.append(f"block {b}: uniform workload with L != 128")
        if cfg["WORKLOAD"] in (1, 2) and not set(L.tolist()) <= set(ladder):
            errs.append(f"block {b}: L not drawn from the ladder {ladder}")
        if cfg["WORKLOAD"] == 2 and not np.all(L == L[0]):
            errs.append(f"block {b}: row-grouped workload with different L across the tile's rows")
        if blk["C"] != -(-int(L.max()) // R.POS):
            errs.append(f"block {b}: {blk['C']} cycles, ceil(max L / 16) = {-(-int(L.max()) // R.POS)}")
        if blk["ss"] != int(b % CB == 0):
            errs.append(f"block {b}: slice_start {blk['ss']} on chunk position {b % CB}")
        if blk["g"] != gen:
            errs.append(f"block {b}: generation starts at edge {blk['g']}, gapless schedule says {gen}")
        gen += blk["C"]
        lo = K * b
        ba[:, lo:lo + K] = blk["AMAG"].reshape(NH, K)
        sa[:, lo:lo + K] = np.where(blk["ASIGN"].reshape(NH, K) == 1, -1, 1)
        bb[:, lo:lo + K] = blk["WMAG"].reshape(NW, K)
        sb[:, lo:lo + K] = np.where(blk["WSIGN"].reshape(NW, K) == 1, -1, 1)
    if window != (gen, NB):
        errs.append(f"WINDOW {window}, expected ({gen}, {NB})")

    lens = sorted(set(Lrc.reshape(-1).tolist()))
    if nch > 1:
        rung = np.searchsorted(np.array(lens), Lrc)
        kern = R.kernel_acc_chunked(ba, sa, bb, sb, cd, stoc_len=R.L_MAX, rung_table=rung, level_lens=lens).sum(0)
    else:
        kern = R.kernel_acc_plain(ba, sa, bb, sb, Lrc[:, 0])
    hw = R.hw_rg_acc(ba, sa, bb, sb, Lrc, slice_len=cd).sum(0)
    got = drain.reshape(NH, NW)
    n_k = int(np.count_nonzero(got != kern))
    n_h = int(np.count_nonzero(got != hw))
    n_kh = int(np.count_nonzero(kern != hw))
    if n_kh:
        errs.append(f"reference disagreement: kernel vs hw_rg_acc differ in {n_kh} accumulators")
    if n_k:
        errs.append(f"drain vs kernel: {n_k}/{got.size} accumulators differ")
    if n_h:
        errs.append(f"drain vs hw_rg_acc: {n_h}/{got.size} accumulators differ")
    res = dict(trace=str(args.trace), workload=WORKLOADS[cfg["WORKLOAD"]], blocks=NB,
               chunks=nch, window_clocks=gen, macs=NB * NH * NW * K, drain_accs=int(got.size),
               drain_vs_kernel_bad=n_k, drain_vs_hw_bad=n_h, max_abs_acc=int(np.abs(got).max()),
               cycles_hist={int(c): int(sum(1 for b in blocks if b["C"] == c)) for c in sorted({b["C"] for b in blocks})},
               lens=lens, errors=errs)
    if args.json:
        Path(args.json).write_text(json.dumps(res, indent=1) + "\n")
    for e in errs[:20]:
        print("  " + e)
    tag = "PASS" if not errs else "FAIL"
    print(f"[{tag}] {res['workload']}: {NB} blocks ({nch} chunks of {cd} columns), {gen} window clocks, "
          f"{res['macs']} MACs; drain {got.size} accumulators vs kernel_acc_chunked {n_k} bad, vs hw_rg_acc {n_h} bad; "
          f"max |acc| {res['max_abs_acc']}; cycles/block {res['cycles_hist']}")
    return 0 if not errs else 1


if __name__ == "__main__":
    sys.exit(main())
