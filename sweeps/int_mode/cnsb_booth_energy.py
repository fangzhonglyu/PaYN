#!/usr/bin/env python3
"""Stimulus generator and bit-exact checker for the CNSB INT energy bench.

CNSB = comparator-native spatial Booth (design key red_team_novel, same mapping
as spatial_fixed_weight).  The routed CSA netlist is used unchanged: the shared
Sobol random-value nets are held at PRESETS["r4rows"] (the bench forces them,
modelling the proposed preset gate with rng_en = 0), and every clock the edge
binary/sign ports carry per-lane comparator codes and Booth-digit signs.

  gen   : draw an INT workload (A rows x L, W L x cols), recode it into Booth
          digits, map digits onto PE rows/columns (orientation r4rows) and write
          the per-slice port image int_stim.mem, int_preset.mem, operands.npz
          and stim_meta.json.
  check : parse the drained accumulator matrix from the bench trace and require
            (1) every drained tile == T_pq, computed from the raw operands with
                an independent table-driven Booth recoder (not the model's);
            (2) the edge combine sum_pq 4^p 16^q T_pq == numpy A @ W (int64);
            (3) the stimulus itself, pushed through the comparator formula with
                the preset thresholds, the 16-slot AND/popcount and the lane
                sign XOR, reproduces T_pq (independent of the netlist).

Mappings (tile row h, tile column v; lane k of slice s carries reduction index
l = 8 s + k):
  int8 : h = 4 i + p (2 activations x 4 radix-4 digits),
         v = 2 j + q (4 weights x 2 radix-16 digits)      64 MAC/cycle/PE
  w4a8 : h = 4 i + p, v = j (8 4-bit weights, w is its own radix-16 digit)
                                                           128 MAC/cycle/PE
  int4 : h = 2 i + p (4 activations x 2 radix-4 digits), v = j
                                                           256 MAC/cycle/PE

Sign convention ("gated", default): lane sign = digit < 0, i.e. the raw sign
bit ANDed with digit != 0 (one AND2 per digit lane in the feeder).  "raw" uses
the raw group sign bit (bit 2p+1 / bit 4q+3), which is a pure wire but sets the
sign of zero digits of negative operands; both are exact (count 0 -> 0).

No EDA tools.  Usage:
  python3 cnsb_booth_energy.py gen --prec int8 --dist uniform --out DIR
  python3 cnsb_booth_energy.py check --stim DIR --trace int_booth_trace.txt
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import model_red_team_novel as mdl  # noqa: E402  (design presets + E codes)

K, M, NH, NW, WIDTH, OWIDTH = 8, 16, 8, 8, 8, 24
SALT_A, SALT_W = 0, 128
SK, SM = ((256 * 79) // 128) | 1, ((256 * 49) // 128) | 1   # pe_peripheral.sv
ORIENT = "r4rows"

# prec -> (a bits, w bits, NP a-digits, NQ w-digits, NI acts, NJ weights,
#          digit pairs per MAC, MAC per cycle per PE)
PRECS = {
    "int8": dict(ab=8, wb=8, NP=4, NQ=2, NI=2, NJ=4, mac_per_cycle=64),
    "w4a8": dict(ab=8, wb=4, NP=4, NQ=1, NI=2, NJ=8, mac_per_cycle=128),
    "int4": dict(ab=4, wb=4, NP=2, NQ=1, NI=4, NJ=8, mac_per_cycle=256),
}
A_BW, A_SW, W_BW, W_SW = NH * K * WIDTH, NH * K, NW * K * WIDTH, NW * K
STIM_W = A_BW + A_SW + W_BW + W_SW                  # 1152 bits per slice


# ---------------------------------------------------------------- workload --
def draw(dist: str, bits: int, shape, rng, sigma_frac: float):
    lo, hi = -(1 << (bits - 1)), (1 << (bits - 1)) - 1
    if dist == "uniform":
        return rng.integers(lo, hi + 1, shape, dtype=np.int64)
    if dist == "dnn":
        # clipped Gaussian, sigma = sigma_frac * 2^(bits-1) (0.25: clip at ~4 sigma)
        sigma = sigma_frac * (1 << (bits - 1))
        return np.clip(np.rint(rng.normal(0.0, sigma, shape)), lo, hi).astype(np.int64)
    raise SystemExit(f"unknown dist {dist}")


def group_sign_bits(v, nbits, r_bits):
    """Raw sign bit of each Booth group: bit (r*d + r - 1), capped at nbits-1."""
    u = np.asarray(v, np.int64) & ((1 << nbits) - 1)
    nd = -(-nbits // r_bits)
    return np.stack([(u >> min(r_bits * d + r_bits - 1, nbits - 1)) & 1
                     for d in range(nd)], -1)


def masks(salt):
    k = np.arange(K)[:, None]
    m = np.arange(M)[None, :]
    return (k * SK + m * SM + salt) & 255


def gen(args):
    cfg = PRECS[args.prec]
    NP, NQ, NI, NJ = cfg["NP"], cfg["NQ"], cfg["NI"], cfg["NJ"]
    assert NP * NI == NH and NQ * NJ == NW
    n = args.slices
    n_stim = n + 2                       # two slices in flight at window end
    L_tot = K * n_stim
    rng = np.random.default_rng(args.seed)
    A = draw(args.dist, cfg["ab"], (NI, L_tot), rng, args.sigma_frac)
    W = draw(args.dist, cfg["wb"], (L_tot, NJ), rng, args.sigma_frac)

    pre = mdl.PRESETS[ORIENT]
    Er, Ec = mdl.verify_preset(ORIENT)   # exhaustive per-lane certification
    da = mdl.booth_digits(A, cfg["ab"], 2)            # [NI, L, NP]
    dw = mdl.booth_digits(W, cfg["wb"], 4)            # [L, NJ, NQ]
    assert da.shape[-1] == NP and dw.shape[-1] == NQ
    if args.sign == "gated":
        sa = (da < 0).astype(np.int64)
        sw = (dw < 0).astype(np.int64)
    else:
        sa = group_sign_bits(A, cfg["ab"], 2)
        sw = group_sign_bits(W, cfg["wb"], 4)
    # tile-row / tile-column streams: [slice, h|v, k]
    da_r = da.reshape(NI, n_stim, K, NP).transpose(1, 0, 3, 2).reshape(n_stim, NH, K)
    sa_r = sa.reshape(NI, n_stim, K, NP).transpose(1, 0, 3, 2).reshape(n_stim, NH, K)
    dw_c = dw.reshape(n_stim, K, NJ, NQ).transpose(0, 2, 3, 1).reshape(n_stim, NW, K)
    sw_c = sw.reshape(n_stim, K, NJ, NQ).transpose(0, 2, 3, 1).reshape(n_stim, NW, K)
    kk = np.arange(K)[None, None, :]
    a_code = Er[kk, np.abs(da_r)]
    w_code = Ec[kk, np.abs(dw_c)]

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    lines = []
    for s in range(n_stim):
        a_bin = sum(int(c) << (8 * i) for i, c in enumerate(a_code[s].reshape(-1)))
        a_sg = sum(int(b) << i for i, b in enumerate(sa_r[s].reshape(-1)))
        w_bin = sum(int(c) << (8 * i) for i, c in enumerate(w_code[s].reshape(-1)))
        w_sg = sum(int(b) << i for i, b in enumerate(sw_c[s].reshape(-1)))
        word = a_bin | (a_sg << A_BW) | (w_bin << (A_BW + A_SW)) | \
            (w_sg << (A_BW + A_SW + W_BW))
        lines.append(f"{word:0{STIM_W // 4}x}")
    (out / "int_stim.mem").write_text("\n".join(lines) + "\n")
    pa = sum(int(v) << (8 * m) for m, v in enumerate(pre["row"]))
    pw = sum(int(v) << (8 * m) for m, v in enumerate(pre["col"]))
    (out / "int_preset.mem").write_text(f"{pa:032x}\n{pw:032x}\n")
    np.savez_compressed(out / "operands.npz", A=A, W=W, a_code=a_code, w_code=w_code,
                        a_sign=sa_r, w_sign=sw_c)

    # activity statistics of the port image (explains workload energy shifts)
    def ham(x, width):
        d = np.bitwise_xor(x[1:], x[:-1]).astype(np.uint64)
        return int(sum(((d >> b) & 1).sum() for b in range(width)))
    win = slice(0, n_stim)
    stats = dict(
        a_digit_zero_frac=float((da_r == 0).mean()),
        w_digit_zero_frac=float((dw_c == 0).mean()),
        a_digit_mean_abs=float(np.abs(da_r).mean()),
        w_digit_mean_abs=float(np.abs(dw_c).mean()),
        mean_lane_count=float((np.abs(da_r)[:, :, None, :] *
                               np.abs(dw_c)[:, None, :, :]).mean()),
        a_code_bit_toggles_per_cycle=ham(a_code[win], 8) / (n_stim - 1),
        w_code_bit_toggles_per_cycle=ham(w_code[win], 8) / (n_stim - 1),
        a_sign_toggles_per_cycle=ham(sa_r[win], 1) / (n_stim - 1),
        w_sign_toggles_per_cycle=ham(sw_c[win], 1) / (n_stim - 1),
        a_sign_one_frac=float(sa_r.mean()),
        w_sign_one_frac=float(sw_c.mean()),
    )
    meta = dict(design="CNSB (red_team_novel) comparator-native spatial Booth",
                orient=ORIENT, prec=args.prec, dist=args.dist, sign=args.sign,
                sigma_frac=args.sigma_frac if args.dist == "dnn" else None,
                seed=args.seed, slices=n, stim_slices=n_stim,
                reduction_len_accumulated=K * n, mac_per_cycle_per_pe=cfg["mac_per_cycle"],
                presets=dict(a_bank=pre["row"], w_bank=pre["col"]),
                code_table_a=Er.tolist(), code_table_w=Ec.tolist(),
                stats=stats, **{k: v for k, v in cfg.items() if k != "mac_per_cycle"})
    (out / "stim_meta.json").write_text(json.dumps(meta, indent=1) + "\n")
    print(json.dumps(dict(out=str(out), prec=args.prec, dist=args.dist, sign=args.sign,
                          slices=n, **stats)))


# ----------------------------------------------------------------- checker --
# Independent recoders: 3-bit / 5-bit group -> digit lookup tables, built from
# the radix definitions, not from model_red_team_novel.booth_digits.
R4_TABLE = np.array([0, 1, 1, 2, -2, -1, -1, 0], np.int64)          # b(2p+1) b(2p) b(2p-1)
R16_TABLE = np.array([(-8 * ((g >> 4) & 1) + 4 * ((g >> 3) & 1) + 2 * ((g >> 2) & 1)
                       + ((g >> 1) & 1) + (g & 1)) for g in range(32)], np.int64)


def ref_digits(v, nbits, r_bits):
    u = (np.asarray(v, np.int64) & ((1 << nbits) - 1)) << 1      # append b(-1) = 0
    table = R4_TABLE if r_bits == 2 else R16_TABLE
    nd = -(-nbits // r_bits)
    width = r_bits + 1
    digits = []
    for d in range(nd):
        g = (u >> (r_bits * d)) & ((1 << width) - 1)
        digits.append(table[g])
    dig = np.stack(digits, -1)
    recon = sum(dig[..., d] * (1 << (r_bits * d)) for d in range(nd))
    assert np.array_equal(recon, np.asarray(v, np.int64)), "reference recoder broken"
    return dig


def parse_trace(path: Path):
    cfg, drain, passed, presets = None, None, False, {}
    for line in path.read_text().splitlines():
        if line.startswith("PRESET_"):
            name, val = line.split()
            presets[name] = [(int(val, 16) >> (8 * m)) & 255 for m in range(M)]
        elif line.startswith("INTCFG"):
            cfg = [int(x) for x in line.split()[1:]]
        elif line.startswith("DRAIN"):
            drain = np.array([int(x) for x in line.split()[1:]], np.int64)
        elif line.startswith("TRACE_END"):
            passed = True
    if cfg is None or drain is None or not passed or len(presets) != 2:
        raise SystemExit(f"[FAIL] incomplete trace {path}")
    return cfg, drain, presets


def check(args):
    stim = Path(args.stim)
    meta = json.loads((stim / "stim_meta.json").read_text())
    ops = np.load(stim / "operands.npz")
    A, W = ops["A"], ops["W"]
    cfg = PRECS[meta["prec"]]
    NP, NQ, NI, NJ = cfg["NP"], cfg["NQ"], cfg["NI"], cfg["NJ"]
    n = meta["slices"]
    L = K * n
    tcfg, drain, tpre = parse_trace(Path(args.trace))
    exp_cfg = [K, M, NH, NW, WIDTH, OWIDTH, n]
    if tcfg != exp_cfg:
        raise SystemExit(f"[FAIL] trace INTCFG {tcfg} != expected {exp_cfg}")
    if tpre != {"PRESET_A": meta["presets"]["a_bank"], "PRESET_W": meta["presets"]["w_bank"]}:
        raise SystemExit(f"[FAIL] bench presets {tpre} differ from the stimulus presets")
    if drain.size != NH * NW:
        raise SystemExit(f"[FAIL] drain has {drain.size} values")
    T_hw = drain.reshape(NH, NW)

    # (1) reference tile sums from raw operands (accumulated slices only)
    da = ref_digits(A[:, :L], cfg["ab"], 2)                 # [NI, L, NP]
    dw = ref_digits(W[:L, :], cfg["wb"], 4)                 # [L, NJ, NQ]
    T_ref = np.zeros((NH, NW), np.int64)
    for i in range(NI):
        for p in range(NP):
            for j in range(NJ):
                for q in range(NQ):
                    T_ref[NP * i + p, NQ * j + q] = int(np.dot(da[i, :, p], dw[:, j, q]))
    lim = 1 << (OWIDTH - 1)
    assert np.all(np.abs(T_ref) < lim), "reference exceeds OWIDTH"
    bad = np.argwhere(T_hw != T_ref)

    # (2) east-edge combine vs numpy GEMM
    Y_ref = A[:, :L].astype(np.int64) @ W[:L, :].astype(np.int64)
    Y_hw = np.zeros((NI, NJ), np.int64)
    for i in range(NI):
        for j in range(NJ):
            Y_hw[i, j] = sum((4 ** p) * (16 ** q) * int(T_hw[NP * i + p, NQ * j + q])
                             for p in range(NP) for q in range(NQ))

    # (3) stimulus -> comparator -> AND/popcount -> lane sign, per slice
    thr_a = np.asarray(meta["presets"]["a_bank"])[None, :] ^ \
        (lambda k, m: (k * SK + m * SM + SALT_A) & 255)(np.arange(K)[:, None], np.arange(M)[None, :])
    thr_w = np.asarray(meta["presets"]["w_bank"])[None, :] ^ \
        (lambda k, m: (k * SK + m * SM + SALT_W) & 255)(np.arange(K)[:, None], np.arange(M)[None, :])
    a_code, w_code = ops["a_code"][:n], ops["w_code"][:n]
    a_sg, w_sg = ops["a_sign"][:n], ops["w_sign"][:n]
    a_bits = a_code[..., None] > thr_a[None, None]             # [n, NH, K, M]
    w_bits = w_code[..., None] > thr_w[None, None]             # [n, NW, K, M]
    T_emu = np.zeros((NH, NW), np.int64)
    max_d = 0
    for s0 in range(0, n, 256):
        ab, wb = a_bits[s0:s0 + 256], w_bits[s0:s0 + 256]
        cnt = (ab[:, :, None] & wb[:, None]).sum(-1).astype(np.int64)    # [s,h,v,k]
        neg = a_sg[s0:s0 + 256][:, :, None, :] ^ w_sg[s0:s0 + 256][:, None, :, :]
        d = np.where(neg == 1, -cnt, cnt).sum(-1)                         # [s,h,v]
        max_d = max(max_d, int(np.abs(d).max()))
        T_emu += d.sum(0)
    ok = (bad.size == 0 and np.array_equal(Y_hw, Y_ref) and np.array_equal(T_emu, T_ref)
          and max_d <= K * M)
    result = dict(
        status="PASS" if ok else "FAIL", prec=meta["prec"], dist=meta["dist"],
        sign=meta["sign"], slices=n, reduction_len=L, tiles_checked=int(NH * NW),
        tile_mismatches=int(bad.shape[0]),
        first_mismatches=[(int(h), int(v), int(T_hw[h, v]), int(T_ref[h, v]))
                          for h, v in bad[:4]],
        gemm_outputs_checked=int(NI * NJ),
        gemm_match=bool(np.array_equal(Y_hw, Y_ref)),
        stimulus_emulation_match=bool(np.array_equal(T_emu, T_ref)),
        max_abs_cycle_partial=max_d, max_abs_tile=int(np.abs(T_ref).max()),
        nonzero_tiles=int((T_ref != 0).sum()),
        max_abs_gemm=int(np.abs(Y_ref).max()),
    )
    text = json.dumps(result, indent=1)
    if args.json:
        Path(args.json).write_text(text + "\n")
    print(text)
    print("[PASS] CNSB drain bit-exact: tiles == T_pq reference, combine == numpy GEMM"
          if ok else "[FAIL] CNSB drain mismatch")
    if not ok:
        raise SystemExit(1)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    g = sub.add_parser("gen")
    g.add_argument("--prec", choices=sorted(PRECS), required=True)
    g.add_argument("--dist", choices=["uniform", "dnn"], required=True)
    g.add_argument("--sign", choices=["gated", "raw"], default="gated")
    g.add_argument("--sigma-frac", type=float, default=0.25)
    g.add_argument("--slices", type=int, default=3072)
    g.add_argument("--seed", type=int, default=20261003)
    g.add_argument("--out", required=True)
    c = sub.add_parser("check")
    c.add_argument("--stim", required=True)
    c.add_argument("--trace", required=True)
    c.add_argument("--json")
    args = ap.parse_args()
    gen(args) if args.cmd == "gen" else check(args)


if __name__ == "__main__":
    main()
