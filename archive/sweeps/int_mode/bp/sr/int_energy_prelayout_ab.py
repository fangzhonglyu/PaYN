#!/usr/bin/env python3
"""Summary of the pre-layout INT energy A/B of the lap-length family
(sweeps/int_mode/bp/sr/run_int_energy_prelayout_ab.sh): BP ring g = 8 (lap),
sub-rings g = 4 (sr4) and g = 2 (sr2), in-place doubling g = 1 (ipd).

Reads OUT/results.csv (one row per qualified arm / point, the columns of
bp_int_energy_row.py plus "arm"), OUT/<arm>/<label>/power/block_power.csv,
and the routed lap campaign's results.csv (ROUTED, the calibration).

Definitions (T = 2.5 ns; E = P * T * active intervals):
  pJ/MAC (dr)        the headline: data + lap intervals, drain excluded
  e_data             P(d) * T: energy of one data interval (interval-count
                     classing, as the routed flow: data = u < NB of every pass)
  e_lap              (E(dr) - E(d)) / lap intervals (the same classing: the
                     g intervals u = NB .. NB+g-1 of every non-final pass; the
                     first holds the pass's last MAC, the lap shift that closes
                     the pass falls in the next pass's u = 0 data interval)
  e_mac, e_lapedge   the same from the cause-classed windows dc / drc: e_mac =
                     P(dc) * T over intervals that follow a MAC edge, e_lapedge
                     = (E(drc) - E(dc)) / lap intervals over intervals that
                     follow a lap (ring_q) edge; comparable across g
  e_drain            (E(all) - E(dr)) / drain intervals (L = 1024)
Calibration: k = routed / pre-layout of the lap arm at the routed campaign's
points (pJ/MAC); "calibrated" = pre-layout * k of the matching window
(dr / all: k of INT8 or INT4 L1024 dr / all; d: k of the long-L d point).

  int_energy_prelayout_ab.py OUT [--routed ROUTED_DIR] [--json out.json]
                             [--corrections [--robust OUT2]]

--corrections (opt-in; without it the output is unchanged) appends:
  8. the per-data-cycle mux overhead from the long-L data-only window (the
     L = 1024 d window's u = 0 slots hold the shift that closed the previous
     pass, so its e_data carries part of the lap cost), with the closing-edge
     share of every d window;
  9. the calibration bracket of the headline: central = cause-classed per-class
     (section 7), pessimistic = every g < 8 interval at k_data (lap edges gain
     like data cycles), optimistic = one ratio for all intervals (= pre-layout
     relative change); and the L = 4096 caveats;
 10. with --robust OUT2: the same bracket for the points of a second A/B run
     with another operand distribution (k ratios from OUT's routed calibration).
"""
from __future__ import annotations

import argparse
import csv
import json
from collections import defaultdict
from pathlib import Path

T_NS = 2.5
ARMS = [("lap", 8), ("sr4", 4), ("sr2", 2), ("ipd", 1)]
G = dict(ARMS)
ROUTED = Path("build/power_char/int_mode_energy_20261004_lap/bp/csa_bp_20261004_lap_distguide_spp_pins")
# The estimate this A/B confirms or refutes (INT8, 1 PE, from the routed lap
# per-cycle energies: data 44.6 pJ, lap 15.4 pJ, mux overhead not included).
ESTIMATE = {1024: {8: 0.453, 4: 0.401, 2: 0.374, 1: 0.361}, 4096: {8: 0.374, 4: 0.361, 2: 0.355, 1: 0.351}}
EST_E_DATA, EST_E_LAP = 44.6, 15.4


def label_parts(label: str):
    prec, dist, l, win = label.split("_")
    return prec, dist, int(l[1:]), win


def pct(a: float, b: float) -> str:
    return f"{100.0 * (a / b - 1.0):+.1f}%"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("out", type=Path)
    ap.add_argument("--routed", type=Path, default=ROUTED)
    ap.add_argument("--json", type=Path, dest="json_path")
    ap.add_argument("--corrections", action="store_true",
                    help="append sections 8-10 (clean data-cycle overhead, calibration bracket)")
    ap.add_argument("--robust", type=Path, help="with --corrections: second A/B OUT (other distribution)")
    args = ap.parse_args()
    if args.robust and not args.corrections:
        ap.error("--robust needs --corrections")
    out = args.out

    rows = {}
    for r in csv.DictReader((out / "results.csv").open()):
        rows[(r["arm"], r["label"])] = r
    routed = {r["label"]: r for r in csv.DictReader((args.routed / "results.csv").open())}

    def get(arm, prec, L, win, key="power_mW"):
        r = rows.get((arm, f"{prec}_uniform_L{L}_{win}"))
        return None if r is None else float(r[key])

    def cyc(arm, prec, L, win, key):
        r = rows.get((arm, f"{prec}_uniform_L{L}_{win}"))
        return None if r is None else int(r[key])

    def energy(arm, prec, L, win):      # pJ in the window
        p = get(arm, prec, L, win)
        return None if p is None else p * T_NS * cyc(arm, prec, L, win, "active_cycles")

    def blocks(arm, label):
        p = out / arm / label / "power" / "block_power.csv"
        if not p.is_file():
            return None
        return {b["block"]: float(b["total_mW"]) for b in csv.DictReader(p.open())}

    lines: list[str] = []
    say = lines.append
    res: dict = {"points": {}, "per_cycle": {}, "calibration": {}, "estimate": {}}
    present = [a for a, _ in ARMS if any(k[0] == a for k in rows)]

    # ------------------------------------------------------ identity checks
    import hashlib, re
    TBDIR = "designs/payn/power/power_payn_array_bp_int.sv"
    ident = {"stim_identical": 0, "stim_points": 0, "operand_tc_identical": 0, "operand_tc_points": 0,
             "routed_trace_identical": [], "routed_trace_differs": []}
    labels = sorted({lab for (_, lab) in rows})
    for lab in labels:
        arms_here = [a for a in present if (a, lab) in rows]
        sh = {a: tuple(hashlib.sha256((out / a / lab / "stim" / f).read_bytes()).hexdigest()
                       for f in ("intb_a.hex", "intb_w.hex")) for a in arms_here}
        ident["stim_points"] += 1
        ident["stim_identical"] += len(set(sh.values())) == 1
        tc = {}
        for a in arms_here:
            m = re.search(r"operand TC=(\d+)", (out / a / lab / "gl" / "saif_validation.log").read_text())
            tc[a] = int(m[1]) if m else None
        ident["operand_tc_points"] += 1
        ident["operand_tc_identical"] += len(set(tc.values())) == 1 and None not in tc.values()
        ident.setdefault("operand_tc", {})[lab] = tc
        if lab in routed and ("lap", lab) in rows:
            same = all((out / "lap" / lab / kind / TBDIR / f).read_bytes() ==
                       (args.routed / lab / kind / TBDIR / f).read_bytes()
                       for kind in ("rtl", "gl") for f in ("bpt_trace.txt", "bpe_saif.txt"))
            ident["routed_trace_identical" if same else "routed_trace_differs"].append(lab)
    res["identity"] = ident

    say("Pre-layout INT energy A/B, single PE, lap-length family (g = tiles per doubling mux)")
    say("  PT-PX on the synthesized netlists (no parasitics, ideal clock), SAIF from SDF-annotated GL of")
    say("  identical stimulus (INT uniform random, operands of the routed lap campaign), drain excluded")
    say("  unless noted; every point bit-exact (RTL and GL) with GL trace == RTL trace.")
    say("  arms: " + ", ".join(f"{a} (g={G[a]})" for a in present))
    say(f"  stimulus: operand files identical across arms for {ident['stim_identical']}/{ident['stim_points']} points")
    bywin = defaultdict(lambda: [0, 0, 0.0])
    for lab, tc in ident.get("operand_tc", {}).items():
        w = label_parts(lab)[3]
        vals = [v for v in tc.values() if v is not None]
        bywin[w][0] += 1
        bywin[w][1] += len(set(vals)) == 1
        if vals:
            bywin[w][2] = max(bywin[w][2], (max(vals) - min(vals)) / min(vals))
    ident["operand_tc_by_window"] = {w: dict(points=v[0], identical=v[1], max_rel_spread=v[2]) for w, v in bywin.items()}
    say("  operand-net toggles in the window (validate_sc_power_saif.py 'operand TC': a/w bits and signs), across arms: "
        + "; ".join(f"{w}: identical {v[1]}/{v[0]}" + (f" (max spread {100 * v[2]:.3f}%)" if v[2] else "")
                    for w, v in sorted(bywin.items())))
    say("   (d / dc spread: with 1-2 edge laps the w_signs_in change before a pass lands in a data interval;")
    say("    dr / drc / all hold the same stimulus edges in every arm)")
    say(f"  lap arm vs the routed lap campaign: RTL and GL bpt_trace.txt + bpe_saif.txt byte-identical for "
        f"{len(ident['routed_trace_identical'])} points {ident['routed_trace_identical']}"
        + (f"; DIFFER for {ident['routed_trace_differs']}" if ident['routed_trace_differs'] else ""))
    say("")

    # ------------------------------------------------------ headline pJ/MAC
    say("1. pJ/MAC, data + lap intervals (dr), pre-layout absolute and vs lap")
    hdr = f"  {'prec':5s} {'L':>6s} " + " ".join(f"{a + ' g=' + str(G[a]):>16s}" for a in present)
    say(hdr)
    for prec in ("int8", "int4"):
        for L in (1024, 4096):
            cells = []
            base = get("lap", prec, L, "dr", "pJ_MAC")
            for a in present:
                v = get(a, prec, L, "dr", "pJ_MAC")
                if v is None:
                    cells.append(f"{'-':>16s}")
                    continue
                res["points"].setdefault(f"{prec}_L{L}_dr", {})[a] = v
                cells.append(f"{v:8.4f} {pct(v, base) if base and a != 'lap' else '':>7s}")
            say(f"  {prec.upper():5s} {L:6d} " + " ".join(cells))
    say("")
    say("   same, u_pe only (array pJ/MAC)")
    for prec in ("int8", "int4"):
        for L in (1024, 4096):
            base = get("lap", prec, L, "dr", "array_pJ_MAC")
            cells = []
            for a in present:
                v = get(a, prec, L, "dr", "array_pJ_MAC")
                cells.append(f"{'-':>16s}" if v is None else f"{v:8.4f} {pct(v, base) if base and a != 'lap' else '':>7s}")
            say(f"  {prec.upper():5s} {L:6d} " + " ".join(cells))
    say("")
    say("   drain included (all), L = 1024")
    for prec in ("int8", "int4"):
        base = get("lap", prec, 1024, "all", "pJ_MAC")
        cells = []
        for a in present:
            v = get(a, prec, 1024, "all", "pJ_MAC")
            cells.append(f"{'-':>16s}" if v is None else f"{v:8.4f} {pct(v, base) if base and a != 'lap' else '':>7s}")
        say(f"  {prec.upper():5s} {1024:6d} " + " ".join(cells))
    say("")

    # ------------------------------------------------------ per-cycle energies
    say("2. Per-interval energies (pJ), pre-layout")
    say("   interval-count classing (d / dr, as the routed flow) and cause classing (dc / drc)")
    say(f"  {'prec':5s} {'L':>6s} {'arm':4s} {'g':>2s} {'e_data':>8s} {'vs lap':>7s} {'e_lap':>7s} "
        f"{'e_mac':>8s} {'vs lap':>7s} {'e_lapedge':>9s} {'vs lap':>7s} {'lap/pass':>8s} {'e_drain':>8s}")
    for prec in ("int8", "int4"):
        for L in (1024, 4096):
            base = {}
            for a in present:
                g = G[a]
                ed = get(a, prec, L, "d")
                Ed, Edr = energy(a, prec, L, "d"), energy(a, prec, L, "dr")
                Edc, Edrc = energy(a, prec, L, "dc"), energy(a, prec, L, "drc")
                nr = cyc(a, prec, L, "dr", "ring_cycles")
                e_data = ed * T_NS if ed is not None else None
                e_lap = (Edr - Ed) / nr if None not in (Edr, Ed) and nr else None
                e_mac = get(a, prec, L, "dc") * T_NS if get(a, prec, L, "dc") is not None else None
                nrc = cyc(a, prec, L, "drc", "ring_cycles")
                e_lapedge = (Edrc - Edc) / nrc if None not in (Edrc, Edc) and nrc else None
                Eall = energy(a, prec, L, "all")
                nd = cyc(a, prec, L, "all", "drain_cycles")
                e_drain = (Eall - Edr) / nd if None not in (Eall, Edr) and nd else None
                rec = dict(g=g, e_data=e_data, e_lap=e_lap, e_mac=e_mac, e_lapedge=e_lapedge,
                           lap_energy_per_pass_pJ=(g * e_lapedge) if e_lapedge is not None else None,
                           e_drain=e_drain)
                res["per_cycle"].setdefault(f"{prec}_L{L}", {})[a] = rec
                if a == "lap":
                    base = rec
                f = lambda v, w=8, d=2: f"{v:{w}.{d}f}" if v is not None else f"{'-':>{w}s}"
                rel = lambda k: (pct(rec[k], base[k]) if a != "lap" and rec[k] is not None and base.get(k) else "")
                say(f"  {prec.upper():5s} {L:6d} {a:4s} {g:2d} {f(e_data)} {rel('e_data'):>7s} {f(e_lap, 7)} "
                    f"{f(e_mac)} {rel('e_mac'):>7s} {f(e_lapedge, 9)} {rel('e_lapedge'):>7s} "
                    f"{f(rec['lap_energy_per_pass_pJ'], 8, 1)} {f(e_drain)}")
    say("   lap/pass = g * e_lapedge: energy of one complete g-edge lap (every tile doubled once)")
    for key, recs in res["per_cycle"].items():
        pts = [(v["g"], v["lap_energy_per_pass_pJ"]) for v in recs.values() if v["lap_energy_per_pass_pJ"] is not None]
        if len(pts) < 3:
            continue
        gm = sum(g for g, _ in pts) / len(pts); ym = sum(y for _, y in pts) / len(pts)
        b = sum((g - gm) * (y - ym) for g, y in pts) / sum((g - gm) ** 2 for g, _ in pts)
        a0 = ym - b * gm
        res.setdefault("lap_per_pass_fit", {})[key] = dict(fixed_pJ=a0, per_edge_pJ=b,
                                                          residuals=[y - (a0 + b * g) for g, y in sorted(pts)])
        say(f"   fit {key}: lap/pass = {a0:.1f} pJ + {b:.2f} pJ x g  (residuals "
            + ", ".join(f"{y - (a0 + b * g):+.1f}" for g, y in sorted(pts)) + " for g = 1, 2, 4, 8)")
    say("   (the fixed part is the pass-closing lap edge, which also starts the next plane's popcounts;")
    say("    the estimate assumed lap energy proportional to g)")
    say("")

    # ------------------------------------------------------ block split
    say("3. Where the difference sits: block power (mW) in the dr window, INT8 L = 1024 and 4096")
    blks = ["tiles_seq", "tiles_comb", "core_other_seq", "core_other_comb", "pe_other", "u_peripheral",
            "u_combiner", "u_a_rng", "u_w_rng", "top_other"]
    for L in (1024, 4096):
        say(f"   INT8 L={L} dr: per-MAC energy by block (fJ/MAC) = mW * 2.5 ns / MAC-per-cycle")
        say(f"  {'block':16s} " + " ".join(f"{a:>9s}" for a in present))
        tab = {}
        for a in present:
            b = blocks(a, f"int8_uniform_L{L}_dr")
            mpc = get(a, "int8", L, "dr", "mac_per_cycle")
            if b is None or mpc is None:
                continue
            tab[a] = {k: 1e3 * v * T_NS / mpc for k, v in b.items()}
        for k in blks:
            say(f"  {k:16s} " + " ".join(f"{tab[a][k]:9.2f}" if a in tab else f"{'-':>9s}" for a in present))
        say(f"  {'total':16s} " + " ".join(f"{sum(tab[a].values()):9.2f}" if a in tab else f"{'-':>9s}" for a in present))
        res.setdefault("block_fJ_per_MAC", {})[f"int8_L{L}_dr"] = tab
    say("   core_other_comb holds the sub-ring head muxes (16 / 32 / 64 x 24-bit AO22) and their select trees;")
    say("   pe_other the BP west <<1 mux and ring_q (lap only).")
    say("")

    # ------------------------------------------------------ calibration
    say("4. Calibration against the routed lap campaign (csa_bp_20261004_lap_distguide_spp_pins)")
    say(f"  {'point':24s} {'routed':>8s} {'pre-layout':>10s} {'routed/pre':>10s}")
    k = {}
    for lab in ("int8_uniform_L1024_dr", "int8_uniform_L49152_d", "int8_uniform_L1024_all",
                "int4_uniform_L1024_dr", "int4_uniform_L98304_d", "int4_uniform_L1024_all"):
        if lab not in routed or ("lap", lab) not in rows:
            continue
        rv, pv = float(routed[lab]["pJ_MAC"]), float(rows[("lap", lab)]["pJ_MAC"])
        k[lab] = rv / pv
        say(f"  {lab:24s} {rv:8.4f} {pv:10.4f} {rv / pv:10.3f}")
    res["calibration"]["routed_over_prelayout"] = k
    say("   (same stimulus, same windows; the ratio is the parasitic + clock-tree share the pre-layout run lacks)")
    # per-cycle calibration of the lap arm
    for prec, longL, kd_lab, kdr_lab in (("int8", 49152, "int8_uniform_L49152_d", "int8_uniform_L1024_dr"),
                                          ("int4", 98304, "int4_uniform_L98304_d", "int4_uniform_L1024_dr")):
        if kd_lab in routed and kdr_lab in routed:
            rd = float(routed[kd_lab]["power_mW"]) * T_NS
            nd = int(routed[kdr_lab]["data_cycles"]); nr = int(routed[kdr_lab]["ring_cycles"])
            Edr = float(routed[kdr_lab]["power_mW"]) * T_NS * int(routed[kdr_lab]["active_cycles"])
            rl = (Edr - nd * rd) / nr
            pd_ = get("lap", prec, longL, "d")
            pdr = energy("lap", prec, 1024, "dr")
            if pd_ is not None and pdr is not None:
                pdd = pd_ * T_NS
                pl = (pdr - nd * pdd) / nr
                say(f"   {prec.upper()} lap per-interval, as the estimate derives them (data from long-L d, lap from L1024 dr):"
                    f" routed data {rd:.1f} / lap {rl:.1f} pJ; pre-layout {pdd:.1f} / {pl:.1f} pJ;"
                    f" ratio {rd / pdd:.3f} / {rl / pl:.3f}")
                res["calibration"][f"{prec}_lap_per_interval"] = dict(routed_data=rd, routed_lap=rl,
                                                                     pre_data=pdd, pre_lap=pl,
                                                                     k_data=rd / pdd, k_lap=rl / pl)
    say("")

    # ------------------------------------------------------ estimate
    say("5. Against the estimate (INT8, 1 PE, pJ/MAC dr; estimate from routed lap per-cycle energies, no mux cost)")
    say(f"  {'L':>6s} {'g':>2s} {'estimate':>8s} {'est vs g8':>9s} | {'pre-layout':>10s} {'vs lap':>7s} | "
        f"{'calibrated':>10s} {'cal - est':>9s} | {'per-class':>9s} {'vs lap':>7s} | {'cause cls':>9s} {'vs lap':>7s}")
    kc = res["calibration"].get("int8_lap_per_interval", {})
    # cause-classed per-class ratios: k_data on MAC intervals, k_lapedge fitted so that the lap arm
    # reproduces the routed INT8 L1024 dr energy
    kcc = None
    if kc and ("lap", "int8_uniform_L1024_dc") in rows and "int8_uniform_L1024_dr" in routed:
        r = routed["int8_uniform_L1024_dr"]
        Er = float(r["power_mW"]) * T_NS * int(r["active_cycles"])
        Em = energy("lap", "int8", 1024, "dc"); El = energy("lap", "int8", 1024, "drc") - Em
        kcc = dict(k_data=kc["k_data"], k_lapedge=(Er - kc["k_data"] * Em) / El)
        res["calibration"]["int8_cause_per_class"] = kcc
    kdr = k.get("int8_uniform_L1024_dr")
    for L in (1024, 4096):
        for a, g in ARMS:
            if a not in present:
                continue
            est = ESTIMATE[L][g]
            pv = get(a, "int8", L, "dr", "pJ_MAC")
            pl = get("lap", "int8", L, "dr", "pJ_MAC")
            if pv is None:
                continue
            cal = pv * kdr if kdr else None
            # per-class: data intervals x k_data, lap intervals x k_lap (count classing, the
            # estimate's own split of the routed lap numbers)
            cal2 = None
            Ed, Edr = energy(a, "int8", L, "d"), energy(a, "int8", L, "dr")
            if kc and None not in (Ed, Edr):
                macs = cyc(a, "int8", L, "dr", "data_cycles") * 128
                cal2 = (Ed * kc["k_data"] + (Edr - Ed) * kc["k_lap"]) / macs
            cal3 = None
            Em, Edrc = energy(a, "int8", L, "dc"), energy(a, "int8", L, "drc")
            if kcc and None not in (Em, Edrc):
                macs = cyc(a, "int8", L, "drc", "data_cycles") * 128
                cal3 = (Em * kcc["k_data"] + (Edrc - Em) * kcc["k_lapedge"]) / macs
            base2 = res["estimate"].get(f"L{L}", {}).get("lap", {}).get("calibrated_per_class")
            base3 = res["estimate"].get(f"L{L}", {}).get("lap", {}).get("calibrated_cause_per_class")
            res["estimate"].setdefault(f"L{L}", {})[a] = dict(estimate=est, prelayout=pv,
                                                              prelayout_vs_lap=pv / pl - 1 if pl else None,
                                                              calibrated=cal, calibrated_per_class=cal2,
                                                              calibrated_cause_per_class=cal3)
            c2 = f"{cal2:9.3f} {pct(cal2, base2) if a != 'lap' and base2 else '':>7s}" if cal2 else f"{'-':>9s} {'':>7s}"
            c2 += (f" | {cal3:9.3f} {pct(cal3, base3) if a != 'lap' and base3 else '':>7s}" if cal3 else "")
            say(f"  {L:6d} {g:2d} {est:8.3f} {pct(est, ESTIMATE[L][8]) if g != 8 else '':>9s} | {pv:10.4f} "
                f"{pct(pv, pl) if a != 'lap' and pl else '':>7s} | "
                + (f"{cal:10.3f} {cal - est:+9.3f}" if cal else f"{'-':>10s} {'':>9s}") + f" | {c2}")
    say("   calibrated = pre-layout x (routed / pre-layout of lap at INT8 L1024 dr); at L = 4096 the lap row")
    say("   tests that single ratio against the estimate's own L-scaling.  per-class = data-window energy x k_data")
    say("   + lap-window energy x k_lap (section 4 ratios); cause cls = MAC intervals (dc) x k_data + lap-edge")
    say("   intervals (drc - dc) x k_lapedge, k_lapedge set so the lap arm reproduces routed INT8 L1024 dr"
        + (f" ({kcc['k_lapedge']:.3f})." if kcc else "."))
    say("   Both per-class columns reproduce the estimate's routed-derived lap value at L = 4096; the single ratio")
    say("   does not (it applies the data-heavy ratio to lap intervals, which gain less from layout).")
    say("")

    # ------------------------------------------------------ L-scaling check
    say("6. L-scaling check (what the estimate assumes): L = 4096 predicted from the L = 1024 per-interval")
    say("   energies, E_block = BW*NB*e + (BW-1)*g*e_l, against the measured L = 4096 point")
    say(f"  {'prec':5s} {'arm':4s} {'pred dr':>8s} {'meas dr':>8s} {'err':>7s} {'pred drc':>8s} {'meas drc':>8s} {'err':>7s}")
    for prec, ba, bw in (("int8", 8, 8), ("int4", 4, 4)):
        nb = 4096 // 128
        macs = bw * nb * 8192 // (ba * bw)
        for a in present:
            pc = res["per_cycle"].get(f"{prec}_L1024", {}).get(a)
            if not pc:
                continue
            cells = []
            for e, el, win in ((pc["e_data"], pc["e_lap"], "dr"), (pc["e_mac"], pc["e_lapedge"], "drc")):
                meas = get(a, prec, 4096, win, "pJ_MAC")
                if None in (e, el, meas):
                    cells.append(f"{'-':>8s} {'-':>8s} {'-':>7s}")
                    continue
                pred = (bw * nb * e + (bw - 1) * G[a] * el) / macs
                cells.append(f"{pred:8.4f} {meas:8.4f} {pct(pred, meas):>7s}")
                res.setdefault("l_scaling", {}).setdefault(f"{prec}_{win}", {})[a] = dict(pred=pred, meas=meas)
            say(f"  {prec.upper():5s} {a:4s} " + " ".join(cells))
    say("")

    # ------------------------------------------------------ calibrated table, both precisions
    say("7. Calibrated pJ/MAC (dr), cause-classed per-class (MAC x k_data, lap edges x k_lapedge; ratios per")
    say("   precision from the routed lap campaign), and the single-ratio value in brackets")
    say(f"  {'prec':5s} {'L':>6s} " + " ".join(f"{a + ' g=' + str(G[a]):>22s}" for a in present))
    for prec, longL, mpc in (("int8", 49152, 128), ("int4", 98304, 512)):
        ld, ldr = f"{prec}_uniform_L{longL}_d", f"{prec}_uniform_L1024_dr"
        if ld not in routed or ldr not in routed or ("lap", ld) not in rows or ("lap", f"{prec}_uniform_L1024_dc") not in rows:
            continue
        kd = float(routed[ld]["power_mW"]) / float(rows[("lap", ld)]["power_mW"])
        r = routed[ldr]
        Er = float(r["power_mW"]) * T_NS * int(r["active_cycles"])
        Em = energy("lap", prec, 1024, "dc"); El = energy("lap", prec, 1024, "drc") - Em
        kl = (Er - kd * Em) / El
        k1 = float(r["pJ_MAC"]) / float(rows[("lap", ldr)]["pJ_MAC"])
        res["calibration"][f"{prec}_cause_per_class"] = dict(k_data=kd, k_lapedge=kl, k_single=k1)
        for L in (1024, 4096):
            cells, base = [], None
            for a in present:
                Em_, Edrc = energy(a, prec, L, "dc"), energy(a, prec, L, "drc")
                pv = get(a, prec, L, "dr", "pJ_MAC")
                if None in (Em_, Edrc, pv):
                    cells.append(f"{'-':>22s}")
                    continue
                v = (kd * Em_ + kl * (Edrc - Em_)) / (cyc(a, prec, L, "drc", "data_cycles") * mpc)
                base = base or v
                res.setdefault("calibrated", {}).setdefault(f"{prec}_L{L}", {})[a] = dict(cause_per_class=v, single_ratio=pv * k1)
                cells.append(f"{v:6.4f} {pct(v, base) if a != 'lap' else '':>6s} [{pv * k1:6.4f}]")
            say(f"  {prec.upper():5s} {L:6d} " + " ".join(cells))
        say(f"   {prec.upper()}: k_data {kd:.3f} (long-L d), k_lapedge {kl:.3f}, single ratio {k1:.3f} (L1024 dr)")
    say("")

    if args.corrections:
        corrections(rows, routed, res, say, present, args.robust)

    text = "\n".join(lines) + "\n"
    print(text, end="")
    (args.json_path or (out / "summary.json")).write_text(json.dumps(res, indent=2, default=str) + "\n")
    return 0


LONG_L = {"int8": 49152, "int4": 98304}
BW_OF = {"int8": 8, "int4": 4}


def corrections(rows, routed, res, say, present, robust_out):
    """Sections 8-10 (--corrections); see the module docstring."""
    import re

    def row(rws, arm, prec, dist, L, win):
        return rws.get((arm, f"{prec}_{dist}_L{L}_{win}"))

    def op_tc(r):
        m = re.search(r"operand TC=(\d+)", r["saif_validation"])
        return int(m[1]) if m else None

    def e_win(r):                       # pJ in the window
        return float(r["power_mW"]) * T_NS * int(r["active_cycles"])

    cor = res.setdefault("corrections", {})

    pct2 = lambda x, y: f"{100.0 * (x / y - 1.0):+.2f}%"
    # ------------------------------------------------------ 8. clean data-cycle overhead
    say("8. Per-data-cycle cost of the doubling hardware: data-only (d) windows by closing-edge share")
    say("   Interval-count classing puts the u = 0 slot of every pass in the d window; that slot holds the")
    say("   shift edge that closed the previous pass (a lap edge in g < 8 designs: the whole doubling for")
    say("   g = 1).  closing = blocks x (BW-1) lap closings in the window; share = closing / data intervals.")
    say(f"  {'prec':5s} {'L':>6s} {'blk':>4s} {'data':>5s} {'closing':>7s} {'share':>6s} | "
        + " ".join(f"{a + ' e_data':>12s} {'vs lap':>7s}" for a in present) + " | operand TC vs lap")
    for prec in ("int8", "int4"):
        for L in (LONG_L[prec], 4096, 1024):
            rl = row(rows, "lap", prec, "uniform", L, "d")
            if rl is None:
                continue
            blk, nd = int(rl["blocks"]), int(rl["data_cycles"])
            closing = blk * (BW_OF[prec] - 1)
            cells, tcs, rec = [], [], {}
            for a in present:
                r = row(rows, a, prec, "uniform", L, "d")
                if r is None:
                    cells.append(f"{'-':>12s} {'':>7s}")
                    continue
                e = float(r["power_mW"]) * T_NS
                el = float(rl["power_mW"]) * T_NS
                rec[a] = dict(e_data_pJ=e, vs_lap=e / el - 1, operand_tc=op_tc(r))
                cells.append(f"{e:12.3f} {pct2(e, el) if a != 'lap' else '':>7s}")
                if a != "lap":
                    d = op_tc(r) - op_tc(rl)
                    tcs.append(f"{a} {d:+d}" + (f" ({100 * d / op_tc(rl):+.4f}%)" if d else ""))
            cor.setdefault("d_window_overhead", {})[f"{prec}_L{L}"] = dict(blocks=blk, data_cycles=nd,
                                                                         closing_edges=closing, arms=rec)
            say(f"  {prec.upper():5s} {L:6d} {blk:4d} {nd:5d} {closing:7d} {100 * closing / nd:5.2f}% | "
                + " ".join(cells) + " | " + ", ".join(tcs))
    say("   -> the long-L row (0.2% closing share) is the per-data-cycle cost of the doubling hardware; the")
    say("      L = 1024 d-window e_data of section 2 (and any 'data cycle' quoted from it) includes 9-11% lap")
    say("      closings and overstates the mux overhead about 2x.")
    for prec in ("int8", "int4"):
        L = LONG_L[prec]
        rl = row(rows, "lap", prec, "uniform", L, "d")
        rr = routed.get(f"{prec}_uniform_L{L}_d")
        if rl is None or rr is None:
            continue
        kd = float(rr["power_mW"]) / float(rl["power_mW"])
        el = float(rl["power_mW"]) * T_NS
        parts = []
        for a in present:
            r = row(rows, a, prec, "uniform", L, "d")
            if r is None:
                continue
            e = float(r["power_mW"]) * T_NS
            cor.setdefault("data_cycle_clean", {}).setdefault(prec, {})[a] = dict(pre_pJ=e, vs_lap=e / el - 1,
                                                                                  calibrated_pJ=e * kd)
            parts.append(f"{a} {e:.2f} pre / {e * kd:.2f} cal" + (f" ({pct2(e, el)})" if a != "lap" else ""))
        say(f"   {prec.upper()} data cycle, long-L d, pJ (calibrated x k_data {kd:.4f}; routed lap "
            f"{float(rr['power_mW']) * T_NS:.2f}): " + "; ".join(parts))
    say("")

    # ------------------------------------------------------ 9. calibration bracket
    def bracket(rws, prec, dist, L, kd, kl, k1, base_central=None):
        out = {}
        for a in present:
            rdc, rdrc, rdr = (row(rws, a, prec, dist, L, w) for w in ("dc", "drc", "dr"))
            if None in (rdc, rdrc, rdr):
                return None
            macs = int(rdrc["data_cycles"]) * float(rdrc["mac_per_data_cycle"])
            Em, Edrc = e_win(rdc), e_win(rdrc)
            central = (kd * Em + kl * (Edrc - Em)) / macs
            out[a] = dict(pre_dr=float(rdr["pJ_MAC"]), central=central,
                          pess=central if a == "lap" else kd * Edrc / macs,
                          opt_abs=float(rdr["pJ_MAC"]) * k1,
                          tc_dr=op_tc(rdr), tc_drc=op_tc(rdrc), status=(rdr["status"], rdrc["status"]))
        lap = out["lap"]
        for a, v in out.items():
            v["central_vs_lap"] = v["central"] / lap["central"] - 1
            v["pess_vs_lap"] = v["pess"] / lap["central"] - 1
            v["opt_vs_lap"] = v["pre_dr"] / lap["pre_dr"] - 1
        return out

    say("9. Calibrated pJ/MAC (dr) with its bracket.  central = cause-classed per-class (section 7);")
    say("   pessimistic = every g < 8 interval x k_data (its lap edges gain from layout like data cycles,")
    say("   likely nearest the truth for g = 1, whose single lap edge per pass also starts the next plane's")
    say("   popcounts); optimistic = one ratio for every interval (= the pre-layout relative change).")
    say(f"  {'prec':5s} {'L':>6s} {'arm':4s} {'g':>2s} {'pre-layout':>10s} {'central':>8s} {'vs lap':>7s}"
        f" {'pessim.':>8s} {'vs lap':>7s} {'optim.':>8s} {'vs lap':>7s}   range of the saving")
    for prec in ("int8", "int4"):
        c = res["calibration"].get(f"{prec}_cause_per_class")
        if not c:
            continue
        for L in (1024, 4096):
            b = bracket(rows, prec, "uniform", L, c["k_data"], c["k_lapedge"], c["k_single"])
            if b is None:
                continue
            cor.setdefault("bracket", {})[f"{prec}_L{L}"] = b
            for a in present:
                v = b[a]
                rng = "" if a == "lap" else (f"{100 * v['central_vs_lap']:+.1f}% "
                                             f"({100 * v['pess_vs_lap']:+.1f}% to {100 * v['opt_vs_lap']:+.1f}%)")
                f = lambda x: f"{100 * x:+6.1f}%" if a != "lap" else f"{'':>7s}"
                say(f"  {prec.upper():5s} {L:6d} {a:4s} {G[a]:2d} {v['pre_dr']:10.4f} {v['central']:8.4f} "
                    f"{f(v['central_vs_lap'])} {v['pess']:8.4f} {f(v['pess_vs_lap'])} {v['opt_abs']:8.4f} "
                    f"{f(v['opt_vs_lap'])}   {rng}")
        say(f"   {prec.upper()}: k_data {c['k_data']:.4f}, k_lapedge {c['k_lapedge']:.4f}, single {c['k_single']:.4f}")
    say("   L = 4096 caveats: there is no routed L = 4096 point; every L = 4096 calibrated value comes from the")
    say("   routed L1024 dr and long-L d points, so the lap row's agreement with the estimate (0.375 vs 0.374)")
    say("   is a consistency check of the per-class method, not an independent validation.  The measured")
    for prec in ("int8", "int4"):
        r = row(rows, "lap", prec, "uniform", 4096, "dr")
        r1 = row(rows, "lap", prec, "uniform", 1024, "dr")
        if r is not None and r1 is not None:
            say(f"   {prec.upper()} L = 4096 point is {r['blocks']} block ({r['data_cycles']} data cycles, "
                f"{int(r['data_cycles']) * float(r['mac_per_data_cycle']):.0f} MACs) against {r1['blocks']} blocks "
                f"({r1['data_cycles']} data cycles) at L = 1024;")
    say("   its pre-layout values agree with the L = 1024 per-interval energies scaled to L = 4096 to within")
    say("   1.6% (section 6).")
    say("")

    # ------------------------------------------------------ 10. other distribution
    if robust_out:
        rows2 = {}
        for r in csv.DictReader((robust_out / "results.csv").open()):
            rows2[(r["arm"], r["label"])] = r
        keys = sorted({tuple(lab.split("_")[:3]) for (_, lab) in rows2})
        say(f"10. Stimulus robustness: {robust_out} (k ratios from the uniform routed calibration)")
        n_pass = sum(r["status"] == "PASS" for r in rows2.values())
        say(f"   {len(rows2)} points, {n_pass} PASS (bit-exact RTL and GL, GL trace == RTL trace)")
        for prec, dist, l in keys:
            L = int(l[1:])
            c = res["calibration"].get(f"{prec}_cause_per_class")
            b2 = bracket(rows2, prec, dist, L, c["k_data"], c["k_lapedge"], c["k_single"]) if c else None
            b1 = cor.get("bracket", {}).get(f"{prec}_L{L}")
            if b2 is None:
                continue
            cor.setdefault("robust", {})[f"{prec}_{dist}_L{L}"] = b2
            same_dr = len({v["tc_dr"] for v in b2.values()}) == 1
            same_drc = len({v["tc_drc"] for v in b2.values()}) == 1
            say(f"   {prec.upper()} {dist} L={L}: operand TC identical across arms in dr: {same_dr} "
                f"({b2['lap']['tc_dr']}), drc: {same_drc}")
            say(f"  {'arm':4s} {'g':>2s} {'pre dr vs lap':>14s} {'(uniform)':>10s} {'central':>8s} {'(uniform)':>10s}"
                f" {'pessim.':>8s} {'(uniform)':>10s}")
            for a in present:
                if a == "lap":
                    continue
                v, u = b2[a], (b1 or {}).get(a, {})
                q = lambda d, k: f"{100 * d[k]:+.2f}%" if k in d else "-"
                say(f"  {a:4s} {G[a]:2d} {q(v, 'opt_vs_lap'):>14s} {q(u, 'opt_vs_lap'):>10s} "
                    f"{q(v, 'central_vs_lap'):>8s} {q(u, 'central_vs_lap'):>10s} "
                    f"{q(v, 'pess_vs_lap'):>8s} {q(u, 'pess_vs_lap'):>10s}")
        say("")


if __name__ == "__main__":
    raise SystemExit(main())
