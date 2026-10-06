#!/usr/bin/env python3
"""Write the stimulus file of designs/payn/power/power_payn_array_csa_vart.sv.

Format (decimal, whitespace separated):
    CSAVARTSTIM <N_BLOCKS> <N_H> <N_W> <K> <MAG_WIDTH>
    one line per block: c  aq[N_H*K]  as[N_H*K]  wq[N_W*K]  ws[N_W*K]
aq/wq are logical 7-bit magnitudes |q| (the bench sends |q| << 1, as power_payn_array.sv does).

Sources:
  --from-af TRACE    the A-first C-BSG power trace (power_payn_array_cbsg_af.sv, CBSGAFSTREAM): per block the
                     same |q| and signs (the AF field b = round(|q|*128/127) = |q| + [|q| >= 64] is inverted:
                     |q| = b - [b >= 65]; b = 64 cannot occur), and c_b = the AF block's cycle count, checked to be
                     ceil(max row L / 16).  This is the CSA "ladder-equivalent": every row of block b runs for the
                     block's longest row.
  --from-csa TRACE   a power_payn_array.sv trace (STREAMCFG ... T ...): the same operands (m >> 1) and c = T/M
                     for every block -- the bench-copy reproduction control.
  --random N         N blocks, uniform |q| and signs, c uniform in [--cmin, --cmax] (RTL stress of the schedule).
A JSON summary (source sha256, blocks, window clocks, cycle histogram) goes to --json.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import random
from collections import Counter
from pathlib import Path

K, NH, NW, MAG_WIDTH, M = 8, 8, 8, 7, 16


def af_q(b: int) -> int:
    if not (0 <= b <= 128) or b == 64:
        raise ValueError(f"AF boundary {b} is not round(|q|*128/127) of a 7-bit |q|")
    q = b - (1 if b >= 65 else 0)
    assert q + (1 if q >= 64 else 0) == b
    return q


def tagged(lines, i, tag, n):
    f = lines[i]
    if f[0] != tag or len(f) != n + 1:
        raise ValueError(f"line {i + 1}: expected {tag} with {n} values, got {f[0]} with {len(f) - 1}")
    return [int(x) for x in f[1:]]


def from_af(path: Path):
    lines = [l.split() for l in path.read_text().splitlines() if l.split()]
    h = lines[0]
    if h[0] != "CBSGAFSTREAM":
        raise ValueError("not an AF power trace")
    k, m, nh, nw, ow, nblocks, chunk, wl = map(int, h[1:9])
    assert (k, m, nh, nw) == (K, M, NH, NW), h
    i = 2  # header, LADDER
    blocks = []
    for b in range(nblocks):
        f = lines[i]
        assert f[0] == "BLOCK" and int(f[1]) == b, f
        c = int(f[2]); i += 1
        amag = tagged(lines, i, "AMAG", nh * k); i += 1
        asg = tagged(lines, i, "ASIGN", nh * k); i += 1
        alen = tagged(lines, i, "ALEN", nh); i += 1
        wmag = tagged(lines, i, "WMAG", nw * k); i += 1
        wsg = tagged(lines, i, "WSIGN", nw * k); i += 1
        if c != math.ceil(max(alen) / M):
            raise ValueError(f"block {b}: cycles {c} != ceil(max L {max(alen)} / {M})")
        blocks.append(dict(c=c, aq=[af_q(x) for x in amag], as_=asg, wq=[af_q(x) for x in wmag], ws=wsg,
                           alen=alen))
    window = None
    for f in lines[i:]:
        if f[0] == "WINDOW":
            window = int(f[1])
    if window is not None and window != sum(bl["c"] for bl in blocks):
        raise ValueError(f"AF WINDOW {window} != sum of block cycles {sum(bl['c'] for bl in blocks)}")
    return blocks, dict(af_workload=wl, af_window=window, af_chunk_blocks=chunk,
                        mean_row_L=sum(sum(bl["alen"]) for bl in blocks) / (nh * nblocks))


def from_csa(path: Path):
    lines = [l.split() for l in path.read_text().splitlines() if l.split()]
    h = lines[0]
    assert h[0] == "STREAMCFG", h
    k, m, nh, nw, width, ow, t, nb = map(int, h[1:9])
    assert (k, m, nh, nw, width) == (K, M, NH, NW, 8) and t % m == 0, h
    c = t // m
    i = 1
    blocks = []
    for b in range(nb):
        assert lines[i] == ["BATCH", str(b)], lines[i]
        i += 1
        amag = tagged(lines, i, "AMAG", nh * k); i += 1
        asg = tagged(lines, i, "ASIGN", nh * k); i += 1
        wmag = tagged(lines, i, "WMAG", nw * k); i += 1
        wsg = tagged(lines, i, "WSIGN", nw * k); i += 1
        assert all(x % 2 == 0 for x in amag + wmag)
        blocks.append(dict(c=c, aq=[x >> 1 for x in amag], as_=asg, wq=[x >> 1 for x in wmag], ws=wsg))
    return blocks, dict(csa_T=t)


def random_blocks(n, seed, cmin, cmax):
    r = random.Random(seed)
    return [dict(c=r.randint(cmin, cmax), aq=[r.randrange(128) for _ in range(NH * K)],
                 as_=[r.randrange(2) for _ in range(NH * K)], wq=[r.randrange(128) for _ in range(NW * K)],
                 ws=[r.randrange(2) for _ in range(NW * K)]) for _ in range(n)], dict(seed=seed, cmin=cmin, cmax=cmax)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--from-af", type=Path)
    src.add_argument("--from-csa", type=Path)
    src.add_argument("--random", type=int)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--cmin", type=int, default=2)
    ap.add_argument("--cmax", type=int, default=8)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--json", type=Path, required=True)
    a = ap.parse_args()
    if a.from_af:
        blocks, extra = from_af(a.from_af); source = a.from_af
    elif a.from_csa:
        blocks, extra = from_csa(a.from_csa); source = a.from_csa
    else:
        blocks, extra = random_blocks(a.random, a.seed, a.cmin, a.cmax); source = None
    with a.out.open("w") as f:
        f.write(f"CSAVARTSTIM {len(blocks)} {NH} {NW} {K} {MAG_WIDTH}\n")
        for bl in blocks:
            f.write(" ".join(map(str, [bl["c"]] + bl["aq"] + bl["as_"] + bl["wq"] + bl["ws"])) + "\n")
    window = sum(bl["c"] for bl in blocks)
    summary = dict(stim=str(a.out.resolve()), stim_sha256=hashlib.sha256(a.out.read_bytes()).hexdigest(),
                   source=str(source.resolve()) if source else None,
                   source_sha256=hashlib.sha256(source.read_bytes()).hexdigest() if source else None,
                   blocks=len(blocks), window_clocks=window, mean_cycles=window / len(blocks),
                   cycle_histogram={str(k): v for k, v in sorted(Counter(bl["c"] for bl in blocks).items())},
                   mean_abs_q=sum(sum(bl["aq"]) + sum(bl["wq"]) for bl in blocks) / (len(blocks) * (NH + NW) * K),
                   **extra)
    a.json.write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary))


if __name__ == "__main__":
    main()
