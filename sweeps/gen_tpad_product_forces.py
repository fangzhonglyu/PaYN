#!/usr/bin/env python3
"""Emit force/release blocks that mask pad-lane PRODUCT nets in a GL netlist.

For padded-T execution (T % M != 0), the cheap masking point is the product
term inside each tile: product duty is q^2 (~6%) versus q (~50%) on the
operand-broadcast wires, so the mask's entry/exit transitions are ~8x cheaper
(see doc/results.md, "Padded T").  This script finds, in every uniquified
tile-module copy, the AND2 gate computing a_bits[i] & w_bits[i] for each
masked product index i (lane = i % M >= T % M), maps module copies to
instance paths, and writes a SystemVerilog include file with one
force/release block per net, keyed on the bench's pad_prod_mask_en.

Coverage is asserted: every tile copy must yield exactly K * PAD_LANES nets
from clean 2-input AND gates, or the script fails loudly rather than emit a
mask that silently misses products.

Usage:
  gen_tpad_product_forces.py NETLIST T [--k 8] [--m 16] [--out forces.svh]
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("netlist", type=Path)
    ap.add_argument("t", type=int)
    ap.add_argument("--k", type=int, default=8)
    ap.add_argument("--m", type=int, default=16)
    ap.add_argument("--tile-prefix", default="InnerTileSignedSegmented")
    ap.add_argument("--out", type=Path, required=True)
    args = ap.parse_args()

    pad_lanes = (-args.t) % args.m
    if pad_lanes == 0:
        args.out.write_text("// T is a multiple of M: no product masking\n")
        print("T multiple of M; empty force file written")
        return 0
    live = args.t % args.m  # lanes >= live are dead

    txt = args.netlist.read_text()

    # 1. masked product forces per tile-module copy.  Synthesis implements
    # each product a&w in one of two shapes:
    #   plain:  AND2(.A(w[i]), .B(a[i])) -> and_i      mask: force Y = 0
    #   paired: NAND2(w[i], a[i]) -> ~and_i            mask: force Y = 1
    #           NAND2(w[j], a[j]) -> ~and_j            mask: force Y = 1
    #           AND4(w[i],a[i],w[j],a[j]) -> and_i&and_j  mask: force Y = 0
    # Forcing the NAND to 0 (as a naive "product net" match would) asserts
    # and=1 on the enc_lo path -- that bug produced deterministic drain
    # corruption.  Every masked index must resolve to exactly one shape.
    inst_pins = re.compile(r'(\w+)\s+(\S+)\s*\(((?:[^()]|\([^()]*\))*)\)\s*;')
    bit_re = re.compile(r'\.(\w+)\(([aw])_bits\[(\d+)\]\)')
    y_re = re.compile(r'\.Y\((\w+)\)')
    mod_forces: dict[str, list[tuple[str, int]]] = {}
    for mm in re.finditer(
            rf'module\s+({re.escape(args.tile_prefix)}\w*)\s*\((.*?)endmodule',
            txt, re.S):
        name, body = mm.group(1), mm.group(2)
        and2: dict[int, str] = {}    # idx -> Y of plain AND2
        nand2: dict[int, str] = {}   # idx -> Y of NAND2(~and)
        and4: dict[frozenset, str] = {}  # {i, j} -> Y of pair AND4
        for cell, iname, pins in inst_pins.findall(body):
            bits = bit_re.findall(pins)
            if not bits:
                continue
            idxs = {}
            for _pin, op, i in bits:
                idxs.setdefault(int(i), set()).add(op)
            full = [i for i, ops in idxs.items() if ops == {'a', 'w'}]
            ym = y_re.search(pins)
            if cell.startswith('AND2') and len(full) == 1 and len(idxs) == 1:
                if full[0] in and2:
                    raise SystemExit(f"{name}: duplicate AND2 for {full[0]}")
                and2[full[0]] = ym.group(1)
            elif cell.startswith('NAND2') and len(full) == 1 and len(idxs) == 1:
                if full[0] in nand2:
                    raise SystemExit(f"{name}: duplicate NAND2 for {full[0]}")
                nand2[full[0]] = ym.group(1)
            elif cell.startswith('AND4') and len(full) == 2 and len(idxs) == 2:
                and4[frozenset(full)] = ym.group(1)
            elif cell.startswith(('ANTENNA', 'DIODE', 'DCAP')):
                continue
            elif ym:
                raise SystemExit(
                    f"{name}: unrecognized product-shape cell {cell} {iname}: "
                    f"{' '.join(pins.split())[:120]}")
        pair_of = {}
        for pair, y in and4.items():
            for i in pair:
                pair_of[i] = (pair, y)
        forces: dict[str, int] = {}
        covered = 0
        for i in range(args.k * args.m):
            lane = i % args.m
            in_and2, in_pair = i in and2, i in pair_of
            if in_and2 == in_pair:
                raise SystemExit(f"{name}: product {i} covered by "
                                 f"and2={in_and2} pair={in_pair}")
            covered += 1
            if lane < live:
                continue
            if in_and2:
                forces[and2[i]] = 0
            else:
                if i not in nand2:
                    raise SystemExit(f"{name}: paired product {i} has no NAND2")
                forces[nand2[i]] = 1
                forces[pair_of[i][1]] = 0   # shared AND4; both members agree
        assert covered == args.k * args.m
        mod_forces[name] = sorted(forces.items())

    if not mod_forces:
        raise SystemExit("no tile modules found")

    # 2. instance paths: tile instances inside their parent, parent under u_pe
    inst_re = re.compile(r'(\w+)\s+(\S+)\s*\(\s*\.')
    parents: dict[str, list[tuple[str, str]]] = {}  # parent module -> [(inst, tilemod)]
    for mm in re.finditer(r'module\s+(\w+)\s*\((.*?)endmodule', txt, re.S):
        pname, body = mm.group(1), mm.group(2)
        for cell, inst in inst_re.findall(body):
            if cell in mod_forces:
                parents.setdefault(pname, []).append((inst, cell))
    if len(parents) != 1:
        raise SystemExit(f"tile instances span {len(parents)} parent modules: "
                         f"{sorted(parents)}; expected exactly one")
    (parent_mod, tiles), = parents.items()

    # parent's own instance path under dut (expect u_pe/<inst>)
    path_re = re.compile(rf'{re.escape(parent_mod)}\s+(\S+)\s*\(')
    hops = path_re.findall(txt)
    hops = [h for h in hops if not h.startswith('.')]
    if len(hops) != 1:
        raise SystemExit(f"expected one instance of {parent_mod}, got {hops}")
    core_inst = hops[0]

    total = 0
    lines = [
        "// generated by sweeps/gen_tpad_product_forces.py -- do not edit",
        f"// netlist: {args.netlist}",
        f"// T={args.t} M={args.m} K={args.k} pad_lanes={pad_lanes}: "
        f"masking {args.k * pad_lanes} products/tile across {len(tiles)} tiles",
    ]
    for inst, tilemod in sorted(tiles):
        base = f"dut.u_pe.{core_inst}.{inst}"
        for net, val in mod_forces[tilemod]:
            lines.append(
                f"always @(pad_prod_mask_en) "
                f"if (pad_prod_mask_en) force {base}.{net} = 1'b{val}; "
                f"else release {base}.{net};")
            total += 1
    args.out.write_text("\n".join(lines) + "\n")
    print(f"wrote {args.out}: {total} net forces "
          f"({len(tiles)} tiles, {args.k * pad_lanes} masked products each)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
