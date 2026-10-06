#!/usr/bin/env python3
"""Classify the full DRC-marker population of a probe directory (sweeps/cbsg/af/run_drc_population.sh) and map the
second-pass (no-DRC-check) fillers.

  drc_population.py PROBE_DIR [PROBE_DIR ...] [--json OUT]

Per probe: markers by type/layer; by the objects involved (second-pass filler blockage FILLER_incr*, first-pass
filler, cell pin, regular wire, special wire); by the regular-wire net's hierarchy (u_peripheral kA encoders
g_a_row_*__u_ka, other u_peripheral, u_pe, u_rng, top); by distance from the east die edge (10 um bins); and the
cell (non-filler) under each marker centre.  Second-pass fillers: count, cell area, and per-east-distance bin;
kA-encoder cells: east-distance range.  Distances are measured from the die's east edge.
"""
import argparse, collections, json, re, sys
from pathlib import Path

BIN = 10.0


def hier(net):
    if re.match(r'u_peripheral/g_a_row_\d+__g_a_depth_\d+__u_ka/', net): return 'ka_encoder'
    if net.startswith('u_peripheral/'): return 'u_peripheral_other'
    if net.startswith('u_pe/'): return 'u_pe'
    if net.startswith('u_rng'): return 'u_rng'
    return 'top_or_other'


def objkind(o):
    o = o.strip()
    if re.match(r'Blockage of Cell FILLER_incr', o): return 'filler_pass2_blockage'
    if re.match(r'Blockage of Cell FILLER', o): return 'filler_pass1_blockage'
    if o.startswith('Blockage of Cell'): return 'cell_blockage'
    if o.startswith('Pin of Cell'): return 'cell_pin'
    if o.startswith('Regular Wire of Net') or o.startswith('Regular Via of Net'): return 'regular_wire'
    if o.startswith('Special Wire') or o.startswith('Special Via'): return 'special_wire'
    return 'other'


def analyse(d):
    d = Path(d)
    log = (d / 'innovus_probe.log').read_text(errors='replace')
    die_w, die_h = map(float, re.search(r'DRCPOP_DIE (\S+) (\S+)', log).groups())
    insts = []
    with open(d / 'insts.tsv') as f:
        next(f)
        for line in f:
            n, c, *b = line.rstrip('\n').split('\t')
            insts.append((n, c, *map(float, b)))
    # grid index of non-filler cells for "cell under marker"
    G = 5.0
    grid = collections.defaultdict(list)
    for i, (n, c, x1, y1, x2, y2) in enumerate(insts):
        if n.startswith('FILLER'): continue
        for gx in range(int(x1 // G), int(x2 // G) + 1):
            for gy in range(int(y1 // G), int(y2 // G) + 1):
                grid[(gx, gy)].append(i)

    def cell_at(x, y):
        for i in grid.get((int(x // G), int(y // G)), ()):
            n, c, x1, y1, x2, y2 = insts[i]
            if x1 <= x <= x2 and y1 <= y <= y2: return n
        return None

    out = dict(probe=str(d), die_um=[die_w, die_h])
    rpt = (d / 'drc_full.rpt').read_text(errors='replace') if (d / 'drc_full.rpt').exists() else ''
    marks = re.findall(r'^(\w+): \( ([^)]*) \) (.*?)  \( (\w+) \)\s*\nBounds : \( ([-\d.]+), ([-\d.]+) \) \( ([-\d.]+), ([-\d.]+) \)', rpt, re.M)
    m = re.search(r'Verification Complete : (\d+) Viols', log)
    out['markers_verify_drc'] = int(m[1]) if m else None
    out['markers_parsed'] = len(marks)
    C = collections.Counter
    by_type, by_pair, by_hier, by_east, by_cell_under, by_hier_east = C(), C(), C(), C(), C(), C()
    nets_ka = C()
    for typ, desc, objs, layer, x1, y1, x2, y2 in marks:
        x = (float(x1) + float(x2)) / 2; y = (float(y1) + float(y2)) / 2
        by_type[f'{typ}/{layer}'] += 1
        parts = [p for p in objs.split(' & ')]
        kinds = sorted(objkind(p) for p in parts)
        by_pair[' & '.join(kinds)] += 1
        nets = re.findall(r'(?:Regular Wire|Regular Via) of Net (\S+)', objs)
        h = hier(nets[0]) if nets else 'no_regular_net'
        by_hier[h] += 1
        e = int((die_w - x) // BIN) * int(BIN)
        by_east[e] += 1
        by_hier_east[(h, e)] += 1
        cu = cell_at(x, y)
        by_cell_under['none(gap/filler)' if cu is None else hier(cu + '/')] += 1
    out['by_type_layer'] = dict(by_type.most_common())
    out['by_object_pair'] = dict(by_pair.most_common())
    out['by_net_hierarchy'] = dict(by_hier.most_common())
    out['by_cell_under_marker'] = dict(by_cell_under.most_common())
    out['by_east_distance_um'] = {f'{k}-{k+int(BIN)}': v for k, v in sorted(by_east.items())}
    out['ka_encoder_markers_by_east_distance_um'] = {f'{e}-{e+int(BIN)}': v for (h, e), v in sorted(by_hier_east.items(), key=lambda t: t[0][1]) if h == 'ka_encoder'}
    # fillers and encoders
    f2 = [(x1, y1, x2, y2) for n, c, x1, y1, x2, y2 in insts if n.startswith('FILLER_incr')]
    f1 = [(x1, y1, x2, y2) for n, c, x1, y1, x2, y2 in insts if n.startswith('FILLER') and not n.startswith('FILLER_incr')]
    out['fillers_pass1'] = len(f1); out['fillers_pass2'] = len(f2)
    out['fillers_pass2_area_um2'] = round(sum((x2 - x1) * (y2 - y1) for x1, y1, x2, y2 in f2), 1)
    out['fillers_pass1_area_um2'] = round(sum((x2 - x1) * (y2 - y1) for x1, y1, x2, y2 in f1), 1)
    fe = C(int((die_w - (x1 + x2) / 2) // BIN) * int(BIN) for x1, y1, x2, y2 in f2)
    out['fillers_pass2_by_east_distance_um'] = {f'{k}-{k+int(BIN)}': v for k, v in sorted(fe.items())}
    ka = [(die_w - (x1 + x2) / 2) for n, c, x1, y1, x2, y2 in insts if re.match(r'u_peripheral/g_a_row_\d+__g_a_depth_\d+__u_ka/', n)]
    if ka:
        ka.sort()
        out['ka_encoder_cells'] = len(ka)
        out['ka_encoder_east_distance_um_p5_p50_p95'] = [round(ka[int(len(ka) * q)], 1) for q in (0.05, 0.5, 0.95)]
        ke = C(int(v // BIN) * int(BIN) for v in ka)
        out['ka_encoder_cells_by_east_distance_um'] = {f'{k}-{k+int(BIN)}': v for k, v in sorted(ke.items())}
    std = [(x2 - x1) * (y2 - y1) for n, c, x1, y1, x2, y2 in insts if not n.startswith('FILLER')]
    out['std_cells'] = len(std); out['std_cell_area_um2'] = round(sum(std), 1)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('probes', nargs='+')
    ap.add_argument('--json')
    a = ap.parse_args()
    res = [analyse(p) for p in a.probes]
    for r in res:
        print(f"== {r['probe']}  die {r['die_um']}  markers {r['markers_verify_drc']} (parsed {r['markers_parsed']})")
        for k in ('by_type_layer', 'by_object_pair', 'by_net_hierarchy', 'by_cell_under_marker', 'by_east_distance_um',
                  'ka_encoder_markers_by_east_distance_um', 'fillers_pass2_by_east_distance_um', 'ka_encoder_cells_by_east_distance_um'):
            if r.get(k): print(f'  {k}: {json.dumps(r[k])}')
        for k in ('fillers_pass1', 'fillers_pass2', 'fillers_pass1_area_um2', 'fillers_pass2_area_um2', 'std_cells',
                  'std_cell_area_um2', 'ka_encoder_cells', 'ka_encoder_east_distance_um_p5_p50_p95'):
            print(f'  {k}: {r.get(k)}')
    if a.json:
        Path(a.json).write_text(json.dumps(res, indent=2) + '\n')


if __name__ == '__main__':
    sys.exit(main())
