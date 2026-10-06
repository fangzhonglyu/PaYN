#!/usr/bin/env python3
"""Summary of the all-bits-in-time (abit) INT measurements on AF-IPD vs the current schedule and BOS.

Reads
  <ABIT_OUT>/results.csv          routed INT energy (sweeps/cbsg/af_ipd/abit/run_abit_int_energy.sh): abit points and
                                  current-schedule (cur) controls on the same operands
  <ABIT_OUT>/<label>/classes/power_classes.json   per-class split where it was run
  <CUR_OUT>/results.csv           the current schedule's existing INT energy points (run_af_ipd_int_energy.sh)
  <RTL>/grid/g4_*/check.json      measured 4x4 block periods (sweeps/cbsg/af_ipd/abit/run_abit_rtl.sh, part grid)
and writes <ABIT_OUT>/summary.txt and summary.json.

Throughput (4x4 grid, 400 MHz, AF-IPD 4x4 composite 538,299 um2, drain-excluded data fraction as BOS's peaks are
drain-excluded; the block-period ratio includes laps, skew and drain):
  GMAC/s/mm2 = 16 PEs x (MAC per data cycle per PE) x (data edges / block period) x 0.4 / 0.538299
  abit: MAC per data cycle 8192 / (BA*BW), block period measured on the 4x4 RTL grid (formula BA*BW*NB + (BA+BW-2)
        + 6 + 32);
  cur:  MAC per data cycle 8 x 128 x (8 // BA rows) / BW for BA in {4, 8} (INT6: 6 of 8 tile rows used, 8 x 128 / 6),
        block period BW*NB + (BW-1) + 6 + 32 (the IPD grid formula, verified on RTL by run_rtl_checks.sh part grid
        for BA in {4, 8}; INT6 is formula only).
BOS (designs/baselines/binary_os, handoff section 4): INT8 1,621 / 0.412, INT6 2,064 / 0.260, INT4 2,491 / 0.155
(GMAC/s/mm2 / pJ/MAC).

  summarize_abit.py [--abit-out DIR] [--cur-out DIR] [--rtl DIR]
"""
from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path

ROUTE = "cbsg_af_ipd_20261005_distguide_spp_pins_postfill"
CAMP = Path("build/power_char/cbsg_20261005/af_ipd")
AREA_MM2 = 0.538299
F_GHZ = 0.4
BOS = {"INT8": (1621, 0.412), "INT6": (2064, 0.260), "INT4": (2491, 0.155)}
PREC_BITS = {"INT8": (8, 8), "INT6": (6, 6), "INT4": (4, 4), "W4A8": (8, 4), "W6A8": (8, 6)}
PR = PC = 4
S = PR + PC - 2


def gmacs(mpdc: float, data: int, period: int) -> float:
    return 16 * mpdc * data / period * F_GHZ / AREA_MM2


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--abit-out", type=Path, default=CAMP / "abit_int_energy" / ROUTE)
    ap.add_argument("--cur-out", type=Path, default=CAMP / "int_energy" / ROUTE)
    ap.add_argument("--rtl", type=Path, default=Path("build/cbsg/af_ipd/abit"))
    args = ap.parse_args()

    rows = list(csv.DictReader((args.abit_out / "results.csv").open()))
    existing = list(csv.DictReader((args.cur_out / "results.csv").open()))
    grid = {}
    for c in sorted((args.rtl / "grid").glob("g4_*/check.json")):
        j = json.loads(c.read_text())
        if j["status"] == "PASS" and j["grid"] == "4x4":
            grid.setdefault((j["precision"], j["L"]), set()).update(j["measured_periods"])

    out: dict = dict(throughput=[], energy=[], existing_current=[], classes={})
    lines = ["All-bits-in-time (abit) INT on AF-IPD: measured (route " + ROUTE + ")", ""]

    # ------------------------------------------------------------ throughput --
    lines.append("4x4 GMAC/s/mm2 at 400 MHz on 538,299 um2 (block period incl. laps, skew and drain; BOS = drain-excluded peak)")
    lines.append(f"{'prec':5} {'L':>5} | {'cur period':>10} {'cur':>6} | {'abit period':>11} {'abit':>6} {'src':>8} | "
                 f"{'abit/cur':>8} {'abit/BOS':>8} | {'abit peak':>9} {'BOS':>5}")
    for prec, L in [("INT8", 128), ("INT8", 256), ("INT8", 384), ("INT8", 1024), ("INT8", 4096), ("INT6", 1024),
                    ("INT6", 4096), ("INT4", 1024), ("INT4", 4096), ("W4A8", 1024)]:
        ba, bw = PREC_BITS[prec]
        nb = L // 128
        mp_a = 8192 / (ba * bw)
        f_a = ba * bw * nb + (ba + bw - 2) + S + 8 * PC
        meas = grid.get((prec, L))
        p_a = sorted(meas)[0] if meas and len(meas) == 1 else None
        src = "RTL 4x4" if p_a is not None else "formula"
        if p_a is not None and p_a != f_a:
            src = "MISMATCH"
        p_a = p_a or f_a
        rows_pe = 8 // ba if ba in (4, 8) else 1
        mp_c = 8 * 128 * rows_pe / bw
        p_c = bw * nb + (bw - 1) + S + 8 * PC
        g_c, g_a = gmacs(mp_c, bw * nb, p_c), gmacs(mp_a, ba * bw * nb, p_a)
        peak_a = 16 * mp_a * F_GHZ / AREA_MM2
        bos = BOS.get(prec, (None, None))[0]
        note = " (worst-case range exceeded: data-dependent)" if L * (1 << (ba + bw - 2)) > (1 << 23) - 1 else ""
        out["throughput"].append(dict(precision=prec, L=L, cur_period=p_c, cur_gmacs_mm2=round(g_c, 1),
                                      abit_period=p_a, abit_period_source=src, abit_formula=f_a,
                                      abit_gmacs_mm2=round(g_a, 1), abit_over_cur=round(g_a / g_c, 3),
                                      abit_over_bos=round(g_a / bos, 3) if bos else None,
                                      abit_peak=round(peak_a, 1), bos=bos, note=note.strip(" ()")))
        lines.append(f"{prec:5} {L:>5} | {p_c:>10} {g_c:>6.0f} | {p_a:>11} {g_a:>6.0f} {src:>8} | {g_a / g_c:>7.2f}x "
                     f"{(f'{g_a / bos:.2f}x' if bos else '-'):>8} | {peak_a:>9.0f} {bos or '-':>5}{note}")
    lines.append("  cur INT6 = formula only (6 of 8 tile rows used); the current-schedule benches support BA in {4, 8}.")
    lines.append("")

    # ---------------------------------------------------------------- energy --
    lines.append("Routed single-PE INT energy (PT-PX, extracted parasitics, max-SDF GL SAIF), window: dr = drain excluded,"
                 " d = data only, all = drain included")
    hdr = (f"{'label':30} {'sched':5} {'prec':5} {'L':>5} {'win':>3} {'blocks':>6} {'active':>6} {'data':>5} "
           f"{'lap':>4} {'drain':>5} {'MAC/cyc':>8} {'mW':>7} {'pJ/MAC':>7} {'array':>6}")
    lines.append(hdr)
    win_of = {"0": "dr", "1": "d", "2": "all"}
    for r in sorted(rows, key=lambda r: (r["precision"], int(r["L"]), r["schedule"], r["saif_mode"])):
        e = dict(label=r["label"], schedule=r["schedule"], precision=r["precision"], L=int(r["L"]),
                 window=win_of[r["saif_mode"]], blocks=int(r["blocks"]), active_cycles=int(r["active_cycles"]),
                 data_cycles=int(r["data_cycles"]), lap_cycles=int(r["ring_cycles"]),
                 drain_cycles=int(r["drain_cycles"]), mac_per_cycle=float(r["mac_per_cycle"]),
                 power_mW=float(r["power_mW"]), pJ_MAC=float(r["pJ_MAC"]), array_pJ_MAC=float(r["array_pJ_MAC"]),
                 block_period=int(r["block_period"]), status=r["status"],
                 approved_interconnects=int(r["approved_interconnects"]),
                 post_reset_timing_violations=int(r["post_reset_timing_violations"]))
        out["energy"].append(e)
        lines.append(f"{e['label']:30} {e['schedule']:5} {e['precision']:5} {e['L']:>5} {e['window']:>3} "
                     f"{e['blocks']:>6} {e['active_cycles']:>6} {e['data_cycles']:>5} {e['lap_cycles']:>4} "
                     f"{e['drain_cycles']:>5} {e['mac_per_cycle']:>8.2f} {e['power_mW']:>7.3f} {e['pJ_MAC']:>7.4f} "
                     f"{e['array_pJ_MAC']:>6.4f}")
    lines.append("")
    lines.append("Existing current-schedule points (build/power_char/cbsg_20261005/af_ipd/int_energy, other operands/shapes):")
    for r in existing:
        out["existing_current"].append(dict(label=r["label"], precision=r["precision"], L=int(r["L"]),
                                            window=win_of[r["saif_mode"]], mac_per_cycle=float(r["mac_per_cycle"]),
                                            pJ_MAC=float(r["pJ_MAC"]), power_mW=float(r["power_mW"])))
        lines.append(f"  {r['label']:28} {r['precision']:5} L={r['L']:>6} {win_of[r['saif_mode']]:>3} "
                     f"MAC/cyc {float(r['mac_per_cycle']):7.2f}  {float(r['power_mW']):7.3f} mW  "
                     f"{float(r['pJ_MAC']):.4f} pJ/MAC")
    lines.append("")

    # A/B on identical operands, and vs BOS.
    lines.append("A/B on identical operands (dr unless noted): abit vs cur pJ/MAC, and vs BOS")
    by = {(r["schedule"], r["precision"], int(r["L"]), r["saif_mode"]): r for r in rows}
    ex = {(r["precision"], int(r["L"]), r["saif_mode"]): r for r in existing}
    ab = []
    for (sched, prec, L, mode), r in sorted(by.items()):
        if sched != "abit":
            continue
        c = by.get(("cur", prec, L, mode))
        src = "cur control"
        if c is None and prec == "W4A8" and L == 1024:
            c, src = ex.get((prec, L, mode)), "existing point (same operands)"
        bos = BOS.get(prec, (None, None))[1]
        a_pj = float(r["pJ_MAC"])
        item = dict(precision=prec, L=L, window=win_of[mode], abit_pJ_MAC=a_pj,
                    abit_mac_per_cycle=float(r["mac_per_cycle"]), bos_pJ_MAC=bos,
                    abit_vs_bos=round(a_pj / bos - 1, 4) if bos else None)
        txt = f"  {prec:5} L={L:>5} {win_of[mode]:>3}: abit {a_pj:.4f} pJ/MAC @ {float(r['mac_per_cycle']):7.2f} MAC/cycle"
        if c is not None:
            c_pj = float(c["pJ_MAC"])
            item.update(cur_pJ_MAC=c_pj, cur_mac_per_cycle=float(c["mac_per_cycle"]), cur_source=src,
                        abit_vs_cur=round(a_pj / c_pj - 1, 4))
            txt += (f"; cur {c_pj:.4f} @ {float(c['mac_per_cycle']):7.2f} ({src}): {100 * (a_pj / c_pj - 1):+.1f} %")
        if bos:
            txt += f"; BOS {bos:.3f}: {100 * (a_pj / bos - 1):+.1f} %"
        ab.append(item)
        lines.append(txt)
    out["ab"] = ab
    lines.append("")

    # ------------------------------------------------------------- classes --
    cls_rows = ("u_pe", "tiles", "pe_pipes_glue", "dbl_mux", "pe_clk_buf", "a_edge", "w_edge", "w_bank", "combiner",
                "other", "clock_buffers_all")
    have = [r for r in rows if (args.abit_out / r["label"] / "classes" / "power_classes.json").is_file()]
    if have:
        lines.append("Per-class split (pJ/MAC = class mW x 2.5 ns / MAC per cycle of the window)")
        lines.append(f"{'label':30} " + " ".join(f"{k:>10}" for k in ("total",) + cls_rows))
        for r in have:
            j = json.loads((args.abit_out / r["label"] / "classes" / "power_classes.json").read_text())
            mpc = float(r["mac_per_cycle"])
            mw = j["rows_mW"]
            vals = {k: mw.get(k) for k in ("total",) + cls_rows}
            out["classes"][r["label"]] = dict(mW=vals, pJ_MAC={k: (v * 2.5 / mpc if v is not None else None)
                                                               for k, v in vals.items()})
            lines.append(f"{r['label']:30} " + " ".join(
                f"{(v * 2.5 / mpc if v is not None else float('nan')):>10.4f}" for v in vals.values()))
        lines.append("")

    (args.abit_out / "summary.txt").write_text("\n".join(lines) + "\n")
    (args.abit_out / "summary.json").write_text(json.dumps(out, indent=2) + "\n")
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
