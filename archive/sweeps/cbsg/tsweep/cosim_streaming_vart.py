#!/usr/bin/env python3
"""Bit-exact check of the variable-length CSA power trace (power_payn_array_csa_vart.sv).

A copy of designs/payn/cosim/cosim_streaming.py whose blocks carry their own cycle count: batch b is held for
c_b clocks (the trace's "BATCH b c_b" line) while both Sobol banks advance every clock, and the accumulator
matrix is recomputed slice by slice with the same sc_kernel functions (edge_operand_bits,
inner_tile_2bit_contribution) and compared with the drain bit for bit.  The window (sum of c_b) must equal the
trace's WINDOW line.

Also accepts a plain power_payn_array.sv trace (STREAMCFG ... T ...; c_b = T/M for every block), which is how
this checker is cross-checked against cosim_streaming.py.

Optional provenance checks:
  --stim FILE       the trace's operands (m >> 1) and cycle counts equal the stimulus file
  --af-trace FILE   ... equal the A-first C-BSG power trace's |q| (b = |q| + [|q| >= 64] inverted), signs and
                    per-block cycle counts (the ladder-equivalent run)

  python3 sweeps/cbsg/tsweep/cosim_streaming_vart.py TRACE [--stim F] [--af-trace F] [--json OUT]
"""
from __future__ import annotations

import argparse
import json
import math
import sys
from dataclasses import dataclass
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / "designs" / "payn" / "cosim"))
from sc_kernel import ArrayCfg, edge_operand_bits, inner_tile_2bit_contribution  # noqa: E402


@dataclass(frozen=True)
class VartTrace:
    cfg: ArrayCfg
    n_batches: int
    cycles: list[int]
    a_mag: list[np.ndarray]
    a_sign: list[np.ndarray]
    w_mag: list[np.ndarray]
    w_sign: list[np.ndarray]
    window: int | None
    drain: np.ndarray


def _read_vector(lines, cursor, tag, count, dtype):
    if cursor >= len(lines) or not lines[cursor] or lines[cursor][0] != tag:
        found = "<EOF>" if cursor >= len(lines) else " ".join(lines[cursor][:2])
        raise ValueError(f"expected {tag}, found {found}")
    values = lines[cursor][1:]
    if len(values) != count:
        raise ValueError(f"{tag} has {len(values)} values, expected {count}")
    return np.asarray(values, dtype=dtype), cursor + 1


def parse_trace(path: Path) -> VartTrace:
    lines = [line.split() for line in path.read_text().splitlines() if line.split()]
    head = lines[0] if lines else []
    fixed_c = None
    if head and head[0] == "STREAMCFGV" and len(head) == 9:
        k, m, nh, nw, width, owidth, n_batches, wrap = map(int, head[1:])
    elif head and head[0] == "STREAMCFG" and len(head) in (9, 10):
        vals = [int(v) for v in head[1:]]
        k, m, nh, nw, width, owidth, t, n_batches = vals[:8]
        wrap = vals[8] if len(vals) == 9 else 0
        if t % m:
            raise ValueError("padded-T traces are cosim_streaming.py's job")
        fixed_c = t // m
    else:
        raise ValueError("missing STREAMCFGV K M NH NW WIDTH OWIDTH NBATCHES RNG_WRAP (or STREAMCFG)")
    cfg = ArrayCfg(K=k, M=m, N_H=nh, N_W=nw, WIDTH=width, OWIDTH=owidth, T=m, RNG_FULL_PERIOD_WRAP=bool(wrap))
    cycles, a_mag, a_sign, w_mag, w_sign = [], [], [], [], []
    cursor = 1
    for b in range(n_batches):
        f = lines[cursor] if cursor < len(lines) else []
        want = 3 if fixed_c is None else 2
        if len(f) != want or f[0] != "BATCH" or int(f[1]) != b:
            raise ValueError(f"missing or out-of-order BATCH {b}")
        c = int(f[2]) if fixed_c is None else fixed_c
        if c < 1:
            raise ValueError(f"BATCH {b}: cycle count {c}")
        cycles.append(c)
        cursor += 1
        v, cursor = _read_vector(lines, cursor, "AMAG", nh * k, np.int64); a_mag.append(v.reshape(nh, k))
        v, cursor = _read_vector(lines, cursor, "ASIGN", nh * k, np.uint8); a_sign.append(v.reshape(nh, k))
        v, cursor = _read_vector(lines, cursor, "WMAG", nw * k, np.int64); w_mag.append(v.reshape(nw, k))
        v, cursor = _read_vector(lines, cursor, "WSIGN", nw * k, np.uint8); w_sign.append(v.reshape(nw, k))
    window = None
    if cursor < len(lines) and lines[cursor][0] == "WINDOW":
        window = int(lines[cursor][1]); cursor += 1
    elif fixed_c is None:
        raise ValueError("missing WINDOW")
    drain, cursor = _read_vector(lines, cursor, "DRAIN", nh * nw, np.int64)
    if cursor != len(lines):
        raise ValueError(f"unexpected trailing trace record: {' '.join(lines[cursor])}")
    return VartTrace(cfg, n_batches, cycles, a_mag, a_sign, w_mag, w_sign, window, drain.reshape(nh, nw))


def reference(tr: VartTrace) -> np.ndarray:
    cfg = tr.cfg
    rng_a, rng_w = cfg.make_rng_in(), cfg.make_rng_w()
    acc = np.zeros((cfg.N_H, cfg.N_W), dtype=np.int64)
    for b in range(tr.n_batches):
        for _ in range(tr.cycles[b]):
            ta, tw = rng_a.step(), rng_w.step()
            a_bits = edge_operand_bits(tr.a_mag[b], ta, cfg.K, cfg.M, cfg.WIDTH, 0)
            w_bits = edge_operand_bits(tr.w_mag[b], tw, cfg.K, cfg.M, cfg.WIDTH, 1 << (cfg.WIDTH - 1))
            for h in range(cfg.N_H):
                for v in range(cfg.N_W):
                    acc[h, v] += inner_tile_2bit_contribution(a_bits[h], w_bits[v], tr.a_sign[b][h],
                                                              tr.w_sign[b][v], cfg.K, cfg.M)
    mask, sign_bit = (1 << cfg.OWIDTH) - 1, 1 << (cfg.OWIDTH - 1)
    wrapped = acc & mask
    return np.where(wrapped & sign_bit, wrapped - (1 << cfg.OWIDTH), wrapped), int(np.abs(acc).max())


def check_stim(tr: VartTrace, path: Path, shift: int) -> list[str]:
    tok = path.read_text().split()
    assert tok[0] == "CSAVARTSTIM", tok[:6]
    nb, nh, nw, k = map(int, tok[1:5]); pos = 6
    errs = []
    if (nb, nh, nw, k) != (tr.n_batches, tr.cfg.N_H, tr.cfg.N_W, tr.cfg.K):
        return [f"stimulus shape {(nb, nh, nw, k)} != trace"]
    for b in range(nb):
        vals = list(map(int, tok[pos:pos + 1 + 2 * nh * k + 2 * nw * k])); pos += len(vals)
        c, rest = vals[0], vals[1:]
        aq, as_, wq, ws = (rest[:nh * k], rest[nh * k:2 * nh * k], rest[2 * nh * k:2 * nh * k + nw * k],
                           rest[2 * nh * k + nw * k:])
        if c != tr.cycles[b]: errs.append(f"block {b}: cycles {tr.cycles[b]} != stim {c}")
        if list(tr.a_mag[b].ravel() >> shift) != aq or list(tr.a_mag[b].ravel() & ((1 << shift) - 1)) != [0] * len(aq):
            errs.append(f"block {b}: AMAG != stim")
        if list(tr.a_sign[b].ravel()) != as_: errs.append(f"block {b}: ASIGN != stim")
        if list(tr.w_mag[b].ravel() >> shift) != wq or list(tr.w_mag[b].ravel() & ((1 << shift) - 1)) != [0] * len(wq):
            errs.append(f"block {b}: WMAG != stim")
        if list(tr.w_sign[b].ravel()) != ws: errs.append(f"block {b}: WSIGN != stim")
    if pos != len(tok): errs.append("stimulus has trailing values")
    return errs


def check_af(tr: VartTrace, path: Path, shift: int) -> tuple[list[str], dict]:
    lines = [l.split() for l in path.read_text().splitlines() if l.split()]
    assert lines[0][0] == "CBSGAFSTREAM", lines[0]
    nblocks = int(lines[0][6])
    inv = lambda b: b - (1 if b >= 65 else 0)
    errs, i, alens = [], 2, []
    if nblocks != tr.n_batches:
        return [f"AF trace has {nblocks} blocks, CSA trace {tr.n_batches}"], {}
    for b in range(nblocks):
        f = lines[i]; assert f[0] == "BLOCK" and int(f[1]) == b
        c = int(f[2])
        amag = list(map(int, lines[i + 1][1:])); asg = list(map(int, lines[i + 2][1:]))
        alen = list(map(int, lines[i + 3][1:])); wmag = list(map(int, lines[i + 4][1:]))
        wsg = list(map(int, lines[i + 5][1:]))
        assert [lines[i + j][0] for j in range(1, 6)] == ["AMAG", "ASIGN", "ALEN", "WMAG", "WSIGN"]
        i += 6
        alens.append(alen)
        if any(x == 64 or not 0 <= x <= 128 for x in amag + wmag): errs.append(f"block {b}: AF b outside the map")
        if c != math.ceil(max(alen) / tr.cfg.M): errs.append(f"block {b}: AF cycles {c} != ceil(max L/16)")
        if tr.cycles[b] != c: errs.append(f"block {b}: CSA cycles {tr.cycles[b]} != AF {c}")
        if list(tr.a_mag[b].ravel()) != [inv(x) << shift for x in amag]: errs.append(f"block {b}: AMAG != AF |q|<<{shift}")
        if list(tr.a_sign[b].ravel()) != asg: errs.append(f"block {b}: ASIGN != AF")
        if list(tr.w_mag[b].ravel()) != [inv(x) << shift for x in wmag]: errs.append(f"block {b}: WMAG != AF |q|<<{shift}")
        if list(tr.w_sign[b].ravel()) != wsg: errs.append(f"block {b}: WSIGN != AF")
    af_window = next((int(f[1]) for f in lines[i:] if f[0] == "WINDOW"), None)
    if af_window is not None and tr.window != af_window:
        errs.append(f"CSA window {tr.window} != AF window {af_window}")
    return errs, dict(af_trace=str(path.resolve()), af_window=af_window,
                      af_mean_row_L=float(np.mean(alens)), af_blocks=nblocks)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("trace", type=Path)
    ap.add_argument("--stim", type=Path)
    ap.add_argument("--af-trace", type=Path)
    ap.add_argument("--json", type=Path)
    a = ap.parse_args()
    tr = parse_trace(a.trace)
    cfg = tr.cfg
    shift = cfg.WIDTH - 7
    errors = []
    total = sum(tr.cycles)
    if tr.window is not None and tr.window != total:
        errors.append(f"WINDOW {tr.window} != sum of block cycles {total}")
    expected, max_abs = reference(tr)
    wrong = int(np.count_nonzero(expected != tr.drain))
    if wrong:
        errors.append(f"{wrong} of {expected.size} drained accumulators differ from the cycle reference")
    extra = {}
    if a.stim:
        errors += check_stim(tr, a.stim, shift)
        extra["stim"] = str(a.stim.resolve())
    if a.af_trace:
        e, extra_af = check_af(tr, a.af_trace, shift)
        errors += e; extra.update(extra_af)
    hist = {}
    for c in tr.cycles: hist[str(c)] = hist.get(str(c), 0) + 1
    shape = f"K={cfg.K} M={cfg.M} N={cfg.N_H}x{cfg.N_W} blocks={tr.n_batches} window={total}"
    out = dict(trace=str(a.trace.resolve()), blocks=tr.n_batches, window_clocks=total, mean_cycles=total / tr.n_batches,
               cycle_histogram=dict(sorted(hist.items(), key=lambda kv: int(kv[0]))), accumulators=int(expected.size),
               wrong=wrong, max_abs_acc=max_abs, errors=errors[:50], n_errors=len(errors), **extra)
    if a.json:
        a.json.write_text(json.dumps(out, indent=2) + "\n")
    if not errors:
        print(f"[PASS] streaming CSA vart drain matches cycle reference ({shape})"
              + (" ; operands == stimulus" if a.stim else "") + (" ; operands/cycles == AF trace" if a.af_trace else ""))
        return 0
    print(f"[FAIL] streaming CSA vart check ({shape})")
    for e in errors[:20]:
        print("  ", e)
    if wrong:
        print("RTL drain:\n", tr.drain); print("expected:\n", expected); print("RTL - expected:\n", tr.drain - expected)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
