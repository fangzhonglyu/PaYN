#!/usr/bin/env python3
"""Post-filler DRC trace of an ASTRAEA apr.log (run_final): filler passes, markers, and whether NanoRoute's strong
reroute (editDeleteViolations + globalDetailRoute) ran search-and-repair iterations.

The flow's addFiller runs a DRC-checked pass (prefix FILLER) and a second pass "without DRC checking" (prefix
FILLER_incr) whose cells overlap existing M1 routing.  The strong reroute's detail router reports the violations of
its initial pass and, after marking the filler-touched instances ("need to be verified (marked ipoed)"), the full
count; with -drouteAutoStop at its default it skips search-and-repair when that count is too high.  Over the repo's
routes the iterations ran whenever after_ipo / routable_nets <= 0.99 and were skipped at 1.09 (AF pinned).

  filler_drc_trace.py APR_LOG [APR_LOG ...] [--json OUT] [--tsv OUT]
"""
import argparse, json, re, sys
from pathlib import Path


def trace(path):
    log = Path(path).read_text(errors='replace')
    r = dict(log=str(path))
    m = re.search(r'Total (\d+) filler insts added - prefix FILLER \(', log)
    r['fillers_pass1'] = int(m[1]) if m else None
    m = re.search(r'Total (\d+) filler insts added - prefix FILLER_incr', log)
    r['fillers_pass2_no_drc'] = int(m[1]) if m else None
    m = re.search(r'Pre-route DRC Violation:\s*(\d+)', log)
    r['preroute_drc_after_filler'] = int(m[1]) if m else None
    m = re.search(r'Design Boundary: \(0\.0000, 0\.0000\) \(([\d.]+), ([\d.]+)\)', log)
    r['die_um'] = [float(m[1]), float(m[2])] if m else None
    m = re.search(r'markers_after_fix=(\d+)', log)
    r['markers_after_local_fix'] = int(m[1]) if m else None
    r['strong_reroute'] = 'Running strong reroute' in log
    if r['fillers_pass2_no_drc'] is not None:
        tail = log[log.index('prefix FILLER_incr'):]
        m = re.search(r'#CELL_VIEW \S+ has (\d+) DRC violations', tail)
        r['local_detailroute_violations'] = int(m[1]) if m else None
    s = log.rfind('INFO: Running strong reroute')
    if s >= 0:
        seg = log[s:]
        e = seg.find('#Complete globalDetailRoute')
        seg = seg[:e if e > 0 else None]
        m = re.search(r'#Total number of routable nets = (\d+)', seg)
        r['routable_nets'] = int(m[1]) if m else None
        d = seg.find('#start initial detail routing')
        c = seg.find('#Complete Detail Routing', d)
        det = seg[d:c]
        counts = [int(x) for x in re.findall(r'#\s+number of violations = (\d+)', det)]
        r['initial_detail_violations'] = counts[0] if counts else None
        m = re.search(r'#(\d+) out of (\d+) instances \(([\d.]+)%\) need to be verified', det)
        r['ipoed_instances'] = int(m[1]) if m else None
        r['after_ipo_violations'] = counts[1] if len(counts) > 1 else None
        r['search_repair_iterations'] = len(re.findall(r'#start \S+ optimization iteration', det))
        r['iteration_violations'] = counts[2:]
        m = re.findall(r'#Total number of DRC violations = (\d+)', seg)
        r['strong_reroute_final_violations'] = int(m[-1]) if m else None
        if r.get('routable_nets') and r.get('after_ipo_violations') is not None:
            r['after_ipo_per_routable_net'] = round(r['after_ipo_violations'] / r['routable_nets'], 4)
    # Fix option (c): apr/scripts/cbsg/postfill_search_repair.tcl (PRE_REPORT_SCRIPT hook), if present.
    h = log.find('CBSG_POSTFILL_DRC_REPAIR_BEGIN')
    if h >= 0:
        seg = log[h:log.find('CBSG_POSTFILL_DRC_REPAIR_END', h)]
        m = re.search(r'CBSG_POSTFILL_DRC_REPAIR: ran=(\d)', seg)
        r['postfill_hook_ran'] = bool(int(m[1])) if m else None
        m = re.search(r'markers_before=(\d+) markers_after=(\d+)', seg)
        if m: r['postfill_verify_markers_before_after'] = [int(m[1]), int(m[2])]
        d = seg.find('#start initial detail routing')
        c = seg.find('#Complete Detail Routing', d)
        if d >= 0:
            det = seg[d:c]
            counts = [int(x) for x in re.findall(r'#\s+number of violations = (\d+)', det)]
            r['postfill_initial_detail_violations'] = counts[0] if counts else None
            r['postfill_search_repair_iterations'] = len(re.findall(r'#start \S+ optimization iteration', det))
            r['postfill_last_iteration_violations'] = counts[-1] if counts else None
            m = re.search(r'#Start Post Route via swapping\.\.\.(?:(?!#Post Route via swapping is done).)*?#\s+number of violations = (\d+)', seg[c:], re.S)
            r['postfill_after_via_swap_violations'] = int(m[1]) if m else None
    drc = re.findall(r'Verification Complete\s*:\s*(\d+) Viols\.', log)
    r['final_verify_drc'] = int(drc[-2]) if len(drc) >= 2 else None
    r['verify_drc_limit_hit'] = r['final_verify_drc'] == 1000
    return r


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('logs', nargs='+')
    ap.add_argument('--json')
    ap.add_argument('--tsv')
    a = ap.parse_args()
    rows = [trace(p) for p in a.logs]
    keys = ['log', 'die_um', 'fillers_pass1', 'fillers_pass2_no_drc', 'local_detailroute_violations',
            'routable_nets', 'initial_detail_violations', 'after_ipo_violations', 'after_ipo_per_routable_net',
            'search_repair_iterations', 'strong_reroute_final_violations', 'final_verify_drc']
    lines = ['\t'.join(keys)] + ['\t'.join(str(r.get(k)) for k in keys) for r in rows]
    print('\n'.join(lines))
    if a.json:
        Path(a.json).write_text(json.dumps(rows if len(rows) > 1 else rows[0], indent=2) + '\n')
    if a.tsv:
        Path(a.tsv).write_text('\n'.join(lines) + '\n')


if __name__ == '__main__':
    sys.exit(main())
