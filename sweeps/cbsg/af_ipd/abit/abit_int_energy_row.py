#!/usr/bin/env python3
"""One results row for a qualified all-bits-in-time (abit) or current-schedule (cur) INT energy point
(sweeps/cbsg/af_ipd/abit/run_abit_int_energy.sh).

[ABIT COPY] of sweeps/cbsg/af_ipd/af_ipd_int_energy_row.py (sha256 d00683db...b2a at copy time, 2026-10-06).
Changes: MAC accounting in exact integers (data cycles x 8192 = MACs x BA x BW, for any BA x BW: INT6 has 227.56
MAC per data cycle); added columns schedule (abit / cur, from check.json), block_period (abit: BA*BW*NB + (BA+BW-2)
+ 8; cur: BW*NB + (BW-1) + 8) and lap_cycles (= ring_cycles: abit lap bubbles, cur ring bubbles).  The rest is the
copy's.  The copy's docstring:

[CBSG-AF-IPD COPY] of sweeps/int_mode/bp/bp_int_energy_row.py (sha256 in
designs/payn/variants/signed_segmented_csa_cbsg_af_ipd/copied_from.sha256).  Changes: the hierarchies are u_pe,
u_peripheral, u_combiner and u_rng (the AF block clock replaces the Sobol banks u_a_rng / u_w_rng), so the column
sobol_mW becomes rng_mW; the check JSON must carry lap_len 1 (1-edge in-place laps).  Everything else (MAC
accounting, columns, the 7 s.f. / 3 s.f. hierarchy cross-check) is the original's.  Original docstring:

Reads, under WORK (= OUT/<label>):
  gl/check.json                 check_bp_power_trace.py on the routed GL run (PASS)
  gl/timing_qualification.json  validate_routed_gl.py (PASS)
  gl/saif_validation.log        validate_sc_power_saif.py summary line
  power/power.rpt               PT-PX totals
  power/cell_power.rpt          top-level cells, 7 significant digits: u_pe,
                                u_peripheral, u_combiner, u_a_rng, u_w_rng
  power/power_hier.rpt          the same hierarchies at 3 s.f. (cross-check)
and writes WORK/row.csv with the emulation campaign's columns
(run_bitplane_energy.sh) plus u_combiner_mW and toplevel_mW (the rest: int_mode
register and MAC guard, top-level clock tree and buffers).

MAC accounting: one data cycle is 8 x 8 tiles x 128 bit-products, i.e.
8192 / (BA * BW) MACs (INT8 128, W4A8 256, INT4 512); ring and drain cycles
carry none.  mac_per_cycle = data_cycles * that / active_cycles over the SAIF
window, pJ/MAC = P * period / mac_per_cycle (full design, and u_pe only as
"array").

  bp_int_energy_row.py WORK LABEL [--period-ns 2.5] [--route NAME]
"""
from __future__ import annotations

import argparse
import csv
import json
import re
from pathlib import Path

HIER = ("u_pe", "u_peripheral", "u_combiner", "u_rng")   # [AF-IPD]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("work", type=Path)
    ap.add_argument("label")
    ap.add_argument("--period-ns", type=float, default=2.5)
    ap.add_argument("--route", default="")
    args = ap.parse_args()
    work, period = args.work, args.period_ns

    chk = json.loads((work / "gl" / "check.json").read_text())
    timing = json.loads((work / "gl" / "timing_qualification.json").read_text())
    if chk["status"] != "PASS" or timing["status"] != "PASS":
        raise SystemExit(f"point not qualified: check {chk['status']}, timing {timing['status']}")
    saif_line = (work / "gl" / "saif_validation.log").read_text().strip().splitlines()
    if not saif_line or not saif_line[-1].startswith("validated SC SAIF"):
        raise SystemExit("SAIF validation log lacks the 'validated SC SAIF' line")

    report = (work / "power" / "power.rpt").read_text()

    def total(name: str) -> float:
        m = re.search(name + r"\s*=\s*([0-9.eE+-]+)", report)
        if not m:
            raise SystemExit(f"power.rpt lacks {name}")
        return float(m[1]) * 1e3

    precise: dict[str, float] = {}
    for line in (work / "power" / "cell_power.rpt").read_text().splitlines():
        f = line.split()
        if len(f) >= 6 and f[0] in HIER and f[-1] == "h":
            if f[0] in precise:
                raise SystemExit(f"cell_power.rpt lists {f[0]} twice")
            precise[f[0]] = float(f[4]) * 1e3
    coarse: dict[str, float] = {}
    for line in (work / "power" / "power_hier.rpt").read_text().splitlines():
        m = re.match(r"  (\S+) \(\S+\)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)", line)
        if m and m[1] in HIER and m[1] not in coarse:
            coarse[m[1]] = float(m[5]) * 1e3
    if set(precise) != set(HIER) or set(coarse) != set(HIER):
        raise SystemExit(f"hierarchy powers incomplete: cell_power {sorted(precise)}, power_hier {sorted(coarse)}")
    for name in HIER:   # 3 s.f. rounding is at most 0.5% of the value
        if abs(precise[name] - coarse[name]) > 0.0051 * abs(coarse[name]) + 1e-6:
            raise SystemExit(f"{name}: cell_power {precise[name]} mW vs power_hier {coarse[name]} mW")

    ba, bw = chk["ba"], chk["bw"]
    win = chk["saif_window"]
    mac_per_data_cycle = 64 * 128 / (ba * bw)
    if win["data"] * 64 * 128 != chk["macs"] * ba * bw:   # [ABIT] exact for any BA x BW
        raise SystemExit(f"window data cycles {win['data']} x 8192 / (BA*BW) != checked MACs {chk['macs']}")
    macs = chk["macs"]
    mac_per_cycle = macs / win["active"]
    schedule = chk.get("schedule", "cur")                  # [ABIT]
    nb = chk["L"] // 128
    block_period = (ba * bw * nb + ba + bw - 2 + 8) if schedule == "abit" else (bw * nb + bw - 1 + 8)
    power = total("Total Power")
    if chk.get("lap_len") != 1:   # [AF-IPD]
        raise SystemExit(f"check.json lap_len {chk.get('lap_len')} != 1")
    rng = precise["u_rng"]
    row = dict(
        label=args.label, schedule=schedule, precision=chk["precision"], dist=args.label.split("_")[2],
        L=chk["L"], blocks=chk["blocks"], saif_mode=chk["saif_mode"],
        active_cycles=win["active"], data_cycles=win["data"], ring_cycles=win["ring"],
        drain_cycles=win["drain"], lap_cycles=win["ring"], block_period=block_period,
        mac_per_data_cycle=mac_per_data_cycle,
        mac_per_cycle=mac_per_cycle,
        power_mW=power, internal_mW=total("Cell Internal Power"),
        switching_mW=total("Net Switching Power"), leakage_mW=total("Cell Leakage Power"),
        u_pe_mW=precise["u_pe"], u_peripheral_mW=precise["u_peripheral"],
        u_combiner_mW=precise["u_combiner"], rng_mW=rng,
        toplevel_mW=power - precise["u_pe"] - precise["u_peripheral"] - precise["u_combiner"] - rng,
        pJ_MAC=power * period / mac_per_cycle,
        array_pJ_MAC=precise["u_pe"] * period / mac_per_cycle,
        max_abs_tile=chk["max_abs_tile"], max_abs_output=chk["max_abs_output"],
        tiles_checked=chk["tiles_checked"], outputs_checked=chk["outputs_checked"],
        macs_checked=chk["macs"],
        sdf_warnings=json.dumps(timing["sdf_warning_categories"], sort_keys=True),
        approved_iopath_clamps=len(timing.get("approved_negative_iopath_clamps", [])),
        approved_interconnects=len(timing.get("approved_annotated_interconnects", [])),
        post_reset_timing_violations=timing["post_reset_timing_violations"],
        saif_validation=saif_line[-1].split("  [note")[0],
        route=args.route, status="PASS",
    )
    with (work / "row.csv").open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(row))
        writer.writeheader()
        writer.writerow(row)
    print(json.dumps(row))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
