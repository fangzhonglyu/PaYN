#!/bin/bash
# Synthesis-power screen for symmetric A6P5/SVT pending-bit PaYN arrays.
# K=8, M=16, LOW_W=9, T=128 are fixed; command-line arguments select N.
set -u

cd /home/barrylyu/repos/PaYN
source /etc/profile.d/modules.sh 2>/dev/null || \
    source /usr/share/Modules/init/bash 2>/dev/null
module load synopsys-lib-compiler/2022.03-SP3 \
            synopsys-synth/2021.06-SP1 \
            primetime/2021.06-SP1 \
            vcs/2020.12-SP2-1 \
            innovus/21.14.000 \
            genus/21.14.000 2>/dev/null

export SYNOPSYS=${SYNOPSYS:-/usr/caen/synopsys-synth-2021.06-SP1}
export USE_DW=1

TARGET=TSMC22/PAYN_SC_SIGNED_SEGMENTED_A6P5_SVT
TB=designs/payn/power/power_payn_array.sv
OUT=build/power_char/a6p5_n_screen
CSV=$OUT/results.csv
MAX_JOBS=${MAX_JOBS:-3}
N_VALUES=("$@")
[ ${#N_VALUES[@]} -gt 0 ] || N_VALUES=(4 6 10)
mkdir -p "$OUT"
[ -f "$CSV" ] || \
    echo "N,run,syn_area_um2,syn_setup_wns_ns,power_mW,pJ_MAC,status" > "$CSV"

run_n() {
    local n=$1
    local run=a6p5_svt_k8m16n${n}_lw9
    local log=$OUT/n${n}.log
    local syn_dir=syn/build/$TARGET/$run
    local build=$OUT/n${n}_gl
    local defs="+define+PAYN_ARRAY_DUT=payn_array_signed_segmented +define+SC_K=8 +define+SC_M=16 +define+SC_NH=$n +define+SC_NW=$n +define+SC_OWIDTH=24 +define+SC_T=128 +define+SC_BATCHES=384"

    grep -q "^${n},.*,OK$" "$CSV" 2>/dev/null && return
    : > "$log"

    if [ -f "$syn_dir/payn_array_signed_segmented.syn.v" ]; then
        echo "[N=$n] reuse completed synth" >> "$log"
    else
        echo "[N=$n] synth" >> "$log"
        PAYN_A6P5_N=$n RUN_NAME=$run \
            make synth TARGET=$TARGET >> "$log" 2>&1
    fi
    if [ ! -f "$syn_dir/payn_array_signed_segmented.syn.v" ]; then
        echo "$n,$run,,,,,SYNTH_FAIL" >> "$CSV"
        return
    fi

    echo "[N=$n] output-checked synthesis GL activity" >> "$log"
    PAYN_A6P5_N=$n \
        make sim GL=syn NO_SDF=1 TARGET=$TARGET RUN=$run USE_DW=1 \
        BUILD_DIR=$build TB=$TB \
        VCS_ARGS="+delay_mode_unit +notimingcheck $defs" >> "$log" 2>&1

    local saif
    local trace
    saif=$(rg --files -uu "$build" 2>/dev/null |
        awk '/\/dut\.saif$/{print; exit}')
    trace=$(rg --files -uu "$build" 2>/dev/null |
        awk '/\/array_streaming_rtl\.txt$/{print; exit}')
    if [ -z "$saif" ] || [ -z "$trace" ] ||
       ! python3 designs/payn/cosim/cosim_streaming.py "$trace" \
            >> "$log" 2>&1; then
        echo "$n,$run,,,,,SIM_OR_COSIM_FAIL" >> "$CSV"
        return
    fi
    if ! python3 sweeps/validate_sc_power_saif.py "$saif" \
            --expected-period-ns 2.5 >> "$log" 2>&1; then
        echo "$n,$run,,,,,SAIF_FAIL" >> "$CSV"
        return
    fi

    echo "[N=$n] PT-PX" >> "$log"
    PAYN_A6P5_N=$n POWER_SAIF_VALIDATOR=sweeps/validate_sc_power_saif.py \
        make power TARGET=$TARGET RUN=$run SAIF=$saif \
        SAIF_STRIP_PATH=Top/dut >> "$log" 2>&1

    local area
    local slack
    local power
    local energy
    area=$(awk '/Total cell area:/{print $4; exit}' "$syn_dir/area.rpt")
    slack=$(awk '/slack \(MET\)/{print $NF; exit}' "$syn_dir/timing.rpt")
    power=$(awk '
        /^Total / {
            for (i=1; i<=NF; i++) {
                if ($(i+1) == "mW") {printf "%.6f", $i; exit}
                if ($(i+1) == "W")  {printf "%.6f", 1000*$i; exit}
            }
        }' "$syn_dir/pwr_saif.rpt")
    if [ -z "$power" ]; then
        echo "$n,$run,$area,$slack,,,POWER_FAIL" >> "$CSV"
        return
    fi
    energy=$(awk -v p="$power" -v n="$n" \
        'BEGIN {printf "%.9f", p/(0.4*n*n)}')
    echo "$n,$run,$area,$slack,$power,$energy,OK" >> "$CSV"
    echo "[N=$n] DONE ${power}mW ${energy}pJ/MAC" >> "$log"
}

for n in "${N_VALUES[@]}"; do
    run_n "$n" &
    while [ "$(jobs -rp | wc -l)" -ge "$MAX_JOBS" ]; do
        wait -n
    done
done
wait
sort -t, -k1,1n "$CSV"
