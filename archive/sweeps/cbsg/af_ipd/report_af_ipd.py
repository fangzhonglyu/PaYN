#!/usr/bin/env python3
"""Report of the C-BSG A-first + INT variant (AF-IPD: bit-plane INT mode with every-tile, 1-edge doubling) for
doc/cbsg_variants.md section 7.  Pure Python, no EDA tools, reads only.

Inputs (all read only):
  AF-IPD route        apr/build/TSMC22/PAYN_SC_CSA_CBSG_AF_IPD/cbsg_af_ipd_20261005_distguide_spp_pins_postfill
                      (reports/area.rpt, outputs/*.def DIEAREA, *.syn.sdc)
  AF-IPD campaign     build/power_char/cbsg_20261005/af_ipd/ (pinned/{result.csv, ladder/result.csv, classes_uniform/,
                      classes_ladder/, qualification.json, basin/basin_gate.json, gl_final/, gl_ladder/, routed_func/},
                      bootstrap/gl_bootstrap/, int_energy/<route>/{results.csv, <point>/gl/*.json})
  AF route            build/power_char/cbsg_20261005/af/pinned_fix/postfill/{qualification.json, measure/...}
  CSA / AF references build/power_char/cbsg_20261005/variants/{grid.csv, tsweep.csv, summary.json}
                      (sweeps/cbsg/compare_cbsg.py) and the CSA class split af/csa_baseline_power_classes/
  CSA pinned          build/power_char/pinned_pass2_20261004/csa/result.csv
  BP lap route        build/power_char/pinned_pass2_csa_bp_20261004_lap/results.csv (SC),
                      build/power_char/int_mode_energy_20261004_lap/bp/csa_bp_20261004_lap_distguide_spp_pins/
                      results_precise.csv (INT), its reports/area.rpt, and sweeps/int_mode/bp/model_lap_schedules.csv
                      (T1 = BP lap, T3 = 1-edge laps on the BP edge, estimate; section 10 supply readings)
  RTL / GL logs       build/cbsg/af_ipd/rtl_checks_summary.log, build/cbsg/af_ipd/gl/cbsg_af_ipd_20261005/
                      syn_gl_checks_summary.log, build/rtl_preflight/bp_ipd/grid/periods.txt (original IPD grid),
                      build/cbsg/af_ipd/route_debug/pt_{afipd,af}/pt.log (drain-rail arrival)

Conventions (as compare_cbsg.py): 400 MHz, K8 M16 N8, 512 kernel MACs per SC block, SC 64 MAC/cycle per PE.
Grid composites: P_R x P_C x PE core + P_R x (A edge + combiner) + P_C x W edge + edge clock buffers / leftovers
split half to each edge + one W bank; no skew, drain cycles or top-level rest.  4x8 = 4 PE rows x 8 PE columns.
The script recomputes compare_cbsg.py's CSA and AF composites with the same function and stops if they differ.
INT block period on a P_R x P_C grid: BW*NB + LAP*(BW-1) + (P_R+P_C-2) + 8*P_C, NB = L/128; LAP = 1 (AF-IPD), 8 (BP).

Writes OUT/report_af_ipd.md (every block) and OUT/report_af_ipd.json (default OUT
build/power_char/cbsg_20261005/af_ipd/report).  --doc PATH replaces every
<!-- BEGIN af_ipd:NAME --> ... <!-- END af_ipd:NAME --> region of that doc with block NAME (summary, area, sc, int,
tput, verify, caveats).  The prefix differs from compare_cbsg.py's "generated:", so neither script touches the other's
blocks.  The qualitative claims of the doc's hand-written section 7 prose are asserted here.

  PYTHONDONTWRITEBYTECODE=1 python3 sweeps/cbsg/af_ipd/report_af_ipd.py [--out DIR] [--doc doc/cbsg_variants.md]
"""
import argparse
import csv
import json
import re
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
PC = REPO / 'build/power_char'
CAMP = PC / 'cbsg_20261005'
AFIPD = CAMP / 'af_ipd'
PIN = AFIPD / 'pinned'
RUN = 'cbsg_af_ipd_20261005_distguide_spp_pins_postfill'
ROUTE = REPO / 'apr/build/TSMC22/PAYN_SC_CSA_CBSG_AF_IPD' / RUN
TOP = 'payn_array_signed_segmented_csa_cbsg_af_ipd'
INTDIR = AFIPD / 'int_energy' / RUN
AFM = CAMP / 'af/pinned_fix/postfill'
AF_ROUTE = REPO / 'apr/build/TSMC22/PAYN_SC_CSA_CBSG_AF/cbsg_af_20261005_distguide_spp_pins_postfill'
VAR = CAMP / 'variants'
BP_RUN = 'csa_bp_20261004_lap_distguide_spp_pins'
BP_AREA_RPT = REPO / 'apr/build/TSMC22/PAYN_SC_CSA_BP' / BP_RUN / 'reports/area.rpt'
MODEL = REPO / 'sweeps/int_mode/bp/model_lap_schedules.csv'
RTL_SUM = REPO / 'build/cbsg/af_ipd/rtl_checks_summary.log'
SYN_GL_SUM = REPO / 'build/cbsg/af_ipd/gl/cbsg_af_ipd_20261005/syn_gl_checks_summary.log'
IPD_PERIODS = REPO / 'build/rtl_preflight/bp_ipd/grid/periods.txt'
DBG = REPO / 'build/cbsg/af_ipd/route_debug'

F_GHZ = 0.4
T_NS = 1.0 / F_GHZ
SC_MPC = 64                       # SC kernel MACs per cycle per PE at T = 128
MB = 512                          # kernel MACs per SC block
GRIDS = {'1 PE': (1, 1), '4x4': (4, 4), '4x8': (4, 8)}
PREC = {'INT8': (8, 8), 'W4A8': (8, 4), 'INT4': (4, 4)}     # (BA, BW)
LAP = {'AF-IPD': 1, 'BP lap': 8}
POINTS = [   # label, window
    ('int8_uniform_L49152_d', 'data only (peak)'),
    ('int8_uniform_L1024_dr', 'data + laps'),
    ('int8_uniform_L1024_all', 'data + laps + drain'),
    ('w4a8_uniform_L1024_dr', 'data + laps'),
    ('int4_uniform_L98304_d', 'data only (peak)'),
    ('int4_uniform_L1024_dr', 'data + laps'),
    ('int4_uniform_L1024_all', 'data + laps + drain'),
]
AF_PIN_BASIS = 'pinned route (qualified, grid basin)'
CSA_BASIS = 'pinned route (qualified)'


# ------------------------------------------------------------------------------------------------ helpers
def rcsv(p):
    with open(p, newline='') as f:
        return list(csv.DictReader(f))


def jload(p):
    return json.loads(Path(p).read_text())


def close(a, b, tol, what):
    assert abs(a - b) <= tol, f'{what}: {a} vs {b} (tol {tol})'


def pct(a, b):
    return f'{100 * (a / b - 1):+.1f}%'


def c0(x):
    return f'{x:,.0f}'


def c1(x):
    return f'{x:,.1f}'


def fl(L):
    return f'{L:,}' if L >= 10000 else str(L)


def area_rpt(path, top, names):
    """Total of the top row and the Total Area of each first-level hierarchy in names (area.rpt layout)."""
    out = {}
    for line in Path(path).read_text().splitlines():
        f = line.split()
        if not f:
            continue
        if f[0] == top and 'total' not in out:
            out['total'] = float(f[2])
        elif f[0] in names and f[0] not in out:
            out[f[0]] = float(f[3])
    assert 'total' in out and all(n in out for n in names), f'{path}: {sorted(out)}'
    return out


def die_um(def_path):
    units = None
    with open(def_path) as f:
        for line in f:
            m = re.match(r'UNITS DISTANCE MICRONS (\d+)', line)
            if m:
                units = int(m[1])
            m = re.match(r'DIEAREA \( 0 0 \) \( (\d+) (\d+) \)', line)
            if m:
                assert units
                return int(m[1]) / units, int(m[2]) / units
    raise AssertionError(f'{def_path}: no DIEAREA')


# ---------------------------------------------------------------------------------------- class records
SUMKEYS = ('u_pe', 'a_edge', 'w_edge', 'shared', 'bank', 'comb', 'top_rest')


def cls_csa(x):
    return dict(total=x['total'], u_pe=x['u_pe'], a_edge=x['a_regs'] + x['a_cmp'], w_edge=x['w_regs'] + x['w_cmp'],
                shared=x['periph_clk_buf'] + x['periph_other'], bank=x['a_bank'] + x['w_bank'], comb=0.0,
                top_rest=x['top_glue'] + x['top_clk_buf'] + x.get('port_nets', 0.0))


def cls_af(x):
    return dict(total=x['total'], u_pe=x['u_pe'], a_edge=x['a_edge'], w_edge=x['w_edge'],
                shared=x['periph_clk_buf'] + x['periph_other'], bank=x['w_bank'], comb=0.0,
                top_rest=x['top_glue'] + x['top_clk_buf'] + x['port_nets'])


def cls_afipd(x):
    return dict(total=x['total'], u_pe=x['u_pe'], a_edge=x['a_edge'], w_edge=x['w_edge'],
                shared=x['periph_clk_buf'] + x['periph_other'] + x['sel_shared'], bank=x['w_bank'], comb=x['combiner'],
                top_rest=x['top_glue'] + x['top_clk_buf'] + x['port_nets'])


def check_sum(d, what):
    s = sum(d[k] for k in SUMKEYS)
    assert abs(s - d['total']) <= 1e-6 * d['total'] + 2e-3, f'{what}: parts {s} != total {d["total"]}'
    return d


def comp(c, pr, pc):
    """Split-form grid composite (area or power) from a per-PE class record."""
    return (pr * pc * c['u_pe'] + pr * (c['a_edge'] + c['shared'] / 2 + c['comb'])
            + pc * (c['w_edge'] + c['shared'] / 2) + c['bank'])


def comp_sym(c, pr, pc):
    """The project's symmetric form: (P_R + P_C)/2 x u_peripheral."""
    return pr * pc * c['u_pe'] + (pr + pc) / 2 * (c['a_edge'] + c['w_edge'] + c['shared']) + pr * c['comb'] + c['bank']


def sc_gmacs(area_um2, n_pe):
    return n_pe * SC_MPC * F_GHZ / (area_um2 * 1e-6)


def per_mac(p_mw, window, blocks, n_pe=1):
    return p_mw * window * T_NS / (n_pe * blocks * MB)


# ------------------------------------------------------------------------------------------ INT schedule
def peak_pe(prec):
    ba, bw = PREC[prec]
    return 64 * (128 // (ba * bw))        # MAC per PE per data edge: 128 / 256 / 512


def period(prec, L, pr, pc, lap):
    bw = PREC[prec][1]
    assert L % 128 == 0
    nb = L // 128
    return bw * nb + lap * (bw - 1) + (pr + pc - 2) + 8 * pc, bw * nb


def int_gmacs(prec, L, pr, pc, lap, area_um2):
    p, d = period(prec, L, pr, pc, lap)
    return pr * pc * peak_pe(prec) * d / p * F_GHZ / (area_um2 * 1e-6)


# ------------------------------------------------------------------------------------------------ inputs
def load():
    S = {}
    # --- AF-IPD route and campaign
    ar = area_rpt(ROUTE / 'reports/area.rpt', TOP, ('u_pe', 'u_peripheral', 'u_combiner', 'u_rng'))
    u = rcsv(PIN / 'result.csv')[0]
    lad = rcsv(PIN / 'ladder/result.csv')[0]
    assert u['run'] == RUN and lad['run'] == RUN and u['status'] == 'PASS' and lad['status'] == 'PASS'
    cu, cl = jload(PIN / 'classes_uniform/power_classes.json'), jload(PIN / 'classes_ladder/power_classes.json')
    assert cu['kind'] == 'afipd' and cl['kind'] == 'afipd'
    S['afipd'] = dict(
        area=check_sum(cls_afipd(cu['rows_area_um2']), 'afipd area'),
        uni=check_sum(cls_afipd(cu['rows_mW']), 'afipd uniform power'),
        lad=check_sum(cls_afipd(cl['rows_mW']), 'afipd ladder power'),
        rows_area=cu['rows_area_um2'], rows_uni=cu['rows_mW'], rows_lad=cl['rows_mW'], res_u=u, res_l=lad, rpt=ar)
    close(S['afipd']['area']['total'], ar['total'], 1e-3, 'afipd class area vs area.rpt')
    close(float(u['area_um2']), ar['total'], 1e-3, 'afipd result.csv area vs area.rpt')
    close(ar['u_pe'] + ar['u_peripheral'] + ar['u_combiner'] + ar['u_rng'] + S['afipd']['area']['top_rest'],
          ar['total'], 2e-3, 'afipd hierarchy + top rest')
    close(S['afipd']['uni']['total'], float(u['power_mW']), 1e-4, 'afipd uniform class total vs result')
    close(S['afipd']['lad']['total'], float(lad['power_mW']), 1e-4, 'afipd ladder class total vs result')
    S['q'] = jload(PIN / 'qualification.json')
    S['basin'] = jload(PIN / 'basin/basin_gate.json')
    S['rf'] = jload(PIN / 'routed_func/summary.json')
    S['die'] = die_um(next((ROUTE / 'outputs').glob('*.apr.def')))
    S['die_af'] = die_um(next((AF_ROUTE / 'outputs').glob('*.apr.def')))
    # --- AF route
    afr = jload(AFM / 'measure/result.json')
    afu, afl = afr[0], afr[1]
    acu, acl = jload(AFM / 'measure/classes_uniform/power_classes.json'), jload(AFM / 'measure/classes_ladder/power_classes.json')
    S['af'] = dict(area=check_sum(cls_af(acu['rows_area_um2']), 'af area'),
                   uni=check_sum(cls_af(acu['rows_mW']), 'af uniform power'),
                   lad=check_sum(cls_af(acl['rows_mW']), 'af ladder power'),
                   rows_area=acu['rows_area_um2'], rows_uni=acu['rows_mW'], rows_lad=acl['rows_mW'], res_u=afu, res_l=afl,
                   q=jload(AFM / 'qualification.json'))
    close(S['af']['uni']['total'], afu['power_mW'], 1e-4, 'af uniform')
    close(S['af']['lad']['total'], afl['power_mW'], 1e-4, 'af ladder')
    # same SC stimulus as AF (asserted on the GL traces' statistics)
    for r, a, w in ((u, afu, 'uniform'), (lad, afl, 'ladder')):
        assert int(r['blocks']) == a['blocks'] and int(r['window_clocks']) == a['window_clocks'], w
        close(float(r['mean_kA']), a['mean_kA'], 1e-9, f'{w} mean kA vs AF')
        close(float(r['a_one_density']), a['a_one_density'], 1e-12, f'{w} A-one density vs AF')
    # --- CSA
    csc = jload(CAMP / 'af/csa_baseline_power_classes/power_classes.json')
    csa_res = rcsv(PC / 'pinned_pass2_20261004/csa/result.csv')[0]
    S['csa'] = dict(area=check_sum(cls_csa(csc['rows_area_um2']), 'csa area'),
                    uni=check_sum(cls_csa(csc['rows_mW']), 'csa power'), res=csa_res)
    close(S['csa']['uni']['total'], float(csa_res['power_mW']), 1e-4, 'csa power')
    # compare_cbsg.py references: grid composites and the CSA ladder-equivalent
    grid = {(r['design'], r['grid']): r for r in rcsv(VAR / 'grid.csv') if r['basis'] in (AF_PIN_BASIS, CSA_BASIS)}
    S['ref_grid'] = grid
    ts = {(r['design'], r['tag']): r for r in rcsv(VAR / 'tsweep.csv')}
    S['csa_ladder'] = ts[('csa', 'ladder')]
    close(float(ts[('af', 'ladder')]['power_mW']), afl['power_mW'], 1e-5, 'tsweep AF ladder vs AF measure')
    close(float(ts[('csa', 'T128')]['power_mW']), float(csa_res['power_mW']), 1e-5, 'tsweep CSA T128 vs baseline')
    assert int(S['csa_ladder']['window']) == int(lad['window_clocks']) and int(S['csa_ladder']['blocks']) == int(lad['blocks'])
    S['params'] = jload(VAR / 'summary.json')['params']
    # --- BP lap
    bps = next(r for r in rcsv(PC / 'pinned_pass2_csa_bp_20261004_lap/results.csv')
               if r['label'] == 'bp_lap' and r['pins'] == 'pinned')
    assert bps['run'] == BP_RUN, bps['run']
    S['bp_sc'] = bps
    S['bp_rpt'] = area_rpt(BP_AREA_RPT, 'payn_array_signed_segmented_csa_bp',
                           ('u_pe', 'u_peripheral', 'u_combiner', 'u_a_rng', 'u_w_rng'))
    close(S['bp_rpt']['total'], float(bps['area_um2']), 1e-3, 'bp lap area')
    S['int'] = {r['label']: r for r in rcsv(INTDIR / 'results.csv')}
    S['bp_int'] = {r['label']: r for r in rcsv(PC / 'int_mode_energy_20261004_lap/bp' / BP_RUN / 'results_precise.csv')}
    S['model'] = rcsv(MODEL)
    return S


# ------------------------------------------------------------------------------------------------ blocks
def block_area(S, R):
    A = {d: S[d]['area'] for d in ('csa', 'af', 'afipd')}
    rg = S['ref_grid']
    # gate: this composite reproduces compare_cbsg.py's CSA and AF composites (area, SC GMAC/s/mm2)
    for d, key in (('csa', 'CSA'), ('af', 'AF')):
        for g in ('4x4', '4x8'):
            pr, pc = GRIDS[g]
            close(comp(A[d], pr, pc), float(rg[(key, g)]['area_um2']), 1e-3, f'{key} {g} composite area')
            close(sc_gmacs(comp(A[d], pr, pc), pr * pc), float(rg[(key, g)]['gmacs_mm2']), 1e-6, f'{key} {g} GMAC/s/mm2')
    tot = {d: A[d]['total'] for d in A}
    gar = {d: {g: (tot[d] if g == '1 PE' else comp(A[d], *GRIDS[g])) for g in GRIDS} for d in A}
    gm = {d: {g: sc_gmacs(gar[d][g], GRIDS[g][0] * GRIDS[g][1]) for g in GRIDS} for d in A}
    ra, raf = S['afipd']['rows_area'], S['af']['rows_area']
    remap = ra['ka_enc'] - raf['ka_enc']                     # routed kA encoder growth (same RTL)
    nore = {g: gar['afipd'][g] - (1 if g == '1 PE' else GRIDS[g][0]) * remap for g in GRIDS}
    R['area'] = dict(composite=gar, gmacs=gm, remap_um2=remap, no_remap=nore,
                     sym={g: comp_sym(A['afipd'], *GRIDS[g]) for g in ('4x4', '4x8')})

    def trio(fn, fmt):
        return ' / '.join(fmt(fn(g)) for g in GRIDS)
    L = ['| | CSA | AF | AF-IPD | AF-IPD vs CSA | AF-IPD vs AF |', '|---|---:|---:|---:|---:|---:|']
    for g, lab in (('1 PE', 'area, 1 PE route (um2)'), ('4x4', 'area, 4x4 grid composite (um2)'),
                   ('4x8', 'area, 4x8 grid composite (um2)')):
        L.append(f"| {lab} | {c1(gar['csa'][g])} | {c1(gar['af'][g])} | **{c1(gar['afipd'][g])}** | "
                 f"{pct(gar['afipd'][g], gar['csa'][g])} | {pct(gar['afipd'][g], gar['af'][g])} |")
    n48 = 32
    L.append(f"| area per PE in the 4x8 composite (um2) | {c1(gar['csa']['4x8'] / n48)} | {c1(gar['af']['4x8'] / n48)} | "
             f"{c1(gar['afipd']['4x8'] / n48)} | | |")
    L.append(f"| SC GMAC/s/mm2, 1 PE / 4x4 / 4x8 | {trio(lambda g: gm['csa'][g], c1)} | {trio(lambda g: gm['af'][g], c1)} | "
             f"**{trio(lambda g: gm['afipd'][g], c1)}** | {trio(lambda g: gm['afipd'][g] / gm['csa'][g], lambda x: f'{100 * (x - 1):+.1f}%')} | "
             f"{trio(lambda g: gm['afipd'][g] / gm['af'][g], lambda x: f'{100 * (x - 1):+.1f}%')} |")
    L.append(f"| AF-IPD without the kA encoder remap (estimate), 1 PE / 4x4 / 4x8 (um2) | | | "
             f"{trio(lambda g: nore[g], c0)} | {trio(lambda g: nore[g] / gar['csa'][g], lambda x: f'{100 * (x - 1):+.1f}%')} | "
             f"{trio(lambda g: nore[g] / gar['af'][g], lambda x: f'{100 * (x - 1):+.1f}%')} |")
    L.append('')
    L.append('Where the area goes (route cell area, um2) and how each part scales on a grid:')
    L.append('')
    L.append('| part | one per | AF-IPD | AF | change |')
    L.append('|---|---|---:|---:|---:|')
    parts = [
        ('PE core: tiles, bit/sign pipes, PE clock buffers', 'PE', ra['u_pe'] - ra['dbl_mux'] - ra['dbl_sel'], raf['u_pe']),
        ('PE core: per-tile doubling muxes + lap select tree', 'PE', ra['dbl_mux'] + ra['dbl_sel'], 0.0),
        ('A edge: 64 kA encoders (DC remap with the INT bypass; RTL unchanged)', 'PE row', ra['ka_enc'], raf['ka_enc']),
        ('A edge: thermometers (+ A bypass, merged), registers, encoder input buffers', 'PE row',
         ra['a_edge'] - ra['ka_enc'], raf['a_edge'] - raf['ka_enc']),
        ('W edge: comparators (+ W bypass, merged), registers', 'PE column', ra['w_edge'], raf['w_edge']),
        ('combiner', 'PE row', ra['combiner'], 0.0),
        ('edge clock buffers, leftovers, shared bypass select', 'half per edge', A['afipd']['shared'], A['af']['shared']),
        ('W bank (AF block clock)', 'grid', A['afipd']['bank'], A['af']['bank']),
        ('top-level rest (not in the composites)', '-', A['afipd']['top_rest'], A['af']['top_rest']),
    ]
    close(sum(p[2] for p in parts), tot['afipd'], 2e-3, 'afipd area parts')
    close(sum(p[3] for p in parts), tot['af'], 2e-3, 'af area parts')
    for name, per, x, y in parts:
        L.append(f"| {name} | {per} | {c1(x)} | {c1(y) if y else '-'} | {x - y:+,.1f} |")
    L.append(f"| **total** | | **{c1(tot['afipd'])}** | **{c1(tot['af'])}** | **{tot['afipd'] - tot['af']:+,.1f}** |")
    L.append('')
    afa = A['afipd']
    dpe = ra['u_pe'] - raf['u_pe']
    drow = (afa['a_edge'] + afa['comb']) - A['af']['a_edge']
    L.append(f"- Per PE the INT hardware adds {dpe:+,.1f} um2 ({pct(ra['u_pe'], raf['u_pe'])} of the PE core): the doubling muxes "
             f"and lap select ({ra['dbl_mux'] + ra['dbl_sel']:,.1f}), less {raf['u_pe'] - (ra['u_pe'] - ra['dbl_mux'] - ra['dbl_sel']):,.1f} "
             f"by which the rest of the core (tiles, pipes, clock buffers) routed smaller than AF's. Per PE row it adds {drow:+,.1f} (A edge and combiner), of which "
             f"{remap:,.1f} is the kA encoder remap; per PE column {afa['w_edge'] - A['af']['w_edge']:+,.1f} (W edge).")
    cs = A['csa']
    d_core = afa['u_pe'] - cs['u_pe']
    d_row = (afa['a_edge'] + afa['shared'] / 2 + afa['comb']) - (cs['a_edge'] + cs['shared'] / 2 + cs['comb'])
    d_col = (afa['w_edge'] + afa['shared'] / 2) - (cs['w_edge'] + cs['shared'] / 2)
    assert d_core > 0 and d_row > 0 and d_col < 0
    L.append(f"- So the overhead over AF shrinks on a grid ({pct(gar['afipd']['1 PE'], gar['af']['1 PE'])} at 1 PE, "
             f"{pct(gar['afipd']['4x4'], gar['af']['4x4'])} at 4x4, {pct(gar['afipd']['4x8'], gar['af']['4x8'])} at 4x8). "
             f"Against the CSA, AF-IPD's PE core is {d_core:+,.1f} um2 ({pct(afa['u_pe'], cs['u_pe'])}), each PE row's "
             f"A edge and combiner {d_row:+,.1f} and each PE column's W edge {d_col:+,.1f}, so AF-IPD is "
             f"{pct(gar['afipd']['1 PE'], gar['csa']['1 PE'])} at 1 PE, "
             f"{pct(gar['afipd']['4x4'], gar['csa']['4x4'])} at 4x4, and {pct(gar['afipd']['4x8'], gar['csa']['4x8'])} at "
             f"4x8, where the eight W edges win part of it back.")
    L.append(f"- Without the remap (the encoders mapped as in AF, {remap:,.1f} um2 less per A edge) AF-IPD would be "
             f"{pct(nore['1 PE'], gar['csa']['1 PE'])} / {pct(nore['4x4'], gar['csa']['4x4'])} / {pct(nore['4x8'], gar['csa']['4x8'])} "
             f"against the CSA at 1 PE / 4x4 / 4x8. This is an estimate: it assumes the routed encoders would shrink by exactly "
             f"the routed difference.")
    L.append(f"- The composite is compare_cbsg.py's (section 1) plus one combiner per PE row, and it reproduces that script's "
             f"CSA and AF composites (asserted). The symmetric form, (P_R + P_C)/2 x the whole peripheral, gives "
             f"{c1(R['area']['sym']['4x4'])} / {c1(R['area']['sym']['4x8'])} um2 for AF-IPD at 4x4 / 4x8 "
             f"({pct(R['area']['sym']['4x8'], gar['afipd']['4x8'])} at 4x8), because AF-IPD's A edge is "
             f"{afa['a_edge'] / afa['w_edge']:.1f}x its W edge.")
    return '\n'.join(L)


def block_sc(S, R):
    D = {d: S[d] for d in ('csa', 'af', 'afipd')}
    u, lad = S['afipd']['res_u'], S['afipd']['res_l']
    win_u, blk_u = int(u['window_clocks']), int(u['blocks'])
    win_l, blk_l = int(lad['window_clocks']), int(lad['blocks'])
    pu = {d: D[d]['uni']['total'] for d in D}
    eu = {d: per_mac(pu[d], win_u, blk_u) for d in D}
    close(eu['afipd'], float(u['pJ_MAC']), 1e-9, 'afipd pJ/MAC')
    close(eu['csa'], float(S['csa']['res']['pJ_MAC']), 1e-9, 'csa pJ/MAC')
    gp = {d: {g: per_mac(comp(D[d]['uni'], *GRIDS[g]), win_u, blk_u, GRIDS[g][0] * GRIDS[g][1]) for g in ('4x4', '4x8')}
          for d in D}
    rg = S['ref_grid']
    for d, key in (('csa', 'CSA'), ('af', 'AF')):
        for g in ('4x4', '4x8'):
            close(gp[d][g], float(rg[(key, g)]['uniform_pJ_MAC']), 1e-9, f'{key} {g} composite pJ/MAC')
    pl = {'af': D['af']['lad']['total'], 'afipd': D['afipd']['lad']['total'], 'csa': float(S['csa_ladder']['power_mW'])}
    el = {d: per_mac(pl[d], win_l, blk_l) for d in pl}
    close(el['csa'], float(S['csa_ladder']['pJ_MAC']), 1e-9, 'csa ladder-equivalent pJ/MAC')
    close(el['afipd'], float(lad['pJ_MAC']), 1e-9, 'afipd ladder pJ/MAC')
    R['sc'] = dict(uniform_mW=pu, uniform_pJ=eu, grid_pJ=gp, ladder_mW=pl, ladder_pJ=el)
    L = ['| | CSA | AF | AF-IPD | AF-IPD vs CSA | AF-IPD vs AF |', '|---|---:|---:|---:|---:|---:|']
    L.append(f"| SC power, uniform L = 128, 1 PE (mW) | {pu['csa']:.3f} | {pu['af']:.3f} | **{pu['afipd']:.3f}** | "
             f"{pct(pu['afipd'], pu['csa'])} | {pct(pu['afipd'], pu['af'])} |")
    L.append(f"| energy per kernel MAC, uniform, 1 PE (pJ) | {eu['csa']:.4f} | {eu['af']:.4f} | **{eu['afipd']:.4f}** | "
             f"{pct(eu['afipd'], eu['csa'])} | {pct(eu['afipd'], eu['af'])} |")
    L.append('| energy per MAC, uniform, 4x4 / 4x8 grid composite (pJ) | '
             + ' | '.join(f"{gp[d]['4x4']:.4f} / {gp[d]['4x8']:.4f}" for d in ('csa', 'af'))
             + f" | **{gp['afipd']['4x4']:.4f} / {gp['afipd']['4x8']:.4f}** | "
             + ' / '.join(pct(gp['afipd'][g], gp['csa'][g]) for g in ('4x4', '4x8')) + ' | '
             + ' / '.join(pct(gp['afipd'][g], gp['af'][g]) for g in ('4x4', '4x8')) + ' |')
    L.append(f"| per-row ladder, 1 PE (mW; CSA: ladder-equivalent) | {pl['csa']:.3f} | {pl['af']:.3f} | **{pl['afipd']:.3f}** | "
             f"{pct(pl['afipd'], pl['csa'])} | {pct(pl['afipd'], pl['af'])} |")
    L.append(f"| per-row ladder, 1 PE (pJ/MAC) | {el['csa']:.4f} | {el['af']:.4f} | **{el['afipd']:.4f}** | "
             f"{pct(el['afipd'], el['csa'])} | {pct(el['afipd'], el['af'])} |")
    L.append('')
    # where the SC delta goes
    xu, xl, xa = S['afipd']['rows_uni'], S['afipd']['rows_lad'], S['afipd']['rows_area']
    yu, yl = S['af']['rows_uni'], S['af']['rows_lad']
    g0 = lambda r, ks: sum(r.get(k, 0.0) for k in ks)
    groups = [
        ('64 kA encoders (the DC remap)', ['ka_enc'], ['ka_enc']),
        ('PE bit/sign pipes + core glue', ['pe_pipes_glue'], ['pe_pipes_glue']),
        ('64 tiles', ['tiles'], ['tiles']),
        ('per-tile doubling muxes + lap select', ['dbl_mux', 'dbl_sel'], []),
        ('thermometers (+ A bypass, merged)', ['therm_byp'], ['therm']),
        ('W comparators (+ W bypass, merged)', ['w_cmp_byp'], ['w_cmp']),
        ('combiner', ['combiner'], []),
        ('A / W registers, encoder input buffers, W bank, edge clock buffers, shared select',
         ['a_regs', 'w_regs', 'ka_in_buf', 'w_bank', 'periph_clk_buf', 'periph_other', 'sel_shared'],
         ['a_regs', 'w_regs', 'ka_in_buf', 'w_bank', 'periph_clk_buf', 'periph_other']),
        ('PE clock buffers + top-level rest', ['pe_clk_buf', 'top_glue', 'top_clk_buf', 'port_nets'],
         ['pe_clk_buf', 'top_glue', 'top_clk_buf', 'port_nets']),
    ]
    for r in (xu, xl):
        close(sum(g0(r, g[1]) for g in groups), r['total'], 2e-3, 'afipd SC groups')
    for r in (yu, yl):
        close(sum(g0(r, g[2]) for g in groups), r['total'], 2e-3, 'af SC groups')
    L.append(f"Where the SC power difference to AF goes (PT cell power by class, mW; rows add up to the PT totals):")
    L.append('')
    L.append('| part | AF-IPD, uniform | AF, uniform | change, uniform | change, ladder |')
    L.append('|---|---:|---:|---:|---:|')
    for name, ka, kb in groups:
        L.append(f"| {name} | {g0(xu, ka):.3f} | {g0(yu, kb):.3f} | {g0(xu, ka) - g0(yu, kb):+.3f} | {g0(xl, ka) - g0(yl, kb):+.3f} |")
    L.append(f"| **total** | **{xu['total']:.3f}** | **{yu['total']:.3f}** | **{xu['total'] - yu['total']:+.3f}** | "
             f"**{xl['total'] - yl['total']:+.3f}** |")
    L.append('')
    d_enc = xu['ka_enc'] - yu['ka_enc']
    d_tot = xu['total'] - yu['total']
    wide = S['die'][0] / S['die_af'][0] - 1
    R['sc'].update(remap_mW=d_enc, no_remap_delta_mW=d_tot - d_enc)
    L.append(f"- Same stimulus as the AF campaign (asserted: blocks, window, mean kA and A-one density equal AF's for both "
             f"workloads); drains bit-exact; power excludes the drain.")
    L.append(f"- The kA encoder remap costs {d_enc:+.3f} mW of the {d_tot:+.3f} mW. Without it AF-IPD would be "
             f"{d_tot - d_enc:+.3f} mW ({100 * (d_tot - d_enc) / yu['total']:+.1f}%) over AF at uniform L = 128 (estimate).")
    L.append(f"- The pipes and core glue carry the same flops in both designs; their {xu['pe_pipes_glue'] - yu['pe_pipes_glue']:+.3f} mW "
             f"is attributed to longer broadcast wiring on a die {100 * wide:.1f}% wider ({S['die'][0]:.2f} x {S['die'][1]:.2f} um against "
             f"{S['die_af'][0]:.2f} x {S['die_af'][1]:.2f}); the register-level split is in "
             f"`build/cbsg/af_ipd/route_debug/core_{{af,afipd}}/`.")
    L.append(f"- The ladder has no grid composite here: a grid runs one block length (section 3.1), and AF-IPD has no "
             f"held-ladder run.")
    return '\n'.join(L)


def block_int(S, R):
    A, B = S['int'], S['bp_int']
    rows = []
    for lab, win in POINTS:
        a, b = A[lab], B[lab]
        assert a['status'] == 'PASS' and b['status'] == 'PASS', lab
        assert a['route'] == RUN and b['route'] == BP_RUN
        prec = a['precision']
        ba, bw = PREC[prec]
        # same operands and windows as the BP lap campaign
        for k in ('precision', 'dist', 'L', 'blocks', 'saif_mode', 'data_cycles', 'drain_cycles', 'macs_checked',
                  'tiles_checked', 'outputs_checked', 'max_abs_tile', 'max_abs_output', 'mac_per_data_cycle'):
            assert a[k] == b[k], f'{lab}: {k} {a[k]} vs {b[k]}'
        blocks, data = int(a['blocks']), int(a['data_cycles'])
        assert float(a['mac_per_data_cycle']) == peak_pe(prec)
        for d, r in (('AF-IPD', a), ('BP lap', b)):
            ring, drain, act = int(r['ring_cycles']), int(r['drain_cycles']), int(r['active_cycles'])
            mode = int(r['saif_mode'])
            assert ring == (0 if mode == 1 else blocks * LAP[d] * (bw - 1)), f'{lab} {d} laps {ring}'
            assert drain == (blocks * 8 if mode == 2 else 0), f'{lab} {d} drain {drain}'
            assert act == data + ring + drain
            close(float(r['mac_per_cycle']), peak_pe(prec) * data / act, 1e-9, f'{lab} {d} MAC/cycle')
            close(float(r['pJ_MAC']), float(r['power_mW']) * act * T_NS / int(r['macs_checked']), 1e-9, f'{lab} {d} pJ/MAC')
        rows.append(dict(label=lab, prec=prec, L=int(a['L']), win=win, a=a, b=b,
                         ratio=float(a['pJ_MAC']) / float(b['pJ_MAC'])))
    # claims of the hand-written prose: every lap window is cheaper than BP lap, the peaks are within 2% above
    assert all(r['ratio'] < 1 for r in rows if r['win'] != 'data only (peak)')
    assert all(1 < r['ratio'] < 1.02 for r in rows if r['win'] == 'data only (peak)')
    R['int'] = [dict(label=r['label'], afipd_pJ_MAC=float(r['a']['pJ_MAC']), bp_lap_pJ_MAC=float(r['b']['pJ_MAC']),
                     ratio=r['ratio'], afipd_mac_per_cycle=float(r['a']['mac_per_cycle']),
                     bp_lap_mac_per_cycle=float(r['b']['mac_per_cycle'])) for r in rows]
    L = ['| point | window | MAC/cycle, AF-IPD / BP lap | power (mW), AF-IPD / BP lap | pJ/MAC AF-IPD | pJ/MAC BP lap | '
         'AF-IPD vs BP lap | PE core (u_pe) pJ/MAC, AF-IPD / BP lap |', '|---|---|---:|---:|---:|---:|---:|---:|']
    for r in rows:
        a, b = r['a'], r['b']
        L.append(f"| {r['prec']}, L = {fl(r['L'])} | {r['win']} | {float(a['mac_per_cycle']):.1f} / {float(b['mac_per_cycle']):.1f} | "
                 f"{float(a['power_mW']):.3f} / {float(b['power_mW']):.3f} | **{float(a['pJ_MAC']):.4f}** | {float(b['pJ_MAC']):.4f} | "
                 f"{100 * (r['ratio'] - 1):+.1f}% | {float(a['array_pJ_MAC']):.4f} / {float(b['array_pJ_MAC']):.4f} |")
    L.append('')
    i8 = next(r for r in rows if r['label'] == 'int8_uniform_L1024_dr')
    a, b = i8['a'], i8['b']
    busy = lambda r: int(r['data_cycles']) / int(r['active_cycles'])
    lap_blk = lambda r: int(r['ring_cycles']) // int(r['blocks'])
    pk = [r for r in rows if r['win'] == 'data only (peak)']
    p8 = pk[0]
    dpe = float(p8['a']['u_pe_mW']) - float(p8['b']['u_pe_mW'])
    dper = float(p8['a']['u_peripheral_mW']) - float(p8['b']['u_peripheral_mW'])
    L.append(f"- Same operands, block counts and windows as the BP lap campaign (asserted per point: blocks, data and drain "
             f"cycles, MACs, tiles and outputs checked, max |tile| and |output|). INT8 L = 1024 runs {int(a['blocks'])} blocks, "
             f"W4A8 and INT4 {int(S['int']['w4a8_uniform_L1024_dr']['blocks'])}, all with {int(a['data_cycles']):,} data cycles. "
             f"Every MAC/cycle equals peak x data / (data + laps [+ drain]) with BW - 1 lap cycles per block for AF-IPD and "
             f"8 (BW - 1) for BP lap (asserted).")
    L.append(f"- **The gain comes from the laps.** INT8 at L = 1024 has {lap_blk(a)} lap cycles per block instead of "
             f"{lap_blk(b)}, so the array does MACs in {100 * busy(a):.0f}% of its cycles instead of {100 * busy(b):.0f}%. "
             f"Power per cycle is {100 * (float(a['power_mW']) / float(b['power_mW']) - 1):.1f}% higher and MACs per cycle "
             f"{100 * (float(a['mac_per_cycle']) / float(b['mac_per_cycle']) - 1):.1f}% higher, so energy per MAC is "
             f"{100 * (1 - float(a['pJ_MAC']) / float(b['pJ_MAC'])):.1f}% lower.")
    L.append(f"- **Without laps (the peak points) AF-IPD costs slightly more**: "
             + ', '.join(f"{r['prec']} {100 * (r['ratio'] - 1):+.1f}%" for r in pk)
             + f". At INT8 peak the PE core draws {dpe:.3f} mW more (doubling muxes that see every acc_out toggle, and "
               f"longer wires) and the peripheral {dper:.3f} mW more (the bypass sits in larger merged gates that the raw "
               f"planes drive), against {float(p8['b']['sobol_mW']) - float(p8['a']['rng_mW']):.3f} mW saved by the frozen "
               f"AF block clock in place of BP's Sobol banks.")
    L.append(f"- INT density on one PE at INT8 L = 1024 (data + laps window, the SC convention): "
             f"{float(a['mac_per_cycle']) * F_GHZ / (S['afipd']['area']['total'] * 1e-6):,.0f} GMAC/s/mm2 against "
             f"{float(b['mac_per_cycle']) * F_GHZ / (S['bp_rpt']['total'] * 1e-6):,.0f} for BP lap. Section 7.4 includes "
             f"the drain and the grids.")
    return '\n'.join(L)


def measured_periods():
    """Block periods that an RTL bench ran bit-exact: {(prec, grid, L): {source: period}}."""
    out = {}

    def put(k, src, p):
        out.setdefault(k, {}).setdefault(src, set()).add(p)
    txt = RTL_SUM.read_text().splitlines()
    sec = None
    for ln in txt:
        if ln.startswith('single-PE block periods'):
            sec = 'pe'
            continue
        if ln.startswith('grid block periods'):
            sec = 'grid'
            continue
        if ln.startswith('period rows:') or ln.startswith('=='):
            sec = None
            continue
        f = ln.split()
        if sec == 'pe' and len(f) == 7 and f[6] == 'OK':
            m = re.search(r'(int8|w4a8|int4)_.*_L(\d+)_', f[0])
            assert m and f[2] == f[3], ln
            put((m[1].upper(), '1 PE', int(m[2])), 'AF-IPD top', int(f[2]))
        elif sec == 'grid' and len(f) == 11 and f[4] == 'per_pe_laps' and f[5] == '1':
            assert f[6] == f[8], ln
            put((f[1], f[0], int(f[2])), 'IPD grid copy', int(f[6]))
    for ln in IPD_PERIODS.read_text().splitlines():
        f = ln.split()
        if len(f) == 13 and f[4] == 'per_pe_laps' and f[5] == '1' and f[12].startswith('g'):
            assert f[6] == f[8], ln
            put((f[1], f[0], int(f[2])), 'IPD grid', int(f[6]))
    return out


def model_rows(S):
    m = {}
    for r in S['model']:
        if r['sram'] == '' and r['schedule'] in ('T1', 'T3') and r['L'] in ('1024', '4096'):
            m[(r['schedule'], r['prec'], r['shape'], int(r['L']))] = r
    return m


def block_tput(S, R):
    meas = measured_periods()
    mod = model_rows(S)
    ar_ipd = R['area']['composite']['afipd']
    bp = S['bp_rpt']
    bpc = dict(u_pe=bp['u_pe'], a_edge=bp['u_peripheral'] / 2, w_edge=bp['u_peripheral'] / 2, shared=0.0,
               bank=bp['u_a_rng'] + bp['u_w_rng'], comb=bp['u_combiner'])
    ar_bp = {g: (bp['total'] if g == '1 PE' else comp_sym(bpc, *GRIDS[g])) for g in GRIDS}
    shape = {'1 PE': '1PE', '4x4': '4x4', '4x8': '4x8'}
    rows = []
    for prec in PREC:
        for g, (pr, pc) in GRIDS.items():
            for L in (1024, 4096):
                pa, d = period(prec, L, pr, pc, 1)
                pb, _ = period(prec, L, pr, pc, 8)
                ga = int_gmacs(prec, L, pr, pc, 1, ar_ipd[g])
                gb = int_gmacs(prec, L, pr, pc, 8, ar_bp[g])
                t1, t3 = mod[('T1', prec, shape[g], L)], mod[('T3', prec, shape[g], L)]
                # BP lap: the INT doc's routed composite and periods (model_lap_schedules.csv T1), reproduced
                assert int(t1['period']) == pb and int(t3['period']) == pa, (prec, g, L)
                close(float(t1['area_um2']), ar_bp[g], 0.06, f'BP lap {g} composite area')
                close(float(t1['gmacs_mm2']), gb, 0.006, f'BP lap {prec} {g} L={L} GMAC/s/mm2')
                src = meas.get((prec, g, L), {})
                for s, ps in src.items():
                    assert ps == {pa}, f'{prec} {g} L={L} {s}: measured {ps} vs formula {pa}'
                rows.append(dict(prec=prec, grid=g, L=L, pa=pa, pb=pb, d=d, ga=ga, gb=gb, src=sorted(src),
                                 t3_est=float(t3['gmacs_mm2'])))
    assert all(r['ga'] > r['gb'] for r in rows), 'AF-IPD below BP lap somewhere'
    R['tput'] = [{k: v for k, v in r.items()} for r in rows]
    R['bp_composite'] = ar_bp
    L = ['| precision | grid | L | edges per block, AF-IPD / BP lap | % of peak, AF-IPD / BP lap | GMAC/s/mm2 AF-IPD | '
         'GMAC/s/mm2 BP lap | AF-IPD vs BP lap | AF-IPD period run bit-exact in RTL |',
         '|---|---|---:|---:|---:|---:|---:|---:|---|']
    for r in rows:
        L.append(f"| {r['prec']} | {r['grid']} | {fl(r['L'])} | {r['pa']} / {r['pb']} | {100 * r['d'] / r['pa']:.1f}% / "
                 f"{100 * r['d'] / r['pb']:.1f}% | **{r['ga']:,.1f}** | {r['gb']:,.1f} | {pct(r['ga'], r['gb'])} | "
                 f"{', '.join(r['src']) if r['src'] else '- (formula)'} |")
    L.append('')
    sel = lambda p, g, l: next(r for r in rows if r['prec'] == p and r['grid'] == g and r['L'] == l)
    i44, i48 = sel('INT8', '4x4', 1024), sel('INT8', '4x8', 1024)
    drain48 = 8 * GRIDS['4x8'][1]
    sk48 = sum(GRIDS['4x8']) - 2
    sym = R['area']['sym']
    cg = S['ref_grid'][('CSA', '4x8')]
    csa_forms = 100 * abs(float(cg['area_classic_um2']) / float(cg['area_um2']) - 1)
    sym_g = {g: int_gmacs('INT8', 4096, *GRIDS[g], 1, sym[g]) for g in ('4x4', '4x8')}
    pk = {g: GRIDS[g][0] * GRIDS[g][1] * peak_pe('INT8') * F_GHZ / (ar_ipd[g] * 1e-6) for g in GRIDS}
    pkb = {g: GRIDS[g][0] * GRIDS[g][1] * peak_pe('INT8') * F_GHZ / (ar_bp[g] * 1e-6) for g in GRIDS}
    L.append("- Block period on a P_R x P_C grid: `BW*NB + LAP*(BW-1) + (P_R+P_C-2) + 8*P_C` edges, NB = L/128, "
             "LAP = 1 for AF-IPD and 8 for BP lap; % of peak = BW*NB / period. "
             "1 PE has no skew and an 8-edge drain, so its rows include the drain (section 7.3's 'data + laps + drain').")
    L.append("- The last column names the RTL benches that ran that exact schedule bit-exact: 'AF-IPD top' is this "
             "variant's single-PE INT matrix, 'IPD grid copy' this variant's renamed copy of the IPD grid wrapper (4x4 "
             "only), 'IPD grid' the original IPD grid bench (`build/rtl_preflight/bp_ipd/grid/periods.txt`). Every listed "
             "period equals the formula (asserted). No AF-IPD grid exists (section 7.6).")
    L.append(f"- GMAC/s/mm2 = P_R x P_C x peak x % of peak x 0.4 GHz / area, with peak {peak_pe('INT8')} / {peak_pe('W4A8')} / "
             f"{peak_pe('INT4')} MAC per PE per data edge (INT8 / W4A8 / INT4). AF-IPD uses its route area at 1 PE and the "
             f"split composites of section 7.1 on grids. BP lap uses its route and the INT doc's routed symmetric composites "
             f"({c1(ar_bp['4x4'])} / {c1(ar_bp['4x8'])} um2; reproduced here, and its periods and GMAC/s/mm2 equal "
             f"`model_lap_schedules.csv`'s T1 rows, asserted). BP lap keeps the CSA's comparator edges, whose two forms "
             f"differ by {csa_forms:.3f}% at 4x8 (`compare_cbsg.py`'s grid.csv); AF-IPD in the symmetric form would read "
             f"{sym_g['4x4']:,.1f} / {sym_g['4x8']:,.1f} at INT8 L = 4096 on 4x4 / 4x8.")
    L.append(f"- The laps drop from 8 (BW - 1) to BW - 1 edges; the skew and the 8 P_C drain are unchanged and now dominate "
             f"what is left on grids: at INT8 L = 1024 on 4x8 the {drain48}-edge drain and {sk48} skew edges are "
             f"{100 * (drain48 + sk48) / i48['pa']:.0f}% of the {i48['pa']}-edge block (4x4: "
             f"{100 * (8 * GRIDS['4x4'][1] + sum(GRIDS['4x4']) - 2) / i44['pa']:.0f}%).")
    L.append(f"- INT8 peak, no laps, skew or drain: {pk['1 PE']:,.1f} / {pk['4x4']:,.1f} / {pk['4x8']:,.1f} GMAC/s/mm2 at "
             f"1 PE / 4x4 / 4x8 (BP lap {pkb['1 PE']:,.1f} / {pkb['4x4']:,.1f} / {pkb['4x8']:,.1f}). On grids AF-IPD's larger "
             f"PE core outweighs its smaller edges, so the 1-edge laps are what puts it ahead.")
    assert pk['1 PE'] > pkb['1 PE'] and pk['4x4'] < pkb['4x4'] and pk['4x8'] < pkb['4x8'], (pk, pkb)
    t3 = [(r, r['ga'] / r['t3_est'] - 1) for r in rows if r['grid'] != '1 PE']
    assert all(x > 0 for _, x in t3)
    L.append(f"- The IPD estimate on the Sobol edge (`model_lap_schedules.csv` T3: routed BP lap + synthesized IPD delta) "
             f"has the same periods; AF-IPD's composites from its own route land {100 * min(x for _, x in t3):.1f}% to "
             f"{100 * max(x for _, x in t3):.1f}% above that estimate on the grids.")
    return '\n'.join(L)


def section(lines, start, stop=None):
    out, on = [], False
    for ln in lines:
        if ln.startswith(start):
            on = True
        elif on and stop and ln.startswith(stop):
            break
        elif on:
            out.append(ln)
    return out


def one(rx, text, what):
    m = re.search(rx, text, re.M)
    assert m, f'{what}: /{rx}/ not found'
    return m


def block_verify(S, R):
    rtl = RTL_SUM.read_text()
    lines = rtl.splitlines()
    one(r'^C-BSG AF \+ IPD RTL checks: PASS$', rtl, 'rtl verdict')
    n_src = len([ln for ln in section(lines, '== source hashes', '== RTL copies') if ln.startswith('unchanged ')])
    n_chg = len([ln for ln in section(lines, '== source hashes', '== RTL copies') if ln.strip() and not ln.startswith('unchanged ')])
    assert n_chg == 0, 'a recorded source changed'
    n_ren = len([ln for ln in section(lines, '== RTL copies', '== python') if ln.startswith('rename-only, identical')])
    per = one(r'^peripheral: rename \+ INT bypass only \((\d+) lines added, (\d+) changed', rtl, 'peripheral copy')
    readme = one(r'^README table: (\d+) rows, every prefix matches', rtl, 'readme table')
    one(r'^check_copies: PASS$', rtl, 'check_copies')
    gold = one(r'shipped golden cases re-derived from \.mem: (\d+) PASS', rtl, 'golden')
    extra = one(r'extra cases emitted .*: (\d+) PASS, (\d+) blocks', rtl, 'extra')
    rv = one(r'review cases emitted .*: (\d+) PASS, (\d+) blocks', rtl, 'review')
    un = one(r'^UNITS PASS: encoder (\d+) cases, stream gen (\d+) checks, INT silence (\d+) checks, peripheral copy vs '
             r'original (\d+) checks, L=0 gate point (\d+) checks', rtl, 'units')
    scm = one(r'^SC functional matrix \(lockstep vs the AF top\): (\d+) runs, status PASS', rtl, 'sc matrix')
    sct = one(r'^SC totals: (\d+) passing runs, (\d+) blocks, (\d+) drained accumulators, (\d+) per-block accumulators, '
              r'(\d+) kA values bit-exact; (\d+) lockstep edges .*; (\d+) negative controls caught', rtl, 'sc totals')
    trc = one(r'^SC trace identity .*: (\d+) runs, status PASS', rtl, 'sctrace')
    intm = one(r'^INT matrix: (\d+) cases, status PASS', rtl, 'int matrix')
    isec = section(lines, '== int', '  lap coverage')
    i_pass = [ln for ln in isec if re.match(r'^\S+: PASS', ln)]
    i_neg = [ln for ln in i_pass if ln.startswith('neg_')]
    i_strobe = [ln for ln in i_neg if 'bit-exact as required' in ln and '[CBSG-AF-CONTRACT] caught' in ln]
    assert all('negative control caught' in ln or ln in i_strobe for ln in i_neg)
    assert all('bit-exact' in ln for ln in i_pass if not ln.startswith('neg_'))
    assert len(i_pass) == int(intm[1])
    lapc = one(r'lap coverage .*: cases (\d+), lap_edges (\d+), tile_laps (\d+), with_pending_carry (\d+), '
               r'with_pending_borrow (\d+)', rtl, 'lap coverage')
    sil = one(r'INT MACs consumed with the AF streams silent .*: (\d+)', rtl, 'silence')
    prow = one(r'^period rows: (\d+), mismatches: (\d+)', rtl, 'period rows')
    assert prow[2] == '0'
    intx = one(r'^INT cross-check vs the IPD top: (\d+) cases, status PASS', rtl, 'intx')
    sw = one(r'^SC <-> INT switching: (\d+) runs, status PASS', rtl, 'switch')
    ssec = section(lines, '== switch', '== grid')
    s_pass = [ln for ln in ssec if re.match(r'^\S+: PASS', ln)]
    s_neg = [ln for ln in s_pass if ln.startswith('neg_')]
    assert all('negative control caught' in ln for ln in s_neg)
    assert len(s_pass) == int(sw[1])
    grd = one(r'^IPD grid wrapper, rename check .*: (\d+) cases, status PASS', rtl, 'grid')
    one(r'^power benches: status PASS', rtl, 'power benches')
    gl = SYN_GL_SUM.read_text()
    one(r'^C-BSG AF-IPD post-synthesis GL checks: PASS$', gl, 'syn gl verdict')
    ud = one(r'^unit: (\d+)/(\d+) runs PASS \(sc (\d+)/(\d+), int (\d+)/(\d+), switch (\d+)/(\d+)\)', gl, 'unit')
    sd = one(r'^sdf: (\d+)/(\d+) runs PASS \(sc (\d+)/(\d+), int (\d+)/(\d+), switch (\d+)/(\d+)\)', gl, 'sdf')
    assert ud[1] == ud[2] and sd[1] == sd[2]
    sdf_lines = [ln for ln in gl.splitlines() if ln.startswith('sdf ')]
    assert len(sdf_lines) == int(sd[2]) and all('timing violations 0 (post-reset 0)' in ln for ln in sdf_lines)
    sdf_w = set(re.findall(r"SDF warnings (\{[^}]*\})", gl))
    cftc = set(re.findall(r'(\d+) SDFCOM_CFTC all DFFRPQ removal checks', gl))
    assert sdf_w == {"{'SDFCOM_CFTC': %s}" % c for c in cftc} and len(cftc) == 1, (sdf_w, cftc)
    cftc = int(cftc.pop())
    # routed: qualification, basin, SC GL audits
    q, b, u = S['q'], S['basin'], S['afipd']['res_u']
    assert q['qualification'] == 'final' and q['geometry_drc'] == 0 and q['antenna_violations'] == 0
    assert q['connectivity_violations'] == 0 and q['placement_overlapping_instances'] == 0
    assert b['gate']['basin'] == 'grid' and b['gate']['status'] == 'PASS' and b['pin_proof']['status'] == 'PASS'
    sc_gl = {}
    for name, d in (('bootstrap', AFIPD / 'bootstrap/gl_bootstrap'), ('uniform', PIN / 'gl_final'), ('ladder', PIN / 'gl_ladder')):
        st, ap = jload(d / 'timing_qualification_strict.json'), jload(d / 'timing_qualification.json')
        tc, ck = jload(d / 'trace_check.json'), jload(d / 'sdf_clock_audit.json')
        assert st['status'] == 'FAIL' and st['rejection_reasons'] == ['unapproved SDF warnings: SDFCOM_IWSBA'], name
        assert ap['status'] == 'PASS' and ap['approved_negative_iopath_clamps'] == [] and ap['post_reset_timing_violations'] == 0
        assert ap['sdf_warning_categories'].get('SDFCOM_IWSBA') == 4 and len(ap['approved_annotated_interconnects']) == 4
        assert all('int_out' in x['entry'] for x in ap['approved_annotated_interconnects'])
        assert tc['wrong'] == 0 and ck['status'] == 'PASS'
        sc_gl[name] = dict(accs=tc['accumulators'], icg=ck['worst_icg_iopath_ns'])
    # routed INT energy points
    ip = dict(n=0, tiles=0, outs=0, macs=0, audit=0)
    for lab, _ in POINTS:
        r = S['int'][lab]
        g = INTDIR / lab / 'gl'
        st, ap, ck, sa = (jload(g / 'timing_qualification_strict.json'), jload(g / 'timing_qualification.json'),
                          jload(g / 'check.json'), jload(g / 'saif_int_audit.json'))
        assert st['status'] == 'FAIL' and st['rejection_reasons'] == ['unapproved SDF warnings: SDFCOM_IWSBA'], lab
        assert ap['status'] == 'PASS' and ap['approved_negative_iopath_clamps'] == [] and ap['post_reset_timing_violations'] == 0
        assert len(ap['approved_annotated_interconnects']) == 4 and r['approved_interconnects'] == '4'
        assert r['approved_iopath_clamps'] == '0' and r['post_reset_timing_violations'] == '0'
        assert ck['status'] == 'PASS' and ck['n_mismatch'] == 0 and sa['status'] == 'PASS'
        assert (INTDIR / lab / 'status').read_text().strip() == 'PASS'      # the runner's gate includes GL == RTL (cmp)
        ip['n'] += 1
        ip['tiles'] += int(r['tiles_checked'])
        ip['outs'] += int(r['outputs_checked'])
        ip['macs'] += int(r['macs_checked'])
        ip['audit'] += 1
    rf = S['rf']
    assert rf['passed'] == rf['total'] == rf['ran']
    rneg = [x for x in rf['runs'] if x['expect'] != 'pass']
    assert all(x['status'] == 'PASS' for x in rf['runs'])
    assert all("'SDFCOM_IWSBA': 4" in x['line'] and 'post-reset viol 0' in x['line'] for x in rf['runs']
               if 'audit' in x['line']), 'routed_func audit'
    R['verify'] = dict(rtl_sc_runs=int(scm[1]), rtl_int_cases=int(intm[1]), syn_unit=ud[1], syn_sdf=sd[1],
                       routed_func=f"{rf['passed']}/{rf['total']}", int_points=ip['n'])
    L = ['| level | what ran | result |', '|---|---|---|']
    n_rec = sum(1 for ln in (REPO / 'designs/payn/variants/signed_segmented_csa_cbsg_af_ipd/copied_from.sha256')
                .read_text().splitlines() if re.match(r'^[0-9a-f]{64}  ', ln))
    assert n_rec >= n_src
    L.append(f"| provenance (`check_copies.sh`, in the RTL run) | {n_src} recorded sources unchanged since the copy (the "
             f"record now holds {n_rec}, with the synthesis and route scripts); {n_ren} RTL copies rename-only; the "
             f"peripheral is the AF one plus the INT bypass ({per[1]} lines added, {per[2]} changed) | PASS |")
    L.append(f"| kernel reference and units | golden cases {gold[1]} shipped, {extra[1]} extra ({int(extra[2]):,} blocks), "
             f"{rv[1]} review ({int(rv[2]):,} blocks); kA encoder {int(un[1]):,} cases, stream generator {int(un[2]):,}, "
             f"INT silence {int(un[3]):,}, copied peripheral vs the original {int(un[4]):,}, L = 0 gate point {int(un[5]):,} | "
             f"PASS, 0 wrong |")
    L.append(f"| RTL, SC mode (lockstep against the AF top every edge, random INT inputs) | {scm[1]} runs: {sct[1]} passing "
             f"({int(sct[2]):,} blocks, {int(sct[3]):,} drained accumulators and {int(sct[5]):,} kA values bit-exact, "
             f"{int(sct[6]):,} lockstep edges identical) and {sct[7]} negative controls caught; SC traces byte-identical to "
             f"the AF top's in {trc[1]} of {trc[1]} runs | PASS |")
    L.append(f"| RTL, INT mode | {intm[1]} cases: {len(i_pass) - len(i_neg)} positive runs bit-exact, {len(i_neg)} negative "
             f"controls caught ({len(i_strobe)} of them SC strobes in INT mode, which stay bit-exact and are flagged by the "
             f"AF contract monitor); block period `BW*NB + (BW-1) + 8` in {prow[1]} rows, {prow[2]} mismatches; "
             f"{int(lapc[3]):,} tile laps ({int(lapc[4]):,} folding a pending carry, {int(lapc[5]):,} a borrow); "
             f"{int(sil[1]):,} INT MACs with the AF streams silent; {intx[1]} cases byte-identical to the IPD top | PASS |")
    L.append(f"| RTL, SC <-> INT switching (no reset) | {sw[1]} runs: {len(s_pass) - len(s_neg)} bit-exact, {len(s_neg)} "
             f"negative controls caught | PASS |")
    L.append(f"| RTL, IPD grid wrapper (rename check) | {grd[1]} cases on 2x2 and 4x4; evidence for the copied lap wave "
             f"only, not for AF + INT on a grid | PASS |")
    L.append(f"| synthesized netlist GL | unit delay {ud[1]}/{ud[2]} (SC {ud[3]}, INT {ud[5]}, switch {ud[7]}); "
             f"ideal-clock max SDF {sd[1]}/{sd[2]} (SC {sd[3]}, INT {sd[5]}, switch {sd[7]}), 0 timing violations, "
             f"SDF warnings only {cftc} `SDFCOM_CFTC`, all async-reset removal checks of `DFFRPQ` cells | PASS |")
    L.append(f"| route qualification | final: geometry {q['geometry_drc']}, antenna {q['antenna_violations']}, connectivity "
             f"{q['connectivity_violations']}, placement legal; setup {q['setup_wns_ns']:+.3f} / hold {q['hold_wns_ns']:+.3f} ns; "
             f"{b['gate']['basin']} basin (corr {b['corr_x_col']:.3f}, mean \\|skew\\| {b['abs_skew_mean_ps']:.1f} ps); "
             f"{b['pin_proof']['fixed_in_def']:,} pins fixed, pin proof {b['pin_proof']['status']} | PASS |")
    L.append(f"| routed GL, SC power (bootstrap, uniform, ladder) | strict audit fails only on 4 `SDFCOM_IWSBA` "
             f"(the combiner's `int_out[60..63]` sign-extension aliases), approved with rationale files; 0 clamps, "
             f"0 post-reset violations; worst ICG CK->ECK {max(v['icg'] for v in sc_gl.values()):.3f} ns; drains bit-exact "
             f"({sc_gl['uniform']['accs']} accumulators per run) | PASS |")
    L.append(f"| routed GL, INT energy | {ip['n']}/{len(POINTS)} points: {ip['tiles']:,} tiles, {ip['outs']:,} combiner "
             f"outputs, {ip['macs']:,} MACs bit-exact, GL traces byte-identical to RTL; INT SAIF audit (AF side silent, "
             f"bypass transparent) {ip['audit']}/{len(POINTS)}; the same 4 approvals, 0 clamps, 0 post-reset violations | "
             f"PASS |")
    L.append(f"| routed GL, functional | {rf['passed']}/{rf['total']} (SC {rf['by_kind']['sc']}, INT {rf['by_kind']['int']}, "
             f"switch {rf['by_kind']['switch']}), {len(rneg)} of them negative controls; no ideal-clock view or reset "
             f"settle; SC drains read at the SDC output-delay point (section 7.6) | PASS |")
    return '\n'.join(L)


def block_caveats(S, R):
    p = S['params']
    nh, k, m, wd, t = p['N_H'], p['K'], p['M'], p['WIDTH'], p['T']
    demand = nh * k * m                          # operand bits per data edge per edge half
    blk = nh * k * (wd + 1)                      # SC block per edge half: magnitudes + signs
    reads = [('(i)', blk * m // t), ('(ii)', blk)]   # section 10: the SC T=128 average; the block every cycle
    # reproduce model_lap_schedules.csv's section 10 / stall / prefetch percentages (T1 = BP lap, T3 = 1-edge laps)
    chk = 0
    for r in S['model']:
        if r['schedule'] in ('T1', 'T3') and r['sram'] in ('(i) 72 b/cyc avg', '(ii) 576 b every cyc'):
            sup = dict(reads)['(i)' if r['sram'].startswith('(i)') else '(ii)']
            assert str(sup) in r['sram']
            pr, pc = (1, 1) if r['shape'] == '1PE' else GRIDS[r['shape']]
            P, D = period(r['prec'], int(r['L']), pr, pc, 1 if r['schedule'] == 'T3' else 8)
            close(float(r['sec10_pct']), round(100 * min(1, sup / demand), 2), 0.006, 'sec10')
            close(float(r['stall_pct']), 100 * D / (D * max(1, demand / sup) + P - D), 0.006, 'stall')
            close(float(r['prefetch_pct']), 100 * D / max(P, D * demand / sup), 0.006, 'prefetch')
            chk += 1
    assert chk >= 24, chk
    stall = lambda P, D, sup: D / (D * max(1, demand / sup) + P - D)
    pref = lambda P, D, sup: D / max(P, D * demand / sup)
    L = [f"- **Memory bandwidth (doc/INT_mode_on_PaYN.md section 10) still applies, and the 1-edge laps make it bind "
         f"sooner.** INT takes {demand:,} operand bits per edge half on every data edge, for any precision; SC T = 128 "
         f"takes a {blk}-bit block every {t // m} cycles. The laps change the data-edge fraction, not the bits per data "
         f"edge, so with no reuse at the array edge the throughput is capped by the supply. % of peak, AF-IPD / BP lap, "
         f"for section 10's two readings of an SC-sized SRAM, (i) {reads[0][1]} b/cycle per edge half and (ii) "
         f"{reads[1][1]} b/cycle; 'prefetch' fetches the next data edges' operands during laps and drain (an upper "
         f"bound), 'stall' stops the array while it loads:",
         '',
         '| precision | grid | L | compute-bound | (ii), prefetch | (ii), stall | (i), prefetch | (i), stall |',
         '|---|---|---:|---:|---:|---:|---:|---:|']
    rows = []
    for prec in ('INT8', 'INT4'):
        for g in ('4x4', '4x8'):
            for Lr in (1024, 4096):
                pa, d = period(prec, Lr, *GRIDS[g], 1)
                pb, _ = period(prec, Lr, *GRIDS[g], 8)
                cell = lambda fa, fb: f"{100 * fa:.1f}% / {100 * fb:.1f}%"
                v = dict(prec=prec, grid=g, L=Lr, cb=(d / pa, d / pb),
                         p2=(pref(pa, d, reads[1][1]), pref(pb, d, reads[1][1])),
                         s2=(stall(pa, d, reads[1][1]), stall(pb, d, reads[1][1])),
                         p1=(pref(pa, d, reads[0][1]), pref(pb, d, reads[0][1])),
                         s1=(stall(pa, d, reads[0][1]), stall(pb, d, reads[0][1])))
                rows.append(v)
                L.append(f"| {prec} | {g} | {fl(Lr)} | {cell(*v['cb'])} | {cell(*v['p2'])} | {cell(*v['s2'])} | "
                         f"{cell(*v['p1'])} | {cell(*v['s1'])} |")
    L.append('')
    gain = lambda key, sel=lambda v: True: [v[key][0] / v[key][1] - 1 for v in rows if sel(v)]
    cap2 = reads[1][1] / demand
    assert all(abs(x) < 1e-12 for x in gain('p1')), 'reading (i) with prefetch should cap both designs'
    capped = [v for v in rows if v['p2'][0] == v['p2'][1]]
    assert capped and all(v['L'] == 4096 and abs(v['p2'][0] - cap2) < 1e-12 for v in capped)
    assert all(v['L'] != 4096 or v in capped for v in rows)
    rng = lambda xs: f"{100 * min(xs):+.0f}% to {100 * max(xs):+.0f}%"
    L.append(f"  W4A8 has INT4's schedule and the same bits per data edge, so its percentages are INT4's. AF-IPD's gain over "
             f"BP lap in MACs per cycle is {rng(gain('cb'))} compute-bound. Under (ii) with prefetch it is "
             f"{rng(gain('p2', lambda v: v['L'] == 1024))} at L = 1024 and none at L = 4096, where both designs hit the "
             f"{100 * cap2:.2f}% cap; without prefetch it is {rng(gain('s2'))}. Under (i) both sit at the "
             f"{100 * reads[0][1] / demand:.2f}% cap with prefetch, and within {100 * max(gain('s1')):.0f}% of each other "
             f"without it. Section 10's edge buffers (an A replay buffer per PE row, a W block buffer per PE column) were "
             f"modelled for the 8-edge laps and the hybrid schedules, not for 1-edge laps.")
    R['caveats'] = dict(demand_bits=demand, sc_block_bits=blk, readings=dict(reads),
                        gain_compute=(min(gain('cb')), max(gain('cb'))), gain_ii_prefetch=(min(gain('p2')), max(gain('p2'))),
                        gain_i_prefetch=(min(gain('p1')), max(gain('p1'))),
                        gain_ii_prefetch_1024=(min(gain('p2', lambda v: v['L'] == 1024)),
                                               max(gain('p2', lambda v: v['L'] == 1024))))
    # drain rail on a PE row
    arr = {}
    for d in ('afipd', 'af'):
        txt = (DBG / f'pt_{d}' / 'pt.log').read_text()
        a = float(one(r'^\s+data arrival time\s+([\d.]+)$', txt, f'{d} arrival')[1])
        s = float(one(r'^\s+slack \(MET\)\s+([\d.]+)$', txt, f'{d} slack')[1])
        e = one(r'^\s+Endpoint: (acc_out_east\[\d+\])', txt, f'{d} endpoint')[1]
        arr[d] = (a, s, e)
    sdc = next(ROUTE.glob('*.syn.sdc')).read_text()
    ind = set(re.findall(r'set_input_delay -clock clk\s+([\d.]+)\s+\[get_ports \{acc_in_west\[\d+\]\}\]', sdc))
    assert len(ind) == 1
    ind = float(ind.pop())
    f1 = sorted(PIN.glob('routed_func/summary.json.failed_*'))
    assert len(f1) == 1
    f1 = jload(f1[0])
    n_fail1 = f1['total'] - f1['passed']
    assert n_fail1 == sum(1 for x in f1['runs'] if x['status'] != 'PASS') and n_fail1 > 0
    R['caveats']['drain_rail'] = dict(arrival_ns={d: v[0] for d, v in arr.items()}, acc_in_west_input_delay_ns=ind)
    L.append(f"- **PE-grid skew is not built.** Every grid figure in this section is a composite of the single-PE route. "
             f"As for AF (section 8), each PE row's and column's AF edge needs its `block_start` and phase aligned to the "
             f"skewed operands, and the INT raw planes need edge skew (doc/INT_mode_on_PaYN.md section 9, correction item 2); "
             f"neither is in the composites. The variant's grid wrapper is a renamed copy of the IPD grid, with no AF "
             f"edge, INT bypass, mode register, guard or combiner, so it checks the lap wave only.")
    L.append(f"- **Drain rail timing on a PE row.** On this route `{arr['afipd'][2]}` settles {arr['afipd'][0]:.2f} ns after "
             f"the clock (PT, routed SPEF, propagated clock; AF route {arr['af'][0]:.2f} ns), inside its own output "
             f"constraint (slack {arr['afipd'][1]:+.2f} ns). In a PE row it drives the next PE's `acc_in_west`, which the "
             f"SDC budgets at {ind:.2f} ns, so a grid must absorb {arr['afipd'][0] - ind:.2f} ns on the neighbour's "
             f"`acc_in_west` paths (the AF route arrives {abs(arr['af'][0] - ind):.2f} ns "
             f"{'before' if arr['af'][0] < ind else 'after'} it), or upsize or register the column-7 drain outputs. "
             f"The same late settle is why the inherited SC functional bench, which read at the falling edge, failed {n_fail1} "
             f"of {f1['total']} routed runs until it read at the SDC point; the netlist matched unit delay at every clock edge "
             f"(`build/cbsg/af_ipd/route_debug/README.txt`).")
    L.append(f"- **The kA encoder remap is a synthesis-side choice that is still open** (sections 7.1 and 7.2): a fixed "
             f"encoder-adder implementation or a bottom-up encoder compile would change the recipe, so it would apply to "
             f"AF as well.")
    L.append(f"- **Workloads measured.** SC at uniform L = 128 and the per-row ladder only (no stream-length sweep as in "
             f"section 3); INT at the BP lap campaign's seven uniform-operand points.")
    return '\n'.join(L)


def block_summary(S, R):
    ga, sc, it = R['area']['composite'], R['sc'], {r['label']: r for r in R['int']}
    tp = {(r['prec'], r['grid'], r['L']): r for r in R['tput']}
    cv = R['caveats']
    ra, raf = S['afipd']['rows_area'], S['af']['rows_area']
    lap = [it[k] for k in ('int8_uniform_L1024_dr', 'w4a8_uniform_L1024_dr', 'int4_uniform_L1024_dr')]
    pk = [it[k] for k in ('int8_uniform_L49152_d', 'int4_uniform_L98304_d')]
    t = lambda g, L: tp[('INT8', g, L)]
    L = []
    L.append(f"- **Area.** {c1(ga['afipd']['1 PE'])} um2 for one PE: {pct(ga['afipd']['1 PE'], ga['csa']['1 PE'])} against the "
             f"CSA and {pct(ga['afipd']['1 PE'], ga['af']['1 PE'])} against AF. In the 4x4 / 4x8 grid composites it is "
             f"{pct(ga['afipd']['4x4'], ga['csa']['4x4'])} / {pct(ga['afipd']['4x8'], ga['csa']['4x8'])} against the CSA. "
             f"The kA encoder remap is {ra['ka_enc'] - raf['ka_enc']:,.1f} um2 of it per A edge.")
    L.append(f"- **SC mode.** {sc['uniform_pJ']['afipd']:.4f} pJ/MAC at uniform L = 128 "
             f"({pct(sc['uniform_pJ']['afipd'], sc['uniform_pJ']['csa'])} against the CSA, "
             f"{pct(sc['uniform_pJ']['afipd'], sc['uniform_pJ']['af'])} against AF) and {sc['ladder_pJ']['afipd']:.4f} on the "
             f"per-row ladder ({pct(sc['ladder_pJ']['afipd'], sc['ladder_pJ']['csa'])} against the CSA ladder-equivalent, "
             f"{pct(sc['ladder_pJ']['afipd'], sc['ladder_pJ']['af'])} against AF). Carrying INT adds "
             f"{sc['uniform_mW']['afipd'] - sc['uniform_mW']['af']:+.3f} mW to AF's SC power, {sc['remap_mW']:+.3f} of it the "
             f"encoder remap.")
    L.append(f"- **INT energy, one PE.** With laps at L = 1024, energy per MAC against the routed BP lap route is "
             + ' / '.join(f"{100 * (r['ratio'] - 1):+.1f}%" for r in lap)
             + f" (INT8 / W4A8 / INT4); without laps (peak) it is "
             + ' / '.join(f"{100 * (r['ratio'] - 1):+.1f}%" for r in pk) + " (INT8 / INT4).")
    L.append(f"- **INT throughput with 1-edge laps (compute-bound).** INT8 on 4x4: {t('4x4', 1024)['ga']:,.1f} against "
             f"{t('4x4', 1024)['gb']:,.1f} GMAC/s/mm2 at L = 1024 ({pct(t('4x4', 1024)['ga'], t('4x4', 1024)['gb'])}), "
             f"{t('4x4', 4096)['ga']:,.1f} against {t('4x4', 4096)['gb']:,.1f} at L = 4096 "
             f"({pct(t('4x4', 4096)['ga'], t('4x4', 4096)['gb'])}). An SRAM sized for SC can take that gain away "
             f"(section 7.6): with section 10's wider reading and prefetch it is up to "
             f"{100 * cv['gain_ii_prefetch_1024'][1]:+.0f}% at L = 1024 on the grids and none at L = 4096; with the "
             f"narrower one, essentially none.")
    return '\n'.join(L)


# ------------------------------------------------------------------------------------------------- doc splice
def splice(path, blocks):
    text = Path(path).read_text()
    names = re.findall(r'<!-- BEGIN af_ipd:(\w+) -->', text)
    assert names, f'{path}: no af_ipd markers'
    for n in names:
        assert n in blocks, f'{path}: marker {n} is not a block ({sorted(blocks)})'
        pat = re.compile(rf'(<!-- BEGIN af_ipd:{n} -->\n).*?(<!-- END af_ipd:{n} -->)', re.S)
        assert len(pat.findall(text)) == 1, f'{path}: marker {n} missing its END or repeated'
        text = pat.sub(lambda mm: mm[1] + blocks[n] + '\n' + mm[2], text)
    Path(path).write_text(text)
    return names


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', default=str(AFIPD / 'report'))
    ap.add_argument('--doc', default=None, help='repo-relative doc to splice (e.g. doc/cbsg_variants.md)')
    a = ap.parse_args()
    S = load()
    R = {}
    blocks = {}
    blocks['area'] = block_area(S, R)
    blocks['sc'] = block_sc(S, R)
    blocks['int'] = block_int(S, R)
    blocks['tput'] = block_tput(S, R)
    blocks['verify'] = block_verify(S, R)
    blocks['caveats'] = block_caveats(S, R)
    blocks['summary'] = block_summary(S, R)
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    md = ['<!-- generated by sweeps/cbsg/af_ipd/report_af_ipd.py; do not edit by hand -->', '']
    for n, b in blocks.items():
        md += [f'## {n}', '', b, '']
    (out / 'report_af_ipd.md').write_text('\n'.join(md))
    (out / 'report_af_ipd.json').write_text(json.dumps(R, indent=1, default=str) + '\n')
    print(f'wrote {out}/report_af_ipd.md and report_af_ipd.json')
    if a.doc:
        print('spliced into ' + a.doc + ': ' + ', '.join(splice(REPO / a.doc, blocks)))


if __name__ == '__main__':
    main()
