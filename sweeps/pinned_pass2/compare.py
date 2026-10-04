#!/usr/bin/env python3
"""Pinned pass 2 vs the earlier floating-pin finals (single PE, SC workload).

Reads <out>/<arm>/result.csv of sweeps/run_pinned_pass2.sh and, for the earlier
floating-pin finals, their campaign result.csv, route power_hier.rpt and the
basin-gate calibration JSON (<out>/calibration/<tag>/basin_gate.json, produced
read-only by sweeps/pinned_pass2/run_basin_gate.sh). Writes <out>/results.csv
and <out>/comparison.txt.
Usage: compare.py OUT_DIR
"""
import csv
import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
OUT = Path(sys.argv[1])
APR = REPO / 'apr/build/TSMC22'
FLOATING = {
    'csa': dict(result=REPO / 'build/power_char/popcount_apr_20261002/csa/result.csv',
                route=APR / 'PAYN_SC_CSA/csa_20261002_distguide_spp_fixed', cal='csa_final'),
    'csa_bp': dict(result=REPO / 'build/power_char/popcount_apr_csa_bp_20261003/csa_bp/result.csv',
                   route=APR / 'PAYN_SC_CSA_BP/csa_bp_20261003b_distguide_spp_fixed', cal='bp_final'),
}
FIELDS = ['arm', 'pins', 'run', 'basin', 'corr_x_col', 'd_col_um', 'mean_abs_aw_skew_ps', 'wire_mm',
          'area_um2', 'setup_wns_ns', 'hold_wns_ns', 'power_mW', 'pJ_MAC', 'u_pe_mW', 'u_peripheral_mW',
          'sobol_mW', 'internal_mW', 'switching_mW', 'leakage_mW', 'pin_proof', 'targeted_repair',
          'gl_approved_ndi_clamps', 'gl_approved_iwsba']
# u_pe / u_peripheral / sobol are taken from cell_power.rpt for every row
# (result.csv of the driver carries the 3-digit power_hier.rpt values).


def hier(path):
    """First-level hierarchy totals (mW) from PT's cell_power.rpt (7 significant
    digits; power_hier.rpt prints only 3)."""
    out = {}
    for line in Path(path).read_text().splitlines():
        m = re.match(r'^(u_\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+\(.*\)\s+h\s*$', line)
        if m and m[1] not in out:
            out[m[1]] = float(m[5]) * 1e3
    return out


def totals(path):
    t = Path(path).read_text()
    get = lambda n: float(re.search(n + r'\s*=\s*([0-9.eE+-]+)', t)[1]) * 1e3
    return dict(internal_mW=get('Cell Internal Power'), switching_mW=get('Net Switching Power'),
                leakage_mW=get('Cell Leakage Power'))


rows = []
for arm, ref in FLOATING.items():
    r = next(csv.DictReader(ref['result'].open()))
    g_path = OUT / 'calibration' / ref['cal'] / 'basin_gate.json'
    g = json.loads(g_path.read_text()) if g_path.exists() else None
    h = hier(ref['route'] / 'reports/cell_power.rpt')
    row = dict(arm=arm, pins='floating (assignIoPins after place_opt_design)', run=r['run'],
               area_um2=float(r['area_um2']), setup_wns_ns=float(r['setup_wns_ns']),
               hold_wns_ns=float(r['hold_wns_ns']), power_mW=float(r['power_mW']), pJ_MAC=float(r['pJ_MAC']),
               u_pe_mW=h['u_pe'], u_peripheral_mW=h['u_peripheral'], sobol_mW=h['u_a_rng'] + h['u_w_rng'],
               **totals(ref['route'] / 'reports/power.rpt'), pin_proof='n/a', targeted_repair=True,
               gl_approved_ndi_clamps='', gl_approved_iwsba='')
    if g:
        row.update(basin=g['gate']['basin'], corr_x_col=g['corr_x_col'], d_col_um=g['d_col_um'],
                   mean_abs_aw_skew_ps=g['abs_skew_mean_ps'], wire_mm=g['wire_mm'])
    rows.append(row)
pinned = {}
for arm in FLOATING:
    p = OUT / arm / 'result.csv'
    if not p.exists():
        continue
    r = next(csv.DictReader(p.open()))
    row = {k: r.get(k, '') for k in FIELDS}
    row['pins'] = 'fixed grid-matched (PRE_PLACE)'
    for k in FIELDS:
        try:
            row[k] = float(row[k])
        except (TypeError, ValueError):
            pass
    h = hier(OUT / arm / 'power_result' / 'cell_power.rpt')
    row.update(u_pe_mW=h['u_pe'], u_peripheral_mW=h['u_peripheral'], sobol_mW=h['u_a_rng'] + h['u_w_rng'])
    pinned[arm] = row
    rows.append(row)

with (OUT / 'results.csv').open('w', newline='') as f:
    w = csv.DictWriter(f, fieldnames=FIELDS, extrasaction='ignore')
    w.writeheader()
    w.writerows(rows)


def fmt(v, spec):
    return format(v, spec) if isinstance(v, (int, float)) else str(v)


lines = ['Pinned pass 2 (fixed grid-matched IO) vs earlier floating-pin finals; TSMC22, 400 MHz, K8 M16 N8, '
         'SC workload T=128 (384 batches, 3,072 clocks). Basin gate: grid iff corr(tile x, column) >= 0.8 and '
         'mean |a-w skew| at the 8,192 product AND2s <= 50 ps.', '']
hdr = f"{'arm':7s} {'pins':9s} {'basin':9s} {'corr':>6s} {'d_col':>6s} {'skew_ps':>8s} {'wire_mm':>8s} " \
      f"{'area_um2':>9s} {'setupWNS':>8s} {'holdWNS':>7s} {'P_mW':>8s} {'pJ/MAC':>7s} {'u_pe':>7s} {'u_periph':>8s} {'sobol':>6s}"
lines += [hdr, '-' * len(hdr)]
for r in rows:
    lines.append(f"{r['arm']:7s} {r['pins'].split()[0]:9s} {str(r.get('basin', '?')):9s} "
                 f"{fmt(r.get('corr_x_col', ''), '6.3f'):>6s} {fmt(r.get('d_col_um', ''), '6.1f'):>6s} "
                 f"{fmt(r.get('mean_abs_aw_skew_ps', ''), '8.1f'):>8s} {fmt(r.get('wire_mm', ''), '8.1f'):>8s} "
                 f"{fmt(r['area_um2'], '9.1f'):>9s} {fmt(r['setup_wns_ns'], '8.3f'):>8s} {fmt(r['hold_wns_ns'], '7.3f'):>7s} "
                 f"{fmt(r['power_mW'], '8.3f'):>8s} {fmt(r['pJ_MAC'], '7.4f'):>7s} {fmt(r['u_pe_mW'], '7.3f'):>7s} "
                 f"{fmt(r['u_peripheral_mW'], '8.3f'):>8s} {fmt(r['sobol_mW'], '6.3f'):>6s}")
lines.append('')
if len(pinned) == 2:
    b, c = pinned['csa_bp'], pinned['csa']
    d = b['power_mW'] - c['power_mW']
    lines.append(f"BP - CSA, both pinned: {d:+.3f} mW ({100 * d / c['power_mW']:+.2f} % of CSA pinned); "
                 f"u_pe {b['u_pe_mW'] - c['u_pe_mW']:+.3f} mW, u_peripheral {b['u_peripheral_mW'] - c['u_peripheral_mW']:+.3f} mW, "
                 f"area {b['area_um2'] - c['area_um2']:+.1f} um2, wire {b['wire_mm'] - c['wire_mm']:+.1f} mm; "
                 f"basins BP={b['basin']} CSA={c['basin']}")
    if b['basin'] != 'grid' or c['basin'] != 'grid':
        lines.append('  WARNING: at least one pinned arm is not in the grid basin; this difference is not the inherent cost.')


def tiles_and_sc(path):
    """Sum of the 64 tile totals and the u_sc total (mW) from power_hier.rpt
    (3 significant digits per entry)."""
    tiles, sc = 0.0, None
    for line in Path(path).read_text().splitlines():
        m = re.match(r'^ +(\S+) \(\S+\)\s+\S+\s+\S+\s+\S+\s+(\S+)', line)
        if not m:
            continue
        if re.match(r'g_row_\d+__g_col_\d+__u_inner$', m[1]):
            tiles += float(m[2]) * 1e3
        elif m[1] == 'u_sc':
            sc = float(m[2]) * 1e3
    return tiles, sc


def first_level(path):
    out = {}
    for line in Path(path).read_text().splitlines():
        m = re.match(r'^(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+\(.*\)\s+h\s*$', line)
        if m:
            out[m[1]] = float(m[5]) * 1e3
    return out


if len(pinned) == 2:
    parts = {}
    for arm in pinned:
        pr = OUT / arm / 'power_result'
        h = first_level(pr / 'cell_power.rpt')
        t, sc = tiles_and_sc(pr / 'power_hier.rpt')
        total = pinned[arm]['power_mW']
        parts[arm] = dict(tiles=t, pipes_ring=h['u_pe'] - t,
                          sc_peripheral=sc if sc is not None else h['u_peripheral'],
                          bp_bypass_wrapper=(h['u_peripheral'] - sc) if sc is not None else 0.0,
                          sobol=h['u_a_rng'] + h['u_w_rng'], combiner=h.get('u_combiner', 0.0),
                          top_level_rest=total - sum(h.values()) + sum(v for k, v in h.items()
                                                                      if k not in ('u_pe', 'u_peripheral', 'u_a_rng', 'u_w_rng', 'u_combiner')))
    lines.append('')
    lines.append('BP - CSA (pinned) by hierarchy, mW (tiles and u_sc from power_hier.rpt, 3 digits; rest from cell_power.rpt):')
    for k in parts['csa']:
        lines.append(f"  {k:18s} CSA {parts['csa'][k]:8.3f}  BP {parts['csa_bp'][k]:8.3f}  delta {parts['csa_bp'][k] - parts['csa'][k]:+7.3f}")
    lines.append(f"  {'sum':18s} CSA {sum(parts['csa'].values()):8.3f}  BP {sum(parts['csa_bp'].values()):8.3f}  "
                 f"delta {sum(parts['csa_bp'].values()) - sum(parts['csa'].values()):+7.3f}")
    lines.append('  bp_bypass_wrapper = u_peripheral minus u_sc (AO21 bypass cells and nets); top_level_rest = top-level nets/cells '
                 '(peripheral->pipe nets, int_mode flops, clock tree).')
for arm in pinned:
    f = next(r for r in rows if r['arm'] == arm and r['pins'].startswith('floating'))
    p = pinned[arm]
    lines.append(f"{arm} pinned - floating final: {p['power_mW'] - f['power_mW']:+.3f} mW "
                 f"({100 * (p['power_mW'] - f['power_mW']) / f['power_mW']:+.2f} %), wire "
                 f"{p['wire_mm'] - f.get('wire_mm', float('nan')):+.1f} mm, basin {f.get('basin')} -> {p['basin']}")
(OUT / 'comparison.txt').write_text('\n'.join(lines) + '\n')
print('\n'.join(lines))
