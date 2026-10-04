#!/bin/bash
# Repair a completed popcount APR checkpoint without rerunning synthesis/CTS.
# Usage: bash sweeps/repair_popcount_apr.sh TARGET INPUT_RUN [OUTPUT_RUN]
# Default OUTPUT_RUN=INPUT_RUN_legalized. Explicitly repeating INPUT_RUN as the
# output archives every original artifact before repairing the canonical path.
# REPAIR_MODE=auto (default): current placement violations -> overlap repair
# from route.enc; otherwise targeted geometry/antenna repair from final.enc.
# Caller must first establish that the original process has exited.
set -Eeuo pipefail
[[ $# -ge 2 && $# -le 3 ]] || { echo "Usage: $0 TARGET INPUT_RUN [OUTPUT_RUN]" >&2; exit 2; }
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO"
export ASTRAEA_FLOW=${ASTRAEA_FLOW:-$(cd "$REPO/../ASTRAEA" && pwd)}
TARGET=$1; INPUT_RUN=$2; OUTPUT_RUN=${3:-${INPUT_RUN}_legalized}
REPAIR_MODE=${REPAIR_MODE:-auto}
case "$TARGET" in TSMC22/PAYN_SC_POPCOUNT_INFERRED|TSMC22/PAYN_SC_POPCOUNT_TECHMAP|TSMC22/PAYN_SC_CSA|TSMC22/PAYN_SC_CSA_BP) ;; *) echo 'Unsupported repair target' >&2; exit 2;; esac
case "$REPAIR_MODE" in auto|overlap|targeted) ;; *) echo 'Invalid REPAIR_MODE' >&2; exit 2;; esac
[[ "$INPUT_RUN" =~ ^[A-Za-z0-9_]+$ && "$OUTPUT_RUN" =~ ^[A-Za-z0-9_]+$ ]] || { echo 'Invalid run name' >&2; exit 2; }
SOURCE_DIR="$REPO/apr/build/$TARGET/$INPUT_RUN"
DEST_DIR="$REPO/apr/build/$TARGET/$OUTPUT_RUN"
[[ -f "$SOURCE_DIR/apr.log" ]] && grep -Eq 'Innovus script finished|POP_COUNT_CHECKPOINT_REPAIR_COMPLETE' "$SOURCE_DIR/apr.log"
exec 9>"$REPO/build/power_char/popcount_apr_20260930/repair_notes/${TARGET##*/}_${OUTPUT_RUN}.lock"
flock -n 9 || { echo 'Another repair owns this output' >&2; exit 2; }
source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash
module load synopsys-lib-compiler/2022.03-SP3
module load synopsys-synth/2021.06-SP1
module load primetime/2021.06-SP1
module load vcs/2020.12-SP2-1
module load innovus/21.14.000
module load genus/21.14.000
export NTFY_CHNL= SYNTH_RUN=checkpoint_only_repair
export TSMC22_CELL_TIER=sc7mcpp140z TSMC22_LIB_FLAVORS=svt_c30 TSMC22_HPK_FLAVORS=svt_c30 TSMC22_HPK=1
export PERIOD=2.5 CLOCK_UNCERTAINTY=0.125 APR_LOCAL_CPUS=32 ZERO_PINLESS_NET_ACTIVITY=1
export CORE_UTIL=0.70 CORE_ASPECT=1.000 SC_DISTRIBUTION_GUIDES=1 SC_PLACE_GUIDES=0 SC_NH=8 SC_NW=8
export APR_OPT_POWER=0 APR_MULTIBIT_FLOP_OPT=0 APR_LEAN_OPT=0
export SKIP_FINAL_HOLD_OPT=1 FORCE_FINAL_HOLD_OPT=0 SKIP_FILLER=0 FORCE_STRONG_FINAL_DRC=0
unset POST_SCRIPT APR_RESUME_FINAL
source "$REPO/apr/targets/$TARGET"
export DESIGN_ROOT="$REPO" FLOW_ROOT="$ASTRAEA_FLOW"
export PRE_REPORT_SCRIPT=apr/scripts/check_popcount_placement.tcl
export POP_REPAIR_FLOW_SCRIPTS="$ASTRAEA_FLOW/apr/scripts"
# Prepare and validate the exact repair plan before archiving anything.
PLAN_FILE=$(mktemp /tmp/payn_repair_plan.XXXXXX)
trap 'rm -f "$PLAN_FILE"' EXIT
python3 - "$SOURCE_DIR" "$TOP" "$REPAIR_MODE" "$PLAN_FILE" <<'PY'
from pathlib import Path
import json,re,sys
source,top,mode,output=Path(sys.argv[1]),sys.argv[2],sys.argv[3],Path(sys.argv[4])
log=(source/'apr.log').read_text(errors='replace')
checks=list(re.finditer(r'Begin checking placement.*?Finished checkPlace[^\n]*',log,re.S))
assert checks, 'No placement diagnosis'
match=re.search(r'Overlapping with other instance:\s*(\d+)',checks[-1][0])
overlaps=int(match[1]) if match else 0
if mode=='auto': mode='overlap' if overlaps or 'NRDB-2082' in log[checks[-1].end():] else 'targeted'
plan={'mode':mode,'checkpoint':'route' if mode=='overlap' else 'final','overlap_instances':[],'geometry':[],'antenna_pins':[]}
if mode=='overlap':
    names=[]
    for a,b in re.findall(r'NRDB-2082\) INST (\S+) and INST (\S+) are overlapped\.',log): names += [a,b]
    plan['overlap_instances']=sorted(set(names))
    assert names, 'No overlap instance names in source APR log'
else:
    geometry=(source/f'{top}.geom.rpt').read_text()
    for match in re.finditer(r'([^\n]+)\nBounds\s*:\s*\(\s*([-0-9.]+),\s*([-0-9.]+)\s*\)\s*\(\s*([-0-9.]+),\s*([-0-9.]+)\s*\)',geometry):
        nets=sorted(set(re.findall(r'Regular Wire of Net\s+(\S+)',match[1])))
        assert nets, 'Geometry violation lacks a supported regular-net diagnosis'
        plan['geometry'].append({'diagnosis':match[1],'nets':nets,'box':[float(match[i]) for i in range(2,6)]})
    total=re.search(r'Total Violations\s*:\s*(\d+)',geometry)
    if total: assert int(total[1])==len(plan['geometry']), 'Some geometry violations were not parsed'
    net=None; seen=set()
    for line in (source/f'{top}.antenna.rpt').read_text().splitlines():
        match=re.match(r'^(\S+)\s+\(\d+\)\s*$',line)
        if match: net=match[1]
        match=re.match(r'^\s+(\S+)\s+\(([^)]+)\)\s+(\S+)\s*$',line)
        if match:
            assert net, 'Antenna pin without a net'
            key=(net,match[1],match[3])
            if key not in seen:
                plan['antenna_pins'].append({'net':net,'inst':match[1],'pin':match[3],'cell':match[2]})
                seen.add(key)
    assert plan['geometry'] or plan['antenna_pins'], 'No residual geometry/antenna violations; no repair needed'
for suffix in (f'{top}.{plan["checkpoint"]}.enc',f'{top}.{plan["checkpoint"]}.enc.dat',f'{top}.syn.v',f'{top}.syn.sdc','TARGET_DEF'):
    assert (source/suffix).exists(), f'Missing repair input {suffix}'
output.write_text(json.dumps(plan,indent=2)+'\n')
print(json.dumps(plan,indent=2))
PY
MODE=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["mode"])' "$PLAN_FILE")
CHECKPOINT=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["checkpoint"])' "$PLAN_FILE")
if [[ "$SOURCE_DIR" == "$DEST_DIR" ]]; then
    archive="$SOURCE_DIR/before_legalization_$(date +%Y%m%d_%H%M%S)_${BASHPID}"
    mkdir "$archive"
    python3 - "$SOURCE_DIR" "$archive" <<'PY'
from pathlib import Path
import shutil,sys
source,archive=map(Path,sys.argv[1:])
for path in list(source.iterdir()):
    if path != archive: shutil.move(str(path),str(archive/path.name))
PY
    SOURCE_DIR="$archive"
else
    [[ ! -e "$DEST_DIR" ]] || { echo "Refusing existing output $DEST_DIR" >&2; exit 2; }
    mkdir -p "$DEST_DIR"
fi
cp -a "$SOURCE_DIR/$TOP.$CHECKPOINT.enc" "$SOURCE_DIR/$TOP.$CHECKPOINT.enc.dat" "$DEST_DIR/"
cp -p "$SOURCE_DIR/$TOP.syn.v" "$SOURCE_DIR/$TOP.syn.sdc" "$SOURCE_DIR/TARGET_DEF" "$DEST_DIR/"
# Saved power constraints reference a symlink to this generated local TCF.
# Archiving the run moves its old target; restore a local copy and repoint only
# this known link in the copied checkpoint, keeping the original archive intact.
if [[ -f "$SOURCE_DIR/astraea_placement_activity.tcf" ]]; then
    cp -p "$SOURCE_DIR/astraea_placement_activity.tcf" "$DEST_DIR/"
    saved_tcf="$DEST_DIR/$TOP.$CHECKPOINT.enc.dat/libs/power/astraea_placement_activity.tcf"
    if [[ -L "$saved_tcf" ]]; then
        ln -sfn "$DEST_DIR/astraea_placement_activity.tcf" "$saved_tcf"
    fi
fi
cp "$PLAN_FILE" "$DEST_DIR/repair_plan.json"
printf 'source=%s\noutput=%s\nflow=%s\nmode=%s\ncheckpoint=%s\n' "$SOURCE_DIR" "$DEST_DIR" "$ASTRAEA_FLOW" "$MODE" "$CHECKPOINT" > "$DEST_DIR/repair_inputs.txt"
export DISABLE_POSTROUTE_SWAPVIA=1
python3 - "$ASTRAEA_FLOW/apr/scripts/apr.tcl" "$DEST_DIR" <<'PY'
from pathlib import Path
import json,sys
flow,dest=map(Path,sys.argv[1:]);plan=json.loads((dest/'repair_plan.json').read_text())
s=flow.read_text();cut='if {[info exists env(APR_RESUME_FINAL)] &&'
assert s.count(cut)==1
s=s.split(cut)[0]
line='set SCRIPT_DIR [file dirname [file normalize [info script]]]'
assert s.count(line)==1
s=s.replace(line,'set SCRIPT_DIR $env(POP_REPAIR_FLOW_SCRIPTS)')
if plan['mode']=='targeted':
    # Local snapshot only: if targeted repair cannot close geometry, stop for
    # diagnosis rather than repeating the entire successful global routing.
    old='''	if {!$skip_strong_drc_fix} {
	    editDeleteViolations
	    globalDetailRoute
	}'''
    assert old in s, 'Unexpected standard final DRC fallback structure'
    s=s.replace(old,'''    if {!$skip_strong_drc_fix} {
        error "Targeted checkpoint repair leaves geometry markers; refusing a blind global reroute"
    }''')
(dest/'repair_flow_procedures.tcl').write_text(s)
def word(x): return '{'+str(x).replace('\\','\\\\').replace('{','\\{').replace('}','\\}')+'}'
def listing(xs): return '[list '+' '.join(word(x) for x in xs)+']'
lines=['set repair_mode '+word(plan['mode']), 'set repair_checkpoint '+word(plan['checkpoint']),
       'set repair_instances '+listing(plan['overlap_instances']), 'set repair_ant_pins [list]','set repair_geometry [list]']
for pin in plan['antenna_pins']:
    lines.append('lappend repair_ant_pins '+listing([pin['inst'],pin['pin'],pin['net']]))
for geo in plan['geometry']:
    lines.append('lappend repair_geometry [list '+listing(geo['nets'])+' '+listing(geo['box'])+']')
(dest/'repair_targets.tcl').write_text('\n'.join(lines)+'\n')
PY
cat > "$DEST_DIR/repair.tcl" <<'TCL'
source repair_flow_procedures.tcl
source repair_targets.tcl
restoreDesign "${top_level}.${repair_checkpoint}.enc.dat" $top_level
get_multithread_lic
file mkdir reports
checkPlace reports/placement_before_repair.rpt
configure_antenna_repair
configure_postroute_swapvia
proc exact_inst {name} {
    set pattern [string map [list "\\" "\\\\" {[} {\[} {]} {\]} {*} {\*} {?} {\?}] $name]
    set ptr [dbGet -p top.insts.name $pattern]
    if {$ptr eq "0x0" || [llength $ptr] != 1} { error "Cannot uniquely find instance $name" }
    return $ptr
}
setPlaceMode -place_detail_preserve_routing true
setPlaceMode -place_detail_remove_affected_routing true
setPlaceMode -place_hard_fence false
if {$repair_mode eq "overlap"} {
    set movable {}
    foreach name $repair_instances {
        set ptr [exact_inst $name]
        set status [dbGet ${ptr}.pStatus]
        puts "REPAIR_INSTANCE name=$name placement_status=$status"
        if {$status ne "fixed" && $status ne "cover"} { lappend movable $name }
    }
    if {[llength $movable] == 0} { error "All overlap instances are fixed" }
    refinePlace -eco true -inst $movable
} else {
    # Filler-complete density blocked automatic antenna-diode insertion. Open
    # only five-micron neighborhoods around the reported sinks, attach the
    # library diode explicitly, and preserve all existing logical placement.
    foreach item $repair_ant_pins {
        lassign $item inst pin net
        set ptr [exact_inst $inst]
        set box [lindex [dbGet ${ptr}.box] 0]
        lassign $box x1 y1 x2 y2
        set halo 5.0
        set local_box [list [expr {$x1-$halo}] [expr {$y1-$halo}] [expr {$x2+$halo}] [expr {$y2+$halo}]]
        puts "REPAIR_ANTENNA net=$net sink=$inst/$pin filler_window=$local_box"
        deleteFiller -area $local_box
        attachDiode -diodeCell $ANTENNA_CELL -pin [list $inst $pin] -prefix POP_REPAIR_DIODE
    }
    if {[llength $repair_ant_pins] > 0} {
        set diode_ptrs [dbGet -p top.insts.name *POP_REPAIR_DIODE*]
        if {$diode_ptrs eq "0x0"} { error "attachDiode created no diode instances" }
        set diode_names [dbGet ${diode_ptrs}.name]
        if {[llength $diode_names] < [llength $repair_ant_pins]} { error "Not all requested antenna diodes were created" }
        refinePlace -eco true -inst $diode_names
    }
    # Rip up only regular geometry on the diagnosed nets inside the local
    # marker neighborhood. This changes the failed via placement before ECO
    # routing, rather than repeating an unchanged detailRoute pass.
    foreach item $repair_geometry {
        lassign $item nets box
        lassign $box x1 y1 x2 y2
        set halo 0.5
        set local_box [list [expr {$x1-$halo}] [expr {$y1-$halo}] [expr {$x2+$halo}] [expr {$y2+$halo}]]
        puts "REPAIR_GEOMETRY nets=$nets area=$local_box"
        editDelete -net $nets -area $local_box -type Regular
    }
}
checkPlace reports/placement_after_legalize.rpt
connect_std_cells_to_power
ecoRoute
connect_std_cells_to_power
saveDesign ${top_level}.repaired_route.enc
# Refill opened gaps and use the existing standard local checks/export path.
# In targeted mode, the local flow snapshot refuses a global-reroute fallback.
run_final
puts "POP_COUNT_CHECKPOINT_REPAIR_COMPLETE"
exit
TCL
cd "$DEST_DIR"
trap 'rc=$?; printf "FAIL exit=%s\n" "$rc" > repair.status; exit "$rc"' ERR
innovus -batch -no_gui -files repair.tcl > apr.log 2>&1
grep -q 'POP_COUNT_CHECKPOINT_REPAIR_COMPLETE' apr.log
python3 - "$REPO/sweeps/run_popcount_apr.sh" "$DEST_DIR" "$TOP" <<'PY'
from pathlib import Path
import re,subprocess,sys
runner,path,top=sys.argv[1:]
blocks=re.findall(r"<<'PY'\n(.*?)\nPY",Path(runner).read_text(),re.S)
assert blocks and 'popcount_qualification.json' in blocks[0]
subprocess.run([sys.executable,'-c',blocks[0],path,top,'final'],check=True)
PY
printf 'PASS\n' > repair.status
printf 'Repair qualified: %s\nRegenerate full-timing max-SDF GL/cosim/SAIF and PT-PX for this changed layout.\n' "$DEST_DIR"
