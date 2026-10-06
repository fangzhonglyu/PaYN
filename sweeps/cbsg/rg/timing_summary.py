#!/usr/bin/env python3
"""DC timing summary of a C-BSG RG synthesis run (timing.rpt = report_timing -max_paths 10000, one path per endpoint).

Prints WNS / violating endpoints, the endpoint-slack histogram by startpoint and endpoint class, and the stage split
of the worst path (control fan-out -> prefix chain (ADDH) -> Gray/k-direction XOR map -> W compare -> CSA tile).
  python3 sweeps/cbsg/rg/timing_summary.py [RUN_DIR]
"""
import re
import sys
from collections import Counter
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
run = Path(sys.argv[1]) if len(sys.argv) > 1 else REPO / "syn/build/TSMC22/PAYN_SC_CSA_CBSG_RG/cbsg_rg_20261005"
text = (run / "timing.rpt").read_text(errors="replace")
paths = re.split(r"\n\s*Startpoint: ", text)[1:]


def norm(name):
    name = re.sub(r"^u_pe/u_array_core/g_row_\d+__g_col_\d+__u_inner/", "tile/", name)
    name = re.sub(r"^u_pe/u_array_core/", "core/", name)
    return re.sub(r"\d+", "N", name)


rows = []
for p in paths:
    sp = p.split()[0]
    ep = re.search(r"Endpoint: (\S+)", p)[1]
    sl = float(re.search(r"slack \((?:MET|VIOLATED)[^)]*\)\s+(-?[\d.]+)", p)[1])
    rows.append((sl, sp, ep, p))
rows.sort(key=lambda r: r[0])
print(f"{run}: {len(rows)} endpoints reported; WNS {rows[0][0]:+.2f} ns; "
      f"violating {sum(r[0] < 0 for r in rows)}; TNS {sum(min(r[0], 0) for r in rows):.2f} ns")
for lim in (0.10, 0.20, 0.30, 0.50):
    sel = [r for r in rows if r[0] < lim]
    st = Counter(norm(r[1]) for r in sel)
    en = Counter(norm(r[2]) for r in sel)
    print(f"  slack < {lim:.2f} ns: {len(sel):4d} endpoints; startpoints {dict(st.most_common(4))}; "
          f"endpoints {dict(en.most_common(4))}")
by_start = {}
for r in rows:
    by_start.setdefault(norm(r[1]), r[0])
print("  worst slack per startpoint class: " + ", ".join(f"{k} {v:+.2f}" for k, v in sorted(by_start.items(), key=lambda kv: kv[1])[:10]))

# Stage split of the worst path.
p = rows[0][3]
pts = re.findall(r"^\s+(\S+) \((\S+)\)\s*\n?\s*(-?[\d.]+)\s+(-?[\d.]+) [rf]", p, re.M)
stages = []          # (stage, incr, cell)
stage = "launch"
for pin, ref, inc, at in pts:
    inc = float(inc)
    if "/w_bits[" in pin:
        stage = "tile"
    elif stage != "tile":
        if ref.startswith("ADDH"):
            stage = "prefix"
        elif ref.startswith("XOR") and stage in ("prefix", "map"):
            stage = "map"
        elif stage in ("map", "compare"):
            stage = "compare"
        elif stage == "launch" and not re.search(r"/(CK|Q\d?|QN\d?)$", pin):
            stage = "fanout"
    stages.append((stage, inc, ref))
tot = Counter()
cells = Counter()
for s, inc, ref in stages:
    tot[s] += inc
    cells[s] += 1
dly = sum(inc for s, inc, ref in stages if ref.startswith("DLY"))
arr = re.search(r"data arrival time\s+([\d.]+)", p)[1]
print(f"  worst path {rows[0][1]} -> {rows[0][2]} (arrival {arr} ns):")
for s in ("launch", "fanout", "prefix", "map", "compare", "tile"):   # fanout = control buffering + j mux
    if cells[s]:
        print(f"    {s:8s} {tot[s]:.2f} ns over {cells[s]} cells")
print(f"    of which DLY cells {dly:.2f} ns")
