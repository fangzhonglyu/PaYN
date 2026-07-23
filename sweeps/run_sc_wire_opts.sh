#!/bin/bash
# Controlled K8/M16/8x8 wire-power experiments:
#   baseline              unconstrained placement, native operand distribution
#   guide                 soft tile guides
#   guide_fanout4         tile guides plus global synthesis MAX_FANOUT=4
#   distguide             A row/W column distribution guides
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO"
source /etc/profile.d/modules.sh 2>/dev/null || \
    source /usr/share/Modules/init/bash 2>/dev/null
module load synopsys-lib-compiler/2022.03-SP3
module load synopsys-synth/2021.06-SP1
module load primetime/2021.06-SP1
module load vcs/2020.12-SP2-1
module load innovus/21.14.000
module load genus/21.14.000

export SYNOPSYS=/usr/caen/synopsys-synth-2021.06-SP1
export USE_DW=1

K=8
M=16
N=8
T=128
TARGET=TSMC22/PAYN_SC_SWEEP
TB=designs/payn/power/power_payn_array.sv
SYN_DEFINES="PAYN_K=$K PAYN_M=$M PAYN_NH=$N PAYN_NW=$N"
SIM_DEFINES="+define+SC_K=$K +define+SC_M=$M +define+SC_NH=$N +define+SC_NW=$N +define+SC_T=$T"
OUT=build/power_char/wire_opts
CSV=$OUT/sc_wire_opts.csv
mkdir -p "$OUT"
printf '%s\n' 'variant,max_fanout,guide_type,topology,syn_area_um2,syn_slack_ns,apr_cell_area_um2,apr_setup_wns_ns,apr_hold_wns_ns,power_mW,power_valid,pJ_MAC,net_switch_mW,total_net_cap_pF,total_wire_um,a_root_cap_pF,a_root_switch_mW,a_root_fanout_max,w_root_cap_pF,w_root_switch_mW,w_root_fanout_max,cosim,saif_valid,status' > "$CSV"

stage() {
    printf '[%s] %s\n' "$1" "$2" | tee -a "$OUT/$1.log"
}

is_pt_power_report() {
    local report=$1
    [ -f "$report" ] && rg -q '^Total Power[[:space:]]*=' "$report"
}

run_net_loads() {
    local run=$1
    local saif=$2
    local run_dir="apr/build/$TARGET/$run"
    if [ ! -f "$run_dir/reports/sc_net_loads.rpt" ]; then
        (
            cd "$run_dir"
            TOP=payn_array SAIF_FILE="$saif" \
                pt_shell -file "$REPO/sweeps/pt_sc_net_loads.tcl"
        ) >> "$OUT/$run.log" 2>&1
    fi
}

append_result() {
    local variant=$1
    local max_fanout=$2
    local guide_type=$3
    local topology=$4
    local syn_run=$5
    local apr_run=$6
    local cosim=$7
    local saif_valid=$8
    local power_valid=$9
    local status=${10}
    local syn_dir="syn/build/$TARGET/$syn_run"
    local apr_dir="apr/build/$TARGET/$apr_run"
    local metrics="$apr_dir/reports/sc_net_loads.rpt"
    local syn_area syn_slack apr_area apr_setup apr_hold power_w power_mw pj net_switch wire
    local all_cap a_cap a_switch a_fanout w_cap w_switch w_fanout

    syn_area=$(awk '/Total cell area/{print $NF; exit}' "$syn_dir/area.rpt")
    syn_slack=$(awk '/slack \(MET\)|slack \(VIOLATED\)/{print $NF; exit}' "$syn_dir/timing.rpt")
    apr_area=$(awk '$1=="payn_array"{print $3; exit}' "$apr_dir/reports/area.rpt")
    # These reports are generated after the final signoff extraction.  The
    # postRoute.summary.gz checkpoint can be optimistic and is not signoff WNS.
    apr_setup=$(awk '/Slack Time/{print $NF; exit}' "$apr_dir/reports/setup.rpt")
    apr_hold=$(awk '/Slack Time/{print $NF; exit}' "$apr_dir/reports/hold.rpt")
    if is_pt_power_report "$apr_dir/reports/power.rpt"; then
        power_w=$(awk '$1=="Total" && $2=="Power" && $3=="="{print $4; exit}' \
            "$apr_dir/reports/power.rpt")
        power_mw=$(awk -v p="$power_w" 'BEGIN{printf "%.6f",1000*p}')
        pj=$(awk -v p="$power_w" -v k="$K" -v m="$M" -v n="$N" -v t="$T" \
            'BEGIN{printf "%.6f",p*2.5e-9/(k*m*n*n/t)*1e12}')
        net_switch=$(awk '$1=="Net" && $2=="Switching" && $3=="Power"{printf "%.6f",1000*$5; exit}' \
            "$apr_dir/reports/power.rpt")
    else
        power_mw=
        pj=
        net_switch=
        power_valid=NO
        status="${status}+POWER_NOT_RUN"
    fi
    wire=$(awk '/#Total wire length =/{v=$5} END{print v}' "$apr_dir/innovus.log")
    all_cap=$(awk -F, '$1=="all_nets"{print $3}' "$metrics")
    a_cap=$(awk -F, '$1=="a_pipe_root"{print $3}' "$metrics")
    a_switch=$(awk -F, '$1=="a_pipe_root"{print $7}' "$metrics")
    a_fanout=$(awk -F, '$1=="a_pipe_root"{print $9}' "$metrics")
    w_cap=$(awk -F, '$1=="w_pipe_root"{print $3}' "$metrics")
    w_switch=$(awk -F, '$1=="w_pipe_root"{print $7}' "$metrics")
    w_fanout=$(awk -F, '$1=="w_pipe_root"{print $9}' "$metrics")
    if awk -v v="$apr_setup" 'BEGIN{exit !(v < 0)}'; then
        status="${status}+SETUP"
    fi
    if awk -v v="$apr_hold" 'BEGIN{exit !(v < 0)}'; then
        status="${status}+HOLD"
    fi
    if [ "$status" != OK ]; then
        status=${status#OK+}
        status="INVALID_${status#INVALID_}"
    fi
    printf '%s\n' "$variant,$max_fanout,$guide_type,$topology,$syn_area,$syn_slack,$apr_area,$apr_setup,$apr_hold,$power_mw,$power_valid,$pj,$net_switch,$all_cap,$wire,$a_cap,$a_switch,$a_fanout,$w_cap,$w_switch,$w_fanout,$cosim,$saif_valid,$status" >> "$CSV"
}

# Capture the existing baseline with the same PT net-capacitance script.
BASE_RUN=k8m16n8
BASE_DIR="apr/build/$TARGET/$BASE_RUN"
if [ ! -f "$BASE_DIR/outputs/payn_array.apr.v" ] || \
   [ ! -f "$BASE_DIR/activity/dut.saif" ]; then
    echo "ERROR: expected existing baseline run $BASE_DIR" >&2
    exit 2
fi
stage baseline "PrimeTime net-load characterization"
run_net_loads "$BASE_RUN" "$REPO/$BASE_DIR/activity/dut.saif"
append_result baseline 16 none native "$BASE_RUN" "$BASE_RUN" PASS YES YES OK

run_variant() {
    local variant=$1
    local max_fanout=$2
    local syn_run=$3
    local apr_run=$4
    local guide_type=$5
    local topology=$6
    local log="$OUT/$variant.log"
    local sim_dir="build/wire_opts/$variant/gl"
    : > "$log"

    if [ ! -f "syn/build/$TARGET/$syn_run/payn_array.syn.v" ]; then
        stage "$variant" "synthesis (MAX_FANOUT=$max_fanout)"
        MAX_FANOUT="$max_fanout" RUN_NAME="$syn_run" \
            SYN_DEFINES="$SYN_DEFINES" make synth TARGET="$TARGET" \
            >> "$log" 2>&1
    else
        stage "$variant" "reusing synthesis run $syn_run"
    fi
    if [ ! -f "apr/build/$TARGET/$apr_run/outputs/payn_array.apr.v" ]; then
        stage "$variant" "APR with $guide_type guides"
        local apr_status=0
        if [ "$guide_type" = tile ]; then
            SC_PLACE_GUIDES=1 SC_NH="$N" SC_NW="$N" \
                SC_TILE_HIER_STYLE=manual SC_TILE_HIER_PREFIX=u_pe/u_array_core \
                RUN_NAME="$apr_run" make apr TARGET="$TARGET" SYNTH_RUN="$syn_run" \
                >> "$log" 2>&1 || apr_status=$?
        elif [ "$guide_type" = distribution ]; then
            SC_DISTRIBUTION_GUIDES=1 SC_NH="$N" SC_NW="$N" \
                RUN_NAME="$apr_run" make apr TARGET="$TARGET" SYNTH_RUN="$syn_run" \
                >> "$log" 2>&1 || apr_status=$?
        else
            echo "ERROR: unsupported guide type $guide_type" >&2
            exit 3
        fi
        if [ "$apr_status" -ne 0 ]; then
            if [ ! -f "apr/build/$TARGET/$apr_run/outputs/payn_array.apr.v" ] || \
               [ ! -f "apr/build/$TARGET/$apr_run/outputs/payn_array.spef" ]; then
                echo "ERROR: APR failed before producing routed outputs for $variant" >&2
                exit 3
            fi
            stage "$variant" "APR produced routed outputs with signoff violations"
        fi
    else
        stage "$variant" "reusing APR run $apr_run"
    fi

    if [ "$guide_type" = tile ]; then
        if ! rg -q 'SC_TILE_GUIDES:.*added=64' \
            "apr/build/$TARGET/$apr_run/apr.log"; then
            echo "ERROR: APR did not confirm all 64 tile guides" >&2
            exit 3
        fi
    elif [ "$guide_type" = distribution ]; then
        if ! rg -q 'SC_DISTRIBUTION_GUIDES:.*a_cells=1088 w_cells=1088' \
            "apr/build/$TARGET/$apr_run/apr.log"; then
            echo "ERROR: APR did not confirm all A/W distribution guides" >&2
            exit 3
        fi
    fi

    local saif trace
    # SAIF files are intentionally ignored by git, so include ignored build
    # products while keeping the search scoped to this variant's sim directory.
    saif=$(rg --files -uu "$sim_dir" 2>/dev/null | awk '/\/dut\.saif$/{print; exit}' || true)
    trace=$(rg --files -uu "$sim_dir" 2>/dev/null | awk '/\/array_rtl\.txt$/{print; exit}' || true)
    if [ -z "$saif" ] || [ -z "$trace" ]; then
        stage "$variant" "routed-SDF gate-level simulation"
        if ! make sim GL=apr TARGET="$TARGET" RUN="$apr_run" USE_DW=1 \
                BUILD_DIR="$sim_dir" TB="$TB" VCS_ARGS="$SIM_DEFINES" \
                >> "$log" 2>&1; then
            stage "$variant" "gate-level simulation returned nonzero; checking artifacts"
        fi
        saif=$(rg --files -uu "$sim_dir" | awk '/\/dut\.saif$/{print; exit}')
        trace=$(rg --files -uu "$sim_dir" | awk '/\/array_rtl\.txt$/{print; exit}')
    fi

    local cosim=FAIL
    if python3 designs/payn/cosim/cosim_array.py "$trace" 2>> "$log" | \
        tee -a "$log" | rg -q '\[PASS\]'; then
        cosim=PASS
    fi
    if rg -q 'X-FAIL|\$fatal' "$log"; then
        cosim=FAIL
    fi

    saif=$(realpath "$saif")
    local saif_valid=NO
    if python3 -B sweeps/validate_sc_power_saif.py "$saif" \
            --expected-period-ns 2.5 >> "$log" 2>&1; then
        saif_valid=YES
    fi

    local status=OK
    if [ "$cosim" != PASS ]; then
        status=COSIM
    fi
    if [ "$saif_valid" != YES ]; then
        status="${status}+SAIF"
    fi
    status=${status#OK+}

    local power_valid=NO
    if [ "$cosim" = PASS ] && [ "$saif_valid" = YES ] && \
       ! is_pt_power_report "apr/build/$TARGET/$apr_run/reports/power.rpt"; then
        stage "$variant" "PrimeTime PX power"
        POWER_SAIF_VALIDATOR=sweeps/validate_sc_power_saif.py \
            make power_apr TARGET="$TARGET" RUN="$apr_run" \
            SAIF="$saif" SAIF_STRIP_PATH=Top/dut >> "$log" 2>&1
    fi
    if [ "$cosim" = PASS ] && [ "$saif_valid" = YES ] && \
       is_pt_power_report "apr/build/$TARGET/$apr_run/reports/power.rpt"; then
        power_valid=YES
    fi
    stage "$variant" "PrimeTime operand-net capacitance"
    run_net_loads "$apr_run" "$saif"
    append_result "$variant" "$max_fanout" "$guide_type" "$topology" \
        "$syn_run" "$apr_run" "$cosim" "$saif_valid" "$power_valid" "$status"
    if [ "$cosim" = PASS ] && [ "$saif_valid" = YES ]; then
        stage "$variant" "complete"
    else
        stage "$variant" "recorded as invalid (cosim=$cosim, SAIF=$saif_valid)"
    fi
}

run_variant guide 16 k8m16n8 k8m16n8_guide tile native
run_variant guide_fanout4 4 k8m16n8_fanout4 k8m16n8_guide_fanout4 tile global_fanout4
run_variant distguide 16 k8m16n8 k8m16n8_distguide distribution native
echo "SC wire experiment complete: $CSV"
