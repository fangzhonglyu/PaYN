#!/bin/bash
# A/B of the [CBSG-AF-CONTRACT] cut-block fix in payn_array_signed_segmented_csa_cbsg_af_ipd.sv
# (review finding 1, 2026-10-05).  The check used u_peripheral.a_len_q, which INT-mode A loads also load
# with the don't-care a_len_in; it now uses sc_a_len, the L of the last SC-edge A load.
#   pre-fix: the top as it was before the fix, snapshot in build/cbsg/af_ipd/review_fix/prefix_inc/
#            (sha256 in build/cbsg/af_ipd/review_fix/prefix_sha256.txt), put ahead of designs/ on +incdir;
#   fixed:   the current top.
# Same benches on both:
#   (1) the reviewer's directed bench sweeps/cbsg/af_ipd/tb_review_cutblock.sv (SC block of C cycles,
#       INT zero-load with a_len_in = L_int and rng_en low, INT MACs and drain, SC block on E_END+2;
#       drains compared with an AF top), L_int in {0,16,32,128,255} x C in {1,2,7,8};
#   (2) the new switch-matrix cases of sweeps/cbsg/af_ipd/run_rtl_checks.sh (same items and plusargs).
# Expected: pre-fix counts contract errors in the legal runs (L_int > 16*(C+1), and the switch positives)
# and misses the cut-across-INT negative (no "cuts a block"); fixed: 0 in every legal run, drains equal
# to the AF top, and the negative flagged with "cuts a block".
#   bash sweeps/cbsg/af_ipd/review_fix_ab.sh    -> build/cbsg/af_ipd/review_fix/ab_summary.log
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
export PYTHONDONTWRITEBYTECODE=1
R=build/cbsg/af_ipd/review_fix
OLDINC=$R/prefix_inc
TOPF=payn/variants/signed_segmented_csa_cbsg_af_ipd/payn_array_signed_segmented_csa_cbsg_af_ipd.sv
GEN=sweeps/cbsg/af_ipd/gen_bp_workload.py
[[ -f "$OLDINC/$TOPF" ]] || { echo "pre-fix snapshot missing: $OLDINC/$TOPF"; exit 1; }
sha256sum -c --quiet <(grep "$OLDINC" "$R/prefix_sha256.txt") || { echo "pre-fix snapshot changed"; exit 1; }

comp() {   # build_dir tb top inc_first(- or dir)
    local b=$1 tb=$2 top=$3 inc=$4
    local -a pre=()
    [[ "$inc" == - ]] || pre=("+incdir+$inc")
    rm -rf "$b"; mkdir -p "$b"
    vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca -debug_access+pp "${pre[@]}" +incdir+designs \
        -assert svaext -timescale=1ns/1ps -o "$b/simv" -Mdir="$b/obj" \
        -y "$SYNOPSYS/dw/sim_ver" +libext+.v+ +incdir+"$SYNOPSYS/dw/sim_ver" \
        "$tb" -top "$top" > "$b/compile.log" 2>&1 || { echo "compile FAILED: $b/compile.log"; return 1; }
    # which top file the build parsed
    if [[ "$inc" == - ]]; then
        grep -q "designs/$TOPF" "$b/compile.log" || { echo "$b did not parse designs/$TOPF"; return 1; }
    else
        grep -q "$inc/$TOPF" "$b/compile.log" || { echo "$b did not parse $inc/$TOPF"; return 1; }
    fi
}

pids=()
for v in old new; do
    inc=-; [[ $v == old ]] && inc=$OLDINC
    comp "$R/build_dir_$v" sweeps/cbsg/af_ipd/tb_review_cutblock.sv TbReviewCutBlock "$inc" & pids+=("$!")
    comp "$R/build_int_$v" designs/payn/tb/test_payn_array_cbsg_af_ipd.sv Top "$inc" & pids+=("$!")
done
st=0; for p in "${pids[@]}"; do wait "$p" || st=1; done
(( st == 0 )) || exit 1

{
echo "review fix A/B, $(date '+%F %T'): pre-fix top $(grep "$OLDINC" "$R/prefix_sha256.txt" | cut -c1-16)..., fixed top $(sha256sum "designs/$TOPF" | cut -c1-16)..."
echo "== (1) directed bench (tb_review_cutblock.sv): contract_errors pre-fix / fixed, AF top, drains vs AF top"
mkdir -p "$R/dirruns"
for L in 0 16 32 128 255; do
    for C in 1 2 7 8; do
        line=""
        for v in old new; do
            log="$R/dirruns/${v}_L${L}_C${C}.log"
            (cd "$R/dirruns" && "$REPO/$R/build_dir_$v/simv" +LEN_INT=$L +C=$C > "${v}_L${L}_C${C}.log" 2>&1)
            ce=$(grep -oE 'AF-IPD contract_errors [0-9]+' "$log" | awk '{print $3}')
            ae=$(grep -oE 'AF contract_errors [0-9]+' "$log" | tail -1 | awk '{print $3}')
            dd=$(grep -oE 'drains differing from the AF top: [0-9]+ of [0-9]+' "$log" | sed 's/drains differing from the AF top: //')
            line+=" $v: contract ${ce:-?} (AF ${ae:-?}), drains differing ${dd:-?};"
        done
        legal_flag=$(( L > 16 * (C + 1) && C < 8 ))
        echo "L_int=$L C=$C (pre-fix false positive expected: $legal_flag):$line"
    done
done
echo "== (2) switch cases of run_rtl_checks.sh on both tops"
# The runner's @ALL construction.
cfgs=("8:8:256:1:8:0:0:1" "8:4:384:1:8:1:1:0" "4:4:256:2:8:2:0:1" "8:8:128:1:16:3:1:1" "4:4:384:2:8:0:1:0" "8:4:128:1:8:0:0:0")
all=""; k=0
for c in build/cbsg/golden/*/ build/cbsg/af_ipd/golden_extra/*/ build/cbsg/af_ipd/golden_rv/*/; do
    all+="$(basename "$c") i:${cfgs[$((k % 6))]}:uniform:$((100 + k)) "; k=$((k + 1))
done
while IFS='|' read -r label flags items; do
    label=$(echo $label); flags=$(echo $flags); items=$(echo $items)
    [[ -n "$label" ]] || continue
    [[ "$items" == @ALL ]] && items=$all
    for v in old new; do
        dir="$R/switch/$v/$label"; rm -rf "$dir"; mkdir -p "$dir"
        seq=(); n=0
        for it in $items; do
            if [[ $it == i:* ]]; then
                IFS=: read -ra p <<< "$it"
                mkdir -p "$dir/i$n"
                python3 "$GEN" --ba "${p[1]}" --bw "${p[2]}" --L "${p[3]}" --mrows "${p[4]}" --ncols "${p[5]}" \
                    --dist "${p[9]}" --seed "${p[10]}" --out-dir "$dir/i$n" > "$dir/i$n/gen.log"
                echo "${p[1]} ${p[2]} ${p[3]} ${p[4]} ${p[5]} ${p[6]} ${p[7]} ${p[8]}" > "$dir/i$n/bpt_cfg.txt"
                seq+=("int:$REPO/$dir/i$n"); n=$((n + 1))
            else
                for base in build/cbsg/golden build/cbsg/af_ipd/golden_extra build/cbsg/af_ipd/golden_rv; do
                    [[ -d "$base/$it" ]] && seq+=("sc:$REPO/$base/$it")
                done
            fi
        done
        plus=(); IFS=, read -ra fl <<< "$flags"; for x in "${fl[@]}"; do plus+=("+$x"); done
        (cd "$dir" && "$REPO/$R/build_int_$v/simv" +MODE=switch "+SWITCH=$(IFS=,; echo "${seq[*]}")" "${plus[@]}" > sim.log 2>&1)
        verdict=$(grep -m1 -oE '^(PASS|FAIL): CBSG AF-IPD switch bench' "$dir/sim.log" | cut -c1-4)
        con=$(grep -m1 '^RESULT' "$dir/sim.log" | grep -oE 'contract [0-9]+' | awk '{print $2}')
        cut=$(grep -c 'cuts a block' "$dir/sim.log")
        chk=$(grep -m1 -oE '^\[CHECK\] [0-9]+ of [0-9]+' "$dir/sim.log" | sed 's/\[CHECK\] //')
        echo "$label [$v]: ${verdict:-NONE}, contract ${con:-?}, 'cuts a block' messages $cut, drained wrong ${chk:-0}"
    done
done <<'EOF'
sw_len_dc_hold | INT_JUNK,RNG_LOW_IDLE,INT_LEN_DC=255 | rv_c1_chain i:8:8:256:1:8:0:0:1:uniform:71 af_perhead i:4:4:256:2:8:0:0:0:uniform:72 af_uL_001_032 i:8:4:256:1:8:2:0:1:uniform:73 perhead_64 i:8:8:128:1:8:0:0:1:uniform:74 plain_u97 i:4:4:128:2:8:1:0:1:uniform:75 calls_prot
sw_len_dc128_gap1 | RNG_LOW_IDLE,INT_LEN_DC=128,SW_GAP=1 | rv_c1_chain i:8:8:256:1:8:0:0:1:uniform:76 af_uL_001_032 i:8:8:256:1:8:3:0:0:uniform:77 af_perhead
all_interleaved_len_dc | INT_JUNK,RNG_LOW_IDLE,INT_LEN_DC=255,SEED=6 | @ALL
neg_sw_cut_across_int | NEG_SHORT_LAST=2,RNG_LOW_IDLE | plain_u128 i:8:8:256:1:8:0:0:1:uniform:78 plain_u97
EOF
} | tee "$R/ab_summary.log"
