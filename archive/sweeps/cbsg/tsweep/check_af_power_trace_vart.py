#!/usr/bin/env python3
"""Bit-exact check of the C-BSG AF streaming power bench trace (designs/payn/power/power_payn_array_cbsg_af_vart.sv,
the L-sweep copy of power_payn_array_cbsg_af.sv; this file is the matching copy of sweeps/cbsg/af/check_power_trace.py).
The only change: workload 0 is uniform L for the L on the trace's LADDER line (one value, 1..128) instead of a fixed
128, so an L=128 trace of either bench is checked exactly as before.

Rebuilds the call from the trace (column d = 8 * block + lane; A row h lane k = AMAG[h*K + k], W column v lane k =
WMAG[v*K + k]; sign bit 1 = negative; per-row L per 128-column chunk) and recomputes the drained accumulators with
sweeps/cbsg/cbsg_ref.py two ways, which must agree with each other and with the DRAIN line:
  uniform (workload 0): kernel_acc_plain(.., L)               and hw_af_acc(.., L), L = the LADDER line's value
  ladder  (workload 1): kernel_acc_chunked(.., chunk_d=128, rung_table) summed over the chunks
                        and hw_af_acc(.., L=(rows, chunks), slice_len=128) summed over the slices
(the bench drains once, so the hardware accumulator holds the sum of the per-chunk partials).
Also checks the schedule: every block's cycle count is ceil(max L / 16), slice_start only on block 0, the
window covers exactly the block cycles, and the row lengths are constant inside a chunk.

  PYTHONDONTWRITEBYTECODE=1 python3 sweeps/cbsg/tsweep/check_af_power_trace_vart.py TRACE [--json OUT]
"""
import argparse
import importlib.util
import json
import sys
from pathlib import Path

sys.dont_write_bytecode = True
import numpy as np  # noqa: E402

REPO = Path(__file__).resolve().parents[3]
_spec = importlib.util.spec_from_file_location("cbsg_ref", REPO / "sweeps" / "cbsg" / "cbsg_ref.py")
ref = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ref)


def parse(path):
    lines = Path(path).read_text().split("\n")
    it = iter(lines)
    hdr = next(it).split()
    assert hdr[0] == "CBSGAFSTREAM", f"not a C-BSG AF stream trace: {hdr[:1]}"
    K, M, NH, NW, OW, NB, CB, WL = map(int, hdr[1:9])
    lad = list(map(int, next(it).split()[1:]))
    blocks, window, drain = [], None, None
    for line in it:
        tok = line.split()
        if not tok:
            continue
        if tok[0] == "BLOCK":
            b = dict(idx=int(tok[1]), cycles=int(tok[2]), slice_start=int(tok[3]))
            for key in ("AMAG", "ASIGN", "ALEN", "WMAG", "WSIGN"):
                t = next(it).split()
                assert t[0] == key, f"block {b['idx']}: expected {key}, got {t[0]}"
                b[key] = np.array(list(map(int, t[1:])), np.int64)
            blocks.append(b)
        elif tok[0] == "WINDOW":
            window = int(tok[1])
        elif tok[0] == "DRAIN":
            drain = np.array(list(map(int, tok[1:])), np.int64).reshape(NH, NW)
    return dict(K=K, M=M, NH=NH, NW=NW, OW=OW, NB=NB, CB=CB, WL=WL, ladder=lad,
                blocks=blocks, window=window, drain=drain)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("trace")
    ap.add_argument("--json")
    args = ap.parse_args()
    tr = parse(args.trace)
    K, NH, NW, NB, CB = tr["K"], tr["NH"], tr["NW"], tr["NB"], tr["CB"]
    bl = tr["blocks"]
    errs = []
    if len(bl) != NB:
        errs.append(f"{len(bl)} blocks in the trace, header says {NB}")
    if tr["drain"] is None or tr["window"] is None:
        errs.append("trace has no WINDOW / DRAIN line")
        print("[FAIL] " + "; ".join(errs))
        return 1
    D = K * len(bl)
    ba = np.zeros((NH, D), np.int64); sa = np.ones((NH, D), np.int64)
    bb = np.zeros((NW, D), np.int64); sb = np.ones((NW, D), np.int64)
    n_ch = -(-len(bl) // CB)
    Lrc = np.zeros((NH, n_ch), np.int64)
    for i, b in enumerate(bl):
        if b["idx"] != i:
            errs.append(f"block {i} has index {b['idx']}")
        cols = slice(K * i, K * (i + 1))
        ba[:, cols] = b["AMAG"].reshape(NH, K)
        sa[:, cols] = np.where(b["ASIGN"].reshape(NH, K) != 0, -1, 1)
        bb[:, cols] = b["WMAG"].reshape(NW, K)
        sb[:, cols] = np.where(b["WSIGN"].reshape(NW, K) != 0, -1, 1)
        L = b["ALEN"]
        ch = i // CB
        if i % CB == 0:
            Lrc[:, ch] = L
        elif not np.array_equal(Lrc[:, ch], L):
            errs.append(f"block {i}: row lengths change inside chunk {ch}")
        if b["cycles"] != -(-int(L.max()) // 16):
            errs.append(f"block {i}: {b['cycles']} cycles, ceil(max L / 16) = {-(-int(L.max()) // 16)}")
        if b["slice_start"] != int(i == 0):
            errs.append(f"block {i}: slice_start {b['slice_start']}")
    if ba.max() > 128 or bb.max() > 128 or 64 in np.concatenate([ba.ravel(), bb.ravel()]):
        errs.append("magnitudes outside the boundary map b = round(|q| * 128/127) (0..128 without 64)")
    total_cycles = sum(b["cycles"] for b in bl)
    if tr["window"] != total_cycles:
        errs.append(f"window {tr['window']} edges, blocks need {total_cycles}")

    if tr["WL"] == 0:
        if len(tr["ladder"]) != 1 or not 1 <= tr["ladder"][0] <= 128:
            errs.append(f"uniform workload needs one L in 1..128 on the LADDER line, got {tr['ladder']}")
            print("[FAIL] " + "; ".join(errs))
            return 1
        L0 = int(tr["ladder"][0])
        if not np.all(Lrc == L0):
            errs.append(f"uniform workload with L != {L0}")
        exp = ref.kernel_acc_plain(ba, sa, bb, sb, L0)
        hw = ref.hw_af_acc(ba, sa, bb, sb, L0)[0]
        wl = f"uniform L={L0}"
    else:
        lad = tr["ladder"]
        if not set(np.unique(Lrc)) <= set(lad):
            errs.append(f"row lengths {sorted(set(np.unique(Lrc)))} outside the ladder {lad}")
        rung = np.vectorize(lambda v: lad.index(int(v)))(Lrc)
        if D > K * CB:
            exp = ref.kernel_acc_chunked(ba, sa, bb, sb, K * CB, stoc_len=ref.L_MAX, rung_table=rung,
                                         level_lens=lad).sum(axis=0)
        else:                                       # one chunk: the standard (plain) path
            exp = ref.kernel_acc_plain(ba, sa, bb, sb, Lrc[:, 0])
        hw = ref.hw_af_acc(ba, sa, bb, sb, Lrc, slice_len=K * CB).sum(axis=0)
        wl = f"ladder {lad} per (row, {K * CB}-column chunk)"
    if not np.array_equal(exp, hw):
        errs.append(f"kernel and AF model disagree on {int(np.count_nonzero(exp != hw))} accumulators")
    wrong = int(np.count_nonzero(tr["drain"] != exp))
    if wrong:
        errs.append(f"{wrong} of {exp.size} drained accumulators differ from the kernel")
        for h, v in list(zip(*np.nonzero(tr["drain"] != exp)))[:5]:
            errs.append(f"  ({h},{v}) drained {tr['drain'][h, v]} expected {exp[h, v]}")

    # Workload statistics for the power analysis (A ones per element = kA, AND density).
    ka = np.zeros_like(ba)
    for i in range(len(bl)):
        cols = slice(K * i, K * (i + 1))
        masks = ref.HW_MASK[:, i % 8]
        ka[:, cols] = ref.ka_closed(ba[:, cols], Lrc[:, [i // CB]], masks[None, :])
    stats = dict(workload=wl, blocks=len(bl), columns=D, window_edges=tr["window"],
                 mean_cycles=total_cycles / len(bl), mean_L=float(Lrc.mean()),
                 a_one_density=float(ka.sum() / (NH * len(bl) * K * 16 * (total_cycles / len(bl)))),
                 mean_kA=float(ka.mean()), max_abs_acc=int(np.abs(exp).max()),
                 accumulators=int(exp.size), wrong=wrong)
    if args.json:
        Path(args.json).write_text(json.dumps(dict(stats, errors=errs), indent=1) + "\n")
    if errs:
        print("[FAIL] " + "\n  ".join(errs))
        return 1
    print(f"[PASS] {exp.size} drained accumulators bit-exact (kernel == AF model == RTL); {wl}; {len(bl)} blocks, "
          f"{tr['window']} window edges ({stats['mean_cycles']:.2f} cycles/block), mean kA {stats['mean_kA']:.1f}, "
          f"A-one density {stats['a_one_density']:.3f}, max |acc| {stats['max_abs_acc']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
