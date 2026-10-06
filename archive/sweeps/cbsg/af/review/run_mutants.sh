#!/bin/bash
# Mutation test of the AF functional bench (adversarial review; not part of run_rtl_checks.sh).
# Each mutant is a copy of designs/payn/variants/signed_segmented_csa_cbsg_af with one plausible RTL bug,
# placed under build/cbsg/af/review/mut/<name>/payn/variants/... and found first through +incdir, so the
# unmodified bench (designs/payn/tb/test_payn_array_cbsg_af.sv) compiles against it.  Every mutant must make
# the bench FAIL on the shipped + extra + review golden cases chained, in at least one of three runs: plain
# (slice_start and the drain-derived restart both active), +NO_SLICE_START (drains alone) and
# +KILL_DRAIN_RESET (slice_start alone).  A survivor is either equivalent or a coverage gap.
# Summary: build/cbsg/af/review/mutants_summary.log
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)
cd "$REPO"
source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash
module load synopsys-synth/2021.06-SP1
module load vcs/2020.12-SP2-1
OUT=build/cbsg/af/review/mut
SRC=designs/payn/variants/signed_segmented_csa_cbsg_af
mkdir -p "$OUT"
CASES=$(for d in build/cbsg/golden/*/ build/cbsg/af/golden_extra/*/ build/cbsg/af/golden_rv/*/; do printf '%s,' "$REPO/${d%/}"; done)
CASES=${CASES%,}

# name | file | python replace (old ||| new)
MUTANTS=$(cat <<'EOF'
enc_phase_norev|cbsg_af_peripheral.sv|assign mask = {LANE_BITS, phase[0], phase[1], phase[2], 2'b00};|||assign mask = {LANE_BITS, phase[2], phase[1], phase[0], 2'b00};
enc_lane_norev|cbsg_af_peripheral.sv|localparam logic [2:0] LANE_BITS = {LANE[0], LANE[1], LANE[2]};|||localparam logic [2:0] LANE_BITS = LANE[2:0];
enc_ge|cbsg_af_peripheral.sv|8'(b_low > {1'b0, c})|||8'(b_low >= {1'b0, c})
therm_le|cbsg_af_peripheral.sv|(4'(lane) < ka[3:0])|||(4'(lane) <= ka[3:0])
therm_cyc3|cbsg_af_peripheral.sv|assign ka_hi_gt = cyc < ka[7:4];|||assign ka_hi_gt = {1'b0, cyc[2:0]} < ka[7:4];
w_lane_norev|cbsg_af_peripheral.sv|((depth & 1) << 6) | (((depth >> 1) & 1) << 5) |
                (((depth >> 2) & 1) << 4));|||(depth << 4));
w_ge|cbsg_af_peripheral.sv|w_binary_q[(col*K + depth)*WIDTH +: WIDTH] >
                    {1'b0, threshold};|||w_binary_q[(col*K + depth)*WIDTH +: WIDTH] >=
                    {1'b0, threshold};
gen_phase_norev|cbsg_af_stream_gen.sv|bitrev3 = {x[0], x[1], x[2]};|||bitrev3 = x;
gen_start_oldphase|cbsg_af_stream_gen.sv|assign start_high = cycle_word(3'd0) ^ {3'b000, bitrev3(start_phase), 2'b00};|||assign start_high = cycle_word(3'd0) ^ {3'b000, bitrev3(phase_q), 2'b00};
gen_no_dv3|cbsg_af_stream_gen.sv|cycle_word = c[0] ? dv_k(3) : 8'h00;|||cycle_word = 8'h00;
gen_keep_bit0|cbsg_af_stream_gen.sv|words_q[m] <= TW'((next_high ^ lane_word(m)) >> 1);|||words_q[m] <= TW'(next_high ^ lane_word(m));
gen_no_phase_reset|cbsg_af_stream_gen.sv|assign start_phase = slice_reset ? 3'd0 : phase_q + 3'd1;|||assign start_phase = phase_q + 3'd1;
gen_ignore_slice_start|cbsg_af_stream_gen.sv|assign slice_reset = slice_start || drain_seen;|||assign slice_reset = drain_seen;
gen_no_drain_reset|cbsg_af_stream_gen.sv|assign slice_reset = slice_start || drain_seen;|||assign slice_reset = slice_start;
gen_drain_tail_counts|cbsg_af_stream_gen.sv|assign drain_edge = shift_in && !block_start_q;|||assign drain_edge = shift_in;
gen_pending_no_reset|cbsg_af_stream_gen.sv|block_start_q <= 1'b0;
            slice_pending_q <= 1'b1;|||block_start_q <= 1'b0;
            slice_pending_q <= 1'b0;
gen_pending_set_wins|cbsg_af_stream_gen.sv|if (block_start)
                slice_pending_q <= 1'b0;
            else if (drain_edge)
                slice_pending_q <= 1'b1;|||if (drain_edge)
                slice_pending_q <= 1'b1;
            else if (block_start)
                slice_pending_q <= 1'b0;
gen_pending_not_used|cbsg_af_stream_gen.sv|assign drain_seen = slice_pending_q || drain_edge;|||assign drain_seen = drain_edge;
gen_idle_wrap|cbsg_af_stream_gen.sv|assign advance = rng_en && !cyc_q[3];|||assign advance = rng_en;
enc_l_alias|cbsg_af_peripheral.sv|.len(a_len_q[row*WIDTH +: WIDTH]),|||.len(a_len_q[0 +: WIDTH]),
EOF
)

compile_run() {   # name
    local name=$1 m=$OUT/$1
    vcs -sverilog +vc -Mupdate -line -full64 -xprop=tmerge -lca -debug_access+pp -assert svaext \
        +incdir+"$m" +incdir+designs -timescale=1ns/1ps -o "$m/simv" -Mdir="$m/obj" \
        -y "$SYNOPSYS/dw/sim_ver" +libext+.v+ +incdir+"$SYNOPSYS/dw/sim_ver" \
        designs/payn/tb/test_payn_array_cbsg_af.sv -top Top > "$m/compile.log" 2>&1 \
        || { echo "$name: COMPILE FAILED (see $m/compile.log)"; return; }
    local cfg plus log tags t killed=0 err=0 res=()
    for cfg in plain NO_SLICE_START KILL_DRAIN_RESET; do
        plus=(); [[ $cfg != plain ]] && plus=("+$cfg")
        log="$REPO/$m/sim_$cfg.log"
        (cd "$m" && ./simv "+CASES=$CASES" "${plus[@]}" > "$log" 2>&1) || true
        tags=""
        for t in CHECK BLOCK KA PHASE CONTRACT; do grep -q "^\[$t\] [0-9]" "$log" && tags+=" $t"; done
        if grep -q '^FAIL: CBSG AF bench' "$log"; then
            killed=1; res+=("$cfg killed (tags:$tags; $(grep -E '^\[CHECK\] [0-9]' "$log" || echo 'drains all match'))")
        elif grep -q '^PASS: CBSG AF bench' "$log"; then
            res+=("$cfg passes")
        else
            err=1; res+=("$cfg ERROR ($(grep -m2 -E 'Error|FATAL|fatal' "$log" | tr '\n' ';'))")
        fi
    done
    local IFS='|'
    if (( killed )); then echo "$name: KILLED [${res[*]}]";
    elif (( err )); then echo "$name: ERROR [${res[*]}]";
    else echo "$name: SURVIVED [${res[*]}]"; fi
}

python3 - "$SRC" "$OUT" <<PY
import sys, pathlib, shutil
src, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
spec = """$MUTANTS"""
entries, cur = [], None
for line in spec.split("\n"):
    if "|" in line and line.split("|")[0] and "|||" not in line.split("|")[0] and len(line.split("|")) >= 3 and not line.startswith(" "):
        name, f, rest = line.split("|", 2)
        cur = [name, f, rest]
        entries.append(cur)
    else:
        cur[2] += "\n" + line
for name, f, rest in entries:
    old, new = rest.split("|||")
    d = out / name / "payn/variants/signed_segmented_csa_cbsg_af"
    if d.exists():
        shutil.rmtree(d)
    d.mkdir(parents=True)
    for p in src.glob("*.sv"):
        shutil.copy(p, d / p.name)
    t = (d / f).read_text()
    assert t.count(old) == 1, (name, t.count(old))
    (d / f).write_text(t.replace(old, new))
    print("made", name)
PY

names=$(echo "$MUTANTS" | grep -E '^[a-z_0-9]+\|' | cut -d'|' -f1)
pids=()
for n in $names; do compile_run "$n" > "$OUT/$n.result" & pids+=("$!"); while (( $(jobs -rp | wc -l) >= ${MAX_JOBS:-6} )); do wait -n || true; done; done
wait
cat $(for n in $names; do echo "$OUT/$n.result"; done) | tee build/cbsg/af/review/mutants_summary.log
