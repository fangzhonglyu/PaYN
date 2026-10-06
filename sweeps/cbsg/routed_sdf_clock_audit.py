#!/usr/bin/env python3
"""Clock-gate delay audit of an SDF: is the ideal-clock view of the pre-layout C-BSG GL runs needed here?

The C-BSG post-synthesis GL runs (sweeps/cbsg/{af,rg}/run_syn_gl_checks.sh) had to zero the CK->ECK IOPATHs of
the integrated clock gates (sweeps/cbsg/{af,rg}/sdf_ideal_clock.py): DC's SDF gives the unbuffered shared ICGs
2.8-3.8 ns into hundreds of clock pins, longer than the 2.5 ns period, so no gated pulse survives.  After clock
tree synthesis the ICGs are cloned and drive buffered trees (the PAYN_SC_CSA pinned route: 118 PREICG instances,
CK->ECK 0.03-0.04 ns), so the routed SDF must be simulated as written.  This script proves that for one SDF:
every ICG cell (CELLTYPE matching --icg-regex) and its worst IOPATH delay; PASS iff the worst is below
--max-fraction (default 0.5) of the period.  With --sim-log it also proves the GL run annotated exactly this
file (the flow's "sdf     = <path>" line and VCS's '***    SDF file: "<path>"' banner), i.e. that no rewritten view
was used.

  python3 sweeps/cbsg/routed_sdf_clock_audit.py ROUTE.apr.sdf --period-ns 2.5 [--sim-log simulation.log] --json OUT
"""
import argparse
import json
import re
import sys
from pathlib import Path

ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
ap.add_argument('sdf', type=Path)
ap.add_argument('--period-ns', type=float, required=True)
ap.add_argument('--max-fraction', type=float, default=0.5)
ap.add_argument('--icg-regex', default=r'ICG')
ap.add_argument('--sim-log', type=Path)
ap.add_argument('--json', type=Path, required=True)
a = ap.parse_args()

icg = re.compile(a.icg_regex)
cell_re = re.compile(r'\(CELLTYPE\s+"([^"]+)"\)\s*\(INSTANCE\s*([^)]*)\)')
num = re.compile(r'-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?')
text = a.sdf.read_text(errors='replace')
cells = []
for m in cell_re.finditer(text):
    if not icg.search(m[1]):
        continue
    start = m.end()
    nxt = text.find('(CELL', start)
    end = nxt if nxt >= 0 else len(text)
    tc = text.find('(TIMINGCHECK', start, end)
    block = text[start:tc if tc >= 0 else end]
    vals = [float(x) for line in block.splitlines() if 'IOPATH' in line
            for x in num.findall(line.split('IOPATH', 1)[1])]
    cells.append(dict(instance=m[2].strip(), celltype=m[1], worst_iopath_ns=max(vals) if vals else None))
limit = a.max_fraction * a.period_ns
timed = [c for c in cells if c['worst_iopath_ns'] is not None]
worst = max((c['worst_iopath_ns'] for c in timed), default=None)
reasons = []
if not timed:
    reasons.append('no clock-gate cell with IOPATH delays found')
elif worst >= limit:
    reasons.append(f'worst clock-gate IOPATH {worst:.3f} ns >= {limit:.3f} ns: the ideal-clock problem is present')
out = dict(sdf=str(a.sdf.resolve()), period_ns=a.period_ns, limit_ns=limit, icg_cells=len(cells),
           icg_cells_with_iopath=len(timed), worst_icg_iopath_ns=worst,
           worst_cells=sorted(timed, key=lambda c: -c['worst_iopath_ns'])[:8])
if a.sim_log:
    log = a.sim_log.read_text(errors='replace')
    m = re.search(r'^\s*sdf\s*=\s*(\S+)', log, re.M)
    ann = re.search(r'\*\*\*\s+SDF file:\s*"([^"]+)"', log)      # VCS's $sdf_annotate banner
    used = m[1] if m else None
    out.update(sim_log=str(a.sim_log.resolve()), sdf_used_by_gl=used,
               sdf_annotated=ann[1] if ann else None)
    if not used or Path(used).resolve() != a.sdf.resolve():
        reasons.append(f'GL compiled against {used}, not {a.sdf}')
    if not ann or Path(ann[1]).resolve() != a.sdf.resolve():
        reasons.append(f'bench annotated {ann[1] if ann else None}, not {a.sdf}')
out['status'] = 'FAIL' if reasons else 'PASS'
out['reasons'] = reasons
a.json.write_text(json.dumps(out, indent=2) + '\n')
print(f"[{out['status']}] {len(cells)} clock-gate cells, worst CK->ECK {worst if worst is None else round(worst, 3)} ns "
      f"(limit {limit:.3f} ns){'; ' + '; '.join(reasons) if reasons else ''}")
sys.exit(1 if reasons else 0)
