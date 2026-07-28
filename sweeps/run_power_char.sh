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

# ---- flow knobs ----------------------------------------------------------
# Power-optimization passes adopted from the bitmod fork of this flow.  They are
# opt-in in ASTRAEA and enabled here for EVERY design so the table stays
# apples-to-apples: whatever these passes are worth, every row gets it.
#
#   TSMC22_HPK            supplies the multi-bit sequentials that
#                         APR_MULTIBIT_FLOP_OPT re-banks.  Previously set only on
#                         PAYN_SC, which made the library asymmetric across rows.
#   APR_MULTIBIT_FLOP_OPT placement-driven flop banking/debanking.
#   APR_OPT_POWER         optPower -allowResizing -effortLevel high at postCTS
#                         and postRoute.
#   SYN_WORKLOAD_SAIF     synthesize against the measured workload: an RTL run of
#                         the same power bench produces a SAIF that is annotated
#                         before compile_ultra, so DC's clock gating and operand
#                         isolation optimize for real activity instead of the
#                         generic 0.5/0.25 input hint.
#
# Set any of these to 0 to reproduce the pre-adoption numbers.
export TSMC22_HPK=${TSMC22_HPK:-1}
export APR_MULTIBIT_FLOP_OPT=${APR_MULTIBIT_FLOP_OPT:-1}
export APR_OPT_POWER=${APR_OPT_POWER:-1}
SYN_WORKLOAD_SAIF=${SYN_WORKLOAD_SAIF:-1}
# Re-baselining with a changed recipe must not reuse netlists built by the old
# one.  FRESH=1 forces a new synth + APR run per design instead of picking up
# the latest existing one.
FRESH=${FRESH:-0}
# The RTL SAIF needs SystemVerilog net monitoring, which is an LCA feature.
# ASTRAEA's Makefile passes -lca on every VCS invocation (LCA_FLAG), so nothing
# extra is required here; kept as a hook in case a site has to drop it.
RTL_SAIF_VCS_ARGS=""

# ---- design table --------------------------------------------------------
# name | target | top | power_bench | validator | Tdefine | Tvalues
TABLE=(
  "BP_ARRAY|TSMC22/BP_ARRAY|array_8|designs/baselines/binary_parallel/power/power_array_8.sv|validate_power_saif.py|STIM_CYCLES_N|4096"
  "BP_ARRAY_ASYM|TSMC22/BP_ARRAY_ASYM|array_8_asym_corr_v2|designs/baselines/binary_parallel/power/power_array_8_asym_corr_v2.sv|validate_power_saif.py|STIM_CYCLES_N|4096"
  "BS_ARRAY|TSMC22/BS_ARRAY|array_8|designs/baselines/binary_serial/power/power_array_8.sv|validate_power_saif.py|STIM_CYCLES_N|4096"
  "BOS_ARRAY|TSMC22/BOS_ARRAY|binary_os_array|designs/baselines/binary_os/power/power_binary_os_array.sv|validate_power_saif.py|STIM_CYCLES_N|4096"
  "BOS_ARRAY_ASYM|TSMC22/BOS_ARRAY_ASYM|binary_os_array_asym|designs/baselines/binary_os/power/power_binary_os_array_asym.sv|validate_power_saif.py|STIM_CYCLES_N|4096"
  "UR_ARRAY|TSMC22/UR_ARRAY|array_8|designs/baselines/unary_rate/power/power_array_8.sv|validate_power_saif.py|RATE_LEN_N|64,128,256"
  "UT_ARRAY|TSMC22/UT_ARRAY|array_8|designs/baselines/unary_temporal/power/power_array_8.sv|validate_power_saif.py|RATE_LEN_N|64,128,256"
  "PAYN_SC|TSMC22/PAYN_SC|payn_array|designs/payn/power/power_payn_array.sv|validate_sc_power_saif.py|SC_T|64,128,256"
  "SC_INNER_PE|TSMC22/SC_INNER_PE|sc_inner_pe_manual_k6m16n9_ow24|designs/payn/power/power_inner_pe.sv|validate_sc_power_saif.py|SC_T|64,128,256"
  # bitmod migrated baselines.  BITMOD_TILE is the 64 MAC/cycle throughput match;
  # BITMOD_ARRAY is the whole design at 1024 MAC/cycle (16x the cells, so its APR
  # is correspondingly longer).  See designs/baselines/bitmod/README.md.
  "BITMOD_TILE|TSMC22/BITMOD_TILE|tile|designs/baselines/bitmod/power/power_bitmod_tile.sv|validate_power_saif.py|STIM_CYCLES_N|4096"
  "BITMOD_ARRAY|TSMC22/BITMOD_ARRAY|Raptor_Lake_HX|designs/baselines/bitmod/power/power_bitmod_array.sv|validate_power_saif.py|STIM_CYCLES_N|4096"
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

  # 0) workload SAIF for synthesis ----------------------------------------
  # An RTL run of the same power bench, at the first T of the sweep, so DC
  # optimizes against the activity we are about to measure.  Cheap relative to
  # synthesis, and skipped entirely when SYN_WORKLOAD_SAIF=0.
  unset SYN_SAIF_FILE SYN_SAIF_INSTANCE
  if [ "$SYN_WORKLOAD_SAIF" != "0" ]; then
    IFS=',' read -ra _t0 <<< "$tvals"
    sbd="build/syn_saif/$name"
    log "  rtl workload SAIF (${tdef}=${_t0[0]}) ..."
    make -C "$REPO" --no-print-directory sim GL= TARGET= TOP=Top TB="$bench" \
         BUILD_DIR="$sbd" VCS_ARGS="$RTL_SAIF_VCS_ARGS +define+${tdef}=${_t0[0]}" \
         > "$dlog/syn_saif.log" 2>&1
    ssaif="$REPO/$sbd/$bench/dut.saif"
    if [ ! -s "$ssaif" ] || ! grep -q "(INSTANCE " "$ssaif"; then
      log "  SYNTH SAIF EMPTY/MISSING (see $dlog/syn_saif.log)"
      echo "$name,$target,,,,,,SYN_SAIF_FAIL," >> "$CSV"; overall=1; continue
    fi
    export SYN_SAIF_FILE="$ssaif"
    export SYN_SAIF_INSTANCE="Top/dut"
    log "  synth SAIF = $ssaif"
  fi

  # 1) synth ---------------------------------------------------------------
  synrun=$(latest_run "$REPO/syn/build/$target")
  if [ "$FRESH" = "1" ] || [ -z "$synrun" ] || \
     [ ! -f "$REPO/syn/build/$target/$synrun/$top.syn.v" ]; then
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
  if [ "$FRESH" = "1" ] || [ -z "$aprrun" ] || \
     [ ! -f "$REPO/apr/build/$target/$aprrun/outputs/$top.apr.v" ]; then
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
    if [ "$name" = PAYN_SC ] || [ "$name" = SC_INNER_PE ]; then
      trace="$REPO/build/$bench/array_streaming_rtl.txt"
      if [ ! -f "$trace" ] || \
         ! python3 "$REPO/designs/payn/cosim/cosim_streaming.py" "$trace" \
              >> "$wlog/sim.log" 2>&1; then
        log "    STREAMING COSIM FAIL (see $wlog/sim.log)"
        echo "$name,$target,$T,,,,,COSIM_FAIL,$saif" >> "$CSV"
        overall=1
        continue
      fi
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
