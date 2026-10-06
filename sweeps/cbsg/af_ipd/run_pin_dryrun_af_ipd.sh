#!/bin/bash
# [CBSG-AF-IPD COPY] of sweeps/cbsg/pin_dryrun/run_pin_dryrun.sh (unchanged; sha256 in
# designs/payn/variants/signed_segmented_csa_cbsg_af_ipd/copied_from.sha256) for the AF-IPD netlist.
# Dry run (plain tclsh, no Innovus, no license) of the APR pre-placement Tcl on the synthesized AF-IPD netlist,
# with the C-BSG mock unchanged (sweeps/cbsg/pin_dryrun/innovus_mock.tcl, netlist_mockdb.py, invoked read-only).
# Changes (marked [AF-IPD]): one arm (TSMC22/PAYN_SC_CSA_CBSG_AF_IPD, synthesis AFIPD_SYNTH_RUN, default
# cbsg_af_ipd_20261005); mode postfill (the pinned pass 2 pre-place script of this route,
# apr/scripts/cbsg/place_pins_and_guides_sc_cbsg_postfill.tcl, which sources the C-BSG pin script unchanged);
# and, after the mock's own audit (which band-checks the AF buses but not the INT ones), an extra audit of the
# plan file: every a_raw_in[(h*K+k)*M + m] pin on the EAST edge inside row h's band, every w_raw_in pin on the
# NORTH edge inside column v's band, the scalars int_mode / int_prec / ring_in in the SOUTH control group and
# int_out / int_out_valid in the SOUTH out group (the BP plan of the shared pin script).
#
#   bash sweeps/cbsg/af_ipd/run_pin_dryrun_af_ipd.sh [pins|postfill|guides] [OUT_DIR]
# Output: OUT_DIR (default build/cbsg/af_ipd/pin_dryrun/<mode>) with dryrun.log, dryrun_summary.txt,
# sc_pin_plan.tsv, guides.tsv; the last log line is PIN_DRYRUN_AF_IPD: PASS|FAIL.
set -Eeuo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
cd "$REPO"
mode=${1:-pins}
target=TSMC22/PAYN_SC_CSA_CBSG_AF_IPD; top=payn_array_signed_segmented_csa_cbsg_af_ipd
synrun=${AFIPD_SYNTH_RUN:-cbsg_af_ipd_20261005}
case "$mode" in
    pins) script=apr/scripts/cbsg/place_pins_and_guides_sc_cbsg.tcl;;
    postfill) script=apr/scripts/cbsg/place_pins_and_guides_sc_cbsg_postfill.tcl;;
    guides) script=apr/scripts/place_guides_sc_distribution.tcl;;
    *) echo "unknown mode $mode" >&2; exit 2;;
esac
out=${2:-$REPO/build/cbsg/af_ipd/pin_dryrun/$mode}
[[ "$out" == /* ]] || out="$REPO/$out"
syndir="$REPO/syn/build/$target/$synrun"
[[ -s "$syndir/$top.syn.v" && -s "$syndir/area.rpt" ]] || { echo "missing $syndir/$top.syn.v or area.rpt" >&2; exit 2; }
rm -rf "$out"; mkdir -p "$out"
python3 sweeps/cbsg/pin_dryrun/netlist_mockdb.py "$syndir" "$top" "$out/mockdb.tcl" --util "${CORE_UTIL:-0.70}" | tee "$out/dryrun.log"
export SC_NH=8 SC_NW=8 SC_DIST_HIER_PREFIX=u_pe/u_array_core
unset SC_PIN_SPAN SC_PIN_LAYERS_H SC_PIN_LAYERS_V SC_PIN_TRACK_UM SC_PIN_MIN_PITCH_TRACKS
unset SC_PIN_SOUTH_CTRL_STEP_UM SC_PIN_PLAN_FILE SC_DIST_GUIDE_BAND SC_DIST_GUIDE_MARGIN SC_DIST_GUIDE_DENSITY
# [AF-IPD] the postfill script reads (and re-points) the flow's PRE_REPORT_SCRIPT, as the target sets it.
export PRE_REPORT_SCRIPT=apr/scripts/check_popcount_placement.tcl
rc=0
MOCK_EXPECT_PINS=1; [[ "$mode" != guides ]] || MOCK_EXPECT_PINS=0
export MOCK_EXPECT_PINS
tclsh sweeps/cbsg/pin_dryrun/innovus_mock.tcl "$out/mockdb.tcl" "$REPO/$script" "$out" >> "$out/dryrun.log" 2>&1 || rc=$?
rm -f "$out/mockdb.tcl"
grep -E '^(SC_DISTRIBUTION_GUIDES|SC_PIN_PLACEMENT|CBSG_POSTFILL_HOOK|WARNING|ERROR|MOCK_ERROR|PIN_DRYRUN)' "$out/dryrun.log" | cut -c1-900
# [AF-IPD] INT-port audit of the plan (pins / postfill modes).
if [[ "$mode" != guides && "$rc" == 0 ]]; then
    python3 - "$out/sc_pin_plan.tsv" "$out/dryrun_summary.txt" >> "$out/dryrun.log" <<'PY' || rc=$?
import csv, re, sys
rows = list(csv.DictReader(open(sys.argv[1]), delimiter='\t'))
die = re.search(r'die_um=([0-9.]+)', open(sys.argv[2]).read())
by = {r['pin']: r for r in rows}
err = []
def idx(p): return int(re.search(r'\[(\d+)\]$', p)[1])
K, M, NH, NW = 8, 16, 8, 8
cnt = {}
for p, r in by.items():
    base = p.split('[')[0]
    if base == 'a_raw_in':
        h = idx(p) // (K * M)
        if r['edge'] != 'E' or int(r['group']) != h: err.append(f'{p}: edge {r["edge"]} group {r["group"]}, expected E {h}')
    elif base == 'w_raw_in':
        v = idx(p) // (K * M)
        if r['edge'] != 'N' or int(r['group']) != v: err.append(f'{p}: edge {r["edge"]} group {r["group"]}, expected N {v}')
    elif p in ('int_mode', 'int_prec', 'ring_in', 'block_start', 'slice_start'):
        if r['edge'] != 'S' or r['group'] != 'ctrl': err.append(f'{p}: {r["edge"]} {r["group"]}, expected S ctrl')
    elif base == 'int_out' or p == 'int_out_valid':
        if r['edge'] != 'S' or r['group'] != 'out': err.append(f'{p}: {r["edge"]} {r["group"]}, expected S out')
    elif base == 'a_len_in':
        h = idx(p) // 8
        if r['edge'] != 'E' or int(r['group']) != h: err.append(f'{p}: edge {r["edge"]} group {r["group"]}, expected E {h}')
    cnt[(base, r['edge'])] = cnt.get((base, r['edge']), 0) + 1
need = {('a_raw_in', 'E'): 1024, ('w_raw_in', 'N'): 1024, ('int_out', 'S'): 64, ('a_len_in', 'E'): 64}
for k, n in need.items():
    if cnt.get(k, 0) != n: err.append(f'{k}: {cnt.get(k, 0)} pins, expected {n}')
per_edge = {}
for r in rows: per_edge[r['edge']] = per_edge.get(r['edge'], 0) + 1
for e in err[:20]: print('INT_AUDIT_ERROR:', e)
print(f"PIN_DRYRUN_AF_IPD_INT_AUDIT: {'PASS' if not err else 'FAIL'} pins={len(rows)} per_edge={per_edge} "
      f"a_raw_in E={cnt.get(('a_raw_in','E'),0)} w_raw_in N={cnt.get(('w_raw_in','N'),0)} int_out S={cnt.get(('int_out','S'),0)} "
      f"a_len_in E={cnt.get(('a_len_in','E'),0)} errors={len(err)}")
sys.exit(1 if err else 0)
PY
    grep -E '^(INT_AUDIT_ERROR|PIN_DRYRUN_AF_IPD_INT_AUDIT)' "$out/dryrun.log"
fi
echo "PIN_DRYRUN_AF_IPD: $([[ $rc == 0 ]] && echo PASS || echo FAIL) mode=$mode" | tee -a "$out/dryrun.log"
exit "$rc"
