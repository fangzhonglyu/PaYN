#!/usr/bin/env python3
"""PaYN results report: doc/payn_results.md, generated from the run directories (no number is typed in here).

  python3 flow/report.py                                  # every build/flow/*/measure* with results
  python3 flow/report.py build/flow/payn_k16m8_20261006/measure build/flow/cbsg_af_ipd_20261005/measure
  python3 flow/report.py ... --bos-results build/flow/bos/<campaign>/results.csv --out doc/payn_results.md

Per measurement set (a flow/measure.py directory: its inputs.txt names the route, top, shape and qualification
evidence) the report reads
  route        reports/area.rpt (total and first-level blocks), outputs/<top>.apr.def (die)
  evidence     qualification.json (setup / hold WNS, repair), basin/basin_gate.json (basin, skew, pins)
  measure      sc_results.csv, int_results.csv (flow/measure.py rows), sc_uniform/classes and sc_ladder/classes
               (power and area by functional class)
and the BOS baseline from its qualified results: bos.sh / precision-campaign results.csv rows (power, area, 64 MAC
per cycle) and, for INT8, the routed BOS_ARRAY run's area.rpt with its 4,096-cycle PT report and bench log.

Throughput (period 2.5 ns, so f = 0.4 GHz; MACs per data edge of one PE = 8,192 / (BA x BW)):
  SC        GMAC/s/mm2 = N_PE x MAC/cycle x f / area, MAC/cycle = kernel MACs / window edges (64 at L = 128)
  INT bp    block period on a P_R x P_C grid = BW*NB + (BW-1) + (P_R+P_C-2) + 8*P_C, data edges BW*NB
  INT abit  block period = BA*BW*NB + (BA+BW-2) + (P_R+P_C-2) + 8*P_C, data edges BA*BW*NB      (NB = L / 128)
            drain-register route (PAYN_DRAIN=1): max(BA*BW*NB + (BA+BW-2) + 2, 2*P_C) (per-PE read-out in the
            wavefront: no skew or drain per block; the chain is busy 2*P_C edges)
            lap-fold route (PAYN_LAP_FOLD=1): the BA+BW-2 term is 0 (each lap is folded into a MAC edge)
            GMAC/s/mm2 = P_R x P_C x MACs per data edge x data / period x f / area
  BOS       GMAC/s/mm2 = MAC/cycle x f / area (drain-excluded peak; a grid of BOS arrays has the same density)
Areas: 1 PE = the route; grids = the split composite of the per-PE class areas,
  P_R*P_C*u_pe + P_R*(A edge + combiner + shared/2) + P_C*(W edge + shared/2) + block clock
(shared = peripheral clock buffers and leftovers + the bypass select shared by both edges); no skew registers, no
drain or top-level glue.  Energies are the routed single PE's (PT-PX, extracted parasitics, gate-level SAIF).
"""
from __future__ import annotations

import argparse
import csv
import json
import re
import sys
from pathlib import Path

sys.dont_write_bytecode = True
REPO = Path(__file__).resolve().parent.parent
PERIOD_NS = 2.5
F_GHZ = 1.0 / PERIOD_NS
GRIDS = {"1 PE": (1, 1), "4x4": (4, 4), "4x8": (4, 8)}
# BOS qualified results, later files overriding earlier ones per precision: the precision campaign, then every
# flow/bos.sh campaign (its INT6 rerun reproduces the campaign's INT6 row exactly).
BOS_RESULTS = [REPO / "build/bos_precision/bos_precision_20261002/results.csv",
               *sorted((REPO / "build/flow/bos").glob("*/results.csv"))]
BOS_INT8 = dict(route=REPO / "apr/build/TSMC22/BOS_ARRAY/20260728_143921",
                power=REPO / "build/power_char/BOS_ARRAY__T4096/power.rpt",
                sim=REPO / "build/power_char/BOS_ARRAY__T4096/sim.log")
SHAPE_LABEL = {"k16m8": "K16/M8", "k8m16": "K8/M16"}
PREC_BITS = {"INT8": (8, 8), "INT7": (7, 7), "INT6": (6, 6), "INT4": (4, 4), "W4A8": (8, 4), "W6A8": (8, 6)}


# ------------------------------------------------------------------------------------------------ helpers --
def rcsv(path: Path) -> list[dict]:
    return list(csv.DictReader(path.open())) if path.is_file() else []


def jload(path: Path) -> dict:
    return json.loads(path.read_text()) if path.is_file() else {}


def text(path: Path) -> str:
    return path.read_text(errors="replace") if path.is_file() else ""


def f0(x) -> str:
    return "-" if x is None else f"{x:,.0f}"


def f1(x) -> str:
    return "-" if x is None else f"{x:,.1f}"


def f3(x) -> str:
    return "-" if x is None else f"{x:.3f}"


def f4(x) -> str:
    return "-" if x is None else f"{x:.4f}"


def pct(a, b) -> str:
    return "-" if a is None or b is None or b == 0 else f"{100 * (a / b - 1):+.1f}%"


def ratio(a, b) -> str:
    return "-" if a is None or b is None or b == 0 else f"{a / b:.2f}x"


def area_rpt(path: Path, top: str) -> dict[str, float]:
    """Total of the top row and the total area of each first-level hierarchy (Innovus area.rpt layout)."""
    out: dict[str, float] = {}
    for line in text(path).splitlines():
        f = line.split()
        if len(f) >= 3 and f[0] == top and "total" not in out:
            out["total"] = float(f[2])
        elif len(f) >= 4 and f[0] in ("u_pe", "u_peripheral", "u_combiner", "u_rng") and f[0] not in out:
            out[f[0]] = float(f[3])
    return out


def die_um(def_path: Path) -> tuple[float, float] | None:
    units = None
    for line in text(def_path).splitlines():
        m = re.match(r"UNITS DISTANCE MICRONS (\d+)", line)
        if m:
            units = int(m[1])
        m = re.match(r"DIEAREA \( 0 0 \) \( (\d+) (\d+) \)", line)
        if m and units:
            return int(m[1]) / units, int(m[2]) / units
    return None


def power_total(rpt: Path) -> float | None:
    m = re.search(r"Total Power\s*=\s*([0-9.eE+-]+)", text(rpt))
    return float(m[1]) * 1e3 if m else None


# -------------------------------------------------------------------------------------------- the inputs --
def split(rows: dict | None) -> dict | None:
    """Per-PE blocks of a class split (area or power): PE core, A edge, W edge, combiner, block clock, shared."""
    if not rows:
        return None
    return dict(u_pe=rows["u_pe"], a_edge=rows["a_edge"], w_edge=rows["w_edge"], comb=rows["combiner"],
                bank=rows["w_bank"], shared=rows["periph_clk_buf"] + rows["periph_other"] + rows["sel_shared"],
                top_rest=rows["top_glue"] + rows["top_clk_buf"] + rows["port_nets"], total=rows["total"])


def composite(c: dict, pr: int, pc: int) -> float:
    return (pr * pc * c["u_pe"] + pr * (c["a_edge"] + c["shared"] / 2 + c["comb"])
            + pc * (c["w_edge"] + c["shared"] / 2) + c["bank"])


class MeasureSet:
    """One measured route: its inputs, rows, class split, area and qualification."""

    def __init__(self, measure: Path):
        self.dir = measure
        self.dirs = [measure]
        kv = dict(line.split("=", 1) for line in text(measure / "inputs.txt").splitlines() if "=" in line
                  and not line[0].isdigit() and " " not in line.split("=", 1)[0])
        self.route = Path(kv["route"])
        self.top = kv["top"]
        self.shape = kv["shape"].split()[0]
        self.drain = int(kv.get("drain", "0"))
        self.fold = int(kv.get("fold", "0"))
        self.evidence = Path(kv["evidence"])
        self.label = (f"{SHAPE_LABEL[self.shape]}{' DR' if self.drain else ''}{' fold' if self.fold else ''} "
                      f"({self.route.name})")
        self.sc = {r["point"]: r for r in rcsv(measure / "sc_results.csv")}
        self.int = {r["point"]: r for r in rcsv(measure / "int_results.csv")}
        self.classes = {p: jload(measure / p / "classes/power_classes.json") for p in ("sc_uniform", "sc_ladder")}
        self.area = area_rpt(self.route / "reports/area.rpt", self.top)
        self.q = jload(self.evidence / "qualification.json")
        self.basin = jload(self.evidence / "basin/basin_gate.json")
        self.die = die_um(self.route / "outputs" / f"{self.top}.apr.def")
        self.blocked = self.stopped_points()
        self.blocks = split(self.classes["sc_uniform"].get("rows_area_um2"))
        self.blocks_mw = split(self.classes["sc_uniform"].get("rows_mW"))

    def stopped_points(self) -> list[dict]:
        """INT points whose gate-level simulation and timing audit passed but a later gate stopped them."""
        out = []
        for d in sorted(self.dir.iterdir()):
            if not d.name.startswith(("bp_", "abit_")) or text(d / "row.status").strip() == "PASS":
                continue
            if text(d / "gl.status").strip() != "PASS":
                continue
            chk = jload(d / "gl/trace_check.json")
            stage = next((st for st in ("audit", "saif", "power", "row") if text(d / f"{st}.status").strip() != "PASS"),
                         "row")
            why = "; ".join(jload(d / "saif/saif_int_audit.json").get("rejection_reasons", [])) if stage == "saif" else ""
            last = sorted(d.glob(f"{stage}.attempt_*.log"))
            if not why and last:
                fails = [ln for ln in text(last[-1]).splitlines() if ln.startswith("FAILED:")]
                why = fails[-1][len("FAILED: "):] if fails else "pending"
            out.append(dict(point=d.name, schedule=chk.get("schedule", "bp"), precision=chk.get("precision"),
                            ba=chk.get("ba"), bw=chk.get("bw"), L=chk.get("L"), saif_mode=str(chk.get("saif_mode")),
                            window=chk.get("saif_window", {}).get("active"), macs=chk.get("macs"),
                            trace=chk.get("status"), stage=stage, why=why))
        return out

    def absorb(self, other: "MeasureSet") -> None:
        """Merge another measurement directory of the same route: the union of the points; a point measured
        in both must have the same power and energy."""
        for mine, theirs in ((self.sc, other.sc), (self.int, other.int)):
            for point, row in theirs.items():
                if point in mine and (mine[point]["power_mW"], mine[point]["pJ_MAC"]) != (row["power_mW"], row["pJ_MAC"]):
                    raise SystemExit(f"{point} differs between {self.dir} and {other.dir} on the same route")
                mine.setdefault(point, row)
        for point, c in other.classes.items():
            if not self.classes.get(point):
                self.classes[point] = c
        measured = set(self.sc) | set(self.int)
        self.blocked = [b for b in self.blocked + other.blocked if b["point"] not in measured]
        self.dirs.append(other.dir)

    def grid_area(self, grid: str) -> float | None:
        if grid == "1 PE":
            return self.area.get("total")
        return composite(self.blocks, *GRIDS[grid]) if self.blocks else None

    def sc_grid_pj(self, grid: str) -> float | None:
        """SC uniform energy per MAC of a grid composite (the same split applied to the class power)."""
        r = self.sc.get("sc_uniform")
        if not r or not self.blocks_mw:
            return None
        pr, pc = GRIDS[grid]
        p = float(r["power_mW"]) if grid == "1 PE" else composite(self.blocks_mw, pr, pc)
        return p * float(r["window_edges"]) * PERIOD_NS / (pr * pc * float(r["kernel_macs"]))

    def sc_gmacs(self, grid: str, point: str = "sc_uniform") -> float | None:
        r, area = self.sc.get(point), self.grid_area(grid)
        if not r or not area:
            return None
        pr, pc = GRIDS[grid]
        return pr * pc * float(r["mac_per_cycle"]) * F_GHZ / (area * 1e-6)

    def int_gmacs(self, r: dict, grid: str) -> float | None:
        area = self.grid_area(grid)
        if not area:
            return None
        pr, pc = GRIDS[grid]
        ba, bw, nb = int(r["ba"]), int(r["bw"]), int(r["L"]) // 128
        data, laps = (ba * bw * nb, 0 if self.fold else ba + bw - 2) if r["schedule"] == "abit" else (bw * nb, bw - 1)
        period = max(data + laps + 2, 2 * pc) if self.drain else data + laps + (pr + pc - 2) + 8 * pc
        return pr * pc * (8192 / (ba * bw)) * data / period * F_GHZ / (area * 1e-6)

    def int_peak(self, ba: int, bw: int, grid: str) -> float | None:
        area = self.grid_area(grid)
        pr, pc = GRIDS[grid]
        return pr * pc * (8192 / (ba * bw)) * F_GHZ / (area * 1e-6) if area else None


def load_bos(extra: list[Path]) -> dict[str, dict]:
    """BOS per precision: area, power, pJ/MAC, MAC/cycle, slacks and the source."""
    bos: dict[str, dict] = {}
    r = BOS_INT8
    area = area_rpt(r["route"] / "reports/area.rpt", "binary_os_array").get("total")
    pw = power_total(r["power"])
    m = re.search(r"PASS: binary OS power SAIF captured \+ output-checked; (\d+) cycles \((\d+) MAC, (\d+) drain\), "
                  r"(\d+) useful MAC", text(r["sim"]))
    if area and pw and m:
        mpc = int(m[4]) / int(m[1])
        setup = re.search(r"Slack Time\s+([-+0-9.]+)", text(r["route"] / "reports/setup.rpt"))
        bos["INT8"] = dict(area_um2=area, power_mW=pw, mac_per_cycle=mpc, pJ_MAC=pw * PERIOD_NS / mpc,
                           setup_wns_ns=float(setup[1]) if setup else None,
                           source=f"{r['route'].relative_to(REPO)} + {r['power'].relative_to(REPO)}")
    for path in BOS_RESULTS + extra:
        for row in rcsv(path):
            if row.get("status") != "PASS":
                continue
            mpc = float(row["GMAC_s"]) / F_GHZ
            bos[f"INT{row['IWIDTH']}"] = dict(area_um2=float(row["area_um2"]), power_mW=float(row["power_mW"]),
                                             mac_per_cycle=mpc, pJ_MAC=float(row["power_mW"]) * PERIOD_NS / mpc,
                                             setup_wns_ns=float(row["setup_wns_ns"]),
                                             source=str(path.relative_to(REPO)) if path.is_relative_to(REPO) else str(path))
    for b in bos.values():
        b["gmacs_mm2"] = b["mac_per_cycle"] * F_GHZ / (b["area_um2"] * 1e-6)
    return bos


# ------------------------------------------------------------------------------------------------ blocks --
def table(head: list[str], rows: list[list[str]], align: str | None = None) -> list[str]:
    align = align or "l" + "r" * (len(head) - 1)
    out = ["| " + " | ".join(head) + " |", "|" + "|".join("---" if a == "l" else "---:" for a in align) + "|"]
    return out + ["| " + " | ".join(r) + " |" for r in rows]


def block_route(S: list[MeasureSet]) -> list[str]:
    L = ["## Routes", ""]
    rows = []
    for s in S:
        q, b = s.q, s.basin
        rows.append([s.label, f0(s.area.get("total")),
                     f"{s.die[0]:.1f} x {s.die[1]:.1f}" if s.die else "-",
                     f"{q.get('setup_wns_ns', 0):+.3f} / {q.get('hold_wns_ns', 0):+.3f}",
                     "targeted repair" if q.get("targeted_repair") else "clean",
                     f"{b.get('gate', {}).get('basin', '-')} (corr {b.get('corr_x_col', 0):.3f}, "
                     f"skew {b.get('abs_skew_mean_ps', 0):.1f} ps)",
                     f"{b.get('pin_proof', {}).get('status', '-')} ({b.get('pin_proof', {}).get('fixed_in_def', '-')})"])
    L += table(["route", "area (um2)", "die (um)", "setup / hold WNS (ns)", "final DRC/antenna", "basin",
                "pin proof (fixed pins)"], rows, "lrrrlll")
    L += ["", "Qualification: qualify.py routed-apr --stage final (geometry, antenna, connectivity, placement, timing) "
          "and basin (tile grid, product-AND operand skew, every pin fixed as planned).", ""]
    return L


def block_area(S: list[MeasureSet]) -> list[str]:
    L = ["## Area", "", "Routed cell area by block (um2): first-level hierarchy (area.rpt), then the functional classes "
         "of the SC uniform class run (flow/tcl/pt_power_classes.tcl).", ""]
    keys = [("total", "total"), ("u_pe", "PE core (u_pe)"), ("tiles", "  tiles"),
            ("pe_pipes_glue", "  bit / sign pipes, core clock gates, glue"), ("dbl_mux", "  doubling muxes"),
            ("dbl_sel", "  lap select"), ("pe_clk_buf", "  PE clock tree"),
            ("drain_reg", "  drain register (flops + mux; DR routes)"), ("a_edge", "A edge"),
            ("a_regs", "  A registers"), ("ka_enc", "  kA encoders"), ("ka_in_buf", "  encoder input buffers"),
            ("therm_byp", "  thermometers + INT bypass"), ("w_edge", "W edge"), ("w_regs", "  W registers"),
            ("w_cmp_byp", "  W comparators + INT bypass"), ("sel_shared", "bypass select (shared)"),
            ("w_bank", "block clock (u_rng)"), ("combiner", "INT combiner"), ("periph_clk_buf", "edge clock tree"),
            ("other", "other (edge leftovers, top glue, top clock tree)"), ("int_additions", "INT additions (sum)")]
    cls = [s.classes["sc_uniform"].get("rows_area_um2") or {} for s in S]
    rows = [[lab] + [f1(c.get(k)) for c in cls] for k, lab in keys]
    rows.append(["hierarchy: u_pe / u_peripheral / u_combiner / u_rng"] +
                [" / ".join(f0(s.area.get(h)) for h in ("u_pe", "u_peripheral", "u_combiner", "u_rng")) for s in S])
    for g in ("4x4", "4x8"):
        rows.append([f"{g} grid composite"] + [f0(s.grid_area(g)) for s in S])
    L += table(["block"] + [s.label for s in S], rows)
    return L + [""]


def block_sc(S: list[MeasureSet]) -> list[str]:
    L = ["## SC energy", "", "Routed single PE, PT-PX on the full-timing gate-level SAIF; the drain is outside the "
         "window.  pJ/MAC = P x window x 2.5 ns / kernel MACs (K columns x 64 tiles per block).", ""]
    rows = []
    for s in S:
        for p in sorted(s.sc, key=lambda n: (not n.startswith("sc_uniform"), n)):
            r = s.sc[p]
            rows.append([s.label, r["workload"], r["blocks"], r["window_edges"], f3(float(r["power_mW"])),
                         f4(float(r["pJ_MAC"])), f4(float(r["array_pJ_MAC"])), f3(float(r["u_pe_mW"])),
                         f3(float(r["u_peripheral_mW"])), f"{float(r['mean_cycles_per_block']):.2f}",
                         f1(s.sc_gmacs("1 PE", p))])
    L += table(["route", "workload", "blocks", "window edges", "power (mW)", "pJ/MAC", "array pJ/MAC",
                "u_pe (mW)", "edge (mW)", "cycles/block", "GMAC/s/mm2 (1 PE)"], rows, "llrrrrrrrrr")
    L += ["", "SC throughput at L = 128 (GMAC/s/mm2) and the composite energy:", ""]
    rows = []
    for s in S:
        r = s.sc.get("sc_uniform")
        if not r:
            continue
        rows.append([s.label] + [f1(s.sc_gmacs(g)) for g in GRIDS] + [f4(s.sc_grid_pj(g)) for g in GRIDS])
    L += table(["route"] + [f"GMAC/s/mm2 {g}" for g in GRIDS] + [f"pJ/MAC {g}" for g in GRIDS], rows)
    tpts = [p for s in S for p in s.sc if p.startswith("sc_T")]
    L += [""]
    if tpts:
        L += ["SC energy vs stream length T (uniform L = T):", ""]
        rows = [[s.label] + [f4(float(s.sc[p]["pJ_MAC"])) if p in s.sc else "-" for p in sorted(set(tpts))]
                for s in S]
        L += table(["route"] + [p.replace("sc_T", "T=") for p in sorted(set(tpts))], rows)
    else:
        L += ["SC energy vs stream length T: not measured (the SC power bench runs uniform L = 128 or the ladder "
              "only; flow/measure.py's sc_T points need its SC_L workload)."]
    cl = [(s, s.classes["sc_uniform"].get("rows_mW"), s.classes["sc_ladder"].get("rows_mW")) for s in S]
    if any(c[1] for c in cl):
        L += ["", "SC power by block (mW, uniform / ladder):", ""]
        keys = ["total", "tiles", "pe_pipes_glue", "pe_clk_buf", "dbl_mux", "drain_reg", "a_edge", "ka_enc",
                "therm_byp", "w_edge", "w_cmp_byp", "w_bank", "combiner", "periph_clk_buf", "other"]
        rows = [[k] + [f"{f3(u.get(k)) if u else '-'} / {f3(l.get(k)) if l else '-'}" for _, u, l in cl] for k in keys]
        L += table(["block"] + [s.label for s in S], rows)
    return L + [""]


def int_label(r: dict) -> str:
    win = {"0": "dr", "1": "d", "2": "all"}[r["saif_mode"]]
    ctl = " (bp on abit operands)" if r["point"].endswith("_ctl") else ""
    return f"{r['schedule']} {r['precision']} L={int(r['L']):,} {win}{ctl}"


def block_int(S: list[MeasureSet]) -> list[str]:
    L = ["## INT energy and throughput", "",
         "Windows: dr = data + laps (drain excluded, the headline), d = data only (peak), all = drain included.  "
         "GMAC/s/mm2 from the block-period formulas above (laps, grid skew and drain included).", ""]
    for s in S:
        if not s.int and not s.blocked:
            continue
        L += [f"### {s.label}", ""]
        rows = []
        order = sorted(s.int.values(), key=lambda r: (r["schedule"], r["point"].endswith("_ctl"), r["precision"],
                                                       int(r["L"]), r["saif_mode"]))
        for r in order:
            rows.append([int_label(r), r["mrows"] + "x" + r["ncols"], r["blocks"], r["active_cycles"],
                         f1(float(r["mac_per_cycle"])), f3(float(r["power_mW"])), f4(float(r["pJ_MAC"])),
                         f4(float(r["array_pJ_MAC"]))] + [f0(s.int_gmacs(r, g)) for g in GRIDS])
        if rows:
            L += table(["point", "M x N", "blocks", "window", "MAC/cycle", "power (mW)", "pJ/MAC", "array pJ/MAC"]
                       + [f"GMAC/s/mm2 {g}" for g in GRIDS], rows, "lrrrrrrrrrr")
        if s.blocked:
            L += ["" if rows else "", f"INT points of {s.label} that passed the routed gate-level simulation (bit-exact trace, SAIF "
                  "window) and the timing audit but were stopped by a later gate, so they have no energy; their "
                  "throughput depends only on the block-period formula and the area:", ""]
            rows = [[f"{b['point']}", b["trace"], str(b["window"]), b["stage"], b["why"][:160]]
                    + [f0(s.int_gmacs(b, g)) for g in GRIDS] for b in s.blocked]
            L += table(["point", "trace check", "window", "stopped at", "reason"] + [f"GMAC/s/mm2 {g}" for g in GRIDS],
                       rows, "lllllrrr")
        L += ["", "Peak (no laps, skew or drain), GMAC/s/mm2: " + "; ".join(
            f"{p} " + " / ".join(f0(s.int_peak(*PREC_BITS[p], g)) for g in GRIDS) for p in ("INT8", "INT7", "INT6", "INT4"))
              + f" ({' / '.join(GRIDS)})", ""]
    return L


def block_bos(S: list[MeasureSet], bos: dict) -> list[str]:
    L = ["## Against BOS", "", "INT schedule of record: all bits in time (abit); the bit-plane points stay in the INT "
         "tables for reference.  BOS: binary output-stationary 8x8 array per precision (24-bit accumulators, 64 "
         "MAC/cycle, 400 MHz), routed and measured with the same PT-PX method; its GMAC/s/mm2 is the drain-excluded "
         "peak, the same for any grid of BOS arrays.  PaYN: routed single-PE pJ/MAC (dr window: data + laps, drain "
         "excluded) and grid GMAC/s/mm2 with laps, skew and drain.", ""]
    rows = [[p, f0(b["area_um2"]), f3(b["power_mW"]), f4(b["pJ_MAC"]), f0(b["gmacs_mm2"]),
             f"{b['setup_wns_ns']:+.3f}" if b.get("setup_wns_ns") is not None else "-", b["source"]]
            for p, b in sorted(bos.items())]
    L += table(["BOS", "area (um2)", "power (mW)", "pJ/MAC", "GMAC/s/mm2", "setup WNS (ns)", "source"], rows,
               "lrrrrrl") + [""]
    rows = []
    for s in S:
        pts = [(r, float(r["pJ_MAC"])) for r in s.int.values()] + [(b, None) for b in s.blocked]
        for r, pj in sorted(pts, key=lambda x: (x[0]["precision"], int(x[0]["L"]))):
            if (r["schedule"] != "abit" or r["saif_mode"] != "0" or r["point"].endswith("_ctl")
                    or r["precision"] not in bos):
                continue
            b = bos[r["precision"]]
            g4, g8 = s.int_gmacs(r, "4x4"), s.int_gmacs(r, "4x8")
            rows.append([s.label, f"{r['precision']} L={int(r['L']):,}",
                         f4(pj) if pj is not None else f"stopped at {r['stage']}", f4(b["pJ_MAC"]),
                         pct(pj, b["pJ_MAC"]), f0(g4), f0(g8), f0(b["gmacs_mm2"]), ratio(g4, b["gmacs_mm2"]),
                         ratio(g8, b["gmacs_mm2"])])
    L += table(["route", "abit point", "pJ/MAC", "BOS pJ/MAC", "vs BOS", "4x4 GMAC/s/mm2", "4x8 GMAC/s/mm2",
                "BOS GMAC/s/mm2", "4x4 vs BOS", "4x8 vs BOS"], rows, "llrrrrrrrr")
    return L + [""]


def abit_edges(L: int, ba: int, bw: int, pr: int, pc: int, drain: int | None = None, dr: bool = False,
               fold: bool = False) -> int:
    """Edges to finish one set of output tiles over a reduction of L in one block: its data passes, BA+BW-2
    laps, P_R+P_C-2 skew and the drain (8*P_C edges unless given).  dr: the drain-register hardware, max(data + laps
    + 2, 2*P_C).  fold: the lap fold (no lap edges).  Accumulator range is not modelled, as for BOS (both have
    24-bit accumulators)."""
    laps = 0 if fold else ba + bw - 2
    if dr:
        return max(ba * bw * -(-L // 128) + laps + 2, 2 * pc)
    return ba * bw * -(-L // 128) + laps + (pr + pc - 2) + (8 * pc if drain is None else drain)


def abit_gmacs(L: int, ba: int, bw: int, pr: int, pc: int, area_mm2: float, drain: int | None = None,
               dr: bool = False, fold: bool = False) -> float:
    return pr * pc * 64 * L / abit_edges(L, ba, bw, pr, pc, drain, dr, fold) * F_GHZ / area_mm2


LUT_L = [128, 256, 384, 512, 768, 1024, 2048, 4096, 8192, 16384, 65536]


def block_lut(S: list[MeasureSet], bos: dict) -> list[str]:
    L = ["## INT throughput vs reduction length L (all bits in time)", "",
         "For an A (BA-bit) x W (BW-bit) GEMM with reduction length L on a P_R x P_C grid of PEs (8 x 8 tiles, "
         "64 outputs per PE per block):", "",
         "    E(L)  = BA*BW*ceil(L/128) + (BA+BW-2) + (P_R+P_C-2) + 8*P_C      edges per block: data passes, "
         "laps, skew, drain",
         "    GMAC/s/mm2 = 0.4 GHz * P_R*P_C*64*L / (E(L) * A_grid)  =  peak * U(L),   "
         "U(L) = BA*BW*(L/128) / E(L)", "",
         "A_grid is the grid composite area of the Area section; the measured block periods equal E(L) for every "
         "measured point (regression and INT tables).  Other drains: replace 8*P_C by D (4*P_C both-way drain, 8 "
         "per-PE drain, ~1 overlapped).  Drain-register routes (DR): E(L) = max(BA*BW*ceil(L/128) + (BA+BW-2) + 2, "
         "2*P_C), with their own measured area.  Lap-fold routes (fold): the (BA+BW-2) term is 0.  Accumulator range "
         "is not modelled, for PaYN or BOS (both 24-bit).  BOS: drain-excluded peak, independent of L.", ""]
    for s in S:
        for grid in ("4x4", "4x8"):
            area = s.grid_area(grid)
            if not area:
                continue
            pr, pc = (int(x) for x in grid.split("x"))
            rows = []
            for ba in (8, 7, 6, 4):
                prec = f"INT{ba}"
                g = [abit_gmacs(x, ba, ba, pr, pc, area * 1e-6, dr=bool(s.drain), fold=bool(s.fold)) for x in LUT_L]
                rows.append([f"{prec} GMAC/s/mm2"] + [f0(v) for v in g])
                if prec in bos:
                    rows.append([f"{prec} vs BOS ({f0(bos[prec]['gmacs_mm2'])})"]
                                + [f"{v / bos[prec]['gmacs_mm2']:.2f}x" for v in g])
            L += [f"{s.label}, {grid}:", ""]
            L += table(["L"] + [f"{x:,}" for x in LUT_L], rows, "l" + "r" * len(LUT_L)) + [""]
    L += ["### Drain variants (upper bounds)", "",
          "The same E(L) with the drain term D in place of 8*P_C.  The area is the measured one: the hardware each "
          "variant needs is not included, so these are upper bounds until that hardware is synthesized.  Variants: "
          "both-way (each half of a PE row drains to its own edge, D = 4*P_C), per-PE (each PE drains on its own "
          "path, D = 8), overlapped (shadow registers drain during the next block, D ~ 1).", ""]
    drains = [("now, 8*P_C", None), ("both-way, 4*P_C", lambda pc: 4 * pc), ("per-PE, 8", lambda pc: 8),
              ("overlapped, ~1", lambda pc: 1)]
    points = [(8, 384), (8, 1024), (7, 1024), (6, 1024), (4, 1024), (4, 4096)]
    for s in S:
        if s.drain or s.fold:                      # its drain is built and measured: the DR comparison section
            continue
        for grid in ("4x4", "4x8"):
            area = s.grid_area(grid)
            if not area:
                continue
            pr, pc = (int(x) for x in grid.split("x"))
            rows = []
            for name, d in drains:
                row = [name]
                for ba, l in points:
                    g = abit_gmacs(l, ba, ba, pr, pc, area * 1e-6, None if d is None else d(pc))
                    b = bos.get(f"INT{ba}")
                    row.append(f0(g) + (f" ({g / b['gmacs_mm2']:.2f}x)" if b else ""))
                rows.append(row)
            L += [f"{s.label}, {grid}, GMAC/s/mm2 (vs BOS):", ""]
            L += table(["drain"] + [f"INT{ba} L={l:,}" for ba, l in points], rows, "l" + "r" * len(points)) + [""]
    return L


def block_drain(S: list[MeasureSet], bos: dict) -> list[str]:
    """Drain register against the in-tile chain, per shape with both routes measured."""
    pairs = [(t, d) for d in S if d.drain and not d.fold for t in S
             if not t.drain and not t.fold and t.shape == d.shape]
    if not pairs:
        return []
    L = ["## Drain register vs in-tile chain", "",
         "The same shape built with PAYN_DRAIN=1 (one 768-bit drain register per PE, per-PE drain wave, registers "
         "shifting west; doc/column_sort_drain.md) and with the qualified in-tile chain, each routed, qualified and "
         "measured by the same flow.  INT throughput uses each route's own block period and area.", ""]
    for t, d in pairs:
        rows = [["area 1 PE (um2)", f0(t.grid_area("1 PE")), f0(d.grid_area("1 PE")),
                 pct(d.grid_area("1 PE"), t.grid_area("1 PE"))]]
        for g in ("4x4", "4x8"):
            rows.append([f"area {g} composite (um2)", f0(t.grid_area(g)), f0(d.grid_area(g)),
                         pct(d.grid_area(g), t.grid_area(g))])
        dt, dd = (s.classes["sc_uniform"].get("rows_area_um2") or {} for s in (t, d))
        rows.append(["  u_pe (um2)", f1(dt.get("u_pe")), f1(dd.get("u_pe")), pct(dd.get("u_pe"), dt.get("u_pe"))])
        rows.append(["  drain register (um2)", f1(dt.get("drain_reg")), f1(dd.get("drain_reg")), "-"])
        rows.append(["setup / hold WNS (ns)", f"{t.q.get('setup_wns_ns', 0):+.3f} / {t.q.get('hold_wns_ns', 0):+.3f}",
                     f"{d.q.get('setup_wns_ns', 0):+.3f} / {d.q.get('hold_wns_ns', 0):+.3f}", "-"])
        for p in sorted(set(t.sc) & set(d.sc), key=lambda n: (not n.startswith("sc_uniform"), n)):
            a, b = float(t.sc[p]["pJ_MAC"]), float(d.sc[p]["pJ_MAC"])
            rows.append([f"SC {t.sc[p]['workload']} pJ/MAC", f4(a), f4(b), pct(b, a)])
        for g in ("4x4", "4x8"):
            a, b = t.sc_gmacs(g), d.sc_gmacs(g)
            rows.append([f"SC L=128 GMAC/s/mm2 {g}", f1(a), f1(b), pct(b, a)])
        for p in sorted(set(t.int) & set(d.int)):
            rt, rd = t.int[p], d.int[p]
            if rt["schedule"] != "abit":
                continue
            a, b = float(rt["pJ_MAC"]), float(rd["pJ_MAC"])
            rows.append([f"{int_label(rt)} pJ/MAC", f4(a), f4(b), pct(b, a)])
            if rt["saif_mode"] == "0":
                for g in ("4x4", "4x8"):
                    ga, gb = t.int_gmacs(rt, g), d.int_gmacs(rd, g)
                    bb = bos.get(rt["precision"])
                    tail = f" ({gb / bb['gmacs_mm2']:.2f}x BOS)" if bb and gb else ""
                    rows.append([f"  GMAC/s/mm2 {g}", f0(ga), f0(gb) + tail, pct(gb, ga)])
        L += [f"{SHAPE_LABEL[t.shape]}: {t.route.name} (in-tile chain) vs {d.route.name} (drain register)", ""]
        L += table(["", "in-tile chain", "drain register", "change"], rows, "lrrr") + [""]
    return L


def block_fold(S: list[MeasureSet], bos: dict) -> list[str]:
    """Lap fold against the in-place lap, per shape and drain with both routes measured."""
    pairs = [(t, f) for f in S if f.fold for t in S if not t.fold and (t.shape, t.drain) == (f.shape, f.drain)]
    if not pairs:
        return []
    L = ["## Lap fold vs in-place lap", "",
         "The same shape and drain built with PAYN_LAP_FOLD=1 (each INT doubling lap folded into the next level's "
         "first MAC edge: no bubble and no lap edge per level step; doc/int_lap_fold.md) and with the in-place lap, "
         "each routed, qualified and measured by the same flow.  INT throughput uses each route's own block period "
         "and area; at L = 128 (NB = 1, one quantization group per block) the laps are the largest share.", ""]
    for t, f in pairs:
        rows = [["area 1 PE (um2)", f0(t.grid_area("1 PE")), f0(f.grid_area("1 PE")),
                 pct(f.grid_area("1 PE"), t.grid_area("1 PE"))]]
        for g in ("4x4", "4x8"):
            rows.append([f"area {g} composite (um2)", f0(t.grid_area(g)), f0(f.grid_area(g)),
                         pct(f.grid_area(g), t.grid_area(g))])
        dt, df = (s.classes["sc_uniform"].get("rows_area_um2") or {} for s in (t, f))
        for k, name in (("u_pe", "u_pe"), ("tiles", "  tiles"), ("dbl_mux", "  doubling mux (lap leg)"),
                        ("dbl_sel", "  lap select")):
            rows.append([f"{name} (um2)", f1(dt.get(k)), f1(df.get(k)), pct(df.get(k), dt.get(k))])
        rows.append(["setup / hold WNS (ns)", f"{t.q.get('setup_wns_ns', 0):+.3f} / {t.q.get('hold_wns_ns', 0):+.3f}",
                     f"{f.q.get('setup_wns_ns', 0):+.3f} / {f.q.get('hold_wns_ns', 0):+.3f}", "-"])
        for p in sorted(set(t.sc) & set(f.sc), key=lambda n: (not n.startswith("sc_uniform"), n)):
            a, b = float(t.sc[p]["pJ_MAC"]), float(f.sc[p]["pJ_MAC"])
            rows.append([f"SC {t.sc[p]['workload']} pJ/MAC", f4(a), f4(b), pct(b, a)])
        for p in sorted(set(t.int) & set(f.int), key=lambda n: (t.int[n]["precision"], int(t.int[n]["L"]), n)):
            rt, rf = t.int[p], f.int[p]
            if rt["schedule"] != "abit":
                continue
            a, b = float(rt["pJ_MAC"]), float(rf["pJ_MAC"])
            rows.append([f"{int_label(rt)} pJ/MAC", f4(a), f4(b), pct(b, a)])
            rows.append(["  block period (1 PE, edges)", rt["block_period"], rf["block_period"],
                         pct(float(rf["block_period"]), float(rt["block_period"]))])
            if rt["saif_mode"] == "0":
                ea = float(rt["pJ_MAC"]) * float(rt["block_period"])
                eb = float(rf["pJ_MAC"]) * float(rf["block_period"])
                rows.append(["  energy x period (pJ/MAC x edges)", f1(ea), f1(eb), pct(eb, ea)])
                for g in ("4x4", "4x8"):
                    ga, gb = t.int_gmacs(rt, g), f.int_gmacs(rf, g)
                    bb = bos.get(rt["precision"])
                    tail = f" ({gb / bb['gmacs_mm2']:.2f}x BOS)" if bb and gb else ""
                    rows.append([f"  GMAC/s/mm2 {g}", f0(ga), f0(gb) + tail, pct(gb, ga)])
        kind = f"{SHAPE_LABEL[t.shape]}{' DR' if t.drain else ''}"
        L += [f"{kind}: {t.route.name} (in-place lap) vs {f.route.name} (lap fold)", ""]
        L += table(["", "in-place lap", "lap fold", "change"], rows, "lrrr") + [""]
    return L


def block_sources(S: list[MeasureSet]) -> list[str]:
    L = ["## Sources", ""]
    for s in S:
        L += [f"- {s.label}: route `{s.route.relative_to(REPO) if s.route.is_relative_to(REPO) else s.route}` "
              f"(top `{s.top}`), qualification `{s.evidence.relative_to(REPO)}`, measurements "
              f"{', '.join(f'`{d.relative_to(REPO)}`' for d in s.dirs)} ({len(s.sc)} SC + {len(s.int)} INT points, "
              "every one through gl-audit, "
              "saif-sc / saif-int, sdf-clock, pt-coverage and its trace checker)."]
    return L + [""]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("measure", nargs="*", type=Path, help="flow/measure.py directories (default: every "
                                                          "build/flow/*/measure with results)")
    ap.add_argument("--bos-results", type=Path, action="append", default=[],
                    help="extra BOS results.csv (flow/bos.sh); its rows replace the default ones per precision")
    ap.add_argument("--out", type=Path, default=REPO / "doc/payn_results.md")
    a = ap.parse_args()
    dirs = a.measure or sorted(d.parent for d in (REPO / "build/flow").glob("*/measure*/inputs.txt"))
    S = [MeasureSet(d.resolve()) for d in dirs]
    S = [s for s in S if s.sc or s.int or s.blocked]
    merged: dict[tuple, MeasureSet] = {}
    for s in S:                                    # one set per route: merge its measurement directories
        key = (s.route, s.top, s.shape)
        if key in merged:
            merged[key].absorb(s)
        else:
            merged[key] = s
    S = list(merged.values())
    if not S:
        raise SystemExit("no measurement with results")
    S.sort(key=lambda s: (s.shape != "k16m8", s.drain, s.fold, s.route.name))
    bos = load_bos([p.resolve() for p in a.bos_results])
    L = ["# PaYN results", "",
         "Generated by `flow/report.py` from the run directories listed under Sources; do not edit by hand (rerun "
         "`python3 flow/report.py` after new measurements).  Every number below is read from a qualified route, "
         "its qualification evidence and its gated measurements.", ""]
    L += block_route(S) + block_area(S) + block_sc(S) + block_int(S) + block_bos(S, bos) + block_lut(S, bos) \
         + block_drain(S, bos) + block_fold(S, bos) + block_sources(S)
    a.out.parent.mkdir(parents=True, exist_ok=True)
    a.out.write_text("\n".join(L) + "\n")
    print(f"wrote {a.out} ({len(S)} measurement sets: {', '.join(s.label for s in S)}; BOS {', '.join(sorted(bos))})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
