#!/bin/bash
# Provenance check of the C-BSG AF + IPD variant (designs/payn/variants/signed_segmented_csa_cbsg_af_ipd).
#  1. sha256 of every source the variant copied from, against copied_from.sha256 (recorded at copy
#     time): "unchanged" or "CHANGED since the copy" (informational: the copies are snapshots; the
#     snapshot of each source is kept in build/cbsg/af_ipd/source_snapshot/).
#  2. Every RTL copy against its source snapshot after the module/guard/include renames of
#     sweeps/cbsg/af_ipd/rename_af_ipd.pl, ignoring the "// [CBSG-AF-IPD COPY]" provenance lines:
#     the rename-only copies must be identical; for the peripheral the diff (the INT bypass) is
#     written to build/cbsg/af_ipd/copies/cbsg_af_ipd_peripheral.diff and must only add lines
#     marked [AF-IPD] or touch the sc_a_bits / sc_w_bits / a_bits / w_bits assignments.
#  3. The python tool copies against their sources modulo the provenance line (gen_bp_workload.py:
#     plus its import path).
#   bash sweeps/cbsg/af_ipd/check_copies.sh     -> build/cbsg/af_ipd/copies/summary.log
set -uo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
cd "$REPO"
V=designs/payn/variants/signed_segmented_csa_cbsg_af_ipd
SNAP=build/cbsg/af_ipd/source_snapshot
OUT=build/cbsg/af_ipd/copies
mkdir -p "$OUT"
status=0
{
echo "== source hashes vs $V/copied_from.sha256"
while read -r sha path; do
    [[ "$sha" == \#* || -z "$sha" ]] && continue
    now=$(sha256sum "$path" 2>/dev/null | cut -d' ' -f1)
    snap=$(sha256sum "$SNAP/$path" 2>/dev/null | cut -d' ' -f1)
    [[ "$snap" == "$sha" ]] || { echo "SNAPSHOT MISSING/WRONG $path"; status=1; }
    if [[ "$now" == "$sha" ]]; then echo "unchanged  $path"; else echo "CHANGED since the copy (info)  $path"; fi
done < "$V/copied_from.sha256"

echo "== RTL copies vs renamed source snapshots"
strip() { grep -v '^// \[CBSG-AF-IPD COPY\]' "$1"; }
for pair in \
    "designs/payn/variants/signed_segmented_csa_cbsg_af/cbsg_af_stream_gen.sv $V/cbsg_af_ipd_stream_gen.sv" \
    "designs/payn/variants/signed_segmented_csa_bp_ipd/inner_pe_core_signed_segmented_csa_ipd.sv $V/inner_pe_core_signed_segmented_csa_cbsg_af_ipd.sv" \
    "designs/payn/variants/signed_segmented_csa_bp_ipd/inner_pe_signed_segmented_csa_bp_ipd.sv $V/inner_pe_signed_segmented_csa_cbsg_af_ipd.sv" \
    "designs/payn/variants/signed_segmented_csa_bp_ipd/inner_pe_grid_signed_segmented_csa_bp_ipd.sv $V/inner_pe_grid_signed_segmented_csa_cbsg_af_ipd.sv" \
    "designs/payn/variants/signed_segmented_csa_bp/bp_combiner.sv $V/bp_combiner_cbsg_af_ipd.sv"; do
    set -- $pair
    if diff <(perl sweeps/cbsg/af_ipd/rename_af_ipd.pl < "$SNAP/$1") <(strip "$2") > /dev/null; then
        echo "rename-only, identical  $2  <-  $1"
    else
        echo "DIFFERS  $2  <-  $1"; status=1
    fi
done
src=designs/payn/variants/signed_segmented_csa_cbsg_af/cbsg_af_peripheral.sv
diff <(perl sweeps/cbsg/af_ipd/rename_af_ipd.pl < "$SNAP/$src") <(strip "$V/cbsg_af_ipd_peripheral.sv") > "$OUT/cbsg_af_ipd_peripheral.diff"
removed=$(grep -c '^<' "$OUT/cbsg_af_ipd_peripheral.diff")
added=$(grep -c '^>' "$OUT/cbsg_af_ipd_peripheral.diff")
bad=$(grep '^[<>]' "$OUT/cbsg_af_ipd_peripheral.diff" \
      | grep -vE '\[AF-IPD\]|^> *//|^> *$|sc_a_bits|sc_w_bits|a_raw_in|w_raw_in|input logic int_mode|^< +assign [aw]_bits\[' || true)
if [[ -z "$bad" && $removed -eq 2 ]]; then
    echo "peripheral: rename + INT bypass only ($added lines added, $removed changed: the two stream assigns now drive sc_a_bits / sc_w_bits)  $V/cbsg_af_ipd_peripheral.sv"
else
    echo "peripheral: UNEXPECTED diff lines:"; echo "$bad"; status=1
fi

echo "== python tool copies"
for pair in "sweeps/int_mode/gen_bitplane_workload.py gen_bitplane_workload.py" \
            "sweeps/int_mode/bp/check_bp_trace.py check_bp_trace.py" \
            "sweeps/int_mode/bp/check_bp_power_trace.py check_bp_power_trace.py" \
            "sweeps/int_mode/bp/ipd/check_bp_ipd_grid_trace.py check_bp_ipd_grid_trace.py" \
            "sweeps/int_mode/bp/gen_bp_workload.py gen_bp_workload.py"; do
    set -- $pair
    n=$(diff <(sed 2d "sweeps/cbsg/af_ipd/$2") "$SNAP/$1" | grep -c '^[<>]')
    if [[ $n -eq 0 || ( $2 == gen_bp_workload.py && $n -eq 2 ) ]]; then
        echo "identical modulo provenance$([[ $n -eq 2 ]] && echo ' and the import path')  sweeps/cbsg/af_ipd/$2  <-  $1"
    else
        echo "DIFFERS  sweeps/cbsg/af_ipd/$2  <-  $1"; status=1
    fi
done
echo "== README sha256 table vs copied_from.sha256"
# Every row "| <16 hex>... | `path` |" of the README Sources table must be the prefix of that path's
# full hash in copied_from.sha256, and every recorded source must have a row.
nrow=0; nbad=0
while read -r pre path; do
    nrow=$((nrow + 1))
    full=$(awk -v p="$path" '$2 == p {print $1}' "$V/copied_from.sha256")
    if [[ -z "$full" || "$full" != "$pre"* ]]; then
        echo "README PREFIX WRONG  $pre  $path  (copied_from.sha256: ${full:-missing})"; nbad=$((nbad + 1))
    fi
done < <(sed -nE 's/^\| ([0-9a-f]{16})\.\.\. \| `([^`]+)`.*/\1 \2/p' "$V/README.md")
nsrc=$(grep -cvE '^#|^$' "$V/copied_from.sha256")
if (( nbad == 0 && nrow == nsrc )); then
    echo "README table: $nrow rows, every prefix matches copied_from.sha256 ($nsrc sources)"
else
    echo "README table: $nrow rows for $nsrc sources, $nbad wrong prefixes"; status=1
fi
echo "check_copies: $([[ $status == 0 ]] && echo PASS || echo FAIL)"
} | tee "$OUT/summary.log"
grep -q 'check_copies: PASS' "$OUT/summary.log"
