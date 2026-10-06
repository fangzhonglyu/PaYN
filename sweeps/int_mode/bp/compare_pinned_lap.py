#!/usr/bin/env python3
"""Pinned pass 2 of the per-PE lap-enable BP netlist vs the earlier pinned finals.

Reads, all read only except OUT:
  <OUT>/csa_bp_lap/                       sweeps/run_pinned_pass2.sh csa_bp_lap
                                          (result.csv, power_result/, basin/)
  build/power_char/pinned_pass2_20261004/{csa_bp,csa}/
                                          the csa_bp_20261003b and CSA pinned finals
  build/power_char/popcount_apr_<synth>/csa_bp/   the lap netlist's own floating-pin
                                          final (optional; its basin gate, if run, at
                                          <OUT>/calibration/lap_floating/basin_gate.json)
  build/rtl_preflight/bp_paths/routed_shift_in/<route>/summary.txt
                                          routed shift_in / ring_q slack (optional,
                                          sweeps/int_mode/bp/report_bp_routed_shift_in.sh)
Writes <OUT>/results.csv and <OUT>/comparison.txt.

Area efficiency: one PE does K*M*N_H*N_W/T = 64 MAC per cycle at 400 MHz (SC,
T=128); 4x4 composite area = 16 u_pe + 4 u_peripheral + 4 u_combiner + the
Sobol pair (u_a_rng + u_w_rng), the composition of
build/power_char/int_mode_energy_20261003/bp/routed_summary.txt.
Usage: compare_pinned_lap.py OUT_DIR [--synth csa_bp_20261004_lap]
"""
import argparse
import csv
import json
import re
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
APR = REPO / 'apr/build/TSMC22'
REF = REPO / 'build/power_char/pinned_pass2_20261004'
PATHS = REPO / 'build/rtl_preflight/bp_paths/routed_shift_in'
MAC_PER_CYCLE = 8 * 16 * 8 * 8 / 128
F_GHZ = 0.4


def hier_power(path):
    """First-level hierarchy totals (mW) from PT cell_power.rpt (7 digits)."""
    out = {}
    for line in Path(path).read_text().splitlines():
        m = re.match(r'^(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+\(.*\)\s+h\s*$', line)
        if m and m[1] not in out:
            out[m[1]] = float(m[5]) * 1e3
    return out


def totals(path):
    t = Path(path).read_text()
    get = lambda n: float(re.search(n + r'\s*=\s*([0-9.eE+-]+)', t)[1]) * 1e3
    return dict(power_mW=get('Total Power'), internal_mW=get('Cell Internal Power'),
                switching_mW=get('Net Switching Power'), leakage_mW=get('Cell Leakage Power'))


def tiles_and_sc(path):
    """Sum of the 64 tile totals and u_sc (mW), power_hier.rpt (3 digits)."""
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


def areas(path, top):
    """Top and first-level hierarchy areas (um2) from the route's area.rpt."""
    out = {}
    for line in Path(path).read_text().splitlines():
        f = line.split()
        if not f:
            continue
        if f[0] == top:
            out[top] = float(f[2])
        elif line.startswith(' ') and not line.startswith('  ') and len(f) >= 4:
            out[f[0]] = float(f[3])
    return out


def shift_summary(route):
    p = PATHS / route / 'summary.txt'
    if not p.exists():
        return {}
    out = {}
    for line in p.read_text().splitlines():
        m = re.match(r'^(.*?)\s*:\s*([-+][0-9.]+) ns\s+(.*)$', line)
        if m:
            out[m[1].strip()] = (float(m[2]), m[3])
    return out


def row_for(label, pins, route, top, work, result_csv, gate_json, gl_json):
    r = next(csv.DictReader(Path(result_csv).open()))
    pr = Path(work) / 'power_result'
    h = hier_power(pr / 'cell_power.rpt')
    t, sc = tiles_and_sc(pr / 'power_hier.rpt')
    tdir = 'PAYN_SC_CSA_BP' if top.endswith('_csa_bp') else 'PAYN_SC_CSA'
    a = areas(APR / tdir / route / 'reports/area.rpt', top)
    comp = 16 * a['u_pe'] + 4 * a['u_peripheral'] + 4 * a.get('u_combiner', 0.0) + a['u_a_rng'] + a['u_w_rng']
    row = dict(label=label, pins=pins, run=route, area_um2=a[top], setup_wns_ns=float(r['setup_wns_ns']),
               hold_wns_ns=float(r['hold_wns_ns']), **totals(pr / 'power.rpt'),
               u_pe_mW=h['u_pe'], u_peripheral_mW=h['u_peripheral'], sobol_mW=h['u_a_rng'] + h['u_w_rng'],
               combiner_mW=h.get('u_combiner', 0.0), tiles_mW=t, pipes_ring_mW=h['u_pe'] - t,
               sc_peripheral_mW=sc if sc is not None else h['u_peripheral'],
               bp_bypass_wrapper_mW=(h['u_peripheral'] - sc) if sc is not None else 0.0,
               u_pe_um2=a['u_pe'], u_peripheral_um2=a['u_peripheral'], u_combiner_um2=a.get('u_combiner', 0.0),
               sobol_um2=a['u_a_rng'] + a['u_w_rng'], comp4x4_um2=comp)
    row['top_level_rest_mW'] = row['power_mW'] - sum(h.values()) + sum(
        v for k, v in h.items() if k not in ('u_pe', 'u_peripheral', 'u_a_rng', 'u_w_rng', 'u_combiner'))
    row['pJ_MAC'] = row['power_mW'] / (MAC_PER_CYCLE * F_GHZ)
    row['gmacs_mm2_1pe'] = MAC_PER_CYCLE * F_GHZ / (row['area_um2'] * 1e-6)
    row['gmacs_mm2_4x4'] = 16 * MAC_PER_CYCLE * F_GHZ / (comp * 1e-6)
    g = json.loads(Path(gate_json).read_text()) if gate_json and Path(gate_json).exists() else None
    if g:
        row.update(basin=g['gate']['basin'], corr_x_col=g['corr_x_col'], d_col_um=g['d_col_um'],
                   mean_abs_aw_skew_ps=g['abs_skew_mean_ps'], wire_mm=g['wire_mm'],
                   pin_proof=g.get('pin_proof', {}).get('status', 'n/a'))
    q = json.loads(Path(gl_json).read_text()) if gl_json and Path(gl_json).exists() else None
    if q:
        row.update(gl_status=q['status'], gl_approved_ndi_clamps=len(q['approved_negative_iopath_clamps']),
                   gl_approved_iwsba=len(q['approved_annotated_interconnects']),
                   gl_post_reset_violations=q['post_reset_timing_violations'])
    s = shift_summary(route)
    for key, col in (('worst from shift_in', 'shift_in_worst_ns'), ('shift_in -> clock gate', 'shift_in_cg_ns'),
                     ('worst from ring_q', 'ring_q_worst_ns')):
        if key in s:
            row[col] = s[key][0]
    return row


FIELDS = ['label', 'pins', 'run', 'basin', 'corr_x_col', 'd_col_um', 'mean_abs_aw_skew_ps', 'wire_mm', 'pin_proof',
          'area_um2', 'comp4x4_um2', 'gmacs_mm2_1pe', 'gmacs_mm2_4x4', 'setup_wns_ns', 'hold_wns_ns',
          'shift_in_worst_ns', 'shift_in_cg_ns', 'ring_q_worst_ns', 'power_mW', 'pJ_MAC',
          'internal_mW', 'switching_mW', 'leakage_mW', 'u_pe_mW', 'u_peripheral_mW', 'sobol_mW', 'combiner_mW',
          'tiles_mW', 'pipes_ring_mW', 'sc_peripheral_mW', 'bp_bypass_wrapper_mW', 'top_level_rest_mW',
          'u_pe_um2', 'u_peripheral_um2', 'u_combiner_um2', 'sobol_um2',
          'gl_status', 'gl_approved_ndi_clamps', 'gl_approved_iwsba', 'gl_post_reset_violations']


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('out', type=Path)
    ap.add_argument('--synth', default='csa_bp_20261004_lap')
    args = ap.parse_args()
    out, synth = args.out, args.synth
    bp, csa = 'payn_array_signed_segmented_csa_bp', 'payn_array_signed_segmented_csa'
    rows = [
        row_for('csa', 'pinned', 'csa_20261002_distguide_spp_pins', csa, REF / 'csa', REF / 'csa/result.csv',
                REF / 'csa/basin/basin_gate.json', REF / 'csa/gl_final/timing_qualification.json'),
        row_for('bp_03b', 'pinned', 'csa_bp_20261003b_distguide_spp_pins', bp, REF / 'csa_bp',
                REF / 'csa_bp/result.csv', REF / 'csa_bp/basin/basin_gate.json',
                REF / 'csa_bp/gl_final/timing_qualification.json'),
    ]
    lap = out / 'csa_bp_lap'
    if (lap / 'result.csv').exists():
        rows.append(row_for('bp_lap', 'pinned', f'{synth}_distguide_spp_pins', bp, lap, lap / 'result.csv',
                            lap / 'basin/basin_gate.json', lap / 'gl_final/timing_qualification.json'))
    flo = REPO / f'build/power_char/popcount_apr_{synth}/csa_bp'
    if (flo / 'result.csv').exists():
        rows.append(row_for('bp_lap', 'floating', f'{synth}_distguide_spp_fixed', bp, flo, flo / 'result.csv',
                            out / 'calibration/lap_floating/basin_gate.json', flo / 'gl_final/timing_qualification.json'))
    # Earlier floating final of csa_bp_20261003b, for the shift_in slack context only.
    s03f = shift_summary('csa_bp_20261003b_distguide_spp_fixed')

    with (out / 'results.csv').open('w', newline='') as f:
        w = csv.DictWriter(f, fieldnames=FIELDS, extrasaction='ignore')
        w.writeheader()
        w.writerows(rows)

    def fmt(v, spec):
        return format(v, spec) if isinstance(v, (int, float)) else ('-' if v in (None, '') else str(v))

    L = [f'Pinned pass 2 of the per-PE lap-enable BP netlist ({synth}) vs the pinned finals of '
         'build/power_char/pinned_pass2_20261004; TSMC22, 400 MHz, K8 M16 N8, SC workload T=128 '
         '(384 batches, 3,072 clocks), PT-PX on routed SPEF + max-SDF GL SAIF. Basin gate: grid iff '
         'corr(tile x, column) >= 0.8 and mean |a-w skew| <= 50 ps.', '']
    hdr = (f"{'design':7s} {'pins':8s} {'basin':9s} {'corr':>6s} {'skew_ps':>7s} {'wire_mm':>8s} {'area_um2':>9s} "
           f"{'4x4_um2':>9s} {'setup':>6s} {'hold':>6s} {'P_mW':>7s} {'pJ/MAC':>7s} {'u_pe':>7s} {'periph':>6s} "
           f"{'sobol':>6s} {'GMAC/s/mm2 1PE/4x4':>18s}")
    L += [hdr, '-' * len(hdr)]
    for r in rows:
        L.append(f"{r['label']:7s} {r['pins']:8s} {str(r.get('basin', '?')):9s} {fmt(r.get('corr_x_col'), '6.3f'):>6s} "
                 f"{fmt(r.get('mean_abs_aw_skew_ps'), '7.1f'):>7s} {fmt(r.get('wire_mm'), '8.1f'):>8s} "
                 f"{r['area_um2']:9.1f} {r['comp4x4_um2']:9.0f} {r['setup_wns_ns']:6.3f} {r['hold_wns_ns']:6.3f} "
                 f"{r['power_mW']:7.3f} {r['pJ_MAC']:7.4f} {r['u_pe_mW']:7.3f} {r['u_peripheral_mW']:6.3f} "
                 f"{r['sobol_mW']:6.3f} {r['gmacs_mm2_1pe']:8.1f} /{r['gmacs_mm2_4x4']:7.1f}")
    L.append('')
    by = {(r['label'], r['pins']): r for r in rows}
    c, b, n = by[('csa', 'pinned')], by[('bp_03b', 'pinned')], by.get(('bp_lap', 'pinned'))
    if n:
        for ref, name in ((b, 'csa_bp_20261003b pinned'), (c, 'CSA pinned')):
            d = n['power_mW'] - ref['power_mW']
            L.append(f"lap - {name}: power {d:+.3f} mW ({100 * d / ref['power_mW']:+.2f} %), "
                     f"area {n['area_um2'] - ref['area_um2']:+.1f} um2 ({100 * (n['area_um2'] / ref['area_um2'] - 1):+.2f} %), "
                     f"4x4 composite {n['comp4x4_um2'] - ref['comp4x4_um2']:+.0f} um2 "
                     f"({100 * (n['comp4x4_um2'] / ref['comp4x4_um2'] - 1):+.2f} %), "
                     f"setup WNS {n['setup_wns_ns'] - ref['setup_wns_ns']:+.3f} ns, "
                     f"wire {fmt(n.get('wire_mm', float('nan')) - ref.get('wire_mm', float('nan')), '+.1f')} mm, "
                     f"basin {ref.get('basin')} -> {n.get('basin')}")
        if n.get('basin') != 'grid':
            L.append('  WARNING: the lap route is not in the grid basin; its power is not comparable.')
        L.append('')
        L.append('By hierarchy, mW (tiles and u_sc from power_hier.rpt, 3 digits; rest from cell_power.rpt):')
        keys = ['tiles_mW', 'pipes_ring_mW', 'sc_peripheral_mW', 'bp_bypass_wrapper_mW', 'sobol_mW', 'combiner_mW',
                'top_level_rest_mW', 'power_mW']
        L.append(f"  {'part':20s} {'CSA':>8s} {'BP 03b':>8s} {'BP lap':>8s} {'lap-03b':>8s} {'lap-CSA':>8s}")
        for k in keys:
            L.append(f"  {k[:-3]:20s} {c[k]:8.3f} {b[k]:8.3f} {n[k]:8.3f} {n[k] - b[k]:+8.3f} {n[k] - c[k]:+8.3f}")
        L.append('')
        L.append('Areas, um2 (route area.rpt):')
        for k in ('area_um2', 'u_pe_um2', 'u_peripheral_um2', 'u_combiner_um2', 'sobol_um2', 'comp4x4_um2'):
            L.append(f"  {k[:-4]:20s} {c[k]:10.1f} {b[k]:10.1f} {n[k]:10.1f} {n[k] - b[k]:+9.1f} {n[k] - c[k]:+9.1f}")
    L.append('')
    L.append('Routed shift_in / ring_q setup slack (Innovus on copies of the final DBs; '
             'sweeps/int_mode/bp/report_bp_routed_shift_in.sh), ns:')
    for r in rows:
        L.append(f"  {r['label']:7s} {r['pins']:8s} WNS {r['setup_wns_ns']:+.3f}  from shift_in "
                 f"{fmt(r.get('shift_in_worst_ns'), '+.3f')}  shift_in->clock gate {fmt(r.get('shift_in_cg_ns'), '+.3f')}"
                 f"  from ring_q {fmt(r.get('ring_q_worst_ns'), '+.3f')}")
    if s03f:
        L.append(f"  bp_03b  floating WNS (route)  from shift_in {s03f.get('worst from shift_in', ('-',))[0]:+.3f}  "
                 f"shift_in->clock gate {s03f.get('shift_in -> clock gate', ('-',))[0]:+.3f}")
    L.append('')
    L.append('GL audit (max SDF, +neg_tchk): ' + '; '.join(
        f"{r['label']} {r['pins']}: {r.get('gl_status', '?')} ndi_clamps={r.get('gl_approved_ndi_clamps', '?')} "
        f"iwsba={r.get('gl_approved_iwsba', '?')} post_reset_violations={r.get('gl_post_reset_violations', '?')}"
        for r in rows))
    (out / 'comparison.txt').write_text('\n'.join(L) + '\n')
    print('\n'.join(L))


if __name__ == '__main__':
    main()
