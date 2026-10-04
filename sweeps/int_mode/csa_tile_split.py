#!/usr/bin/env python3
"""Functional area split of one synthesized CSA tile (no EDA tools needed).

Parses tile00 (InnerTileSignedSegmentedCsa_..._63) out of the matched DC
netlist syn/build/TSMC22/PAYN_SC_CSA/csa_20261002/payn_array_signed_segmented_csa.syn.v,
uses LEF footprint areas (the same numbers PT reports in
build/area_anatomy/csa_syn_area_anatomy.rpt), and attributes every leaf cell to
one bucket by structural cone tracing:

  product_and      AND2 whose inputs are both tile a_bits/w_bits ports
  counters         the 8 PaynPopcount16Csa sub-instances (11 FA each)
  lane_sign_xor    XOR/XNOR with a popcount output as a direct input
  sign_glue        cells whose fan-in is only a_signs/w_signs (a^w, countones,
                   -16*N row encode)
  high_segment     cells in the fan-in of acc_out[23:9] whose cone touches
                   acc_high/pending flags but no popcount/heap net
  drain_mux        cells whose input is acc_in or that drive a state flop D pin
                   and take shift_in/reset glue
  heap_cpa         everything else in the low-sum cone (DW02_tree + final adder +
                   carry/borrow decode)
  flops / icg      state registers and the tile clock gate

Usage: python3 sweeps/int_mode/csa_tile_split.py
"""
import collections
import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
NL = REPO / "syn/build/TSMC22/PAYN_SC_CSA/csa_20261002/payn_array_signed_segmented_csa.syn.v"
TILE = "InnerTileSignedSegmentedCsa_K8_M16_OWIDTH24_LOW_W9_63"

# Footprint areas (um2) from the A7 SVT C30 base/HPK LEFs, identical to the PT
# per-reference areas in build/area_anatomy/csa_syn_area_anatomy.rpt.
AREA = {
    "ADDF_X1M": 1.666, "ADDF_X1P4M": 1.862, "ADDH_X1M": 0.98,
    "AND2_X1M": 0.392, "AND3_X1M": 0.49, "AO22_X1M": 0.686,
    "AOI21_X1A": 0.392, "BUFH_X1M": 0.294, "DFFQA2W_X1M": 2.744,
    "DFFQA_X1M": 1.47, "INV_X1M": 0.196, "NAND2XB_X1M": 0.392,
    "NAND3BB_X1M": 0.49, "NOR2XB_X1M": 0.392, "NOR2_X1A": 0.294,
    "NOR4BB_X1M": 0.588, "OR2_X1M": 0.392, "PREICG_X0P5B": 1.47,
    "TIELO_X1M": 0.392, "XNOR2_X0P7M": 0.588, "XOR2_X0P7M": 0.588,
    "XOR3_X0P7M": 1.176,
}
OUT_PINS = {"Y", "S", "CO", "Q", "Q0", "Q1", "ENCLK", "GCLK"}


def read_module(text, name):
    m = re.search(r"^\s*module\s+%s\b.*?^endmodule" % re.escape(name), text, re.S | re.M)
    if not m:
        sys.exit(f"module {name} not found")
    return m.group(0)


def parse_cells(body):
    # Join statements on ';' and pick instance statements "TYPE inst ( .P(n), ... );"
    stmts = body.replace("\n", " ").split(";")
    cells = []
    for s in stmts:
        s = s.strip()
        m = re.match(r"([A-Za-z_][\w]*)\s+([\\\w\[\]\.]+)\s*\((.*)\)\s*$", s)
        if not m or m.group(1) in ("input", "output", "wire", "module", "assign"):
            continue
        typ, inst, pins = m.groups()
        pinmap = dict(re.findall(r"\.(\w+)\s*\(\s*([^()]*?)\s*\)", pins))
        cells.append((typ, inst, pinmap))
    return cells


def main():
    text = NL.read_text()
    body = read_module(text, TILE)
    cells = parse_cells(body)

    leaf, subs = [], []
    for typ, inst, pins in cells:
        short = typ.replace("_A7PP140ZTS_C30", "")
        if short in AREA:
            leaf.append((short, inst, pins))
        else:
            subs.append((typ, inst, pins))

    driver = {}
    readers = collections.defaultdict(list)
    for idx, (typ, inst, pins) in enumerate(leaf):
        for p, n in pins.items():
            if p in OUT_PINS:
                driver[n] = idx
            else:
                readers[n].append(idx)

    pop_out = set()
    for typ, inst, pins in subs:
        if "Popcount16Csa" in typ:
            pop_out.update(v for k, v in pins.items() if k.startswith("s"))
    product_nets = set()
    for typ, inst, pins in subs:
        if "Popcount16Csa" in typ:
            # .bits_in(g_lanes_i__products) is a bus; the AND2 outputs are its bits
            product_nets.add(pins["bits_in"])

    def is_port(n, prefix):
        return n.startswith(prefix + "[") or n == prefix

    bucket = {}
    # 1) flops, ICG
    for i, (t, inst, pins) in enumerate(leaf):
        if t.startswith("DFF"):
            bucket[i] = "flops"
        elif t.startswith("PREICG"):
            bucket[i] = "icg"
    # 2) product ANDs
    for i, (t, inst, pins) in enumerate(leaf):
        if i in bucket:
            continue
        ins = [n for p, n in pins.items() if p not in OUT_PINS]
        if t.startswith("AND2") and all(is_port(n, "a_bits") or is_port(n, "w_bits") for n in ins):
            bucket[i] = "product_and"

    # fan-in source classes, memoized
    memo = {}

    def sources(net, depth=0):
        if net in memo:
            return memo[net]
        if net in pop_out:
            r = frozenset({"pop"})
        elif is_port(net, "a_signs") or is_port(net, "w_signs"):
            r = frozenset({"sign"})
        elif is_port(net, "acc_in"):
            r = frozenset({"acc_in"})
        elif net in ("shift_in", "reset", "mac_en"):
            r = frozenset({"ctl"})
        elif net.startswith("acc_high[") or net in ("pending_carry", "pending_borrow"):
            r = frozenset({"high"})
        elif re.match(r"acc_out\[[0-8]\]$", net) and driver.get(net) is not None and leaf[driver[net]][0].startswith("DFF"):
            r = frozenset({"low_q"})
        elif net in driver:
            i = driver[net]
            t, inst, pins = leaf[i]
            if t.startswith("DFF"):
                r = frozenset({"state"})
            else:
                acc = set()
                memo[net] = frozenset()  # cycle guard
                for p, n in pins.items():
                    if p not in OUT_PINS:
                        acc |= sources(n, depth + 1)
                r = frozenset(acc)
        else:
            r = frozenset({"const"}) if net in ("n_Logic0_", "1'b0", "1'b1") else frozenset({"other"})
        memo[net] = r
        return r

    for i, (t, inst, pins) in enumerate(leaf):
        if i in bucket:
            continue
        ins = [n for p, n in pins.items() if p not in OUT_PINS]
        src = set()
        for n in ins:
            src |= sources(n)
        if any(n in pop_out for n in ins) and (t.startswith("XOR") or t.startswith("XNOR")):
            bucket[i] = "lane_sign_xor"
        elif src <= {"sign", "const"}:
            bucket[i] = "sign_glue"
        elif "acc_in" in src or (t.startswith("AO22")):
            bucket[i] = "drain_mux"
        elif src <= {"ctl", "const"}:
            bucket[i] = "control_glue"
        elif "high" in src and not ({"pop", "sign", "low_q"} & src):
            bucket[i] = "high_segment"
        elif src <= {"high", "ctl", "const", "state"}:
            bucket[i] = "control_glue"
        else:
            bucket[i] = "heap_cpa"

    # Split heap_cpa.  Final CPA = adders whose S drives a low-half drain AO22
    # (A1 pin; B1 is acc_in[0..8]); the pending carry/borrow decode = heap_cpa
    # cells in the fan-in of the pending flop D pins that are not CPA adders.
    cpa = set()
    for i, (t, inst, pins) in enumerate(leaf):
        if t.startswith("AO22") and re.match(r"acc_in\[[0-8]\]$", pins.get("B1", "")):
            d = driver.get(pins["A1"])
            if d is not None and bucket.get(d) == "heap_cpa":
                cpa.add(d)
    # top adder whose CO feeds the decode also belongs to the CPA chain (already
    # included when its S drives acc_low[8]'s mux).
    for d in cpa:
        bucket[d] = "final_cpa"
    pend_d = [pins["D"] for t, inst, pins in leaf
              if t.startswith("DFFQA_") and inst.startswith("pending_")]
    stack, seen = list(pend_d), set()
    while stack:
        n = stack.pop()
        if n in seen or n not in driver:
            continue
        seen.add(n)
        i = driver[n]
        if bucket.get(i) == "heap_cpa":
            t, inst, pins = leaf[i]
            if not (t.startswith("ADDF") or t.startswith("ADDH")):
                bucket[i] = "carry_borrow_decode"
                stack.extend(v for p, v in pins.items() if p not in OUT_PINS)
        elif bucket.get(i) in ("control_glue",):
            continue
    for i in range(len(leaf)):
        if bucket[i] == "heap_cpa":
            bucket[i] = "heap_dw02_tree"

    res = collections.OrderedDict()
    for i, (t, inst, pins) in enumerate(leaf):
        b = bucket[i]
        res.setdefault(b, collections.Counter())[t] += 1

    out = {}
    total = 0.0
    for b, c in res.items():
        a = sum(AREA[t] * n for t, n in c.items())
        total += a
        out[b] = {"cells": dict(c), "area_um2": round(a, 3)}
    # counters from sub-instances: 88 FAs (54 X1M + 34 X1P4M in tile00 per PT)
    sub_fa = collections.Counter()
    for typ, inst, pins in subs:
        if "Popcount16Csa" in typ:
            sub_body = read_module(text, typ)
            for st, si, sp in parse_cells(sub_body):
                fa_body = read_module(text, st)
                for ft, fi, fp in parse_cells(fa_body):
                    sub_fa[ft.replace("_A7PP140ZTS_C30", "")] += 1
    ca = sum(AREA[t] * n for t, n in sub_fa.items())
    out["counters"] = {"cells": dict(sub_fa), "area_um2": round(ca, 3)}
    total += ca
    # SNPS clock gate sub-instance
    for typ, inst, pins in subs:
        if "CLOCK_GATE" in typ:
            cg = read_module(text, typ)
            for ct, ci, cp in parse_cells(cg):
                s = ct.replace("_A7PP140ZTS_C30", "")
                out.setdefault("icg", {"cells": {}, "area_um2": 0.0})
                out["icg"]["cells"][s] = out["icg"]["cells"].get(s, 0) + 1
                out["icg"]["area_um2"] = round(out["icg"]["area_um2"] + AREA[s], 3)
                total += AREA[s]
    out["_total_um2"] = round(total, 3)
    print(json.dumps(out, indent=1))


if __name__ == "__main__":
    main()
