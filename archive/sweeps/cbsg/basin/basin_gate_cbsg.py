#!/usr/bin/env python3
"""Basin QoR gate and pin-survival proof for one routed C-BSG single-PE layout.

C-BSG copy of sweeps/pinned_pass2/basin_gate.py (shared, unchanged).  The tile metrics (corr(tile x, column),
d_col / d_row / tile radius over u_pe/u_array_core/g_row_h__g_col_v__u_inner/ components), the routed wire length
and the pin proof are the shared module's own functions, imported read-only, so they are computed identically.
Only the skew criterion depends on --mode:

  and  (AF)  the shared metric from a basin_skew_pt.tcl-format TSV: mean |w_arr - a_arr| at the product AND2s,
             both operands rooted at the a_bits_pipe / w_bits_pipe flops (the AF tiles and pipes are the CSA's).
  rg   (RG)  from sweeps/cbsg/basin/basin_skew_cbsg_pt.tcl MODE=rg: per product AND, its comparator's
             broadcast-network skew  skew_cmp = mean W-magnitude network delay - mean threshold network delay
             (driver output -> comparator input pin, hold-padding DLY cells subtracted), i.e. the column-broadcast
             vs row-broadcast mismatch where the two broadcast operands of an RG tile meet.  This is the closest
             equivalent of the CSA metric, which is the same difference at the AND (both CSA operands are
             flop-launched on one edge); the RG AND's own w_arr - a_arr includes ~1 ns of generator logic in
             every basin and is reported as information only (and_abs_skew_mean_ps).  Because a W-magnitude
             bit drives 128-256 comparator inputs and a threshold bit ~10, the skew has a structural floor even
             in a perfect layout; with --skew-floor (the same PT metric on the run's synthesized netlist, zero
             wire load) the gated quantity is the placement-induced increment, per product AND
             |skew_routed - skew_floor|, matched by AND instance name.  See basin_skew_cbsg_pt.tcl.
             The 50 ps limit is kept because the increment is the same kind of network-delay mismatch the CSA
             metric limits; it has not been calibrated on RG layouts (none existed when the gate was written),
             so corr(tile x, column), the geometric criterion that separated every calibration layout (grid
             0.83-0.99, collapsed 0.12-0.16), carries the verdict's weight; read both.
Gate: grid basin iff corr >= 0.8 and mean |skew| <= 50 ps (as the shared gate).
With --plan (the PRE_PLACE pin plan, sc_pin_plan.tsv) it also proves that every top-level pin in the final DEF
is FIXED at exactly the planned layer and location (shared pin_proof).
Usage: basin_gate_cbsg.py --mode and|rg --def D --skew T [--skew-floor F] [--plan P] --label L --json OUT
"""
from __future__ import annotations

import argparse
import collections
import csv
import json
import statistics
import sys
from pathlib import Path

sys.dont_write_bytecode = True          # never write a __pycache__ into the shared directory
REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / 'sweeps/pinned_pass2'))
import basin_gate as shared  # noqa: E402  (also imports build/sc_power_regression/physical/def_parse)


def _rg_rows(path):
    rows = list(csv.DictReader(open(path), delimiter='\t'))
    assert rows, f'no product ANDs with a comparator in {path}'
    return rows


def _rg_skew(r):
    return (float(r['w_net_nodly_mean']) - float(r['r_net_nodly_mean'])) * 1000


def rg_skew_metrics(path, floor_path=None):
    rows = _rg_rows(path)
    sk = [_rg_skew(r) for r in rows]
    n = len(rows)
    out = dict(skew_metric='rg: comparator broadcast-network skew (W-magnitude minus threshold network delay, '
                           'hold-padding DLY excluded), one per product AND',
               product_ands=n, comparators=len({r['cmp_cell'] for r in rows}),
               w_sinks_mean=statistics.mean(int(r['n_w']) for r in rows),
               thr_sinks_mean=statistics.mean(int(r['n_r']) for r in rows),
               thr_flop_rooted_sinks=sum(int(r['r_flop_roots']) for r in rows),
               unrooted_sinks=sum(int(r['n_x']) for r in rows),
               w_net_mean_ps=statistics.mean(float(r['w_net_mean']) for r in rows) * 1000,
               thr_net_mean_ps=statistics.mean(float(r['r_net_mean']) for r in rows) * 1000,
               w_dly_mean_ps=statistics.mean(float(r['w_dly_mean']) for r in rows) * 1000,
               thr_dly_mean_ps=statistics.mean(float(r['r_dly_mean']) for r in rows) * 1000,
               raw_skew_mean_ps=statistics.mean(sk), raw_abs_skew_mean_ps=statistics.mean(abs(x) for x in sk),
               a_arr_mean_ps=statistics.mean(float(r['a_arr']) for r in rows) * 1000,
               w_arr_mean_ps=statistics.mean(float(r['w_arr']) for r in rows) * 1000)
    and_sk = sorted(abs(float(r['w_arr']) - float(r['a_arr'])) * 1000 for r in rows)
    out.update(and_abs_skew_mean_ps=statistics.mean(and_sk), and_abs_skew_p90_ps=and_sk[int(0.9 * n)])
    gated = sk
    if floor_path:
        floor = {r['cell']: _rg_skew(r) for r in _rg_rows(floor_path)}
        matched = [(s_, floor[r['cell']]) for r, s_ in zip(rows, sk) if r['cell'] in floor]
        out.update(floor_file=str(Path(floor_path).resolve()), floor_matched_ands=len(matched),
                   floor_skew_mean_ps=statistics.mean(floor.values()))
        if len(matched) == n:
            gated = [s_ - f for s_, f in matched]
            out['gated_quantity'] = 'per-AND increment over the synthesized-netlist floor'
        else:   # instance names changed: compare the means instead
            m = statistics.mean(floor.values())
            gated = [s_ - m for s_ in sk]
            out['gated_quantity'] = f'increment over the mean floor ({len(matched)}/{n} AND names matched)'
    else:
        out['gated_quantity'] = 'raw skew (no floor given)'
    ab = sorted(abs(x) for x in gated)
    per_tile = collections.defaultdict(list)
    for r, x in zip(rows, gated):
        per_tile[(int(r['tile_row']), int(r['tile_col']))].append(abs(x))
    out.update(skew_mean_ps=statistics.mean(gated), abs_skew_mean_ps=statistics.mean(ab),
               abs_skew_p50_ps=ab[n // 2], abs_skew_p90_ps=ab[int(0.9 * n)],
               worst_tile_abs_skew_ps=max(sum(v) / len(v) for v in per_tile.values()))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--mode', choices=('and', 'rg'), required=True)
    ap.add_argument('--def', dest='def_path')
    ap.add_argument('--skew', required=True)
    ap.add_argument('--skew-floor', help='rg: the same metric on the synthesized netlist (zero wire load)')
    ap.add_argument('--plan')
    ap.add_argument('--label', required=True)
    ap.add_argument('--json', required=True)
    ap.add_argument('--min-corr', type=float, default=0.8)
    ap.add_argument('--max-skew-ps', type=float, default=50.0)
    ap.add_argument('--skew-only', action='store_true', help='no DEF (dry run on a synthesized netlist)')
    a = ap.parse_args()
    if a.mode == 'and':
        sm = shared.skew_metrics(a.skew)
        sm['skew_metric'] = 'and: mean |w_arr - a_arr| at the product AND2s (shared gate metric)'
    else:
        sm = rg_skew_metrics(a.skew, a.skew_floor)
    if a.skew_only:
        out = dict(label=a.label, skew_file=str(Path(a.skew).resolve()), mode=a.mode, **sm)
        Path(a.json).write_text(json.dumps(out, indent=2) + '\n')
        print(json.dumps(out))
        return
    d = shared.def_parse.parse(a.def_path)
    tm = shared.tile_metrics(d)
    wire_mm = sum(sum(n['len'].values()) for n in d['nets'].values()) / 1e3
    grid = tm['corr_x_col'] >= a.min_corr and sm['abs_skew_mean_ps'] <= a.max_skew_ps
    out = dict(label=a.label, mode=a.mode, def_file=str(Path(a.def_path).resolve()),
               skew_file=str(Path(a.skew).resolve()), die_um=[d['die'][2], d['die'][3]], wire_mm=wire_mm,
               gate=dict(min_corr_x_col=a.min_corr, max_abs_skew_ps=a.max_skew_ps,
                         basin='grid' if grid else 'collapsed', status='PASS' if grid else 'FAIL',
                         skew_threshold_calibrated=(a.mode == 'and')),
               **{k: v for k, v in tm.items() if k != 'tile_centroids'}, **sm,
               tile_centroids=tm['tile_centroids'])
    if a.plan:
        out['pin_proof'] = shared.pin_proof(a.def_path, a.plan, d['units'])
    Path(a.json).write_text(json.dumps(out, indent=2) + '\n')
    summary = {k: out[k] for k in ('label', 'mode', 'wire_mm', 'corr_x_col', 'corr_y_negrow', 'd_col_um', 'd_row_um',
                                   'tile_radius_um', 'product_ands', 'abs_skew_mean_ps', 'abs_skew_p90_ps')}
    summary['basin'] = out['gate']['basin']
    if a.plan:
        summary['pin_proof'] = out['pin_proof']['status']
        summary['pins_fixed'] = out['pin_proof']['fixed_in_def']
    print(json.dumps(summary))


if __name__ == '__main__':
    main()
