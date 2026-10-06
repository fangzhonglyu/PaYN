#!/usr/bin/env python3
"""Summarize sweeps/cbsg/af_ipd/pt_power_classes_af_ipd.tcl output into AF-IPD block rows (mW and um2).

[CBSG-AF-IPD COPY] of sweeps/cbsg/af/power_classes.py (unchanged; sha256 in
designs/payn/variants/signed_segmented_csa_cbsg_af_ipd/copied_from.sha256), with the AF-IPD rows.  The AF rows keep
their names and meaning so the two routes compare row for row; the INT additions are separate rows:
  u_pe            tiles + pe_pipes_glue (core_seq + core_glue + pe_local) + dbl_mux + dbl_sel + pe_clk_buf
                  (AF: tiles + pipes_glue + clk_buf; dbl_mux = per-tile doubling muxes, dbl_sel = lap select tree,
                  pe_local = PE wrapper ring_q flop and shift_in | ring_q)
  a_edge          a_regs + ka_enc + ka_in_buf + therm_byp (thermometer + A INT bypass, merged by DC: a_logic +
                  byp_a + sel_a)
  w_edge          w_regs + w_cmp_byp (W comparators + W INT bypass: w_logic + byp_w + sel_w)
  sel_shared      bypass select buffering feeding both bit cones (sel_both)
  w_bank          u_rng (AF block clock)
  combiner        u_combiner
  periph_clk_buf  CTS buffers in u_peripheral
  other           u_peripheral leftovers + top glue + top CTS buffers + input-port net switching
The rows sum to PT's Total Power (checked); the same rows as PT cell area sum to the leaf total.
  power_classes_af_ipd.py pt_power_classes.log [--json out.json]
"""
import argparse
import json
import sys


def parse(path):
    d = {'class': {}, 'hier': {}, 'info': [], 'other': []}
    for line in open(path):
        f = line.split()
        if not f:
            continue
        if f[0] == 'PWR_TOTAL':
            d['total'] = float(f[1])
        elif f[0] == 'PWR_CLASS':
            d['class'][(f[1], f[2])] = dict(cells=int(f[3]), int=float(f[4]), sw=float(f[5]), leak=float(f[6]),
                                            tot=float(f[7]), area=float(f[8]) if len(f) > 8 else None)
        elif f[0] == 'PWR_HIER':
            d['hier'][f[1]] = dict(int=float(f[2]), sw=float(f[3]), leak=float(f[4]), tot=float(f[5]))
        elif f[0] == 'PWR_CHECK' and f[1] == 'leaf_sum':
            d['leaf_sum'] = float(f[2])
            d['port_nets'] = float(f[4])
        elif f[0] in ('PWR_INFO', 'PWR_CHECK'):
            d['info'].append(' '.join(f[1:]))
        elif f[0] == 'PWR_OTHER':
            d['other'].append(' '.join(f[1:]))
    return d


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('log')
    ap.add_argument('--json')
    a = ap.parse_args()
    d = parse(a.log)
    n = lambda s, k: d['class'].get((s, k), dict(cells=0))['cells']

    def build(field, scale, total, port):
        c = lambda s, k: (d['class'].get((s, k), {}).get(field) or 0.0) * scale
        r = {}
        r['tiles'] = c('u_pe', 'tiles')
        r['pe_pipes_glue'] = c('u_pe', 'core_seq') + c('u_pe', 'core_glue') + c('u_pe', 'pe_local')
        r['pe_core_seq'] = c('u_pe', 'core_seq')
        r['pe_core_glue'] = c('u_pe', 'core_glue')
        r['pe_local'] = c('u_pe', 'pe_local')
        r['dbl_mux'] = c('u_pe', 'dbl_mux')
        r['dbl_sel'] = c('u_pe', 'dbl_sel')
        r['pe_clk_buf'] = c('u_pe', 'clk_buf')
        r['u_pe'] = r['tiles'] + r['pe_pipes_glue'] + r['dbl_mux'] + r['dbl_sel'] + r['pe_clk_buf']
        r['a_regs'] = c('u_peripheral', 'a_regs')
        r['ka_enc'] = c('u_peripheral', 'ka_enc')
        r['ka_in_buf'] = c('u_peripheral', 'ka_in_buf')
        r['therm'] = c('u_peripheral', 'a_logic')
        r['byp_a'] = c('u_peripheral', 'byp_a')
        r['sel_a'] = c('u_peripheral', 'sel_a')
        r['therm_byp'] = r['therm'] + r['byp_a'] + r['sel_a']
        r['a_edge'] = r['a_regs'] + r['ka_enc'] + r['ka_in_buf'] + r['therm_byp']
        r['w_regs'] = c('u_peripheral', 'w_regs')
        r['w_cmp'] = c('u_peripheral', 'w_logic')
        r['byp_w'] = c('u_peripheral', 'byp_w')
        r['sel_w'] = c('u_peripheral', 'sel_w')
        r['w_cmp_byp'] = r['w_cmp'] + r['byp_w'] + r['sel_w']
        r['w_edge'] = r['w_regs'] + r['w_cmp_byp']
        r['sel_shared'] = c('u_peripheral', 'sel_both')
        r['rng_words'] = c('u_rng', 'rng_words')
        r['rng_ctrl'] = c('u_rng', 'rng_ctrl')
        r['rng_clk_buf'] = c('u_rng', 'clk_buf')
        r['w_bank'] = c('u_rng', 'ALL')
        r['combiner'] = c('u_combiner', 'ALL')
        r['combiner_clk_buf'] = c('u_combiner', 'clk_buf')
        r['periph_clk_buf'] = c('u_peripheral', 'clk_buf')
        r['periph_other'] = c('u_peripheral', 'p_other')
        r['top_glue'] = c('top', 'glue')
        r['top_clk_buf'] = c('top', 'clk_buf')
        r['port_nets'] = port
        r['other'] = r['periph_other'] + r['top_glue'] + r['top_clk_buf'] + r['port_nets']
        r['total'] = total if total is not None else c('top', 'ALL_LEAF')
        r['u_peripheral_leaf_sum'] = c('u_peripheral', 'ALL')
        r['u_pe_leaf_sum'] = c('u_pe', 'ALL')
        r['clock_buffers_all'] = c('top', 'CLOCK_BUFFERS_ALL')
        # INT / doubling additions over AF (the classes AF does not have)
        r['int_additions'] = r['dbl_mux'] + r['dbl_sel'] + r['pe_local'] + r['byp_a'] + r['sel_a'] + r['byp_w'] \
            + r['sel_w'] + r['sel_shared'] + r['combiner'] + r['top_glue']
        check = r['u_pe'] + r['a_edge'] + r['w_edge'] + r['sel_shared'] + r['w_bank'] + r['combiner'] \
            + r['periph_clk_buf'] + r['other']
        if abs(check - r['total']) > 1e-6 * r['total'] + 1e-3:
            sys.exit(f'{field}: class rows sum {check:.6f} != total {r["total"]:.6f}')
        if abs(r['u_pe'] - r['u_pe_leaf_sum']) > 1e-6 * r['total'] + 1e-3:
            sys.exit(f'{field}: u_pe classes {r["u_pe"]:.6f} != u_pe leaf sum {r["u_pe_leaf_sum"]:.6f}')
        return r

    rows = build('tot', 1e3, d['total'] * 1e3, d['port_nets'] * 1e3)
    has_area = all(v.get('area') is not None for v in d['class'].values())
    area = build('area', 1.0, None, 0.0) if has_area else None
    keys = ['ka_enc', 'a_regs', 'w_regs', 'clk_buf', 'ka_in_buf', 'byp_a', 'byp_w', 'sel_a', 'sel_w', 'sel_both',
            'a_logic', 'w_logic', 'p_other']
    if sum(n('u_peripheral', k) for k in keys) != n('u_peripheral', 'ALL'):
        sys.exit('u_peripheral classes do not partition its leaf cells')
    pk = ['tiles', 'clk_buf', 'core_seq', 'dbl_mux', 'dbl_sel', 'core_glue', 'pe_local']
    if sum(n('u_pe', k) for k in pk) != n('u_pe', 'ALL'):
        sys.exit('u_pe classes do not partition its leaf cells')
    hier = {k: v['tot'] * 1e3 for k, v in d['hier'].items()}
    cells = {f'{s}/{k}': v['cells'] for (s, k), v in d['class'].items()}
    out = dict(kind='afipd', rows_mW=rows, rows_area_um2=area, hier_attr_mW=hier, cells=cells, info=d['info'],
               top_p_other=d['other'])
    if a.json:
        json.dump(out, open(a.json, 'w'), indent=2)
    order = ['total', 'u_pe', 'tiles', 'pe_pipes_glue', 'pe_core_seq', 'pe_core_glue', 'pe_local', 'dbl_mux', 'dbl_sel',
             'pe_clk_buf', 'a_edge', 'a_regs', 'ka_enc', 'ka_in_buf', 'therm_byp', 'therm', 'byp_a', 'sel_a',
             'w_edge', 'w_regs', 'w_cmp_byp', 'w_cmp', 'byp_w', 'sel_w', 'sel_shared', 'w_bank', 'rng_words',
             'rng_ctrl', 'rng_clk_buf', 'combiner', 'combiner_clk_buf', 'periph_clk_buf', 'other', 'periph_other',
             'top_glue', 'top_clk_buf', 'port_nets', 'u_peripheral_leaf_sum', 'clock_buffers_all', 'int_additions']
    for k in order:
        ar = f'{area[k]:11.1f} um2 ({100 * area[k] / area["total"]:5.2f} %)' if area else ''
        print(f'{k:22s} {rows[k]:10.4f} mW  ({100 * rows[k] / rows["total"]:5.2f} %)  {ar}')
    for k, v in hier.items():
        print(f'hier attribute {k:12s} {v:10.4f} mW')
    for i in d['info']:
        print('info', i)


if __name__ == '__main__':
    main()
