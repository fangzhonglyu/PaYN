#!/usr/bin/env python3
"""Validation gate of the AF L sweep: the sweep's u128 and ladder points must reproduce the qualified pinned AF route's
headline measurement exactly (build/power_char/cbsg_20261005/af/pinned_fix/postfill/measure):
  - the GL SAIF is byte-identical apart from its (DATE ...) line,
  - the trace (operands, row lengths, drain) is identical, and the trace check JSON is identical,
  - PT-PX power.rpt: every power-group row and the four totals are identical strings,
  - the class split (power_classes.json rows_mW) agrees to 1e-9 mW (PT summation-order noise: the ladder rerun's
    derived port_nets / other rows moved by 7e-15 mW, every other class row is bit-identical),
  - the result totals (power, pJ/MAC, pJ/block, window, mean kA) are identical.
Writes OUT/gate.json and exits 1 on any difference.

  python3 sweeps/cbsg/tsweep/af_tsweep_gate.py [--sweep DIR] [--headline DIR]
"""
import argparse
import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
HEAD = REPO / "build/power_char/cbsg_20261005/af/pinned_fix/postfill/measure"
SWEEP = REPO / "build/power_char/cbsg_20261005/tsweep/af"
TB_HEAD = "designs/payn/power/power_payn_array_cbsg_af.sv"
TB_SWEEP = "designs/payn/power/power_payn_array_cbsg_af_vart.sv"


def saif_body(p):
    return [ln for ln in Path(p).read_text().splitlines() if not ln.startswith("(DATE ")]


def power_rows(p):
    t = Path(p).read_text()
    rows = [ln.split() for ln in t.splitlines()
            if re.match(r"^(clock_network|register|combinational|sequential|memory|io_pad|black_box)\s", ln)]
    tot = re.findall(r"^\s*(Net Switching Power|Cell Internal Power|Cell Leakage Power|Total Power)\s*=\s*(\S+)", t, re.M)
    return rows, tot


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sweep", default=str(SWEEP))
    ap.add_argument("--headline", default=str(HEAD))
    a = ap.parse_args()
    sweep, head = Path(a.sweep), Path(a.headline)
    hres = {r["workload"].split()[0]: r for r in json.loads((head / "result.json").read_text())}
    pairs = dict(
        u128=dict(hsim=head / "gl_final", hpwr=head / "power_result", hcls=head / "classes_uniform", hres=hres["uniform"]),
        ladder=dict(hsim=head / "gl_ladder", hpwr=head / "ladder/power_result", hcls=head / "classes_ladder",
                    hres=hres["ladder"]))
    out, ok = {}, True
    for tag, h in pairs.items():
        d = sweep / tag
        s = json.loads((d / "result.json").read_text())
        chk = {}
        chk["saif_identical_except_date"] = saif_body(h["hsim"] / TB_HEAD / "dut.saif") == saif_body(d / "gl" / TB_SWEEP / "dut.saif")
        chk["trace_identical"] = ((h["hsim"] / TB_HEAD / "array_streaming_cbsg_af_rtl.txt").read_bytes()
                                  == (d / "gl" / TB_SWEEP / "array_streaming_cbsg_af_rtl.txt").read_bytes())
        chk["trace_check_json_identical"] = (json.loads((h["hsim"] / "trace_check.json").read_text())
                                             == json.loads((d / "gl" / "trace_check.json").read_text()))
        hp, sp = power_rows(h["hpwr"] / "power.rpt"), power_rows(d / "power_result" / "power.rpt")
        chk["power_rpt_groups_and_totals_identical"] = hp == sp and len(hp[1]) == 4
        hc = json.loads((h["hcls"] / "power_classes.json").read_text())["rows_mW"]
        sc = json.loads((d / "classes" / "power_classes.json").read_text())["rows_mW"]
        cdiff = max(abs(hc[k] - sc[k]) for k in hc) if set(hc) == set(sc) else float("inf")
        chk["classes_equal_within_1e-9_mW"] = cdiff <= 1e-9   # PT summation-order noise only (seen: 7e-15 mW)
        hr = h["hres"]
        for k in ("power_mW", "internal_mW", "switching_mW", "leakage_mW", "pJ_per_MAC", "pJ_per_block", "window_clocks",
                  "mean_kA", "a_one_density"):
            chk[f"result_{k}_identical"] = hr[k] == s[k]
        chk["gl_strict_pass_both"] = hr["gl_strict"] == "PASS" and s["gl_strict"] == "PASS"
        chk["drain_bit_exact_both"] = bool(hr["drain_bit_exact"]) and bool(s["drain_bit_exact"])
        out[tag] = dict(checks=chk, headline=dict(power_mW=hr["power_mW"], pJ_per_MAC=hr["pJ_per_MAC"],
                                                   window_clocks=hr["window_clocks"]),
                        sweep=dict(power_mW=s["power_mW"], pJ_per_MAC=s["pJ_per_MAC"], window_clocks=s["window_clocks"]),
                        classes_max_abs_diff_mW=cdiff,
                        total_power_strings=dict(headline=dict(hp[1]).get("Total Power"), sweep=dict(sp[1]).get("Total Power")))
        bad = [k for k, v in chk.items() if not v]
        ok &= not bad
        print(f"{tag}: {'PASS' if not bad else 'FAIL ' + ', '.join(bad)}  headline {hr['power_mW']} mW / sweep {s['power_mW']} mW "
              f"(Total Power {out[tag]['total_power_strings']['headline']} vs {out[tag]['total_power_strings']['sweep']})")
    out["status"] = "PASS" if ok else "FAIL"
    (sweep / "gate.json").write_text(json.dumps(out, indent=1) + "\n")
    print(f"gate {out['status']} -> {sweep / 'gate.json'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
