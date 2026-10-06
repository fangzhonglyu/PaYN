#!/usr/bin/env python3
"""Extra golden cases for the RG RTL bench (designs/payn/tb/test_payn_array_cbsg_rg.sv).

Same file format and the same writer as `sweeps/cbsg/cbsg_ref.py --emit` (cbsg_ref.emit_case): every case is
written only after kernel == RG model == AF model at every block and drain.  The cases here are longer
multi-call sequences (one 8 x 8 tile, calls back to back, no DUT reset in between):

  allL_plain      L = 1..128, one plain call each (D = 67: 9 blocks, last block 3 lanes)
  ladders_plain   every deployed trace ladder (cbsg_ref.trace_ladders()), one plain call each, per-row L, D = 45
  allL_chunk128   L = 1..128, chunk_d = 128, D = 133 (5-column tail)
  allL_chunk96    L = 1..128, chunk_d = 96,  D = 200 (8-column tail)
  allL_chunk100   L = 1..128, chunk_d = 100, D = 230 (30-column tail; every chunk ends in a padded block)
  allL_perhead    L = 1..128, per-head, 2 heads of D = 40 (odd L) or 64 (even L), one drain per head
  calls_mix       heterogeneous calls back to back: plain / chunked 96, 100, 128 with rungs / per-head /
                  protected split / single-column and single-block calls
  extreme_mix     all-128 (both product signs), all-1, all-127, all-64, all-zero with random signs, and
                  0/1/127/128 magnitudes at L = 1, 2, 15, 16, 17, ... 127, 128
  range_2048      plain D = 2048 (one av-length slice), all magnitudes 128: |acc| up to 128 * 2048 = 262144

The mask faults a case catches (cbsg_ref.MASK_FAULTS, checked with hw_calls_acc) are recorded in case.json.

  PYTHONDONTWRITEBYTECODE=1 python3 sweeps/cbsg/rg/gen_cases.py [--out build/cbsg/rg/golden_extra] [--case all]
"""
import argparse
import sys
import time
from pathlib import Path

sys.dont_write_bytecode = True
REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / "sweeps" / "cbsg"))
import numpy as np            # noqa: E402
import cbsg_ref as R          # noqa: E402

TILE = R.TILE_R
LAD_4B = [128, 97, 84, 64, 48, 32, 25, 18]


def _ops(rng, D, mags="mixed"):
    ba, sa = R.gen_operands(rng, TILE, D, mags)
    bb, sb = R.gen_operands(rng, TILE, D, mags)
    return ba, sa, bb, sb


def plain_call(ba, sa, bb, sb, L):
    L = np.broadcast_to(np.asarray(L, np.int64), (TILE,)).copy()
    return dict(ba=ba, sa=sa, bb=bb, sb=sb, L=L[:, None], slice_len=0, cols=None,
                exp=R.kernel_acc_plain(ba, sa, bb, sb, L)[None])


def chunked_call(ba, sa, bb, sb, cd, L=None, ladder=None, rng=None):
    D = ba.shape[1]
    if D <= cd:
        raise ValueError("chunked_call needs D > chunk_d")
    nch = -(-D // cd)
    if ladder is not None:
        rung = rng.integers(0, len(ladder), size=(TILE, nch))
        rung.reshape(-1)[: len(ladder)] = np.arange(len(ladder))
        exp = R.kernel_acc_chunked(ba, sa, bb, sb, cd, stoc_len=R.L_MAX, rung_table=rung, level_lens=ladder)
        Lrc = np.asarray(ladder)[rung]
    else:
        exp = R.kernel_acc_chunked(ba, sa, bb, sb, cd, stoc_len=int(L))
        Lrc = np.full((TILE, nch), int(L))
    return dict(ba=ba, sa=sa, bb=bb, sb=sb, L=Lrc, slice_len=cd, cols=None, exp=exp)


def perhead_call(rng, BH, D, L, mags="mixed"):
    ops = [_ops(rng, D, mags) for _ in range(BH)]
    st = [np.stack([o[i] for o in ops]) for i in range(4)]
    exp = R.kernel_acc_batched(st[0], st[1], st[2], st[3], L)
    cat = lambda x: np.concatenate(list(x), axis=1)
    return dict(ba=cat(st[0]), sa=cat(st[1]), bb=cat(st[2]), sb=cat(st[3]), L=np.full((TILE, BH), int(L)),
                slice_len=D, cols=None, exp=exp)


def prot_split_calls(rng, D, n_prot, prot_L, cd, ladder):
    """Unprotected call on the gathered rest (chunked, rungs), then the protected call (chunked, one L), as
    cbsg_ref build_case 'calls_prot'."""
    ba, sa, bb, sb = _ops(rng, D)
    prot = np.sort(rng.choice(D, size=n_prot, replace=False))
    rest = np.setdiff1d(np.arange(D), prot)
    out = []
    for cols, L in ((rest, None), (prot, prot_L)):
        c = dict(ba=ba[:, cols], sa=sa[:, cols], bb=bb[:, cols], sb=sb[:, cols])
        if L is None:
            call = chunked_call(c["ba"], c["sa"], c["bb"], c["sb"], cd, ladder=ladder, rng=rng)
        elif len(cols) > cd:
            call = chunked_call(c["ba"], c["sa"], c["bb"], c["sb"], cd, L=L)
        else:
            call = plain_call(c["ba"], c["sa"], c["bb"], c["sb"], L)
        call["cols"] = cols
        out.append(call)
    return out


def const_ops(D, mag_a, mag_w, neg_a, neg_w):
    ba = np.full((TILE, D), mag_a, np.int16)
    bb = np.full((TILE, D), mag_w, np.int16)
    sa = np.where(np.asarray(neg_a), -1, 1) * np.ones((TILE, D), np.int8)
    sb = np.where(np.asarray(neg_w), -1, 1) * np.ones((TILE, D), np.int8)
    return ba, sa.astype(np.int8), bb, sb.astype(np.int8)


# ----------------------------------------------------------------------------------------------- cases --
def c_allL_plain(rng):
    return [plain_call(*_ops(rng, 67), L) for L in range(1, 129)]


def c_ladders_plain(rng):
    calls = []
    for lad in R.trace_ladders().values():
        L = R._ladder_rows(rng, lad, TILE)
        calls.append(plain_call(*_ops(rng, 45), L))
    return calls


def c_allL_chunk(cd, D):
    return lambda rng: [chunked_call(*_ops(rng, D), cd, L=L) for L in range(1, 129)]


def c_allL_perhead(rng):
    return [perhead_call(rng, 2, 40 if L % 2 else 64, L) for L in range(1, 129)]


def c_calls_mix(rng):
    calls = [plain_call(*_ops(rng, 257), R._ladder_rows(rng, [128, 97, 64, 48, 32], TILE)),
             chunked_call(*_ops(rng, 200), 96, ladder=[128, 96, 64, 48, 32, 24, 16], rng=rng),
             perhead_call(rng, 2, 40, 48)]
    calls += prot_split_calls(rng, 600, 139, 84, 128, LAD_4B)
    calls += [plain_call(*_ops(rng, 1), 128),
              chunked_call(*_ops(rng, 230), 100, L=64),
              plain_call(*_ops(rng, 21), 17),
              chunked_call(*_ops(rng, 261), 128, ladder=LAD_4B, rng=rng),
              plain_call(*_ops(rng, 8), 1),
              plain_call(*_ops(rng, 13), R._ladder_rows(rng, [113, 112, 111, 65, 64, 63, 17, 16], TILE))]
    return calls


def c_extreme_mix(rng):
    calls = []
    rows = np.arange(TILE)
    calls.append(plain_call(*const_ops(64, 128, 128, False, False), 128))                   # +128*64
    calls.append(plain_call(*const_ops(64, 128, 128, True, False), 128))                    # -128*64
    calls.append(plain_call(*const_ops(64, 128, 128, (rows % 2)[:, None] == 1, (rows // 4)[:, None] == 1),
                            [128, 127, 97, 96, 65, 64, 2, 1]))
    calls.append(plain_call(*const_ops(64, 1, 1, False, True), 1))
    calls.append(plain_call(*const_ops(64, 1, 128, False, False), 128))
    calls.append(plain_call(*const_ops(64, 127, 127, True, True), 97))
    calls.append(plain_call(*const_ops(64, 64, 64, False, True), 64))
    calls.append(plain_call(*const_ops(40, 128, 1, False, False), [128, 112, 64, 33, 32, 31, 16, 1]))
    z = const_ops(24, 0, 0, False, False)
    zs = (z[0], rng.choice(np.array([-1, 0, 1]), size=(TILE, 24)).astype(np.int8),
          z[2], rng.choice(np.array([-1, 0, 1]), size=(TILE, 24)).astype(np.int8))
    calls.append(plain_call(*zs, 128))                                                     # zeros, any sign
    for L in (1, 2, 15, 16, 17, 31, 32, 33, 63, 64, 65, 111, 112, 113, 127, 128):
        calls.append(plain_call(*_ops(rng, 24, "extreme"), L))
    return calls


def c_range_2048(rng):
    rows = np.arange(TILE)
    ba, sa, bb, sb = const_ops(2048, 128, 128, (rows % 2)[:, None] == 1, ((rows // 2) % 2)[:, None] == 1)
    return [plain_call(ba, sa, bb, sb, [128, 128, 128, 128, 128, 128, 97, 1])]


EXTRA = {
    "allL_plain":    (c_allL_plain, "L = 1..128, one plain call each, D = 67 (9 blocks, last 3 lanes padded)"),
    "ladders_plain": (c_ladders_plain, "every trace ladder, one plain call each, per-row L, D = 45"),
    "allL_chunk128": (c_allL_chunk(128, 133), "L = 1..128, chunk_d 128, D = 133 (5-column tail)"),
    "allL_chunk96":  (c_allL_chunk(96, 200), "L = 1..128, chunk_d 96, D = 200 (8-column tail)"),
    "allL_chunk100": (c_allL_chunk(100, 230), "L = 1..128, chunk_d 100, D = 230 (padded block per chunk)"),
    "allL_perhead":  (c_allL_perhead, "L = 1..128, per-head 2 heads of D = 40 / 64, one drain per head"),
    "calls_mix":     (c_calls_mix, "heterogeneous calls back to back: plain, chunked 96/100/128 with rungs, "
                                   "per-head, protected split, 1-column and 1-block calls"),
    "extreme_mix":   (c_extreme_mix, "all-128 both signs, all-1, all-127, all-64, zeros with random signs, "
                                     "0/1/127/128 magnitudes at boundary L"),
    "range_2048":    (c_range_2048, "plain D = 2048, all magnitudes 128: |acc| up to 262144"),
}

_ORIG_BUILD = R.build_case
_BUILT = {}


def _build(name, seed=1):
    if name not in EXTRA:
        return _ORIG_BUILD(name, seed)
    return _BUILT[name]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default=str(REPO / "build" / "cbsg" / "rg" / "golden_extra"))
    ap.add_argument("--case", default="all")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--no-check", action="store_true", help="skip cbsg_ref.check_golden on the written cases")
    args = ap.parse_args()
    names = list(EXTRA) if args.case == "all" else args.case.split(",")
    R.build_case = _build
    rc = 0
    for name in names:
        t0 = time.time()
        fn, doc = EXTRA[name]
        rng = np.random.default_rng(args.seed + sum(map(ord, name)))
        calls = fn(rng)
        catches = []
        for f in R.MASK_FAULTS:
            wrong = R._fault_wrong(calls, f)
            if min(wrong) > 0:
                catches.append(f)
        spec = dict(path="rg_extra", doc=doc, n_calls=len(calls), catches=tuple(catches))
        R.CASES[name] = spec
        _BUILT[name] = (spec, calls)
        out, nb, nd, nc, caught = R.emit_case(args.out, name, args.seed)
        cs = ", ".join(f"{f} {a}/{b}" for f, (a, b) in caught.items()) or "none"
        line = (f"wrote {out}  ({nb} blocks, {nd} drains, {nc} calls, kernel == RG == AF; "
                f"mask faults caught (RG/AF accs wrong): {cs})  [{time.time() - t0:.1f} s]")
        if not args.no_check:
            bad, *_ = R.check_golden(out)
            line += f"  check_golden {'PASS' if bad == 0 else 'FAIL'}"
            rc |= int(bad != 0)
        print(line, flush=True)
    return rc


if __name__ == "__main__":
    sys.exit(main())
