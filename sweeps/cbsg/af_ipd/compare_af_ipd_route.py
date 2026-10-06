#!/usr/bin/env python3
"""Routed comparison of the C-BSG AF + IPD INT variant against the AF route (SC) and the BP lap route (INT).

Reads (read only):
  AF-IPD pinned campaign   build/power_char/cbsg_20261005/af_ipd/pinned/ (result.csv, ladder/result.csv,
                           classes_uniform/, classes_ladder/, qualification.json, basin/, routed_func/summary.json,
                           filler_drc_trace.json) and the route's reports/area.rpt
  AF-IPD INT energy        build/power_char/cbsg_20261005/af_ipd/int_energy/<route>/results.csv
  AF qualified route       build/power_char/cbsg_20261005/af/pinned_fix/postfill/{qualification.json,measure/...}
  CSA pinned baseline      build/power_char/pinned_pass2_20261004/csa/result.csv
  BP lap pinned route      build/power_char/pinned_pass2_csa_bp_20261004_lap/results.csv (SC) and
                           build/power_char/int_mode_energy_20261004_lap/bp/csa_bp_20261004_lap_distguide_spp_pins/
                           results_precise.csv (INT)
Writes OUT/comparison.txt, OUT/comparison.json and OUT/results.csv (default OUT build/power_char/cbsg_20261005/af_ipd).
Throughput density: SC 64 MAC/cycle (one PE, L = 128 blocks back to back; the ladder issues 196,608 kernel MACs in
its window), INT mac_per_cycle of the point; 400 MHz; area = the route's area.rpt cell area.

  python3 sweeps/cbsg/af_ipd/compare_af_ipd_route.py [--out DIR] [--int-dir DIR]
"""
import argparse
import csv
import json
import re
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
PC = REPO / 'build/power_char'
F_GHZ = 0.4


def rcsv(p):
    return list(csv.DictReader(open(p)))


def area_rpt(route, top):
    a = {}
    for line in (route / 'reports' / 'area.rpt').read_text().splitlines():
        f = line.split()
        if not f:
            continue
        if f[0] == top:
            a['total'] = float(f[2])
        elif line.startswith(' ') and not line.startswith('  ') and len(f) >= 4:
            try:
                a[f[0]] = float(f[3])
            except ValueError:
                pass
    return a


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', default=str(PC / 'cbsg_20261005/af_ipd'))
    ap.add_argument('--int-dir', default=None)
    a = ap.parse_args()
    out = Path(a.out)
    pin = PC / 'cbsg_20261005/af_ipd/pinned'
    top = 'payn_array_signed_segmented_csa_cbsg_af_ipd'
    u = rcsv(pin / 'result.csv')[0]
    lad = rcsv(pin / 'ladder' / 'result.csv')[0]
    route = REPO / 'apr/build' / u['target'] / u['run']
    ar = area_rpt(route, top)
    q = json.loads((pin / 'qualification.json').read_text())
    b = json.loads((pin / 'basin' / 'basin_gate.json').read_text())
    cls_u = json.loads((pin / 'classes_uniform' / 'power_classes.json').read_text())
    cls_l = json.loads((pin / 'classes_ladder' / 'power_classes.json').read_text())
    rf = json.loads((pin / 'routed_func' / 'summary.json').read_text()) if (pin / 'routed_func' / 'summary.json').exists() else None
    ft = json.loads((pin / 'filler_drc_trace.json').read_text()) if (pin / 'filler_drc_trace.json').exists() else {}
    # AF qualified route
    afm = PC / 'cbsg_20261005/af/pinned_fix/postfill'
    afr = json.loads((afm / 'measure' / 'result.json').read_text())
    afu, afl = afr[0], afr[1]
    afq = json.loads((afm / 'qualification.json').read_text())
    afb = json.loads((afm / 'measure' / 'basin' / 'basin_gate.json').read_text())
    afc_u = json.loads((afm / 'measure' / 'classes_uniform' / 'power_classes.json').read_text())
    afc_l = json.loads((afm / 'measure' / 'classes_ladder' / 'power_classes.json').read_text())
    af_route = REPO / 'apr/build/TSMC22/PAYN_SC_CSA_CBSG_AF' / afu['run']
    af_ar = area_rpt(af_route, 'payn_array_signed_segmented_csa_cbsg_af')
    csa = rcsv(PC / 'pinned_pass2_20261004/csa/result.csv')[0]
    # the BP lap PINNED route (the INT campaign ran on it); results.csv also lists its floating final
    bps = next((r for r in rcsv(PC / 'pinned_pass2_csa_bp_20261004_lap/results.csv')
                if r['label'] == 'bp_lap' and r['pins'] == 'pinned'), None)
    assert bps is None or bps['run'] == 'csa_bp_20261004_lap_distguide_spp_pins', bps

    L = []
    p = L.append
    area, af_area, csa_area = ar['total'], af_ar['total'], float(csa['area_um2'])
    bp_area = float(bps['area_um2']) if bps else None
    p('C-BSG AF + IPD INT variant (payn_array_signed_segmented_csa_cbsg_af_ipd), routed: SC cost of carrying INT + per-tile')
    p('doubling vs the AF route, and INT energy vs the routed BP lap route.  TSMC22, 400 MHz, K8 M16 N8, one PE; PT-PX on')
    p('routed SPEF with full-timing max-SDF GL SAIFs (drain excluded for SC), bit-exact drains / tiles / outputs.')
    p('')
    p('1. Routes (pinned pass 2, post-fill hook, strict final qualification)')
    p(f"{'design':10s} {'run':48s} {'area_um2':>9s} {'setup':>6s} {'hold':>6s} {'wire_mm':>8s} {'basin':>6s} {'corr':>6s} {'skew_ps':>7s} {'pins':>5s} {'repair':>7s}")
    p(f"{'AF-IPD':10s} {u['run']:48s} {area:9.1f} {float(u['setup_wns_ns']):+6.3f} {float(u['hold_wns_ns']):+6.3f} {float(u['wire_mm']):8.1f} {u['basin']:>6s} {float(u['corr_x_col']):6.3f} {float(u['mean_abs_skew_ps']):7.1f} {u['pins_fixed']:>5s} {str(q['targeted_repair']):>7s}")
    p(f"{'AF':10s} {afu['run']:48s} {af_area:9.1f} {afq['setup_wns_ns']:+6.3f} {afq['hold_wns_ns']:+6.3f} {afb['wire_mm']:8.1f} {afb['gate']['basin']:>6s} {afb['corr_x_col']:6.3f} {afb['abs_skew_mean_ps']:7.1f} {afb['pin_proof']['fixed_in_def']:>5d} {str(afq['targeted_repair']):>7s}")
    if bps:
        p(f"{'BP lap':10s} {bps['run']:48s} {bp_area:9.1f} {float(bps['setup_wns_ns']):+6.3f} {float(bps['hold_wns_ns']):+6.3f} {float(bps['wire_mm']):8.1f} {bps['basin']:>6s} {float(bps['corr_x_col']):6.3f} {float(bps['mean_abs_aw_skew_ps']):7.1f} {'3661':>5s} {'True':>7s}")
    p(f"{'CSA':10s} {csa['run']:48s} {csa_area:9.1f} {float(csa['setup_wns_ns']):+6.3f} {float(csa['hold_wns_ns']):+6.3f} {float(csa['wire_mm']):8.1f} {csa['basin']:>6s} {float(csa['corr_x_col']):6.3f} {float(csa['mean_abs_aw_skew_ps']):7.1f} {csa['pins_fixed']:>5s} {csa['targeted_repair']:>7s}")
    p(f"AF-IPD - AF: area {area - af_area:+.1f} um2 ({100 * (area / af_area - 1):+.2f} %); AF-IPD - CSA: {area - csa_area:+.1f} um2 ({100 * (area / csa_area - 1):+.2f} %)"
      + (f"; AF-IPD - BP lap: {area - bp_area:+.1f} um2 ({100 * (area / bp_area - 1):+.2f} %)" if bps else ''))
    p('Route area by hierarchy (area.rpt, um2):  ' + '  '.join(f"{k} {v:.1f}" for k, v in ar.items() if k != 'total')
      + '   | AF: ' + '  '.join(f"{k} {v:.1f}" for k, v in af_ar.items() if k != 'total'))
    if ft:
        p(f"Post-filler trace: fillers pass1 {ft.get('fillers_pass1')} pass2 (no DRC) {ft.get('fillers_pass2_no_drc')}, "
          f"router markers after ipo / routable nets {ft.get('after_ipo_violations')}/{ft.get('routable_nets')} "
          f"= {ft.get('after_ipo_per_routable_net')}, strong-reroute iterations {ft.get('search_repair_iterations')}; "
          f"post-fill hook ran {ft.get('postfill_hook_ran')} (markers before/after {ft.get('postfill_verify_markers_before_after')}, "
          f"iterations {ft.get('postfill_search_repair_iterations')}); geometry {q['geometry_drc']} antenna {q['antenna_violations']} after qualify")
    p('')
    p('2. SC power (drain excluded), same stimulus as the AF campaign')
    hdr = f"{'workload':10s} {'design':8s} {'P_mW':>8s} {'pJ/MAC':>8s} {'u_pe':>8s} {'periph':>8s} {'u_rng':>7s} {'comb':>7s} {'cyc/blk':>7s} {'GMAC/s/mm2':>10s}"
    p(hdr)
    rows = []

    def sc_row(wl, d, P, pj, upe, uper, rng, comb, cpb, ar_um2, macs_per_cycle):
        g = macs_per_cycle * F_GHZ / (ar_um2 * 1e-6)
        p(f"{wl:10s} {d:8s} {P:8.3f} {pj:8.4f} {upe:8.3f} {uper:8.3f} {rng:7.3f} {comb:7.3f} {cpb:7.3f} {g:10.1f}")
        rows.append(dict(kind='SC', workload=wl, design=d, power_mW=P, pJ_MAC=pj, u_pe_mW=upe, u_peripheral_mW=uper,
                         rng_mW=rng, combiner_mW=comb, cycles_per_block=cpb, area_um2=ar_um2, gmacs_per_mm2=g))
    other = lambda r: json.loads(r['other_top_children_mW']).get('u_combiner', 0.0)
    for wl, r, ra in (('uniform', u, afu), ('ladder', lad, afl)):
        mpc = 512 * int(r['blocks']) / int(r['window_clocks'])
        sc_row(wl, 'AF-IPD', float(r['power_mW']), float(r['pJ_MAC']), float(r['u_pe_mW']), float(r['u_peripheral_mW']),
               float(r['sobol_mW']), other(r), float(r['mean_cycles_per_block']), area, mpc)
        mpc_af = 512 * ra['blocks'] / ra['window_clocks']
        sc_row(wl, 'AF', ra['power_mW'], ra['pJ_per_MAC'], ra['u_pe_mW'], ra['u_peripheral_mW'], ra['u_rng_mW'], 0.0,
               ra['cycles_per_block'], af_area, mpc_af)
        if wl == 'uniform':
            if bps:
                sc_row(wl, 'BP lap', float(bps['power_mW']), float(bps['pJ_MAC']), float(bps['u_pe_mW']),
                       float(bps['u_peripheral_mW']), float(bps['sobol_mW']), float(bps['combiner_mW']), 8.0, bp_area, 64)
            sc_row(wl, 'CSA', float(csa['power_mW']), float(csa['pJ_MAC']), float(csa['u_pe_mW']), float(csa['u_peripheral_mW']),
                   float(csa['sobol_mW']), 0.0, 8.0, csa_area, 64)
        dP = float(r['power_mW']) - ra['power_mW']
        p(f"{'':10s} AF-IPD - AF: {dP:+.3f} mW ({100 * dP / ra['power_mW']:+.2f} %), pJ/MAC {float(r['pJ_MAC']) - ra['pJ_per_MAC']:+.4f}")
    p(f"{'':10s} AF-IPD - CSA (uniform): {float(u['power_mW']) - float(csa['power_mW']):+.3f} mW ({100 * (float(u['power_mW']) / float(csa['power_mW']) - 1):+.2f} %)")
    p('')
    p('3. SC power by class, mW (PT cell power attributes; rows sum to the PT total; area = routed cell area, um2)')
    keys = [('u_pe', 'u_pe'), ('tiles', 'tiles'), ('pe_pipes_glue', 'pe_pipes_glue'), ('dbl_mux', None), ('dbl_sel', None),
            ('pe_clk_buf', 'pe_clk_buf'), ('a_edge', 'a_edge'), ('a_regs', 'a_regs'), ('ka_enc', 'ka_enc'),
            ('ka_in_buf', 'ka_in_buf'), ('therm_byp', 'therm'), ('w_edge', 'w_edge'), ('w_regs', 'w_regs'),
            ('w_cmp_byp', 'w_cmp'), ('sel_shared', None), ('w_bank', 'w_bank'), ('combiner', None),
            ('periph_clk_buf', 'periph_clk_buf'), ('other', 'other'), ('total', 'total')]
    p(f"{'class (AF-IPD / AF)':28s} {'uni AF-IPD':>10s} {'uni AF':>8s} {'delta':>8s} | {'lad AF-IPD':>10s} {'lad AF':>8s} {'delta':>8s} | {'area AF-IPD':>11s} {'area AF':>8s} {'delta':>8s}")
    cls_rows = []
    for k, ka in keys:
        x_u = cls_u['rows_mW'][k]; x_l = cls_l['rows_mW'][k]; x_a = cls_u['rows_area_um2'][k]
        y_u = afc_u['rows_mW'][ka] if ka else 0.0
        y_l = afc_l['rows_mW'][ka] if ka else 0.0
        y_a = afc_u['rows_area_um2'][ka] if ka else 0.0
        name = k if (ka == k or ka is None) else f'{k} / {ka}'
        p(f"{name:28s} {x_u:10.4f} {y_u:8.4f} {x_u - y_u:+8.4f} | {x_l:10.4f} {y_l:8.4f} {x_l - y_l:+8.4f} | {x_a:11.1f} {y_a:8.1f} {x_a - y_a:+8.1f}")
        cls_rows.append(dict(cls=k, af_cls=ka, uni_afipd=x_u, uni_af=y_u, lad_afipd=x_l, lad_af=y_l, area_afipd=x_a, area_af=y_a))
    p(f"INT additions (dbl_mux + dbl_sel + PE wrapper + bypass gates/select + combiner + top glue): uniform "
      f"{cls_u['rows_mW']['int_additions']:.4f} mW, ladder {cls_l['rows_mW']['int_additions']:.4f} mW, area {cls_u['rows_area_um2']['int_additions']:.1f} um2")
    p('')
    # INT
    int_dir = Path(a.int_dir) if a.int_dir else PC / 'cbsg_20261005/af_ipd/int_energy' / u['run']
    bpint = {r['label']: r for r in rcsv(PC / 'int_mode_energy_20261004_lap/bp/csa_bp_20261004_lap_distguide_spp_pins/results_precise.csv')}
    if (int_dir / 'results.csv').exists():
        ints = {r['label']: r for r in rcsv(int_dir / 'results.csv')}
        p('4. INT energy (routed GL, strict audit, bit-exact tiles and combiner outputs), AF-IPD (1-edge in-place laps) vs BP lap (8-edge ring laps)')
        p(f"{'point':24s} {'MAC/cyc':>8s} {'BP':>8s} {'P_mW':>7s} {'BP':>7s} {'pJ/MAC':>7s} {'BP':>7s} {'ratio':>6s} {'u_pe pJ':>7s} {'BP':>7s} {'GMAC/s/mm2':>10s} {'BP':>7s}")
        for lab in ['int8_uniform_L49152_d', 'int8_uniform_L1024_dr', 'int8_uniform_L1024_all', 'w4a8_uniform_L1024_dr',
                    'int4_uniform_L98304_d', 'int4_uniform_L1024_dr', 'int4_uniform_L1024_all']:
            if lab not in ints:
                p(f"{lab:24s} (not measured)")
                continue
            r, s = ints[lab], bpint.get(lab)
            mpc = float(r['mac_per_cycle']); g = mpc * F_GHZ / (area * 1e-6)
            if s:
                ms = float(s['mac_per_cycle']); gs = ms * F_GHZ / (bp_area * 1e-6) if bp_area else float('nan')
                p(f"{lab:24s} {mpc:8.2f} {ms:8.2f} {float(r['power_mW']):7.3f} {float(s['power_mW']):7.3f} {float(r['pJ_MAC']):7.4f} {float(s['pJ_MAC']):7.4f} {float(r['pJ_MAC']) / float(s['pJ_MAC']):6.3f} {float(r['array_pJ_MAC']):7.4f} {float(s['array_pJ_MAC']):7.4f} {g:10.1f} {gs:7.1f}")
            else:
                p(f"{lab:24s} {mpc:8.2f} {'-':>8s} {float(r['power_mW']):7.3f} {'-':>7s} {float(r['pJ_MAC']):7.4f} {'-':>7s} {'-':>6s} {float(r['array_pJ_MAC']):7.4f} {'-':>7s} {g:10.1f}")
            rows.append(dict(kind='INT', workload=lab, design='AF-IPD', power_mW=float(r['power_mW']), pJ_MAC=float(r['pJ_MAC']),
                             u_pe_mW=float(r['u_pe_mW']), u_peripheral_mW=float(r['u_peripheral_mW']), rng_mW=float(r['rng_mW']),
                             combiner_mW=float(r['u_combiner_mW']), cycles_per_block='', area_um2=area, gmacs_per_mm2=g,
                             mac_per_cycle=mpc, array_pJ_MAC=float(r['array_pJ_MAC']),
                             bp_lap_pJ_MAC=float(s['pJ_MAC']) if s else '', bp_lap_mac_per_cycle=float(s['mac_per_cycle']) if s else ''))
        p('Windows: d = data only (peak, one long block), dr = data + laps (drain paused, the SC methodology), all = drain')
        p('included; L=1024 runs are multi-block (INT8 48 blocks, W4A8 / INT4 96) with 3,072 data cycles.')
        p('')
    else:
        p(f'4. INT energy: {int_dir}/results.csv not there yet')
    if rf:
        p(f"Routed functional GL (routed_func): {rf['passed']}/{rf['total']} PASS ({rf['by_kind']}), strict audits {rf['strict_audits']}, "
          f"ideal-clock view needed: {rf['ideal_clock_view_needed']}, reset settle needed: {rf['reset_settle_needed']}, worst ICG CK->ECK {rf['worst_icg_ck_eck_ns']} ns")
    (out / 'comparison.txt').write_text('\n'.join(L) + '\n')
    json.dump(dict(rows=rows, classes=cls_rows, area=ar, af_area=af_ar, qualification=q, basin=b['gate'],
                   routed_func={k: v for k, v in (rf or {}).items() if k != 'runs'}), open(out / 'comparison.json', 'w'), indent=2)
    with (out / 'results.csv').open('w', newline='') as f:
        keys_all = []
        for r in rows:
            for k in r:
                if k not in keys_all:
                    keys_all.append(k)
        w = csv.DictWriter(f, fieldnames=keys_all); w.writeheader(); w.writerows(rows)
    print('\n'.join(L))


if __name__ == '__main__':
    main()
