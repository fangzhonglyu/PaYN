#!/bin/bash
set -u
cd /home/barrylyu/repos/PaYN
source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash 2>/dev/null
module load synopsys-lib-compiler/2022.03-SP3 synopsys-synth/2021.06-SP1 primetime/2021.06-SP1 vcs/2020.12-SP2-1 innovus/21.14.000 genus/21.14.000 2>/dev/null
export SYNOPSYS=/usr/caen/synopsys-synth-2021.06-SP1 USE_DW=1
ST=TSMC22/PAYN_SC_SWEEP
TB="designs/payn/power/power_payn_array.sv"
CSV=build/power_char/sc_sweep_synpwr.csv
[ -f "$CSV" ] || echo "config,K,M,N,syn_pwr_mW,syn_pJ_MAC,status" > $CSV
MAX=6

syn_cfg() {
  local K=$1 M=$2 N=$3 ; local cfg=k${K}m${M}n${N}
  local sd=syn/build/$ST/$cfg ; local L=build/power_char/synpwr_$cfg.log
  grep -q "^$cfg,.*,OK$" "$CSV" 2>/dev/null && return   # resume: skip done
  [ -f "$sd/payn_array.syn.v" ] || { echo "[$cfg] no synth netlist yet" >>"$L" 2>/dev/null; return; }
  : > "$L"
  local DEF="+define+SC_K=$K +define+SC_M=$M +define+SC_NH=$N +define+SC_NW=$N +define+SC_T=128"
  local bd=build/synpwr/$cfg ; rm -rf "$bd"
  make sim GL=syn NO_SDF=1 TARGET=$ST RUN=$cfg USE_DW=1 BUILD_DIR="$bd" TB="$TB" \
       VCS_ARGS="+delay_mode_unit +notimingcheck $DEF" >> "$L" 2>&1
  local saif=$(rg --files -uu "$bd" 2>/dev/null | awk '/\/dut\\.saif$/{print; exit}')
  local trace=$(rg --files -uu "$bd" 2>/dev/null | awk '/\/array_streaming_rtl\\.txt$/{print; exit}')
  if [ -z "$saif" ] || grep -q "X-FAIL" "$L"; then echo "$cfg,$K,$M,$N,,,SIM_FAIL" >> $CSV; return; fi
  if [ -z "$trace" ] || \
     ! python3 designs/payn/cosim/cosim_streaming.py "$trace" >> "$L" 2>&1; then
    echo "$cfg,$K,$M,$N,,,COSIM_FAIL" >> $CSV
    return
  fi
  make power TARGET=$ST RUN=$cfg SAIF="$saif" SAIF_STRIP_PATH=Top/dut >> "$L" 2>&1
  local tot=$(python3 -c "
import re
t=None
for l in open('$sd/pwr_saif.rpt'):
    if l.startswith('Total '):
        v=re.findall(r'([0-9.]+)\s*(mW|uW|W)', l)
        if v: x,u=v[-1]; t=float(x)*{'W':1000,'mW':1,'uW':0.001}[u]
print(f'{t:.4f}' if t else '')
" 2>/dev/null)
  if [ -z "$tot" ]; then echo "$cfg,$K,$M,$N,,,PWR_FAIL" >> $CSV; return; fi
  local pj=$(python3 -c "print(f'{$tot*1e-3*2.5e-9/($K*$M*$N*$N/128)*1e12:.4f}')")
  echo "$cfg,$K,$M,$N,$tot,$pj,OK" >> $CSV
  echo "[$cfg] syn ${tot}mW $pj pJ/MAC" >> "$L"
}

for K in 4 6 8; do for M in 8 16; do for N in 2 4 8; do
  syn_cfg $K $M $N &
  while [ "$(jobs -rp | wc -l)" -ge $MAX ]; do wait -n; done
done; done; done
wait
echo "[synth-pJ/MAC pass done] -> $CSV"
