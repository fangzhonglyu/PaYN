#!/usr/bin/env python3
"""Summarize sweeps/cbsg/af/pt_power_classes.tcl output into the AF / CSA block rows (mW).

Rows (as sweeps/cbsg/af/area_breakdown.py, plus the clock buffers CTS added):
  PE core u_pe        tiles (64 InnerTileSignedSegmentedCsa) + pipes/glue + CTS buffers in u_pe
  A edge              AF: A regs (mag, sign, per-row L) + 64 kA encoders + encoder input buffering + thermometer
                      CSA: A regs + 1,024 A comparators + A Sobol bank u_a_rng
  W edge              W regs + 1,024 W comparators (+ threshold buffering)
  W bank              AF: u_rng (lane words, counter, phase, slice restart); CSA: u_w_rng
  periph clock bufs   CTS buffers inside u_peripheral (u_rng's are in W bank)
  other               u_peripheral leftovers + top-level glue + top CTS buffers + input-port net switching
Every row is a sum of PT cell power attributes; the rows sum to PT's Total Power (checked).  The same rows are
also given as cell area (um2, PT cell area of the routed netlist; sums to the leaf-cell total).
  power_classes.py pt_power_classes.log --kind af|csa [--json out.json]
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
    ap.add_argument('--kind', choices=('af', 'csa'), required=True)
    ap.add_argument('--json')
    a = ap.parse_args()
    d = parse(a.log)
    n = lambda s, k: d['class'].get((s, k), dict(cells=0))['cells']

    def build(field, scale, total, port):
        c = lambda s, k: (d['class'].get((s, k), {}).get(field) or 0.0) * scale
        rows = {}
        rows['tiles'] = c('u_pe', 'tiles')
        rows['pe_pipes_glue'] = c('u_pe', 'pipes_glue')
        rows['pe_clk_buf'] = c('u_pe', 'clk_buf')
        rows['u_pe'] = rows['tiles'] + rows['pe_pipes_glue'] + rows['pe_clk_buf']
        rows['a_regs'] = c('u_peripheral', 'a_regs')
        rows['w_regs'] = c('u_peripheral', 'w_regs')
        rows['w_cmp'] = c('u_peripheral', 'w_logic')
        if a.kind == 'af':
            rows['ka_enc'] = c('u_peripheral', 'ka_enc')
            rows['ka_in_buf'] = c('u_peripheral', 'ka_in_buf')
            rows['therm'] = c('u_peripheral', 'a_logic')
            rows['a_edge'] = rows['a_regs'] + rows['ka_enc'] + rows['ka_in_buf'] + rows['therm']
            rows['rng_words'] = c('u_rng', 'rng_words')
            rows['rng_ctrl'] = c('u_rng', 'rng_ctrl')
            rows['rng_clk_buf'] = c('u_rng', 'clk_buf')
            rows['w_bank'] = c('u_rng', 'ALL')
        else:
            rows['a_cmp'] = c('u_peripheral', 'a_logic')
            rows['a_bank'] = c('u_a_rng', 'ALL')
            rows['a_edge'] = rows['a_regs'] + rows['a_cmp'] + rows['a_bank']
            rows['w_bank'] = c('u_w_rng', 'ALL')
        rows['w_edge'] = rows['w_regs'] + rows['w_cmp']
        rows['periph_clk_buf'] = c('u_peripheral', 'clk_buf')
        rows['periph_other'] = c('u_peripheral', 'p_other')
        rows['top_glue'] = c('top', 'glue')
        rows['top_clk_buf'] = c('top', 'clk_buf')
        rows['port_nets'] = port
        rows['other'] = rows['periph_other'] + rows['top_glue'] + rows['top_clk_buf'] + rows['port_nets']
        rows['total'] = total if total is not None else c('top', 'ALL_LEAF')
        rows['u_peripheral_leaf_sum'] = c('u_peripheral', 'ALL')
        rows['clock_buffers_all'] = c('top', 'CLOCK_BUFFERS_ALL')
        check = rows['u_pe'] + rows['a_edge'] + rows['w_edge'] + rows['w_bank'] + rows['periph_clk_buf'] + rows['other']
        if abs(check - rows['total']) > 1e-6 * rows['total'] + 1e-3:
            sys.exit(f'{field}: class rows sum {check:.6f} != total {rows["total"]:.6f}')
        return rows

    rows = build('tot', 1e3, d['total'] * 1e3, d['port_nets'] * 1e3)
    has_area = all(v.get('area') is not None for v in d['class'].values())
    area = build('area', 1.0, None, 0.0) if has_area else None
    # u_peripheral leaf classes must partition u_peripheral's leaf cells
    keys = ['a_regs', 'w_regs', 'clk_buf', 'a_logic', 'w_logic', 'p_other'] + (['ka_enc', 'ka_in_buf'] if a.kind == 'af' else [])
    if sum(n('u_peripheral', k) for k in keys) != n('u_peripheral', 'ALL'):
        sys.exit('u_peripheral classes do not partition its leaf cells')
    hier = {k: v['tot'] * 1e3 for k, v in d['hier'].items()}
    cells = {f'{s}/{k}': v['cells'] for (s, k), v in d['class'].items()}
    out = dict(kind=a.kind, rows_mW=rows, rows_area_um2=area, hier_attr_mW=hier, cells=cells, info=d['info'],
               top_p_other=d['other'])
    if a.json:
        json.dump(out, open(a.json, 'w'), indent=2)
    order = ['total', 'u_pe', 'tiles', 'pe_pipes_glue', 'pe_clk_buf', 'a_edge', 'a_regs']
    order += ['ka_enc', 'ka_in_buf', 'therm'] if a.kind == 'af' else ['a_cmp', 'a_bank']
    order += ['w_edge', 'w_regs', 'w_cmp', 'w_bank']
    order += ['rng_words', 'rng_ctrl', 'rng_clk_buf'] if a.kind == 'af' else []
    order += ['periph_clk_buf', 'other', 'periph_other', 'top_glue', 'top_clk_buf', 'port_nets', 'u_peripheral_leaf_sum',
              'clock_buffers_all']
    for k in order:
        ar = f'{area[k]:11.1f} um2 ({100 * area[k] / area["total"]:5.2f} %)' if area else ''
        print(f'{k:22s} {rows[k]:10.4f} mW  ({100 * rows[k] / rows["total"]:5.2f} %)  {ar}')
    for k, v in hier.items():
        print(f'hier attribute {k:12s} {v:10.4f} mW')
    for i in d['info']:
        print('info', i)


if __name__ == '__main__':
    main()
