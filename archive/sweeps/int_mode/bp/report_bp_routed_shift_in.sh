#!/bin/bash
# Routed setup slack of shift_in on existing BP routes (Innovus, on a copy of
# each route's final database; the route directories are only read).
#
# Background: the per-PE lap enable (csa_bp_20261004_lap) puts one OR2 on
# shift_in -> tile clock-gate enable and shift-mux select (DC, zero wire load:
# +30 ps).  That RTL has not been routed.  This reports how much routed slack
# shift_in had on the csa_bp_20261003b layouts, which depends on the IO pin
# placement, so the OR's cost can be judged against it.
#
#   bash sweeps/int_mode/bp/report_bp_routed_shift_in.sh [route_run ...]
# Default routes: csa_bp_20261003b_distguide_spp_fixed (floating IO pins) and
# csa_bp_20261003b_distguide_spp_pins (pinned IO pins).
# Also used on the lap-enable routes (csa_bp_20261004_lap_distguide_spp_pins,
# ..._spp_fixed); every run also reports the worst path from the ring_q flop
# (u_pe/ring_q_reg) when the route has one.
# Reports: build/rtl_preflight/bp_paths/routed_shift_in/<route_run>/
set -uo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
cd "$REPO"
source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash
module load synopsys-lib-compiler/2022.03-SP3
module load synopsys-synth/2021.06-SP1
module load primetime/2021.06-SP1
module load vcs/2020.12-SP2-1
module load innovus/21.14.000
module load genus/21.14.000
TOP=payn_array_signed_segmented_csa_bp
ROUTES=("$@")
(( ${#ROUTES[@]} )) || ROUTES=(csa_bp_20261003b_distguide_spp_fixed csa_bp_20261003b_distguide_spp_pins)

slack() {   # report -> "slack  beginpoint -> endpoint" of its first path
    awk '/^Endpoint:/{e=$2} /^Beginpoint:/{b=$2} /= Slack Time/{printf "%+.3f ns  %s -> %s\n", $4, b, e; exit}' "$1"
}

status=0
for r in "${ROUTES[@]}"; do
    rd="$REPO/apr/build/TSMC22/PAYN_SC_CSA_BP/$r"
    od="$REPO/build/rtl_preflight/bp_paths/routed_shift_in/$r"
    [[ -d $rd/$TOP.final.enc.dat ]] || { echo "$r: no final database in $rd"; status=1; continue; }
    rm -rf "$od"; mkdir -p "$od/run"
    cp -r "$rd/$TOP.final.enc.dat" "$od/run/"
    (cd "$od/run" && DB="$od/run/$TOP.final.enc.dat" OUT_DIR="$od" \
        innovus -no_gui -batch -files "$REPO/sweeps/int_mode/bp/innovus_routed_shift_in.tcl" \
        > "$od/innovus.out" 2>&1) || { echo "$r: innovus failed ($od/innovus.out)"; status=1; continue; }
    rm -rf "$od/run/$TOP.final.enc.dat"
    {
        echo "== $r"
        echo "route setup.rpt worst : $(slack "$rd/reports/setup.rpt")"
        echo "restored worst        : $(slack "$od/worst.rpt")"
        echo "worst from shift_in   : $(slack "$od/from_shift_in.rpt")"
        echo "shift_in -> clock gate: $(slack "$od/from_shift_in_to_clock_gate.rpt")"
        echo "worst from reset      : $(slack "$od/from_reset.rpt")"
        echo "worst from int_mode   : $(slack "$od/from_int_mode.rpt")"
        [[ ! -s "$od/from_ring_q.rpt" ]] || echo "worst from ring_q     : $(slack "$od/from_ring_q.rpt")"
    } | tee "$od/summary.txt"
done
exit $status
