#!/usr/bin/env python3
"""Stimulus generator and checker for tb_cnsb_int.sv (RTL check of CNSB).

Independent of the architects' models: Booth recoding, per-lane code choice,
schedule, drain decoding and the digit-weight combine are written here from
the design description and the RTL.  The comparator thresholds come from the
RTL mask formula (re-derived in cnsb_identity_check.py) and the claimed
presets.

  python3 cnsb_rtl_cases.py list
  python3 cnsb_rtl_cases.py gen   <case> <dir>     -> <dir>/stim.txt, <dir>/meta.npz
  python3 cnsb_rtl_cases.py check <case> <dir>     -> compares <dir>/out.txt

A case is expected to PASS unless its 'expect' is 'fail' (negative controls
and the OWIDTH boundary probe), in which case the checker requires a mismatch.
"""
from __future__ import annotations

import json
import sys

import numpy as np

K, M, NH, NW = 8, 16, 8, 8
SK, SM, SALT_A, SALT_W = 159, 99, 0, 128   # pe_peripheral.sv, routed top

PRESETS = {
    "spatial": dict(row=[183, 166, 106, 211, 179, 48, 65, 189, 197, 84, 120, 108,
                         10, 177, 221, 209],
                    col=[254, 16, 49, 107, 53, 212, 110, 133, 21, 35, 183, 70,
                         165, 180, 161, 32]),
    "red_r4rows": dict(row=[184, 112, 109, 173, 159, 27, 142, 93, 253, 44, 148,
                            40, 250, 207, 155, 139],
                       col=[243, 203, 204, 246, 229, 147, 152, 9, 146, 95, 190,
                            181, 96, 91, 75, 37]),
    "red_r16rows": dict(row=[222, 50, 245, 231, 140, 40, 98, 162, 230, 210, 171,
                             241, 250, 189, 169, 229],
                        col=[139, 92, 120, 87, 27, 6, 224, 234, 96, 84, 79, 234,
                             201, 197, 115, 145]),
}
C1_SPATIAL = [173, 115, 122, 124, 119, 130, 113, 129]


def thr(preset, salt):
    return np.array([[preset[m] ^ ((k * SK + m * SM + salt) & 255) for m in range(M)]
                     for k in range(K)])


def code_table(th, kind, choice, rng, c1=None):
    """codes[k][level]; level = |digit|.  r4: 3 levels lighting 0/8/16 bits,
    r16: 9 levels lighting 0,2,..,16 bits.  choice: lo / hi / rand inside the
    valid interval; c1: explicit |d|=1 codes for the r4 side (spatial wiring)."""
    nlev, step = (3, 8) if kind == "r4" else (9, 2)
    tab = np.zeros((K, nlev), dtype=np.int64)
    for k in range(K):
        lit = np.array([(th[k] < c).sum() for c in range(256)])
        for lvl in range(nlev):
            valid = np.nonzero(lit == step * lvl)[0]
            assert len(valid), f"level {lvl} unreachable on lane {k}"
            if lvl == 0:
                tab[k, lvl] = 0
            elif lvl == nlev - 1:
                tab[k, lvl] = 255
            elif kind == "r4" and c1 is not None:
                assert c1[k] in valid
                tab[k, lvl] = c1[k]
            elif choice == "lo":
                tab[k, lvl] = valid[0]
            elif choice == "hi":
                tab[k, lvl] = valid[-1]
            else:
                tab[k, lvl] = rng.choice(valid)
        assert lit[tab[k, 0]] == 0 and lit[tab[k, -1]] == 16
    return tab


def raw_sign_bits(vals, nbits, rbits):
    """Top bit of each Booth window (the designs' 'sign = raw bit' wiring)."""
    u = np.asarray(vals, dtype=np.int64) & ((1 << nbits) - 1)
    nd = nbits // rbits
    return np.stack([(u >> min(d * rbits + rbits - 1, nbits - 1)) & 1
                     for d in range(nd)], -1)


def booth(vals, nbits, rbits):
    """Booth digits (radix 2**rbits) of nbits two's-complement values."""
    u = np.asarray(vals, dtype=np.int64) & ((1 << nbits) - 1)
    nd = nbits // rbits

    def b(i):
        if i < 0:
            return np.zeros_like(u)
        return (u >> min(i, nbits - 1)) & 1
    out = []
    for d in range(nd):
        lo = d * rbits
        v = b(lo - 1) - (1 << (rbits - 1)) * b(lo + rbits - 1)
        for t in range(rbits - 1):
            v = v + (1 << t) * b(lo + t)
        out.append(v)
    return np.stack(out, -1)


# ---------------------------------------------------------------- cases --
def mk(name, **kw):
    base = dict(name=name, grid=(1, 1), top=True, prec="int8", orient="r4rows",
                preset="spatial", L=64, blocks=2, data="random", choice="rand",
                seed=1, expect="pass", mac_in_drain=False, hold_padding=False,
                bad_code=False, raw_sign=None, pad_sign_noise=False)
    base.update(kw)
    if base["grid"] != (1, 1):
        base["top"] = False
    if base["raw_sign"] is None:
        # spatial design: sign = raw top bit of the digit window (zero digits
        # from 111 / 11111 then carry sign 1); red team: sign = (digit < 0)
        base["raw_sign"] = base["preset"] == "spatial"
    return base


CASES = {c["name"]: c for c in [
    # single PE through the real top (forced Sobol buses)
    mk("top_int8_rand", L=64, blocks=2, seed=11),
    mk("top_int8_extremes", L=256, blocks=2, data="extremes", seed=12),
    mk("top_int8_allmin", L=1024, blocks=1, data="all_min"),
    mk("top_int8_minmax", L=1024, blocks=1, data="min_x_max"),
    mk("top_int8_allmax", L=512, blocks=1, data="all_max"),
    mk("top_int8_alt", L=512, blocks=2, data="alternating"),
    mk("top_int8_macdrain", L=128, blocks=3, mac_in_drain=True, seed=13),
    mk("top_int8_C1wiring_lo", L=128, blocks=2, choice="lo", seed=14),
    mk("top_w4a8_rand", prec="w4a8", L=64, blocks=2, seed=15),
    mk("top_w4a8_extremes", prec="w4a8", L=128, blocks=1, data="extremes", seed=16),
    mk("top_int4_rand", prec="int4", L=64, blocks=2, seed=17),
    mk("top_int4_extremes", prec="int4", L=128, blocks=1, data="extremes", seed=18),
    mk("top_red_r4_int8", preset="red_r4rows", L=128, blocks=2, choice="hi", seed=19),
    mk("top_red_r16_int8", preset="red_r16rows", orient="r16rows", L=256, blocks=2,
       seed=20),
    mk("top_red_r16_int8_ext", preset="red_r16rows", orient="r16rows", L=256,
       blocks=1, data="extremes", seed=21),
    # grids built from the real peripheral + PE modules
    mk("grid2x2_int8_rand", grid=(2, 2), L=64, blocks=2, seed=31),
    mk("grid2x3_int8_red", grid=(2, 3), preset="red_r4rows", L=64, blocks=2, seed=32),
    mk("grid3x2_int8_ext", grid=(3, 2), L=64, blocks=2, data="extremes", seed=33),
    mk("grid2x2_w4a8", grid=(2, 2), prec="w4a8", L=64, blocks=2, seed=34),
    mk("grid2x2_int4", grid=(2, 2), prec="int4", L=64, blocks=2, seed=35),
    mk("grid2x2_r16", grid=(2, 2), preset="red_r16rows", orient="r16rows", L=64,
       blocks=2, seed=36),
    mk("grid4x4_int8", grid=(4, 4), L=64, blocks=2, seed=37),
    mk("grid2x2_macdrain", grid=(2, 2), L=64, blocks=2, mac_in_drain=True, seed=38),
    # skew padding with code 0 but random digit signs (claim: exactly 0)
    mk("grid2x3_padsign", grid=(2, 3), L=64, blocks=2, pad_sign_noise=True, seed=39),
    mk("grid2x2_padsign_red", grid=(2, 2), preset="red_r4rows", L=64, blocks=2,
       pad_sign_noise=True, seed=40),
    # spatial wiring with sign = (digit<0) instead of raw bit, for contrast
    mk("top_int8_signlt0", L=128, blocks=2, raw_sign=False, data="extremes", seed=43),
    # OWIDTH boundary: 16*L = 2^23 - 128 (exact) and 2^23 (wraps)
    mk("top_ovf_L524280", L=524280, blocks=1, data="all_min"),
    mk("top_ovf_L524288", L=524288, blocks=1, data="all_min", expect="fail"),
    # negative controls (the flow must detect these)
    mk("neg_bad_code", L=64, blocks=1, bad_code=True, expect="fail", seed=41),
    mk("neg_hold_padding_2x2", grid=(2, 2), L=64, blocks=2, hold_padding=True,
       expect="fail", seed=42),
]}


def geometry(case):
    prec, orient = case["prec"], case["orient"]
    abits, wbits = {"int8": (8, 8), "w4a8": (8, 4), "int4": (4, 4)}[prec]
    rk, ck = ("r4", "r16") if orient == "r4rows" else ("r16", "r4")
    rb = {"r4": 2, "r16": 4}
    NP, NQ = abits // rb[rk], wbits // rb[ck]
    return dict(abits=abits, wbits=wbits, rk=rk, ck=ck, NP=NP, NQ=NQ,
                NI=NH // NP, NJ=NW // NQ, RA=1 << rb[rk], RW=1 << rb[ck],
                rbr=rb[rk], rbc=rb[ck])


def make_data(case, g, rng):
    PR, PC = case["grid"]
    rows, cols, L = PR * g["NI"], PC * g["NJ"], case["L"]
    lo_a, hi_a = -(1 << (g["abits"] - 1)), (1 << (g["abits"] - 1)) - 1
    lo_w, hi_w = -(1 << (g["wbits"] - 1)), (1 << (g["wbits"] - 1)) - 1
    blocks = []
    for b in range(case["blocks"]):
        kind = case["data"]
        if kind == "random":
            A = rng.integers(lo_a, hi_a + 1, (rows, L))
            W = rng.integers(lo_w, hi_w + 1, (L, cols))
        elif kind == "extremes":
            A = rng.choice([lo_a, lo_a + 1, -1, 0, 1, hi_a], (rows, L))
            W = rng.choice([lo_w, lo_w + 1, -1, 0, 1, hi_w], (L, cols))
        elif kind == "all_min":
            A, W = np.full((rows, L), lo_a), np.full((L, cols), lo_w)
        elif kind == "all_max":
            A, W = np.full((rows, L), hi_a), np.full((L, cols), hi_w)
        elif kind == "min_x_max":
            A, W = np.full((rows, L), lo_a), np.full((L, cols), hi_w)
        elif kind == "alternating":
            A = np.where((np.arange(L) + np.arange(rows)[:, None]) % 2 == 0, lo_a, hi_a)
            W = np.where((np.arange(L)[:, None] + np.arange(cols)) % 3 == 0, lo_w, hi_w)
        else:
            raise ValueError(kind)
        blocks.append((A.astype(np.int64), W.astype(np.int64)))
    return blocks


def side_slices(X, nbits, rbits, n_vec_per_edge, n_edges, codes, raw_sign=False):
    """X [n_edges*n_vec, L] -> per slice s, edge e: (code [8,K], sign [8,K]).
    Tile line index = ND*vec + digit."""
    dig = booth(X, nbits, rbits)                      # [rows, L, ND]
    ND = dig.shape[-1]
    assert ND * n_vec_per_edge == 8
    L = X.shape[1]
    S = L // K

    def lay(x):
        x = x.reshape(n_edges, n_vec_per_edge, S, K, ND).transpose(2, 0, 1, 4, 3)
        return x.reshape(S, n_edges, 8, K)            # line = ND*vec + digit
    d = lay(dig)
    mag = np.abs(d)
    if raw_sign:
        sgn = lay(raw_sign_bits(X, nbits, rbits))
        assert np.all(sgn[d < 0] == 1) and np.all(sgn[d > 0] == 0)
    else:
        sgn = (d < 0).astype(np.int64)
    code = codes[np.arange(K)[None, None, None, :], mag]
    return code, sgn


def pack(code, sgn):
    """[8,K] codes/signs -> (512-bit int, 64-bit int) with RTL bit order."""
    v = 0
    s = 0
    for h in range(8):
        for k in range(K):
            v |= int(code[h, k]) << ((h * K + k) * 8)
            s |= int(sgn[h, k]) << (h * K + k)
    return v, s


def gen(case_name, outdir):
    case = CASES[case_name]
    rng = np.random.default_rng(case["seed"])
    g = geometry(case)
    PR, PC = case["grid"]
    ps = PRESETS[case["preset"]]
    th_r, th_c = thr(ps["row"], SALT_A), thr(ps["col"], SALT_W)
    c1 = C1_SPATIAL if (case["preset"] == "spatial" and g["rk"] == "r4") else None
    codes_r = code_table(th_r, g["rk"], case["choice"], rng, c1)
    codes_c = code_table(th_c, g["ck"], case["choice"], rng)
    if case["bad_code"]:
        codes_c = codes_c.copy()
        codes_c[3, 5] = codes_c[3, 4]          # lane 3, |dw|=5 lights 8 not 10
    blocks = make_data(case, g, rng)
    L = case["L"]
    S = L // K
    span = S + PR + PC - 2
    period = span + 8 * PC
    F0 = 2
    starts = [F0 + b * period for b in range(len(blocks))]
    sl = []
    for A, W in blocks:
        ac, asg = side_slices(A, g["abits"], g["rbr"], g["NI"], PR, codes_r,
                              case["raw_sign"])
        wc, wsg = side_slices(W.T, g["wbits"], g["rbc"], g["NJ"], PC, codes_c,
                              case["raw_sign"])
        sl.append((ac, asg, wc, wsg))
    n_lines = starts[-1] + 2 + period + 8 * PC + 3
    zero = (0, 0)
    pack_cache = {}

    def pk(arrs, key):
        if key not in pack_cache:
            pack_cache[key] = pack(*arrs)
        return pack_cache[key]

    lines = []
    last_a = [zero] * PR
    last_w = [zero] * PC
    drain_map = {}
    for t in range(n_lines):
        a_f = [None] * PR
        w_f = [None] * PC
        mac, sh = 0, 0
        for b, F in enumerate(starts):
            ac, asg, wc, wsg = sl[b]
            for r in range(PR):
                s = t - F - r
                if 0 <= s < S:
                    a_f[r] = pk((ac[s, r], asg[s, r]), ("a", b, s, r)) \
                        if case["data"] not in ("all_min",) else pk((ac[0, r], asg[0, r]), ("a", b, 0, r))
            for c in range(PC):
                s = t - F - c
                if 0 <= s < S:
                    w_f[c] = pk((wc[s, c], wsg[s, c]), ("w", b, s, c)) \
                        if case["data"] not in ("all_min",) else pk((wc[0, c], wsg[0, c]), ("w", b, 0, c))
            if F + 2 <= t < F + 2 + span:
                mac = 1
            if F + 2 + span <= t < F + 2 + period:
                sh = 1
                drain_map[t] = (b, t - (F + 2 + span))
                if case["mac_in_drain"]:
                    mac = 1
        if starts[-1] + 2 + period <= t < starts[-1] + 2 + period + 8 * PC:
            sh = 1                                     # extra drain: must read 0
            drain_map[t] = (-1, t - (starts[-1] + 2 + period))
            if case["mac_in_drain"]:
                mac = 1
        noise = (0, int(rng.integers(0, 1 << 63)) | (1 << 63)) if case["pad_sign_noise"] else zero
        for r in range(PR):
            if a_f[r] is None:
                a_f[r] = last_a[r] if case["hold_padding"] else noise
            last_a[r] = a_f[r]
        for c in range(PC):
            if w_f[c] is None:
                w_f[c] = last_w[c] if case["hold_padding"] else noise
            last_w[c] = w_f[c]
        fields = [str(mac), str(sh), "1", "1"]
        for r in range(PR):
            fields += [f"{a_f[r][0]:0128x}", f"{a_f[r][1]:016x}"]
        for c in range(PC):
            fields += [f"{w_f[c][0]:0128x}", f"{w_f[c][1]:016x}"]
        body = " ".join(fields)
        if lines and lines[-1][1] == body:
            lines[-1][0] += 1
        else:
            lines.append([1, body])
    a_bus = sum(v << (8 * m) for m, v in enumerate(ps["row"]))
    w_bus = sum(v << (8 * m) for m, v in enumerate(ps["col"]))
    with open(f"{outdir}/stim.txt", "w") as f:
        f.write(f"{a_bus:032x} {w_bus:032x}\n")
        for rep, body in lines:
            f.write(f"{rep} {body}\n")
    meta = dict(case=case, starts=starts, span=span, period=period, S=S,
                drain_map={str(k): v for k, v in drain_map.items()},
                codes_r=codes_r.tolist(), codes_c=codes_c.tolist())
    with open(f"{outdir}/meta.json", "w") as f:
        json.dump(meta, f)
    np.savez(f"{outdir}/blocks.npz", *[x for A, W in blocks for x in (A, W)])
    print(f"gen {case_name}: {n_lines} cycles in {len(lines)} stimulus lines, "
          f"S={S} span={span} period={period}")


def check(case_name, outdir):
    case = CASES[case_name]
    meta = json.load(open(f"{outdir}/meta.json"))
    g = geometry(case)
    PR, PC = case["grid"]
    z = np.load(f"{outdir}/blocks.npz")
    arrs = [z[f"arr_{i}"] for i in range(len(z.files))]
    blocks = [(arrs[2 * b], arrs[2 * b + 1]) for b in range(len(arrs) // 2)]
    drain_map = {int(k): tuple(v) for k, v in meta["drain_map"].items()}
    T = [np.full((PR, NH, PC, NW), np.iinfo(np.int64).min, dtype=np.int64)
         for _ in blocks]
    extra_nonzero = 0
    xs = None
    n_samples = 0
    for ln in open(f"{outdir}/out.txt"):
        p = ln.split()
        if p[0] == "END":
            xs = int(p[2].split("=")[1])
            continue
        cyc, r, h, val = int(p[1]), int(p[2]), int(p[3]), int(p[4])
        n_samples += 1
        b, d = drain_map[cyc]
        gcol = 8 * PC - 1 - d
        c, v = divmod(gcol, 8)
        if b < 0:
            extra_nonzero += val != 0
        else:
            T[b][r, h, c, v] = val
    assert xs is not None, "simulation did not finish (no END line)"
    mism = 0
    tile_mism = 0
    detail = []
    for b, (A, W) in enumerate(blocks):
        assert (T[b] != np.iinfo(np.int64).min).all(), "missing drain samples"
        ref = A @ W
        Y = np.zeros_like(ref)
        for r in range(PR):
            for i in range(g["NI"]):
                for c in range(PC):
                    for j in range(g["NJ"]):
                        acc = 0
                        for p in range(g["NP"]):
                            for q in range(g["NQ"]):
                                acc += (g["RA"] ** p) * (g["RW"] ** q) * \
                                    int(T[b][r, g["NP"] * i + p, c, g["NQ"] * j + q])
                        Y[r * g["NI"] + i, c * g["NJ"] + j] = acc
        # per-tile exact digit-product sums (localises any mismatch)
        da = booth(A, g["abits"], g["rbr"])        # [rows, L, NP]
        dw = booth(W.T, g["wbits"], g["rbc"])      # [cols, L, NQ]
        for r in range(PR):
            for i in range(g["NI"]):
                for c in range(PC):
                    for j in range(g["NJ"]):
                        ra, cb = r * g["NI"] + i, c * g["NJ"] + j
                        for p in range(g["NP"]):
                            for q in range(g["NQ"]):
                                exact = int((da[ra, :, p] * dw[cb, :, q]).sum())
                                got = int(T[b][r, g["NP"] * i + p, c, g["NQ"] * j + q])
                                if exact != got:
                                    tile_mism += 1
                                    if len(detail) < 3:
                                        detail.append((b, r, i, c, j, p, q, exact, got))
        bad = int((Y != ref).sum())
        mism += bad
        if bad and len(detail) < 6:
            idx = np.argwhere(Y != ref)[0]
            detail.append(("out", b, tuple(idx), int(Y[tuple(idx)]), int(ref[tuple(idx)])))
    passed = mism == 0 and tile_mism == 0 and extra_nonzero == 0 and xs == 0
    verdict = "PASS" if passed == (case["expect"] == "pass") else "UNEXPECTED"
    print(f"{verdict:10s} {case_name:24s} expect={case['expect']:4s} grid={PR}x{PC} "
          f"{case['prec']} {case['orient']} preset={case['preset']} L={case['L']} "
          f"blocks={len(blocks)}: output mismatches={mism}, tile mismatches="
          f"{tile_mism}, nonzero after drain={extra_nonzero}, X samples={xs}, "
          f"samples={n_samples}" + (f" e.g. {detail[:3]}" if detail else ""))
    return verdict == "PASS"


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "list":
        print(" ".join(CASES))
    elif cmd == "gen":
        gen(sys.argv[2], sys.argv[3])
    elif cmd == "check":
        sys.exit(0 if check(sys.argv[2], sys.argv[3]) else 1)
