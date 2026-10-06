#!/usr/bin/env python3
"""Adversarial re-checks of the round-1 bit-plane (bitplane_throughput) model.

Reuses sweeps/int_mode/model_bitplane_throughput.py unchanged (imported, never
edited).  Checks:
  1. HW-ring INT8 at the grid sizes that the area-efficiency claim is made for
     (4x4 and 4x8; the round-1 run stopped at 2x3), with partial output tiles,
     and the block-cycle formula  Bw*ceil(L/128) + 8*(Bw-1) + (P_R+P_C-2) + 8*P_C.
  2. INT8 HB (both planes in time, 64 outputs/PE) at L <= 511, which round 1
     declared "not offered": worst-case |out| <= 2^14*L < 2^23 holds for
     L <= 511, so it should be exact there and overflow at L = 512.
  3. The rtl_changes text says raw_bits reuse a_binary_in[511:0].  The model
     drives a_raw and a_bin as separate ports, so it never tested that.  Here
     the SC transparency check is re-run with the shared lines as written
     (raw = a_binary_in on the 512 reused lines, bus zero except on load
     cycles) to see whether SC stays bit-identical without an int_mode gate.
Usage: python3 sweeps/int_mode/verify/bitplane_ring/check_model_grid.py
"""
import sys
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
import model_bitplane_throughput as mb  # noqa: E402


def formula_hw(L, pr, pc, bw=8, lap=8):
    return bw * -(-L // 128) + lap * (bw - 1) + (pr + pc - 2) + 8 * pc


def formula_hb(L, pr, pc, ba=8, bw=8, lap=8):
    return ba * bw * -(-L // 128) + lap * (ba + bw - 2) + (pr + pc - 2) + 8 * pc


def run(tag, A, W, mode, ba, bw, pr, pc, mech, rng, expect):
    t0 = time.time()
    _, st = mb.run_gemm(A, W, mode, ba, bw, pr, pc, mech, rng)
    ok = st["block_cycles"] == expect
    print(f"  {tag:46s} exact vs numpy; {st['blocks']} blocks, {st['block_cycles']} cyc/block "
          f"(formula {expect}: {'MATCH' if ok else 'MISMATCH'}), max|tile| {st['max_tile']}, "
          f"max|out| {st['max_out']}  [{time.time()-t0:.1f}s]")
    assert ok
    return st


def sc_shared_line_test(pr, pc, rng, gate):
    """SC stimulus where the 512 reused raw lines carry a_binary_in (bus only
    driven on load cycles).  gate=True models raw & int_mode."""
    ga = mb.Grid(pr, pc, "ring", int_hw=True)
    gb = mb.Grid(pr, pc, "none", int_hw=False)
    T = 8                                    # SC reloads magnitudes every T/M = 128/16 = 8 clocks
    mism = 0
    first = None
    for blk in range(4):
        a_bin = rng.integers(0, 256, (pr, mb.NH, mb.NK))
        w_bin = rng.integers(0, 256, (pc, mb.NW, mb.NK))
        a_sgn = rng.integers(0, 2, (pr, mb.NH, mb.NK))
        w_sgn = rng.integers(0, 2, (pc, mb.NW, mb.NK))
        for t in range(T):
            load = int(t == 0)
            a_raw = np.zeros((pr, mb.NH, mb.NK, mb.M), dtype=np.int64)
            w_raw = np.zeros((pc, mb.NW, mb.NK, mb.M), dtype=np.int64)
            if load and not gate:
                # a_binary_in[511:0] bit n -> raw line n (row h, lane k, position m order)
                for r in range(pr):
                    bits = ((a_bin[r].reshape(-1)[:, None] >> np.arange(8)) & 1).reshape(-1)  # 512
                    flat = a_raw[r].reshape(-1)
                    flat[:512] = bits
                    a_raw[r] = flat.reshape(mb.NH, mb.NK, mb.M)
                for c in range(pc):
                    bits = ((w_bin[c].reshape(-1)[:, None] >> np.arange(8)) & 1).reshape(-1)
                    flat = w_raw[c].reshape(-1)
                    flat[:512] = bits
                    w_raw[c] = flat.reshape(mb.NW, mb.NK, mb.M)
            inp = dict(int_mode=0, mac_en=1, shift_in=0,
                       a_rand=rng.integers(0, 256, mb.M), w_rand=rng.integers(0, 256, mb.M),
                       a_raw=a_raw, w_raw=w_raw,
                       a_bin=a_bin, w_bin=w_bin, a_sgn=a_sgn, w_sgn=w_sgn,
                       load_a=[load] * pr, load_w=[load] * pc,
                       load_a_sign=np.full(pr, load), load_w_sign=np.full(pc, load),
                       ring=np.zeros(pr, dtype=np.int64), dbl=np.zeros(pr, dtype=np.int64))
            # original datapath never sees raw lines
            inp_b = dict(inp)
            inp_b["a_raw"] = np.zeros_like(a_raw)
            inp_b["w_raw"] = np.zeros_like(w_raw)
            ga.step(inp)
            gb.step(inp_b)
            for x, y in zip(ga.state(), gb.state()):
                if not np.array_equal(x, y):
                    mism += 1
                    if first is None:
                        first = ga.cycle
                    break
    return mism, first


def main():
    rng = np.random.default_rng(20261004)
    print("== 1. HW-ring INT8 at grid scale (block-cycle formula check)")
    run("4x4 INT8 HW/ring random K=256 M=5 N=33", *mb.gen("random", 5, 256, 33, 8, 8, rng),
        "HW", 8, 8, 4, 4, "ring", rng, formula_hw(256, 4, 4))
    run("4x4 INT8 HW/ring allmin K=1024 M=4 N=32", *mb.gen("allmin", 4, 1024, 32, 8, 8, rng),
        "HW", 8, 8, 4, 4, "ring", rng, formula_hw(1024, 4, 4))
    run("4x4 INT8 HW/ring random K=128 M=4 N=32", *mb.gen("random", 4, 128, 32, 8, 8, rng),
        "HW", 8, 8, 4, 4, "ring", rng, formula_hw(128, 4, 4))
    run("4x8 INT8 HW/ring random K=128 M=5 N=65", *mb.gen("random", 5, 128, 65, 8, 8, rng),
        "HW", 8, 8, 4, 8, "ring", rng, formula_hw(128, 4, 8))
    run("4x4 INT8 S (BP-S) random K=256 M=5 N=5", *mb.gen("random", 5, 256, 5, 8, 8, rng),
        "S", 8, 8, 4, 4, "none", rng, -(-256 // 128) + 6 + 32)

    print("\n== 2. INT8 HB (64 outputs/PE) at short L -- round 1 said 'not offered'")
    for kind, L in (("random", 128), ("random", 64), ("allmin", 511), ("minmax", 511),
                    ("alternating", 511), ("allmax", 511)):
        run(f"2x2 INT8 HB/ring {kind} K={L} M=17 N=17", *mb.gen(kind, 17, L, 17, 8, 8, rng),
            "HB", 8, 8, 2, 2, "ring", rng, formula_hb(L, 2, 2))
    run("4x4 INT8 HB/ring random K=128 M=32 N=32", *mb.gen("random", 32, 128, 32, 8, 8, rng),
        "HB", 8, 8, 4, 4, "ring", rng, formula_hb(128, 4, 4))
    A, W = mb.gen("allmin", 8, 512, 8, 8, 8, rng)
    try:
        mb.run_gemm(A, W, "HB", 8, 8, 1, 1, "ring", rng)
        print("  1x1 INT8 HB allmin K=512: UNEXPECTED PASS")
    except mb.ModelError as e:
        print(f"  1x1 INT8 HB allmin K=512: overflows as predicted -> {e}")

    print("\n== 3. SC transparency with raw lines shared with a_binary_in[511:0] (as the rtl_changes state)")
    for gate in (False, True):
        m, first = sc_shared_line_test(2, 2, rng, gate)
        print(f"  2x2, {'raw & int_mode gate' if gate else 'no gate (as written)'}: "
              f"{m} cycles with register mismatch vs original SC datapath"
              + (f" (first at cycle {first})" if first is not None else ""))


if __name__ == "__main__":
    main()
