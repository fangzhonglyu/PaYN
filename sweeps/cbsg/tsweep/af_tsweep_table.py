#!/usr/bin/env python3
"""Collect the AF L-sweep points (sweeps/cbsg/tsweep/run_af_tsweep_point.sh) into one table.

Reads build/power_char/cbsg_20261005/tsweep/af/<tag>/result.json for every tag present, requires the validation gate
(gate.json, sweeps/cbsg/tsweep/af_tsweep_gate.py) to be PASS, and also verifies on the traces that every uniform-L
point drew the same operands as u128 (AMAG / ASIGN / WMAG / WSIGN lines identical).  Writes results.csv,
results.json and table.txt beside the points.

  python3 sweeps/cbsg/tsweep/af_tsweep_table.py [--sweep DIR]
"""
import argparse
import csv
import json
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
SWEEP = REPO / "build/power_char/cbsg_20261005/tsweep/af"
TB = "designs/payn/power/power_payn_array_cbsg_af_vart.sv"
CLASSES = ["tiles", "pe_pipes_glue", "pe_clk_buf", "a_edge", "a_regs", "ka_enc", "therm", "w_edge", "w_regs", "w_cmp",
           "w_bank", "rng_words", "rng_ctrl", "periph_clk_buf", "top_clk_buf", "other", "u_pe",
           "u_peripheral_leaf_sum", "clock_buffers_all"]


def operand_lines(trace):
    return [ln for ln in Path(trace).read_text().splitlines() if ln.split()[:1] in (["AMAG"], ["ASIGN"], ["WMAG"], ["WSIGN"])]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sweep", default=str(SWEEP))
    sweep = Path(ap.parse_args().sweep)
    gate = json.loads((sweep / "gate.json").read_text())
    assert gate["status"] == "PASS", "validation gate is not PASS"
    rows = []
    ref_ops = operand_lines(sweep / "u128" / "gl" / TB / "array_streaming_cbsg_af_rtl.txt")
    for d in sorted(sweep.iterdir()):
        if not (d / "result.json").is_file():
            continue
        r = json.loads((d / "result.json").read_text())
        same_ops = None
        if r["L"] is not None:
            same_ops = operand_lines(d / "gl" / TB / "array_streaming_cbsg_af_rtl.txt") == ref_ops
            assert same_ops, f"{d.name}: operand draws differ from u128"
        row = {k: r[k] for k in ("tag", "workload", "L", "mean_L", "blocks", "window_clocks", "cycles_per_block",
                                 "kernel_macs", "power_mW", "internal_mW", "switching_mW", "leakage_mW", "pJ_per_MAC",
                                 "pJ_per_block", "nJ_window", "mean_kA", "a_one_density", "drain_bit_exact",
                                 "drained_accumulators", "gl_strict", "gl_status", "gl_approvals_ndi",
                                 "gl_approvals_iwsba", "gl_post_reset_violations", "worst_icg_ck_eck_ns",
                                 "sdf_clock_audit", "pt_coverage")}
        row["gl_sdf_warnings"] = json.dumps(r["gl_sdf_warnings"], sort_keys=True)
        row["same_operands_as_u128"] = same_ops
        for c in CLASSES:
            row[f"cls_{c}_mW"] = r["classes_mW"][c]
        for c in ("tiles", "pe_pipes_glue", "pe_clk_buf", "a_edge", "w_edge"):
            row[f"cls_{c}_pJ_per_block"] = r["classes_mW"][c] * r["window_clocks"] * 2.5 / r["blocks"]
        row.update(sim_dir=r["sim_dir"], power_dir=r["power_dir"], classes_dir=r["classes_dir"], pt_view=r["pt_view"],
                   result_json=str(d / "result.json"))
        rows.append(row)
    rows.sort(key=lambda x: (x["L"] is None, x["L"] or 0))
    with (sweep / "results.csv").open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0]))
        w.writeheader()
        w.writerows(rows)
    (sweep / "results.json").write_text(json.dumps(dict(gate=gate["status"], points=rows), indent=1) + "\n")
    hdr = (f"{'point':<8}{'clk/blk':>8}{'window':>8}{'mW':>9}{'pJ/MAC':>9}{'pJ/blk':>9}{'mean kA':>9}"
           f"{'tiles':>8}{'pipes':>8}{'peclk':>8}{'A edge':>8}{'kA enc':>8}{'therm':>8}{'W edge':>8}{'other':>8}"
           f"  drain  GL")
    lines = ["AF (A-first C-BSG) uniform-L sweep on the qualified pinned route "
             "cbsg_af_20261005_distguide_spp_pins_postfill; 384 blocks, 196,608 MACs, 400 MHz, drain excluded.",
             "Class columns in mW (sweeps/cbsg/af/run_pt_power_classes.sh); 'other' = top clock buffers + glue + "
             "W bank + RNG + periph clock buffers + misc.", hdr]
    for r in rows:
        c = {k[4:-3]: v for k, v in r.items() if k.startswith("cls_") and k.endswith("_mW")}
        rest = r["power_mW"] - c["tiles"] - c["pe_pipes_glue"] - c["pe_clk_buf"] - c["a_edge"] - c["w_edge"]
        lines.append(f"{r['tag']:<8}{r['cycles_per_block']:>8.3f}{r['window_clocks']:>8}{r['power_mW']:>9.4f}"
                     f"{r['pJ_per_MAC']:>9.4f}{r['pJ_per_block']:>9.2f}{r['mean_kA']:>9.2f}{c['tiles']:>8.3f}"
                     f"{c['pe_pipes_glue']:>8.3f}{c['pe_clk_buf']:>8.3f}{c['a_edge']:>8.3f}{c['ka_enc']:>8.3f}"
                     f"{c['therm']:>8.3f}{c['w_edge']:>8.3f}{rest:>8.3f}  {'exact' if r['drain_bit_exact'] else 'FAIL':<6} "
                     f"{r['gl_strict']}")
    (sweep / "table.txt").write_text("\n".join(lines) + "\n")
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
