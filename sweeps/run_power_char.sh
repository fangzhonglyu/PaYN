#!/bin/bash
# PaYN gate-level power characterization campaign.
#
# For every design: ensure a synthesis run, ensure an APR run, then for each
# requested cycle-count T run the routed-SDF power bench (timing checks ON),
# validate the SAIF (X-policy: architectural outputs must be X-free; dead-net
# persistent X is benign), back-annotate with PT-PX, and record Total Power.
#
# Each design's netlist is placed & routed ONCE; the T-sweep only re-runs the
# gate sim + PT (the netlist is identical, only the workload/window changes).
#
# Results  -> build/power_char/results.csv
# Per-step logs -> build/power_char/<design>__T<t>/{sim,power}.log, <design>/apr.log
#
# Usage:  sweeps/run_power_char.sh [design ...]      (default: all in TABLE)
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$REPO/build/power_char"
CSV="$OUT/results.csv"
mkdir -p "$OUT"

# ---- toolchain -----------------------------------------------------------
source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash 2>/dev/null
module load synopsys-lib-compiler/2022.03-SP3 synopsys-synth/2021.06-SP1 \
            primetime/2021.06-SP1 vcs/2020.12-SP2-1 \
            innovus/21.14.000 genus/21.14.000 2>/dev/null
export SYNOPSYS="${SYNOPSYS:-/usr/caen/synopsys-synth-2021.06-SP1}"
export USE_DW=1

# ---- design table --------------------------------------------------------
# name | target | top | power_bench | validator | Tdefine | Tvalues
TABLE=(
  "BP_ARRAY|TSMC22/BP_ARRAY|array_8|designs/baselines/binary_parallel/power/power_array_8.sv|validate_power_saif.py|STIM_CYCLES_N|4096"
  "BS_ARRAY|TSMC22/BS_ARRAY|array_8|designs/baselines/binary_serial/power/power_array_8.sv|validate_power_saif.py|STIM_CYCLES_N|4096"
  "UR_ARRAY|TSMC22/UR_ARRAY|array_8|designs/baselines/unary_rate/power/power_array_8.sv|validate_power_saif.py|RATE_LEN_N|64,128,256"
  "UT_ARRAY|TSMC22/UT_ARRAY|array_8|designs/baselines/unary_temporal/power/power_array_8.sv|validate_power_saif.py|RATE_LEN_N|64,128,256"
  "PAYN_SC|TSMC22/PAYN_SC|payn_array|designs/payn/power/power_payn_array.sv|validate_sc_power_saif.py|SC_T|64,128,256"
  "SC_INNER_PE|TSMC22/SC_INNER_PE|sc_inner_pe_manual_k6m16n9_ow24|designs/payn/power/power_inner_pe.sv|validate_sc_power_saif.py|SC_T|64,128,256"
)

SELECT=("$@")
want() { [ ${#SELECT[@]} -eq 0 ] && return 0; for s in "${SELECT[@]}"; do [ "$s" = "$1" ] && return 0; done; return 1; }

log() { echo "[$(basename "$0")] $*"; }
latest_run() { ls -1dt "$1"/*/ 2>/dev/null | head -1 | xargs -r basename; }

if [ ! -f "$CSV" ]; then
  echo "design,target,T,total_power_W,net_switching_W,cell_internal_W,cell_leakage_W,status,saif" > "$CSV"
fi

overall=0
for row in "${TABLE[@]}"; do
  IFS='|' read -r name target top bench validator tdef tvals <<< "$row"
  want "$name" || continue
  log "===== $name ($target) ====="
  dlog="$OUT/$name"; mkdir -p "$dlog"

  # 1) synth ---------------------------------------------------------------
  synrun=$(latest_run "$REPO/syn/build/$target")
  if [ -z "$synrun" ] || [ ! -f "$REPO/syn/build/$target/$synrun/$top.syn.v" ]; then
    log "  synth $target ..."
    make -C "$REPO" synth TARGET="$target" > "$dlog/synth.log" 2>&1
    synrun=$(latest_run "$REPO/syn/build/$target")
  fi
  if [ -z "$synrun" ] || [ ! -f "$REPO/syn/build/$target/$synrun/$top.syn.v" ]; then
    log "  SYNTH FAILED (see $dlog/synth.log)"
    echo "$name,$target,,,,,,SYNTH_FAIL," >> "$CSV"; overall=1; continue
  fi
  log "  synth run = $synrun"

  # 2) apr -----------------------------------------------------------------
  aprrun=$(latest_run "$REPO/apr/build/$target")
  if [ -z "$aprrun" ] || [ ! -f "$REPO/apr/build/$target/$aprrun/outputs/$top.apr.v" ]; then
    log "  apr $target (SYNTH_RUN=$synrun) ..."
    make -C "$REPO" apr TARGET="$target" SYNTH_RUN="$synrun" > "$dlog/apr.log" 2>&1
    aprrun=$(latest_run "$REPO/apr/build/$target")
  fi
  if [ -z "$aprrun" ] || [ ! -f "$REPO/apr/build/$target/$aprrun/outputs/$top.apr.v" ]; then
    log "  APR FAILED (see $dlog/apr.log)"
    echo "$name,$target,,,,,,APR_FAIL," >> "$CSV"; overall=1; continue
  fi
  log "  apr run = $aprrun"

  # 3) per-T gate sim + validate + PT-PX ----------------------------------
  IFS=',' read -ra TS <<< "$tvals"
  for T in "${TS[@]}"; do
    tag="${name}__T${T}"; wlog="$OUT/$tag"; mkdir -p "$wlog"
    log "  --- T=$T ---"
    saif="$REPO/build/$bench/dut.saif"
    rm -f "$saif"

    # gate-level sim (routed SDF, timing checks on) -> dut.saif
    make -C "$REPO" sim GL=apr TARGET="$target" RUN="$aprrun" \
         TB="$bench" VCS_ARGS="+define+${tdef}=${T}" \
         > "$wlog/sim.log" 2>&1
    if ! grep -q "PASS:" "$wlog/sim.log" || [ ! -f "$saif" ]; then
      log "    SIM/FUNC FAIL (see $wlog/sim.log)"
      grep -iE "FUNC-FAIL|X-FAIL|Error-|^Error|fatal" "$wlog/sim.log" | head -3
      echo "$name,$target,$T,,,,,SIM_FAIL,$saif" >> "$CSV"; overall=1; continue
    fi

    # validate + PT-PX back-annotation
    POWER_SAIF_VALIDATOR="$REPO/sweeps/$validator" \
    make -C "$REPO" power_apr TARGET="$target" RUN="$aprrun" \
         SAIF="$saif" SAIF_STRIP_PATH=Top/dut \
         > "$wlog/power.log" 2>&1
    prpt="$REPO/apr/build/$target/$aprrun/reports/power.rpt"
    if grep -qE "invalid (binary|SC) SAIF" "$wlog/power.log"; then
      log "    SAIF VALIDATION FAILED (see $wlog/power.log)"
      grep -m1 "invalid" "$wlog/power.log"
      echo "$name,$target,$T,,,,,SAIF_INVALID,$saif" >> "$CSV"; overall=1; continue
    fi
    if [ ! -s "$prpt" ]; then
      log "    PT-PX produced no report (see $wlog/power.log)"
      echo "$name,$target,$T,,,,,PT_FAIL,$saif" >> "$CSV"; overall=1; continue
    fi
    # snapshot the report for this T (it gets overwritten next T)
    cp -f "$prpt" "$wlog/power.rpt"

    tot=$(grep -m1 "Total Power" "$prpt" | grep -oE "[0-9]+\.[0-9]+e[-+][0-9]+" | head -1)
    sw=$(grep -m1 "Net Switching Power" "$prpt" | grep -oE "[0-9]+\.[0-9]+e[-+][0-9]+" | head -1)
    intl=$(grep -m1 "Cell Internal Power" "$prpt" | grep -oE "[0-9]+\.[0-9]+e[-+][0-9]+" | head -1)
    leak=$(grep -m1 "Cell Leakage Power" "$prpt" | grep -oE "[0-9]+\.[0-9]+e[-+][0-9]+" | head -1)
    log "    OK  Total=${tot} W"
    echo "$name,$target,$T,$tot,$sw,$intl,$leak,OK,$saif" >> "$CSV"
  done
done

log "campaign done. results -> $CSV"
column -t -s, "$CSV"
exit $overall
