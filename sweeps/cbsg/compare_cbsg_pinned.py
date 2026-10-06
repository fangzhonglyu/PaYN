#!/usr/bin/env python3
"""C-BSG pinned pass 2 (AF, RG) vs the CSA pinned pass 2 baseline; single PE, TSMC22, 400 MHz, K8 M16 N8.

Reads, all read only except OUT:
  <OUT>/<arm>/pinned/            sweeps/cbsg/run_cbsg_pinned_pass2.sh (result.csv, power_result/, basin/, gl_final/,
                                 ladder/, routed_func/summary.json) for arm in af, rg (whatever exists)
  <OUT>/<arm>/bootstrap/         sweeps/cbsg/run_cbsg_apr.sh floating-pin final (result.csv), optional
  build/power_char/pinned_pass2_20261004/csa/   the CSA pinned pass 2 (baseline, not rerun) and its route
                                 apr/build/TSMC22/PAYN_SC_CSA/csa_20261002_distguide_spp_pins
Writes <OUT>/results.csv and <OUT>/comparison.txt.

Headline workload: uniform random 7-bit magnitudes, L = T = 128, 384 blocks = 3,072 window clocks, drain excluded
(the baseline's 384 batches x 8 cycles).  64 MAC/cycle per PE.  Areas from the routed area.rpt.
Grid composites (sweeps/int_mode/compare_grid_configs.py grid_area): P_R x P_C x u_pe + (P_R + P_C)/2 x
u_peripheral + one stream-generator set, where the generator set is the CSA's Sobol pair (u_a_rng + u_w_rng),
AF's u_rng (W lane words, counter, phase) and RG's u_a_rng (H-only A bank); AF's per-row encoders and W
comparators live in u_peripheral, RG's per-row W generators and 8,192 comparators in u_pe.
Ladder rows: the same routed netlist with the per-row ladder workload; energy per kernel MAC =
P x window clocks x 2.5 ns / (blocks x 512).
Usage: compare_cbsg_pinned.py OUT_DIR
"""
import csv
import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
OUT = Path(sys.argv[1])
APR = REPO / 'apr/build/TSMC22'
REF = REPO / 'build/power_char/pinned_pass2_20261004/csa'
GRIDS = {'4x4': (4, 4), '4x8': (4, 8)}
F_GHZ = 0.4
MAC_PER_CYCLE = 64
ARMS = {
    'af': dict(target='PAYN_SC_CSA_CBSG_AF', top='payn_array_signed_segmented_csa_cbsg_af', rng=('u_rng',)),
    'rg': dict(target='PAYN_SC_CSA_CBSG_RG', top='payn_array_signed_segmented_csa_cbsg_rg', rng=('u_a_rng',)),
}


def hier_power(path):
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


def tiles_power(path):
    tiles = 0.0
    for line in Path(path).read_text().splitlines():
        m = re.match(r'^ +(\S+) \(\S+\)\s+\S+\s+\S+\s+\S+\s+(\S+)', line)
        if m and re.match(r'g_row_\d+__g_col_\d+__u_inner$', m[1]):
            tiles += float(m[2]) * 1e3
    return tiles


def areas(path, top):
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


def jload(p):
    p = Path(p)
    return json.loads(p.read_text()) if p.exists() else None


def row_for(label, pins, workload, route, top, rng, work, result_csv, sim='gl_final', power_dir=None):
    r = next(csv.DictReader(Path(result_csv).open()))
    pr = Path(power_dir) if power_dir else Path(work) / 'power_result'
    h = hier_power(pr / 'cell_power.rpt')
    a = areas(route / 'reports/area.rpt', top)
    rng_area = sum(a[k] for k in rng)
    row = dict(label=label, pins=pins, workload=workload, run=route.name, area_um2=a[top],
               u_pe_um2=a['u_pe'], u_peripheral_um2=a['u_peripheral'], rng_um2=rng_area,
               setup_wns_ns=float(r['setup_wns_ns']), hold_wns_ns=float(r['hold_wns_ns']), **totals(pr / 'power.rpt'),
               u_pe_mW=h['u_pe'], u_peripheral_mW=h['u_peripheral'], rng_mW=sum(h[k] for k in rng),
               tiles_mW=tiles_power(pr / 'power_hier.rpt'))
    row['pipes_edge_in_pe_mW'] = row['u_pe_mW'] - row['tiles_mW']
    row['top_level_rest_mW'] = row['power_mW'] - row['u_pe_mW'] - row['u_peripheral_mW'] - row['rng_mW']
    blocks = int(r.get('blocks') or 384)
    window = int(r.get('window_clocks') or 3072)
    row.update(blocks=blocks, window_clocks=window, pJ_MAC=row['power_mW'] * window * 2.5 / (blocks * 512))
    for g, (pr_, pc_) in GRIDS.items():
        comp = pr_ * pc_ * a['u_pe'] + (pr_ + pc_) / 2 * a['u_peripheral'] + rng_area
        row[f'comp{g}_um2'] = comp
        row[f'gmacs_mm2_{g}'] = pr_ * pc_ * MAC_PER_CYCLE * F_GHZ / (comp * 1e-6)
    row['gmacs_mm2_1pe'] = MAC_PER_CYCLE * F_GHZ / (a[top] * 1e-6)
    g = jload(Path(work) / 'basin/basin_gate.json')
    if g:
        row.update(basin=g['gate']['basin'], corr_x_col=g['corr_x_col'], skew_ps=g['abs_skew_mean_ps'],
                   skew_metric=g.get('skew_metric', 'and (shared)').split(':')[0], wire_mm=g['wire_mm'],
                   pin_proof=g.get('pin_proof', {}).get('status', 'n/a'))
    q = jload(Path(work) / sim / 'timing_qualification.json')
    if q:
        row.update(gl_status=q['status'], gl_ndi_clamps=len(q['approved_negative_iopath_clamps']),
                   gl_iwsba=len(q['approved_annotated_interconnects']),
                   gl_post_reset_violations=q['post_reset_timing_violations'])
    c = jload(Path(work) / sim / 'trace_check.json')
    if c:
        row.update(a_one_density=c.get('a_one_density'), mean_kA=c.get('mean_kA'))
    return row


FIELDS = ['label', 'pins', 'workload', 'run', 'basin', 'corr_x_col', 'skew_metric', 'skew_ps', 'wire_mm', 'pin_proof',
          'area_um2', 'comp4x4_um2', 'comp4x8_um2', 'gmacs_mm2_1pe', 'gmacs_mm2_4x4', 'gmacs_mm2_4x8',
          'setup_wns_ns', 'hold_wns_ns', 'blocks', 'window_clocks', 'power_mW', 'pJ_MAC', 'internal_mW',
          'switching_mW', 'leakage_mW', 'u_pe_mW', 'tiles_mW', 'pipes_edge_in_pe_mW', 'u_peripheral_mW', 'rng_mW',
          'top_level_rest_mW', 'u_pe_um2', 'u_peripheral_um2', 'rng_um2', 'a_one_density', 'mean_kA',
          'gl_status', 'gl_ndi_clamps', 'gl_iwsba', 'gl_post_reset_violations']


def fmt(v, spec):
    return format(v, spec) if isinstance(v, (int, float)) and not isinstance(v, bool) else ('-' if v in (None, '') else str(v))


def main():
    rows = [row_for('csa', 'pinned', 'uniform L=128', APR / 'PAYN_SC_CSA/csa_20261002_distguide_spp_pins',
                    'payn_array_signed_segmented_csa', ('u_a_rng', 'u_w_rng'), REF, REF / 'result.csv')]
    notes, funcs = [], {}
    for arm, cfg in ARMS.items():
        pw = OUT / arm / 'pinned'
        if (pw / 'result.csv').exists():
            r = next(csv.DictReader((pw / 'result.csv').open()))
            route = APR / cfg['target'] / r['run']
            rows.append(row_for(arm, 'pinned', r['workload'], route, cfg['top'], cfg['rng'], pw, pw / 'result.csv'))
            if (pw / 'ladder/result.csv').exists():
                lr = next(csv.DictReader((pw / 'ladder/result.csv').open()))
                rows.append(row_for(arm, 'pinned', lr['workload'], route, cfg['top'], cfg['rng'], pw,
                                    pw / 'ladder/result.csv', sim='gl_ladder', power_dir=pw / 'ladder/power_result'))
            f = jload(pw / 'routed_func/summary.json')
            if f:
                funcs[arm] = f
        bw = OUT / arm / 'bootstrap'
        if (bw / 'result.csv').exists():
            r = next(csv.DictReader((bw / 'result.csv').open()))
            route = APR / cfg['target'] / r['run']
            row = row_for(arm, 'floating', r['workload'], route, cfg['top'], cfg['rng'], bw, bw / 'result.csv')
            rows.append(row)
    with (OUT / 'results.csv').open('w', newline='') as fh:
        w = csv.DictWriter(fh, fieldnames=FIELDS, extrasaction='ignore')
        w.writeheader()
        w.writerows(rows)

    L = ['C-BSG (AF, RG) vs the CSA pinned pass 2; TSMC22, 400 MHz, single PE K8 M16 N8, 64 MAC/cycle at L=T=128. '
         'PT-PX on routed SPEF + max-SDF GL SAIF, drain excluded. Headline: uniform random 7-bit magnitudes, '
         '384 blocks = 3,072 window clocks. Basin gate: grid iff corr(tile x, column) >= 0.8 and skew <= 50 ps '
         '(AF: shared a/w skew at the product AND2s; RG: comparator broadcast-network skew increment, uncalibrated).', '']
    hdr = (f"{'design':6s} {'pins':8s} {'workload':16s} {'basin':9s} {'corr':>6s} {'skew':>6s} {'wire_mm':>8s} "
           f"{'area_um2':>9s} {'4x4_um2':>9s} {'setup':>6s} {'hold':>6s} {'P_mW':>7s} {'pJ/MAC':>7s} {'u_pe':>7s} "
           f"{'periph':>6s} {'rng':>6s} {'GMAC/s/mm2 1PE/4x4/4x8':>24s}")
    L += [hdr, '-' * len(hdr)]
    for r in rows:
        L.append(f"{r['label']:6s} {r['pins']:8s} {r['workload'][:16]:16s} {str(r.get('basin', '?')):9s} "
                 f"{fmt(r.get('corr_x_col'), '6.3f'):>6s} {fmt(r.get('skew_ps'), '6.1f'):>6s} {fmt(r.get('wire_mm'), '8.1f'):>8s} "
                 f"{r['area_um2']:9.1f} {r['comp4x4_um2']:9.0f} {r['setup_wns_ns']:6.3f} {r['hold_wns_ns']:6.3f} "
                 f"{r['power_mW']:7.3f} {r['pJ_MAC']:7.4f} {r['u_pe_mW']:7.3f} {r['u_peripheral_mW']:6.3f} {r['rng_mW']:6.3f} "
                 f"{r['gmacs_mm2_1pe']:7.1f} /{r['gmacs_mm2_4x4']:7.1f} /{r['gmacs_mm2_4x8']:7.1f}")
    L.append('')
    c = rows[0]
    for arm in ARMS:
        n = next((r for r in rows if r['label'] == arm and r['pins'] == 'pinned' and r['workload'].startswith('uniform')), None)
        if not n:
            L.append(f'{arm}: no pinned result yet.')
            continue
        d = n['power_mW'] - c['power_mW']
        L.append(f"{arm} - CSA (pinned, uniform): power {d:+.3f} mW ({100 * d / c['power_mW']:+.2f} %), pJ/MAC "
                 f"{n['pJ_MAC'] - c['pJ_MAC']:+.4f}, area {n['area_um2'] - c['area_um2']:+.1f} um2 "
                 f"({100 * (n['area_um2'] / c['area_um2'] - 1):+.2f} %), 4x4 composite "
                 f"{100 * (n['comp4x4_um2'] / c['comp4x4_um2'] - 1):+.2f} %, 4x8 composite "
                 f"{100 * (n['comp4x8_um2'] / c['comp4x8_um2'] - 1):+.2f} %, GMAC/s/mm2 4x4 "
                 f"{100 * (n['gmacs_mm2_4x4'] / c['gmacs_mm2_4x4'] - 1):+.2f} %, setup WNS {n['setup_wns_ns'] - c['setup_wns_ns']:+.3f} ns, "
                 f"basin {c.get('basin')} -> {n.get('basin')}")
        if n.get('basin') != 'grid':
            L.append(f'  WARNING: the {arm} pinned route is not in the grid basin by the gate; read corr and skew before quoting.')
        if n.get('gl_ndi_clamps') or n.get('gl_iwsba'):
            L.append(f"  NOTE: GL approvals used ({n.get('gl_ndi_clamps')} NDI clamps, {n.get('gl_iwsba')} IWSBA); see "
                     f"{arm}/pinned/gl_validator_args.txt and the rationale file.")
        lad = next((r for r in rows if r['label'] == arm and r['pins'] == 'pinned' and not r['workload'].startswith('uniform')), None)
        if lad:
            L.append(f"  {arm} ladder ({lad['workload']}): {lad['power_mW']:.3f} mW over {lad['window_clocks']} window clocks "
                     f"({lad['window_clocks'] / lad['blocks']:.2f} cycles/block), {lad['pJ_MAC']:.4f} pJ per kernel MAC "
                     f"({100 * (lad['pJ_MAC'] / n['pJ_MAC'] - 1):+.1f} % vs its uniform; "
                     f"{100 * (lad['pJ_MAC'] / c['pJ_MAC'] - 1):+.1f} % vs CSA uniform)")
        if arm in funcs:
            f = funcs[arm]
            L.append(f"  routed functional bench (raw routed SDF): ideal-clock view needed: {f['ideal_clock_view_needed']} "
                     f"(worst clock-gate CK->ECK {f['worst_icg_ck_eck_ns']} ns over {f['icg_cells']} cells); "
                     f"2-edge reset settle needed: {f['reset_settle_needed']}")
    L.append('')
    L.append('By hierarchy, mW (tiles from power_hier.rpt, 3 digits; rest from cell_power.rpt) and areas, um2:')
    keys = ['tiles_mW', 'pipes_edge_in_pe_mW', 'u_peripheral_mW', 'rng_mW', 'top_level_rest_mW', 'power_mW',
            'u_pe_um2', 'u_peripheral_um2', 'rng_um2', 'area_um2', 'comp4x4_um2', 'comp4x8_um2']
    sel = [r for r in rows if r['pins'] == 'pinned']
    L.append('  ' + f"{'part':22s}" + ''.join(f"{r['label'] + ('/' + r['workload'][:7] if not r['workload'].startswith('uniform') else ''):>16s}" for r in sel))
    for k in keys:
        L.append('  ' + f"{k:22s}" + ''.join(f"{r[k]:16.3f}" if k.endswith('mW') else f"{r[k]:16.1f}" for r in sel))
    L.append('')
    L.append('Notes: rng = stream generators (CSA u_a_rng + u_w_rng, AF u_rng, RG u_a_rng). AF composites assume one '
             'u_rng per grid like the CSA Sobol pair (per-PE block_start alignment on a skewed grid is open, see the AF '
             'README). RG puts its W generators and comparators in u_pe, so its composite scales them per PE. The CSA '
             'baseline has no ladder run (its bench has no stream-length workload).')
    (OUT / 'comparison.txt').write_text('\n'.join(L) + '\n')
    print('\n'.join(L))


if __name__ == '__main__':
    main()
