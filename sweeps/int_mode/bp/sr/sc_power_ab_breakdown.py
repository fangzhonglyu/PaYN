#!/usr/bin/env python3
"""Hierarchy breakdown + routed calibration of the pre-layout SC power A/B.

Inputs
  AB_OUT/<arm>/power.rpt            run_sc_prelayout_power_ab.sh (pre-layout PT-PX: synthesized
                                    netlist, own unit-delay GL SAIF of the SC streaming bench,
                                    384 batches x T=128, drain excluded, no SPEF / CTS)
  BUCKETS/<arm>/hier_buckets.csv    run_sc_power_buckets.sh (same sessions, leaf-cell sums per
                                    bucket at full precision; report_power -hier prints 3 digits)
  BUCKETS/routed_{csa,lap}/         the same buckets for the routed pinned finals (PT-PX, routed
                                    SPEF, max-SDF GL SAIF, same stimulus); totals equal the
                                    pinned results (15.72648 / 16.49444 mW)

Blocks (mW)
  tiles       64 u_pe/u_array_core/g_row_*__g_col_*__u_inner (seq = accumulator/hold flops,
              comb = popcount CSA + accumulate)
  core_seq    other u_array_core flops: a/w bit pipes (+ ICGs)
  core_comb   other u_array_core comb: select tree, SR head muxes, IPD doubling AO22s (the
              doubling hardware lives here)
  pe_wrapper  u_pe outside u_array_core (lap: BP west mux)
  sc_periph   u_peripheral/u_sc (CSA: all u_peripheral); bp_bypass = rest of u_peripheral
  combiner, sobol (u_a_rng + u_w_rng), top
  *_cts       routed clock-tree buffers inside that block (none pre-layout)
  pipes_ring  = core_seq + core_comb + pe_wrapper + core cts (the routed tables' u_pe - tiles)
pJ/MAC = mW / (64 MAC/cycle x 0.4 GHz).

Usage: sc_power_ab_breakdown.py AB_OUT BUCKETS [--arms csa lap sr4 sr2 ipd]
Writes BUCKETS/breakdown.txt and BUCKETS/breakdown.json.
"""
from __future__ import annotations

import argparse
import csv
import json
import re
from pathlib import Path

REPO = Path(__file__).resolve().parents[4]
PJ_DIV = (8 * 16 * 8 * 8 / 128) * 0.4   # 25.6
BUCKETS = ("tiles_seq", "tiles_comb", "core_seq", "core_comb", "pe_wrapper", "sc_periph", "bp_bypass",
           "combiner", "sobol", "top")
COMP = ("internal_mW", "switching_mW", "leakage_mW")


def power_rpt(path: Path) -> dict:
    t = path.read_text()
    get = lambda n: float(re.search(n + r"\s*=\s*([0-9.eE+-]+)", t)[1]) * 1e3
    d = dict(total=get("Total Power"), int=get("Cell Internal Power"), sw=get("Net Switching Power"),
             leak=get("Cell Leakage Power"))
    for g in ("clock_network", "register", "combinational"):
        m = re.search(rf"^{g}\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)", t, re.M)
        d[f"grp_{g}"] = float(m[4]) * 1e3 if m else float("nan")
    return d


def buckets(path: Path) -> dict:
    rows = {r["bucket"]: r for r in csv.DictReader(path.open())}
    out = {}
    for b in BUCKETS:
        base, cts = rows.get(b), rows.get(b + "_cts")
        for c in COMP + ("total_mW",):
            out[f"{b}.{c}"] = float(base[c]) if base else 0.0
            out[f"{b}_cts.{c}"] = float(cts[c]) if cts else 0.0
        out[f"{b}.cells"] = int(base["cells"]) if base else 0
    return out


def blocks(bk: dict) -> dict:
    t = lambda b: bk[f"{b}.total_mW"] + bk[f"{b}_cts.total_mW"]
    d = {b: bk[f"{b}.total_mW"] for b in BUCKETS}
    d["tiles"] = t("tiles_seq") + t("tiles_comb")
    d["core_cts"] = bk["core_seq_cts.total_mW"] + bk["core_comb_cts.total_mW"]
    d["pipes_ring"] = d["core_seq"] + d["core_comb"] + d["pe_wrapper"] + d["core_cts"] + bk["pe_wrapper_cts.total_mW"]
    d["sc_periph_all"] = t("sc_periph")
    d["bp_bypass_all"] = t("bp_bypass")
    d["sobol_all"] = t("sobol")
    d["combiner_all"] = t("combiner")
    d["top_all"] = t("top")
    d["cts_all"] = sum(bk[f"{b}_cts.total_mW"] for b in BUCKETS)
    d["bucket_sum"] = sum(bk[f"{b}.total_mW"] + bk[f"{b}_cts.total_mW"] for b in BUCKETS)
    return d


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("ab_out", type=Path)
    ap.add_argument("buckets", type=Path)
    ap.add_argument("--arms", nargs="+", default=["csa", "lap", "sr4", "sr2", "ipd"])
    a = ap.parse_args()
    ab = a.ab_out if a.ab_out.is_absolute() else REPO / a.ab_out
    bo = a.buckets if a.buckets.is_absolute() else REPO / a.buckets

    P, B, K = {}, {}, {}   # power.rpt, blocks, raw buckets
    for arm in a.arms:
        P[arm] = power_rpt(ab / arm / "power.rpt")
        K[arm] = buckets(bo / arm / "hier_buckets.csv")
        B[arm] = blocks(K[arm])
    for arm in ("csa", "lap"):
        r = f"routed_{arm}"
        P[r] = power_rpt(bo / r / "reports/power.rpt")
        K[r] = buckets(bo / r / "hier_buckets.csv")
        B[r] = blocks(K[r])
    for x in P:
        assert abs(B[x]["bucket_sum"] - P[x]["total"]) < 1e-4, (x, B[x]["bucket_sum"], P[x]["total"])
        P[x]["pJ_MAC"] = P[x]["total"] / PJ_DIV

    arms = list(a.arms)
    L = []
    p = L.append
    f4 = lambda v: f"{v:10.4f}"
    p("SC power A/B, pre-layout: PT-PX on each synthesized netlist with its own unit-delay GL SAIF (no SPEF, no CTS).")
    p("Identical stimulus in every arm (power_payn_array.sv, K8 M16 N8x8, T=128, 384 batches = 3,072 clocks, default")
    p("seed, uniform random operands; drain outside the SAIF window; all 1,353 stimulus-port SAIF records identical).")
    p("pJ/MAC = mW / 25.6.  Blocks are leaf-cell sums (hier_buckets.csv); they add up to the PT total.")
    p("")
    hdr = f"{'mW':28s}" + "".join(f"{x:>10s}" for x in arms)
    p(hdr)
    rows = [("total", P, "total"), ("pJ/MAC", P, "pJ_MAC"), ("  internal", P, "int"), ("  switching", P, "sw"),
            ("  leakage", P, "leak"), ("group clock_network", P, "grp_clock_network"),
            ("group register", P, "grp_register"), ("group combinational", P, "grp_combinational"),
            ("tiles (64)", B, "tiles"), ("  tile flops", B, "tiles_seq"), ("  tile comb", B, "tiles_comb"),
            ("pipes_ring (u_pe - tiles)", B, "pipes_ring"), ("  a/w bit pipes (flops)", B, "core_seq"),
            ("  core comb (muxes/select)", B, "core_comb"), ("  PE wrapper (BP west mux)", B, "pe_wrapper"),
            ("SC peripheral (u_sc)", B, "sc_periph_all"), ("BP bypass wrapper", B, "bp_bypass_all"),
            ("combiner", B, "combiner_all"), ("Sobol (a+w)", B, "sobol_all"), ("top level", B, "top_all")]
    for lab, src, k in rows:
        fmt = (lambda v: f"{v:10.5f}") if k == "pJ_MAC" else f4
        p(f"{lab:28s}" + "".join(fmt(src[x][k]) for x in arms))
    p(f"{'core comb cells':28s}" + "".join(f"{K[x]['core_comb.cells']:10d}" for x in arms))
    p("")
    dkeys = [("total", P, "total"), ("pJ/MAC", P, "pJ_MAC"), ("internal", P, "int"), ("switching", P, "sw"),
             ("leakage", P, "leak"), ("tile flops", B, "tiles_seq"), ("tile comb", B, "tiles_comb"),
             ("a/w bit pipes", B, "core_seq"), ("core comb (doubling hw)", B, "core_comb"),
             ("PE wrapper (BP west mux)", B, "pe_wrapper"), ("SC peripheral", B, "sc_periph_all"),
             ("BP bypass wrapper", B, "bp_bypass_all"), ("combiner", B, "combiner_all"), ("Sobol", B, "sobol_all"),
             ("top level", B, "top_all")]
    for base in ("lap", "csa"):
        p(f"Delta vs {base}, mW")
        p(hdr)
        for lab, src, k in dkeys:
            fmt = (lambda v: f"{v:+10.5f}") if k == "pJ_MAC" else (lambda v: f"{v:+10.4f}")
            p(f"{lab:28s}" + "".join(fmt(src[x][k] - src[base][k]) for x in arms))
        p(f"{'total %':28s}" + "".join(f"{100 * (P[x]['total'] / P[base]['total'] - 1):+9.2f}%" for x in arms))
        p("")
    # doubling-hardware cost split (vs lap): mux cells + extra load on the accumulator flop outputs
    p("Doubling hardware vs lap, mW: core comb (the mux cells: internal + their output nets) + tile-flop switching")
    p("(accumulator Q nets now also drive the mux inputs) + everything else")
    p(f"{'arm':6s}{'core comb':>11s}{'flop sw':>10s}{'other':>10s}{'total':>10s}{'per mux bit uW':>16s}")
    mux_bits = {"sr4": 16 * 24, "sr2": 32 * 24, "ipd": 64 * 24}
    for x in arms:
        if x not in mux_bits:
            continue
        cc = B[x]["core_comb"] - B["lap"]["core_comb"]
        fs = K[x]["tiles_seq.switching_mW"] - K["lap"]["tiles_seq.switching_mW"]
        tot = P[x]["total"] - P["lap"]["total"]
        p(f"{x:6s}{cc:+11.4f}{fs:+10.4f}{tot - cc - fs:+10.4f}{tot:+10.4f}{1e3 * tot / mux_bits[x]:16.3f}")
    p("  (mux bits per PE: g=4 16 x 24, g=2 32 x 24, g=1 64 x 24; 'other' includes -0.0006 mW for the removed")
    p("   BP west mux and DC sizing noise in the tile comb)")
    p("")

    # calibration
    p("Calibration vs the routed pinned finals (same stimulus; routed = PT-PX with routed SPEF + max-SDF GL SAIF)")
    p(f"{'mW':28s}{'csa pre':>10s}{'csa rtd':>10s}{'rtd/pre':>9s}{'lap pre':>10s}{'lap rtd':>10s}{'rtd/pre':>9s}")
    ratio = {}
    crow = [("total", P, "total"), ("internal", P, "int"), ("switching", P, "sw"), ("leakage", P, "leak"),
            ("group clock_network", P, "grp_clock_network"), ("group register", P, "grp_register"),
            ("group combinational", P, "grp_combinational"), ("tiles", B, "tiles"), ("  tile flops", B, "tiles_seq"),
            ("  tile comb", B, "tiles_comb"), ("pipes_ring", B, "pipes_ring"), ("  a/w bit pipes", B, "core_seq"),
            ("  core comb", B, "core_comb"), ("  core clock tree", B, "core_cts"), ("SC peripheral", B, "sc_periph_all"),
            ("BP bypass wrapper", B, "bp_bypass_all"), ("Sobol", B, "sobol_all"), ("top level", B, "top_all"),
            ("all CTS buffers", B, "cts_all")]
    for lab, src, k in crow:
        s = ""
        for arm in ("csa", "lap"):
            pv, rv = src[arm][k], src[f"routed_{arm}"][k]
            rr = rv / pv if abs(pv) > 1e-6 else float("nan")
            ratio.setdefault(arm, {})[k] = rr
            s += f"{pv:10.4f}{rv:10.4f}{rr:9.3f}" if rr == rr else f"{pv:10.4f}{rv:10.4f}{'-':>9s}"
        p(f"{lab:28s}{s}")
    p("by component (lap):            internal               switching")
    comp_ratio = {}
    for b in ("tiles_seq", "tiles_comb", "core_seq", "sc_periph", "sobol"):
        ri = K["routed_lap"][f"{b}.internal_mW"] / K["lap"][f"{b}.internal_mW"]
        rs = K["routed_lap"][f"{b}.switching_mW"] / K["lap"][f"{b}.switching_mW"]
        comp_ratio[b] = (ri, rs)
        p(f"  {b:26s}{K['lap'][f'{b}.internal_mW']:8.4f} ->{K['routed_lap'][f'{b}.internal_mW']:8.4f} x{ri:5.3f}"
          f"   {K['lap'][f'{b}.switching_mW']:8.4f} ->{K['routed_lap'][f'{b}.switching_mW']:8.4f} x{rs:5.3f}")
    dpre = P["lap"]["total"] - P["csa"]["total"]
    drt = P["routed_lap"]["total"] - P["routed_csa"]["total"]
    p(f"lap - csa: pre-layout {dpre:+.4f} mW ({100 * dpre / P['csa']['total']:+.2f}%), routed {drt:+.4f} mW "
      f"({100 * drt / P['routed_csa']['total']:+.2f}%), routed/pre-layout delta ratio {drt / dpre:.2f}")
    p("")

    # projections
    rl = P["routed_lap"]["total"]
    p(f"Projected routed SC power of each arm from its pre-layout delta vs lap (routed lap {rl:.4f} mW):")
    p("  A  uniform  : routed_lap x pre_arm / pre_lap (the lap total ratio, %.3f)" % ratio["lap"]["total"])
    p("  B  matched  : each bucket's internal / switching / leakage delta x the lap routed/pre ratio of the same")
    p("                bucket and component; core comb (the muxes; lap has almost none) x the tile-comb ratios")
    p("  C  high     : as B, but the mux cells' internal x 1.0 (flop-driven, no glitches for SDF to filter) and")
    p("                their switching x the tile-flop switching ratio (local wire on a pin-cap-only net)")
    p(f"{'arm':5s}{'pre mW':>9s}{'dpre':>9s}{'dpre%':>8s}{'A mW':>10s}{'A d%':>8s}{'B mW':>10s}{'B d%':>8s}"
      f"{'C mW':>10s}{'C d%':>8s}{'B pJ/MAC':>10s}")
    proj = {}
    def matched(x, high=False):
        d = 0.0
        for b in BUCKETS:
            for c, ci in (("internal_mW", 0), ("switching_mW", 1), ("leakage_mW", 2)):
                dv = K[x][f"{b}.{c}"] - K["lap"][f"{b}.{c}"]
                if ci == 2:
                    r = 1.04   # lap total leakage ratio
                elif b == "core_comb":
                    r = (1.0 if ci == 0 else comp_ratio["tiles_seq"][1]) if high else comp_ratio["tiles_comb"][ci]
                elif b in comp_ratio:
                    r = comp_ratio[b][ci]
                else:
                    pv, rv = K["lap"][f"{b}.{c}"], K["routed_lap"][f"{b}.{c}"]
                    r = rv / pv if pv > 1e-6 else 1.0
                d += dv * r
        return rl + d
    for x in arms:
        A = rl * P[x]["total"] / P["lap"]["total"]
        Bm, C = matched(x), matched(x, True)
        dp = P[x]["total"] - P["lap"]["total"]
        proj[x] = dict(pre=P[x]["total"], dpre=dp, A=A, B=Bm, C=C)
        p(f"{x:5s}{P[x]['total']:9.4f}{dp:+9.4f}{100 * dp / P['lap']['total']:+7.2f}%{A:10.4f}{100 * (A / rl - 1):+7.2f}%"
          f"{Bm:10.4f}{100 * (Bm / rl - 1):+7.2f}%{C:10.4f}{100 * (C / rl - 1):+7.2f}%{Bm / PJ_DIV:10.5f}")
    p(f"  check: csa via B lands at {proj['csa']['B']:.3f} mW vs routed csa {P['routed_csa']['total']:.3f} mW: the routed")
    p(f"  lap-csa gap is {drt:+.3f} mW, of which tiles {B['routed_lap']['tiles'] - B['routed_csa']['tiles']:+.3f} mW although the tile logic is identical")
    p(f"  (pre-layout tiles {B['lap']['tiles'] - B['csa']['tiles']:+.3f} mW): a route-level effect that no pre-layout delta can see.")
    p("")
    # geometric spread estimate: the doubling hw adds area inside u_pe, stretching the array
    upe = {}
    for x in arms:
        nl = next(l.split("=", 1)[1] for l in (ab / x / "inputs.txt").read_text().splitlines() if l.startswith("NETLIST="))
        for line in (Path(nl).parent / "area.rpt").read_text().splitlines():
            f = line.split()
            if len(f) >= 6 and f[0] == "u_pe":
                upe[x] = float(f[1])
                break
    wire = sum(K["routed_lap"][f"{b}.switching_mW"] for b in ("core_seq", "core_seq_cts", "core_comb_cts"))
    p("Floorplan spread (estimate, not measured): the routed lap a/w bit-pipe + core clock-tree switching")
    p(f"({wire:.3f} mW) scaled by the u_pe linear growth sqrt(u_pe_arm / u_pe_lap) - 1 (synthesized u_pe areas)")
    p(f"{'arm':5s}{'u_pe um2':>10s}{'lin %':>8s}{'spread mW':>11s}{'all-in routed delta vs lap (B..C + spread)':>46s}{'pJ/MAC':>17s}")
    for x in arms:
        if x in ("csa", "lap") or x not in upe:
            continue
        lin = (upe[x] / upe["lap"]) ** 0.5 - 1
        sp = wire * lin
        lo, hi = proj[x]["B"] - rl + sp, proj[x]["C"] - rl + sp
        proj[x].update(upe_um2=upe[x], spread_mW=sp, allin_lo_mW=lo, allin_hi_mW=hi)
        p(f"{x:5s}{upe[x]:10.1f}{100 * lin:+7.2f}%{sp:+11.4f}{'':12s}{lo:+.4f}..{hi:+.4f} mW ({100 * lo / rl:+.2f}..{100 * hi / rl:+.2f}%)"
          f"   {(rl + lo) / PJ_DIV:.4f}..{(rl + hi) / PJ_DIV:.4f}")
    p("")
    p("Sources:")
    for x in arms:
        p(f"  {x}: {ab / x}/power.rpt, {bo / x}/hier_buckets.csv")
    p(f"  routed: {bo}/routed_csa, {bo}/routed_lap (totals = pinned_pass2 power_result/power.rpt)")
    text = "\n".join(L) + "\n"
    (bo / "breakdown.txt").write_text(text)
    (bo / "breakdown.json").write_text(json.dumps(dict(power=P, blocks=B, buckets=K, ratio=ratio,
                                                       comp_ratio=comp_ratio, projection=proj), indent=1))
    print(text, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
