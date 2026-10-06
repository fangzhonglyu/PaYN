#!/usr/bin/env python3
"""Golden SC cases for the payn_array benches: build them, write them as .mem files, re-check them from the files.

A case is one PE (8 A rows x 8 W columns) running one or more calls back to back with no reset in between.  It is
written only after the A-first emulation (cbsg.hw_calls_acc) equals the kernel reference at every drain, and is
then re-derived from its .mem files alone (check_golden), so a layout error in the writer cannot hide.  The file
format is in README.md.  Three case sets:

  base    the 12 shipped cases: plain, chunked (tails, rungs, chunk_d 96 / 100), per-head, the protected split and
          consecutive attention calls.  Their mask-fault catches are declared and must hold.
  extra   24 cases: every uniform L, every trace ladder (plain and as chunk_d 128 rung tables), chunked tails and
          rungs, per-head, mixed and odd-block call chains, D = 2048, extreme magnitudes.
  review  7 adversarial cases: chunk_d 8 / 16 / unaligned, one-cycle blocks, 60 tiny calls, long mixed chains.
Extra and review cases record every mask fault (cbsg.MASK_FAULTS) that leaves accumulators wrong.

  python3 designs/payn/model/sc_cases.py emit --set base|extra|review --out DIR [--shape k16m8] [--case A,B] [--seed N]
  python3 designs/payn/model/sc_cases.py check-golden DIR [DIR ...]      # case dirs, or dirs holding case dirs
  python3 designs/payn/model/sc_cases.py list [--set base|extra|review]
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

sys.dont_write_bytecode = True
import numpy as np  # noqa: E402

from cbsg import (L_MAX, MASK_FAULTS, SHAPES, TILE_R, TRACE_LADDERS, af_block, gen_operands, geometry,  # noqa: E402
                  hw_calls_acc, kernel_acc_batched, kernel_acc_chunked, kernel_acc_plain, ladder_rows)

R = C = TILE_R


# ==================================================================================================================
# Case builders.  Each returns (spec, calls); a call is dict(ba, sa, bb, sb (8, D), L (8, n_slices), slice_len,
# cols (original input channel of each column of a gathered call, or None), exp (n_slices, 8, 8) kernel
# accumulators, one per drain).  The random draws are part of the case: their order must not change.
# ==================================================================================================================

def _ops(rng, D, mags="mixed"):
    return (*gen_operands(rng, R, D, mags), *gen_operands(rng, C, D, mags))


def plain_call(rng, D, L, mags="mixed", ops=None):
    ba, sa, bb, sb = ops if ops is not None else _ops(rng, D, mags)
    Lr = np.broadcast_to(np.asarray(L, np.int64), (R,)).copy()
    return dict(ba=ba, sa=sa, bb=bb, sb=sb, L=Lr[:, None], slice_len=0, cols=None,
                exp=kernel_acc_plain(ba, sa, bb, sb, Lr)[None])


def chunked_call(rng, D, cd, L=None, ladder=None, mags="mixed", ops=None):
    """chunk_d cd; uniform L, or a per-(row, chunk) rung table over `ladder` with every rung used at least once."""
    ba, sa, bb, sb = ops if ops is not None else _ops(rng, D, mags)
    nch = -(-D // cd)
    if D <= cd:                                     # standard path: one slice, plain
        Lr = np.full(R, L) if ladder is None else ladder_rows(rng, ladder, R)
        return dict(ba=ba, sa=sa, bb=bb, sb=sb, L=Lr[:, None], slice_len=cd, cols=None,
                    exp=kernel_acc_plain(ba, sa, bb, sb, Lr)[None])
    if ladder is None:
        return dict(ba=ba, sa=sa, bb=bb, sb=sb, L=np.full((R, nch), L), slice_len=cd, cols=None,
                    exp=kernel_acc_chunked(ba, sa, bb, sb, cd, stoc_len=L))
    lad = list(ladder)
    rung = rng.integers(0, len(lad), size=(R, nch))
    k = min(len(lad), rung.size)
    rung.reshape(-1)[:k] = np.arange(k)
    rng.shuffle(rung.reshape(-1))
    return dict(ba=ba, sa=sa, bb=bb, sb=sb, L=np.asarray(lad)[rung], slice_len=cd, cols=None,
                exp=kernel_acc_chunked(ba, sa, bb, sb, cd, stoc_len=L_MAX, rung_table=rung, level_lens=lad))


def perhead_call(rng, BH, D, L, mags="mixed"):
    """BH heads as one call, concatenated along D, one slice (and drain) per head."""
    hs = [_ops(rng, D, mags) for _ in range(BH)]
    ba, sa, bb, sb = (np.stack([h[i] for h in hs]) for i in range(4))
    cat = lambda x: np.concatenate(list(x), axis=1)   # noqa: E731
    return dict(ba=cat(ba), sa=cat(sa), bb=cat(bb), sb=cat(sb), L=np.full((R, BH), L), slice_len=D, cols=None,
                exp=kernel_acc_batched(ba, sa, bb, sb, L))


def prot_calls(rng, D, n_prot, prot_L, cd, ladder, protected_first):
    """The protected split of one linear: the protected channels gathered into a call at prot_L, the rest into a
    rung-table call, in the given order."""
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


def signed_ops(b_a, b_w, sa_bit, sb_bit):
    """Explicit operands; sign bit 1 = negative (b = 0 with sign bit 1 is a legal negative zero)."""
    sgn = lambda bits: np.where(np.asarray(bits) != 0, -1, 1).astype(np.int8)   # noqa: E731
    return np.asarray(b_a, np.int16), sgn(sa_bit), np.asarray(b_w, np.int16), sgn(sb_bit)


def _ladder_rows8(rng, lad):
    lad = np.asarray(lad)
    return rng.permutation(lad)[:R] if len(lad) >= R else ladder_rows(rng, lad, R)


# ----------------------------------------------------------------------------------------------------- base --

_SLICE_FAULTS = ("call_d", "no_slice_reset", "global_mask", "no_phase_reset")   # all bite on slices not 64-aligned
_LAD_4B = [128, 97, 84, 64, 48, 32, 25, 18]                                      # 4B target32 levels + escape + protected

BASE_CASES = {
    "plain_u128":    dict(path="plain", D=64, L=128, doc="plain, uniform L=128, 8 blocks (all 8 phases)"),
    "plain_u97":     dict(path="plain", D=136, L=97, doc="plain, uniform L=97, 17 blocks (phase wraps)"),
    "plain_ladder":  dict(path="plain", D=133, ladder=[128, 96, 64, 48, 44, 42, 38],
                          doc="plain per-row L (14B target48 ladder), D=133: last block has 5 lanes"),
    "plain_extreme": dict(path="plain", D=72, Lrows=[128, 1, 2, 16, 17, 97, 64, 127], mags="extreme",
                          doc="magnitudes only 0/1/127/128, per-row L incl. 1 and 17"),
    "chunked_rung":  dict(path="chunked", D=312, chunk_d=128, ladder=_LAD_4B,
                          doc="chunk_d=128, D=312 (2 full + 56-column tail), per-(row, chunk) rungs "
                              "(4B target32 + esc + prot)"),
    "chunked_tail5": dict(path="chunked", D=261, chunk_d=128, ladder=_LAD_4B,
                          doc="chunk_d=128, D=261 (2 full + 5-column tail, like trace d_in 3973 = 31x128 + 5): "
                              "padded last block at the deployed chunk_d, per-(row, chunk) rungs"),
    "chunked_96":    dict(path="chunked", D=200, chunk_d=96, ladder=[128, 96, 64, 48, 32, 24, 16], catches=_SLICE_FAULTS,
                          doc="chunk_d=96 (not a multiple of 64), D=200 (tail of 8), per-(row, chunk) rungs"),
    "chunked_100":   dict(path="chunked", D=230, chunk_d=100, L=64, catches=_SLICE_FAULTS,
                          doc="chunk_d=100 (not a multiple of 8): every chunk ends in a padded block"),
    "perhead_64":    dict(path="perhead", BH=2, D=64, L=48, doc="per-head, 2 heads x D=64, L=48: one drain per head"),
    "perhead_128":   dict(path="perhead", BH=2, D=128, L=128, doc="per-head, 2 heads x D=128 (mask repeats at d+64)"),
    "calls_prot":    dict(path="calls_prot", D=600, n_prot=139, prot_L=84, chunk_d=128, ladder=_LAD_4B,
                          catches=("global_mask", "no_phase_reset", "orig_channel_d"),
                          doc="2 calls, no reset between: unprotected 461 gathered channels (3x128 + 77 = 58 blocks, so a "
                              "free-running phase enters the next call at 2) with rungs, then protected 139 scattered "
                              "channels (128 + 11) at L=84"),
    "calls_av257":   dict(path="calls_av", D=257, n_calls=2, ladder=[128, 97, 64, 48, 32],
                          catches=("global_mask", "no_phase_reset"),
                          doc="2 consecutive attention calls at D=257 (ViT av: 33 blocks each), per-row L, "
                              "no reset between"),
}


def build_base(name, rng):
    spec = dict(BASE_CASES[name])
    mags = spec.get("mags", "mixed")
    if spec["path"] == "perhead":                   # one call; heads concatenated along D, one slice per head
        BH, D = spec["BH"], spec["D"]
        ops = [gen_operands(rng, R, D, mags) for _ in range(BH)]
        opw = [gen_operands(rng, C, D, mags) for _ in range(BH)]
        ba, sa = (np.stack([o[i] for o in ops]) for i in (0, 1))
        bb, sb = (np.stack([o[i] for o in opw]) for i in (0, 1))
        cat = lambda x: np.concatenate(list(x), axis=1)   # noqa: E731
        return spec, [dict(ba=cat(ba), sa=cat(sa), bb=cat(bb), sb=cat(sb), L=np.full((R, BH), spec["L"]),
                           slice_len=D, cols=None, exp=kernel_acc_batched(ba, sa, bb, sb, spec["L"]))]
    if spec["path"] == "calls_av":                  # consecutive plain (attention) calls
        calls = []
        for _ in range(spec["n_calls"]):
            ba, sa = gen_operands(rng, R, spec["D"], mags)
            bb, sb = gen_operands(rng, C, spec["D"], mags)
            L = ladder_rows(rng, spec["ladder"], R)
            calls.append(dict(ba=ba, sa=sa, bb=bb, sb=sb, L=L[:, None], slice_len=0, cols=None,
                              exp=kernel_acc_plain(ba, sa, bb, sb, L)[None]))
        return spec, calls
    D = spec["D"]
    ba, sa = gen_operands(rng, R, D, mags)
    bb, sb = gen_operands(rng, C, D, mags)
    if spec["path"] == "plain":
        if "ladder" in spec:
            L = ladder_rows(rng, spec["ladder"], R)
        else:
            L = np.array(spec["Lrows"]) if "Lrows" in spec else np.full(R, spec["L"])
        return spec, [dict(ba=ba, sa=sa, bb=bb, sb=sb, L=L[:, None], slice_len=0, cols=None,
                           exp=kernel_acc_plain(ba, sa, bb, sb, L)[None])]
    cd = spec["chunk_d"]
    if spec["path"] == "calls_prot":                # unprotected call (rungs), then protected call (one L)
        prot = np.sort(rng.choice(D, size=spec["n_prot"], replace=False))
        rest = np.setdiff1d(np.arange(D), prot)
        lad = spec["ladder"]
        rung = rng.integers(0, len(lad), size=(R, -(-len(rest) // cd)))
        rung.reshape(-1)[: len(lad)] = np.arange(len(lad))
        gather = lambda cols: dict(ba=ba[:, cols], sa=sa[:, cols], bb=bb[:, cols], sb=sb[:, cols],   # noqa: E731
                                   slice_len=cd, cols=cols)
        cu, cp = gather(rest), gather(prot)
        cu.update(L=np.asarray(lad)[rung], exp=kernel_acc_chunked(cu["ba"], cu["sa"], cu["bb"], cu["sb"], cd,
                                                                    stoc_len=L_MAX, rung_table=rung, level_lens=lad))
        Lp = spec["prot_L"]
        cp.update(L=np.full((R, -(-len(prot) // cd)), Lp),
                  exp=kernel_acc_chunked(cp["ba"], cp["sa"], cp["bb"], cp["sb"], cd, stoc_len=Lp))
        return spec, [cu, cp]
    nch = -(-D // cd)
    if "ladder" in spec:
        lad = spec["ladder"]
        rung = rng.integers(0, len(lad), size=(R, nch))
        rung.reshape(-1)[: len(lad)] = np.arange(len(lad))
        exp = kernel_acc_chunked(ba, sa, bb, sb, cd, stoc_len=L_MAX, rung_table=rung, level_lens=lad)
        Lrc = np.asarray(lad)[rung]
    else:
        exp = kernel_acc_chunked(ba, sa, bb, sb, cd, stoc_len=spec["L"])
        Lrc = np.full((R, nch), spec["L"])
    return spec, [dict(ba=ba, sa=sa, bb=bb, sb=sb, L=Lrc, slice_len=cd, cols=None, exp=exp)]


# ---------------------------------------------------------------------------------------------------- extra --

def _uL(lo, hi):
    return lambda rng: [plain_call(rng, 16 + (37 * L) % 61, L) for L in range(lo, hi + 1)]


def _ladders(part, nparts):
    return lambda rng: [plain_call(rng, 24 + (29 * i) % 57, _ladder_rows8(rng, lad))
                        for i, lad in enumerate(TRACE_LADDERS[part::nparts])]


def _lad_chunk(part, nparts):
    tails = [56, 5, 81, 120, 8, 51, 72, 13, 100, 1]
    return lambda rng: [chunked_call(rng, 128 + tails[i % len(tails)], 128, ladder=lad)
                        for i, lad in enumerate(TRACE_LADDERS[part::nparts])]


def _chunk(cd):
    Ls = [1, 7, 16, 17, 31, 38, 44, 64, 84, 97, 112, 128]
    tails = [1, 5, 8, 13, 56, 81, 3, 72, 9, 40, 0, 17]
    return lambda rng: [chunked_call(rng, 2 * cd + t % cd, cd, L=L) for L, t in zip(Ls, tails)]


def _chunk_rung(cd):
    lads = [[128, 96, 64, 48, 44, 42, 38], [97, 64, 48, 32, 25, 18, 128, 84], [128, 112, 96, 64, 48, 44, 42, 38]]
    return lambda rng: [chunked_call(rng, 3 * cd + t, cd, ladder=lad) for lad, t in zip(lads, [cd // 2 + 3, 7, 1])]


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
    full = np.full((R, 2048), 128)
    sa = np.repeat((np.arange(R) % 2)[:, None], 2048, axis=1)       # odd rows negative
    sb = np.repeat((np.arange(C) // 4)[:, None], 2048, axis=1)      # columns 4..7 negative
    return [plain_call(rng, 2048, 128, ops=signed_ops(full, full, sa, sb))]


def _extreme_mix(rng):
    vals = np.array([0, 1, 63, 64, 65, 127, 128])

    def ops(D):
        ba, bb = rng.choice(vals, size=(R, D)), rng.choice(vals, size=(C, D))
        return signed_ops(ba, bb, rng.integers(0, 2, (R, D)), rng.integers(0, 2, (C, D)))
    out = [plain_call(rng, D, Lr, ops=ops(D)) for D, Lr in ((136, [1, 2, 15, 16, 17, 31, 33, 128]),
                                                            (100, [128, 1, 64, 127, 2, 17, 96, 3]))]
    out.append(chunked_call(rng, 230, 100, ladder=[128, 1, 2, 16, 17, 64], ops=ops(230)))
    return out


def _extreme_zero(rng):
    out = []
    for D, L in ((64, 1), (72, 16), (40, 128)):
        ba = np.where(rng.random((R, D)) < 0.9, 0, 128)
        bb = np.where(rng.random((C, D)) < 0.9, 0, 128)
        out.append(plain_call(rng, D, L, ops=signed_ops(ba, bb, np.ones((R, D)), rng.integers(0, 2, (C, D)))))
    return out


EXTRA_CASES = {
    "af_uL_001_032": (_uL(1, 32), "every uniform L 1..32, one plain call each, back to back"),
    "af_uL_033_064": (_uL(33, 64), "every uniform L 33..64, one plain call each, back to back"),
    "af_uL_065_096": (_uL(65, 96), "every uniform L 65..96, one plain call each, back to back"),
    "af_uL_097_128": (_uL(97, 128), "every uniform L 97..128, one plain call each, back to back"),
    **{f"af_ladders_{i}": (_ladders(i, 4), f"trace ladders part {i}/4: plain per-row-L calls") for i in range(4)},
    **{f"af_lad_chunk_{i}": (_lad_chunk(i, 4), f"trace ladders part {i}/4 as chunk_d=128 rung tables") for i in range(4)},
    **{f"af_chunk_{cd}": (_chunk(cd), f"chunk_d={cd}, uniform L over 12 values, tails 0..81") for cd in (128, 96, 100)},
    **{f"af_chunk_rung_{cd}": (_chunk_rung(cd), f"chunk_d={cd} rung tables") for cd in (96, 100)},
    "af_perhead": (_perhead, "per-head calls: 3xD64 L64, 3xD72 L50, 2xD128 L97, 2xD40 L1"),
    "af_calls_mixed": (_calls_mixed, "protected-first split, plain 257, chunked rungs, per-head 72, gathered 21, "
                                     "chunk_d 96, plain 61"),
    "af_calls_odd": (_calls_odd, "deployed odd block counts: chunk_d 128 at 721 / 584 / 3973, plain 257, gathered 77"),
    "af_av2048": (_av2048, "one attention call, D=2048 (256 blocks), per-row L"),
    "af_extreme_max": (_extreme_max, "all b=128, L=128, D=2048, row/column signs: accumulators +-262144"),
    "af_extreme_mix": (_extreme_mix, "magnitudes 0/1/63/64/65/127/128, per-row L incl. 1, 2, 15..17, 31, 33"),
    "af_extreme_zero": (_extreme_zero, "mostly b=0 with sign bit 1 (negative zero), a few 128s; L 1 / 16 / 128"),
}


# --------------------------------------------------------------------------------------------------- review --

def _rand_ladder(rng, n, lo=1, hi=128):
    return [int(v) for v in rng.choice(np.arange(lo, hi + 1), size=n, replace=False)]


def _rv_tiny_calls(rng):
    out = []
    for _ in range(60):
        D = int(rng.integers(1, 21))
        out.append(plain_call(rng, D, rng.integers(1, 129, size=R)))
    return out


def _rv_mixed_long(rng):
    out = prot_calls(rng, 410, 93, 95, 128, [128, 97, 84, 64, 48, 32, 25, 18], protected_first=False)
    out.append(plain_call(rng, 333, np.array(_rand_ladder(rng, 8))))
    out.append(chunked_call(rng, 136 * 2 + 11, 136, ladder=_rand_ladder(rng, 12)))
    out += prot_calls(rng, 300, 50, 68, 128, [128, 96, 64, 48, 44, 42, 38], protected_first=True)
    return out


def _rv_c1_chain(rng):
    lad = _rand_ladder(rng, 8, 1, 16)
    return [chunked_call(rng, 8 * 12 + 2, 8, ladder=lad), chunked_call(rng, 16 * 6 + 3, 16, ladder=lad),
            plain_call(rng, 77, np.array(_rand_ladder(rng, 8, 1, 16)))]


REVIEW_CASES = {
    "rv_cd8": (lambda rng: [chunked_call(rng, 8 * 30 + 3, 8, ladder=_rand_ladder(rng, 16), mags="uniform")],
               "chunk_d=8: a drain after every block, random per-(row, chunk) L"),
    "rv_cd16": (lambda rng: [chunked_call(rng, 16 * 20 + 9, 16, ladder=_rand_ladder(rng, 16), mags="uniform")],
                "chunk_d=16: two blocks per slice, random rungs"),
    "rv_cd_unaligned": (lambda rng: [chunked_call(rng, 3 * cd + tail, cd, ladder=_rand_ladder(rng, 10))
                                     for cd, tail in ((24, 5), (40, 17), (56, 1), (72, 33), (136, 77))],
                        "chunk_d 24/40/56/72/136 calls back to back, random rungs"),
    "rv_c1_chain": (_rv_c1_chain, "all L <= 16 (one-cycle blocks), cd 8 / cd 16 / plain"),
    "rv_plain_randL": (lambda rng: [plain_call(rng, 1000, np.array(_rand_ladder(rng, 8)), mags="uniform")],
                       "plain D=1000, random distinct per-row L, uniform magnitudes"),
    "rv_tiny_calls": (_rv_tiny_calls, "60 calls of 1..20 columns, per-row L random 1..128"),
    "rv_mixed_long": (_rv_mixed_long, "unprotected-first split, plain 333, cd 136 rungs, protected-first split"),
}

SETS = {"base": BASE_CASES, "extra": EXTRA_CASES, "review": REVIEW_CASES}
DEFAULT_SEED = {"base": 1, "extra": 1, "review": 11}


def build_case(set_name, name, seed):
    """(spec, calls) of one case; the generator seed is derived from the case name."""
    if set_name == "review":
        rng = np.random.default_rng(seed * 7919 + sum(map(ord, name)))
    else:
        rng = np.random.default_rng(seed + sum(map(ord, name)))
    if set_name == "base":
        return build_base(name, rng)
    builder, doc = SETS[set_name][name]
    return dict(path=f"af_{set_name}", doc=doc), builder(rng)


# ==================================================================================================================
# Golden files
# ==================================================================================================================

def write_mem(path, values, digits, header, signed=False):
    """Plain hex, one word per line, after one `//` header line ($readmemh skips it); negatives as two's complement."""
    v = np.asarray(values, np.int64).reshape(-1)
    mask = (1 << (4 * digits)) - 1
    lo, hi = (-(1 << (4 * digits - 1)), mask >> 1) if signed else (0, mask)
    if v.size and (v.min() < lo or v.max() > hi):
        raise ValueError(f"{path}: values outside {digits} hex digits")
    Path(path).write_text("\n".join([f"// {header}"] + [f"{int(x) & mask:0{digits}x}" for x in v]) + "\n")


def read_mem(path):
    """Words of a .mem file (hex, `//` comments)."""
    vals = [line.split("//")[0].strip() for line in Path(path).read_text().splitlines()]
    return np.array([int(x, 16) for x in vals if x], dtype=np.int64)


def fault_wrong(calls, fault, shape):
    """Accumulators a mask fault leaves wrong on a call sequence."""
    return sum(int(np.count_nonzero(o != c["exp"])) for o, c in zip(hw_calls_acc(calls, fault, shape), calls))


def emit_case(outdir, set_name, name, seed, shape=(8, 16)):
    """Gate, then write DIR/<name>/.  Returns (dir, n_blocks, n_drains, n_calls, {fault: accumulators wrong})."""
    g = geometry(*shape)
    spec, calls = build_case(set_name, name, seed)
    trace = []
    if not all(np.array_equal(o, c["exp"]) for o, c in zip(hw_calls_acc(calls, shape=shape, trace=trace), calls)):
        raise SystemExit(f"{name}: the {g.name} emulation disagrees with the kernel; nothing written")
    if set_name == "base":
        caught = {f: fault_wrong(calls, f, shape) for f in spec.get("catches", ())}
        missed = [f for f, n in caught.items() if n == 0]
        if missed:
            raise SystemExit(f"{name}: declared to catch {missed}, but they leave no accumulator wrong; nothing written")
    else:
        caught = {f: n for f in MASK_FAULTS if (n := fault_wrong(calls, f, shape)) > 0}
        spec["catches"] = list(caught)
    K, M = g.K, g.M
    cols = {k: [] for k in ("a_mag", "a_sgn", "w_mag", "w_sgn", "row_len", "phase", "cycles", "drain", "slice_start",
                            "call_start", "ka", "acc_blk", "acc_exp")}
    blkinfo = []
    for b in trace:
        c = calls[b["call"]]
        lo, hi = b["lo"], b["hi"]
        w = hi - lo
        a, an = np.zeros((R, K), np.int64), np.zeros((R, K), np.int64)
        wm, wn = np.zeros((K, C), np.int64), np.zeros((K, C), np.int64)
        a[:, :w], an[:, :w] = c["ba"][:, lo:hi], c["sa"][:, lo:hi] < 0
        wm[:w], wn[:w] = c["bb"][:, lo:hi].T, c["sb"][:, lo:hi].T < 0
        for k, v in (("a_mag", a), ("a_sgn", an), ("w_mag", wm), ("w_sgn", wn), ("row_len", b["L"]),
                     ("phase", b["phase"]), ("cycles", b["cycles"][0]), ("drain", int(b["last"])),
                     ("slice_start", int(b["slice_start"])), ("call_start", int(b["call_start"])), ("ka", b["kA"]),
                     ("acc_blk", b["acc"])):
            cols[k].append(v)
        info = dict(call=b["call"], slice=len(cols["acc_exp"]), call_slice=b["slice"], blk=b["blk"], cols=[lo, hi],
                    local_d=[lo - b["s_lo"], hi - b["s_lo"]], phase=b["phase"], cycles=b["cycles"][0],
                    drain=bool(b["last"]), slice_start=bool(b["slice_start"]), call_start=bool(b["call_start"]))
        if c["cols"] is not None:
            info["orig_ch"] = [int(v) for v in np.asarray(c["cols"])[lo:hi]]
        blkinfo.append(info)
        if b["last"]:
            cols["acc_exp"].append(c["exp"][b["slice"]])
    nb, nd = len(trace), len(cols["acc_exp"])
    out = Path(outdir) / name
    out.mkdir(parents=True, exist_ok=True)
    hdr = f"case {name}: {spec['doc']}" if shape == (8, 16) else f"case {name} ({g.name}): {spec['doc']}"
    files = {   # file: (hex digits, description); the entry index layouts are in the descriptions
        "a_mag": (2, f"A magnitude, entry blk*{R * K} + row*{K} + lane, 0..80h"),
        "a_sgn": (1, f"A sign bit (1 = negative), entry blk*{R * K} + row*{K} + lane"),
        "w_mag": (2, f"W magnitude, entry blk*{K * C} + lane*{C} + col, 0..80h"),
        "w_sgn": (1, f"W sign bit (1 = negative), entry blk*{K * C} + lane*{C} + col"),
        "row_len": (2, f"stream length L of each row, entry blk*{R} + row, 01..80h"),
        "phase": (1, f"EXPECTED block phase p (mask bits [{g.PB + 1}:2] = bitrev{g.PB}(p)), entry blk; "
                     "the DUT derives it from slice_start"),
        "cycles": (len(f"{g.CYC:x}"), f"cycles this block = ceil(max row L / {M}), entry blk"),
        "drain": (1, "1 = drain and clear the accumulators after this block"),
        "slice_start": (1, "1 = first block of a slice (chunk / head / call): phase register resets to 0 for this block"),
        "call_start": (1, "1 = first block of a new call; do NOT reset the DUT here (calls run back to back)"),
        "ka": (2, f"AF A count kA (closed form), entry blk*{R * K} + row*{K} + lane"),
        "acc_blk": (8, f"accumulator after each block (since last drain), entry blk*{R * C} + row*{C} + col, int32"),
        "acc_exp": (8, f"expected accumulator at each drain, entry drain*{R * C} + row*{C} + col, int32 two's complement"),
    }
    for f, (digits, what) in files.items():
        write_mem(out / f"{f}.mem", np.array(cols[f]), digits, f"{hdr} | {what}", signed=f.startswith("acc"))
    write_mem(out / "cfg.mem", [nb, nd, R, C, K, M, len(calls)], 8, f"{hdr} | N_BLOCKS N_DRAINS ROWS COLS LANES POS N_CALLS")
    meta = dict(case=name, doc=spec["doc"], spec={k: v for k, v in spec.items() if k != "doc"}, seed=seed,
                n_blocks=nb, n_drains=nd, n_calls=len(calls), checked=f"kernel == A-first emulation, {g.name} (every drain)",
                catches={f: dict(af_wrong=n, what=MASK_FAULTS[f]) for f, n in caught.items()}, blocks=blkinfo)
    (out / "case.json").write_text(json.dumps(meta, indent=1, default=int) + "\n")
    return out, nb, nd, len(calls), caught


# Phase-reset policies a wrong DUT might have, checkable from the .mem files alone, and the fault each one is.
PHASE_POLICIES = {"call": "no_slice_reset", "free": "no_phase_reset"}


def _policy_phase(slice_start, call_start, policy, nph):
    """Phase per block of a DUT whose phase register resets at every slice start ('slice', correct), at call starts
    only ('call'), or only at the first block of the run ('free')."""
    reset = {"slice": slice_start, "call": call_start, "free": np.arange(len(slice_start)) == 0}[policy]
    ph, p = np.zeros(len(reset), np.int64), 0
    for b, r in enumerate(reset):
        p = 0 if r else (p + 1) % nph
        ph[b] = p
    return ph


def check_golden(case_dir):
    """Re-derive every drain of a case from its .mem files alone (the bench's view), feeding the A-first block model
    only what the files hold; kA and the per-block accumulators must match too.  Control files: a slice starts after
    every drain, call_start implies slice_start and numbers N_CALLS, phase.mem equals a phase register reset at
    slice_start, cycles.mem is ceil(max L / M).  Also reports what a DUT with a wrong phase-reset policy gets; if
    case.json declares the matching fault caught, that DUT must leave accumulators wrong.
    Returns (bad, n_blocks, n_drains, n_calls, shape name, {policy: accumulators wrong})."""
    d = Path(case_dir)
    s32 = lambda v: np.where(v >= 1 << 31, v - (1 << 32), v)   # noqa: E731
    nb, nd, rows, ncols, K, M, n_calls = (int(v) for v in read_mem(d / "cfg.mem"))
    g = geometry(K, M)
    mem = lambda f, *shape: read_mem(d / f"{f}.mem").reshape(nb if f != "acc_exp" else nd, *shape)   # noqa: E731
    am, asg, ka = mem("a_mag", rows, K), mem("a_sgn", rows, K).astype(bool), mem("ka", rows, K)
    wm, wsg = mem("w_mag", K, ncols), mem("w_sgn", K, ncols).astype(bool)
    Lm, ph, cy, dr = mem("row_len", rows), mem("phase"), mem("cycles"), mem("drain").astype(bool)
    ss, cs = mem("slice_start").astype(bool), mem("call_start").astype(bool)
    ab, ex = s32(mem("acc_blk", rows, ncols)), s32(mem("acc_exp", rows, ncols))
    bad = int(not np.array_equal(ss, np.r_[True, dr[:-1]])) + int(np.any(cs & ~ss)) + int(not cs[0])
    bad += int(cs.sum() != n_calls) + int(not np.array_equal(_policy_phase(ss, cs, "slice", g.NPH), ph))
    bad += int(not np.array_equal(cy, -(-Lm.max(axis=1) // M)))

    def run(phases, debug):
        acc, wrong, nbad, di = np.zeros((rows, ncols), np.int64), 0, 0, 0
        for b in range(nb):
            blk, k = af_block(g, am[b], asg[b], wm[b], wsg[b], Lm[b], g.MASK[:, phases[b]], int(cy[b]))
            acc += blk
            if debug:
                nbad += int(np.count_nonzero(k != ka[b])) + int(np.count_nonzero(acc != ab[b]))
            if dr[b]:
                wrong += int(np.count_nonzero(acc != ex[di]))
                acc[:] = 0
                di += 1
        return nbad + int(di != nd), wrong

    nbad, wrong = run(ph, True)
    bad += nbad + wrong
    sens = {pol: run(_policy_phase(ss, cs, pol, g.NPH), False)[1] for pol in PHASE_POLICIES}
    meta = json.loads((d / "case.json").read_text()) if (d / "case.json").exists() else {}
    bad += sum(1 for pol, f in PHASE_POLICIES.items() if f in meta.get("catches", {}) and sens[pol] == 0)
    return bad, nb, nd, n_calls, g.name, sens


def _case_dirs(paths):
    out = []
    for p in map(Path, paths):
        out += [p] if (p / "cfg.mem").exists() else sorted(c for c in p.iterdir() if (c / "cfg.mem").exists())
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    em = sub.add_parser("emit", help="build, gate, write and re-check a case set")
    em.add_argument("--set", choices=SETS, required=True)
    em.add_argument("--out", required=True, help="output directory (one subdirectory per case)")
    em.add_argument("--case", default="all", help="comma-separated case names, or 'all'")
    em.add_argument("--seed", type=int, help="default: 1 for base and extra, 11 for review")
    em.add_argument("--shape", choices=SHAPES, default="k8m16", help="PE shape (default %(default)s)")
    cg = sub.add_parser("check-golden", help="re-derive cases from their .mem files")
    cg.add_argument("dirs", nargs="+")
    ls = sub.add_parser("list", help="list the cases of a set")
    ls.add_argument("--set", choices=SETS)
    args = ap.parse_args()
    if args.cmd == "list":
        for s in [args.set] if args.set else SETS:
            for name, v in SETS[s].items():
                print(f"{s:6s} {name:18s} {v['doc'] if s == 'base' else v[1]}")
        return 0
    rc = 0
    if args.cmd == "emit":
        seed = DEFAULT_SEED[args.set] if args.seed is None else args.seed
        names = list(SETS[args.set]) if args.case == "all" else args.case.split(",")
        for n in names:
            t0 = time.time()
            out, nb, nd, nc, caught = emit_case(args.out, args.set, n, seed, SHAPES[args.shape])
            bad = check_golden(out)[0]
            cs = ", ".join(f"{f} {k}" for f, k in caught.items()) or "none"
            print(f"[{'PASS' if bad == 0 else 'FAIL'}] {n} ({geometry(*SHAPES[args.shape]).name}): {nb} blocks, "
                  f"{nd} drains, {nc} calls; kernel == AF; re-derived from .mem; mask faults caught (AF wrong): {cs}; "
                  f"{time.time() - t0:.1f} s", flush=True)
            rc |= int(bad != 0)
        return rc
    dirs = _case_dirs(args.dirs)
    for cd in dirs:
        bad, nb, nd, nc, shape, sens = check_golden(cd)
        print(f"[{'PASS' if bad == 0 else 'FAIL'}] {cd.name} ({shape}): {nb} blocks, {nd} drains, {nc} call"
              f"{'s' if nc > 1 else ''} re-derived from the .mem files; DUT phase reset at call start only -> "
              f"{sens['call']} wrong, never reset -> {sens['free']} wrong")
        rc |= int(bad != 0)
    print(f"check-golden: {len(dirs)} cases, {'all PASS' if rc == 0 and dirs else 'FAIL'}")
    return rc if dirs else 1


if __name__ == "__main__":
    sys.exit(main())
