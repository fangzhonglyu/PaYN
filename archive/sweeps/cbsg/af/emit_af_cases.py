#!/usr/bin/env python3
"""Extra golden cases for the AF RTL bench (designs/payn/tb/test_payn_array_cbsg_af.sv).

Same .mem format and the same gate as `cbsg_ref.py --emit`: every case is written only after kernel == RG == AF
at every block and drain (cbsg_ref.emit_case), and is then re-derived from its .mem files alone
(cbsg_ref.check_golden).  cbsg_ref.py is imported by path and not modified; the extra cases are registered
at run time (CASES / build_case of the imported module).

Every case is one 8 x 8 PE (8 A rows, 8 W columns) made of calls run back to back with no reset:
  af_uL_*            every uniform L in 1..128, one plain call per L, D = 16 + (37 L mod 61)
  af_ladders_*       all trace ladders (cbsg_ref.trace_ladders), one plain per-row-L call per ladder
  af_lad_chunk_*     all trace ladders as chunk_d=128 rung tables, D = 128 + tail
  af_chunk_{128,96,100}  chunked, uniform L over 12 values, tails 1..81 (padded blocks), 2 full chunks
  af_chunk_rung_{96,100} chunked rung tables at chunk_d 96 / 100 (phase reset per chunk matters)
  af_perhead         per-head calls: 3 x D64 L64, 3 x D72 L50 (unaligned heads), 2 x D128 L97, 2 x D40 L1
  af_calls_mixed     protected-first split, plain D257, chunked rungs, per-head, small gathered call, chunk_d 96
  af_calls_odd       deployed odd block counts: chunk_d 128 at D 721 / 584 / 3973, plain 257, gathered 77
  af_av2048          one attention call at D=2048 (256 blocks), per-row L
  af_extreme_max     all b = 128 at L = 128, D = 2048, row/column signs: every accumulator is +-262,144
  af_extreme_mix     magnitudes 0/1/63/64/65/127/128 only, per-row L incl. 1, 2, 15..17, 31, 33
  af_extreme_zero    mostly b = 0 with sign bit 1 (negative zero), a few 128s; L = 1 and L = 16 calls
Declared mask-fault catches are computed per case (every MASK_FAULTS entry that leaves accumulators wrong).

  PYTHONDONTWRITEBYTECODE=1 python3 sweeps/cbsg/af/emit_af_cases.py --out build/cbsg/af/golden_extra [--case NAME,..]
"""
import argparse
import importlib.util
import sys
import time
from pathlib import Path

sys.dont_write_bytecode = True
import numpy as np  # noqa: E402

REPO = Path(__file__).resolve().parents[3]
_spec = importlib.util.spec_from_file_location("cbsg_ref", REPO / "sweeps" / "cbsg" / "cbsg_ref.py")
ref = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ref)

R = C = ref.TILE_R


def _ops(rng, D, mags="mixed"):
    ba, sa = ref.gen_operands(rng, R, D, mags)
    bb, sb = ref.gen_operands(rng, C, D, mags)
    return ba, sa, bb, sb


def plain_call(rng, D, L, mags="mixed", ops=None):
    ba, sa, bb, sb = ops if ops is not None else _ops(rng, D, mags)
    Lr = np.broadcast_to(np.asarray(L, np.int64), (R,)).copy()
    return dict(ba=ba, sa=sa, bb=bb, sb=sb, L=Lr[:, None], slice_len=0, cols=None,
                exp=ref.kernel_acc_plain(ba, sa, bb, sb, Lr)[None])


def chunked_call(rng, D, cd, L=None, ladder=None, mags="mixed", ops=None):
    """chunk_d cd; uniform L or a per-(row, chunk) rung table over `ladder` (every rung used at least once)."""
    ba, sa, bb, sb = ops if ops is not None else _ops(rng, D, mags)
    nch = -(-D // cd)
    if D <= cd:                                     # standard path: one slice, plain
        Lr = np.full(R, L) if ladder is None else ref._ladder_rows(rng, ladder, R)
        return dict(ba=ba, sa=sa, bb=bb, sb=sb, L=Lr[:, None], slice_len=cd, cols=None,
                    exp=ref.kernel_acc_plain(ba, sa, bb, sb, Lr)[None])
    if ladder is None:
        return dict(ba=ba, sa=sa, bb=bb, sb=sb, L=np.full((R, nch), L), slice_len=cd, cols=None,
                    exp=ref.kernel_acc_chunked(ba, sa, bb, sb, cd, stoc_len=L))
    lad = list(ladder)
    rung = rng.integers(0, len(lad), size=(R, nch))
    k = min(len(lad), rung.size)
    rung.reshape(-1)[:k] = np.arange(k)
    rng.shuffle(rung.reshape(-1))
    return dict(ba=ba, sa=sa, bb=bb, sb=sb, L=np.asarray(lad)[rung], slice_len=cd, cols=None,
                exp=ref.kernel_acc_chunked(ba, sa, bb, sb, cd, stoc_len=ref.L_MAX, rung_table=rung, level_lens=lad))


def perhead_call(rng, BH, D, L, mags="mixed"):
    hs = [_ops(rng, D, mags) for _ in range(BH)]
    ba, sa, bb, sb = (np.stack([h[i] for h in hs]) for i in range(4))
    exp = ref.kernel_acc_batched(ba, sa, bb, sb, L)
    cat = lambda x: np.concatenate(list(x), axis=1)
    return dict(ba=cat(ba), sa=cat(sa), bb=cat(bb), sb=cat(sb), L=np.full((R, BH), L), slice_len=D, cols=None, exp=exp)


def prot_calls(rng, D, n_prot, prot_L, cd, ladder, protected_first):
    ba, sa, bb, sb = _ops(rng, D)
    prot = np.sort(rng.choice(D, size=n_prot, replace=False))
    rest = np.setdiff1d(np.arange(D), prot)
    out = []
    for cols, is_prot in ((prot, True), (rest, False)) if protected_first else ((rest, False), (prot, True)):
        g = (ba[:, cols], sa[:, cols], bb[:, cols], sb[:, cols])
        c = chunked_call(rng, len(cols), cd, L=prot_L if is_prot else None, ladder=None if is_prot else ladder, ops=g)
        c["cols"] = cols
        out.append(c)
    return out


def signed_ops(D, b_a, b_w, sa_bit, sb_bit):
    """Explicit operands; sign bits 1 = negative (b = 0 with sign bit 1 is a legal negative zero)."""
    sgn = lambda bits: np.where(np.asarray(bits) != 0, -1, 1).astype(np.int8)
    return (np.asarray(b_a, np.int16), sgn(sa_bit), np.asarray(b_w, np.int16), sgn(sb_bit))


# ----------------------------------------------------------------------------------------------- cases --

def _uL(lo, hi):
    def build(rng):
        return [plain_call(rng, 16 + (37 * L) % 61, L) for L in range(lo, hi + 1)]
    return build


def _ladder_list():
    return [lad for _, lad in sorted(ref.trace_ladders().items())]


def _ladder_rows8(rng, lad):
    lad = np.asarray(lad)
    return rng.permutation(lad)[:R] if len(lad) >= R else ref._ladder_rows(rng, lad, R)


def _ladders(part, nparts):
    def build(rng):
        lads = _ladder_list()
        sel = lads[part::nparts]
        return [plain_call(rng, 24 + (29 * i) % 57, _ladder_rows8(rng, lad)) for i, lad in enumerate(sel)]
    return build


def _lad_chunk(part, nparts):
    def build(rng):
        lads = _ladder_list()[part::nparts]
        tails = [56, 5, 81, 120, 8, 51, 72, 13, 100, 1]
        return [chunked_call(rng, 128 + tails[i % len(tails)], 128, ladder=lad) for i, lad in enumerate(lads)]
    return build


def _chunk(cd):
    def build(rng):
        Ls = [1, 7, 16, 17, 31, 38, 44, 64, 84, 97, 112, 128]
        tails = [1, 5, 8, 13, 56, 81, 3, 72, 9, 40, 0, 17]
        out = []
        for L, t in zip(Ls, tails):
            t = t % cd
            out.append(chunked_call(rng, 2 * cd + t, cd, L=L))
        return out
    return build


def _chunk_rung(cd):
    def build(rng):
        lads = [[128, 96, 64, 48, 44, 42, 38], [97, 64, 48, 32, 25, 18, 128, 84], [128, 112, 96, 64, 48, 44, 42, 38]]
        return [chunked_call(rng, 3 * cd + t, cd, ladder=lad) for lad, t in zip(lads, [cd // 2 + 3, 7, 1])]
    return build


def _perhead(rng):
    return [perhead_call(rng, 3, 64, 64), perhead_call(rng, 3, 72, 50), perhead_call(rng, 2, 128, 97),
            perhead_call(rng, 2, 40, 1)]


def _calls_mixed(rng):
    out = prot_calls(rng, 300, 77, 112, 128, [128, 96, 64, 48, 44, 42, 38], protected_first=True)
    out.append(plain_call(rng, 257, _ladder_rows8(rng, [128, 97, 64, 48, 32])))
    out.append(chunked_call(rng, 300, 128, ladder=[128, 97, 84, 64, 48, 32, 25, 18]))
    out.append(perhead_call(rng, 2, 72, 48))
    out.append(chunked_call(rng, 21, 128, L=95))       # small gathered call: standard path
    out.append(chunked_call(rng, 200, 96, ladder=[128, 96, 64, 48, 32, 24, 16]))
    out.append(plain_call(rng, 61, 33))
    return out


def _calls_odd(rng):
    lad = [128, 97, 84, 64, 48, 32, 25, 18]
    return [chunked_call(rng, 721, 128, ladder=lad), plain_call(rng, 257, _ladder_rows8(rng, lad)),
            chunked_call(rng, 584, 128, L=84), chunked_call(rng, 77, 128, L=68),
            chunked_call(rng, 3973, 128, ladder=lad)]


def _av2048(rng):
    return [plain_call(rng, 2048, _ladder_rows8(rng, [128, 96, 64, 48, 44, 42, 38]))]


def _extreme_max(rng):
    D = 2048
    full = np.full((R, D), 128)
    sa = np.repeat((np.arange(R) % 2)[:, None], D, axis=1)          # odd rows negative
    sb = np.repeat((np.arange(C) // 4)[:, None], D, axis=1)         # columns 4..7 negative
    return [plain_call(rng, D, 128, ops=signed_ops(D, full, full, sa, sb))]


def _extreme_mix(rng):
    vals = np.array([0, 1, 63, 64, 65, 127, 128])
    out = []
    for D, Lr in ((136, [1, 2, 15, 16, 17, 31, 33, 128]), (100, [128, 1, 64, 127, 2, 17, 96, 3])):
        ba, bb = rng.choice(vals, size=(R, D)), rng.choice(vals, size=(C, D))
        ops = signed_ops(D, ba, bb, rng.integers(0, 2, (R, D)), rng.integers(0, 2, (C, D)))
        out.append(plain_call(rng, D, Lr, ops=ops))
    D = 230
    ba, bb = rng.choice(vals, size=(R, D)), rng.choice(vals, size=(C, D))
    ops = signed_ops(D, ba, bb, rng.integers(0, 2, (R, D)), rng.integers(0, 2, (C, D)))
    out.append(chunked_call(rng, D, 100, ladder=[128, 1, 2, 16, 17, 64], ops=ops))
    return out


def _extreme_zero(rng):
    out = []
    for D, L in ((64, 1), (72, 16), (40, 128)):
        ba = np.where(rng.random((R, D)) < 0.9, 0, 128)
        bb = np.where(rng.random((C, D)) < 0.9, 0, 128)
        ops = signed_ops(D, ba, bb, np.ones((R, D)), rng.integers(0, 2, (C, D)))
        out.append(plain_call(rng, D, L, ops=ops))
    return out


EXTRA = {
    "af_uL_001_032": (_uL(1, 32), "every uniform L 1..32, one plain call each, back to back"),
    "af_uL_033_064": (_uL(33, 64), "every uniform L 33..64, one plain call each, back to back"),
    "af_uL_065_096": (_uL(65, 96), "every uniform L 65..96, one plain call each, back to back"),
    "af_uL_097_128": (_uL(97, 128), "every uniform L 97..128, one plain call each, back to back"),
    **{f"af_ladders_{i}": (_ladders(i, 4), f"trace ladders part {i}/4: plain per-row-L calls") for i in range(4)},
    **{f"af_lad_chunk_{i}": (_lad_chunk(i, 4), f"trace ladders part {i}/4 as chunk_d=128 rung tables") for i in range(4)},
    **{f"af_chunk_{cd}": (_chunk(cd), f"chunk_d={cd}, uniform L over 12 values, tails 0..81") for cd in (128, 96, 100)},
    **{f"af_chunk_rung_{cd}": (_chunk_rung(cd), f"chunk_d={cd} rung tables") for cd in (96, 100)},
    "af_perhead": (_perhead, "per-head calls: 3xD64 L64, 3xD72 L50, 2xD128 L97, 2xD40 L1"),
    "af_calls_mixed": (_calls_mixed, "protected-first split, plain 257, chunked rungs, per-head 72, gathered 21, chunk_d 96, plain 61"),
    "af_calls_odd": (_calls_odd, "deployed odd block counts: chunk_d 128 at 721 / 584 / 3973, plain 257, gathered 77"),
    "af_av2048": (_av2048, "one attention call, D=2048 (256 blocks), per-row L"),
    "af_extreme_max": (_extreme_max, "all b=128, L=128, D=2048, row/column signs: accumulators +-262144"),
    "af_extreme_mix": (_extreme_mix, "magnitudes 0/1/63/64/65/127/128, per-row L incl. 1, 2, 15..17, 31, 33"),
    "af_extreme_zero": (_extreme_zero, "mostly b=0 with sign bit 1 (negative zero), a few 128s; L 1 / 16 / 128"),
}

_orig_build_case = ref.build_case


def build_case(name, seed=1):
    if name not in EXTRA:
        return _orig_build_case(name, seed)
    rng = np.random.default_rng(seed + sum(map(ord, name)))
    calls = EXTRA[name][0](rng)
    spec = ref.CASES[name]
    spec["catches"] = [f for f in ref.MASK_FAULTS if min(ref._fault_wrong(calls, f)) > 0]
    return spec, calls


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default=str(REPO / "build" / "cbsg" / "af" / "golden_extra"))
    ap.add_argument("--case", default="all")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--list", action="store_true")
    args = ap.parse_args()
    if args.list:
        for k, (_, doc) in EXTRA.items():
            print(f"{k:18s} {doc}")
        return 0
    for k, (_, doc) in EXTRA.items():
        ref.CASES[k] = dict(path="af_extra", doc=doc)
    ref.build_case = build_case
    names = list(EXTRA) if args.case == "all" else args.case.split(",")
    rc = 0
    for n in names:
        t0 = time.time()
        out, nb, nd, nc, caught = ref.emit_case(args.out, n, args.seed)
        bad, nb2, nd2, nc2, sens = ref.check_golden(out)
        cs = ", ".join(f"{f} {a}/{b}" for f, (a, b) in caught.items()) or "none"
        print(f"[{'PASS' if bad == 0 else 'FAIL'}] {n}: {nb} blocks, {nd} drains, {nc} calls; kernel == RG == AF; "
              f"re-derived from .mem; mask faults caught (RG/AF wrong): {cs}; {time.time() - t0:.1f} s", flush=True)
        rc |= int(bad != 0)
    return rc


if __name__ == "__main__":
    sys.exit(main())
