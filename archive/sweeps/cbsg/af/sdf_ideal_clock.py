#!/usr/bin/env python3
"""Ideal-clock view of a DC synthesis SDF, for gate-level simulation of a synthesized (pre-CTS) netlist.

DC times the clock network as ideal: zero latency through the clock-gating cells (report_timing shows
"clock network delay (ideal) 0.00"), and it never buffers a gated clock.  The SDF it writes nevertheless gives
every integrated clock gate (ICG) its real CK->ECK delay into the unbuffered gated-clock net.  On the PaYN arrays
the shared ICGs (u_pe/u_array_core/clk_gate_acc_low_reg_0_: all 64 tiles' acc_low flops; the edge's operand-
register gates) drive hundreds of clock pins at X0P5 drive and get CK->ECK = 2.8-3.8 ns, longer than the 2.5 ns
period, so VCS's inertial delay swallows every gated clock pulse and those flops never leave power-up X.  This is
a pre-CTS artifact (the baseline PAYN_SC_CSA synthesis SDF has the same 3.28 ns gate); APR's clock tree replaces it.

This script writes a copy of the SDF in which only the IOPATH delays of ICG cells (CELLTYPE matching --icg-regex)
are set to 0, i.e. the clock model STA used; every data-path delay and every timing check is kept as written.
It prints the zeroed instances with their original worst delay.

  python3 sweeps/cbsg/af/sdf_ideal_clock.py IN.syn.sdf OUT.syn.sdf [--report OUT.txt]
"""
import argparse
import re
from pathlib import Path

ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
ap.add_argument("sdf_in", type=Path)
ap.add_argument("sdf_out", type=Path)
ap.add_argument("--icg-regex", default=r"ICG")
ap.add_argument("--report", type=Path, default=None)
args = ap.parse_args()

text = args.sdf_in.read_text()
icg = re.compile(args.icg_regex)
cell_re = re.compile(r'\(CELL\s*\(CELLTYPE "([^"]+)"\)\s*\(INSTANCE ([^)]*)\)')
trip = re.compile(r"\((-?[\d.]+):(-?[\d.]+):(-?[\d.]+)\)")
out = []
pos = 0
zeroed = []
for m in cell_re.finditer(text):
    if not icg.search(m[1]):
        continue
    # the DELAY section of this cell: from the match to its TIMINGCHECK (or the next CELL)
    start = m.end()
    nxt = text.find("(CELL", start)
    end = nxt if nxt >= 0 else len(text)
    tc = text.find("(TIMINGCHECK", start, end)
    dend = tc if tc >= 0 else end
    block = text[start:dend]
    vals = [float(x) for t in trip.findall(block) for x in t]
    new_block = trip.sub("(0.000:0.000:0.000)", block)
    out.append(text[pos:start])
    out.append(new_block)
    pos = dend
    zeroed.append((max(vals) if vals else 0.0, m[2], m[1]))
out.append(text[pos:])
args.sdf_out.parent.mkdir(parents=True, exist_ok=True)
args.sdf_out.write_text("".join(out))
zeroed.sort(reverse=True)
lines = [f"{args.sdf_in} -> {args.sdf_out}: zeroed the IOPATH delays of {len(zeroed)} ICG cells "
         f"({sum(1 for z in zeroed if z[0] > 0.5)} had CK->ECK > 0.5 ns); data paths and timing checks unchanged"]
lines += [f"  {d:.3f} ns  {inst}  ({ct})" for d, inst, ct in zeroed[:8]]
print("\n".join(lines))
if args.report:
    args.report.write_text("\n".join(lines + [f"  {d:.3f} ns  {inst}  ({ct})" for d, inst, ct in zeroed[8:]]) + "\n")
