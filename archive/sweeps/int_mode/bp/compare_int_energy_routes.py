#!/usr/bin/env python3
"""Routed BP INT energy, point by point, on two routes (run_bp_int_energy.sh outputs).

Usage: compare_int_energy_routes.py NEW_OUT OLD_OUT [--out-name vs_old]
Reads <dir>/<label>/row.csv (status PASS) in both and, for every label present
in NEW_OUT, prints power, pJ/MAC (full and array), the hierarchy split and the
routed-GL approvals side by side; writes NEW_OUT/<out-name>.csv and .txt.
The operands of a label are identical on both routes (same generator and seed),
so a difference is the layout / netlist (and the lap contract, recorded in each
point's inputs.txt as lap_ring_only), not the data.
"""
import argparse
import csv
import re
from pathlib import Path


def rows(d):
    out = {}
    for p in sorted(Path(d).glob('*/row.csv')):
        st = p.parent / 'status'
        if st.is_file() and st.read_text().strip() == 'PASS':
            r = next(csv.DictReader(p.open()))
            inp = (p.parent / 'inputs.txt').read_text()
            m = re.search(r'^lap_ring_only=(\d)', inp, re.M)
            r['lap_ring_only'] = m[1] if m else '0'
            out[r['label']] = r
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('new')
    ap.add_argument('old')
    ap.add_argument('--out-name', default='vs_old_route')
    a = ap.parse_args()
    new, old = rows(a.new), rows(a.old)
    keys = ['power_mW', 'pJ_MAC', 'array_pJ_MAC', 'u_pe_mW', 'u_peripheral_mW', 'u_combiner_mW', 'sobol_mW']
    table, lines = [], []
    hdr = (f"{'label':24s} {'lap':>3s} {'MAC/cyc':>7s} {'P new':>7s} {'P old':>7s} {'pJ/MAC new':>10s} {'old':>7s} "
           f"{'delta%':>7s} {'arr new':>7s} {'arr old':>7s} {'u_pe new':>8s} {'old':>7s} {'periph new':>10s} {'old':>6s}")
    lines += [f'new = {a.new}', f'old = {a.old}', '', hdr, '-' * len(hdr)]
    for label, n in sorted(new.items()):
        o = old.get(label)
        rec = dict(label=label, lap_ring_only_new=n['lap_ring_only'], mac_per_cycle=float(n['mac_per_cycle']))
        for k in keys:
            rec[k + '_new'] = float(n[k])
            rec[k + '_old'] = float(o[k]) if o else ''
        rec['lap_ring_only_old'] = o['lap_ring_only'] if o else ''
        rec['approvals_new'] = f"ndi={n['approved_iopath_clamps']} iwsba={n['approved_interconnects']}"
        rec['approvals_old'] = f"ndi={o['approved_iopath_clamps']} iwsba={o['approved_interconnects']}" if o else ''
        rec['post_reset_violations_new'] = n['post_reset_timing_violations']
        table.append(rec)
        f = lambda v, s: format(v, s) if isinstance(v, float) else '-'
        d = 100 * (rec['pJ_MAC_new'] / rec['pJ_MAC_old'] - 1) if o else None
        lines.append(f"{label:24s} {n['lap_ring_only']:>3s} {rec['mac_per_cycle']:7.1f} {rec['power_mW_new']:7.3f} "
                     f"{f(rec['power_mW_old'], '7.3f'):>7s} {rec['pJ_MAC_new']:10.4f} {f(rec['pJ_MAC_old'], '7.4f'):>7s} "
                     f"{(format(d, '+7.2f') if d is not None else '-'):>7s} {rec['array_pJ_MAC_new']:7.4f} "
                     f"{f(rec['array_pJ_MAC_old'], '7.4f'):>7s} {rec['u_pe_mW_new']:8.3f} {f(rec['u_pe_mW_old'], '7.3f'):>7s} "
                     f"{rec['u_peripheral_mW_new']:10.3f} {f(rec['u_peripheral_mW_old'], '6.3f'):>6s}")
    lines.append('')
    lines.append('approvals (new / old): ' + '; '.join(f"{r['label']}: {r['approvals_new']} / {r['approvals_old']}"
                                                    for r in table))
    out = Path(a.new)
    with (out / f'{a.out_name}.csv').open('w', newline='') as fh:
        w = csv.DictWriter(fh, fieldnames=list(table[0]))
        w.writeheader()
        w.writerows(table)
    (out / f'{a.out_name}.txt').write_text('\n'.join(lines) + '\n')
    print('\n'.join(lines))


if __name__ == '__main__':
    main()
