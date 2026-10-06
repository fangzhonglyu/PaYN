#!/bin/bash
# Post-synthesis area classes and timing probes for TSMC22/PAYN_SC_CSA_CBSG_AF_IPD and, with the SAME probe
# (sweeps/cbsg/af_ipd/dc_af_ipd_probe.tcl), for the three reference netlists, then the block-by-block table.
# Adapted from sweeps/cbsg/af/run_syn_reports.sh (unchanged).
#   bash sweeps/cbsg/af_ipd/run_syn_reports.sh
#   AFIPD_RUN (default cbsg_af_ipd_20261005)  syn/build/TSMC22/PAYN_SC_CSA_CBSG_AF_IPD/<run>
#   AF_RUN    (default cbsg_af_20261005)      syn/build/TSMC22/PAYN_SC_CSA_CBSG_AF/<run>
#   IPD_RUN   (default csa_bp_ipd_20261004)   syn/build/TSMC22/PAYN_SC_CSA_BP_IPD/<run>
#   CSA_RUN   (default csa_20261002)          syn/build/TSMC22/PAYN_SC_CSA/<run>
# dc_shell reads each run's written netlist + SDC in build/cbsg/af_ipd/syn/<target>_<run>/, never in a
# synthesis run directory (the reference runs are read only).
# Outputs: build/cbsg/af_ipd/syn/<target>_<run>/probe.rpt, build/cbsg/af_ipd/syn/area_breakdown.{txt,json},
#          build/cbsg/af_ipd/syn/timing_summary.txt
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
AFIPD_RUN=${AFIPD_RUN:-cbsg_af_ipd_20261005}
AF_RUN=${AF_RUN:-cbsg_af_20261005}
IPD_RUN=${IPD_RUN:-csa_bp_ipd_20261004}
CSA_RUN=${CSA_RUN:-csa_20261002}
source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash
module load synopsys-lib-compiler/2022.03-SP3
module load synopsys-synth/2021.06-SP1
module load primetime/2021.06-SP1
module load vcs/2020.12-SP2-1
module load innovus/21.14.000
module load genus/21.14.000
export ASTRAEA_FLOW=${ASTRAEA_FLOW:-$(cd "$REPO/../ASTRAEA" && pwd)}
export DESIGN_ROOT=$REPO SNPSLMD_QUEUE=true
OUTROOT="$REPO/build/cbsg/af_ipd/syn"

probe() {   # target run kind
    local tgt=$1 run=$2 kind=$3 dir out
    dir="$REPO/syn/build/TSMC22/$tgt/$run"
    [[ -s "$dir/TARGET_DEF" ]] || { echo "no synthesis run at $dir" >&2; return 2; }
    out="$OUTROOT/${tgt}_${run}"
    mkdir -p "$out"
    (
        set -a; . "$dir/TARGET_DEF"; set +a
        export PROBE_RUN_DIR=$dir PROBE_KIND=$kind
        cd "$out"
        dc_shell -f "$REPO/sweeps/cbsg/af_ipd/dc_af_ipd_probe.tcl" > probe.rpt 2>&1
    )
    if grep -nE '^Error' "$out/probe.rpt"; then echo "probe errors in $out/probe.rpt" >&2; return 1; fi
    echo "$out/probe.rpt"
}

if [[ -z "${SKIP_PROBE:-}" ]]; then
    pids=()
    probe PAYN_SC_CSA_CBSG_AF_IPD "$AFIPD_RUN" afipd & pids+=("$!")
    probe PAYN_SC_CSA_CBSG_AF "$AF_RUN" af & pids+=("$!")
    probe PAYN_SC_CSA_BP_IPD "$IPD_RUN" ipd & pids+=("$!")
    probe PAYN_SC_CSA "$CSA_RUN" csa & pids+=("$!")
    st=0
    for p in "${pids[@]}"; do wait "$p" || st=1; done
    (( st == 0 )) || { echo "a probe failed" >&2; exit 1; }
fi
python3 "$REPO/sweeps/cbsg/af_ipd/area_breakdown.py" \
    --afipd "$REPO/syn/build/TSMC22/PAYN_SC_CSA_CBSG_AF_IPD/$AFIPD_RUN" \
    --afipd-probe "$OUTROOT/PAYN_SC_CSA_CBSG_AF_IPD_${AFIPD_RUN}/probe.rpt" \
    --af "$REPO/syn/build/TSMC22/PAYN_SC_CSA_CBSG_AF/$AF_RUN" \
    --af-probe "$OUTROOT/PAYN_SC_CSA_CBSG_AF_${AF_RUN}/probe.rpt" \
    --ipd "$REPO/syn/build/TSMC22/PAYN_SC_CSA_BP_IPD/$IPD_RUN" \
    --ipd-probe "$OUTROOT/PAYN_SC_CSA_BP_IPD_${IPD_RUN}/probe.rpt" \
    --csa "$REPO/syn/build/TSMC22/PAYN_SC_CSA/$CSA_RUN" \
    --csa-probe "$OUTROOT/PAYN_SC_CSA_${CSA_RUN}/probe.rpt" \
    --json "$OUTROOT/area_breakdown.json" | tee "$OUTROOT/area_breakdown.txt"
# Timing table: one row per probe label, slack per netlist (and the AF-IPD path).
python3 - "$OUTROOT" "$AFIPD_RUN" "$AF_RUN" "$IPD_RUN" "$CSA_RUN" <<'PY' | tee "$OUTROOT/timing_summary.txt"
import re, sys
from pathlib import Path
root, afipd, af, ipd, csa = sys.argv[1:]
cols = [("CSA", f"PAYN_SC_CSA_{csa}"), ("AF", f"PAYN_SC_CSA_CBSG_AF_{af}"),
        ("IPD", f"PAYN_SC_CSA_BP_IPD_{ipd}"), ("AF-IPD", f"PAYN_SC_CSA_CBSG_AF_IPD_{afipd}")]
def parse(p):
    text = Path(p).read_text(errors="replace")
    out, order = {}, []
    parts = re.split(r"^PROBE_PATH (.*)$", text, flags=re.M)
    for label, body in zip(parts[1::2], parts[2::2]):
        order.append(label)
        if label.startswith("combinational loops"):
            out[label] = ("no loops" if "No loops." in body else "LOOPS", "", "")
            continue
        if label.startswith("check_timing"):
            w = [l for l in body.splitlines() if l.startswith("Warning")]
            out[label] = (f"{len(w)} warnings" if w else "clean", "; ".join(sorted(set(w)))[:300], "")
            continue
        if label.startswith("top-10"):
            continue
        if body.lstrip().startswith("PROBE_NA") or "No paths." in body:
            out[label] = ("-", "", "")
            continue
        sp = re.search(r"Startpoint: (\S+)", body)
        ep = re.search(r"Endpoint: (\S+)", body)
        arr = re.search(r"data arrival time\s+(-?[0-9.]+)", body)
        sl = re.search(r"slack \((?:MET|VIOLATED)\)\s+(-?[0-9.]+)", body)
        out[label] = (sl[1] if sl else "?", f"{sp[1] if sp else '?'} -> {ep[1] if ep else '?'}",
                      arr[1] if arr else "?")
    return out, order
res = {}
order = None
for name, d in cols:
    res[name], o = parse(f"{root}/{d}/probe.rpt")
    if name == "AF-IPD":
        order = o
print("DC slack (ns) per probe; tt 0.80 V 25 C, ideal clock, 2.5 ns, 1.25 ns input delay; '-' = no such path")
print(f"{'probe':84s} " + " ".join(f"{n:>7s}" for n, _ in cols) + "  | AF-IPD path (arrival)")
for lab in order:
    if lab.startswith("top-10"):
        continue
    row = [res[n].get(lab, ("-", "", ""))[0] for n, _ in cols]
    v = res["AF-IPD"].get(lab, ("-", "", ""))
    extra = f"{v[1]} ({v[2]} ns)" if v[2] else v[1]
    print(f"{lab[:84]:84s} " + " ".join(f"{x:>7s}" for x in row) + f"  | {extra}")
PY
