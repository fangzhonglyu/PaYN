#!/usr/bin/env python3
"""Basin QoR gate and pin-survival proof for one routed single-PE SC layout.

Reuses the SC power regression investigation's DEF parser
(build/sc_power_regression/physical/def_parse.py) and its metric definitions:
  * corr(tile x, column): tile centroid = mean of all components under
    u_pe/u_array_core/g_row_h__g_col_v__u_inner/ (tile_place.py);
  * d_col / d_row / tile radius: same, without FILL/DECAP/ANTENNA cells
    (pop_summary.py);
  * routed wire length: sum of DEF route segment lengths (def_parse.py);
  * mean |a - w skew| at the product AND2s: per-pin arrival
    max(rise, fall), skew = w - a (skew_glitch.py / netpower skew.py), from
    sweeps/pinned_pass2/basin_skew_pt.tcl.
Gate (README rank 1): grid basin iff corr >= 0.8 and mean |skew| <= 50 ps.

With --plan (the PRE_PLACE pin plan, sc_pin_plan.tsv) it also proves that
every top-level pin in the final DEF is FIXED at exactly the planned layer and
location.
Usage: basin_gate.py --def D --skew T [--plan P] --label L --json OUT
"""
from __future__ import annotations

import argparse
import collections
import csv
import json
import math
import re
import statistics
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'build/sc_power_regression/physical'))
import def_parse  # noqa: E402

TILE = re.compile(r'^u_pe/u_array_core/g_row_(\d+)__g_col_(\d+)__u_inner/')


def corr(a, b):
    ma, mb = sum(a) / len(a), sum(b) / len(b)
    sa = math.sqrt(sum((x - ma) ** 2 for x in a))
    sb = math.sqrt(sum((y - mb) ** 2 for y in b))
    return sum((x - ma) * (y - mb) for x, y in zip(a, b)) / (sa * sb)


def tile_metrics(d):
    allc = collections.defaultdict(list)
    logic = collections.defaultdict(list)
    for name, (cell, x, y, _src) in d['comps'].items():
        m = TILE.match(name)
        if not m or x is None:
            continue
        key = (int(m[1]), int(m[2]))
        allc[key].append((x, y))
        if not cell.startswith(('FILL', 'DECAP', 'ANTENNA')):
            logic[key].append((x, y))
    keys = sorted(allc)
    cx = [sum(p[0] for p in allc[k]) / len(allc[k]) for k in keys]
    cy = [sum(p[1] for p in allc[k]) / len(allc[k]) for k in keys]
    hs = [k[0] for k in keys]
    vs = [k[1] for k in keys]
    c = {k: (sum(p[0] for p in v) / len(v), sum(p[1] for p in v) / len(v)) for k, v in logic.items()}
    rad = [math.sqrt(sum((x - c[k][0]) ** 2 + (y - c[k][1]) ** 2 for x, y in v) / len(v)) for k, v in logic.items()]
    nh = max(hs) + 1
    nw = max(vs) + 1
    dist = lambda a, b: math.hypot(c[a][0] - c[b][0], c[a][1] - c[b][1])
    dcol = [dist((h, v), (h, v + 1)) for h in range(nh) for v in range(nw - 1)]
    drow = [dist((h, v), (h + 1, v)) for h in range(nh - 1) for v in range(nw)]
    grid = {f'{h},{v}': [round(c[(h, v)][0], 1), round(c[(h, v)][1], 1)] for h, v in sorted(c)}
    return dict(tiles=len(keys), nh=nh, nw=nw,
                corr_x_col=corr(cx, vs), corr_y_negrow=corr(cy, [-h for h in hs]),
                corr_x_negrow=corr(cx, [-h for h in hs]), corr_y_col=corr(cy, vs),
                d_col_um=sum(dcol) / len(dcol), d_row_um=sum(drow) / len(drow),
                tile_radius_um=sum(rad) / len(rad), tile_centroids=grid)


def skew_metrics(path):
    rows = list(csv.DictReader(open(path), delimiter='\t'))
    assert rows, f'no product ANDs in {path}'
    sk = [(float(r['w_arr']) - float(r['a_arr'])) * 1000 for r in rows]
    ab = sorted(abs(s) for s in sk)
    n = len(rows)
    per_tile = collections.defaultdict(list)
    for r, s in zip(rows, sk):
        per_tile[(int(r['tile_row']), int(r['tile_col']))].append(abs(s))
    return dict(product_ands=n,
                a_arr_mean_ps=statistics.mean(float(r['a_arr']) for r in rows) * 1000,
                w_arr_mean_ps=statistics.mean(float(r['w_arr']) for r in rows) * 1000,
                skew_mean_ps=statistics.mean(sk), abs_skew_mean_ps=statistics.mean(ab),
                abs_skew_p50_ps=ab[n // 2], abs_skew_p90_ps=ab[int(0.9 * n)],
                a_slew_mean_ps=statistics.mean(float(r['a_slew']) for r in rows if r['a_slew']) * 1000,
                w_slew_mean_ps=statistics.mean(float(r['w_slew']) for r in rows if r['w_slew']) * 1000,
                worst_tile_abs_skew_ps=max(sum(v) / len(v) for v in per_tile.values()))


def def_pin_status(path):
    pins, buf, section = {}, '', False
    with open(path, errors='replace') as f:
        for line in f:
            if line.startswith('PINS '):
                section = True
                continue
            if line.startswith('END PINS'):
                break
            if not section:
                continue
            buf += line
            if line.rstrip().endswith(';'):
                name = re.match(r'\s*-\s+(\S+)', buf)[1]
                lay = re.search(r'\+ LAYER (\S+)', buf)
                st = re.search(r'\+ (FIXED|PLACED|COVER)\s*\(\s*(-?\d+)\s+(-?\d+)\s*\)\s*(\S+)', buf)
                pins[name] = (lay[1] if lay else None, st[1] if st else 'UNPLACED',
                              int(st[2]) if st else None, int(st[3]) if st else None)
                buf = ''
    return pins


def pin_proof(def_path, plan_path, units):
    pins = def_pin_status(def_path)
    plan = list(csv.DictReader(open(plan_path), delimiter='\t'))
    bad = []
    for r in plan:
        d = pins.get(r['pin'])
        want = (r['layer'], 'FIXED', round(float(r['x']) * units), round(float(r['y']) * units))
        if d != want:
            bad.append({'pin': r['pin'], 'planned': want, 'def': d})
    edges = collections.Counter(r['edge'] for r in plan)
    return dict(def_pins=len(pins), planned_pins=len(plan),
                fixed_in_def=sum(1 for v in pins.values() if v[1] == 'FIXED'),
                unplanned_def_pins=sorted(set(pins) - {r['pin'] for r in plan})[:20],
                mismatches=len(bad), mismatch_examples=bad[:20], planned_by_edge=dict(edges),
                status='PASS' if not bad and len(pins) == len(plan) else 'FAIL')


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--def', dest='def_path', required=True)
    ap.add_argument('--skew', required=True)
    ap.add_argument('--plan')
    ap.add_argument('--label', required=True)
    ap.add_argument('--json', required=True)
    ap.add_argument('--min-corr', type=float, default=0.8)
    ap.add_argument('--max-skew-ps', type=float, default=50.0)
    a = ap.parse_args()
    d = def_parse.parse(a.def_path)
    tm = tile_metrics(d)
    sm = skew_metrics(a.skew)
    wire_mm = sum(sum(n['len'].values()) for n in d['nets'].values()) / 1e3
    grid = tm['corr_x_col'] >= a.min_corr and sm['abs_skew_mean_ps'] <= a.max_skew_ps
    out = dict(label=a.label, def_file=str(Path(a.def_path).resolve()), skew_file=str(Path(a.skew).resolve()),
               die_um=[d['die'][2], d['die'][3]], wire_mm=wire_mm,
               gate=dict(min_corr_x_col=a.min_corr, max_abs_skew_ps=a.max_skew_ps,
                         basin='grid' if grid else 'collapsed', status='PASS' if grid else 'FAIL'),
               **{k: v for k, v in tm.items() if k != 'tile_centroids'}, **sm,
               tile_centroids=tm['tile_centroids'])
    if a.plan:
        out['pin_proof'] = pin_proof(a.def_path, a.plan, d['units'])
    Path(a.json).write_text(json.dumps(out, indent=2) + '\n')
    summary = {k: out[k] for k in ('label', 'wire_mm', 'corr_x_col', 'corr_y_negrow', 'd_col_um', 'd_row_um',
                                   'tile_radius_um', 'product_ands', 'abs_skew_mean_ps', 'abs_skew_p90_ps')}
    summary['basin'] = out['gate']['basin']
    if a.plan:
        summary['pin_proof'] = out['pin_proof']['status']
        summary['pins_fixed'] = out['pin_proof']['fixed_in_def']
    print(json.dumps(summary))


if __name__ == '__main__':
    main()
