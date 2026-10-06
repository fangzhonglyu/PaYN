#!/usr/bin/env python3
"""Bit-exact check of an SC streaming power-bench trace of payn_array (CBSGAFSTREAM format).

The bench streams NB blocks of K columns through one PE, drains once after the SAIF window and writes every block's
operands, row lengths and cycle count plus the drained accumulators.  This rebuilds the call from the trace
(column d = K * block + lane; A row h lane k = AMAG[h*K + k], W column v lane k = WMAG[v*K + k]; sign bit 1 =
negative; one L per row and 128-column chunk) and recomputes the drain two ways, which must agree with each other
and with the DRAIN line:
  uniform (workload 0): kernel_acc_plain(.., L)                        and hw_af_acc(.., L)
                        (one L on every row, 1..128, from the LADDER line)
  ladder  (workload 1): kernel_acc_chunked(.., chunk_d, rung_table)    and hw_af_acc(.., L=(rows, chunks),
                        summed over the chunks                             slice_len=chunk_d) summed over the slices
(one drain, so the hardware accumulator holds the sum of the per-chunk partials; chunk_d = K * CB).  Also checks the
schedule: every block runs ceil(max L / M) cycles, slice_start only on block 0, the window covers exactly the block
cycles, the row lengths are constant inside a chunk.  The PE shape (K, M) comes from the header.

Trace format:
  CBSGAFSTREAM K M NH NW OWIDTH NB CB WL      CB = blocks per chunk, WL = workload (0 uniform, 1 ladder)
  LADDER v ...                                 WL 1: the ladder; WL 0: the uniform L
  BLOCK i cycles slice_start, then lines AMAG / ASIGN / ALEN / WMAG / WSIGN with NH*K, NH*K, NH, NW*K, NW*K values
  WINDOW edges
  DRAIN acc[0][0] ... acc[NH-1][NW-1]

  python3 designs/payn/model/sc_trace.py TRACE [--json OUT] [--shape k8m16|k16m8]
"""
import argparse
import json
import sys
from pathlib import Path

sys.dont_write_bytecode = True
import numpy as np  # noqa: E402

from cbsg import L_MAX, SHAPES, geometry, hw_af_acc, ka_closed, kernel_acc_chunked, kernel_acc_plain  # noqa: E402


def parse(path):
    it = iter(Path(path).read_text().split("\n"))
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
    return dict(K=K, M=M, NH=NH, NW=NW, OW=OW, NB=NB, CB=CB, WL=WL, ladder=lad, blocks=blocks, window=window,
                drain=drain)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("trace")
    ap.add_argument("--json", help="write the workload statistics and errors here")
    ap.add_argument("--shape", choices=SHAPES, help="require this PE shape (the header's K M must match)")
    args = ap.parse_args()
    tr = parse(args.trace)
    K, M, NH, NW, NB, CB = tr["K"], tr["M"], tr["NH"], tr["NW"], tr["NB"], tr["CB"]
    if args.shape and SHAPES[args.shape] != (K, M):
        print(f"[FAIL] trace shape K{K}/M{M}, --shape {args.shape}")
        return 1
    g = geometry(K, M)
    bl = tr["blocks"]
    errs = []
    if len(bl) != NB:
        errs.append(f"{len(bl)} blocks in the trace, header says {NB}")
    if tr["drain"] is None or tr["window"] is None:
        errs.append("trace has no WINDOW / DRAIN line")
        print("[FAIL] " + "; ".join(errs))
        return 1
    D = K * len(bl)
    ba, sa = np.zeros((NH, D), np.int64), np.ones((NH, D), np.int64)
    bb, sb = np.zeros((NW, D), np.int64), np.ones((NW, D), np.int64)
    Lrc = np.zeros((NH, -(-len(bl) // CB)), np.int64)
    for i, b in enumerate(bl):
        if b["idx"] != i:
            errs.append(f"block {i} has index {b['idx']}")
        cols = slice(K * i, K * (i + 1))
        ba[:, cols] = b["AMAG"].reshape(NH, K)
        sa[:, cols] = np.where(b["ASIGN"].reshape(NH, K) != 0, -1, 1)
        bb[:, cols] = b["WMAG"].reshape(NW, K)
        sb[:, cols] = np.where(b["WSIGN"].reshape(NW, K) != 0, -1, 1)
        L, ch = b["ALEN"], i // CB
        if i % CB == 0:
            Lrc[:, ch] = L
        elif not np.array_equal(Lrc[:, ch], L):
            errs.append(f"block {i}: row lengths change inside chunk {ch}")
        if b["cycles"] != -(-int(L.max()) // M):
            errs.append(f"block {i}: {b['cycles']} cycles, ceil(max L / {M}) = {-(-int(L.max()) // M)}")
        if b["slice_start"] != int(i == 0):
            errs.append(f"block {i}: slice_start {b['slice_start']}")
    if ba.max() > 128 or bb.max() > 128 or 64 in np.concatenate([ba.ravel(), bb.ravel()]):
        errs.append("magnitudes outside the boundary map b = round(|q| * 128/127) (0..128 without 64)")
    total_cycles = sum(b["cycles"] for b in bl)
    if tr["window"] != total_cycles:
        errs.append(f"window {tr['window']} edges, blocks need {total_cycles}")

    if tr["WL"] == 0:
        L0 = int(tr["ladder"][0]) if tr["ladder"] else 128      # the uniform L, on the LADDER line
        if not 1 <= L0 <= 128 or not np.all(Lrc == L0):
            errs.append(f"uniform workload: row lengths {sorted(set(np.unique(Lrc)))}, header L {L0}")
        exp = kernel_acc_plain(ba, sa, bb, sb, L0)
        hw = hw_af_acc(ba, sa, bb, sb, L0, shape=(K, M))[0]
        wl = f"uniform L={L0}"
    else:
        lad = tr["ladder"]
        if not set(np.unique(Lrc)) <= set(lad):
            errs.append(f"row lengths {sorted(set(np.unique(Lrc)))} outside the ladder {lad}")
        rung = np.vectorize(lambda v: lad.index(int(v)))(Lrc)
        if D > K * CB:
            exp = kernel_acc_chunked(ba, sa, bb, sb, K * CB, stoc_len=L_MAX, rung_table=rung, level_lens=lad).sum(axis=0)
        else:                                       # one chunk: the standard (plain) path
            exp = kernel_acc_plain(ba, sa, bb, sb, Lrc[:, 0])
        hw = hw_af_acc(ba, sa, bb, sb, Lrc, slice_len=K * CB, shape=(K, M)).sum(axis=0)
        wl = f"ladder {lad} per (row, {K * CB}-column chunk)"
    if not np.array_equal(exp, hw):
        errs.append(f"kernel and AF model disagree on {int(np.count_nonzero(exp != hw))} accumulators")
    wrong = int(np.count_nonzero(tr["drain"] != exp))
    if wrong:
        errs.append(f"{wrong} of {exp.size} drained accumulators differ from the kernel")
        for h, v in list(zip(*np.nonzero(tr["drain"] != exp)))[:5]:
            errs.append(f"  ({h},{v}) drained {tr['drain'][h, v]} expected {exp[h, v]}")

    # Workload statistics for the power analysis: A ones per element (kA) and AND-input density.
    ka = np.zeros_like(ba)
    for i in range(len(bl)):
        cols = slice(K * i, K * (i + 1))
        ka[:, cols] = ka_closed(ba[:, cols], Lrc[:, [i // CB]], g.MASK[None, :, i % g.NPH])
    stats = dict(workload=wl, blocks=len(bl), columns=D, window_edges=tr["window"],
                 mean_cycles=total_cycles / len(bl), mean_L=float(Lrc.mean()),
                 a_one_density=float(ka.sum() / (NH * len(bl) * K * M * (total_cycles / len(bl)))),
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
