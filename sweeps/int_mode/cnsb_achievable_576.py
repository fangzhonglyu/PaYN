#!/usr/bin/env python3
"""Spatial Booth (CNSB) and bit-plane (BP) INT modes on the CURRENT pinned routed basis, at the
throughput an SC-sized SRAM can sustain: 576 b every cycle per edge half (A and W sides alike), no
added edge buffers (only existing registers: edge magnitude registers, Sobol state, PE pipes).

Pure Python, no EDA.  Read-only on every input; writes only the CSV/log named below.

    python3 sweeps/int_mode/cnsb_achievable_576.py > sweeps/int_mode/cnsb_achievable_576.log
    (writes sweeps/int_mode/cnsb_achievable_576.csv)

Basis (all routed, pinned pass 2, TSMC22 A7 SVT 0.80 V, 400 MHz, K8 M16 N8):
  CSA     apr/build/TSMC22/PAYN_SC_CSA/csa_20261002_distguide_spp_pins/reports/area.rpt
          (43,916.5 um2; 4x4 521,100.2; build/power_char/pinned_pass2_csa_bp_20261004_lap/comparison.txt)
  BP lap  apr/build/TSMC22/PAYN_SC_CSA_BP/csa_bp_20261004_lap_distguide_spp_pins/reports/area.rpt
          (46,096.5 um2; 4x4 531,321.5)
  Composite = N_PE x u_pe + (P_R+P_C)/2 x u_peripheral (+ P_R x u_combiner for BP) + Sobol pair,
  1 PE = the routed total (as compare_grid_configs.py / model_lap_schedules.py).
CNSB added areas (DC, synthesized standalone, sweeps/int_mode/verify/run_cnsb_synth.log):
  Sobol preset = sobol_pair_preset - sobol_pair_orig (one per grid, inside the array),
  feeder per edge half: radix-4 side (A in r4rows) / radix-16 side (W in r4rows, min of hi/lo code
  choice), 2-stage east combiner per PE row.  No CNSB controller is synthesized (control holds
  load_* = 1 and rng_en = 0; doc/INT_mode_on_PaYN.md 2.3); none is added here.
Schedules (one output block, PE (0,0) view, data cycles cannot overlap a drain on the existing tile):
  CNSB    P = ceil(L/8) + (P_R+P_C-2) + 8 P_C           sweeps/int_mode/verify/cnsb_rtl_cases.py:255-256,
                                                         model_lap_schedules.py cnsb_block()
  BP T1   P = BW*ceil(L/128) + 8(BW-1) + (P_R+P_C-2) + 8 P_C   (as built, per-PE laps; model schedule())
  SC T    P = L*T/128 + (P_R+P_C-2) + 8 P_C             (compare_grid_configs.py sc_rows)
Feed under 576 b/cycle/edge half:
  CNSB needs A 128 / W 256 raw b per data cycle per edge half (r4rows, all precisions) -> never stalls.
  BP needs 1,024 b per data edge on both sides -> stalls.  'int' = each data edge takes
  ceil(1024/576) = 2 SRAM cycles (the first 576 b held in the PE bit pipe: existing register, split
  load + MAC-enable control, not in RTL); 'fluid' = 1024/576 = 16/9 cycles per data edge
  (model_lap_schedules.py section 6 'stall'), which needs a sub-word staging register per edge half
  that does not exist in BP mode (the magnitude registers must stay 0 there), so it is an upper bound.
Energy: measured data-cycle (drain-excluded) pJ/MAC from the GL+PT runs, composed to grids as the
existing summarizers do; the 'est_pJ_MAC_at_L' column adds skew/drain/stall cycles from per-cycle
proxies (ESTIMATE, stated below).
"""
from __future__ import annotations

import csv
import importlib.util
import math
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
F_GHZ = 0.4
PERIOD_NS = 2.5
SHAPES = {"1PE": (1, 1), "4x4": (4, 4), "4x8": (4, 8)}
LS = (128, 1024, 4096)
SUP = 576                    # b/cycle per edge half (SC T=16 block every cycle)
DEMAND_BP = 1024             # BP operand bits per data edge per edge half

CSA_RUN = "TSMC22/PAYN_SC_CSA/csa_20261002_distguide_spp_pins"
BP_RUN = "TSMC22/PAYN_SC_CSA_BP/csa_bp_20261004_lap_distguide_spp_pins"
SYN_LOG = "sweeps/int_mode/verify/run_cnsb_synth.log"
CNSB_E = "build/power_char/int_mode_energy_20261003/cnsb_booth/summary.csv"
CNSB_R = "build/power_char/int_mode_energy_20261003/cnsb_booth/results.csv"
BP_E = "build/power_char/int_mode_energy_20261004_lap/bp/csa_bp_20261004_lap_distguide_spp_pins/results.csv"
PIN_RES = "build/power_char/pinned_pass2_csa_bp_20261004_lap/results.csv"
TSWEEP = "build/power_char/csa_t_sweep_20261003/results.csv"
RTL_SUM = "sweeps/int_mode/verify/cnsb_rtl_summary.log"
E_OVH_PE = 14.5              # pJ per PE per skew/drain cycle, u_pe (compare_grid_configs.py sc_rows e_drain_pe)

FAILS: list[str] = []


def check(cond, msg):
    if not cond:
        FAILS.append(msg)
        print(f"  ** MISMATCH: {msg}")


def cdiv(a, b):
    return -(-a // b)


def areas(run):
    d = {}
    for line in (REPO / "apr/build" / run / "reports/area.rpt").read_text().splitlines():
        f = line.split()
        if not f:
            continue
        if f[0].startswith("payn_array_signed_segmented_csa") and "total" not in d:
            d["total"] = float(f[2])
        if f[0] in ("u_pe", "u_peripheral", "u_a_rng", "u_w_rng", "u_combiner") and f[0] not in d:
            d[f[0]] = float(f[3])
    d["sobol"] = d["u_a_rng"] + d["u_w_rng"]
    d.setdefault("u_combiner", 0.0)
    return d


def composite(a, pr, pc, comb):
    if pr * pc == 1:
        return a["total"]
    return pr * pc * a["u_pe"] + (pr + pc) / 2 * a["u_peripheral"] + (pr * a["u_combiner"] if comb else 0) + a["sobol"]


def synth_areas():
    d = {}
    for line in (REPO / SYN_LOG).read_text().splitlines():
        m = re.match(r"\[(\w+)\] top=\S+ area=([0-9.]+)", line)
        if m:
            d[m[1]] = float(m[2])
    return dict(preset=d["sobol_pair_preset"] - d["sobol_pair_orig"], r4=d["feed_r4_half"],
                r16=min(d["feed_r16_half_hi"], d["feed_r16_half_lo"]), comb=d["combiner_row_2st"],
                comb1=d["combiner_row_1st"], raw=d)


def cnsb_add(sy, pr, pc, orient="r4rows"):
    n4, n16 = (pr, pc) if orient == "r4rows" else (pc, pr)
    return sy["preset"] + n4 * sy["r4"] + n16 * sy["r16"] + pr * sy["comb"]


def gmacs(macs, period, area_um2):
    return macs / period * F_GHZ / (area_um2 * 1e-6)


# CNSB mapping (doc 2.3; model_lap_schedules.py CNSB dict): rows/PE, cols/PE, BA, BW, peak, tiles/output
CNSB = {"INT8": (2, 4, 8, 8, 1, 8), "W4A8": (2, 8, 8, 4, 2, 4), "INT4": (4, 8, 4, 4, 4, 2)}


def load_model():
    p = REPO / "sweeps/int_mode/bp/model_lap_schedules.py"
    spec = importlib.util.spec_from_file_location("model_lap_schedules", p)
    m = importlib.util.module_from_spec(spec)
    sys.modules["model_lap_schedules"] = m
    spec.loader.exec_module(m)
    return m


def main():
    csa, bp = areas(CSA_RUN), areas(BP_RUN)
    sy = synth_areas()
    M = load_model()
    out = []

    print("CNSB (spatial Booth) and BP INT modes at an SC-sized SRAM feed (576 b/cycle/edge half, no added buffers)")
    print(f"CSA pinned  ({CSA_RUN}): total {csa['total']:,.3f}  u_pe {csa['u_pe']:,.3f}  periph "
          f"{csa['u_peripheral']:,.3f}  Sobol {csa['sobol']:,.3f} um2")
    print(f"BP lap pin. ({BP_RUN}): total {bp['total']:,.3f}  u_pe {bp['u_pe']:,.3f}  periph "
          f"{bp['u_peripheral']:,.3f}  comb {bp['u_combiner']:,.3f}  Sobol {bp['sobol']:,.3f} um2")
    print(f"CNSB synthesized ({SYN_LOG}): preset {sy['preset']:.1f}, r4 feeder/half {sy['r4']:.1f}, "
          f"r16 feeder/half {sy['r16']:.1f}, combiner/PE row {sy['comb']:.1f} (1-stage {sy['comb1']:.1f}) um2")

    # ---------------------------------------------------------------- 1. areas
    print("\n== 1. Areas (um2) and the SC-mode cost of each INT mode (SC T=128, 1 MAC/tile-cycle)")
    print(f"   {'shape':5s} {'CSA':>12s} {'CNSB add':>9s} {'CNSB r4rows':>12s} {'(r16rows)':>12s} {'BP lap':>12s}"
          f" | SC GMAC/s/mm2: {'CSA':>6s} {'+CNSB':>14s} {'+BP lap':>14s}")
    AREA = {}
    for shape, (pr, pc) in SHAPES.items():
        a_csa = composite(csa, pr, pc, False)
        add4, add16 = cnsb_add(sy, pr, pc, "r4rows"), cnsb_add(sy, pr, pc, "r16rows")
        a_cn, a_cn16 = a_csa + add4, a_csa + add16
        a_bp = composite(bp, pr, pc, True)
        a_bp_model = M.area(M.Sch("T1"), "INT8", shape)[0]
        check(abs(a_bp - a_bp_model) < 0.5, f"BP composite {shape}: {a_bp:.1f} vs model {a_bp_model:.1f}")
        AREA[shape] = dict(csa=a_csa, cnsb=a_cn, cnsb16=a_cn16, bp=a_bp, add4=add4, add16=add16)
        n = pr * pc
        g = lambda ar: gmacs(n * 64, 1, ar)
        print(f"   {shape:5s} {a_csa:12,.1f} {add4:9,.1f} {a_cn:12,.1f} {a_cn16:12,.1f} {a_bp:12,.1f}"
              f" | {g(a_csa):20.1f} {g(a_cn):7.1f} ({100 * (a_csa / a_cn - 1):+.2f}%) {g(a_bp):7.1f} "
              f"({100 * (a_csa / a_bp - 1):+.2f}%)")
        out.append(dict(section="sc_cost", shape=shape, design="SC T=128 on CSA+CNSB", area_um2=round(a_cn, 1),
                        gmacs_mm2_achievable=round(g(a_cn), 1), note=f"CNSB add {add4:.1f} um2 (r4rows), "
                        f"SC loss {100 * (1 - a_csa / a_cn):.2f}%"))
        out.append(dict(section="sc_cost", shape=shape, design="SC T=128 on BP lap", area_um2=round(a_bp, 1),
                        gmacs_mm2_achievable=round(g(a_bp), 1),
                        note=f"BP add {a_bp - a_csa:.1f} um2, SC loss {100 * (1 - a_csa / a_bp):.2f}%"))
    check(abs(AREA["1PE"]["csa"] - 43916.5) < 0.1 and abs(AREA["4x4"]["csa"] - 521100.2) < 0.1, "CSA basis")
    check(abs(AREA["1PE"]["bp"] - 46096.5) < 0.1 and abs(AREA["4x4"]["bp"] - 531321.5) < 0.1, "BP basis")
    print("   CNSB inside the array: the Sobol preset only "
          f"({sy['preset']:.1f} um2 = {100 * sy['preset'] / AREA['4x4']['csa']:.3f}% of a 4x4); the rest is edge logic.")

    # ---------------------------------------------------------------- 2. period validation
    print("\n== 2. CNSB period formula checks")
    for shape, (pr, pc) in SHAPES.items():
        for L in LS:
            for prec in CNSB:
                c = M.cnsb_block(prec, L, pr, pc)
                mine = cdiv(L, 8) + pr + pc - 2 + 8 * pc
                check(c["period"] == mine, f"cnsb_block {shape} {prec} L={L}: {c['period']} vs {mine}")
                S = L // 8          # cnsb_rtl_cases.py: span = S + PR + PC - 2; period = span + 8*PC
                if L % 8 == 0:
                    check(S + pr + pc - 2 + 8 * pc == mine, "cnsb_rtl_cases period")
    rtl = (REPO / RTL_SUM).read_text().splitlines()
    multi = [l for l in rtl if l.startswith("PASS") and "expect=pass" in l and re.search(r"blocks=([2-9])", l)]
    grids = sorted({re.search(r"grid=(\d+x\d+)", l)[1] for l in multi})
    print(f"   model cnsb_block() == ceil(L/8) + (P_R+P_C-2) + 8 P_C == cnsb_rtl_cases.py:255-256 for every point.")
    print(f"   RTL: {len(multi)} back-to-back (blocks >= 2) bit-exact cases at exactly this period on grids "
          f"{', '.join(grids)} ({RTL_SUM}); the period is the bench's schedule, validated bit-exact, not a free-running "
          f"measurement.  No CNSB grid-level period measurement or GL exists.")

    # ---------------------------------------------------------------- 3. throughput
    cn_e = {r["label"]: r for r in csv.DictReader((REPO / CNSB_E).open())}
    bp_e = {r["label"]: r for r in csv.DictReader((REPO / BP_E).open())}
    pin = {r["label"]: r for r in csv.DictReader((REPO / PIN_RES).open())}
    tsw = {(r["arm"], int(r["T"])): r for r in csv.DictReader((REPO / TSWEEP).open())}

    # BP per-cycle energies on the routed lap route (pJ per PE-cycle, u_pe) and edge powers
    def bpcyc(lbl):
        r = bp_e[lbl]
        return float(r["u_pe_mW"]) * PERIOD_NS * (int(r["data_cycles"]) + int(r["ring_cycles"]) + int(r["drain_cycles"]))
    bp_cyc = {}
    for prec, (dl, rl) in {"INT8": ("int8_uniform_L49152_d", "int8_uniform_L1024_dr"),
                           "W4A8": ("int8_uniform_L49152_d", "w4a8_uniform_L1024_dr"),
                           "INT4": ("int4_uniform_L98304_d", "int4_uniform_L1024_dr")}.items():
        d = bp_e[dl]       # W4A8: no peak point on the lap route; its data cycles use the INT8 peak point
        e_data = float(d["u_pe_mW"]) * PERIOD_NS
        r = bp_e[rl]
        e_ring = (bpcyc(rl) - e_data * int(r["data_cycles"])) / int(r["ring_cycles"])
        bp_cyc[prec] = dict(data=e_data, ring=e_ring, periph=float(d["u_peripheral_mW"]),
                            comb=float(d["u_combiner_mW"]), sobol=float(d["sobol_mW"]),
                            top=float(d["toplevel_mW"]), total=float(d["power_mW"]))
    bp_peak_pj = {"INT8": float(bp_e["int8_uniform_L49152_d"]["pJ_MAC"]),
                  "INT4": float(bp_e["int4_uniform_L98304_d"]["pJ_MAC"]), "W4A8": None}

    print("\n== 3. Throughput at 576 b/cycle per edge half, no added buffers")
    print("   cells: MAC/tile-cycle (% of own peak) / GMAC/s/mm2 [est. pJ/MAC at L]")
    hdr = "   {:5s} {:4s} {:24s} " + " ".join(["{:>34s}"] * 3)
    print(hdr.format("shape", "prec", "design", *[f"L={L}" for L in LS]))
    for shape, (pr, pc) in SHAPES.items():
        n = pr * pc
        ar = AREA[shape]
        for prec in ("INT8", "W4A8", "INT4"):
            rows_pe, cols_pe, ba, bw, pk, tpo = CNSB[prec]
            # ---- CNSB
            lbl = f"{prec.lower()}_uniform"
            e = cn_e[lbl]
            ce = {r["label"]: r for r in csv.DictReader((REPO / CNSB_R).open())}[lbl]
            mpc = float(e["mac_per_cycle_per_pe"])
            p_tot, p_upe, p_per, p_sob = (float(e["power_mW"]), float(e["u_pe_mW"]), float(e["periph_mW"]),
                                          float(e["sobol_mW"]))
            resid = p_tot - p_upe - p_per - p_sob
            e_data_grid = (n * (p_upe + resid) + (pr + pc) / 2 * p_per + p_sob) * PERIOD_NS       # pJ / data cycle
            e_ovh_grid = n * E_OVH_PE + ((pr + pc) / 2 * p_per + p_sob) * PERIOD_NS
            pj_peak = e_data_grid / (n * mpc)
            if shape != "1PE":
                check(abs(pj_peak - float(e[f"pJ_MAC_{shape}"])) < 1e-6, f"CNSB compose {shape} {prec}")
            else:
                check(abs(pj_peak - float(e["pJ_MAC_full"])) < 1e-6, f"CNSB 1PE {prec}")
            cells = []
            for L in LS:
                c = M.cnsb_block(prec, L, pr, pc)
                P, D = c["period"], c["D"]
                dA, dW = c["dA"], c["dW"]
                check(dA <= SUP and dW <= SUP, "CNSB feed fits")
                P576 = P                      # feed never binds: max(dA, dW) = 256 <= 576
                tc = pk * D / P576
                g = gmacs(n * 64 * tc, 1, ar["cnsb"])
                ests = (D * e_data_grid + (P576 - D) * e_ovh_grid) / (n * mpc * D)
                cells.append(f"{tc:5.3f} ({100 * D / P576:5.1f}%) / {g:6,.0f} [{ests:5.3f}]")
                out.append(dict(section="throughput", shape=shape, prec=prec, design="CNSB spatial Booth",
                                schedule="r4rows", L=L, outs_pe=rows_pe * cols_pe, tiles_per_output=tpo,
                                feed_A_b_per_cyc_half=dA, feed_W_b_per_cyc_half=dW, data_cycles=D,
                                overhead_cycles=P - D, period_nominal=P, period_576=P576,
                                peak_mac_tile_cycle=pk, mac_tile_cycle_576=round(tc, 4),
                                pct_of_peak=round(100 * D / P576, 2), area_um2=round(ar["cnsb"], 1),
                                area_basis="CSA pinned composite + synthesized CNSB edge blocks (r4rows)",
                                gmacs_mm2_peak=round(gmacs(n * 64 * pk, 1, ar["cnsb"]), 1),
                                gmacs_mm2_achievable=round(g, 1),
                                gmacs_mm2_achievable_r16rows_area=round(gmacs(n * 64 * tc, 1, ar["cnsb16"]), 1),
                                pJ_MAC_measured_peak=round(pj_peak, 4),
                                pJ_MAC_measured_basis="GL+PT, floating CSA route csa_20261002_distguide_spp_fixed, "
                                                      "uniform, data cycles only (drain excluded), edge blocks excluded",
                                est_pJ_MAC_at_L=round(ests, 4),
                                note="feed never binds; skew from per-edge-half offset SRAM addressing"))
            print(hdr.format(shape, prec, "CNSB (r4rows)", *cells))

            # ---- BP T1 as built
            s_cells_i, s_cells_f, nom_cells = [], [], []
            bc = bp_cyc[prec]
            edge_pc = ((pr + pc) / 2 * bc["periph"] + pr * bc["comb"] + bc["sobol"]) * PERIOD_NS
            if n == 1:
                edge_pc = (bc["total"] - bc["data"] / PERIOD_NS) * PERIOD_NS   # 1 PE: full measured rest
            pkbp = M.peak_tc(prec)
            for L in LS:
                s = M.schedule(M.Sch("T1"), prec, L, pr, pc)
                P, D, macs = s["period"], s["D_tot"], s["macs"]
                P_int = 2 * D + (P - D)
                P_flu = D * DEMAND_BP / SUP + (P - D)
                res = {}
                for tag, PP in (("nominal", P), ("576_int", P_int), ("576_fluid", P_flu)):
                    tc = macs / (n * 64 * PP)
                    stall = PP - P
                    e_blk = n * (D * bc["data"] + (P - D) * bc["ring"] + stall * bc["ring"]) + PP * edge_pc
                    res[tag] = (tc, gmacs(macs, PP, ar["bp"]), e_blk / macs, PP)
                # cross-check the fluid bound against the model's own section-6 'stall' rows
                if True:
                    for r in csv.DictReader((REPO / "sweeps/int_mode/bp/model_lap_schedules.csv").open()):
                        if (r["shape"], r["prec"], r["schedule"], r["L"], r["sram"]) == (
                                shape, prec, "T1", str(L), "(ii) 576 b every cyc"):
                            check(abs(float(r["stall_pct"]) - 100 * D / P_flu) < 0.01,
                                  f"BP fluid stall {shape} {prec} L={L}: {r['stall_pct']} vs {100 * D / P_flu:.2f}")
                for tag, lst in (("nominal", nom_cells), ("576_int", s_cells_i), ("576_fluid", s_cells_f)):
                    tc, g, pj, PP = res[tag]
                    lst.append(f"{tc:5.3f} ({100 * tc / pkbp:5.1f}%) / {g:6,.0f} [{pj:5.3f}]")
                    out.append(dict(section="throughput", shape=shape, prec=prec, design="BP T1 as built",
                                    schedule=tag, L=L, outs_pe=s["outs"], tiles_per_output=None,
                                    feed_A_b_per_cyc_half=DEMAND_BP, feed_W_b_per_cyc_half=DEMAND_BP,
                                    data_cycles=D, overhead_cycles=P - D, period_nominal=P,
                                    period_576=round(PP, 2), peak_mac_tile_cycle=pkbp,
                                    mac_tile_cycle_576=round(tc, 4), pct_of_peak=round(100 * tc / pkbp, 2),
                                    area_um2=round(ar["bp"], 1), area_basis="BP lap pinned routed composite",
                                    gmacs_mm2_peak=round(gmacs(n * 64 * pkbp, 1, ar["bp"]), 1),
                                    gmacs_mm2_achievable=round(g, 1),
                                    pJ_MAC_measured_peak=bp_peak_pj[prec],
                                    pJ_MAC_measured_basis="GL+PT, pinned BP lap route, uniform, data cycles only",
                                    est_pJ_MAC_at_L=round(pj, 4),
                                    note={"nominal": "unlimited feed (reference, not achievable at 576)",
                                          "576_int": "2 SRAM cycles per data edge; first 576 b held in PE bit pipe "
                                                     "(split load, control change only)",
                                          "576_fluid": "16/9 cycles per data edge; needs sub-word staging that "
                                                       "does not exist in BP mode (upper bound)"}[tag]))
            print(hdr.format(shape, prec, "BP T1, unlimited feed", *nom_cells))
            print(hdr.format(shape, prec, "BP T1 @576, 2 cyc/edge", *s_cells_i))
            print(hdr.format(shape, prec, "BP T1 @576, fluid 16/9", *s_cells_f))
        # ---- SC context
        for T in (128, 16):
            cells = []
            pk = 128 / T
            if T == 128:
                r = pin["csa"]
                p_upe, p_per, p_sob, p_tot = (float(r["u_pe_mW"]), float(r["u_peripheral_mW"]),
                                              float(r["sobol_mW"]), float(r["power_mW"]))
                basis = "pinned CSA route (comparison.txt)"
            else:
                r = tsw[("csa", 16)]
                p_upe, p_per, p_sob, p_tot = (float(r["u_pe_mW"]), float(r["u_peripheral_mW"]),
                                              float(r["sobol_mW"]), float(r["power_mW"]))
                basis = "floating CSA route T sweep (csa_t_sweep_20261003)"
            mpc = 64 * pk
            e_data_grid = (p_tot if n == 1 else n * p_upe + (pr + pc) / 2 * p_per + p_sob) * PERIOD_NS
            e_ovh_grid = n * E_OVH_PE + ((pr + pc) / 2 * p_per + p_sob) * PERIOD_NS if n > 1 else \
                E_OVH_PE + (p_tot - p_upe) * PERIOD_NS
            for L in LS:
                D = L * T // 128
                P = D + pr + pc - 2 + 8 * pc
                tc = pk * D / P
                g = gmacs(n * 64 * tc, 1, ar["csa"])
                ests = (D * e_data_grid + (P - D) * e_ovh_grid) / (n * mpc * D)
                cells.append(f"{tc:5.3f} ({100 * D / P:5.1f}%) / {g:6,.0f} [{ests:5.3f}]")
                out.append(dict(section="throughput", shape=shape, prec=f"SC T={T}", design=f"SC T={T} (plain CSA)",
                                schedule="SC", L=L, outs_pe=64, feed_A_b_per_cyc_half=576 * 16 / T,
                                feed_W_b_per_cyc_half=576 * 16 / T, data_cycles=D, overhead_cycles=P - D,
                                period_nominal=P, period_576=P, peak_mac_tile_cycle=pk,
                                mac_tile_cycle_576=round(tc, 4), pct_of_peak=round(100 * D / P, 2),
                                area_um2=round(ar["csa"], 1), area_basis="CSA pinned routed composite",
                                gmacs_mm2_peak=round(gmacs(n * 64 * pk, 1, ar["csa"]), 1),
                                gmacs_mm2_achievable=round(g, 1),
                                pJ_MAC_measured_peak=round(e_data_grid / (n * mpc), 4),
                                pJ_MAC_measured_basis=basis + ", data cycles only", est_pJ_MAC_at_L=round(ests, 4),
                                note="approximate arithmetic (not integer-exact)"))
            print(hdr.format(shape, f"T{T}", f"SC T={T} (CSA, context)", *cells))
    print("   GMAC/s/mm2 areas: CNSB on CSA pinned + its synthesized edge blocks (r4rows); BP on the BP-lap composite;")
    print("   SC on plain CSA.  CNSB never stalls (needs A 128 / W 256 b per cycle per edge half).")
    print(f"   est. pJ/MAC at L (ESTIMATE): data cycles at the measured power; each skew/drain cycle charged "
          f"{E_OVH_PE} pJ per PE (u_pe) plus edge power at its data-cycle value;")
    print("   BP stall cycles charged the measured ring-cycle u_pe energy (proxy, no stall cycle was measured).")
    print("   BP W4A8 data-cycle energy uses the INT8 peak point (no W4A8 peak point was measured on the lap route).")

    # ---------------------------------------------------------------- 3b. BP hybrid (not built)
    print("\n== 3b. BP hybrid H(TA,TW) under the same feed (NOT built: unsynthesized H combiner PLACEHOLDER")
    print("   +600.9 um2 per PE row, A must arrive as bit planes; RTL-verified on the unchanged array, no GL).")
    print("   Best (TA,TW) per point under the 2-cycle/edge bound; cells: (TA,TW) MAC/tile-cycle (% peak) / "
          "GMAC/s/mm2, 2 cyc/edge | fluid | with TA:1 + TW:1 feeder selects instead of bit-plane-major storage")
    for shape, (pr, pc) in SHAPES.items():
        n = pr * pc
        for prec in ("INT8", "W4A8", "INT4"):
            pkbp = M.peak_tc(prec)
            cells = []
            for L in LS:
                best = None
                for ta, tw in M.hyb_cands(prec):
                    sch = M.H(ta, tw)
                    if (ta, tw) == (1, PREC_BW[prec]):
                        continue          # H(1,BW) is T1
                    s = M.schedule(sch, prec, L, pr, pc)
                    P, D, macs = s["period"], s["D_tot"], s["macs"]
                    P_int, P_flu = 2 * D + (P - D), D * DEMAND_BP / SUP + (P - D)
                    a_h = M.area(sch, prec, shape)[0]
                    a_mux = a_h + M.feeder_mux_area(sch, prec, shape)
                    g_int = gmacs(macs, P_int, a_h)
                    if best is None or g_int > best["g_int"]:
                        best = dict(ta=ta, tw=tw, P=P, D=D, P_int=P_int, P_flu=P_flu, macs=macs, a=a_h,
                                    a_mux=a_mux, g_int=g_int, g_flu=gmacs(macs, P_flu, a_h),
                                    g_int_mux=gmacs(macs, P_int, a_mux), outs=s["outs"])
                b = best
                tc_i, tc_f = b["macs"] / (n * 64 * b["P_int"]), b["macs"] / (n * 64 * b["P_flu"])
                cells.append(f"({b['ta']},{b['tw']}) {tc_i:5.3f} ({100 * tc_i / pkbp:4.1f}%) / {b['g_int']:5,.0f} | "
                             f"{b['g_flu']:5,.0f} | {b['g_int_mux']:5,.0f}")
                out.append(dict(section="throughput", shape=shape, prec=prec, design="BP hybrid H (not built)",
                                schedule=f"H({b['ta']},{b['tw']}) 576_int", L=L, outs_pe=b["outs"],
                                feed_A_b_per_cyc_half=DEMAND_BP, feed_W_b_per_cyc_half=DEMAND_BP,
                                data_cycles=b["D"], overhead_cycles=b["P"] - b["D"], period_nominal=b["P"],
                                period_576=b["P_int"], peak_mac_tile_cycle=pkbp, mac_tile_cycle_576=round(tc_i, 4),
                                pct_of_peak=round(100 * tc_i / pkbp, 2), area_um2=round(b["a"], 1),
                                area_basis="BP lap composite + H combiner PLACEHOLDER (model_lap_schedules.py)",
                                gmacs_mm2_peak=round(gmacs(n * 64 * pkbp, 1, b["a"]), 1),
                                gmacs_mm2_achievable=round(b["g_int"], 1),
                                note=f"fluid 16/9 bound {b['g_flu']:.1f}; with feeder plane selects "
                                     f"(+{b['a_mux'] - b['a']:.0f} um2) {b['g_int_mux']:.1f}"))
            print("   {:5s} {:4s} ".format(shape, prec) + "   ".join(f"{c:>44s}" for c in cells))

    # ---------------------------------------------------------------- 4. measured energy
    print("\n== 4. Measured INT energy (drain excluded), pJ/MAC: 1 PE full / u_pe only / 4x4 / 4x8 composite")
    for lbl in ("int8_uniform", "w4a8_uniform", "int4_uniform", "int8_gauss8", "w4a8_gauss8", "int4_gauss8"):
        e = cn_e[lbl]
        print(f"   CNSB {lbl:14s} {float(e['pJ_MAC_full']):.4f} / {float(e['pJ_MAC_array']):.4f} / "
              f"{float(e['pJ_MAC_4x4']):.4f} / {float(e['pJ_MAC_4x8']):.4f}   P = {float(e['power_mW']):.3f} mW at "
              f"{float(e['mac_per_cycle_per_pe']):.0f} MAC/cycle/PE")
    for lbl in ("int8_uniform_L49152_d", "int4_uniform_L98304_d", "int8_uniform_L1024_dr", "int8_uniform_L1024_all"):
        e = bp_e[lbl]
        print(f"   BP   {lbl:24s} 1 PE {float(e['pJ_MAC']):.4f}  (P {float(e['power_mW']):.3f} mW)")
    sc = cn_e["SC_T128"]
    print(f"   SC T=128 floating route (the CNSB measurement's own reference): {float(sc['pJ_MAC_full']):.4f} 1 PE, "
          f"{float(sc['pJ_MAC_4x4']):.4f} 4x4;  pinned CSA: {float(pin['csa']['pJ_MAC']):.4f} 1 PE, "
          f"{float(pin['csa']['power_mW']):.3f} vs {float(sc['power_mW']):.3f} mW floating "
          f"({100 * (float(pin['csa']['power_mW']) / float(sc['power_mW']) - 1):+.1f}%)")

    path = REPO / "sweeps/int_mode/cnsb_achievable_576.csv"
    keys = []
    for r in out:
        for k in r:
            if k not in keys:
                keys.append(k)
    with path.open("w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=keys)
        w.writeheader()
        w.writerows(out)
    print(f"\n-> {path.relative_to(REPO)} ({len(out)} rows); checks: "
          + ("all passed" if not FAILS else f"{len(FAILS)} MISMATCHES"))
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
