#!/usr/bin/env python3
"""C-BSG variants (AF, RG) against the carry-save (CSA) pinned pass 2: single PE, 4x4 / 4x8 grid composites,
GMAC/s/mm2 and energy per MAC.  TSMC22, 400 MHz, K8 M16 N8 (64 MAC/cycle per PE at L = T = 128).

Every number comes from a routed report, a PT dump of a routed netlist, a SAIF, or (for the RG forwarding estimate
only) the synthesized RG area breakdown.  Nothing is typed in by hand; the only constants are the clock, T and the
two grid shapes.  The design parameters (K, M, N_H, N_W, WIDTH, IDX_W) are parsed from the routed RG netlist.

Reads (all read only):
  CSA   route apr/build/TSMC22/PAYN_SC_CSA/csa_20261002_distguide_spp_pins (area.rpt, setup/hold.rpt, apr.log, SAIF,
        repair_plan.json, the pre-repair apr.log for the post-filler trace)
        build/power_char/pinned_pass2_20261004/csa/{power_result/power.rpt,basin/basin_gate.json,gl_final/*}
        build/power_char/cbsg_20261005/af/csa_baseline_power_classes/power_classes.json  (PT class split, same SAIF)
  AF    pinned: the QUALIFIED route .../PAYN_SC_CSA_CBSG_AF/cbsg_af_20261005_distguide_spp_pins_postfill (fix option (c)
        of build/power_char/cbsg_20261005/af/pinned_fix/README.txt; + _ptview_* SAIFs), measured in
        af/pinned_fix/postfill/measure/{result.csv,basin/,gl_final/,gl_ladder/,routed_func/}
        floating (qualified, collapsed basin; reference only): .../cbsg_af_20261005_distguide_spp_fixed,
        af/floating_measure/
        superseded: af/pinned_unqualified/result.csv (the unrepaired pinned route) for the qualified-vs-unqualified line
  RG    routes .../PAYN_SC_CSA_CBSG_RG/cbsg_rg_20261005_distguide{,_spp_fixed,_spp_pins} (area.rpt, slack, apr.log,
        the pinned routed netlist for the u_peripheral split), _pt_* SAIFs
        build/power_char/cbsg_20261005/rg/indicative/cbsg_rg_20261005_distguide/<wl>/{result.csv,split/*}
        build/power_char/cbsg_20261005/rg/{pinned/unqualified_diag,indicative/...}/basin/basin_gate.json
        build/cbsg/rg/area/cbsg_rg_20261005/area_breakdown.json   (synthesized cell areas: flop area per bit)
        timing-fix runs (rg/timing_fix_README.txt): syn/build/TSMC22/PAYN_SC_CSA_CBSG_RG/<run>/{timing,area}.rpt, the
        campaign stage status files and strict GL audit of each run's bootstrap, and its bootstrap route reports only
        once the campaign's bootstrap_apr stage has passed (a route still being written is not read)
        the benches' per-block stimulus traces (cbsg_rg_streaming_rtl.txt, array_streaming_cbsg_af_rtl.txt) of the
        runs above, replayed through sweeps/cbsg/cbsg_ref.py for the glitch-free toggle rates
  Sweeps  build/power_char/cbsg_20261005/tsweep/{csa,af}/<point>/{result.json,*.status,classes/power_classes.json,
        power*/power.rpt,gl/<bench>/<trace>} (CSA T16..T128, ladder-equivalent, repro; AF u016..u128, ladder), the PT-only
        views <route>_ptview_tsweep_<point> (SAIF; netlist/SPEF links), tsweep/csa/{T128,repro}/gate.status +
        saif_vs_headline.diff, tsweep/csa/stim/ladder_from_af.json, tsweep/csa/rtl_checks/summary.txt,
        tsweep/af/{gate,negctl}.json; the AF ladder variants tsweep/af/ladder_variants/{hold8,rowmax}/ (same files; views
        <route>_ptview_tsweep_lv_<tag>) and ladder_variants/rtl_checks/summary.txt;
        build/power_char/csa_t_sweep_20261003/results.csv (floating-route cross-check only)
  Campaign  build/power_char/cbsg_20261005/results.csv  (only to check that the composites reproduce it)
  Post-filler trace: sweeps/cbsg/af/filler_drc_trace.py on each route's pre-repair apr.log.
Writes <OUT>/{summary.json,single_pe.csv,grid.csv,rgb_sensitivity.csv,rg_timing_runs.csv,tsweep.csv,tables.md}; default
OUT build/power_char/cbsg_20261005/variants.

Stream-length sweeps.  Both finished pinned routes measured at shorter stream lengths, every point its own full-timing
  GL + PT-PX run (none interpolated).  Gated before any other point is used: CSA T = 128 and the bench-copy replay
  reproduce the qualified CSA baseline (power.rpt total, every PT class row, empty SAIF diff, identical trace); AF L = 128
  and the ladder reproduce the AF pinned measurement (total, every class row, gate.json).  Per point: every stage PASS,
  strict GL audit with no approvals, drain bit-exact, PT coverage, SAIF window, PT view = the route's netlist and SPEF,
  same operands as the full-length point (GL traces; AF magnitude = round(|q| x 128 / 127) of the CSA's).  The CSA
  ladder-equivalent (AF ladder operands, each block ceil(max row L / M) cycles) becomes the CSA's ladder workload in
  every table.  AF-only lengths are compared with the CSA point of the same cycles per block.  Two AF ladder variants
  on the ladder's operands (asserted): every row at its block's longest L (rowmax, the A-first design at the ladder's
  block lengths) and every block held ceil(T / M) = 8 cycles (hold8, drain = the ladder's).
Grid block length.  A grid with one stream generator runs one block length for every PE (each W edge feeds every PE
  row of its column), as long as the longest of all its A rows.  So the per-row-L runs (AF ladder, CSA
  ladder-equivalent, AF rowmax, RG rowmix / rowgrouped), which give each PE its own block length, have no grid
  composite; the grid ladder is composed from AF hold8 and compared with the CSA's T = 128 composite.

Composite.  Split form: P_R x P_C x u_pe + P_R x (A edge + shared/2) + P_C x (W edge + shared/2) + one stream-generator
  set, shared = the edge's clock buffers and leftovers; grid "R x C" is P_R = R PE rows (one A edge each) x P_C = C PE
  columns (one W edge each), the PaYN convention (4x8 = P_R 4, P_C 8).  Symmetric form (the project's standard,
  sweeps/int_mode/compare_grid_configs.py grid_area): P_R x P_C x u_pe + (P_R + P_C)/2 x u_peripheral + generators;
  it reproduces the campaign's CSA and AF floating composites (asserted).  The two forms agree at 4x4 and differ by
  (P_C - P_R)/2 x (A edge - W edge) otherwise, which matters for AF (A edge ~3.8x its W edge).  8x4 is computed as
  the orientation check (grid.csv, derived figures).  RG (b) has no symmetric form (its generator is per PE row by
  construction).
RG (b): the 64 W index generators of a grid row leave the PEs and sit once at that row's A edge; every PE instead
  registers the forwarded per-position threshold (N_H x K x M x (WIDTH-1) bits, "thr"), or the raw W sample index
  (N_H x K x M x IDX_W bits, "idx"; the row-shared Gray/XOR map then stays in every PE).  Flop area per bit = the
  synthesized a_bits_pipe area / its bit count.  Flop power per bit = the routed a_bits_pipe power per bit with its
  switching part scaled from the measured a_bits toggle rate to the forwarded signal's glitch-free toggle rate (the
  bench stimulus replayed through cbsg_ref.py); the a_bits-rate charge is kept as a sensitivity.  The power estimate
  is not a bound: it leaves out the rate dependence of the flops' internal power (pushes up) and keeps the glitch
  power of the as-built tiles and comparators that a registered thr would remove (pushes down).
Energy per kernel MAC = P x window clocks x 2.5 ns / (blocks x N_H x N_W x K); for a grid the hierarchy powers are
  composed like the area (peak: no skew or drain cycles).

Usage: compare_cbsg.py [OUT_DIR] [--doc doc/cbsg_variants.md]
  --doc PATH (repo-relative) also replaces each <!-- BEGIN generated:NAME --> ... <!-- END generated:NAME --> region of
  that doc with the generated block NAME (stamp, bottom_line, why, headline, routes, rg_runs, area, power, deltas,
  activity, toggle, grid, rgb, rg_amort, derived, tsweep, tsweep_reading, tsweep_ladder, tsweep_classes,
  tsweep_permac), so the doc's tables are the script's output verbatim.  The data-dependent wording in those blocks
  is computed, and the claims the doc's hand-written prose makes about them are asserted.
"""
from __future__ import annotations

import csv
import hashlib
import json
import math
import re
import sys
from collections import defaultdict
from datetime import datetime
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
APR = REPO / 'apr/build/TSMC22'
PC = REPO / 'build/power_char'
CAMP = PC / 'cbsg_20261005'
_ARGS = sys.argv[1:]
DOC = REPO / _ARGS[_ARGS.index('--doc') + 1] if '--doc' in _ARGS else None   # splice the generated blocks into this doc
_POS = [a for i, a in enumerate(_ARGS) if a != '--doc' and (i == 0 or _ARGS[i - 1] != '--doc')]
OUT = Path(_POS[0]) if _POS else CAMP / 'variants'
F_GHZ = 0.4
T_NS = 1.0 / F_GHZ
T_STREAM = 128
GRIDS = {'4x4': (4, 4), '4x8': (4, 8), '8x4': (8, 4)}      # (P_R PE rows, P_C PE columns); 8x4 = orientation check
CSA_BASIS = 'pinned route (qualified)'
AF_PIN_BASIS = 'pinned route (qualified, grid basin)'
AF_FLO_BASIS = 'floating route (qualified, collapsed basin; reference only)'
RG_A = 'RG (a) generators in every PE'
RG_A_BASIS = 'pinned route area (not qualified); bootstrap route power (indicative)'
RG_B_PREFIX = 'RG (b) generators at the A edge, forward '
B_THR = RG_B_PREFIX + 'thr'

ROUTES = {
    'csa': APR / 'PAYN_SC_CSA/csa_20261002_distguide_spp_pins',
    'af_pinned': APR / 'PAYN_SC_CSA_CBSG_AF/cbsg_af_20261005_distguide_spp_pins_postfill',
    'af_floating': APR / 'PAYN_SC_CSA_CBSG_AF/cbsg_af_20261005_distguide_spp_fixed',
    'rg_pinned': APR / 'PAYN_SC_CSA_CBSG_RG/cbsg_rg_20261005_distguide_spp_pins',
    'rg_floating': APR / 'PAYN_SC_CSA_CBSG_RG/cbsg_rg_20261005_distguide_spp_fixed',
    'rg_bootstrap': APR / 'PAYN_SC_CSA_CBSG_RG/cbsg_rg_20261005_distguide',
}
AF_PIN_DIR = CAMP / 'af/pinned_fix/postfill'          # qualification of the qualified AF pinned route
AF_PIN_MEAS = AF_PIN_DIR / 'measure'                  # its GL / PT / basin measurement
AF_UNQ = CAMP / 'af/pinned_unqualified'               # superseded: the unrepaired pinned route (filler DRC)
TOPS = {'csa': 'payn_array_signed_segmented_csa', 'af': 'payn_array_signed_segmented_csa_cbsg_af',
        'rg': 'payn_array_signed_segmented_csa_cbsg_rg'}
SAIFS = {
    ('csa', 'uniform'): ROUTES['csa'] / 'activity/dut.saif',
    ('csa', 'ladder'): APR / 'PAYN_SC_CSA/csa_20261002_distguide_spp_pins_ptview_tsweep_ladder/activity/dut.saif',
    ('af_pinned', 'uniform'): APR / 'PAYN_SC_CSA_CBSG_AF/cbsg_af_20261005_distguide_spp_pins_postfill_ptview_uniform/activity/dut.saif',
    ('af_pinned', 'ladder'): APR / 'PAYN_SC_CSA_CBSG_AF/cbsg_af_20261005_distguide_spp_pins_postfill_ptview_ladder/activity/dut.saif',
    ('af_floating', 'uniform'): ROUTES['af_floating'] / 'activity/dut.saif',
    ('af_floating', 'ladder'): APR / 'PAYN_SC_CSA_CBSG_AF/cbsg_af_20261005_distguide_spp_fixed_ptview_ladder/activity/dut.saif',
    ('rg_bootstrap', 'uniform'): APR / 'PAYN_SC_CSA_CBSG_RG/cbsg_rg_20261005_distguide_pt_uniform/activity/dut.saif',
    ('rg_bootstrap', 'rowmix'): APR / 'PAYN_SC_CSA_CBSG_RG/cbsg_rg_20261005_distguide_pt_rowmix/activity/dut.saif',
    ('rg_bootstrap', 'rowgrouped'): APR / 'PAYN_SC_CSA_CBSG_RG/cbsg_rg_20261005_distguide_pt_rowgrouped/activity/dut.saif',
}
RG_IND = CAMP / 'rg/indicative/cbsg_rg_20261005_distguide'
RG_WL = ('uniform', 'rowmix', 'rowgrouped')
RG_SYN_AREA = REPO / 'build/cbsg/rg/area/cbsg_rg_20261005/area_breakdown.json'
RG_TRACE = 'designs/payn/power/power_payn_array_cbsg_rg.sv/cbsg_rg_streaming_rtl.txt'
AF_TRACE = 'designs/payn/power/power_payn_array_cbsg_af.sv/array_streaming_cbsg_af_rtl.txt'
CAMP_RESULTS = CAMP / 'results.csv'
# RG timing-fix runs (build/power_char/cbsg_20261005/rg/timing_fix_README.txt): synthesis run, RTL change, campaign
# bootstrap directory.  The route of a run is <APR RG>/<run>_distguide.
SYN_RG = REPO / 'syn/build/TSMC22/PAYN_SC_CSA_CBSG_RG'
RG_RUNS = [('cbsg_rg_20261005', 'original', CAMP / 'rg/bootstrap'),
           ('cbsg_rg_20261005b', 'step 1a: j pre-clear (first_pipe off the path)', CAMP / 'rg/cbsg_rg_20261005b/rg/bootstrap'),
           ('cbsg_rg_20261005d', 'step 1b: 1a + one A-edge q bank / phase copy per A row',
            CAMP / 'rg/cbsg_rg_20261005d/rg/bootstrap')]
RG_STAGES = ('bootstrap_apr', 'bootstrap_sim', 'bootstrap_audit', 'final_apr')
sys.path.insert(0, str(Path(__file__).resolve().parent / 'af'))
import filler_drc_trace  # noqa: E402  (sweeps/cbsg/af/filler_drc_trace.py)


def rg_sim_dir(wl):
    """GL directory of an RG indicative run (the uniform run reuses the bootstrap GL, named in reused_sim.txt)."""
    reuse = RG_IND / wl / 'reused_sim.txt'
    return Path(reuse.read_text().strip()) if reuse.exists() else RG_IND / wl / 'gl'


# stimulus traces per RG workload: (RG trace, AF trace of the same stimulus or None)
TRACES = {
    'uniform': (lambda: rg_sim_dir('uniform') / RG_TRACE, AF_PIN_MEAS / 'gl_final' / AF_TRACE),
    'rowmix': (lambda: rg_sim_dir('rowmix') / RG_TRACE, AF_PIN_MEAS / 'gl_ladder' / AF_TRACE),
    'rowgrouped': (lambda: rg_sim_dir('rowgrouped') / RG_TRACE, None),
}


# ----------------------------------------------------------------------------------------------- report parsers
def area_rpt(route, top):
    """Top total, first-level children, the 64 tile totals and u_array_core clock gates from Innovus area.rpt."""
    out = dict(children={}, children_inst={}, children_module={}, tiles=0.0, n_tiles=0, core_cg=0.0)
    for line in (route / 'reports/area.rpt').read_text().splitlines():
        f = line.split()
        if not f:
            continue
        if f[0] == top:
            out['total'] = float(f[2])
            continue
        depth = len(line) - len(line.lstrip(' '))
        if depth == 1 and len(f) >= 4:
            out['children'][f[0]] = float(f[3])
            out['children_inst'][f[0]] = int(f[2])
            out['children_module'][f[0]] = f[1]
        elif re.match(r'u_pe/u_array_core/g_row_\d+__g_col_\d+__u_inner$', f[0]):
            out['tiles'] += float(f[3])
            out['n_tiles'] += 1
        elif re.match(r'u_pe/u_array_core/clk_gate_[^/]+$', f[0]):
            out['core_cg'] += float(f[3])
    assert out['n_tiles'] == 64, f'{route}: {out["n_tiles"]} tiles in area.rpt'
    return out


def route_checks(route):
    """Final setup/hold slack and the physical checks, parsed the way the flow's qualify step parses them."""
    slack = {}
    for kind in ('setup', 'hold'):
        m = re.search(r'Slack Time\s*([-+0-9.]+)', (route / f'reports/{kind}.rpt').read_text())
        slack[kind] = float(m[1])
    srpt = (route / 'reports/setup.rpt').read_text()
    path = tuple(re.search(rf'{k}:\s+(\S+)', srpt)[1] for k in ('Beginpoint', 'Endpoint'))
    log = (route / 'apr.log').read_text(errors='replace')
    drc = re.findall(r'Verification Complete\s*:\s*(\d+) Viols\.', log)
    ant = re.findall(r'Verification Complete:\s*(\d+) Violations', log)
    router = re.findall(r'#Total number of DRC violations = (\d+)', log)
    conn = re.findall(r'\*+ Start: VERIFY CONNECTIVITY \*+(.*?)\*+ End: VERIFY CONNECTIVITY \*+', log, re.S)
    place = list(re.finditer(r'Begin checking placement.*?Finished checkPlace[^\n]*', log, re.S))
    ov = re.search(r'Overlapping with other instance:\s*(\d+)', place[-1][0]) if place else None
    q = route / 'reports/popcount_qualification.json'
    return dict(setup_wns_ns=slack['setup'], hold_wns_ns=slack['hold'], setup_path=path, geometry_drc=int(drc[-2]),
                router_drc=int(router[-1]) if router else None, antenna=int(ant[-1]),
                connectivity_clean=bool(conn) and 'Found no problems or warnings.' in conn[-1],
                overlaps=int(ov[1]) if ov else 0,
                flow_qualification=json.loads(q.read_text())['qualification'] if q.exists() else 'none (qualify failed)')


def route_repair(route):
    """Post-filler trace of the route's flow run (the pre-repair apr.log when the targeted repair archived it) and the
    targeted residual repair the qualify step ran (route repair_plan.json; None = no repair)."""
    pre = sorted(route.glob('before_legalization_*/apr.log'))
    t = filler_drc_trace.trace(pre[-1] if pre else route / 'apr.log')
    rp = route / 'repair_plan.json'
    plan = jload(rp) if rp.exists() else None
    cnt = (lambda v: len(v) if isinstance(v, list) else int(v))
    return dict(fillers_pass1=t['fillers_pass1'], fillers_pass2=t['fillers_pass2_no_drc'],
                routable_nets=t.get('routable_nets'), after_ipo=t.get('after_ipo_violations'),
                markers_per_net=t.get('after_ipo_per_routable_net'), sr_iterations=t.get('search_repair_iterations'),
                strong_final=t.get('strong_reroute_final_violations'),
                postfill_ran=bool(t.get('postfill_hook_ran')), postfill_iterations=t.get('postfill_search_repair_iterations'),
                postfill_after_via_swap=t.get('postfill_after_via_swap_violations'),
                flow_verify_drc=t.get('final_verify_drc'),
                targeted=None if plan is None else dict(mode=plan['mode'], geometry=cnt(plan['geometry']),
                                                       antenna_pins=cnt(plan['antenna_pins']),
                                                       overlaps=cnt(plan['overlap_instances'])))


def track_pitches(route):
    """Horizontal / vertical routing-layer pitches (um) from the route's innovus.log."""
    out = {}
    for m in re.finditer(r'#\s+(M\d+)\s+([HV])\s+Track-Pitch = ([0-9.]+)', (route / 'innovus.log').read_text(errors='replace')):
        out.setdefault(m[1], (m[2], float(m[3])))
    return out


def power_total(path):
    t = Path(path).read_text()
    return float(re.search(r'Total Power\s*=\s*([0-9.eE+-]+)', t)[1]) * 1e3


def jload(p):
    return json.loads(Path(p).read_text())


def csv_rows(p):
    return list(csv.DictReader(Path(p).open()))


def basin(p):
    g = jload(p)
    return dict(verdict=g['gate']['basin'], corr_x_col=g['corr_x_col'], corr_y_negrow=g['corr_y_negrow'],
                skew_ps=g['abs_skew_mean_ps'],
                skew_metric=g.get('skew_metric', 'shared a/w skew at the product AND2s').split(':')[0],
                skew_calibrated=g['gate'].get('skew_threshold_calibrated', True), wire_mm=g['wire_mm'],
                die_um=g['die_um'], d_col_um=g['d_col_um'], d_row_um=g['d_row_um'],
                pin_proof=g.get('pin_proof', {}).get('status') if isinstance(g.get('pin_proof'), dict) else None)


def saif_activity(path):
    """Top-level operand-port toggles and tile a_bits / w_bits input toggles from a SAIF (TC per net)."""
    stack, cur, top, tiles = [], None, defaultdict(int), {'a_bits': [], 'w_bits': []}
    dur = None
    with open(path) as fh:
        for ln in fh:
            s = ln.strip()
            if not s:
                continue
            if dur is None and s.startswith('(DURATION'):
                dur = float(s.split()[1].rstrip(')'))
            if s.startswith('(INSTANCE'):
                stack.append(s.split(None, 1)[1])
                continue
            if s == '(NET':
                stack.append('#')
                continue
            if s == ')':
                if stack:
                    stack.pop()
                cur = None
                continue
            if s.startswith('(') and s.count('(') > s.count(')'):
                stack.append('#')
                cur = s[1:].replace('\\', '')
                continue
            if cur is None or '(TC' not in s:
                continue
            inst = [x for x in stack if x != '#']
            tc = int(re.search(r'\(TC (\d+)\)', s)[1])
            base = re.sub(r'\[\d+\]$', '', cur)
            if inst == ['Top', 'dut'] and base in ('a_binary_in', 'w_binary_in', 'a_signs_in', 'w_signs_in'):
                top[base] += tc
            elif inst and re.match(r'g_row_\d+__g_col_\d+__u_inner$', inst[-1]) and base in tiles:
                tiles[base].append(tc)
    clocks = round(dur / 1000.0 / T_NS)
    r = dict(window_clocks=clocks, **{f'port_{k}_TC': v for k, v in top.items()})
    r['port_operand_TC'] = sum(top.values())
    for k, v in tiles.items():
        assert len(v) == 64 * 128, f'{path}: {len(v)} tile {k} nets'
        r[f'tile_{k}_mean_TC'] = sum(v) / len(v)
        r[f'tile_{k}_max_TC'] = max(v)
        r[f'tile_{k}_per_clock'] = sum(v) / len(v) / clocks
    return r


# ----------------------------------------------------------------------------------------------- design records
SUMKEYS = ('u_pe', 'a_edge', 'w_edge', 'shared', 'bank', 'top_rest')


def check_sum(d, what):
    s = sum(d[k] for k in SUMKEYS)
    assert abs(s - d['total']) <= 1e-6 * d['total'] + 2e-3, f'{what}: parts {s} != total {d["total"]}'


def csa_classes(x):
    """CSA PT class rows (sweeps/cbsg/af/run_pt_power_classes.sh power_classes.json, mW or um2) in the hierarchy keys
    used here: A / W edge = registers + comparators, the A and W Sobol banks under stream generators."""
    d = dict(total=x['total'], u_pe=x['u_pe'], tiles=x['tiles'], pe_pipes_glue=x['pe_pipes_glue'],
             pe_clk_buf=x['pe_clk_buf'], a_regs=x['a_regs'], a_logic=x['a_cmp'], w_regs=x['w_regs'],
             w_logic=x['w_cmp'], a_edge=x['a_regs'] + x['a_cmp'], w_edge=x['w_regs'] + x['w_cmp'],
             shared=x['periph_clk_buf'] + x['periph_other'], bank=x['a_bank'] + x['w_bank'],
             a_bank=x['a_bank'], w_bank=x['w_bank'],
             top_rest=x['top_glue'] + x['top_clk_buf'] + x.get('port_nets', 0.0), new_logic=0.0)
    d['pe_local'] = d['u_pe'] - d['tiles']
    d['u_peripheral'] = d['a_edge'] + d['w_edge'] + d['shared']
    return d


AF_CLASS_KEYS = ('total', 'u_pe', 'tiles', 'pe_pipes_glue', 'pe_clk_buf', 'a_regs', 'ka_enc', 'ka_in_buf', 'therm', 'w_regs',
                 'w_cmp', 'a_edge', 'w_edge', 'periph_clk_buf', 'periph_other', 'w_bank', 'top_glue', 'top_clk_buf',
                 'port_nets')


def af_classes(x):
    """AF PT class rows (power_classes.json rows, or a result.csv's cls_* columns keyed the same way) in the hierarchy
    keys used here: A edge = registers + kA encoders + their input buffers + thermometers, the W bank (u_rng) under
    stream generators."""
    d = dict(total=x['total'], u_pe=x['u_pe'], tiles=x['tiles'], pe_pipes_glue=x['pe_pipes_glue'], pe_clk_buf=x['pe_clk_buf'],
             a_regs=x['a_regs'], ka_enc=x['ka_enc'], ka_in_buf=x['ka_in_buf'], therm=x['therm'], w_regs=x['w_regs'],
             w_logic=x['w_cmp'], a_edge=x['a_edge'], w_edge=x['w_edge'], shared=x['periph_clk_buf'] + x['periph_other'],
             bank=x['w_bank'], w_bank=x['w_bank'], a_bank=0.0, top_rest=x['top_glue'] + x['top_clk_buf'] + x['port_nets'])
    d['a_logic'] = d['ka_enc'] + d['ka_in_buf'] + d['therm']
    d['new_logic'] = d['a_logic']
    d['pe_local'] = d['u_pe'] - d['tiles']
    d['u_peripheral'] = d['a_edge'] + d['w_edge'] + d['shared']
    return d


def csa_record(window, cycles_per_block):
    """window: SAIF window clocks; the CSA streams every block for T/M cycles, so blocks = window / (T/M)."""
    ref = PC / 'pinned_pass2_20261004/csa'
    cl = jload(CAMP / 'af/csa_baseline_power_classes/power_classes.json')
    q = jload(ref / 'gl_final/timing_qualification.json')
    cosim = (ref / 'gl_final/cosim.log').read_text()
    rows = csa_classes
    area, pw = rows(cl['rows_area_um2']), rows(cl['rows_mW'])
    check_sum(area, 'csa area')
    check_sum(pw, 'csa power')
    assert abs(pw['total'] - power_total(ref / 'power_result/power.rpt')) < 1e-3
    pw.update(workload='uniform L=128', window=window, blocks=window // cycles_per_block,
              gl=f"{q['status']} (approvals {len(q['approved_negative_iopath_clamps'])}/"
                 f"{len(q['approved_annotated_interconnects'])}, post-reset violations {q['post_reset_timing_violations']})",
              drain_ok='bit-exact (cosim)' if '[PASS]' in cosim else 'see cosim.log', mean_kA=None, a_density=None)
    return dict(label='CSA pinned', route=ROUTES['csa'], status='qualified final (baseline, not rerun)', sdf_audit=None,
                checks=route_checks(ROUTES['csa']), ar=area_rpt(ROUTES['csa'], TOPS['csa']), repair=route_repair(ROUTES['csa']),
                routed_func=None, basin=basin(ref / 'basin/basin_gate.json'), area=area, power={'uniform': pw})


def af_record(key, workdir, label, status):
    rows = csv_rows(workdir / 'result.csv')
    route = ROUTES[key]
    recs = {}
    for r in rows:
        g = lambda k: float(r[k])
        wl = 'uniform' if r['workload'].startswith('uniform') else 'ladder'

        def classes(sfx):
            return af_classes({k: g(f'cls_{k}_{sfx}') for k in AF_CLASS_KEYS})
        pw, area = classes('mW'), classes('um2')
        check_sum(pw, f'{label} {wl} power')
        check_sum(area, f'{label} area')
        assert abs(pw['total'] - g('power_mW')) < 1e-3
        pw.update(workload=r['workload'], window=int(r['window_clocks']), blocks=int(r['blocks']),
                  gl=f"{r['gl_strict']} (approvals {r['gl_approvals_ndi']}/{r['gl_approvals_iwsba']}, post-reset "
                     f"violations {r['gl_post_reset_violations']})",
                  drain_ok='bit-exact' if r['drain_bit_exact'] == 'True' else 'MISMATCH',
                  mean_kA=g('mean_kA'), a_density=g('a_one_density'))
        recs[wl] = pw
    assert {r['run'] for r in rows} == {route.name}, f'{workdir}: result.csv is not of {route.name}'
    sa = jload(workdir / 'gl_ladder/sdf_clock_audit.json')
    rf = jload(workdir / 'routed_func/summary.json')
    rfs = dict(passed=sum(r['status'] == 'PASS' for r in rf['runs']), runs=len(rf['runs']),
               cases=len({r['case'] for r in rf['runs']}), settles=sorted({r['settle'] for r in rf['runs']}, reverse=True),
               ideal_clock_view_needed=rf['ideal_clock_view_needed'], reset_settle_needed=rf['reset_settle_needed'])
    return dict(label=label, route=route, status=status, sdf_audit=sa, checks=route_checks(route), ar=area_rpt(route, TOPS['af']),
                repair=route_repair(route), routed_func=rfs, basin=basin(workdir / 'basin/basin_gate.json'), area=area,
                power=recs)


# ----------------------------------------------------------------------------------------------- stream-length sweeps
# Both finished pinned routes re-measured at shorter stream lengths (sweeps/cbsg/tsweep/): every point its own
# full-timing max-SDF GL run + PT-PX through a PT-only view of the route (<route>_ptview_tsweep_<tag>).
TSWEEP = CAMP / 'tsweep'
TS_STAGES = ('sim', 'audit', 'power', 'classes', 'result')
TS = {'csa': dict(dir=TSWEEP / 'csa', route='csa', top=TOPS['csa'], power='power', classes=csa_classes, sdf='sdf_audit'),
      'af': dict(dir=TSWEEP / 'af', route='af_pinned', top=TOPS['af'], power='power_result', classes=af_classes,
                 sdf='sdf_clock_audit')}
CSA_VART_TB = 'designs/payn/power/power_payn_array_csa_vart.sv'
TS_TRACE = {'csa': 'designs/payn/power/power_payn_array.sv/array_streaming_rtl.txt',      # headline bench, uniform T
            'csa_vart': CSA_VART_TB + '/array_streaming_csa_vart_rtl.txt',                  # bench copy: ladder, repro
            'af': 'designs/payn/power/power_payn_array_cbsg_af_vart.sv/array_streaming_cbsg_af_rtl.txt',
            'af_lvar': 'designs/payn/power/power_payn_array_cbsg_af_lvar.sv/array_streaming_cbsg_af_rtl.txt'}
# AF ladder variants (sweeps/cbsg/tsweep/run_af_lvar_point.sh): the AF ladder's operands and L draws with
#   ladder_hold8   every block held 8 cycles = the block length of a PE grid (one stream generator, W edges shared by
#                  every PE row of a column, so every PE runs the longest of all the grid's A rows)
#   ladder_rowmax  every row of a chunk at the chunk's longest L, block cycles as the ladder's
TS_LV = TSWEEP / 'af/ladder_variants'
LV_TAGS = {'ladder_hold8': 'hold8', 'ladder_rowmax': 'rowmax'}           # point name -> run tag
LADDER_RUNS = ('ladder', *LV_TAGS)                                       # the runs on the ladder's operand set
GRID_WLS = ('uniform', 'ladder_hold8')        # workloads a grid with one stream generator can run (one block length)
BOTTOM_T = (16, 32, 64, 96)                    # the shorter-T points quoted in the doc's bottom line (all measured)
CSA_HEADLINE_TRACE = PC / 'pinned_pass2_20261004/csa/gl_final' / TS_TRACE['csa']
CSA_LADDER_STIM = TSWEEP / 'csa/stim/ladder_from_af.json'
FLOAT_TSWEEP = PC / 'csa_t_sweep_20261003/results.csv'     # earlier CSA T sweep on the floating route (doc/results.md)
TS_CLASSES = (('tiles', '64 tiles'), ('pe_pipes_glue', 'PE pipes + glue'), ('pe_clk_buf', 'PE clock buffers'),
              ('a_edge', 'A edge'), ('w_edge', 'W edge'), ('bank', 'stream generators'),
              ('shared', 'edge clock buffers + leftovers'), ('top_rest', 'top-level rest'))


def sha256(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def gl_text(status, ndi, iwsba, post):
    return f'{status} (approvals {ndi}/{iwsba}, post-reset violations {post})'


def ts_point(design, tag):
    """One measured sweep point: its result.json, PT class split, power.rpt, stage status files and SAIF, with the
    per-point checks asserted (every stage PASS, the PT view links the route's own netlist and SPEF, class split = PT
    total = power.rpt, strict GL audit with no approvals and no post-reset violation, routed-SDF clock audit and PT
    coverage PASS, drain bit-exact, SAIF window = the result's window)."""
    c = TS[design]
    lv = LV_TAGS.get(tag) if design == 'af' else None          # an AF ladder variant (own directory and view)
    d = TS_LV / lv if lv else c['dir'] / tag
    for st in TS_STAGES:
        assert (d / f'{st}.status').read_text().strip() == 'PASS', f'{d}: stage {st} is not PASS'
    r = jload(d / 'result.json')
    route = ROUTES[c['route']]
    view = route.parent / (f'{route.name}_ptview_tsweep_lv_{lv}' if lv else f'{route.name}_ptview_tsweep_{tag}')
    if lv:
        pv = r['provenance']
        assert pv['errors'] == 0 and pv['same_operands'] and Path(pv['ref_trace']).resolve() == \
            (AF_PIN_MEAS / 'gl_ladder' / AF_TRACE).resolve(), f'{d}: provenance vs the AF ladder trace'
        assert (r['hold'], r['rowmax']) == ((8, False) if lv == 'hold8' else (None, True)), f'{d}: variant flags'
        assert lv != 'hold8' or pv['same_drain_as_ref'] is True, f'{d}: held drain != the ladder drain'
    for f in (f"outputs/{c['top']}.apr.v", f"outputs/{c['top']}.spef"):
        assert (view / f).resolve() == (route / f).resolve(), f"{view}: {f} is not the route's own file"
    assert r.get('run', route.name) == route.name and Path(r.get('route', route)).resolve() == route.resolve() and \
        Path(r.get('pt_view', view)).resolve() == view.resolve(), f'{d}: not a point of {route.name}'
    total = power_total(d / c['power'] / 'power.rpt')
    pw = c['classes'](jload(d / 'classes/power_classes.json')['rows_mW'])
    check_sum(pw, f'{design} {tag} power')
    assert abs(pw['total'] - total) < 1e-6 and abs(r['power_mW'] - total) < 1e-6, f'{d}: classes / result / power.rpt differ'
    want = (('drain_bit_exact', True), ('gl_strict', 'PASS'), ('gl_approvals_ndi', 0), ('gl_approvals_iwsba', 0),
            ('gl_post_reset_violations', 0), ('pt_coverage', 'PASS'), (c['sdf'], 'PASS'))
    bad = [k for k, v in want if r[k] != v]
    assert not bad, f'{d}: {bad}'
    assert r['window_clocks'] == round(r['blocks'] * r['cycles_per_block']), f'{d}: window != blocks x cycles'
    act = saif_activity(view / 'activity/dut.saif')
    assert act['window_clocks'] == r['window_clocks'], f'{d}: SAIF window {act["window_clocks"]} != {r["window_clocks"]}'
    sdfw = r['gl_sdf_warnings']
    pw.update(design=design, tag=tag, workload=r['workload'], length=r.get('T') if design == 'csa' else r.get('L'),
              window=r['window_clocks'], blocks=r['blocks'], cycles=r['cycles_per_block'],
              gl=gl_text(r['gl_strict'], r['gl_approvals_ndi'], r['gl_approvals_iwsba'], r['gl_post_reset_violations']),
              drain_ok='bit-exact (cosim)' if design == 'csa' else 'bit-exact', sdf_warnings=json.loads(sdfw) if isinstance(sdfw, str) else sdfw,
              worst_icg_ns=r['worst_icg_ck_eck_ns'], mean_kA=r.get('mean_kA'), a_density=r.get('a_one_density'),
              act=act, dir=d, view=view,
              trace=d / 'gl' / TS_TRACE['af_lvar' if lv else
                                        'csa_vart' if design == 'csa' and tag in ('ladder', 'repro') else design])
    return pw


def trace_ops(path):
    """Per-block operands of a power-bench trace, CSA (BATCH b [c] / AMAG / ASIGN / WMAG / WSIGN) or AF (BLOCK b C ss /
    AMAG / ASIGN / ALEN / WMAG / WSIGN): [dict(C, AMAG, ASIGN, WMAG, WSIGN[, ALEN])], C None when the trace omits it."""
    import numpy as np
    blocks = []
    for ln in Path(path).read_text().splitlines():
        t = ln.split()
        if not t:
            continue
        if t[0] in ('BATCH', 'BLOCK'):
            blocks.append(dict(C=int(t[2]) if len(t) > 2 else None))
        elif t[0] in ('AMAG', 'ASIGN', 'WMAG', 'WSIGN', 'ALEN') and blocks:
            blocks[-1][t[0]] = np.array([int(v) for v in t[1:]], np.int64)
    return blocks


def af_of_csa(blocks):
    """The AF bench's operands for a CSA trace: the CSA drives |q| << 1, AF the magnitude b = round(|q| x 128 / 127)
    (never a tie for integer |q| < 127), same signs."""
    out = []
    for b in blocks:
        assert not (b['AMAG'] & 1).any() and not (b['WMAG'] & 1).any(), 'CSA magnitude LSB set'
        out.append(dict(C=b['C'], AMAG=((b['AMAG'] >> 1) * 256 + 127) // 254, WMAG=((b['WMAG'] >> 1) * 256 + 127) // 254,
                        ASIGN=b['ASIGN'], WSIGN=b['WSIGN']))
    return out


def same_ops(x, y, cycles=False):
    import numpy as np
    return len(x) == len(y) and all(all(np.array_equal(a[k], b[k]) for k in ('AMAG', 'ASIGN', 'WMAG', 'WSIGN'))
                                    and (not cycles or a['C'] == b['C']) for a, b in zip(x, y))


def same_rows(a, b, keys, tol=1e-9):
    return max(abs(a[k] - b[k]) for k in keys) <= tol


def tsweep_records(prm, csa, afp):
    """Both sweeps, gated on the headline: the CSA T = 128 point must reproduce the qualified CSA baseline (power.rpt
    total, every PT class row, the gate's SAIF / trace / class comparison) and the bench-copy replay must equal it; the
    AF L = 128 and ladder points must reproduce the AF pinned measurement (total and every class row) and the AF gate.
    The CSA ladder-equivalent must carry the AF ladder's exact stimulus (source trace hash, block cycle counts =
    ceil(max row L / M), window).  The two AF ladder variants must drive the AF ladder's operands: ladder_hold8 with the
    ladder's per-row L, every block 8 cycles and the ladder's drain; ladder_rowmax with every row at its block's longest
    ladder L and the ladder's block cycles."""
    m = prm['M']
    lengths = list(range(m, T_STREAM + 1, m))                         # the CSA's T: whole cycles of M positions
    pts = {'csa': {f'T{t}': ts_point('csa', f'T{t}') for t in lengths}}
    for tag in ('ladder', 'repro'):
        pts['csa'][tag] = ts_point('csa', tag)
    af_tags = sorted(p.name for p in TS['af']['dir'].glob('u[0-9][0-9][0-9]') if (p / 'result.json').exists())
    pts['af'] = {t: ts_point('af', t) for t in af_tags + list(LADDER_RUNS)}
    assert all(f'u{t:03d}' in pts['af'] for t in lengths), 'AF sweep lacks a CSA T point'
    # --- operands: every uniform point of a design drives the same blocks as its full-length point, and the AF
    # benches drive the CSA's operands (AF magnitude map) -- at full length and on the ladder, with the same cycles
    ops = {(dn, t): trace_ops(p['trace']) for dn, d in pts.items() for t, p in d.items()}
    c128, a128 = ops[('csa', f'T{T_STREAM}')], ops[('af', f'u{T_STREAM:03d}')]
    for (dn, t), o in ops.items():
        assert len(o) == pts[dn][t]['blocks'], f'{dn} {t}: trace blocks'
        if t not in LADDER_RUNS:
            assert same_ops(o, c128 if dn == 'csa' else a128), f'{dn} {t}: operands differ from the full-length point'
        if dn == 'af' and t not in LADDER_RUNS:
            assert all((b['ALEN'] == pts[dn][t]['length']).all() and b['C'] == pts[dn][t]['cycles'] for b in o), f'AF {t}: L'
    assert sha256(pts['csa'][f'T{T_STREAM}']['trace']) == sha256(CSA_HEADLINE_TRACE), 'CSA T128 trace != headline trace'
    assert same_ops(af_of_csa(c128), a128), 'AF and CSA full-length operands differ'
    assert same_ops(af_of_csa(ops[('csa', 'ladder')]), ops[('af', 'ladder')], cycles=True), 'ladder operands / cycles differ'
    # --- the AF ladder variants: the ladder's operands; hold8 = the ladder's L at 8 cycles per block (= ceil(T / M), the
    # grid's block length) with the ladder's drain, rowmax = each block's longest L on every row at the ladder's cycles
    alad = ops[('af', 'ladder')]
    c_full = -(-T_STREAM // m)
    for t in LV_TAGS:
        o = ops[('af', t)]
        assert same_ops(o, alad), f'AF {t}: operands differ from the AF ladder'
        for b, r in zip(o, alad):
            if t == 'ladder_hold8':
                assert b['C'] == c_full and (b['ALEN'] == r['ALEN']).all(), f'AF {t}: cycles / L'
            else:
                assert b['C'] == r['C'] and (b['ALEN'] == r['ALEN'].max()).all(), f'AF {t}: cycles / L'
    drain = lambda tr: next(ln for ln in Path(tr).read_text().splitlines() if ln.startswith('DRAIN'))
    assert drain(pts['af']['ladder_hold8']['trace']) == drain(pts['af']['ladder']['trace']), 'AF hold8 drain != ladder drain'
    assert pts['af']['ladder_hold8']['window'] == pts['af']['ladder_hold8']['blocks'] * c_full, 'AF hold8 window'
    assert pts['af']['ladder_rowmax']['window'] == pts['af']['ladder']['window'], 'AF rowmax window'
    for p in pts['csa'].values():
        assert p['tag'] in ('ladder', 'repro') or p['length'] * p['blocks'] == m * p['window'], f"CSA {p['tag']}: T != M x cycles"
    for t, p in pts['af'].items():
        if t not in LADDER_RUNS:
            assert p['cycles'] == -(-p['length'] // m), f'AF {t}: cycles != ceil(L / M)'
    cls_keys = [k for k in SUMKEYS + ('total', 'tiles', 'pe_pipes_glue', 'pe_clk_buf', 'a_logic', 'w_logic')]

    # --- gate: CSA T = 128 and the bench-copy replay reproduce the qualified CSA baseline exactly
    hl = csa['power']['uniform']
    g128, rep = pts['csa'][f'T{T_STREAM}'], pts['csa']['repro']
    base_rows = jload(CAMP / 'af/csa_baseline_power_classes/power_classes.json')['rows_mW']
    t128_rows = jload(g128['dir'] / 'classes/power_classes.json')['rows_mW']
    assert g128['total'] == hl['total'] == rep['total'], f"CSA T{T_STREAM} {g128['total']} / repro {rep['total']} != headline {hl['total']}"
    assert abs(g128['total'] - power_total(PC / 'pinned_pass2_20261004/csa/power_result/power.rpt')) < 1e-9, 'CSA T128 power.rpt'
    assert g128['window'] == hl['window'] == rep['window'], 'CSA gate window'
    assert set(t128_rows) == set(base_rows) and same_rows(t128_rows, base_rows, base_rows), 'CSA T128 class rows'
    assert same_rows(g128, rep, cls_keys) and same_rows(g128, hl, cls_keys, 1e-6), 'CSA repro / headline class rows'
    for t in (f'T{T_STREAM}', 'repro'):
        assert (TS['csa']['dir'] / t / 'gate.status').read_text().strip() == 'PASS', f'CSA {t} gate'
    assert (g128['dir'] / 'saif_vs_headline.diff').read_text() == '', 'CSA T128 SAIF differs from the headline SAIF'
    # --- gate: AF L = 128 and ladder reproduce the AF pinned measurement exactly
    ag = jload(TS['af']['dir'] / 'gate.json')
    assert ag['status'] == 'PASS', 'AF gate.json'
    for t, wl in ((f'u{T_STREAM:03d}', 'uniform'), ('ladder', 'ladder')):
        p, h = pts['af'][t], afp['power'][wl]
        assert abs(p['total'] - h['total']) < 1e-9 and p['window'] == h['window'] and abs(p['mean_kA'] - h['mean_kA']) < 1e-12, \
            f'AF {t} gate'
        assert same_rows(p, h, cls_keys, 1e-9), f'AF {t} class rows'
        assert all(ag[t]['checks'].values()), f'AF gate.json {t}'
    # --- the CSA ladder-equivalent carries the AF ladder's exact stimulus
    sj = jload(CSA_LADDER_STIM)
    af_trace = AF_PIN_MEAS / 'gl_ladder' / AF_TRACE
    lad = pts['csa']['ladder']
    assert Path(sj['source']).resolve() == af_trace.resolve() and sj['source_sha256'] == sha256(af_trace), 'ladder stim source'
    assert sj['stim_sha256'] == sha256(sj['stim']) == sha256(lad['dir'] / 'gl' / CSA_VART_TB / 'csa_vart_stim.txt'), 'ladder stim'
    _, afb = read_trace(af_trace)
    assert all(b['C'] == -(-int(b['L'].max()) // m) for b in afb), 'AF ladder block cycles != ceil(max row L / M)'
    hist = {}
    for b in afb:
        hist[b['C']] = hist.get(b['C'], 0) + 1
    tc = jload(lad['dir'] / 'gl/trace_check.json')
    rj = jload(lad['dir'] / 'result.json')
    assert {int(k): v for k, v in json.loads(rj['cycle_histogram']).items()} == hist == \
        {int(k): v for k, v in tc['cycle_histogram'].items()}, 'CSA ladder cycles != AF ladder cycles'
    assert tc['wrong'] == 0 == tc['n_errors'] and Path(tc['af_trace']).resolve() == af_trace.resolve(), 'CSA ladder trace check'
    assert lad['window'] == pts['af']['ladder']['window'] == afp['power']['ladder']['window'] == tc['af_window'], 'ladder windows'
    lad['hist'] = dict(sorted(hist.items()))
    # how much of its block a ladder row fills (L / (M x C)), and the chance that a grid's block is shorter than
    # ceil(T / M): every one of its P_R x N_H A rows drew a rung needing fewer cycles
    fill = [float(v) for b in afb for v in b['L'] / (m * b['C'])]
    rungs = ladder_lengths(pts['af']['ladder'])
    n_full = sum(-(-x // m) == c_full for x in rungs)
    grid_short = {g: (1 - n_full / len(rungs)) ** (pr * prm['N_H']) for g, (pr, pc) in GRIDS.items() if g != '8x4'}
    pe_short = (1 - n_full / len(rungs)) ** prm['N_H']
    lad['workload'] = f'ladder-equivalent: AF ladder operands, each block ceil(max row L / {m}) cycles'
    pts['af']['ladder']['hist'] = pts['af']['ladder_rowmax']['hist'] = lad['hist']
    pts['af']['ladder_rowmax']['workload'] += ' (every row at its block\'s longest L)'
    pts['af']['ladder_hold8']['workload'] += ' (every block 8 cycles: the grid block length)'
    for d in pts.values():
        for p in d.values():
            p.setdefault('hist', {int(p['cycles']): p['blocks']})
    nj = jload(TS['af']['dir'] / 'negctl.json')
    negctl = {t: v['status'] for t, v in nj.items() if isinstance(v, dict)}
    assert set(negctl) == set(af_tags) and set(negctl.values()) == {'PASS'} and all(
        v['original']['rc'] == 0 and v['relabel']['rc'] != 0 and v['drain_plus_1']['rc'] != 0
        for v in nj.values() if isinstance(v, dict)), f'AF checker negative controls: {negctl}'
    rtl = (TSWEEP / 'csa/rtl_checks/summary.txt').read_text().strip().splitlines()[-1]
    assert rtl == 'ALL RTL CHECKS PASS', f'CSA vart RTL checks: {rtl}'
    lv_rtl = (TS_LV / 'rtl_checks/summary.txt').read_text().strip().splitlines()
    assert lv_rtl[-1] == 'ALL RTL CHECKS PASS' and sum(ln.startswith('neg_') and 'FAIL as required' in ln for ln in lv_rtl) == 5, \
        f'AF ladder-variant RTL checks: {lv_rtl[-1]}'
    # --- the earlier floating-route CSA sweep (doc/results.md), for the cross-check only
    flo = {int(r['T']): r for r in csv_rows(FLOAT_TSWEEP) if r['arm'] == 'csa'}
    assert set(flo) >= set(lengths), 'floating CSA sweep lacks a T'
    return dict(pts=pts, lengths=lengths, af_only=[int(t[1:]) for t in af_tags if int(t[1:]) not in lengths],
                floating={t: dict(pJ_MAC=float(flo[t]['pJ_MAC']), window=int(flo[t]['productive_cycles']),
                                  blocks=int(flo[t]['batches']), power_mW=float(flo[t]['power_mW'])) for t in lengths},
                ladder_fill=dict(mean=sum(fill) / len(fill), min=min(fill), rungs=rungs, n_full=n_full, c_full=c_full,
                                 grid_short=grid_short, pe_short=pe_short, n_h=prm['N_H']),
                rtl_checks=rtl, lv_rtl_checks=lv_rtl[-1], lv_negctl=sum(ln.startswith('neg_') for ln in lv_rtl),
                af_negctl=negctl)


def rg_pcell_class(name):
    if re.match(r'(w_binary_q|w_signs_q)_reg', name) or re.match(r'FE_\w+?_(w_mags|w_signs|w_binary)', name):
        return 'w'
    if name.startswith('CTS_') or '/' in name:
        return 'shared'
    return 'a'


def rg_split(wl):
    """Bootstrap-route functional split (PT cell sums) for one workload, plus the u_peripheral side split."""
    d = jload(RG_IND / wl / 'split/power_split.json')
    side = {k: [0.0, 0.0] for k in ('a', 'w', 'shared')}
    areas_by_ref = {}
    abp = dict(total=0.0, internal=0.0, switching=0.0, leakage=0.0, cells=0)   # a_bits_pipe flops (power_split.py rule)
    for ln in (RG_IND / wl / 'split/rg_power_split.txt').read_text().splitlines():
        f = ln.split()
        if not f:
            continue
        if f[0] in ('CELL', 'PCELL'):
            areas_by_ref.setdefault(f[2], float(f[3]))
        if f[0] == 'CELL' and f[4] == '1' and 'a_bits_pipe_reg' in f[1]:
            for i, k in enumerate(('total', 'internal', 'switching', 'leakage')):
                abp[k] += float(f[5 + i]) * 1e3
            abp['cells'] += 1
        if f[0] == 'PCELL':
            c = side[rg_pcell_class(f[1])]
            c[0] += float(f[3])
            c[1] += float(f[5]) * 1e3
        elif f[0] == 'PHIER':
            side['shared'][0] += float(f[2])
            side['shared'][1] += float(f[3]) * 1e3
    tc = d['top_children']
    cc_mw, cc_um = d['core_classes_mW'], d['core_classes_um2']

    def build(ix, cc, tiles, gen, cmp_, cg, field):
        u_pe = tc['u_pe'][field]
        r = dict(total=d['total_mW'] if field == 'mW' else sum(v['um2'] for v in tc.values()),
                 u_pe=u_pe, tiles=tiles, w_gen=gen, w_cmp_tile=cmp_,
                 gen_j=cc['gen_j'] + cc['reg_gen_j'], gen_row=cc['gen_row'], reg_a_bits_pipe=cc['reg_a_bits_pipe'],
                 pipes=sum(cc[k] for k in ('reg_a_bits_pipe', 'reg_w_mag_pipe', 'reg_sign_pipes', 'reg_control')),
                 core_other=sum(cc[k] for k in ('col_shared', 'global', 'dist', 'other')) + cg,
                 col_shared=cc['col_shared'],
                 a_edge=side['a'][ix], w_edge=side['w'][ix], shared=side['shared'][ix], w_regs=side['w'][ix],
                 bank=tc['u_a_rng'][field], a_bank=tc['u_a_rng'][field], w_bank=0.0)
        r['top_rest'] = sum(v[field] for k, v in tc.items() if k not in ('u_pe', 'u_peripheral', 'u_a_rng'))
        r['u_peripheral'] = tc['u_peripheral'][field]
        r['pe_local'] = r['u_pe'] - r['tiles']
        r['new_logic'] = gen + cmp_
        assert abs(r['a_edge'] + r['w_edge'] + r['shared'] - r['u_peripheral']) < 1e-3 * max(1.0, r['u_peripheral'])
        assert abs(r['tiles'] + r['w_gen'] + r['w_cmp_tile'] + r['pipes'] + r['core_other'] - r['u_pe']) \
            < 1e-3 * r['u_pe'], 'rg u_pe split'
        return r
    pw = build(1, cc_mw, d['tiles_mW'], d['w_generators_mW'], d['w_comparators_mW'], d['core_clock_gates_mW'], 'mW')
    assert abs(abp['total'] - cc_mw['reg_a_bits_pipe']) < 1e-6 + 1e-6 * abp['total'], 'a_bits_pipe cell sum'
    pw['abp'] = abp
    area = build(0, cc_um, d['tiles_um2'], d['w_generators_um2'], d['w_comparators_um2'],
                 sum(r['um2'] for r in d['rows'] if r['block'] == 'core clock gates'), 'um2')
    check_sum(pw, f'rg {wl} power')
    check_sum(area, 'rg bootstrap area')
    return pw, area, areas_by_ref


def rg_netlist_periph(route, area_of, total):
    """u_peripheral leaf cells of a routed RG netlist by side (A / W / shared), areas from the bootstrap PT dump's
    ref -> area map.  The pinned route's workload power optimization downsized cells into sizes the bootstrap netlist
    does not use; their total area is the area.rpt u_peripheral total minus the known cells, shared out by the
    number of such cells on each side (almost all are A-side gates; the W side has only its hold buffers)."""
    text = (route / f"outputs/{TOPS['rg']}.apr.v").read_text()
    mods = dict(re.findall(r'^module\s+((?:SNPS_CLOCK_GATE_HIGH_)?cbsg_rg_edge\S*)\s*\((.*?)^endmodule', text, re.S | re.M))
    edge = next(m for m in mods if m.startswith('cbsg_rg_edge_'))
    side, unknown = defaultdict(float), defaultdict(int)

    def walk(mod, prefix):
        for ref, inst in re.findall(r'^\s+(\w+)\s+(\\?\S+)\s*\(', mods[mod], re.M):
            if ref in ('input', 'output', 'inout', 'wire', 'assign', 'module'):
                continue
            if ref in mods:
                walk(ref, prefix + inst + '/')
                continue
            c = rg_pcell_class(prefix + inst.lstrip('\\'))
            if ref in area_of:
                side[c] += area_of[ref]
            else:
                unknown[c] += 1
    walk(edge, '')
    resid = total - sum(side.values())
    n_unk = sum(unknown.values())
    assert resid >= 0 and (n_unk or abs(resid) < 0.05), f'u_peripheral residual {resid} with {n_unk} unknown cells'
    for c, n in unknown.items():
        side[c] += resid * n / n_unk
    return dict(side), dict(unknown=dict(unknown), residual_um2=resid)


def rg_records():
    splits = {wl: rg_split(wl) for wl in RG_WL}
    pw_by_wl, boot_area, area_of = {}, splits['uniform'][1], splits['uniform'][2]
    for wl, (pw, _, _) in splits.items():
        r = csv_rows(RG_IND / wl / 'result.csv')[0]
        assert abs(pw['total'] - float(r['power_mW'])) < 1e-3
        pw.update(workload=r['workload'], window=int(r['window_clocks']), blocks=int(r['blocks']),
                  gl=f"{r['gl_strict']} (approvals {r['gl_approved_ndi_clamps']}/{r['gl_approved_iwsba']})",
                  drain_ok='bit-exact' if r['drain_bit_exact'] == 'True' else 'MISMATCH', mean_kA=None, a_density=None)
        pw_by_wl[wl] = pw
    boot = dict(label='RG bootstrap', route=ROUTES['rg_bootstrap'], sdf_audit=jload(CAMP / 'rg/bootstrap/gl_bootstrap/sdf_clock_audit.json'),
                status='bootstrap activity seed: timing-clean, NOT final-qualified (overlaps, antenna), no workload '
                       'power opt; power indicative only',
                checks=route_checks(ROUTES['rg_bootstrap']), ar=area_rpt(ROUTES['rg_bootstrap'], TOPS['rg']),
                repair=route_repair(ROUTES['rg_bootstrap']), routed_func=None,
                basin=basin(RG_IND / 'basin/basin_gate.json'), area=boot_area, power=pw_by_wl)
    # pinned route: totals from area.rpt, u_peripheral split from its own netlist, core split not available
    route = ROUTES['rg_pinned']
    ar = area_rpt(route, TOPS['rg'])
    ch = ar['children']
    side, unk = rg_netlist_periph(route, area_of, ch['u_peripheral'])
    area = dict(total=ar['total'], u_pe=ch['u_pe'], tiles=ar['tiles'], a_edge=side.get('a', 0.0),
                w_edge=side.get('w', 0.0), shared=side.get('shared', 0.0), bank=ch['u_a_rng'], a_bank=ch['u_a_rng'],
                w_bank=0.0, u_peripheral=ch['u_peripheral'], core_cg=ar['core_cg'], periph_unknown_cells=unk)
    area['top_rest'] = area['total'] - area['u_pe'] - area['u_peripheral'] - area['bank']
    area['pe_local'] = area['u_pe'] - area['tiles']
    assert abs(area['a_edge'] + area['w_edge'] + area['shared'] - area['u_peripheral']) < 0.05, \
        f"rg pinned u_peripheral netlist sum {area['a_edge'] + area['w_edge'] + area['shared']} != {area['u_peripheral']}"
    check_sum(area, 'rg pinned area')
    pinned = dict(label='RG pinned', route=route, sdf_audit=None,
                  status='NOT qualified: setup miss at 2.5 ns (+ DRC, antenna); no GL/PT run on it',
                  checks=route_checks(route), ar=ar, repair=route_repair(route), routed_func=None,
                  basin=basin(CAMP / 'rg/pinned/unqualified_diag/basin/basin_gate.json'), area=area, power={})
    flo = dict(label='RG floating', route=ROUTES['rg_floating'], status='NOT qualified: setup miss (+ DRC)',
               checks=route_checks(ROUTES['rg_floating']), ar=area_rpt(ROUTES['rg_floating'], TOPS['rg']))
    return pinned, boot, flo


def syn_summary(run):
    """Worst setup slack and total cell area of an RG synthesis run (DC timing.rpt / area.rpt)."""
    d = SYN_RG / run
    slack = [float(x) for x in re.findall(r'slack \((?:MET|VIOLATED)\)\s+([-0-9.]+)', (d / 'timing.rpt').read_text())]
    area = float(re.search(r'Total cell area:\s+([0-9.]+)', (d / 'area.rpt').read_text())[1])
    return dict(syn_slack_ns=min(slack), syn_area_um2=area)


def stage_status(cdir, st):
    """A campaign stage's state from its directory: the .status file, else FAIL if failures.log names it, else
    'started, no result yet' if an attempt log exists, else '-'."""
    f, fl = cdir / f'{st}.status', cdir / 'failures.log'
    if f.exists():
        return f.read_text().strip()
    if fl.exists() and st in re.findall(r'FAILED stage=(\S+)', fl.read_text()):
        return 'FAIL'
    return 'started, no result yet' if any(cdir.glob(f'{st}.attempt_*.log')) else '-'


def rg_timing_runs():
    """One row per RG timing-fix run: synthesis, the campaign's bootstrap stages, the strict GL audit, and the
    bootstrap route's reports once its bootstrap_apr stage has passed (a route still being written is not read)."""
    rows = []
    for run, change, cdir in RG_RUNS:
        r = dict(run=run, change=change, campaign_dir=str(cdir.relative_to(REPO)), **syn_summary(run))
        for st in RG_STAGES:
            r[st] = stage_status(cdir, st)
        for st in ('final_apr', 'qualify'):
            r[f'pinned_{st}'] = stage_status(cdir.parent / 'pinned', st)
        if r['bootstrap_apr'] == 'PASS':
            route = APR / f'PAYN_SC_CSA_CBSG_RG/{run}_distguide'
            c = route_checks(route)
            r.update(route=route.name, setup_wns_ns=c['setup_wns_ns'], hold_wns_ns=c['hold_wns_ns'],
                     geometry_drc=c['geometry_drc'], antenna=c['antenna'], overlaps=c['overlaps'],
                     area_um2=area_rpt(route, TOPS['rg'])['total'])
        gl = cdir / 'gl_bootstrap'
        q = gl / 'timing_qualification_strict.json'
        if q.exists():
            q = jload(q)
            eps = sorted({re.sub(r'^Timing violation in (Top\.dut\.)?', '', t['header']) for t in q['timing_records']
                          if not t['before_reset_complete']})
            r.update(gl_strict=q['status'], gl_post_reset_violations=q['post_reset_timing_violations'],
                     gl_post_reset_endpoints=eps, gl_rejections=q['rejection_reasons'])
        tc = gl / 'trace_check.json'
        if tc.exists():
            tc = jload(tc)
            r['gl_drain'] = ('bit-exact' if not tc['errors'] and tc['drain_vs_kernel_bad'] == 0 and tc['drain_vs_hw_bad'] == 0
                             else 'MISMATCH')
        rows.append(r)
    return rows


def rg_netlist_params(route):
    text = (route / f"outputs/{TOPS['rg']}.apr.v").read_text()
    m = re.search(r'InnerPESignedSegmentedCsaCbsgRg\w*?_K(\d+)_M(\d+)_N_H(\d+)_N_W(\d+)_OWIDTH(\d+)_LOW_W\d+_WIDTH(\d+)'
                  r'_IDX_W(\d+)', text)
    k, mm, nh, nw, ow, width, idx = map(int, m.groups())
    acc = {int(x) + 1 for x in re.findall(r'^\s*input \[(\d+):0\] acc_in_west;', text, re.M)}
    assert acc == {nh * ow}, f'acc_in_west widths {acc} != N_H x OWIDTH {nh * ow}'
    return dict(K=k, M=mm, N_H=nh, N_W=nw, OWIDTH=ow, WIDTH=width, IDX_W=idx, THR_W=width - 1, ACC_CHAIN=nh * ow)


# ----------------------------------------------------------------------------------------------- stream model
def read_trace(path):
    """Per-block stimulus of a C-BSG power bench trace (RG: CBSGRG_STREAMCFG / BLOCK b C ss g / L / AMAG / WMAG;
    AF: CBSGAFSTREAM / BLOCK b C ss / AMAG / ALEN / WMAG).  Returns (chunk_blocks or None, [block dicts])."""
    import numpy as np
    cb, blocks, cur = None, [], None
    for ln in Path(path).read_text().splitlines():
        tok = ln.split()
        if not tok:
            continue
        if tok[0] == 'CBSGRG_STREAMCFG':
            cb = int(tok[8])
        elif tok[0] == 'BLOCK':
            cur = dict(b=int(tok[1]), C=int(tok[2]))
            blocks.append(cur)
        elif tok[0] in ('L', 'ALEN', 'AMAG', 'WMAG') and cur is not None:
            cur['L' if tok[0] == 'ALEN' else tok[0]] = np.array([int(v) for v in tok[1:]], np.int64)
    return cb, blocks


def toggle_model(wl, thr_w, idx_w, seed=1):
    """Glitch-free toggle rates per clock of the tile inputs and of the RG (b) forwarded signals, from the bit-exact
    stream models in sweeps/cbsg/cbsg_ref.py driven by the bench's own per-block stimulus (operands, per-row L, cycle
    count, phase = block-in-chunk mod 8), blocks back to back as in the SAIF window.  AF keys use the same trace (the
    AF bench draws the identical stimulus; asserted against its own trace).  'indep' redraws every threshold every
    cycle (a stream with no cycle-to-cycle correlation, like the CSA's).  rg_thr / rg_idx are per bit of the
    per-position threshold (x ^ mask) >> 1 and of the W sample index, the signals RG (b) would register per PE."""
    import numpy as np
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import cbsg_ref as R  # noqa: E402
    rg_path, af_path = TRACES[wl][0](), TRACES[wl][1]
    cb, blocks = read_trace(rg_path)
    if af_path is not None:
        _, afb = read_trace(af_path)
        assert len(afb) == len(blocks) and all(
            a['C'] == b['C'] and all(np.array_equal(a[k], b[k]) for k in ('AMAG', 'WMAG', 'L')) for a, b in zip(afb, blocks)), \
            f'{af_path}: AF stimulus differs from {rg_path}'
    rng = np.random.default_rng(seed)
    pos = np.arange(R.POS)
    bits = lambda x, n: ((x[..., None] >> np.arange(n)) & 1).astype(bool)
    tog, prev, n = defaultdict(float), None, 0
    for blk in blocks:
        aB = blk['AMAG'].reshape(R.TILE_R, R.LANES)                                       # (row h, lane k)
        wB = blk['WMAG'].reshape(R.TILE_R, R.LANES).T                                     # (lane k, column v)
        Lr = blk['L']
        masks = R.HW_MASK[:, (blk['b'] % cb) % 8]
        kA = R.ka_closed(aB, Lr[:, None], masks[None, :])
        j = np.zeros((R.TILE_R, R.LANES), np.int64)
        for c in range(blk['C']):
            t = R.POS * c + pos
            cur = {}
            cur['af_a'] = t[None, None, :] < kA[:, :, None]                                # (h, k, m)
            rB = (R.XK_BANK[c][None, :] ^ masks[:, None]) >> 1                              # (k, m)
            cur['af_w'] = wB[:, :, None] > rB[:, None, :]                                   # (k, v, m)
            rA = (R.XQ_BANK[c][None, :] ^ masks[:, None]) >> 1
            a = (rA[None, :, :] < aB[:, :, None]) & (t[None, None, :] < Lr[:, None, None])  # (h, k, m), length gate
            idx = j[:, :, None] + (np.cumsum(a, axis=2) - a)
            thr = (R.XK_GRAY[idx] ^ masks[None, :, None]) >> 1                              # (h, k, m)
            cur['rg_a'] = a
            cur['rg_w'] = wB[None, :, :, None] > thr[:, :, None, :]                         # (h, k, v, m)
            assert thr.max() < (1 << thr_w) and idx.max() < (1 << idx_w)
            cur['rg_thr'] = bits(thr, thr_w)
            cur['rg_idx'] = bits(idx, idx_w)
            j += a.sum(axis=2)
            cur['indep'] = wB[:, :, None] > rng.integers(0, 128, (R.LANES, R.POS))[:, None, :]
            if prev is not None:
                for key, v in cur.items():
                    tog[key] += float((v != prev[key]).mean())
                n += 1
            prev = cur
    out = {k: v / n for k, v in tog.items()}
    out['clocks'] = n + 1
    out['trace'] = str(rg_path.relative_to(REPO))
    return out


# ----------------------------------------------------------------------------------------------- derived figures
def per_mac(p_mw, window, blocks, macs_per_block, n_pe=1):
    return p_mw * window * T_NS / (n_pe * blocks * macs_per_block)


def composite(a, pr, pc, u_pe=None, a_extra=0.0, classic_ok=True):
    """Grid composite (area or power) from a per-PE hierarchy dict: split form (A edge per PE row, W edge per PE
    column) and the symmetric (P_R + P_C)/2 x u_peripheral form (None where it has no meaning)."""
    u = a['u_pe'] if u_pe is None else u_pe
    a_side = a['a_edge'] + a['shared'] / 2 + a_extra
    w_side = a['w_edge'] + a['shared'] / 2
    split = pr * pc * u + pr * a_side + pc * w_side + a['bank']
    classic = pr * pc * u + (pr + pc) / 2 * (a['u_peripheral'] + a_extra) + a['bank'] if classic_ok else None
    return split, classic, dict(u_pe=u, a_side=a_side, w_side=w_side, bank=a['bank'])


def tsweep_summary(ts, mb):
    """Per-point energies (pJ/MAC, pJ per block, per class), grid composites and SAIF activity of both sweeps, the
    common-T pairs, the AF-only lengths against the CSA point with the same cycles per block, and the ladder
    comparisons with the cycle-mix consistency check (uniform points weighted by the ladder's block-cycle histogram)."""
    m = ts['lengths'][0]
    pts = []
    for design, d in ts['pts'].items():
        for tag, p in d.items():
            eb = p['window'] * T_NS / p['blocks']            # ns per block: mW x ns/block = pJ per block
            row = dict(design=design, tag=tag, workload=p['workload'], length=p['length'], cycles=p['cycles'],
                       window=p['window'], blocks=p['blocks'], hist=p['hist'], power_mW=p['total'],
                       pJ_MAC=per_mac(p['total'], p['window'], p['blocks'], mb), pJ_block=p['total'] * eb,
                       mean_kA=p['mean_kA'], a_density=p['a_density'], gl=p['gl'], drain=p['drain_ok'],
                       sdf_warnings=p['sdf_warnings'], worst_icg_ns=p['worst_icg_ns'],
                       port_operand_TC=p['act']['port_operand_TC'], tile_a_per_clock=p['act']['tile_a_bits_per_clock'],
                       tile_w_per_clock=p['act']['tile_w_bits_per_clock'],
                       cls_mW={k: p[k] for k, _ in TS_CLASSES}, cls_pJ_block={k: p[k] * eb for k, _ in TS_CLASSES},
                       cls_resid_mW=p['total'] - sum(p[k] for k, _ in TS_CLASSES),
                       a_logic_mW=p['a_logic'], w_logic_mW=p['w_logic'], a_regs_mW=p['a_regs'], w_regs_mW=p['w_regs'],
                       ka_enc_mW=p.get('ka_enc'), therm_mW=p.get('therm'))
            assert abs(row['cls_resid_mW']) < 1e-3, f'{design} {tag}: classes do not add up'
            # A grid with one stream generator runs one block length for every PE (its W edges feed every PE row of a
            # column), so only the runs with one block length per block for the whole array compose into a grid: the
            # uniform points, the replay and AF's held ladder.  The per-row-L runs give each PE its own block length.
            row['grid_ok'] = tag not in ('ladder', 'ladder_rowmax')
            for gname in ('4x4', '4x8'):
                pr, pc = GRIDS[gname]
                row[f'grid_{gname}_pJ_MAC'] = per_mac(composite(p, pr, pc)[0], p['window'], p['blocks'], mb, pr * pc) \
                    if row['grid_ok'] else None
            pts.append(row)
    idx = {(r['design'], r['tag']): r for r in pts}
    csa_at = lambda t: idx[('csa', f'T{t}')]
    af_at = lambda t: idx[('af', f'u{t:03d}')]
    common = [dict(length=t, csa=csa_at(t), af=af_at(t)) for t in ts['lengths']]
    af_only = [dict(length=t, af=af_at(t), csa_same=csa_at(m * -(-t // m))) for t in ts['af_only']]
    lad = dict(af=idx[('af', 'ladder')], csa=idx[('csa', 'ladder')], csa_full=csa_at(T_STREAM), af_full=af_at(T_STREAM),
               repro=idx[('csa', 'repro')], af_rowmax=idx[('af', 'ladder_rowmax')], af_hold8=idx[('af', 'ladder_hold8')])
    hist = lad['csa']['hist']
    nb = sum(hist.values())
    # the uniform points weighted by the ladder's block-cycle mix: per block (energy, tile energy) and per clock (tile
    # input toggles, clock-weighted) -- a cross-check of the measured same-block-length runs (CSA ladder-equivalent, AF
    # rowmax)
    def mix(fn, f, per_clock=False):
        w = {c: n * (c if per_clock else 1) for c, n in hist.items()}
        return sum(w[c] * f(fn(m * c)) for c in hist) / sum(w.values())
    lad['cycle_mix'] = {d: mix(fn, lambda r: r['pJ_block']) for d, fn in (('csa', csa_at), ('af', af_at))}
    lad['cycle_mix_tiles'] = {d: mix(fn, lambda r: r['cls_pJ_block']['tiles']) for d, fn in (('csa', csa_at), ('af', af_at))}
    lad['cycle_mix_kA'] = mix(af_at, lambda r: r['mean_kA'])
    lad['cycle_mix_a_toggles'] = {d: mix(fn, lambda r: r['tile_a_per_clock'], per_clock=True)
                                  for d, fn in (('csa', csa_at), ('af', af_at))}
    lad['fill'] = ts['ladder_fill']
    lad['fill_uniform'] = {t: t / (m * -(-t // m)) for t in ts['lengths'] + ts['af_only']}
    return dict(points=pts, common=common, af_only=af_only, ladder=lad, lengths=ts['lengths'], m=m,
                floating=ts['floating'], rtl_checks=ts['rtl_checks'], af_negctl=ts['af_negctl'],
                lv_rtl_checks=ts['lv_rtl_checks'], lv_negctl=ts['lv_negctl'])


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    # --- operand / tile-input activity from the SAIFs (also gives the CSA window)
    act = {f'{d}/{wl}': saif_activity(p) for (d, wl), p in SAIFS.items()}
    prm = rg_netlist_params(ROUTES['rg_pinned'])
    csa = csa_record(act['csa/uniform']['window_clocks'], T_STREAM // prm['M'])
    afp = af_record('af_pinned', AF_PIN_MEAS, 'AF pinned',
                    'qualified final (fix (c): post-fill repair hook + targeted repair; af/pinned_fix/README.txt)')
    # --- stream-length sweeps on both finished routes (gated on the two headlines); the CSA ladder-equivalent run
    # becomes the CSA's ladder workload everywhere below
    ts = tsweep_records(prm, csa, afp)
    csa['power']['ladder'] = ts['pts']['csa']['ladder']
    # the AF ladder variants (measured on the same route): rowmax (every row at its block's longest L) and hold8 (every
    # block 8 cycles, the grid block length -- the only per-row-L run a grid composite may use)
    for t in LV_TAGS:
        afp['power'][t] = ts['pts']['af'][t]
    act = {k: v for k0, v0 in act.items()
           for k, v in [(k0, v0)] + ([(f'af_pinned/{t}', ts['pts']['af'][t]['act']) for t in LV_TAGS]
                                     if k0 == 'af_pinned/ladder' else [])}
    aq = jload(AF_PIN_DIR / 'qualification.json')
    assert aq['qualification'] == 'final' == afp['checks']['flow_qualification'], 'AF pinned route is not final-qualified'
    aff = af_record('af_floating', CAMP / 'af/floating_measure', 'AF floating',
                    'qualified final, collapsed basin: reference only, not quoted')
    # superseded: the unrepaired pinned route (same placement and signal routing up to the fillers)
    unq = {('uniform' if r['workload'].startswith('uniform') else 'ladder'): r for r in csv_rows(AF_UNQ / 'result.csv')}
    af_superseded = dict(run=unq['uniform']['run'], qualification=unq['uniform']['route_qualification'],
                         geometry_drc=int(unq['uniform']['geometry_drc']), setup_wns_ns=float(unq['uniform']['setup_wns_ns']),
                         area_um2=float(unq['uniform']['area_um2']), skew_ps=float(unq['uniform']['mean_abs_skew_ps']),
                         **{f'{wl}_{k2}': float(unq[wl][k2]) for wl in unq for k2 in ('power_mW', 'pJ_per_MAC')})
    rgp, rgb, rgf = rg_records()
    rg_runs = rg_timing_runs()
    nh, nw, k, m = prm['N_H'], prm['N_W'], prm['K'], prm['M']
    mac_cycle = nh * nw * k * m / T_STREAM
    mac_block = nh * nw * k
    gmacs_pe = mac_cycle * F_GHZ
    designs = {'csa': csa, 'af_pinned': afp, 'af_floating': aff, 'rg_pinned': rgp, 'rg_bootstrap': rgb}

    # --- glitch-free toggle rates: the benches' own stimulus replayed through cbsg_ref.py
    model = {wl: toggle_model(wl, prm['THR_W'], prm['IDX_W']) for wl in RG_WL}

    # --- RG (b): generator at the A edge, forwarded thr / idx per PE
    syn = jload(RG_SYN_AREA)
    pos = nh * k * m
    flop_um2_bit = syn['rg_core_classes_um2']['reg_a_bits_pipe'] / pos
    upe_scale = rgp['area']['u_pe'] / rgb['area']['u_pe']          # pinned u_pe / bootstrap u_pe
    gen_area = dict(routed=rgb['area']['w_gen'], scaled=rgb['area']['w_gen'] * upe_scale,
                    synth=syn['rg_w_generators_um2'])
    gen_row_area = dict(routed=rgb['area']['gen_row'], scaled=rgb['area']['gen_row'] * upe_scale,
                        synth=syn['rg_core_classes_um2']['gen_row'])
    fwd = {
        'thr': dict(bits=pos * prm['THR_W'], width=prm['THR_W'], move_area=gen_area, rate_key='rg_thr',
                    move_mw_key='w_gen', note='threshold (after Gray/XOR map and mask)'),
        'idx': dict(bits=pos * prm['IDX_W'], width=prm['IDX_W'],
                    move_area={b: gen_area[b] - gen_row_area[b] for b in gen_area}, rate_key='rg_idx',
                    move_mw_key='gen_j', note='raw W sample index; Gray/XOR map stays per PE'),
    }
    for f in fwd.values():
        f['flop_um2'] = f['bits'] * flop_um2_bit

    def flop_mw_bit(p, wl, rate_key):
        """Routed a_bits_pipe power per bit; its switching part is rescaled from the measured a_bits toggle rate to
        the model rate of rate_key (None keeps the a_bits rate)."""
        abp = p['abp']
        fixed, sw = (abp['total'] - abp['switching']) / pos, abp['switching'] / pos
        if rate_key is None:
            return fixed + sw
        return fixed + sw * model[wl][rate_key] / act[f'rg_bootstrap/{wl}']['tile_a_bits_per_clock']

    # --- single-PE rows
    def single(rec):
        a = rec['area']
        out = dict(label=rec['label'], status=rec['status'], area_total=a['total'], gmacs_mm2_1pe=gmacs_pe / (a['total'] * 1e-6),
                   **{f'area_{k2}': a.get(k2) for k2 in ('u_pe', 'tiles', 'pe_local', 'a_edge', 'w_edge', 'shared', 'bank',
                                                        'top_rest', 'new_logic', 'w_gen', 'w_cmp_tile', 'u_peripheral')},
                   u_pe_instances=rec['ar']['children_inst']['u_pe'], u_pe_module=rec['ar']['children_module']['u_pe'],
                   **{f'chk_{k2}': v for k2, v in rec['checks'].items()},
                   **{f'basin_{k2}': v for k2, v in rec['basin'].items() if k2 != 'die_um'},
                   die_um='x'.join(f'{v:.1f}' for v in rec['basin']['die_um']),
                   **{f'repair_{k2}': v for k2, v in rec['repair'].items() if k2 != 'targeted'},
                   **{f'repair_targeted_{k2}': v for k2, v in (rec['repair']['targeted'] or {}).items()},
                   **{f'routed_func_{k2}': v for k2, v in (rec['routed_func'] or {}).items()})
        for wl, p in rec['power'].items():
            out[f'{wl}_power_mW'] = p['total']
            out[f'{wl}_pJ_MAC'] = per_mac(p['total'], p['window'], p['blocks'], mac_block)
            out[f'{wl}_pJ_block'] = p['total'] * p['window'] * T_NS / p['blocks']
            out[f'{wl}_window'] = p['window']
            out[f'{wl}_cycles_per_block'] = p['window'] / p['blocks']
            for k2 in ('u_pe', 'tiles', 'pe_local', 'a_edge', 'w_edge', 'shared', 'bank', 'top_rest', 'w_gen', 'w_cmp_tile'):
                if k2 in p:
                    out[f'{wl}_{k2}_mW'] = p[k2]
        return out
    single_rows = [single(r) for r in designs.values()]

    # --- grid composites
    def make_grid(name, basis, a, p_by_wl, u_pe_a=None, a_extra_a=0.0, classic_ok=True):
        rows = []
        for g, (pr, pc) in GRIDS.items():
            n = pr * pc
            split, classic, parts = composite(a, pr, pc, u_pe_a, a_extra_a, classic_ok)
            row = dict(design=name, basis=basis, grid=g, P_R=pr, P_C=pc, area_um2=split, area_classic_um2=classic,
                       per_pe_um2=split / n, per_pe_u_pe=parts['u_pe'], per_pe_a_share=parts['a_side'] / pc,
                       per_pe_w_share=parts['w_side'] / pr, per_pe_bank=parts['bank'] / n,
                       gmacs_mm2=n * gmacs_pe / (split * 1e-6),
                       gmacs_mm2_classic=n * gmacs_pe / (classic * 1e-6) if classic else None)
            for wl, (p, upe, aex) in p_by_wl.items():
                if wl not in GRID_WLS:        # per-row-L runs: each PE its own block length, not a grid workload
                    continue
                ps, pcl, _ = composite(p, pr, pc, upe, aex, classic_ok)
                row[f'{wl}_power_mW'] = ps
                row[f'{wl}_pJ_MAC'] = per_mac(ps, p['window'], p['blocks'], mac_block, n)
                row[f'{wl}_pJ_MAC_classic'] = per_mac(pcl, p['window'], p['blocks'], mac_block, n) if pcl else None
            rows.append(row)
        return rows

    grid_rows = []
    grid_rows += make_grid('CSA', CSA_BASIS, csa['area'], {wl: (p, None, 0.0) for wl, p in csa['power'].items()})
    grid_rows += make_grid('AF', AF_PIN_BASIS, afp['area'], {wl: (p, None, 0.0) for wl, p in afp['power'].items()})
    grid_rows += make_grid('AF', AF_FLO_BASIS, aff['area'], {wl: (p, None, 0.0) for wl, p in aff['power'].items()})
    grid_rows += make_grid(RG_A, RG_A_BASIS, rgp['area'], {wl: (p, None, 0.0) for wl, p in rgb['power'].items()})

    def rgb_rows(kind, abasis, rate):
        f = fwd[kind]
        move = f['move_area'][abasis]
        u_pe_b = rgp['area']['u_pe'] - move + f['flop_um2']
        pmap = {}
        for wl, p in rgb['power'].items():
            move_mw = p[f['move_mw_key']]
            pmap[wl] = (p, p['u_pe'] - move_mw + f['bits'] * flop_mw_bit(p, wl, f['rate_key'] if rate == 'forwarded' else None),
                        move_mw)
        basis = (f"pinned u_pe - {abasis} generator area {move:,.0f} + {f['bits']:,} flops x {flop_um2_bit:.3f} um2; "
                 f"flop power at the {kind if rate == 'forwarded' else 'a_bits'} toggle rate")
        return make_grid(f'{RG_B_PREFIX}{kind}', basis, rgp['area'], pmap, u_pe_b, move,
                         classic_ok=False), dict(move_um2=move, flop_um2=f['flop_um2'], bits=f['bits'], u_pe_um2=u_pe_b)

    main_b, _ = rgb_rows('thr', 'routed', 'forwarded')
    grid_rows += main_b
    rg_b, sens = {}, []
    for kind in fwd:
        for abasis in ('routed', 'scaled', 'synth'):
            for rate in ('forwarded', 'a_bits'):
                rows, info = rgb_rows(kind, abasis, rate)
                rg_b[f'{kind}/{abasis}'] = info
                for r in rows:
                    sens.append(dict(r, kind=kind, area_basis=abasis, flop_rate=rate))
    flop_power = {}
    for wl, p in rgb['power'].items():
        for kind, f in fwd.items():
            flop_power[f'{kind}/{wl}'] = dict(
                rate_model=model[wl][f['rate_key']], a_bits_rate_measured=act[f'rg_bootstrap/{wl}']['tile_a_bits_per_clock'],
                abp_mW=p['abp']['total'], abp_switching_mW=p['abp']['switching'],
                per_pe_mW_forwarded=f['bits'] * flop_mw_bit(p, wl, f['rate_key']),
                per_pe_mW_a_bits_rate=f['bits'] * flop_mw_bit(p, wl, None),
                moved_mW=p[f['move_mw_key']])

    # --- the composites must reproduce the campaign's comparison (CSA and AF floating; symmetric form at 4x8)
    camp = {(r['label'], r['pins']): r for r in csv_rows(CAMP_RESULTS)}
    gidx = {(r['design'], r['basis'], r['grid']): r for r in grid_rows}
    checks = []
    cases = [(('csa', 'pinned'), 'CSA', CSA_BASIS, ROUTES['csa']), (('af', 'floating'), 'AF', AF_FLO_BASIS, ROUTES['af_floating'])]
    if ('af', 'pinned') in camp:                # cited only if results.csv carries the qualified pinned route
        cases.append((('af', 'pinned'), 'AF', AF_PIN_BASIS, ROUTES['af_pinned']))
    for (lab, pins), dn, basis, route in cases:
        r = camp[(lab, pins)]
        assert r['run'] == route.name, f'results.csv {lab} {pins} is {r["run"]}, not {route.name}'
        g4, g8 = gidx[(dn, basis, '4x4')], gidx[(dn, basis, '4x8')]
        pairs = [('comp4x4_um2', float(r['comp4x4_um2']), g4['area_um2']),
                 ('comp4x4_um2 (symmetric)', float(r['comp4x4_um2']), g4['area_classic_um2']),
                 ('comp4x8_um2 (symmetric)', float(r['comp4x8_um2']), g8['area_classic_um2']),
                 ('gmacs_mm2_4x8 (symmetric)', float(r['gmacs_mm2_4x8']), g8['gmacs_mm2_classic'])]
        for what, ref, got in pairs:
            assert abs(ref - got) < 0.05, f'{lab} {pins} {what}: campaign {ref} != composite {got}'
        checks.append(dict(design=f'{lab} {pins}', comp4x4_um2=float(r['comp4x4_um2']), comp4x8_um2=float(r['comp4x8_um2']),
                           gmacs_mm2_4x8=float(r['gmacs_mm2_4x8']), split_4x8_um2=g8['area_um2']))
    camp_af_pinned = camp.get(('af', 'pinned'), {}).get('run')

    # --- forwarding wires: crossings of a PE's west/east boundary vs horizontal routing tracks
    pit = track_pitches(ROUTES['rg_pinned'])
    h_layers = {ly: p for ly, (d, p) in pit.items() if d == 'H'}
    today = pos + nh * k + prm['ACC_CHAIN']
    wires = dict(a_bits=pos, a_signs=nh * k, acc_chain=prm['ACC_CHAIN'], today=today, thr=fwd['thr']['bits'],
                 idx=fwd['idx']['bits'], h_layers=h_layers)
    for key, rec in (('rg_pinned_die', rgp), ('csa_die', csa)):
        hgt = rec['basin']['die_um'][1]
        cap = sum(hgt / p for p in h_layers.values())
        wires[key] = dict(height_um=hgt, h_tracks=cap, frac_today=today / cap, frac_thr=(today + fwd['thr']['bits']) / cap)

    tsw = tsweep_summary(ts, mac_block)

    summary = dict(params=dict(prm, mac_per_cycle=mac_cycle, kernel_macs_per_block=mac_block, f_ghz=F_GHZ, T=T_STREAM),
                   tsweep=tsw,
                   toggle_model=model, flop_um2_per_bit_synth=flop_um2_bit, rg_forwarding=rg_b, rg_b_flop_power=flop_power,
                   fwd={kk: {k2: v for k2, v in f.items()} for kk, f in fwd.items()}, upe_scale=upe_scale,
                   wires=wires, activity=act, single=single_rows, grid=grid_rows, rgb_sensitivity=sens,
                   campaign_composite_checks=checks, campaign_af_pinned_run=camp_af_pinned,
                   af_qualification=aq, af_superseded_unqualified=af_superseded, rg_timing_runs=rg_runs,
                   rg_floating=dict(checks=rgf['checks'], area=rgf['ar']['total']),
                   rg_status=jload(CAMP / 'rg/rg_campaign_status.json')['routes'],
                   generated=datetime.now().astimezone().isoformat(timespec='minutes'))
    (OUT / 'summary.json').write_text(json.dumps(summary, indent=1, default=str) + '\n')
    ts_rows = [{k: (json.dumps(v) if isinstance(v, dict) else v) for k, v in r.items() if not k.startswith('cls_')}
               | {f'{k}_mW': v for k, v in r['cls_mW'].items()} | {f'{k}_pJ_block': v for k, v in r['cls_pJ_block'].items()}
               for r in tsw['points']]
    for name, rows in (('single_pe.csv', single_rows), ('grid.csv', grid_rows), ('rgb_sensitivity.csv', sens),
                       ('rg_timing_runs.csv', rg_runs), ('tsweep.csv', ts_rows)):
        keys = []
        for r in rows:
            keys += [k2 for k2 in r if k2 not in keys]
        with (OUT / name).open('w', newline='') as fh:
            w = csv.DictWriter(fh, fieldnames=keys)
            w.writeheader()
            w.writerows(rows)
    md, blocks = tables(designs, single_rows, grid_rows, act, summary, rgf)
    (OUT / 'tables.md').write_text(md)
    print(md)
    if DOC:
        print(f'spliced into {DOC}: ' + ', '.join(splice_doc(DOC, blocks)), file=sys.stderr)


# ----------------------------------------------------------------------------------------------- markdown tables
def f0(v):
    return '-' if v is None else f'{v:,.0f}'


def f1(v):
    return '-' if v is None else f'{v:,.1f}'


def f3(v):
    return '-' if v is None else f'{v:.3f}'


def f4(v):
    return '-' if v is None else f'{v:.4f}'


def pct(v, ref):
    return '-' if v is None or ref is None else f'{100 * (v / ref - 1):+.1f}%'


BLOCK_RE = re.compile(r'^<!-- block:(\w+) -->$')
END = '<!-- /block -->'


def begin(name):
    return f'<!-- block:{name} -->'


def split_blocks(lines):
    """tables.md text (block sentinels dropped) and the named blocks, each the lines between its sentinels with
    leading/trailing blank lines stripped."""
    out, blocks, cur = [], {}, None
    for ln in lines:
        m = BLOCK_RE.match(ln)
        if m:
            assert cur is None, f'block {m[1]} opened inside {cur}'
            cur = m[1]
            blocks[cur] = []
        elif ln == END:
            assert cur is not None, 'block end without a start'
            cur = None
        else:
            out.append(ln)
            if cur is not None:
                blocks[cur].append(ln)
    assert cur is None, f'block {cur} not closed'
    return '\n'.join(out) + '\n', {k: '\n'.join(v).strip('\n') for k, v in blocks.items()}


def splice_doc(path, blocks):
    """Replace every <!-- BEGIN generated:NAME --> ... <!-- END generated:NAME --> region of the doc with block NAME.
    Every marker must name a block; returns the names spliced."""
    text = Path(path).read_text()
    names = re.findall(r'<!-- BEGIN generated:(\w+) -->', text)
    assert names, f'{path}: no generated markers'
    for n in names:
        assert n in blocks, f'{path}: marker {n} is not a generated block ({sorted(blocks)})'
        pat = re.compile(rf'(<!-- BEGIN generated:{n} -->\n).*?(<!-- END generated:{n} -->)', re.S)
        assert len(pat.findall(text)) == 1, f'{path}: marker {n} missing its END or repeated'
        text = pat.sub(lambda m: m[1] + blocks[n] + '\n' + m[2], text)
    Path(path).write_text(text)
    return names


def tables(designs, single_rows, grid_rows, act, s, rgf):
    D = designs
    cols = list(D)
    hdr = '| | ' + ' | '.join(D[c]['label'] for c in cols) + ' |\n|---|' + '---:|' * len(cols) + '\n'
    L = ['<!-- generated by sweeps/cbsg/compare_cbsg.py; do not edit by hand -->', '', begin('stamp'),
         f"Tables generated {s['generated']} by `sweeps/cbsg/compare_cbsg.py`.", END, '']
    mb = s['params']['kernel_macs_per_block']
    gm = s['params']['mac_per_cycle'] * F_GHZ
    tl = s['tsweep']['ladder']
    pm = lambda p: per_mac(p['total'], p['window'], p['blocks'], mb)
    g = {(r['design'], r['grid']): r for r in grid_rows if r['basis'] != AF_FLO_BASIS}
    gf = {r['grid']: r for r in grid_rows if r['basis'] == AF_FLO_BASIS}
    ref = {r['grid']: r for r in grid_rows if r['design'] == 'CSA'}
    sg = {r['label']: r for r in single_rows}

    def row(name, fn, fmt=f1):
        vals = []
        for c in cols:
            try:
                v = fn(D[c])
            except (KeyError, TypeError):
                v = None
            vals.append(fmt(v) if not isinstance(v, str) else v)
        return f'| {name} | ' + ' | '.join(vals) + ' |'

    # ------------------------------------------------------------------ bottom line (doc section 1)
    t_ = s['tsweep']
    cm_ = {c['length']: c for c in t_['common']}
    csp, afpp = D['csa'], D['af_pinned']
    cu_, au_ = csp['power']['uniform'], afpp['power']['uniform']
    c4_, c8_, a4_, a8_ = g[('CSA', '4x4')], g[('CSA', '4x8')], g[('AF', '4x4')], g[('AF', '4x8')]
    scs, saf = sg['CSA pinned'], sg['AF pinned']
    bl_t = [n for n in BOTTOM_T if n in cm_]
    assert bl_t == list(BOTTOM_T), f'bottom line T points {BOTTOM_T} not all measured'
    slash = lambda vals, fmt: ' / '.join(fmt(v) for v in vals)
    rev8 = [n for n in bl_t if cm_[n]['af']['grid_4x8_pJ_MAC'] > cm_[n]['csa']['grid_4x8_pJ_MAC']]
    tlh = tl['af_hold8']
    L += ['### Bottom line (single PE measured; grid figures are composites)', '', begin('bottom_line'),
          '| | CSA (baseline) | AF | AF vs CSA |', '|---|---:|---:|---:|',
          f"| area, 1 PE (um2) | {csp['area']['total']:,.1f} | {afpp['area']['total']:,.1f} | "
          f"{pct(afpp['area']['total'], csp['area']['total'])} |",
          f"| SC power, uniform L = {T_STREAM} (mW) | {cu_['total']:.3f} | {au_['total']:.3f} | {pct(au_['total'], cu_['total'])} |",
          f"| energy per kernel MAC, 1 PE (pJ) | {pm(cu_):.4f} | {pm(au_):.4f} | {pct(pm(au_), pm(cu_))} |",
          f"| SC GMAC/s/mm2, 1 PE / 4x4 / 4x8 grid composite | {scs['gmacs_mm2_1pe']:.1f} / {c4_['gmacs_mm2']:.1f} / "
          f"{c8_['gmacs_mm2']:.1f} | {saf['gmacs_mm2_1pe']:.1f} / {a4_['gmacs_mm2']:.1f} / {a8_['gmacs_mm2']:.1f} | "
          f"{pct(saf['gmacs_mm2_1pe'], scs['gmacs_mm2_1pe'])} / {pct(a4_['gmacs_mm2'], c4_['gmacs_mm2'])} / "
          f"{pct(a8_['gmacs_mm2'], c8_['gmacs_mm2'])} |",
          f"| energy per MAC, 4x4 / 4x8 grid composite (pJ) | {c4_['uniform_pJ_MAC']:.4f} / {c8_['uniform_pJ_MAC']:.4f} | "
          f"{a4_['uniform_pJ_MAC']:.4f} / {a8_['uniform_pJ_MAC']:.4f} | {pct(a4_['uniform_pJ_MAC'], c4_['uniform_pJ_MAC'])} / "
          f"{pct(a8_['uniform_pJ_MAC'], c8_['uniform_pJ_MAC'])} |",
          f"| per-row ladder (L in {{{max(tl['fill']['rungs'])}..{min(tl['fill']['rungs'])}}}), 1 PE, pJ/MAC (each block as "
          f"long as its longest row; both measured) | {tl['csa']['pJ_MAC']:.4f} (ladder-equivalent) | {tl['af']['pJ_MAC']:.4f} | "
          f"{pct(tl['af']['pJ_MAC'], tl['csa']['pJ_MAC'])} |",
          f"| per-row ladder on a grid (every block {tl['fill']['c_full']} cycles), 4x4 / 4x8 composite pJ/MAC | "
          f"{c4_['uniform_pJ_MAC']:.4f} / {c8_['uniform_pJ_MAC']:.4f} (T = {T_STREAM}) | {tlh['grid_4x4_pJ_MAC']:.4f} / "
          f"{tlh['grid_4x8_pJ_MAC']:.4f} (blocks held {tl['fill']['c_full']} cycles) | "
          f"{pct(tlh['grid_4x4_pJ_MAC'], c4_['uniform_pJ_MAC'])} / {pct(tlh['grid_4x8_pJ_MAC'], c8_['uniform_pJ_MAC'])} |",
          f"| energy per kernel MAC at T = {slash(bl_t, str)}, 1 PE (pJ, measured) | "
          f"{slash([cm_[n]['csa']['pJ_MAC'] for n in bl_t], lambda v: f'{v:.4f}')} | "
          f"{slash([cm_[n]['af']['pJ_MAC'] for n in bl_t], lambda v: f'{v:.4f}')} | "
          f"{slash([pct(cm_[n]['af']['pJ_MAC'], cm_[n]['csa']['pJ_MAC']) for n in bl_t], str)}"
          + (f" (4x8 grid composite at T = {', '.join(str(n) for n in rev8)}: "
             f"{', '.join(pct(cm_[n]['af']['grid_4x8_pJ_MAC'], cm_[n]['csa']['grid_4x8_pJ_MAC']) for n in rev8)})" if rev8 else '')
          + ' |',
          f"| setup / hold WNS (ns) | {csp['checks']['setup_wns_ns']:+.3f} / {csp['checks']['hold_wns_ns']:+.3f} | "
          f"{afpp['checks']['setup_wns_ns']:+.3f} / {afpp['checks']['hold_wns_ns']:+.3f} | |",
          f"| placement basin (corr(tile x, column), skew) | {csp['basin']['verdict']} ({csp['basin']['corr_x_col']:.3f}, "
          f"{csp['basin']['skew_ps']:.1f} ps) | {afpp['basin']['verdict']} ({afpp['basin']['corr_x_col']:.3f}, "
          f"{afpp['basin']['skew_ps']:.1f} ps) | |", '',
          f"The grid convention is 4x8 = {GRIDS['4x8'][0]} PE rows (one A edge each) x {GRIDS['4x8'][1]} PE columns (one W "
          f"edge each). Grid figures are composites of the single-PE runs (section 3). The project's symmetric "
          f"(P_R + P_C)/2 formula gives {pct(a8_['area_classic_um2'], c8_['area_classic_um2'])} area at 4x8 instead of "
          f"{pct(a8_['area_um2'], c8_['area_um2'])}; both forms are in `tables.md`. The CSA cannot give rows different stream "
          f"lengths, so its single-PE ladder figure runs the AF ladder's operands with each block as long as its longest row, "
          f"the same block lengths AF runs. A grid runs one block length for all its PEs, {tl['fill']['c_full']} cycles for "
          f"this ladder in all but {100 * tl['fill']['grid_short']['4x8']:.1f}% of chunks, so the grid row compares AF's "
          f"ladder held at {tl['fill']['c_full']}-cycle blocks with the CSA at T = {T_STREAM} (section 3.1).", END, '']

    # ------------------------------------------------------------------ why AF wins (doc section 2)
    ca_, aa_ = csp['area'], afpp['area']
    ac, aa = act['csa/uniform'], act['af_pinned/uniform']
    prm_ = s['params']
    n_a, n_w, n_ka = prm_['N_H'] * prm_['K'] * prm_['M'], prm_['N_W'] * prm_['K'] * prm_['M'], prm_['N_H'] * prm_['K']
    rng2 = lambda x, y: f'{min(x, y):.2f}' if f'{x:.2f}' == f'{y:.2f}' else f'{min(x, y):.2f}-{max(x, y):.2f}'
    da = lambda *k: sum(aa_[x] - ca_[x] for x in k)
    dp = lambda *k: sum(au_[x] - cu_[x] for x in k)
    ti_ = {c['length']: c['af']['cls_pJ_block']['tiles'] - c['csa']['cls_pJ_block']['tiles'] for c in t_['common']}
    pe_ = {c['length']: sum(c['af']['cls_pJ_block'][k] - c['csa']['cls_pJ_block'][k] for k in ('tiles', 'pe_pipes_glue', 'pe_clk_buf'))
           for c in t_['common']}
    why = [(f"{prm_['N_H'] * prm_['N_W']} tiles", ('tiles',), ('tiles',),
            f"A's ones come first in each block, so tile inputs toggle {rng2(aa['tile_a_bits_per_clock'], aa['tile_w_bits_per_clock'])} "
            f"per clock against the CSA's {rng2(ac['tile_a_bits_per_clock'], ac['tile_w_bits_per_clock'])}"),
           ('PE-local logic (pipes, glue, clock buffers)', ('pe_local',), ('pe_pipes_glue', 'pe_clk_buf'),
            'same reason: the a_bits/w_bits pipes carry fewer transitions'),
           ('A edge', ('a_edge',), ('a_edge',),
            f"{n_ka} kA encoders ({aa_['ka_enc']:,.0f} um2) and thermometer decoders ({aa_['therm']:,.0f}) replace "
            f"{n_a:,} A comparators"),
           ('W edge', ('w_edge',), ('w_edge',),
            f"the {prm_['M']} W lane words per cycle differ only by constants, so the {n_w:,} comparators share logic "
            f"({aa_['w_logic'] / n_w:.1f} um2 each vs {ca_['w_logic'] / n_w:.1f})"),
           ('stream generators', ('bank',), ('bank',),
            f"one tiny sample-ordered W bank ({aa_['bank']:,.0f} um2) replaces the CSA's A and W Sobol pair "
            f"({ca_['bank']:,.0f} um2)"),
           ('edge clock buffers + top-level rest', ('shared', 'top_rest'), ('shared', 'top_rest'), '')]
    L += [f'### Why AF wins (uniform L = {T_STREAM}, change vs CSA)', '', begin('why'),
          f'| part (uniform L = {T_STREAM}) | area change (um2) | power change (mW) | what changed |', '|---|---:|---:|---|']
    for name, ka, kp, note in why:
        L.append(f"| {name} | {da(*ka):+,.0f} | {dp(*kp):+.3f} | {note} |")
    tot_a, tot_p = sum(da(*w_[1]) for w_ in why), sum(dp(*w_[2]) for w_ in why)
    assert abs(tot_a - (aa_['total'] - ca_['total'])) < 0.5 and abs(tot_p - (au_['total'] - cu_['total'])) < 2e-3, 'why: parts'
    hot_t = sorted((n for n in ti_ if ti_[n] > 0), reverse=True)
    hot_pe = sorted((n for n in pe_ if pe_[n] > 0), reverse=True)
    L += [f"| **total** | **{aa_['total'] - ca_['total']:+,.0f}** | **{au_['total'] - cu_['total']:+.3f}** | |", '',
          f"Operand activity is matched: the operand ports toggle "
          f"{pct(aa['port_operand_TC'], ac['port_operand_TC'])} against the CSA bench's. The power excludes the drain.", '',
          f"This breakdown is for T = {T_STREAM}. At shorter T the tile and pipe savings shrink"
          + (f": the tiles alone cost more than the CSA's at T = {' and '.join(str(n) for n in hot_t)}" if hot_t else '')
          + (f", and the PE core (tiles, pipes and PE clock buffers) at T = {' and '.join(str(n) for n in hot_pe)}"
             if hot_pe else '') + ' (section 3.2).', END, '']

    # ------------------------------------------------------------------ headline
    L += ['### Headline: SC GMAC/s/mm2 and energy per kernel MAC (iso-T, L = T = 128 uniform; ladder = per-row L)', '',
          begin('headline'),
          'Grid "R x C" = R PE rows (one A edge each) x C PE columns (one W edge each): 4x8 = P_R 4 x P_C 8, as PaYN '
          'uses it. "sym." = the project\'s symmetric (P_R + P_C)/2 x u_peripheral form, for reference.', '',
          f"CSA ladder-equivalent = the AF ladder's operands with each block run for ceil(max row L / {s['params']['M']}) "
          'cycles (the CSA has one T per block), measured on the CSA route.', '',
          f"Grid ladder: a grid with one stream generator runs one block length for every PE (each W edge feeds every PE "
          f"row of its column), set by the longest of all its A rows: {tl['fill']['c_full']} cycles in all but "
          f"{100 * tl['fill']['grid_short']['4x8']:.1f}% of the ladder's chunks at {GRIDS['4x8'][0]} PE rows. AF's grid "
          f"ladder figure is composed from the AF ladder run with every block held {tl['fill']['c_full']} cycles (measured), "
          f"and the CSA's counterpart is T = {T_STREAM}. The single-PE per-row-L runs (AF ladder, CSA ladder-equivalent, RG "
          'rowmix / rowgrouped) give each PE its own block length, so they have no grid composite.', '',
          '| design | basis | GMAC/s/mm2 1 PE | 4x4 | 4x8 | 4x8 sym. | pJ/MAC 1 PE | 4x4 | 4x8 | 4x8 sym. | '
          'ladder pJ/MAC: 1 PE (blocks as long as their longest row); 4x4 / 4x8 grid composite (every block '
          f"{tl['fill']['c_full']} cycles) |",
          '|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|']
    c4, c8 = g[('CSA', '4x4')], g[('CSA', '4x8')]
    heads = [('CSA', 'CSA', CSA_BASIS, 'CSA pinned', 'CSA pinned'),
             ('AF', 'AF', AF_PIN_BASIS, 'AF pinned', 'AF pinned'),
             ('RG (a) generators in every PE', RG_A, RG_A_BASIS, 'RG pinned', 'RG bootstrap'),
             ('RG (b) generators at the A edge, forward thr', B_THR, '**estimate** from RG (a) (section 3)', None, None)]
    for name, dn, basis, s_area, s_pow in heads:
        r4, r8 = g[(dn, '4x4')], g[(dn, '4x8')]
        oa, op = (sg[s_area] if s_area else None), (sg[s_pow] if s_pow else None)
        lad, one_pe = [], []
        csl1 = sg['CSA pinned']['ladder_pJ_MAC']
        for wl in ('ladder', 'rowmix', 'rowgrouped'):
            v1 = op.get(f'{wl}_pJ_MAC') if op else None
            if v1 is not None:
                vs = f" ({pct(v1, csl1)} vs CSA ladder-equivalent)" if wl in ('ladder', 'rowmix') and dn != 'CSA' else ''
                one_pe.append(f"{'ladder-equivalent' if dn == 'CSA' else wl} {v1:.4f}{vs}")
        if one_pe:
            lad.append('1 PE: ' + ', '.join(one_pe))
        if dn == 'CSA':
            lad.append(f"grid: T = {T_STREAM} {r4['uniform_pJ_MAC']:.4f} / {r8['uniform_pJ_MAC']:.4f}")
        elif 'ladder_hold8_pJ_MAC' in r4:
            lad.append(f"grid: ladder held {tl['fill']['c_full']} cycles {r4['ladder_hold8_pJ_MAC']:.4f} / "
                       f"{r8['ladder_hold8_pJ_MAC']:.4f} ({pct(r4['ladder_hold8_pJ_MAC'], c4['uniform_pJ_MAC'])} / "
                       f"{pct(r8['ladder_hold8_pJ_MAC'], c8['uniform_pJ_MAC'])} vs CSA T = {T_STREAM})")
        elif lad:
            lad.append(f"grid: no run at {tl['fill']['c_full']}-cycle blocks")
        L.append(f"| {name} | {basis} | {f1(oa['gmacs_mm2_1pe']) if oa else '-'} | {r4['gmacs_mm2']:.1f} | "
                 f"{r8['gmacs_mm2']:.1f} | {f1(r8['gmacs_mm2_classic'])} | {f4(op['uniform_pJ_MAC']) if op else '-'} | "
                 f"{f4(r4['uniform_pJ_MAC'])} | {f4(r8['uniform_pJ_MAC'])} | {f4(r8['uniform_pJ_MAC_classic'])} | "
                 f"{'; '.join(lad) or '-'} |")
    L.append('')

    L.append(END)
    # ------------------------------------------------------------------ routes
    L += ['### Routes, timing, physical checks and basin', '', begin('routes'), hdr.rstrip()]
    L.append(row('route', lambda d: f"`{d['route'].name}`", str))
    L.append(row('status', lambda d: d['status'], str))
    L.append(row('setup WNS (ns, Innovus)', lambda d: d['checks']['setup_wns_ns'], f3))
    L.append(row('hold WNS (ns)', lambda d: d['checks']['hold_wns_ns'], f3))
    L.append(row('worst setup path', lambda d: '`{}` -> `{}`'.format(*d['checks']['setup_path']), str))
    L.append(row('routed SDF: worst clock-gate CK->ECK (ns) / gates',
                 lambda d: f"{d['sdf_audit']['worst_icg_iopath_ns']} / {d['sdf_audit']['icg_cells']}" if d['sdf_audit'] else '-', str))
    L.append(row('fillers: DRC-checked pass / pass 2 "without DRC checking"',
                 lambda d: f"{d['repair']['fillers_pass1']:,} / {d['repair']['fillers_pass2']:,}", str))
    L.append(row('strong reroute: router markers per routable net / search-and-repair iterations',
                 lambda d: f"{d['repair']['markers_per_net']:.3f} / {d['repair']['sr_iterations']}", str))
    L.append(row('post-fill repair hook (AF fix (c)): iterations / markers after via swap',
                 lambda d: (f"{d['repair']['postfill_iterations']} / {d['repair']['postfill_after_via_swap']}"
                            if d['repair']['postfill_ran'] else '-'), str))
    L.append(row('targeted residual repair: geometry markers / antenna pins',
                 lambda d: (f"{d['repair']['targeted']['geometry']} / {d['repair']['targeted']['antenna_pins']}"
                            if d['repair']['targeted'] else 'none'), str))
    L.append(row('final geometry DRC (verify, capped at 1000) / router count',
                 lambda d: f"{d['checks']['geometry_drc']} / {d['checks']['router_drc']}", str))
    L.append(row('final antenna / overlaps / connectivity',
                 lambda d: f"{d['checks']['antenna']} / {d['checks']['overlaps']} / "
                           f"{'clean' if d['checks']['connectivity_clean'] else 'NOT clean'}", str))
    L.append(row('flow qualification', lambda d: d['checks']['flow_qualification'], str))
    L.append(row('routed functional bench (cases x reset settles)',
                 lambda d: (f"{d['routed_func']['passed']}/{d['routed_func']['runs']} PASS ({d['routed_func']['cases']} "
                            f"cases x settle {', '.join(d['routed_func']['settles'])})") if d['routed_func'] else '-', str))
    L.append(row('basin (gate)', lambda d: d['basin']['verdict'], str))
    L.append(row('corr(tile x, column)', lambda d: d['basin']['corr_x_col'], f3))
    L.append(row('corr(tile y, -row)', lambda d: d['basin']['corr_y_negrow'], f3))
    L.append(row('skew (ps; gate <= 50)', lambda d: f"{d['basin']['skew_ps']:.1f}"
                 + ('' if d['basin']['skew_calibrated'] else ' (RG metric, uncalibrated)'), str))
    L.append(row('pin proof', lambda d: d['basin']['pin_proof'] or '-', str))
    L.append(row('tile pitch col / row (um)', lambda d: f"{d['basin']['d_col_um']:.1f} / {d['basin']['d_row_um']:.1f}", str))
    L.append(row('die (um)', lambda d: 'x'.join(f'{v:.1f}' for v in d['basin']['die_um']), str))
    L.append(row('wire (mm)', lambda d: d['basin']['wire_mm'], f0))
    L.append('')
    L.append(f"RG floating final `{rgf['route'].name}`: setup {rgf['checks']['setup_wns_ns']:+.3f} ns, hold "
             f"{rgf['checks']['hold_wns_ns']:+.3f} ns, geometry DRC {rgf['checks']['geometry_drc']}, area "
             f"{rgf['ar']['total']:,.1f} um2. Violating setup paths (RG campaign status): pinned "
             f"{s['rg_status']['pinned_final']['violating_paths']}, floating {s['rg_status']['floating_final']['violating_paths']}.")
    L.append('')
    u = s['af_superseded_unqualified']
    afu, afl = D['af_pinned']['power']['uniform'], D['af_pinned']['power']['ladder']
    L.append(f"Superseded: the unrepaired AF pinned route `{u['run']}` (flow qualification '{u['qualification']}', geometry "
             f"DRC {u['geometry_drc']} = the verify cap) measured {u['uniform_power_mW']:.3f} mW / {u['uniform_pJ_per_MAC']:.4f} "
             f"pJ/MAC uniform and {u['ladder_power_mW']:.3f} mW / {u['ladder_pJ_per_MAC']:.4f} pJ/MAC ladder, area "
             f"{u['area_um2']:,.1f} um2, setup {u['setup_wns_ns']:+.3f} ns, skew {u['skew_ps']:.1f} ps; the qualified route: "
             f"{pct(afu['total'], u['uniform_power_mW'])} / {pct(afl['total'], u['ladder_power_mW'])} power, "
             f"{D['af_pinned']['area']['total'] - u['area_um2']:+.1f} um2.")
    L.append('')

    L.append(END)
    # ------------------------------------------------------------------ RG timing-fix runs
    L += ['### RG timing-fix runs (bootstrap stage of each synthesis run)', '', begin('rg_runs'),
          '| run | RTL change | syn slack (ns) | syn area (um2) | bootstrap route | setup / hold (ns, Innovus) | route area (um2) | '
          'strict GL audit (post-reset violations) | GL drain | stages: bootstrap apr / sim / audit, floating final, pinned '
          'final / qualify |', '|---|---|---:|---:|---|---:|---:|---|---|---|']
    for r in s['rg_timing_runs']:
        gl = (f"{r['gl_strict']} ({r['gl_post_reset_violations']}"
              + (f"; at `{'`, `'.join(r['gl_post_reset_endpoints'])}`" if r['gl_post_reset_endpoints'] else '') + ')'
              ) if 'gl_strict' in r else '-'
        L.append(f"| `{r['run']}` | {r['change']} | {r['syn_slack_ns']:+.2f} | {r['syn_area_um2']:,.1f} | "
                 f"{('`' + r['route'] + '`') if 'route' in r else '-'} | "
                 f"{(format(r['setup_wns_ns'], '+.3f') + ' / ' + format(r['hold_wns_ns'], '+.3f')) if 'route' in r else '-'} | "
                 f"{f1(r.get('area_um2'))} | {gl} | {r.get('gl_drain', '-')} | "
                 f"{r['bootstrap_apr']} / {r['bootstrap_sim']} / {r['bootstrap_audit']}, {r['final_apr']}, "
                 f"{r['pinned_final_apr']} / {r['pinned_qualify']} |")
    L.append('')

    L.append(END)
    # ------------------------------------------------------------------ area
    L += ['### Area (um2)', '', begin('area'), hdr.rstrip()]
    A = lambda k: (lambda d: d['area'].get(k))
    L.append(row('**total**', A('total')))
    L.append(row('PE core `u_pe`', A('u_pe')))
    L.append(row('&nbsp;&nbsp;u_pe instances (area.rpt)', lambda d: d['ar']['children_inst']['u_pe'], f0))
    L.append(row('&nbsp;&nbsp;64 CSA tiles', A('tiles')))
    L.append(row('&nbsp;&nbsp;PE-local logic (u_pe - tiles)', A('pe_local')))
    L.append(row('&nbsp;&nbsp;&nbsp;&nbsp;RG: 64 W index generators', A('w_gen')))
    L.append(row('&nbsp;&nbsp;&nbsp;&nbsp;RG: 8,192 per-tile W comparators', A('w_cmp_tile')))
    L.append(row('A edge (regs + A-side logic)', A('a_edge')))
    L.append(row('&nbsp;&nbsp;A-side logic: CSA 1,024 A comparators / AF 64 kA encoders + input buffers + thermometers',
                 lambda d: d['area'].get('a_logic')))
    L.append(row('&nbsp;&nbsp;&nbsp;&nbsp;AF: 64 kA encoders', A('ka_enc')))
    L.append(row('W edge (regs + W-side logic)', A('w_edge')))
    L.append(row('&nbsp;&nbsp;W-side logic: CSA / AF 1,024 W comparators', lambda d: d['area'].get('w_logic')))
    L.append(row('edge clock buffers + leftovers', A('shared')))
    L.append(row('stream generators (CSA A+W Sobol, AF `u_rng`, RG `u_a_rng`)', A('bank')))
    L.append(row('top-level rest', A('top_rest')))
    L.append(row('new logic (no CSA counterpart)', A('new_logic')))
    L.append(row('vs CSA total', lambda d: pct(d['area']['total'], D['csa']['area']['total']), str))
    L.append(row('GMAC/s/mm2, 1 PE', lambda d: gm / (d['area']['total'] * 1e-6)))
    L.append('')
    uk = D['rg_pinned']['area']['periph_unknown_cells']
    L.append(f"RG pinned u_peripheral side split: {sum(uk['unknown'].values()):,} cells in sizes absent from the bootstrap PT "
             f"dump ({', '.join(f'{k2} {v}' for k2, v in sorted(uk['unknown'].items()))}); their {uk['residual_um2']:,.1f} um2 "
             f"(area.rpt minus known cells) is shared out by cell count.")
    L.append('')

    # ------------------------------------------------------------------ power
    wls = [('uniform', 'uniform L=128'), ('ladder', 'AF ladder (per-row L, = RG rowmix)'),
           ('ladder_rowmax', 'ladder, rows at block max'), ('ladder_hold8', 'ladder, blocks held 8 cycles'),
           ('rowmix', 'RG ladder_rowmix'), ('rowgrouped', 'RG ladder_rowgrouped')]
    pcols = [(c, wl) for c in cols for wl, _ in wls if wl in D[c]['power']]
    wl_name = lambda c, wl: ('ladder-equivalent' if (c, wl) == ('csa', 'ladder') else
                             dict(wls)[wl] if wl.startswith('ladder_') else wl)
    ph = '| | ' + ' | '.join(f"{D[c]['label']}<br>{wl_name(c, wl)}" for c, wl in pcols) + ' |\n|---|' + '---:|' * len(pcols)
    L.append(END)
    L += ['### Power (mW, PT-PX on routed SPEF + max-SDF GL SAIF, drain excluded)', '', begin('power'), ph]

    def prow(name, fn, fmt=f3):
        vals = []
        for c, wl in pcols:
            try:
                v = fn(D[c]['power'][wl], c, wl)
            except (KeyError, TypeError):
                v = None
            vals.append(fmt(v) if not isinstance(v, str) else v)
        return f'| {name} | ' + ' | '.join(vals) + ' |'
    P = lambda k: (lambda p, c, wl: p.get(k))
    L.append(prow('**total**', P('total')))
    L.append(prow('PE core `u_pe`', P('u_pe')))
    L.append(prow('&nbsp;&nbsp;64 CSA tiles', P('tiles')))
    L.append(prow('&nbsp;&nbsp;PE pipes + glue (CSA/AF)', P('pe_pipes_glue')))
    L.append(prow('&nbsp;&nbsp;PE clock buffers (CSA/AF)', P('pe_clk_buf')))
    L.append(prow('&nbsp;&nbsp;RG: W index generators', P('w_gen')))
    L.append(prow('&nbsp;&nbsp;RG: per-tile W comparators', P('w_cmp_tile')))
    L.append(prow('&nbsp;&nbsp;RG: pipes', P('pipes')))
    L.append(prow('&nbsp;&nbsp;RG: other PE-local (col-shared, fan-out, clock)', P('core_other')))
    L.append(prow('A edge', P('a_edge')))
    L.append(prow('&nbsp;&nbsp;A-side logic (CSA A comparators / AF encoders + input buffers + thermometers)', P('a_logic')))
    L.append(prow('&nbsp;&nbsp;&nbsp;&nbsp;AF: 64 kA encoders', P('ka_enc')))
    L.append(prow('W edge', P('w_edge')))
    L.append(prow('edge clock buffers + leftovers', P('shared')))
    L.append(prow('stream generators', P('bank')))
    L.append(prow('top-level rest', P('top_rest')))
    L.append(prow('window clocks / blocks', lambda p, c, wl: f"{p['window']} / {p['blocks']}", str))
    L.append(prow('cycles per block', lambda p, c, wl: p['window'] / p['blocks'], lambda v: f'{v:.2f}'))
    L.append(prow('**pJ per kernel MAC**', lambda p, c, wl: pm(p), f4))
    L.append(prow('pJ per block (512 MACs)', lambda p, c, wl: p['total'] * p['window'] * T_NS / p['blocks'], f1))
    cu = D['csa']['power']['uniform']
    cl_ = D['csa']['power']['ladder']
    L.append(prow('vs CSA pJ/MAC (uniform, ladder held 8 cycles: T = 128; ladder / rows at block max / rowmix: CSA '
                  'ladder-equivalent)',
                  lambda p, c, wl: pct(pm(p), pm(cu)) if wl in ('uniform', 'ladder_hold8') else pct(pm(p), pm(cl_))
                  if wl in ('ladder', 'ladder_rowmax', 'rowmix') else 'n/a: no CSA run of this stimulus', str))
    L.append(prow('vs AF pinned ladder pJ/MAC (same per-row-L stimulus)',
                  lambda p, c, wl: pct(pm(p), pm(afl)) if wl in ('ladder', 'ladder_rowmax', 'ladder_hold8', 'rowmix') else '-', str))
    L.append(prow('GL audit', lambda p, c, wl: p['gl'], str))
    L.append(prow('drain check', lambda p, c, wl: p['drain_ok'], str))
    L.append('')

    L.append(END)
    # ------------------------------------------------------------------ hierarchy deltas vs CSA
    L += ['### Change vs CSA by hierarchy (uniform L=128)', '', begin('deltas'),
          '| part | AF pinned area | AF pinned mW | AF floating mW | RG pinned area | RG bootstrap area | RG bootstrap mW |',
          '|---|---:|---:|---:|---:|---:|---:|']
    ca, cp = D['csa']['area'], D['csa']['power']['uniform']
    parts = [('total', 'total'), ('u_pe', 'PE core'), ('tiles', '64 tiles'), ('pe_local', 'PE-local logic'),
             ('a_edge', 'A edge'), ('w_edge', 'W edge'), ('shared', 'edge clock buffers + leftovers'),
             ('bank', 'stream generators'), ('top_rest', 'top-level rest')]
    for key, name in parts:
        def dl(x, refd, fmt):
            return '-' if x is None or key not in x else fmt(x[key] - refd[key])
        sa = lambda v: f'{v:+,.0f}'
        sp = lambda v: f'{v:+.3f}'
        L.append(f"| {name} | {dl(D['af_pinned']['area'], ca, sa)} | {dl(D['af_pinned']['power']['uniform'], cp, sp)} | "
                 f"{dl(D['af_floating']['power']['uniform'], cp, sp)} | {dl(D['rg_pinned']['area'], ca, sa)} | "
                 f"{dl(D['rg_bootstrap']['area'], ca, sa)} | {dl(D['rg_bootstrap']['power']['uniform'], cp, sp)} |")
    L.append('')

    L.append(END)
    # ------------------------------------------------------------------ activity
    L += ['### Operand and tile-input activity (SAIF toggle counts over the window)', '', begin('activity'),
          '| run | window clocks | operand-port TC (A+W mag+sign) | vs CSA | tile a_bits mean / max TC | per clock | '
          'tile w_bits mean / max TC | per clock |', '|---|---:|---:|---:|---:|---:|---:|---:|']
    base = act['csa/uniform']['port_operand_TC']
    for key, a in act.items():
        L.append(f"| {key} | {a['window_clocks']} | {a['port_operand_TC']:,} | {pct(a['port_operand_TC'], base)} | "
                 f"{a['tile_a_bits_mean_TC']:.0f} / {a['tile_a_bits_max_TC']} | {a['tile_a_bits_per_clock']:.3f} | "
                 f"{a['tile_w_bits_mean_TC']:.0f} / {a['tile_w_bits_max_TC']} | {a['tile_w_bits_per_clock']:.3f} |")
    L.append('')
    tm = s['toggle_model']
    L.append(END)
    L += ['### Glitch-free toggle model vs SAIF (toggles per clock; bench stimulus replayed through cbsg_ref.py)', '',
          begin('toggle'),
          '| signal | uniform: SAIF | model | ladder / rowmix: SAIF | model | rowgrouped: SAIF | model |',
          '|---|---:|---:|---:|---:|---:|---:|']
    meas = {('af_a', 'uniform'): act['af_pinned/uniform']['tile_a_bits_per_clock'],
            ('af_a', 'rowmix'): act['af_pinned/ladder']['tile_a_bits_per_clock'],
            ('af_w', 'uniform'): act['af_pinned/uniform']['tile_w_bits_per_clock'],
            ('af_w', 'rowmix'): act['af_pinned/ladder']['tile_w_bits_per_clock'],
            ('indep', 'uniform'): act['csa/uniform']['tile_w_bits_per_clock']}
    for wl in RG_WL:
        meas[('rg_a', wl)] = act[f'rg_bootstrap/{wl}']['tile_a_bits_per_clock']
        meas[('rg_w', wl)] = act[f'rg_bootstrap/{wl}']['tile_w_bits_per_clock']
    names = [('af_a', 'AF tile a_bits'), ('af_w', 'AF tile w_bits'), ('rg_a', 'RG tile a_bits'),
             ('rg_w', 'RG tile w_bits'), ('rg_thr', 'RG thr bit (RG (b) forwarded, 7 b)'),
             ('rg_idx', 'RG idx bit (W sample index, 8 b)'), ('indep', 'independent threshold (CSA w_bits SAIF)')]
    for key, nm in names:
        cells = []
        for wl in RG_WL:
            mv = meas.get((key, wl))
            show_model = not (key.startswith('af') and wl == 'rowgrouped') and not (key == 'indep' and wl != 'uniform')
            cells += [f3(mv), f3(tm[wl][key]) if show_model else '-']
        L.append(f'| {nm} | ' + ' | '.join(cells) + ' |')
    L.append('')

    L.append(END)
    # ------------------------------------------------------------------ grids
    L += ['### Grid composites (R x C = P_R PE rows x P_C PE columns)', '',
          'Split form: P_R x P_C x u_pe + P_R x (A edge + shared/2) + P_C x (W edge + shared/2) + one stream-generator '
          'set. Symmetric form: P_R x P_C x u_pe + (P_R + P_C)/2 x u_peripheral + generators. Powers composed the same way '
          f"(peak: no skew or drain cycles; the top-level rest, {min(D[c]['power']['uniform']['top_rest'] for c in ('csa', 'af_pinned')):.2f}-"
          f"{max(D[c]['power']['uniform']['top_rest'] for c in ('csa', 'af_pinned')):.2f} mW at 1 PE for AF / CSA, is left out). Every PE of a grid runs "
          f"the same block length (one stream generator, W edges shared by a PE column), so the per-row-L runs are composed "
          f"only from the run with every block held {tl['fill']['c_full']} cycles (AF; the CSA's counterpart is its uniform "
          f"T = {T_STREAM}).", '', begin('grid'),
          '| design | grid | area (um2) | vs CSA | symmetric (um2) | vs CSA | per PE (um2) | of which u_pe / A share / '
          'W share | GMAC/s/mm2 | vs CSA | sym. GMAC/s/mm2 | vs CSA | pJ/MAC uniform | sym. pJ/MAC | ladder pJ/MAC, every '
          f"block {tl['fill']['c_full']} cycles (vs CSA T = {T_STREAM}) |",
          '|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|']
    bases = {}
    for r in grid_rows:
        if r['grid'] == '8x4' or r['basis'] == AF_FLO_BASIS or (r['design'].startswith(RG_B_PREFIX) and r['design'] != B_THR):
            continue
        bases.setdefault(r['design'], r['basis'])
        c = ref[r['grid']]
        lad = ([f"= uniform T = {T_STREAM}"] if r['design'] == 'CSA' else
               [f"held {r['ladder_hold8_pJ_MAC']:.4f} ({pct(r['ladder_hold8_pJ_MAC'], c['uniform_pJ_MAC'])})"]
               if 'ladder_hold8_pJ_MAC' in r else [f"no run at {tl['fill']['c_full']}-cycle blocks"])
        cl = r['area_classic_um2']
        L.append(f"| {r['design']} | {r['grid']} | {r['area_um2']:,.1f} | {pct(r['area_um2'], c['area_um2'])} | "
                 f"{f1(cl)} | {pct(cl, c['area_classic_um2'])} | {r['per_pe_um2']:,.0f} | "
                 f"{r['per_pe_u_pe']:,.0f} / {r['per_pe_a_share']:,.0f} / {r['per_pe_w_share']:,.0f} | "
                 f"{r['gmacs_mm2']:.1f} | {pct(r['gmacs_mm2'], c['gmacs_mm2'])} | {f1(r['gmacs_mm2_classic'])} | "
                 f"{pct(r['gmacs_mm2_classic'], c['gmacs_mm2_classic'])} | "
                 f"{f4(r['uniform_pJ_MAC'])} ({pct(r['uniform_pJ_MAC'], c['uniform_pJ_MAC'])}) | "
                 f"{f4(r.get('uniform_pJ_MAC_classic'))} | {', '.join(lad) or '-'} |")
    L.append('')
    L.append('Bases: ' + '; '.join(f'{d}: {b}' for d, b in bases.items()) + '.')
    L.append('')
    cc = s['campaign_composite_checks']
    L.append('Campaign check (asserted): ' + '; '.join(
        f"{x['design']} reproduces results.csv 4x4 {x['comp4x4_um2']:,.1f} and 4x8 {x['comp4x8_um2']:,.1f} um2 "
        f"({x['gmacs_mm2_4x8']:.1f} GMAC/s/mm2) in the symmetric form (split 4x8: {x['split_4x8_um2']:,.1f})" for x in cc)
        + ('. results.csv has no AF pinned row (compare_cbsg_pinned.py was not rerun on the qualified route).'
           if not s['campaign_af_pinned_run'] else '.'))
    L.append('')

    # ------------------------------------------------------------------ RG (b) sensitivities
    sens = s['rgb_sensitivity']
    sx = {(r['kind'], r['area_basis'], r['flop_rate'], r['grid']): r for r in sens}
    ra = {gr: g[(RG_A, gr)] for gr in ('4x4', '4x8')}
    L.append(END)
    L += ['### RG (b) sensitivities (generators at the A edge; forwarded flops per PE)', '', begin('rgb'),
          'Area: generator area moved out of each PE from the routed bootstrap split (routed), that split scaled by '
          f"pinned / bootstrap u_pe = {s['upe_scale']:.3f} (scaled), or the synthesized split (synth).", '',
          '| forwarded | generator area basis | moved out (um2) | flops (um2) | per PE 4x4 | per PE 4x8 | GMAC/s/mm2 4x4 | 4x8 | vs RG (a) 4x8 |',
          '|---|---|---:|---:|---:|---:|---:|---:|---:|']
    for kind in s['fwd']:
        for ab in ('routed', 'scaled', 'synth'):
            r4, r8 = sx[(kind, ab, 'forwarded', '4x4')], sx[(kind, ab, 'forwarded', '4x8')]
            info = s['rg_forwarding'][f'{kind}/{ab}']
            L.append(f"| {kind} | {ab} | {info['move_um2']:,.0f} | {info['flop_um2']:,.0f} | {r4['per_pe_um2']:,.0f} | "
                     f"{r8['per_pe_um2']:,.0f} | {r4['gmacs_mm2']:.1f} | {r8['gmacs_mm2']:.1f} | "
                     f"{pct(r8['gmacs_mm2'], ra['4x8']['gmacs_mm2'])} |")
    L.append('')
    fp = s['rg_b_flop_power']
    L += ['Energy (uniform; power moved out = the generators, added = the forwarded flops at the a_bits_pipe power per '
          'bit, switching part at the stated toggle rate):', '',
          '| forwarded | flop toggle rate (per clock) | flops per PE (mW) | moved out per PE (mW) | pJ/MAC 4x4 | 4x8 | '
          'vs RG (a) 4x4 | vs RG (a) 4x8 | vs CSA 4x8 |', '|---|---|---:|---:|---:|---:|---:|---:|---:|']
    for kind in s['fwd']:
        f = fp[f'{kind}/uniform']
        for rate, rv, pw in (('forwarded', f['rate_model'], f['per_pe_mW_forwarded']),
                             ('a_bits', f['a_bits_rate_measured'], f['per_pe_mW_a_bits_rate'])):
            r4, r8 = sx[(kind, 'routed', rate, '4x4')], sx[(kind, 'routed', rate, '4x8')]
            L.append(f"| {kind} | {'own (model)' if rate == 'forwarded' else 'a_bits (SAIF)'} {rv:.3f} | {pw:.3f} | "
                     f"{f['moved_mW']:.3f} | {r4['uniform_pJ_MAC']:.4f} | {r8['uniform_pJ_MAC']:.4f} | "
                     f"{pct(r4['uniform_pJ_MAC'], ra['4x4']['uniform_pJ_MAC'])} | "
                     f"{pct(r8['uniform_pJ_MAC'], ra['4x8']['uniform_pJ_MAC'])} | "
                     f"{r8['uniform_pJ_MAC'] / ref['4x8']['uniform_pJ_MAC']:.2f}x |")
    L.append('')
    w = s['wires']
    L.append(f"- RG (b) forwarding: {s['fwd']['thr']['bits']:,} thr flops ({s['params']['THR_W']} b x {w['a_bits']:,} "
             f"positions) or {s['fwd']['idx']['bits']:,} idx flops per PE at {s['flop_um2_per_bit_synth']:.3f} um2/bit "
             f"(synthesized a_bits_pipe) = {s['fwd']['thr']['flop_um2']:,.0f} / {s['fwd']['idx']['flop_um2']:,.0f} um2.")
    ft = fp['thr/uniform']
    L.append(f"- a_bits_pipe (routed bootstrap, uniform): {ft['abp_mW']:.3f} mW for {w['a_bits']:,} bits, of which "
             f"{ft['abp_switching_mW']:.3f} mW switching. Charging the {s['fwd']['thr']['bits']:,} thr flops at the thr "
             f"rate instead of the a_bits rate adds {ft['per_pe_mW_forwarded'] - ft['per_pe_mW_a_bits_rate']:+.2f} mW per PE "
             f"({1e3 * (ft['per_pe_mW_forwarded'] - ft['per_pe_mW_a_bits_rate']) / s['fwd']['thr']['bits']:.2f} uW per bit).")
    L.append(f"- West-east boundary signals per PE: {w['today']:,} today ({w['a_bits']:,} A bits + {w['a_signs']} signs + "
             f"{w['acc_chain']} accumulator drain chain) -> {w['today'] + w['thr']:,} with thr. Horizontal tracks "
             f"({', '.join(f'{k2} {v} um' for k2, v in w['h_layers'].items())}) across the RG die height "
             f"{w['rg_pinned_die']['height_um']:.0f} um: {w['rg_pinned_die']['h_tracks']:,.0f} "
             f"({100 * w['rg_pinned_die']['frac_today']:.0f}% -> {100 * w['rg_pinned_die']['frac_thr']:.0f}%); across the CSA "
             f"die height {w['csa_die']['height_um']:.0f} um: {w['csa_die']['h_tracks']:,.0f} "
             f"({100 * w['csa_die']['frac_today']:.0f}% -> {100 * w['csa_die']['frac_thr']:.0f}%).")
    L.append('')

    # ------------------------------------------------------------------ RG amortization
    fw = s['rg_forwarding']['thr/routed']
    L.append(END)
    L += ['### RG per-PE area in a grid: what amortizes from 4x4 to 4x8 (um2 per PE; pinned u_pe, routed bootstrap split)', '',
          begin('rg_amort'),
          '| per PE | CSA 4x4 | CSA 4x8 | RG (a) 4x4 | RG (a) 4x8 | RG (b) thr 4x4 | RG (b) thr 4x8 |', '|---|---:|---:|---:|---:|---:|---:|']
    keys = [('CSA', 'CSA'), ('RG (a)', RG_A), ('RG (b)', B_THR)]
    lim = {}
    for nm, dn in keys:
        r8 = g[(dn, '4x8')]
        lim[nm] = r8['per_pe_u_pe'] + r8['per_pe_w_share']
    rb = D['rg_bootstrap']['area']

    def cells(fn):
        out = []
        for _, dn in keys:
            for gr in ('4x4', '4x8'):
                out.append(fn(g[(dn, gr)], dn, gr))
        return ' | '.join(out)
    isb = lambda dn: dn == B_THR
    L.append('| PE core as routed (u_pe) | ' + cells(lambda r, dn, gr: f"{(D['csa'] if dn == 'CSA' else D['rg_pinned'])['area']['u_pe']:,.0f}") + ' |')
    L.append('| - generators moved to the A edge | ' + cells(lambda r, dn, gr: f"-{fw['move_um2']:,.0f}" if isb(dn) else '-') + ' |')
    L.append('| + forwarded thr flops | ' + cells(lambda r, dn, gr: f"+{fw['flop_um2']:,.0f}" if isb(dn) else '-') + ' |')
    L.append('| + generator share (G / P_C) | ' + cells(lambda r, dn, gr: f"+{fw['move_um2'] / r['P_C']:,.0f}" if isb(dn) else '-') + ' |')
    L.append('| + A edge share (A / P_C) | ' + cells(lambda r, dn, gr: f"+{r['per_pe_a_share'] - (fw['move_um2'] / r['P_C'] if isb(dn) else 0):,.0f}") + ' |')
    L.append('| + W edge share (W / P_R) | ' + cells(lambda r, dn, gr: f"+{r['per_pe_w_share']:,.0f}") + ' |')
    L.append('| + generator set / n | ' + cells(lambda r, dn, gr: f"+{r['per_pe_bank']:,.0f}") + ' |')
    L.append('| **= per PE** | ' + cells(lambda r, dn, gr: f"**{r['per_pe_um2']:,.0f}**") + ' |')
    L.append('| never amortizes (RG): per-tile comparators / tiles, bootstrap split | ' +
             cells(lambda r, dn, gr: '-' if dn == 'CSA' else f"{rb['w_cmp_tile']:,.0f} / {rb['tiles']:,.0f}") + ' |')
    L.append('| GMAC/s/mm2 | ' + cells(lambda r, dn, gr: f"{r['gmacs_mm2']:.1f}") + ' |')
    L.append('| pJ/MAC uniform | ' + cells(lambda r, dn, gr: f"{r['uniform_pJ_MAC']:.4f}") + ' |')
    L.append('')
    L.append('Limit of an infinitely wide grid (P_R = 4, P_C -> inf: A edge and row generator shares -> 0), per PE: ' +
             ', '.join(f"{nm} {v:,.0f} um2 = {gm / (v * 1e-6):.1f} GMAC/s/mm2" for nm, v in lim.items()) + '.')
    L.append('')

    # ------------------------------------------------------------------ derived figures
    aff_u, aff_l = D['af_floating']['power']['uniform'], D['af_floating']['power']['ladder']
    rgu, rgm = D['rg_bootstrap']['power']['uniform'], D['rg_bootstrap']['power']['rowmix']
    ar = act['rg_bootstrap/uniform']
    rb4, rb8 = g[(B_THR, '4x4')], g[(B_THR, '4x8')]
    ra4, ra8 = g[(RG_A, '4x4')], g[(RG_A, '4x8')]
    gx = {(r['design'], r['basis'], r['grid']): r for r in grid_rows}
    afa, csaa = D['af_pinned']['area'], D['csa']['area']
    sgl = {r['label']: r for r in single_rows}
    L.append(END)
    L += ['### Derived figures quoted in the doc', '', begin('derived')]
    L.append(f"- AF pinned (qualified) vs CSA, single PE: area {pct(afa['total'], csaa['total'])} "
             f"({afa['total'] / csaa['total']:.3f}x), power uniform {pct(afu['total'], cp['total'])} "
             f"({afu['total'] / cp['total']:.3f}x), pJ/MAC {pct(pm(afu), pm(cp))} ({pm(afu) / pm(cp):.3f}x), GMAC/s/mm2 "
             f"{pct(sgl['AF pinned']['gmacs_mm2_1pe'], sgl['CSA pinned']['gmacs_mm2_1pe'])}.")
    rpa, rpc = D['af_pinned']['repair'], D['csa']['repair']
    L.append(f"- Post-fill repair: AF pinned {rpa['fillers_pass2']:,} second-pass fillers, {rpa['after_ipo']:,} router markers for "
             f"{rpa['routable_nets']:,} routable nets ({rpa['markers_per_net']:.3f}/net), {rpa['sr_iterations']} search-and-repair "
             f"iterations, {rpa['strong_final']:,} left; post-fill hook {rpa['postfill_iterations']} iterations, "
             f"{rpa['postfill_after_via_swap']} markers after the via swap, flow verify_drc {rpa['flow_verify_drc']}; targeted repair "
             f"{rpa['targeted']['geometry']} geometry + {rpa['targeted']['antenna_pins']} antenna pins. CSA pinned: "
             f"{rpc['fillers_pass2']:,} second-pass fillers, {rpc['markers_per_net']:.3f}/net, {rpc['sr_iterations']} iterations, "
             f"targeted repair {rpc['targeted']['geometry']} + {rpc['targeted']['antenna_pins']}. AF floating "
             f"{D['af_floating']['repair']['markers_per_net']:.3f}/net, {D['af_floating']['repair']['sr_iterations']} iterations.")
    L.append(f"- AF qualified vs superseded unqualified pinned: uniform {afu['total']:.3f} vs {u['uniform_power_mW']:.3f} mW "
             f"({pct(afu['total'], u['uniform_power_mW'])}), ladder {afl['total']:.3f} vs {u['ladder_power_mW']:.3f} mW "
             f"({pct(afl['total'], u['ladder_power_mW'])}); setup {D['af_pinned']['checks']['setup_wns_ns']:+.3f} vs "
             f"{u['setup_wns_ns']:+.3f} ns; skew {D['af_pinned']['basin']['skew_ps']:.1f} vs {u['skew_ps']:.1f} ps.")
    a4, a8, a84 = g[('AF', '4x4')], g[('AF', '4x8')], gx[('AF', AF_PIN_BASIS, '8x4')]
    L.append(f"- AF pinned vs CSA by composite form: area / GMAC/s/mm2 4x4 {pct(a4['area_um2'], ref['4x4']['area_um2'])} / "
             f"{pct(a4['gmacs_mm2'], ref['4x4']['gmacs_mm2'])}; 4x8 split {pct(a8['area_um2'], ref['4x8']['area_um2'])} / "
             f"{pct(a8['gmacs_mm2'], ref['4x8']['gmacs_mm2'])} ({a8['gmacs_mm2']:.1f} vs {ref['4x8']['gmacs_mm2']:.1f}); "
             f"4x8 symmetric {pct(a8['area_classic_um2'], ref['4x8']['area_classic_um2'])} / "
             f"{pct(a8['gmacs_mm2_classic'], ref['4x8']['gmacs_mm2_classic'])} ({a8['gmacs_mm2_classic']:.1f} vs "
             f"{ref['4x8']['gmacs_mm2_classic']:.1f}); 8x4 (orientation check) {pct(a84['area_um2'], ref['8x4']['area_um2'])} / "
             f"{pct(a84['gmacs_mm2'], ref['8x4']['gmacs_mm2'])} ({a84['area_um2']:,.0f} um2, {a84['gmacs_mm2']:.1f} vs "
             f"{ref['8x4']['gmacs_mm2']:.1f}). Energy 4x4 / 4x8 split / 4x8 symmetric / 8x4: "
             f"{pct(a4['uniform_pJ_MAC'], ref['4x4']['uniform_pJ_MAC'])} / {pct(a8['uniform_pJ_MAC'], ref['4x8']['uniform_pJ_MAC'])} / "
             f"{pct(a8['uniform_pJ_MAC_classic'], ref['4x8']['uniform_pJ_MAC_classic'])} / "
             f"{pct(a84['uniform_pJ_MAC'], ref['8x4']['uniform_pJ_MAC'])}; ladder held {tl['fill']['c_full']} cycles (grid "
             f"block length) 4x4 / 4x8 vs own uniform {pct(a4['ladder_hold8_pJ_MAC'], a4['uniform_pJ_MAC'])} / "
             f"{pct(a8['ladder_hold8_pJ_MAC'], a8['uniform_pJ_MAC'])}.")
    L.append(f"- AF floating (collapsed) composites, reference: 4x4 {gf['4x4']['area_um2']:,.1f} um2, 4x8 split "
             f"{gf['4x8']['area_um2']:,.1f} / symmetric {gf['4x8']['area_classic_um2']:,.1f} um2 "
             f"({gf['4x8']['gmacs_mm2']:.1f} / {gf['4x8']['gmacs_mm2_classic']:.1f} GMAC/s/mm2); energy 4x8 "
             f"{pct(gf['4x8']['uniform_pJ_MAC'], ref['4x8']['uniform_pJ_MAC'])} vs CSA.")
    L.append(f"- AF pinned vs CSA edges: A edge {afa['a_edge']:,.1f} vs {csaa['a_edge']:,.1f} ({afa['a_edge'] - csaa['a_edge']:+,.0f}; "
             f"{afa['a_edge'] / afa['w_edge']:.2f}x AF's W edge {afa['w_edge']:,.1f}); W edge {pct(afa['w_edge'], csaa['w_edge'])} "
             f"({afa['w_edge'] - csaa['w_edge']:+,.0f}); W comparators {afa['w_logic']:,.1f} vs {csaa['w_logic']:,.1f}; "
             f"stream generators {afa['bank'] - csaa['bank']:+,.0f}; kA encoders {afa['ka_enc']:,.1f} um2 / "
             f"{afu['ka_enc']:.3f} mW; CSA A/W {csaa['a_edge'] / csaa['w_edge']:.3f}; PE core {afa['u_pe'] - csaa['u_pe']:+,.0f} um2.")
    L.append(f"- u_pe module / instances: CSA `{sgl['CSA pinned']['u_pe_module']}` {sgl['CSA pinned']['u_pe_instances']:,}; "
             f"AF pinned `{sgl['AF pinned']['u_pe_module']}` {sgl['AF pinned']['u_pe_instances']:,}; AF floating "
             f"{sgl['AF floating']['u_pe_instances']:,}.")
    af_parts = [('tiles', afu['tiles'] - cp['tiles']), ('PE pipes and glue', afu['pe_pipes_glue'] - cp['pe_pipes_glue']),
                ('PE clock buffers', afu['pe_clk_buf'] - cp['pe_clk_buf']), ('stream generators', afu['bank'] - cp['bank']),
                ('W edge', afu['w_edge'] - cp['w_edge']), ('A edge', afu['a_edge'] - cp['a_edge']),
                ('top-level rest', afu['top_rest'] - cp['top_rest']), ('edge clock buffers + leftovers', afu['shared'] - cp['shared'])]
    af_tot = afu['total'] - cp['total']
    af_resid = af_tot - sum(v for _, v in af_parts)      # CSA u_pe vs its tiles + pipes + clock (class rounding)
    L.append(f"- AF pinned - CSA power, uniform, {af_tot:+.3f} mW = " + ', '.join(f'{n} {v:+.3f}' for n, v in af_parts)
             + f" (sum {sum(v for _, v in af_parts):+.3f}; residual {af_resid:+.4f} mW); PE core "
             f"{afu['u_pe'] - cp['u_pe']:+.3f} mW.")
    rg_parts = [('tiles', rgu['tiles'] - cp['tiles']), ('W index generators', rgu['w_gen']),
                ('per-tile W comparators', rgu['w_cmp_tile']),
                ('PE pipes/glue/clock', rgu['pipes'] + rgu['core_other'] - cp['pe_pipes_glue'] - cp['pe_clk_buf']),
                ('A edge', rgu['a_edge'] - cp['a_edge']), ('W edge', rgu['w_edge'] - cp['w_edge']),
                ('edge clock buffers + leftovers', rgu['shared'] - cp['shared']), ('stream generators', rgu['bank'] - cp['bank']),
                ('top-level rest', rgu['top_rest'] - cp['top_rest'])]
    rg_tot = rgu['total'] - cp['total']
    eb = sum(v for n, v in rg_parts[4:])
    L.append(f"- RG bootstrap - CSA power, uniform, {rg_tot:+.3f} mW = " + ', '.join(f'{n} {v:+.3f}' for n, v in rg_parts)
             + f" (edges, banks and top rest together {eb:+.3f}; sum {sum(v for _, v in rg_parts):+.3f}; residual "
             f"{rg_tot - sum(v for _, v in rg_parts):+.4f} mW).")
    L.append(f"- AF floating (collapsed) vs AF pinned (grid), same RTL and stimulus: power uniform "
             f"{pct(aff_u['total'], afu['total'])}, ladder {pct(aff_l['total'], afl['total'])}; tiles "
             f"{pct(aff_u['tiles'], afu['tiles'])}.")
    L.append(f"- AF pinned ladder vs uniform: pJ/MAC {pct(pm(afl), pm(afu))} = clocks per block "
             f"{pct(afl['window'], afu['window'])} x power {pct(afl['total'], afu['total'])}; tiles "
             f"{afu['tiles']:.3f} -> {afl['tiles']:.3f} mW; mean kA {afu['mean_kA']:.1f} -> {afl['mean_kA']:.1f}, "
             f"A-one density {afu['a_density']:.3f} -> {afl['a_density']:.3f}.")
    afh, afr = D['af_pinned']['power']['ladder_hold8'], D['af_pinned']['power']['ladder_rowmax']
    L.append(f"- AF pinned ladder vs CSA ladder-equivalent (same operands, same {cl_['window']:,}-clock window), single PE: pJ/MAC "
             f"{pm(afl):.4f} vs {pm(cl_):.4f} ({pct(pm(afl), pm(cl_))}); vs CSA fixed T = {T_STREAM} {pct(pm(afl), pm(cp))}. "
             f"CSA ladder-equivalent vs CSA T = {T_STREAM}: {pct(pm(cl_), pm(cp))}. AF rows at block max (same block lengths): "
             f"{pm(afr):.4f} ({pct(pm(afr), pm(cl_))} vs CSA ladder-equivalent; AF ladder {pct(pm(afl), pm(afr))} below it).")
    L.append(f"- Grid ladder (every block {tl['fill']['c_full']} cycles): AF ladder held {tl['fill']['c_full']} cycles, single "
             f"PE {pm(afh):.4f} pJ/MAC ({pct(pm(afh), pm(afl))} vs the unheld ladder, {pct(pm(afh), pm(cp))} vs CSA T = "
             f"{T_STREAM}); grid composite 4x4 {a4['ladder_hold8_pJ_MAC']:.4f} / 4x8 {a8['ladder_hold8_pJ_MAC']:.4f} vs CSA "
             f"T = {T_STREAM} {ref['4x4']['uniform_pJ_MAC']:.4f} / {ref['4x8']['uniform_pJ_MAC']:.4f}: "
             f"{pct(a4['ladder_hold8_pJ_MAC'], ref['4x4']['uniform_pJ_MAC'])} / "
             f"{pct(a8['ladder_hold8_pJ_MAC'], ref['4x8']['uniform_pJ_MAC'])}. Share of the ladder's chunks whose grid block "
             f"is shorter than {tl['fill']['c_full']} cycles: " + ', '.join(
                 f"{g} {100 * v:.2f}%" for g, v in tl['fill']['grid_short'].items()) + f" (single PE "
             f"{100 * tl['fill']['pe_short']:.1f}%).")
    L.append(f"- RG rowmix vs AF ladder (same stimulus, same {rgm['window']:,}-clock window): pJ/MAC {pm(rgm):.4f} = "
             f"{pm(rgm) / pm(afl):.2f}x AF pinned (grid basin, qualified), {pm(rgm) / pm(aff_l):.2f}x AF floating (collapsed); "
             f"RG rowgrouped {pm(D['rg_bootstrap']['power']['rowgrouped']):.4f}.")
    L.append(f"- RG tiles vs CSA tiles, uniform: {rgu['tiles'] / cp['tiles']:.2f}x; RG tile w_bits toggles per clock: measured "
             f"{ar['tile_w_bits_per_clock']:.3f} = {ar['tile_w_bits_per_clock'] / tm['uniform']['rg_w']:.2f}x the glitch-free "
             f"model {tm['uniform']['rg_w']:.3f}; worst w_bits net {ar['tile_w_bits_max_TC'] / ar['window_clocks']:.2f} toggles "
             f"per clock; RG a_bits {ar['tile_a_bits_per_clock']:.3f} vs CSA {act['csa/uniform']['tile_a_bits_per_clock']:.3f}.")
    L.append(f"- AF tile inputs vs CSA, uniform: a_bits {act['af_pinned/uniform']['tile_a_bits_per_clock']:.3f} vs "
             f"{act['csa/uniform']['tile_a_bits_per_clock']:.3f}, w_bits {act['af_pinned/uniform']['tile_w_bits_per_clock']:.3f} vs "
             f"{act['csa/uniform']['tile_w_bits_per_clock']:.3f} per clock; operand ports "
             f"{pct(act['af_pinned/uniform']['port_operand_TC'], act['csa/uniform']['port_operand_TC'])}.")
    rgpa = D['rg_pinned']['area']
    L.append(f"- RG pinned vs CSA area: single PE {rgpa['total'] / csaa['total']:.2f}x ({rgpa['total'] - csaa['total']:+,.0f} um2; "
             f"PE-local {rgpa['pe_local']:,.0f} vs {csaa['pe_local']:,.0f}); per PE in a grid 4x4 "
             f"{ra4['per_pe_um2']:,.0f} / {ref['4x4']['per_pe_um2']:,.0f} = {ra4['per_pe_um2'] / ref['4x4']['per_pe_um2']:.2f}x, "
             f"4x8 {ra8['per_pe_um2']:,.0f} / {ref['4x8']['per_pe_um2']:,.0f} = {ra8['per_pe_um2'] / ref['4x8']['per_pe_um2']:.2f}x.")
    L.append(f"- RG (a) grid vs CSA: GMAC/s/mm2 4x4 {pct(ra4['gmacs_mm2'], ref['4x4']['gmacs_mm2'])}, 4x8 "
             f"{pct(ra8['gmacs_mm2'], ref['4x8']['gmacs_mm2'])}; energy 4x4 {ra4['uniform_pJ_MAC'] / ref['4x4']['uniform_pJ_MAC']:.2f}x, "
             f"4x8 {ra8['uniform_pJ_MAC'] / ref['4x8']['uniform_pJ_MAC']:.2f}x. RG (b) thr: GMAC/s/mm2 4x4 "
             f"{pct(rb4['gmacs_mm2'], ref['4x4']['gmacs_mm2'])}, 4x8 {pct(rb8['gmacs_mm2'], ref['4x8']['gmacs_mm2'])}; energy 4x4 "
             f"{rb4['uniform_pJ_MAC'] / ref['4x4']['uniform_pJ_MAC']:.2f}x, 4x8 {rb8['uniform_pJ_MAC'] / ref['4x8']['uniform_pJ_MAC']:.2f}x.")
    L.append(f"- RG (b) thr vs RG (a), per PE: 4x4 {pct(rb4['per_pe_um2'], ra4['per_pe_um2'])}, 4x8 "
             f"{pct(rb8['per_pe_um2'], ra8['per_pe_um2'])}; RG (b) 4x4 -> 4x8: per PE {pct(rb8['per_pe_um2'], rb4['per_pe_um2'])} "
             f"({rb4['per_pe_um2']:,.0f} -> {rb8['per_pe_um2']:,.0f} um2), generator share {fw['move_um2'] / 4:,.0f} -> "
             f"{fw['move_um2'] / 8:,.0f} um2, GMAC/s/mm2 {pct(rb8['gmacs_mm2'], rb4['gmacs_mm2'])}, energy "
             f"{pct(rb8['uniform_pJ_MAC'], rb4['uniform_pJ_MAC'])}; RG (a) 4x4 -> 4x8 per PE {pct(ra8['per_pe_um2'], ra4['per_pe_um2'])}; "
             f"wide-grid limit RG (b) / CSA {lim['CSA'] / lim['RG (b)']:.2f}x GMAC/s/mm2.")
    sb4, sb8 = sx[('thr', 'routed', 'a_bits', '4x4')], sx[('thr', 'routed', 'a_bits', '4x8')]
    sc8 = sx[('thr', 'scaled', 'forwarded', '4x8')]
    L.append(f"- RG (b) grid energy vs RG (a), thr flops at the thr rate ({tm['uniform']['rg_thr']:.3f}/clock): 4x4 "
             f"{pct(rb4['uniform_pJ_MAC'], ra4['uniform_pJ_MAC'])}, 4x8 {pct(rb8['uniform_pJ_MAC'], ra8['uniform_pJ_MAC'])}. "
             f"At the a_bits rate ({ar['tile_a_bits_per_clock']:.3f}/clock): 4x4 {pct(sb4['uniform_pJ_MAC'], ra4['uniform_pJ_MAC'])}, "
             f"4x8 {pct(sb8['uniform_pJ_MAC'], ra8['uniform_pJ_MAC'])}, vs CSA 4x8 "
             f"{sb8['uniform_pJ_MAC'] / ref['4x8']['uniform_pJ_MAC']:.2f}x.")
    L.append(f"- RG (b) with the generator area scaled to the pinned u_pe ({s['rg_forwarding']['thr/scaled']['move_um2']:,.0f} um2): "
             f"4x8 per PE {sc8['per_pe_um2']:,.0f} um2, {sc8['gmacs_mm2']:.1f} GMAC/s/mm2 (vs {rb8['gmacs_mm2']:.1f}); "
             f"thr generator-area bases span {min(sx[('thr', ab, 'forwarded', '4x8')]['gmacs_mm2'] for ab in ('routed', 'scaled', 'synth')):.1f}"
             f" to {max(sx[('thr', ab, 'forwarded', '4x8')]['gmacs_mm2'] for ab in ('routed', 'scaled', 'synth')):.1f} "
             f"GMAC/s/mm2 at 4x8; idx (routed) vs RG (a) 4x8: GMAC/s/mm2 "
             f"{pct(sx[('idx', 'routed', 'forwarded', '4x8')]['gmacs_mm2'], ra8['gmacs_mm2'])}, energy "
             f"{pct(sx[('idx', 'routed', 'forwarded', '4x8')]['uniform_pJ_MAC'], ra8['uniform_pJ_MAC'])}.")
    L.append('- RG tile w_bits SAIF / glitch-free model: ' + ', '.join(
        f"{wl} {act[f'rg_bootstrap/{wl}']['tile_w_bits_per_clock']:.3f} / {tm[wl]['rg_w']:.3f} = "
        f"{act[f'rg_bootstrap/{wl}']['tile_w_bits_per_clock'] / tm[wl]['rg_w']:.2f}x" for wl in RG_WL)
        + f"; forwarded-signal rates vs RG a_bits (uniform): thr {tm['uniform']['rg_thr'] / ar['tile_a_bits_per_clock']:.2f}x, "
          f"idx {tm['uniform']['rg_idx'] / ar['tile_a_bits_per_clock']:.2f}x.")
    bp = D['rg_pinned']['basin']
    L.append(f"- RG pinned basin: corr(x, column) {bp['corr_x_col']:.3f}, corr(y, -row) {bp['corr_y_negrow']:.3f}, tile pitch "
             f"{bp['d_col_um']:.1f} um between columns vs {bp['d_row_um']:.1f} um between rows, skew metric {bp['skew_ps']:.1f} ps "
             f"(uncalibrated). AF floating: corr {D['af_floating']['basin']['corr_x_col']:.3f} / "
             f"{D['af_floating']['basin']['corr_y_negrow']:.3f}, row pitch {D['af_floating']['basin']['d_row_um']:.1f} um.")
    rr = {r['run']: r for r in s['rg_timing_runs']}
    L.append('- RG timing-fix runs: ' + '; '.join(
        f"{r['run']} syn {r['syn_slack_ns']:+.2f} ns / {r['syn_area_um2']:,.1f} um2 ({r['syn_area_um2'] - rr['cbsg_rg_20261005']['syn_area_um2']:+,.1f} "
        f"vs original), bootstrap " + (f"{r['setup_wns_ns']:+.3f} / {r['hold_wns_ns']:+.3f} ns, {r['area_um2']:,.1f} um2, strict GL "
                                        f"{r.get('gl_strict', '-')}" if 'route' in r else r['bootstrap_apr'])
        for r in s['rg_timing_runs']) + '.')
    L.append('')
    L.append(END)
    L += tsweep_tables(s['tsweep'])
    return split_blocks(L)


def tsweep_tables(t):
    """Markdown blocks of the stream-length sweeps (tsweep: both designs per T and the AF-only lengths; tsweep_reading:
    what the table shows; tsweep_ladder: the per-row ladder on one PE and on a grid; tsweep_classes: AF - CSA by class
    as T falls; tsweep_permac), then two tables.md-only sections: every point in absolute terms, and the cross-check
    against the earlier floating-route CSA sweep.  Every claim worded here from the data is either computed or asserted."""
    m, nT = t['m'], T_STREAM
    pts = t['points']
    cyc = lambda r: f"{r['cycles']:.0f}" if float(r['cycles']).is_integer() else f"{r['cycles']:.2f}"
    gvs = lambda a, c: f"{pct(a['grid_4x4_pJ_MAC'], c['grid_4x4_pJ_MAC'])} / {pct(a['grid_4x8_pJ_MAC'], c['grid_4x8_pJ_MAC'])}"
    lad = t['ladder']
    afl, csl, csf, aff = lad['af'], lad['csa'], lad['csa_full'], lad['af_full']
    afr, afh = lad['af_rowmax'], lad['af_hold8']
    fl_ = lad['fill']
    cf = fl_['c_full']
    L = ['### Energy vs stream length: both finished pinned routes, every single-PE point measured', '', begin('tsweep'),
         '| T or L | cycles per block | CSA mW | CSA pJ/MAC | AF mW | AF pJ/MAC | AF vs CSA, 1 PE (measured) | '
         'AF vs CSA, 4x4 / 4x8 grid composite |',
         '|---|---:|---:|---:|---:|---:|---:|---:|']
    rows = sorted([(c['length'], 0, c) for c in t['common']] + [(c['length'], 1, c) for c in t['af_only']], key=lambda x: x[:2])
    for n, only, c in rows:
        a = c['af']
        if not only:
            k = c['csa']
            L.append(f"| {n} | {cyc(a)} | {k['power_mW']:.3f} | {k['pJ_MAC']:.4f} | {a['power_mW']:.3f} | {a['pJ_MAC']:.4f} | "
                     f"{pct(a['pJ_MAC'], k['pJ_MAC'])} | {gvs(a, k)} |")
        else:
            k = c['csa_same']
            L.append(f"| {n} (AF only) | {cyc(a)} | - | - | {a['power_mW']:.3f} | {a['pJ_MAC']:.4f} | "
                     f"{pct(a['pJ_MAC'], k['pJ_MAC'])} vs CSA T = {k['length']} | {gvs(a, k)} |")
    L.append('')
    blocks = {r['blocks'] for r in pts}
    assert len(blocks) == 1
    nb = blocks.pop()
    mb = round(afl['pJ_block'] / afl['pJ_MAC'])
    sdfw = {json.dumps(r['sdf_warnings'], sort_keys=True) for r in pts}
    assert len(sdfw) == 1
    sdfw = ', '.join(f'{k} x{v}' for k, v in json.loads(sdfw.pop()).items())
    port = sorted({f"{100 * (c['af']['port_operand_TC'] / c['csa']['port_operand_TC'] - 1):+.2f}%" for c in t['common']})
    lo_, nx_ = sorted(t['common'], key=lambda c: c['length'])[:2]
    lad_runs = [afl, afr, afh, csl]
    L += [f"- Each point is {nb} blocks of {mb} kernel MACs (N_H x N_W x K) at {F_GHZ * 1e3:.0f} MHz; the window is {nb} x "
          f"cycles per block clocks, the drain is excluded, pJ/MAC = P x window x {T_NS} ns / ({nb} x {mb}). The CSA's T is a "
          f"whole number of {m}-position cycles; AF's L can be any length, and a block runs ceil(L / {m}) cycles. The AF-only "
          f"lengths are compared with the CSA point that runs the same cycles per block.",
          f"- The 1 PE column compares two measured runs. The grid columns are composites, not runs: P_R x P_C x the "
          f"point's PE core + one A edge per PE row + one W edge per PE column + one stream-generator set, from its "
          f"single-PE class split (the top-level rest, skew and drain cycles are left out). A grid runs one T for every PE, "
          f"so every uniform point composes.",
          f"- All uniform points drive the same operands (asserted on the GL traces: each design's uniform points equal its "
          f"T = {nT} point, and AF's magnitudes are round(|q| x 128 / 127) of the CSA's |q| with the same signs). "
          f"Operand-port toggles in the window, AF vs CSA: {' to '.join(port)} at every T. At T = {lo_['length']} both "
          f"benches load one block fewer inside the window (operand-port toggles vs T = {nx_['length']}: CSA "
          f"{100 * (lo_['csa']['port_operand_TC'] / nx_['csa']['port_operand_TC'] - 1):+.2f}%, AF "
          f"{100 * (lo_['af']['port_operand_TC'] / nx_['af']['port_operand_TC'] - 1):+.2f}%), so the two T = {lo_['length']} "
          f"points stay comparable with each other. The {len(lad_runs)} ladder runs of section 3.1 share their own operand "
          f"set, asserted equal among them: the same statistics, shifted by the bench's row-length draws (operand-port "
          f"toggles {min(r['port_operand_TC'] for r in lad_runs):,} to {max(r['port_operand_TC'] for r in lad_runs):,} "
          f"against {csf['port_operand_TC']:,} / {aff['port_operand_TC']:,} for CSA / AF T = {nT}).",
          f"- Gate (asserted): CSA T = {nT} reproduces the qualified baseline exactly ({csf['power_mW']:.5f} mW: power.rpt total, "
          f"every PT class row, SAIF identical apart from its date, trace identical), and so does the bench-copy replay "
          f"({lad['repro']['power_mW']:.5f} mW). AF L = {nT} ({aff['power_mW']:.5f} mW) and the ladder ({afl['power_mW']:.5f} mW) "
          f"reproduce the AF pinned measurement (total and every class row; AF gate: SAIF identical apart from its date, "
          f"traces identical).",
          f"- All {len(pts)} runs: strict max-SDF GL audit PASS with 0 approvals and 0 post-reset violations; SDF warnings only "
          f"{sdfw}; worst clock-gate CK->ECK {max(r['worst_icg_ns'] for r in pts):.3f} ns; drains bit-exact (CSA vs the "
          f"cosim_streaming cycle reference, its per-block-cycles copy for the ladder and replay; AF vs cbsg_ref); "
          f"routed-SDF clock audit and PT coverage PASS. The AF checker's negative controls "
          f"(each L relabelled L - 1, a drain off by one LSB) fail at all {len(t['af_negctl'])} lengths; the CSA bench copy's "
          f"RTL checks: {t['rtl_checks']}; the AF ladder-variant bench's RTL checks: {t['lv_rtl_checks']} "
          f"({t['lv_negctl']} negative controls fail as required).", '', END]

    # ---------------------------------------------------------------- reading the table (data claims, computed)
    one = {c['length']: 100 * (c['af']['pJ_MAC'] / c['csa']['pJ_MAC'] - 1) for c in t['common']}
    g8 = {c['length']: 100 * (c['af']['grid_4x8_pJ_MAC'] / c['csa']['grid_4x8_pJ_MAC'] - 1) for c in t['common']}
    best, worst1 = min(one, key=one.get), max(one, key=one.get)
    rev = sorted(n for n in g8 if g8[n] > 0)
    cm = {c['length']: c for c in t['common']}
    by_c = defaultdict(list)
    for r in pts:
        if r['design'] == 'af' and r['tag'] not in LADDER_RUNS:
            by_c[int(r['cycles'])].append(r)
    groups = {c: sorted(v, key=lambda r: r['length']) for c, v in by_c.items() if len(v) > 1}
    spread = {c: (v[0]['length'], v[-1]['length'], 100 * (max(r['pJ_block'] for r in v) / min(r['pJ_block'] for r in v) - 1))
              for c, v in groups.items()}
    fu = lad['fill_uniform']
    odd = sorted(n for n in fu if n % m)
    L += ['### Reading the energy-vs-length table', '', begin('tsweep_reading'),
          f"- **On one PE, AF uses less energy per MAC than the CSA at "
          + ('every T' if all(v < 0 for v in one.values()) else 'T = ' + ', '.join(str(n) for n in sorted(one) if one[n] < 0))
          + f", but the margin is not monotonic** (both runs measured at every T). It is largest at T = {best} "
          f"({one[best]:+.1f}%) and smallest at T = {worst1} ({one[worst1]:+.1f}%); section 3.2 explains why.",
          f"- **In the grid composites the margin is smaller at every T**, because the edges, where AF saves at every T, "
          f"are shared by a row or a column of PEs, so the PE core decides. "
          + (f"At T = {', '.join(str(n) for n in rev)} the composite puts AF above the CSA "
             f"({', '.join(gvs(cm[n]['af'], cm[n]['csa']) for n in rev)} at 4x4 / 4x8). " if rev else '')
          + 'These are modelled grid figures built from the single-PE runs, not grid runs.',
          f"- **AF lengths that are not a multiple of {m}** run as many cycles as the next multiple of {m}. With a uniform L, "
          f"the cycle count sets the energy: within one cycle count the energy per block spans "
          + ', '.join(f"{sp:.1f}% (L = {a}-{b}, {c} cycles)" for c, (a, b, sp) in sorted(spread.items()))
          + f", because those lengths fill {100 * min(fu[n] for n in odd):.0f}-100% of their block. A row that fills less of "
          f"its block costs less (section 3.1). They are compared with the CSA at the same cycles.", '', END]
    # the reading above claims: the grid composites narrow the margin at every T, and within a cycle count L moves a
    # uniform point less than one more cycle per block does
    assert all(g8[n] > one[n] for n in one), 'a grid composite margin is not smaller than the 1 PE margin'
    step = {c['af']['cycles']: c['af']['pJ_block'] for c in t['common']}
    steps = [100 * (step[c + 1] / step[c] - 1) for c in sorted(step) if c + 1 in step]
    assert max(v[2] for v in spread.values()) < min(steps), 'uniform-L spread vs the per-cycle step'

    # ---------------------------------------------------------------- ladder: one PE (every row measured)
    hist = csl['hist']
    hs = ', '.join(f"{n} blocks x {c}" for c, n in sorted(hist.items()))
    rungs = '{' + ', '.join(str(x) for x in sorted({*ladder_lengths(afl)}, reverse=True)) + '}'
    L += ['### Per-row ladder: AF measured vs the CSA ladder-equivalent measured', '', begin('tsweep_ladder'),
          '**One PE** (each line is a measured run):', '',
          '| run | window clocks | cycles per block | mW | pJ per block | pJ/MAC | mean kA | AF ladder vs this |',
          '|---|---:|---:|---:|---:|---:|---:|---:|']
    for name, r in ((f'AF ladder (rows L in {rungs})', afl),
                    ("AF ladder, every row at its block's longest L (same operands, same block cycles)", afr),
                    ('CSA ladder-equivalent (same operands, same block cycles)', csl),
                    (f'CSA fixed T = {nT}', csf),
                    (f'AF ladder, every block held {cf} cycles (the grid block length)', afh),
                    (f'AF uniform L = {nT} (reference)', aff)):
        L.append(f"| {name} | {r['window']:,} | {cyc(r)} | {r['power_mW']:.3f} | {r['pJ_block']:.2f} | {r['pJ_MAC']:.4f} | "
                 f"{f1(r['mean_kA'])} | {'-' if r is afl else pct(afl['pJ_MAC'], r['pJ_MAC'])} |")
    L.append('')
    mix = lad['cycle_mix']
    tile = lambda r: r['cls_pJ_block']['tiles']
    L += [f"- CSA ladder-equivalent: the AF ladder's operands and signs, each block run for ceil(max row L / {m}) cycles "
          f"({hs} cycles), so its window equals AF's ({csl['window']:,} clocks). Asserted: the stimulus was built from the "
          f"AF ladder trace (sha256), and its block cycles and operands equal that trace's.",
          f"- Where the {pct(afl['pJ_block'], csl['pJ_block'])} comes from, both parts measured: AF with every row at its "
          f"block's longest L costs {afr['pJ_block']:.2f} pJ per block, {pct(afr['pJ_block'], csl['pJ_block'])} against the "
          f"CSA ladder-equivalent (the A-first design at the same block lengths). The AF ladder is a further "
          f"{pct(afl['pJ_block'], afr['pJ_block'])} below that, from its shorter rows.",
          f"- Cross-check: the uniform points weighted by this cycle mix give {mix['csa']:.2f} pJ per block for the CSA "
          f"(measured ladder-equivalent {csl['pJ_block']:.2f}, {100 * (csl['pJ_block'] / mix['csa'] - 1):+.2f}%) and "
          f"{mix['af']:.2f} for AF (measured with every row at its block's longest L {afr['pJ_block']:.2f}, "
          f"{100 * (afr['pJ_block'] / mix['af'] - 1):+.2f}%). The ladder runs drive a different operand draw from the "
          f"uniform points, so this also shows that the draw does not matter.",
          f"- Why the shorter rows save: a row's A stream has kA ones, about b x L / 128 (mean kA {afl['mean_kA']:.1f} "
          f"against {afr['mean_kA']:.1f} with every row at its block's longest L), and they come first in the block, so "
          f"fewer tile products see an A one. Tile energy per block: {tile(afl):.1f} pJ against {tile(afr):.1f} with every "
          f"row at its block's longest L ({pct(tile(afl), tile(afr))}; the uniform points' cycle mix: "
          f"{lad['cycle_mix_tiles']['af']:.1f}). The tile input "
          f"toggles hardly change (a_bits {afl['tile_a_per_clock']:.3f} per clock against {afr['tile_a_per_clock']:.3f}; "
          f"the uniform points' cycle mix: {lad['cycle_mix_a_toggles']['af']:.3f}), so the saving is in the products, not "
          f"in the inputs. The effect is large here because a ladder row fills on average {100 * fl_['mean']:.0f}% of its "
          f"block (down to {100 * fl_['min']:.0f}%: a {min(fl_['rungs'])}-row in a block of {cf} cycles), while a uniform-L "
          f"row fills {100 * min(lad['fill_uniform'][n] for n in lad['fill_uniform'] if n % m):.0f}-100% of its block.", '']
    assert abs(afl['tile_a_per_clock'] / afr['tile_a_per_clock'] - 1) < 0.1 and tile(afl) < 0.9 * tile(afr), \
        'the ladder text claims unchanged tile input toggles and a tile-energy saving'
    # ---------------------------------------------------------------- ladder: on a grid (composites of the held run)
    gs = fl_['grid_short']
    L += [f"**On a grid** (composites of measured single-PE runs): a grid with one stream generator runs one block length "
          f"for every PE, because each W edge feeds every PE row of its column. Its block is as long as the longest of all "
          f"its A rows: with the ladder drawn per row, {cf} cycles in all but {100 * gs['4x8']:.1f}% of the chunks of a "
          f"{GRIDS['4x8'][0]}-PE-row grid ({GRIDS['4x8'][0] * fl_['n_h']} rows; one PE alone: "
          f"{100 * fl_['pe_short']:.0f}% of chunks shorter). So the grid composite uses the AF ladder run with every block "
          f"held {cf} cycles (measured: the ladder's operands and row lengths, drain identical, since the held cycles add "
          f"zero), and the CSA's counterpart is T = {nT}.", '',
          f"| | AF ladder, blocks held {cf} cycles, pJ/MAC | CSA T = {nT}, pJ/MAC | AF vs CSA |", '|---|---:|---:|---:|',
          f"| 1 PE (measured) | {afh['pJ_MAC']:.4f} | {csf['pJ_MAC']:.4f} | {pct(afh['pJ_MAC'], csf['pJ_MAC'])} |"]
    for g in ('4x4', '4x8'):
        L.append(f"| {g} grid composite | {afh[f'grid_{g}_pJ_MAC']:.4f} | {csf[f'grid_{g}_pJ_MAC']:.4f} | "
                 f"{pct(afh[f'grid_{g}_pJ_MAC'], csf[f'grid_{g}_pJ_MAC'])} |")
    L += ['',
          f"- Holding every block for {cf} cycles costs AF {pct(afh['pJ_block'], afl['pJ_block'])} per block against the "
          f"unheld ladder ({afh['pJ_block']:.2f} against {afl['pJ_block']:.2f} pJ): the extra cycles clock the PE and the "
          f"edges but add no products. Against its own uniform L = {nT}, the held ladder is "
          f"{pct(afh['pJ_MAC'], aff['pJ_MAC'])} at 1 PE and "
          f"{pct(afh['grid_4x8_pJ_MAC'], aff['grid_4x8_pJ_MAC'])} in the 4x8 composite.",
          f"- The single-PE figures above ({pct(afl['pJ_MAC'], csl['pJ_MAC'])} against the CSA ladder-equivalent) give each "
          f"PE its own block length, which a grid cannot run, so they have no grid composite.", '', END]

    # ---------------------------------------------------------------- per class as T falls
    other = ('pe_clk_buf', 'shared', 'top_rest')
    L += ['### Where AF saves as T falls (AF - CSA, percentage points of the CSA energy per block)', '', begin('tsweep_classes'),
          '| T | CSA pJ per block | AF pJ per block | AF vs CSA | tiles | PE pipes + glue | A edge | W edge | stream generators | '
          'other | tile a_bits toggles per clock, AF / CSA | tile w_bits, AF / CSA |',
          '|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|']
    pp = lambda c, keys: 100 * sum(c['af']['cls_pJ_block'][k] - c['csa']['cls_pJ_block'][k] for k in keys) / c['csa']['pJ_block']
    for c in sorted(t['common'], key=lambda c: -c['length']):
        a, k = c['af'], c['csa']
        L.append(f"| {c['length']} | {k['pJ_block']:.2f} | {a['pJ_block']:.2f} | {pct(a['pJ_block'], k['pJ_block'])} | "
                 + ' | '.join(f"{pp(c, (key,)):+.1f}" for key in ('tiles', 'pe_pipes_glue', 'a_edge', 'w_edge', 'bank'))
                 + f" | {pp(c, other):+.1f} | {a['tile_a_per_clock']:.3f} / {k['tile_a_per_clock']:.3f} | "
                   f"{a['tile_w_per_clock']:.3f} / {k['tile_w_per_clock']:.3f} |")
    L.append('')
    pe = {c['length']: pp(c, ('tiles', 'pe_pipes_glue', 'pe_clk_buf')) for c in t['common']}
    ed = {c['length']: pp(c, ('a_edge', 'w_edge', 'bank')) for c in t['common']}
    ti = {c['length']: pp(c, ('tiles',)) for c in t['common']}
    worst = max(pe, key=pe.get)
    lo_n, hi_n = min(cm), max(cm)
    ca = {n: cm[n]['csa']['tile_a_per_clock'] for n in cm}
    aa = {n: cm[n]['af']['tile_a_per_clock'] for n in cm}
    short = [n for n in cm if 2 <= cm[n]['af']['cycles'] <= 4]             # 2 to 4 cycles per block
    # the hand-written explanation in the doc (section 3.2) rests on these
    assert all(v < 0 for v in ed.values()), 'edges + stream generators do not save at every T'
    assert all(cm[n]['af']['tile_w_per_clock'] < cm[n]['csa']['tile_w_per_clock'] for n in cm), 'AF w_bits not below CSA'
    assert all(aa[n] > ca[n] for n in short) and pe[lo_n] < 0 and aa[lo_n] < ca[lo_n] and aa[hi_n] < ca[hi_n], \
        'A-bit toggle claims'
    ae = {c['length']: pp(c, ('a_edge',)) for c in t['common']}
    assert max(abs(v) for v in ae.values()) < 2.5, "the A edge's encoders no longer cost about what the A comparators do"
    jn = lambda xs: ' and '.join(xs) if len(xs) < 3 else ', '.join(xs[:-1]) + ' and ' + xs[-1]
    hot_pe = sorted(n for n in pe if pe[n] > 0)
    L += ["- 'other' = PE clock buffers + edge clock buffers + top-level rest. A edge = registers + A-side logic (CSA "
          "comparators, AF kA encoders + thermometers); the stream generators (CSA A and W Sobol banks, AF W bank) are "
          "separate. The class columns add up to 'AF vs CSA'.",
          '- PE core (tiles + pipes + PE clock buffers), percentage points by T: '
          + ', '.join(f'{n}: {pe[n]:+.1f}' for n in sorted(pe, reverse=True)) + '.',
          '- Edges + stream generators by T: ' + ', '.join(f'{n}: {ed[n]:+.1f}' for n in sorted(ed, reverse=True))
          + f" (a saving at every T, {max(ed.values()):+.1f} to {min(ed.values()):+.1f}; of which the A edge "
          f"{min(ae.values()):+.1f} to {max(ae.values()):+.1f}).",
          f"- The tiles alone cost more than the CSA's at T = "
          f"{jn([f'{n} ({ti[n]:+.1f} points)' for n in sorted(ti, reverse=True) if ti[n] > 0])}. The whole PE core (tiles, "
          f"pipes and PE clock buffers) costs more only at T = {jn([f'{n} ({pe[n]:+.1f} points)' for n in hot_pe])}; at "
          f"T = {worst} AF's tile a_bits toggle {aa[worst]:.3f} per clock against {ca[worst]:.3f}. In the grid composites "
          f"the edges are shared, so there AF vs CSA at T = {worst} is {gvs(cm[worst]['af'], cm[worst]['csa'])} (4x4 / 4x8).",
          f"- Tile a_bits toggles per clock: the CSA's stay at {min(ca[n] for n in cm if n > lo_n):.3f}-"
          f"{max(ca[n] for n in cm if n > lo_n):.3f} from T = {min(n for n in cm if n > lo_n)} up; AF's fall from "
          f"{max(aa[n] for n in cm if n > lo_n):.3f} to {aa[hi_n]:.3f} as the blocks lengthen. With "
          f"{min(cm[n]['af']['cycles'] for n in short):.0f}-{max(cm[n]['af']['cycles'] for n in short):.0f} cycles per block "
          f"(T = {', '.join(str(n) for n in sorted(short))}) AF's toggle more than the CSA's; at T = {lo_n} less "
          f"({aa[lo_n]:.3f} against {ca[lo_n]:.3f}), and the PE core saves again ({pe[lo_n]:+.1f} points).",
          f"- AF's tile w_bits toggle less than the CSA's at every T ("
          f"{min(cm[n]['af']['tile_w_per_clock'] for n in cm):.3f}-{max(cm[n]['af']['tile_w_per_clock'] for n in cm):.3f} "
          f"against {min(cm[n]['csa']['tile_w_per_clock'] for n in cm):.3f}-{max(cm[n]['csa']['tile_w_per_clock'] for n in cm):.3f} "
          f"per clock).", '', END]

    # ---------------------------------------------------------------- per MAC at shorter T
    lo, hi = cm[min(cm)], cm[max(cm)]
    per = lambda r: sum(r['cls_mW'][k] for k in ('a_edge', 'w_edge', 'shared'))
    L += ['### What per MAC means at shorter T', '', begin('tsweep_permac'),
          f"- Every block is the same {mb} kernel MACs at every T; T sets how many stream positions each product gets. One PE "
          f"finishes a block every T / {m} cycles: {mb * F_GHZ / lo['af']['cycles']:.1f} GMAC/s at T = {lo['length']}, "
          f"{mb * F_GHZ / hi['af']['cycles']:.1f} GMAC/s at T = {hi['length']}, in the same area, so GMAC/s/mm2 scales by "
          f"{hi['length']} / T for both designs and their area ratio does not change.",
          f"- A T-position stream resolves each operand to about 1/T of full scale, about log2(T) bits: "
          f"{math.log2(lo['length']):.0f} at T = {lo['length']}, {math.log2(hi['length']):.0f} at T = {hi['length']}. So a "
          f"pJ/MAC at short T is the energy of a lower-precision MAC: compare designs at the same T, not one T with another.",
          f"- Power rises as T falls (CSA {hi['csa']['power_mW']:.3f} -> {lo['csa']['power_mW']:.3f} mW, AF "
          f"{hi['af']['power_mW']:.3f} -> {lo['af']['power_mW']:.3f} mW from T = {hi['length']} to {lo['length']}): operand "
          f"loads and the edge logic's switch to new operands come {hi['length'] // lo['length']}x as often (edges + edge clock "
          f"buffers: CSA {per(hi['csa']):.3f} -> {per(lo['csa']):.3f} mW, AF {per(hi['af']):.3f} -> {per(lo['af']):.3f} mW), and "
          f"the tiles see more input toggles (tiles: CSA {hi['csa']['cls_mW']['tiles']:.3f} -> {lo['csa']['cls_mW']['tiles']:.3f} "
          f"mW, AF {hi['af']['cls_mW']['tiles']:.3f} -> {lo['af']['cls_mW']['tiles']:.3f} mW). Energy per block still falls "
          f"(CSA {pct(lo['csa']['pJ_block'], hi['csa']['pJ_block'])}, AF {pct(lo['af']['pJ_block'], hi['af']['pJ_block'])}), "
          f"because a block takes {lo['length']}/{hi['length']} of the cycles.", '', END]

    # ---------------------------------------------------------------- tables.md only: every point, absolute
    L += ['### Stream-length sweeps: every measured point (absolute; mW unless noted)', '',
          '| design | point | T or L | cycles per block | window | mW | pJ/MAC | pJ per block | tiles | PE pipes + glue | '
          'PE clock buffers | A edge | of which A-side logic | W edge | stream generators | edge clock buffers + leftovers | '
          'top-level rest | mean kA | operand-port TC | tile a_bits / w_bits toggles per clock | 4x4 composite pJ/MAC | '
          '4x8 composite pJ/MAC | GL | '
          'drain |', '|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---|']
    for r in sorted(pts, key=lambda r: (r['design'], r['length'] or 0, r['tag'])):
        cm_ = r['cls_mW']
        L.append(f"| {r['design'].upper()} | {r['tag']} | {r['length'] or '-'} | {cyc(r)} | {r['window']:,} | {r['power_mW']:.4f} | "
                 f"{r['pJ_MAC']:.4f} | {r['pJ_block']:.2f} | "
                 + ' | '.join(f"{cm_[k]:.3f}" for k in ('tiles', 'pe_pipes_glue', 'pe_clk_buf', 'a_edge'))
                 + f" | {r['a_logic_mW']:.3f} | "
                 + ' | '.join(f"{cm_[k]:.3f}" for k in ('w_edge', 'bank', 'shared', 'top_rest'))
                 + f" | {f1(r['mean_kA'])} | {r['port_operand_TC']:,} | {r['tile_a_per_clock']:.3f} / {r['tile_w_per_clock']:.3f} | "
                   f"{f4(r['grid_4x4_pJ_MAC'])} | {f4(r['grid_4x8_pJ_MAC'])} | {r['gl']} | {r['drain']} |")
    L.append('')
    L.append(f"Grid composites ('-'): the per-row-L runs give each PE its own block length, which a grid with one stream "
             f"generator cannot run. Ladder runs: AF ladder (`ladder`), every row at its block's longest L "
             f"(`ladder_rowmax`), every block held {T_STREAM // m} cycles (`ladder_hold8`); CSA ladder-equivalent "
             f"(`ladder`) and the bench-copy replay of the T = {T_STREAM} operands (`repro`).")
    L.append('')
    fl = t['floating']
    L += ['Cross-check against the earlier CSA T sweep on the floating route (doc/results.md "Carry-save energy versus T"; '
          'a different route and a fixed ~3,072-clock window, not used for any comparison here):', '',
          '| T | pinned route pJ/MAC (this sweep) | floating route pJ/MAC (blocks) | pinned vs floating |', '|---:|---:|---:|---:|']
    for c in sorted(t['common'], key=lambda c: c['length']):
        f = fl[c['length']]
        L.append(f"| {c['length']} | {c['csa']['pJ_MAC']:.4f} | {f['pJ_MAC']:.4f} ({f['blocks']:,}) | {pct(c['csa']['pJ_MAC'], f['pJ_MAC'])} |")
    L.append('')
    return L


def ladder_lengths(r):
    """Row stream lengths of the AF ladder workload, parsed from its workload label ('ladder [128, 96, ...] ...')."""
    return [int(x) for x in re.search(r'\[([0-9, ]+)\]', r['workload'])[1].split(',')]


if __name__ == '__main__':
    main()
