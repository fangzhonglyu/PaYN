#!/usr/bin/env python3
"""Lap schedules for the bit-plane (BP) INT mode: can we run through the
reduction dimension first and apply the weight-bit factors once at the end?

Pure Python + numpy, no EDA.  Rerun:

    python3 sweeps/int_mode/bp/model_lap_schedules.py > sweeps/int_mode/bp/model_lap_schedules.log
    (--quick: smaller simulator matrix; --t3-pe-add-um2 X: replace the T3 area
     placeholder with a synthesized per-PE number; --csv PATH)

Exit status is non-zero on any validation mismatch.

Schedules (PE = 8x8 tiles, K=8 lanes x M=16 positions = 128 reduction
elements per tile per data edge; operands registered once per PE and
broadcast; accumulators chain west -> east):

  T1  BP-time, as built (csa_bp_20261004_lap).  Tile row h = activation bit h,
      tile column v = output column v, weight bits in time (BW passes, MSB
      first).  Between passes an 8-edge ring lap rotates every tile row once
      around its own drain chain with <<1 at the PE west input (Horner over
      weight bits).  ring_q rides the A wave: PE (r,c) laps at offset r+c.
  T1g T1 with global laps (csa_bp_20261003b usage): every lap waits for the
      far PE.  Reference only (validates the model against the 2nd column of
      measured periods).
  T2  BP-space-S, S in {2,4,8}: S weight bits in SPACE across tile columns
      (8/S output columns per PE), BW/S passes in time.  Column v = jj*S + s
      (output jj, group s); in pass p (p = BW/S-1 first) group s carries
      weight bit q = p + (BW/S)*s, so the existing <<1 ring still works and
      the east combiner applies 2^((BW/S)*s) by a Horner step over the S
      columns of an output (they drain east-first, s = S-1 first).  S = BW
      ("all weight bits in space": INT8 S=8, 4-bit S=4) has one pass, no lap,
      no ring: "execute through the reduction dimension, then shift".
  T3  BP-time with in-place doubling: the lap edge loads each tile's OWN
      acc_out << 1 (a 24-bit mux per tile at PE level, 64 per PE instead of
      the ring's 8), so a lap is 1 edge instead of 8.
  T4  continuous rotation: shift and MAC on the same edge (tile change), W
      column buses rotated so every column value meets its own weights; the
      N_W-edge rotation windows carry MACs, so laps cost no edges, but the 8
      values wrap at 8 different edges, so pass boundaries are staggered by
      up to N_W-1 = 7 edges.  Model only.
  H   BP-hybrid (TA,TW), added after the adversarial review: TA activation
      bits AND TW weight bits in time per tile, GA = BA/TA activation-bit
      groups on the tile rows (8/GA = 8*TA/BA activation rows per PE) and
      GW = BW/TW weight-bit groups on the tile columns (8*TW/BW output columns
      per PE).  Passes (ta,q), grouped by Horner level k = ta+q (highest
      first); one existing 8-edge per-PE ring lap between levels (TA+TW-2
      laps); sign words reloaded per pass (row negative iff its bit g*TA+ta
      is the activation MSB, column iff s*TW+q is the weight MSB); one drain.
      Tile ((i,g),(j,s)) = sum_x Afield_g[i,x] * Wfield_s[x,j]; east combine
      out = sum_g sum_s 2^(g*TA + s*TW) T.  No tile, PE or grid-wrapper change
      (RTL: designs/payn/tb/test_pe_grid_bp_hybrid.sv); the east combine and
      the A feeder differ from T1's.  T1 = H(1,BW), T2 S=BW = H(1,1), and the
      round-1 'HB' mapping (sweeps/int_mode/model_bitplane_throughput.py) is
      H(BA,BW).  More outputs per PE amortise the same skew + drain (and
      nearly the same laps) over TA x more MACs.  Range: the 24-bit tile holds
      |Afield| * |Wfield| * L, e.g. INT8 H(4,8) L <= 4,369.
  H3  H with T3's 1-edge in-place doubling for the laps (needs the T3 PE
      change, csa_bp_ipd RTL).  Model only.

INT4 follows the as-built mapping: tile rows 0-3 and 4-7 are two activation
rows of 4 planes (two outputs per tile column).  W4A8 is 8 planes x 4 weight
bits.  The T2 analogs keep those rows and split the columns into 8/S output
columns x S weight-bit groups (S <= BW).

What the script does:
  1. Validates the T1 / T1g closed forms against every measured period:
     the periods listed in the task (grid bench, L=4096), every period line of
     the grid bench summary (build/rtl_preflight/csa_bp_grid/summary.log), every
     base-to-base period of the independent grid harness
     (build/rtl_preflight/csa_bp_verify_grid/*/check.json), the routed
     single-PE INT runs (data/ring/drain cycles, MAC/cycle) and the README's
     single-PE numbers; reproduces section 10's SRAM numbers.
  2. Runs a value-level simulator of the PE grid with the RTL tile semantics
     (read from inner_tile_signed_segmented_csa.sv / the BP PE / the grid
     wrapper: shift has priority over MAC and discards it; core shift =
     shift_in | ring_q for all 64 tiles of a PE; ring lap west input =
     own east << 1; drain = global shift_in with acc_in_west = 0; operands
     and ring_q reach PE (r,c) r+c edges after PE (0,0)).  Every schedule is
     built from first principles (last MAC, skew, drain), run bit-exactly
     against numpy on 1x1 / 2x3 / 4x4 / 4x8 grids, its period compared with
     the closed form, and three one-edge-shorter negative controls must fail.
     T1 / T1g simulator periods are also compared with the measured RTL ones.
  3. Prints the tables: edges per output block, outputs per PE per block,
     MAC/tile-cycle, % of peak, GMAC/s/mm2 (routed csa_bp_20261004_lap areas
     plus clearly labelled placeholders), operand bandwidth and sends,
     weight layout, the two SRAM readings of doc section 10, SC-mode cost,
     and a verdict on the analytical expectation.
  4. (review fix) The H / H3 family: closed form, simulator runs (incl. the
     24-bit range limit and one-edge-short negatives), validation against
     every RTL hybrid run found under build/rtl_preflight/bp_hybrid*/ (grid
     bench) and bp_hybrid_top/ (single-PE top), best (TA,TW) per L, and an
     edge-buffered SRAM reading (A replay buffer + W block buffer with M as
     the inner loop) for every schedule and for spatial Booth on the same terms.
"""
from __future__ import annotations

import argparse
import csv
import json
import math
import re
import sys
import zlib
from dataclasses import dataclass
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parents[3]
F_GHZ = 0.4
NH = NW = 8
SLOT = 128                      # K*M reduction elements per tile per data edge
OW = 24
TILE_MAX = (1 << (OW - 1)) - 1
DEMAND = NH * SLOT              # 1,024 operand bits per data edge per edge half (A row / W column)
PREC = {"INT8": (8, 8), "W4A8": (8, 4), "INT4": (4, 4)}   # (BA, BW)
SHAPES = {"1PE": (1, 1), "4x4": (4, 4), "4x8": (4, 8)}
LS = (128, 256, 1024, 4096, 65536)
READINGS = (("(i) 72 b/cyc avg", 72), ("(ii) 576 b every cyc", 576))

ROUTE_AREA = "apr/build/TSMC22/PAYN_SC_CSA_BP/csa_bp_20261004_lap_distguide_spp_pins/reports/area.rpt"
GRID_SUMMARY = "build/rtl_preflight/csa_bp_grid/summary.log"
VG_DIR = "build/rtl_preflight/csa_bp_verify_grid"
INT_RESULTS = ("build/power_char/int_mode_energy_20261004_lap/bp/"
               "csa_bp_20261004_lap_distguide_spp_pins/results.csv")
COMPOSED = ("build/power_char/int_mode_energy_20261003/bp/"
            "csa_bp_20261003b_distguide_spp_pins/composed_vs_L.csv")
IPD_JSON = "build/rtl_preflight/bp_ipd/area_efficiency.json"   # In-place stage (T3 RTL, csa_bp_ipd_20261004), optional
HYB_RTL_GLOBS = ("build/rtl_preflight/bp_hybrid/hyb/*/check.json",          # adversarial review (grid bench)
                 "build/rtl_preflight/bp_hybrid_fix/hyb/*/check.json",      # fix stage, extra grid cases
                 "build/rtl_preflight/bp_hybrid_top/hyb/*/check.json")      # fix stage, single-PE top
# Edge-buffered SRAM reading (section 6b): GEMM shape the buffers amortise over.  M = activation rows
# (tokens; S=2048 prefill), N = output columns (LLaMA-2-7B d_model projection width).
GEMM_M, GEMM_N = 2048, 4096

# Cell footprints (um2), as in sweeps/int_mode/bitplane_throughput_costs.py (TSMC22 LEF)
AO22, FA, DFF2W, AND2, OR2 = 0.686, 1.666, 1.372, 0.392, 0.392

FAILS: list[str] = []


def fail(msg):
    FAILS.append(msg)
    print(f"  ** MISMATCH: {msg}")


def cdiv(a, b):
    return -(-a // b)


# ======================================================================= inputs
def read_areas():
    want = {"payn_array_signed_segmented_csa_bp": "total", "u_pe": "u_pe", "u_pe/u_array_core": "core",
            "u_peripheral": "periph", "u_combiner": "comb", "u_a_rng": "a_rng", "u_w_rng": "w_rng"}
    d = {}
    for line in (REPO / ROUTE_AREA).read_text().splitlines():
        f = line.split()
        if f and f[0] in want and want[f[0]] not in d:
            d[want[f[0]]] = float(f[2] if f[0] == "payn_array_signed_segmented_csa_bp" else f[3])
    d["sobol"] = d["a_rng"] + d["w_rng"]
    d["ring"] = d["u_pe"] - d["core"]          # routed ring wrapper: ring_q, OR2, 192-bit west mux
    return d


A = read_areas()
T3SRC = {"mode": "placeholder"}   # set in main(): "ipd" when the In-place stage result exists
PH = {   # PLACEHOLDERS (unsynthesized); per unit, um2
    "T3_pe": 7.0 * A["ring"],                  # 1,344 more mux bits (64x24 - 8x24) at the routed ring's per-bit cost
    "T3_pe_cellcount": (64 - 8) * 24 * AO22,   # cross-check: AO22 per added mux bit
    "horner_row": 40 * (FA + DFF2W + AND2),    # 40-bit R <- 2^k R + S per PE row (bitplane_throughput_costs.py COMB)
    "T4_tile": 9 * AO22 + 2 * AND2,            # 9-bit heap acc_low source mux + shift/MAC enable gating, per tile
    "T4_rot": 3 * DEMAND * AO22,               # 3-stage log rotator on the 1,024-bit W bus, per PE-column edge
    # H combine per PE row: out[il] = sum_{g<GA} 2^(g*TA) T(il*GA+g), GA in {1,2,4,8}: the existing
    # 3-level tree with selectable level shifts plus 8 output words instead of 2.
    "hyb_comb_row": (192 * DFF2W               # 256 output flops instead of 64
                     + 4 * 28 * (AO22 + AND2)  # level-1 shift select {1,2,4}, 4 x 28 b
                     + 2 * 30 * AO22           # level-2 shift select {2,4}, 2 x 30 b
                     + 256 * AO22),            # output word select (raw tile / level 1 / 2 / 3)
}
MUX = {1: 0.0, 2: AO22, 4: 2 * AO22 + OR2, 8: 4 * AO22 + 3 * OR2}   # n:1 select per operand line (um2)


# ==================================================================== schedules
@dataclass(frozen=True)
class Sch:
    key: str        # T1, T1g, T2, T3, T4, H, H3
    S: int = 1
    TA: int = 0     # H / H3: activation bits in time per tile
    TW: int = 0     # H / H3: weight bits in time per tile

    @property
    def name(self):
        if self.key == "T2":
            return f"T2 S={self.S}"
        if self.key in ("H", "H3"):
            return f"{self.key}({self.TA},{self.TW})"
        return self.key


SCHEDS = [Sch("T1"), Sch("T2", 2), Sch("T2", 4), Sch("T2", 8), Sch("T3"), Sch("T4")]
T1G = Sch("T1g")
LABEL = {"T1": "T1 BP-time, 8-edge ring laps (as built)", "T1g": "T1 with global laps (03b usage)",
         "T2": "T2 BP-space-S (weight bits across columns)", "T3": "T3 in-place doubling, 1-edge laps",
         "T4": "T4 continuous rotation (shift+MAC tile)",
         "H": "H BP-hybrid (TA act bits + TW weight bits in time; no PE change)",
         "H3": "H3 BP-hybrid with T3 1-edge laps (T3 PE change)"}
# H points shown in the tables (all valid (TA,TW) compete for "H best"); HEAD = the review's headline point.
HYB_SHOW = {"INT8": [(2, 8), (4, 4), (4, 8), (8, 8)], "W4A8": [(4, 4), (8, 4)], "INT4": [(2, 4), (4, 4)]}
HYB_HEAD = {"INT8": (4, 8), "W4A8": (8, 4), "INT4": (4, 4)}


def H(ta, tw, key="H"):
    return Sch(key, TA=ta, TW=tw)


def hyb_cands(prec):
    ba, bw = PREC[prec]
    return [(ta, tw) for ta in (1, 2, 4, 8) for tw in (1, 2, 4, 8)
            if ta <= ba and tw <= bw and ba % ta == 0 and bw % tw == 0]


def levels(ta_n, tw_n):
    """H passes (ta, q) grouped by Horner level k = ta + q, highest level first, ta high first."""
    return [[(ta, k - ta) for ta in range(ta_n - 1, -1, -1) if 0 <= k - ta < tw_n]
            for k in range(ta_n + tw_n - 2, -1, -1)]


def applies(sch, prec):
    if sch.key in ("H", "H3"):
        ba, bw = PREC[prec]
        return (1 <= sch.TA <= ba and 1 <= sch.TW <= bw and ba % sch.TA == 0 and bw % sch.TW == 0)
    return sch.key != "T2" or sch.S <= PREC[prec][1]


def mapping(sch, prec):
    """(BA, BW, activation rows per PE, output columns per PE, passes)."""
    ba, bw = PREC[prec]
    rows_pe = NH // ba
    if sch.key == "T2":
        return ba, bw, rows_pe, NW // sch.S, bw // sch.S
    if sch.key in ("H", "H3"):
        return ba, bw, NH // (ba // sch.TA), NW // (bw // sch.TW), sch.TA * sch.TW
    return ba, bw, rows_pe, NW, bw


def peak_tc(prec):
    ba, bw = PREC[prec]
    return SLOT // (ba * bw)          # MAC per tile per data edge: 2 / 4 / 8


def lmax(sch, prec):
    """Longest reduction per output block that the 24-bit tile holds exactly."""
    ba, bw = PREC[prec]
    if sch.key == "T2":
        f = bw // sch.S               # weight field bits per column group
        m = max(1 << (f - 1), (1 << f) - 1)   # signed top group, unsigned lower groups (S >= 2)
    elif sch.key in ("H", "H3"):      # |Afield| * |Wfield|: unsigned lower groups 2^T - 1, a lone signed group 2^(T-1)
        am = (1 << sch.TA) - 1 if ba // sch.TA > 1 else 1 << (sch.TA - 1)
        wm = (1 << sch.TW) - 1 if bw // sch.TW > 1 else 1 << (sch.TW - 1)
        m = am * wm
    else:
        m = 1 << (bw - 1)             # full weight value (Horner in the tile)
    return TILE_MAX // m


def block_terms(sch, prec, L, pr, pc, row_skew_drain=False):
    """Closed form of one output block (L <= lmax).  Edges, PE (0,0) view."""
    _, _, _, _, P = mapping(sch, prec)
    NB = cdiv(L, SLOT)
    Sk = pr + pc - 2
    skew = (pc - 1) if row_skew_drain else Sk
    drain = NW * pc
    D = P * NB
    if sch.key in ("T1", "T2"):
        lap = NW * (P - 1)
    elif sch.key == "T1g":
        lap = (NW + Sk) * (P - 1)     # each lap waits for the far PE
    elif sch.key == "T3":
        lap = P - 1
    elif sch.key == "T4":             # stagger: 2NB + (P-2)max(NB,8) + 7 active edges vs P*NB data
        lap = (P - 2) * (max(NB, NW) - NB) + (NW - 1) if P >= 2 else 0
    elif sch.key == "H":              # one 8-edge per-PE ring lap between Horner levels
        lap = NW * (sch.TA + sch.TW - 2)
    elif sch.key == "H3":             # one 1-edge in-place doubling between Horner levels
        lap = sch.TA + sch.TW - 2
    else:
        raise ValueError(sch)
    return dict(NB=NB, D=D, lap=lap, skew=skew, drain=drain, period=D + lap + skew + drain)


def schedule(sch, prec, L, pr, pc, row_skew_drain=False):
    ba, bw, rows_pe, cols_pe, P = mapping(sch, prec)
    lm = lmax(sch, prec)
    nsplit = cdiv(L, lm)
    lsub = cdiv(L, nsplit)
    t = block_terms(sch, prec, lsub, pr, pc, row_skew_drain)
    n = pr * pc
    outs = rows_pe * cols_pe
    period = nsplit * t["period"]
    macs = n * outs * L
    mac_tc = macs / (n * 64 * period)
    return dict(t, nsplit=nsplit, lsub=lsub, P=P, outs=outs, period=period, D_tot=nsplit * t["D"],
                macs=macs, mac_tc=mac_tc, pct=mac_tc / peak_tc(prec), rows_pe=rows_pe, cols_pe=cols_pe)


def data_pattern(sch, prec, L, pr, pc):
    """Per-edge operand demand of one period (1 = a 1,024-bit data edge on every edge half, 0 = lap /
    stagger / skew / drain edge).  T4's staggered edges are lumped after its P*NB data edges."""
    s = schedule(sch, prec, L, pr, pc)
    pat = []
    for _ in range(s["nsplit"]):
        if sch.key == "T4":
            pat += [1] * s["D"] + [0] * s["lap"]
        elif sch.key in ("H", "H3"):
            lv = levels(sch.TA, sch.TW)
            lap_len = NW if sch.key == "H" else 1
            for li, pl in enumerate(lv):
                pat += [1] * (len(pl) * s["NB"]) + ([0] * lap_len if li < len(lv) - 1 else [])
        else:
            lap_len = s["lap"] // (s["P"] - 1) if s["P"] > 1 else 0
            for p in range(s["P"]):
                pat += [1] * s["NB"] + ([0] * lap_len if p < s["P"] - 1 else [])
        pat += [0] * (s["skew"] + s["drain"])
    assert len(pat) == s["period"]
    return pat


def prefetch_buffer(pat, sup):
    """Smallest buffer (bits per edge half) that lets a feeder streaming sup b/cycle reach the fluid
    period max(P, D*1024/sup).  Memory-bound: hold what arrives during the longest non-data stretch.
    Overhead-bound: hold the largest deficit of any (cyclic) window, max sum of 1024*d - sup."""
    P, D = len(pat), sum(pat)
    if D * DEMAND > sup * P:
        run = best = 0
        for x in pat + pat:
            run = run + 1 if x == 0 else 0
            best = max(best, run)
        return sup * min(best, P)
    cur = best = 0
    for x in pat + pat:
        cur = max(0, cur + (DEMAND if x else 0) - sup)
        best = max(best, cur)
    return best


def area(sch, prec, shape):
    """Area (um2) and a note.  Routed csa_bp_20261004_lap blocks + labelled placeholders."""
    pr, pc = SHAPES[shape]
    n = pr * pc
    base = A["total"] if n == 1 else n * A["u_pe"] + (pr + pc) / 2 * A["periph"] + pr * A["comb"] + A["sobol"]
    add, note = 0.0, "routed"
    bw = PREC[prec][1]
    if sch.key == "T2":
        add += pr * PH["horner_row"]
        note = "routed + Horner PLACEHOLDER"
        if sch.S == bw:
            add -= n * A["ring"]
            note += " - routed ring"
    elif sch.key == "T3":
        if T3SRC["mode"] == "ipd":     # synthesized IPD - lap delta on the routed lap blocks (estimate)
            add += (T3SRC["d_total"] if n == 1 else n * T3SRC["d_pe"] + (pr + pc) / 2 * T3SRC["d_periph"])
            note = "routed lap + synthesized IPD delta (ESTIMATE)"
        else:
            add += n * PH["T3_pe"]
            note = "routed + T3 mux PLACEHOLDER"
    elif sch.key == "T4":
        add += n * 64 * PH["T4_tile"] + pc * PH["T4_rot"]
        note = "routed + T4 tile/rotator PLACEHOLDER"
    elif sch.key in ("H", "H3"):
        notes = []
        if sch.key == "H3":
            t3, t3note = area(Sch("T3"), prec, shape)
            add += t3 - base
            notes.append("T3 laps (" + ("synth. delta, ESTIMATE" if T3SRC["mode"] == "ipd" else "PLACEHOLDER") + ")")
        if (sch.TA, sch.TW) != (1, bw):          # H(1,BW) is T1's mapping: the existing combiner serves it
            add += pr * PH["hyb_comb_row"]
            notes.append("H combiner PLACEHOLDER")
            if bw // sch.TW > 1:
                add += pr * PH["horner_row"]
                notes.append("column Horner PLACEHOLDER")
        note = "routed" + "".join(" + " + x for x in notes)
    return base + add, note


def feeder_mux_area(sch, prec, shape):
    """Sensitivity: the feeder selects the time-multiplexed bit planes from byte-major words instead of
    the SRAM storing them bit-plane-major (n:1 select per operand line, 1,024 lines per edge half)."""
    pr, pc = SHAPES[shape]
    ba, bw, _, _, P = mapping(sch, prec)
    if sch.key in ("H", "H3"):
        ta, tw = sch.TA, sch.TW
    elif sch.key == "T2":
        ta, tw = 1, P
    else:
        ta, tw = 1, bw
    return pr * DEMAND * MUX[ta] + pc * DEMAND * MUX[tw]


def gmacs(macs, period, ar):
    return macs / period * F_GHZ / (ar * 1e-6)


def best_h(prec, L, shape, key="H"):
    """Best (TA,TW) of the H (or H3) family at this L: max GMAC/s/mm2 (24-bit splits included)."""
    pr, pc = SHAPES[shape]
    best = None
    for ta, tw in hyb_cands(prec):
        sch = H(ta, tw, key)
        s = schedule(sch, prec, L, pr, pc)
        g = gmacs(s["macs"], s["period"], area(sch, prec, shape)[0])
        if best is None or g > best[0] + 1e-9:
            best = (g, sch)
    return best[1]


# ============================================================ value-level sim
class Prog:
    """Per-virtual-time operands and controls.  Virtual time u = the edge on
    which PE (0,0) MACs a slice; PE (r,c) MACs it (and sees its lap / doubling
    / rotation control) on edge u + r + c.  Global controls are absolute."""

    def __init__(self, pr, pc, U):
        self.a = np.zeros((U, pr, NH, SLOT), np.uint8)
        self.w = np.zeros((U, pc, NW, SLOT), np.uint8)
        self.ws = np.zeros((U, pc, NW), np.uint8)
        self.lap_v = np.zeros(U, bool)
        self.dbl_v = np.zeros(U, bool)
        self.rot_v = np.zeros(U, bool)
        self.lap_abs, self.shift_abs = set(), set()
        self.sa = np.zeros((U, NH), np.uint8)      # row sign word per virtual time (H reloads it per pass)
        self.U = U


def planes(X, bits):
    """X int (rows, L) two's complement -> (rows, bits, L) 0/1."""
    xu = X.astype(np.int64) & ((1 << bits) - 1)
    return ((xu[:, None, :] >> np.arange(bits)[None, :, None]) & 1).astype(np.uint8)


def wfield(W, bw, qs):
    """Signed value of the weight bits qs (MSB of the weight negative)."""
    wu = W.astype(np.int64) & ((1 << bw) - 1)
    v = np.zeros_like(wu)
    for k, q in enumerate(qs):
        b = (wu >> q) & 1
        v += (-(b << k)) if q == bw - 1 else (b << k)
    return v


class Builder:
    def __init__(self, sch, prec, L, pr, pc, nblk):
        self.sch, self.prec, self.L, self.pr, self.pc = sch, prec, L, pr, pc
        self.ba, self.bw, self.rows_pe, self.cols_pe, self.P = mapping(sch, prec)
        self.NB = cdiv(L, SLOT)
        self.Sk = pr + pc - 2
        self.hyb = sch.key in ("H", "H3")
        self.ga = self.ba // sch.TA if self.hyb else self.ba          # tile rows per activation row
        self.gw = self.bw // sch.TW if self.hyb else 1
        if self.hyb:
            U = nblk * (self.P * self.NB + (NW + 1) * (sch.TA + sch.TW) + NW * pc + self.Sk + 24) + 32
        else:
            U = nblk * (self.bw * self.NB + (NW + self.Sk + 1) * self.bw
                        + 2 * max(self.NB, NW) + NW * pc + self.Sk + 24) + 32
        self.prog = Prog(pr, pc, U)
        self.prog.sa[:] = [(h % self.ba) == self.ba - 1 for h in range(NH)]
        self.rows_idx = np.array([[r * self.rows_pe + h // self.ga for h in range(NH)] for r in range(pr)])
        self.plane_idx = np.array([h % self.ba for h in range(NH)])

    def q_of(self, p, v):
        if self.sch.key == "T2":
            f = self.bw // self.sch.S
            return (f - 1 - p) + f * (v % self.sch.S)
        return self.bw - 1 - p

    def j_of(self, c, v):
        if self.sch.key == "T2":
            return c * self.cols_pe + v // self.sch.S
        return c * NW + v

    def put_a(self, u, Apl, xb):
        x0, x1 = xb * SLOT, min(self.L, xb * SLOT + SLOT)
        self.prog.a[u, :, :, :x1 - x0] = Apl[self.rows_idx, self.plane_idx[None, :], x0:x1]

    def put_w(self, u, Wpl, xb, c_cols, v_cols, j_cols, q_cols):
        """W bits for PE columns c_cols (all), tile columns v_cols carrying output j_cols bit q_cols."""
        x0, x1 = xb * SLOT, min(self.L, xb * SLOT + SLOT)
        self.prog.w[u, c_cols, v_cols, :x1 - x0] = Wpl[q_cols, j_cols, x0:x1]
        self.prog.ws[u, c_cols, v_cols] = (q_cols == self.bw - 1)

    def block_uniform(self, U0, Apl, Wpl, neg):
        """T1 / T1g / T2 / T3: every column of a PE in the same pass."""
        pr, pc, NB, P = self.pr, self.pc, self.NB, self.P
        cc, vv = np.meshgrid(np.arange(pc), np.arange(NW), indexing="ij")
        jj = np.vectorize(self.j_of)(cc, vv)
        u = U0
        last = None
        for p in range(P):
            qq = np.vectorize(lambda v: self.q_of(p, v))(vv)
            for b in range(NB):
                self.put_a(u + b, Apl, b)
                self.put_w(u + b, Wpl, b, cc, vv, jj, qq)
            last = u + NB - 1
            if p < P - 1:
                gs = -1 if (neg == "gap_short" and p == 0) else 0
                if self.sch.key == "T1g":            # broadcast lap after the far PE's last MAC
                    l0 = last + self.Sk + 1 + gs
                    self.prog.lap_abs.update(range(l0, l0 + NW))
                    u = l0 + NW
                elif self.sch.key in ("T1", "T2"):   # per-PE ring lap rides the A wave
                    self.prog.lap_v[last + 1 + gs: last + 1 + gs + NW] = True
                    u = last + 1 + NW + gs
                elif self.sch.key == "T3":           # 1-edge in-place doubling
                    self.prog.dbl_v[last + 1 + gs] = True
                    u = last + 2 + gs
        return last, True

    def block_hybrid(self, U0, Apl, Wpl, neg):
        """H / H3: passes (ta, q) by Horner level, sign words reloaded per pass, one lap (8-edge ring
        lap riding the A wave, or 1-edge doubling) between levels."""
        pc, NB, ga, gw = self.pc, self.NB, self.ga, self.gw
        ta_n, tw_n = self.sch.TA, self.sch.TW
        cc, vv = np.meshgrid(np.arange(pc), np.arange(NW), indexing="ij")
        jj = cc * self.cols_pe + vv // gw
        lv = levels(ta_n, tw_n)
        u, last = U0, None
        for li, pl in enumerate(lv):
            for ta, q in pl:
                pla = np.array([(h % ga) * ta_n + ta for h in range(NH)])
                qq = (vv % gw) * tw_n + q
                srow = (pla == self.ba - 1).astype(np.uint8)
                for b in range(NB):
                    x0, x1 = b * SLOT, min(self.L, b * SLOT + SLOT)
                    self.prog.a[u + b, :, :, :x1 - x0] = Apl[self.rows_idx, pla[None, :], x0:x1]
                    self.put_w(u + b, Wpl, b, cc, vv, jj, qq)
                    self.prog.sa[u + b] = srow
                last = u + NB - 1
                u += NB
            if li < len(lv) - 1:
                gs = -1 if (neg == "gap_short" and li == 0) else 0
                if self.sch.key == "H":
                    self.prog.lap_v[last + 1 + gs: last + 1 + gs + NW] = True
                    u = last + 1 + NW + gs
                else:
                    self.prog.dbl_v[last + 1 + gs] = True
                    u = last + 2 + gs
        return last, True

    def block_t4(self, U0, Apl, Wpl, neg):
        pc, NB, bw = self.pc, self.NB, self.bw
        gs = -1 if neg == "gap_short" else 0
        sp = max(NB, NW) + gs
        wins = [U0 + NB + gs + i * sp for i in range(bw - 1)]
        rot = set()
        for w0 in wins:
            rot.update(range(w0, w0 + NW))
        for u in rot:
            self.prog.rot_v[u] = True
        passj, done, fin = [0] * NW, [set() for _ in range(NW)], [False] * NW
        cols = np.arange(pc)
        m, u, last, feasible = 0, U0, None, True
        wend = max(rot)                 # after the last window a value needs at most NB more edges
        while not all(fin) and u <= wend + NB:
            is_rot = u in rot
            m_after = (m + is_rot) % NW
            xb = (u - U0) % NB
            self.put_a(u, Apl, xb)
            for j in range(NW):
                if is_rot and (j + m) % NW == NW - 1:          # value j wraps (doubled) on this edge
                    if len(done[j]) != NB or passj[j] >= bw - 1:
                        feasible = False
                    passj[j] = min(passj[j] + 1, bw - 1)
                    done[j] = set()
                if not fin[j] and xb not in done[j]:
                    q = bw - 1 - passj[j]
                    v = (j + m_after) % NW                      # the column value j sits in after this edge
                    self.put_w(u, Wpl, xb, cols, np.full(pc, v), cols * NW + j, np.full(pc, q))
                    done[j].add(xb)
                    last = u
                    if passj[j] == bw - 1 and len(done[j]) == NB:
                        fin[j] = True
            m = m_after
            u += 1
        if m != 0 or not all(fin):
            feasible = False
        return last, feasible

    def build(self, blocks, neg=None):
        metas = []
        U0 = 1
        for k, (Am, Wm) in enumerate(blocks):
            Apl = planes(Am, self.ba)
            Wpl = np.ascontiguousarray(planes(Wm.T, self.bw))   # (cols, bw, L) -> index [q, j, x] below
            Wpl = np.ascontiguousarray(Wpl.transpose(1, 0, 2))
            if self.sch.key == "T4":
                last, feas = self.block_t4(U0, Apl, Wpl, neg)
            elif self.hyb:
                last, feas = self.block_hybrid(U0, Apl, Wpl, neg)
            else:
                last, feas = self.block_uniform(U0, Apl, Wpl, neg)
            d0 = last + self.Sk + 1 + (-1 if neg == "drain_early" else 0)   # after the far PE's last MAC
            self.prog.shift_abs.update(range(d0, d0 + NW * self.pc))
            nxt = last + self.Sk + 1 + NW * self.pc + (-1 if (neg == "next_early" and k == 0) else 0)
            metas.append(dict(U0=U0, last=last, d0=d0, period=nxt - U0, active=last - U0 + 1,
                              feasible=feas, A=Am, W=Wm))
            U0 = nxt
        E = metas[-1]["d0"] + NW * self.pc
        assert E + 1 < self.prog.U, "program buffer too small"
        return metas, E


def simulate(prog, pr, pc, E):
    T = np.zeros((pr, pc, NH, NW), np.int64)
    rr, cc = np.meshgrid(np.arange(pr), np.arange(pc), indexing="ij")
    U = prog.U
    caps = {}
    maxabs = 0
    for e in range(E):
        uu = e - rr - cc
        valid = (uu >= 0) & (uu < U)
        uc = np.clip(uu, 0, U - 1)
        Ag = prog.a[uc, rr].astype(np.int32)
        Wg = prog.w[uc, cc].astype(np.int32)
        cnt = np.matmul(Ag, Wg.transpose(0, 1, 3, 2)).astype(np.int64)
        sg = (prog.sa[uc][:, :, :, None] ^ prog.ws[uc, cc][:, :, None, :]).astype(np.int64)
        d = np.where(valid[..., None, None], cnt * (1 - 2 * sg), 0)
        lap = (prog.lap_v[uc] & valid) | (e in prog.lap_abs)
        dbl = prog.dbl_v[uc] & valid
        rot = prog.rot_v[uc] & valid
        sh = e in prog.shift_abs
        if sh and rot.any():
            raise RuntimeError(f"edge {e}: drain during a T4 rotation")
        if (dbl & (lap | sh)).any():
            raise RuntimeError(f"edge {e}: doubling on a shift edge")
        if sh:      # combiner: int_mode & shift_in & ~ring_q(east PE), pre-edge east column
            caps[e] = {r: T[r, pc - 1, :, NW - 1].copy() for r in range(pr) if not lap[r, pc - 1]}
        own = 2 * T[:, :, :, NW - 1]                                   # {acc_out_east[22:0], 0}
        west = np.zeros((pr, pc, NH), np.int64)
        west[:, 1:] = T[:, :-1, :, NW - 1]                              # acc_in_west = 0 at the grid edge
        col0 = np.where(lap[..., None], own, west)
        shift_src = np.concatenate([col0[..., None], T[..., :-1]], axis=3)
        rot_src = np.concatenate([own[..., None], T[..., :-1]], axis=3) + d
        smask = (lap | sh)[..., None, None]                             # shift priority: MAC dropped
        T = np.where(smask, shift_src,
                     np.where(dbl[..., None, None], 2 * T,
                              np.where(rot[..., None, None], rot_src, T + d)))
        maxabs = max(maxabs, int(np.abs(T).max()))
    return caps, maxabs


def check_blocks(bld, metas, caps):
    """Drained tiles vs the scheme's field formula; combined outputs vs A @ W."""
    sch, pr, pc = bld.sch, bld.pr, bld.pc
    ba, bw = bld.ba, bld.bw
    n_tile_mm = n_out_mm = n_out = 0
    for mt in metas:
        Am, Wm = mt["A"], mt["W"]
        Apl = planes(Am, ba).astype(np.int64)                  # (rows, ba, L)
        ref = Am.astype(np.int64) @ Wm.astype(np.int64)
        got = np.zeros_like(ref)
        seen = np.zeros(ref.shape, bool)
        for r in range(pr):
            seq = []
            for k in range(NW * pc):
                e = mt["d0"] + k
                if e not in caps or r not in caps[e]:
                    n_tile_mm += 1
                    seq.append(None)
                    continue
                seq.append(caps[e][r])
            horner = {}
            for k, colv in enumerate(seq):
                g = NW * pc - 1 - k
                c, v = divmod(g, NW)
                if sch.key == "T2":
                    f = bw // sch.S
                    s_grp = v % sch.S
                    qs = [p + f * s_grp for p in range(f)]
                    wv = wfield(Wm, bw, qs)
                else:
                    wv = Wm.astype(np.int64)
                j = bld.j_of(c, v)
                for h in range(NH):
                    i = r * bld.rows_pe + h // ba
                    pl = h % ba
                    sgn = -1 if pl == ba - 1 else 1
                    exp = sgn * int(Apl[i, pl] @ wv[:, j])
                    if colv is None or int(colv[h]) != exp:
                        n_tile_mm += 1
                if colv is None:
                    continue
                for grp in range(bld.rows_pe):            # combiner: sum_h 2^plane T(h) per activation row
                    i = r * bld.rows_pe + grp
                    s_v = sum(int(colv[grp * ba + pl]) << pl for pl in range(ba))
                    if sch.key == "T2":                   # Horner over the S columns, s = S-1 first
                        f = bw // sch.S
                        key = (i, j)
                        horner[key] = s_v if v % sch.S == sch.S - 1 else (horner.get(key, 0) << f) + s_v
                        if v % sch.S == 0:
                            got[i, j], seen[i, j] = horner[key], True
                    else:
                        got[i, j], seen[i, j] = s_v, True
        n_out += ref.size
        n_out_mm += int(np.sum((got != ref) | ~seen))
    return n_tile_mm, n_out_mm, n_out


def check_blocks_h(bld, metas, caps):
    """H / H3: drained tile ((i,g),(j,s)) vs sum_x Afield_g[i,x] Wfield_s[x,j] (independent numpy
    int64); combined out(i,j) = sum_g sum_s 2^(g*TA + s*TW) T from the DRAINED tiles vs A @ W."""
    pr, pc, ba, bw = bld.pr, bld.pc, bld.ba, bld.bw
    ta_n, tw_n, ga, gw = bld.sch.TA, bld.sch.TW, bld.ga, bld.gw
    n_tile_mm = n_out_mm = n_out = 0
    for mt in metas:
        Am, Wm = mt["A"].astype(np.int64), mt["W"].astype(np.int64)
        ref = Am @ Wm
        af = [wfield(Am.T, ba, list(range(g * ta_n, (g + 1) * ta_n))).T for g in range(ga)]
        wf = [wfield(Wm, bw, list(range(s * tw_n, (s + 1) * tw_n))) for s in range(gw)]
        T = {(g, s): af[g] @ wf[s] for g in range(ga) for s in range(gw)}
        acc = np.zeros_like(ref)
        cnt = np.zeros(ref.shape, np.int64)
        for r in range(pr):
            for k in range(NW * pc):
                c, v = divmod(NW * pc - 1 - k, NW)
                j, s = c * bld.cols_pe + v // gw, v % gw
                colv = caps.get(mt["d0"] + k, {}).get(r)
                for h in range(NH):
                    i, g = r * bld.rows_pe + h // ga, h % ga
                    if colv is None or int(colv[h]) != int(T[(g, s)][i, j]):
                        n_tile_mm += 1
                    if colv is not None:
                        acc[i, j] += int(colv[h]) << (g * ta_n + s * tw_n)
                        cnt[i, j] += 1
        n_out += ref.size
        n_out_mm += int(np.sum((acc != ref) | (cnt != ga * gw)))
    return n_tile_mm, n_out_mm, n_out


def gen_block(rng, prec, sch, L, pr, pc, kind):
    ba, bw, rows_pe, cols_pe, _ = mapping(sch, prec)
    rows, cols = pr * rows_pe, pc * cols_pe
    if kind == "minmax":
        return (np.full((rows, L), -(1 << (ba - 1)), np.int64), np.full((L, cols), -(1 << (bw - 1)), np.int64))
    if kind == "range":   # the largest |tile| the schedule can make: all-ones lower groups, or the lone MSB group at min
        ga = ba // sch.TA if sch.key in ("H", "H3") else ba
        gw = bw // sch.TW if sch.key in ("H", "H3") else 1
        av = -1 if ga > 1 else -(1 << (ba - 1))
        wv = -1 if gw > 1 else -(1 << (bw - 1))
        return np.full((rows, L), av, np.int64), np.full((L, cols), wv, np.int64)
    return (rng.integers(-(1 << (ba - 1)), 1 << (ba - 1), (rows, L)),
            rng.integers(-(1 << (bw - 1)), 1 << (bw - 1), (L, cols)))


def run_sim(sch, prec, L, pr, pc, kinds=("uniform", "minmax"), neg=None, seed=1):
    rng = np.random.default_rng(seed)
    bld = Builder(sch, prec, L, pr, pc, len(kinds))
    blocks = [gen_block(rng, prec, sch, L, pr, pc, k) for k in kinds]
    metas, E = bld.build(blocks, neg)
    caps, maxabs = simulate(bld.prog, pr, pc, E)
    tmm, omm, nout = (check_blocks_h if bld.hyb else check_blocks)(bld, metas, caps)
    return dict(metas=metas, tile_mm=tmm, out_mm=omm, n_out=nout, maxabs=maxabs,
                feasible=all(m["feasible"] for m in metas))


# =================================================================== validation
MEASURED = [   # (P_R, P_C, prec, lap, L, period): grid bench, RTL, csa_bp_20261004_lap (README / task)
    (4, 4, "INT8", "pe", 4096, 350), (4, 4, "INT8", "global", 4096, 392),
    (4, 8, "INT8", "pe", 4096, 386), (4, 8, "INT8", "global", 4096, 456),
    (4, 4, "W4A8", "pe", 4096, 190), (4, 4, "W4A8", "global", 4096, 208),
    (4, 4, "INT4", "pe", 4096, 190), (4, 4, "INT4", "global", 4096, 208),
    (4, 8, "W4A8", "pe", 4096, 226), (4, 8, "W4A8", "global", 4096, 256),
    (4, 8, "INT4", "pe", 4096, 226), (4, 8, "INT4", "global", 4096, 256),
]


def t1_period(lap, prec, L, pr, pc):
    return block_terms(Sch("T1") if lap == "pe" else T1G, prec, L, pr, pc)["period"]


def validate_measured():
    print("\n== 1. T1 closed form vs measured periods")
    print("   T1  (per-PE laps):  BW*NB + 8*(BW-1) + (P_R+P_C-2) + 8*P_C")
    print("   T1g (global laps):  BW*NB + (8+S)*(BW-1) + S + 8*P_C,  S = P_R+P_C-2")
    print("\n   a) the periods listed for this study (grid bench, L=4096):")
    for pr, pc, prec, lap, L, meas in MEASURED:
        mod = t1_period(lap, prec, L, pr, pc)
        ok = mod == meas
        print(f"     {pr}x{pc} {prec:4s} {lap:6s} L={L}: measured {meas:4d}  model {mod:4d}  {'ok' if ok else 'MISMATCH'}")
        if not ok:
            fail(f"listed period {pr}x{pc} {prec} {lap}: {meas} vs {mod}")

    print(f"\n   b) every period line of the grid bench summary ({GRID_SUMMARY}):")
    p = REPO / GRID_SUMMARY
    rx = re.compile(r"^(\S+): PASS\s+(\d+)x(\d+) (INT8|W4A8|INT4) L=(\d+) blocks=(\d+) ([a-z_]+)[^:]*:.*"
                    r"scheduled block period (\d+) = formula \((?:drain-start spacing \[([\d, ]+)\]|single block)\)")
    n = nsp = 0
    if not p.exists():
        fail(f"{GRID_SUMMARY} missing")
    else:
        for line in p.read_text().splitlines():
            mm = rx.match(line)
            if not mm:
                continue
            lab, pr, pc, prec, L, nb, mode, per, sp = mm.groups()
            lap = "pe" if mode == "per_pe_laps" else "global"     # global_lap_wait, oldc_unforced (P_C = 1)
            mod = t1_period(lap, prec, int(L), int(pr), int(pc))
            n += 1
            if mod != int(per):
                fail(f"{lab}: scheduled {per} vs model {mod}")
            if sp:
                for s in sp.split(","):
                    nsp += 1
                    if int(s) != mod:
                        fail(f"{lab}: measured drain-start spacing {s} vs model {mod}")
        print(f"     {n} scheduled periods and {nsp} measured drain-start spacings (multi-block runs) "
              f"compared: {'all equal the model' if not [f for f in FAILS if 'scheduled' in f or 'spacing' in f] else 'MISMATCHES'}")
        if n < 40:
            fail(f"grid summary: only {n} period lines parsed")

    print(f"\n   c) independent grid harness ({VG_DIR}/*/check.json, PASS, non-fault scenarios):")
    nv = 0
    for cj in sorted((REPO / VG_DIR).glob("*/check.json")):
        js = json.loads(cj.read_text())
        if js.get("status") != "PASS" or js["scenario"].startswith("f_"):
            continue
        pr, pc = map(int, js["grid"].split("x"))
        for prd in js.get("periods", []):
            bw = prd["BW"]
            prec = "INT8" if bw == 8 else "INT4"           # the period does not depend on BA
            L = prd["NB"] * SLOT
            mod = t1_period(prd["lap"], prec, L, pr, pc)
            nv += 1
            if mod != prd["base_to_base"]:
                fail(f"{cj.parent.name}: base-to-base {prd['base_to_base']} vs model {mod}")
    print(f"     {nv} base-to-base periods compared (1x1, 1x4, 1x8, 4x1, 8x1, 2x3, 4x4, 4x8)")
    if nv < 20:
        fail(f"verify_grid: only {nv} periods found")

    print(f"\n   d) single PE, routed INT runs ({INT_RESULTS}):")
    for r in csv.DictReader(open(REPO / INT_RESULTS)):
        prec, L, blk = r["precision"], int(r["L"]), int(r["blocks"])
        t = block_terms(Sch("T1"), prec, L, 1, 1)
        _, _, rows_pe, cols_pe, _ = mapping(Sch("T1"), prec)
        dat, ring, dr = int(r["data_cycles"]), int(r["ring_cycles"]), int(r["drain_cycles"])
        ok = (dat == blk * t["D"] and ring in (0, blk * t["lap"]) and dr in (0, blk * t["drain"])
              and int(r["macs_checked"]) == blk * rows_pe * cols_pe * L)
        mpc = int(r["macs_checked"]) / (dat + ring + dr)
        ok &= abs(mpc - float(r["mac_per_cycle"])) < 1e-9
        print(f"     {r['label']:24s} data {dat:5d} ring {ring:5d} drain {dr:4d} -> model/block "
              f"D={t['D']} lap={t['lap']} drain={t['drain']}, MAC/cycle {mpc:7.2f}  {'ok' if ok else 'MISMATCH'}")
        if not ok:
            fail(f"routed INT run {r['label']}")

    print("\n   e) README single-PE / grid numbers:")
    def mpc(prec, L, drain):
        t = block_terms(Sch("T1"), prec, L, 1, 1)
        _, _, rp, cp, _ = mapping(Sch("T1"), prec)
        return rp * cp * L / (t["D"] + t["lap"] + (t["drain"] if drain else 0))
    checks = [("INT8 L=1024 data+ring MAC/cycle/PE", mpc("INT8", 1024, False), 68.3, 0.05),
              ("INT8 L=1024 drain included", mpc("INT8", 1024, True), 64.0, 0.05),
              ("W4A8 L=1024 data+ring", mpc("W4A8", 1024, False), 146.3, 0.05),
              ("INT4 L=1024 data+ring", mpc("INT4", 1024, False), 292.6, 0.05),
              ("INT4 L=1024 drain included", mpc("INT4", 1024, True), 256.0, 0.05),
              ("INT8 4x4 L=4096 MAC/tile-cycle", schedule(Sch("T1"), "INT8", 4096, 4, 4)["mac_tc"], 1.46, 0.005),
              ("INT8 peak 1 PE GMAC/s/mm2", gmacs(128, 1, area(Sch("T1"), "INT8", "1PE")[0]), 1110.7, 0.05),
              ("INT8 peak 4x4 GMAC/s/mm2", gmacs(16 * 128, 1, area(Sch("T1"), "INT8", "4x4")[0]), 1541.8, 0.05),
              ("SC T=128 1 PE GMAC/s/mm2", gmacs(64, 1, area(Sch("T1"), "INT8", "1PE")[0]), 555.4, 0.05),
              ("SC T=128 4x4 GMAC/s/mm2", gmacs(16 * 64, 1, area(Sch("T1"), "INT8", "4x4")[0]), 770.9, 0.05),
              ("4x4 composite area um2 (comparison.txt)", area(Sch("T1"), "INT8", "4x4")[0], 531321.5, 0.1)]
    for prec, shape, doc in (("INT8", "4x4", 1128), ("INT8", "4x8", 1055)):
        s = schedule(Sch("T1"), prec, 4096, *SHAPES[shape])
        checks.append((f"{prec} {shape} L=4096 GMAC/s/mm2 (doc sec. 9)",
                       gmacs(s["macs"], s["period"], area(Sch("T1"), prec, shape)[0]), doc, 1.0))
    for lab, v, ref, tol in checks:
        ok = abs(v - ref) <= tol
        print(f"     {lab:44s} model {v:12,.2f}  README/doc {ref:12,.2f}  {'ok' if ok else 'MISMATCH'}")
        if not ok:
            fail(lab)

    print(f"\n   f) single-PE composed curve ({COMPOSED}, uniform):")
    nc = 0
    for r in csv.DictReader(open(REPO / COMPOSED)):
        if r["dist"] != "uniform":
            continue
        prec, L = r["precision"], int(r["L"])
        t = block_terms(Sch("T1"), prec, L, 1, 1)           # one block, as the composed curve assumes
        _, _, rp, cp, _ = mapping(Sch("T1"), prec)
        dr = rp * cp * L / (t["D"] + t["lap"])
        wd = rp * cp * L / t["period"]
        nc += 1
        if abs(dr - float(r["mac_per_cycle_data_ring"])) > 1e-6 or abs(wd - float(r["mac_per_cycle_with_drain"])) > 1e-6:
            fail(f"composed {prec} L={L}")
        if L > lmax(Sch("T1"), prec):
            s = schedule(Sch("T1"), prec, L, 1, 1)
            print(f"     note: {prec} L={L} exceeds the 24-bit block limit (L <= {lmax(Sch('T1'), prec):,}); the "
                  f"composed curve uses one block ({wd:.2f} MAC/cycle), this model splits it into {s['nsplit']} "
                  f"blocks ({s['macs'] / s['period']:.2f})")
    print(f"     {nc} points (data+ring and with-drain MAC/cycle) equal the T1 model")

    print("\n   g) section 10 SRAM table (peak x supply / 1,024 per edge half), 4x4, reproduced:")
    ar = area(Sch("T1"), "INT8", "4x4")[0]
    exp = {"INT8": ((0.14, 108), (1.12, 867)), "W4A8": ((0.28, 217), (2.25, 1734)), "INT4": ((0.56, 434), (4.5, 3469))}
    for prec in PREC:
        pk = peak_tc(prec)
        for (lab, s), (tc_doc, g_doc) in zip(READINGS, exp[prec]):
            tc = pk * min(1, s / DEMAND)
            g = gmacs(16 * 64 * tc, 1, ar)
            ok = abs(tc - tc_doc) < 0.006 and abs(g - g_doc) <= 1.0     # doc rounds to integers
            print(f"     BP {prec:4s} {lab:22s} {tc:5.3f} MAC/tile-cycle, {g:7,.1f} GMAC/s/mm2  "
                  f"(doc {tc_doc}, {g_doc:,})  {'ok' if ok else 'MISMATCH'}")
            if not ok:
                fail(f"section 10 {prec} {lab}")


def validate_ipd():
    """T3 periods and area against the In-place stage (T3 RTL), when its result exists."""
    p = REPO / IPD_JSON
    print(f"\n   h) In-place stage (T3 RTL csa_bp_ipd_20261004, {IPD_JSON}):")
    if not p.exists():
        print("     not present: T3 uses the area PLACEHOLDER and has no RTL-measured period to compare")
        return
    js = json.loads(p.read_text())
    nr = 0
    for r in js["rows"]:
        if "bit-plane" not in r["mode"]:
            continue
        prec = r["mode"].split()[0]
        pr, pc = map(int, r["grid"].split("x"))
        L = int(r["L"])
        for key, sch in (("period_lap", Sch("T1")), ("period_ipd", Sch("T3"))):
            mod = block_terms(sch, prec, L, pr, pc)["period"]
            nr += 1
            ok = mod == int(r[key])
            print(f"     {r['grid']} {prec:4s} L={L:5d} {sch.name}: RTL-measured {int(r[key]):4d}  model {mod:4d}  "
                  f"{'ok' if ok else 'MISMATCH'}")
            if not ok:
                fail(f"IPD stage {key} {r['grid']} {prec} L={L}: {r[key]} vs {mod}")
    if T3SRC["mode"] == "ipd":
        for shape, key in (("1PE", "1x1"), ("4x4", "4x4"), ("4x8", "4x8")):
            mine = area(Sch("T3"), "INT8", shape)[0]
            theirs = js["composites"]["IPD (estimate)"][key]
            ok = abs(mine - theirs) < 0.1
            print(f"     T3 composite {shape}: model {mine:12,.1f}  In-place stage {theirs:12,.1f}  {'ok' if ok else 'MISMATCH'}")
            if not ok:
                fail(f"T3 composite {shape}: {mine} vs {theirs}")
    print(f"     {nr} periods compared")


def validate_sim(quick):
    print("\n== 2. Value-level grid simulator (RTL tile semantics), every schedule built from first principles")
    print("   Semantics taken from the RTL (not assumed):")
    print("   - tile (inner_tile_signed_segmented_csa.sv): `else if (shift_in)` loads acc_in and clears the")
    print("     pending carry/borrow BEFORE the MAC branch, so a shift edge discards that edge's MAC;")
    print("   - PE (inner_pe_signed_segmented_csa_bp.sv): core shift = shift_in | ring_q drives all 64 tiles;")
    print("     west input of each row = ring_q ? acc_out_east << 1 : acc_in_west;")
    print("   - grid wrapper: shift_in is ONE global port; acc chains PE (r,c) -> (r,c+1); acc_in_west = 0 at the")
    print("     west edge on drains, so a 8*P_C-edge drain both reads every column at the east combiner and clears")
    print("     every tile; A / W / ring_q reach PE (r,c) r+c edges after PE (0,0).")
    print("   Consequence: no tile of a PE can MAC on a drain edge, the drain cannot start before the far PE's")
    print("   last MAC (skew P_R+P_C-2 after PE (0,0)), and PE (0,0) cannot start the next block before the")
    print("   drain's last edge.  On the existing tile a drain never overlaps MACs; skew + drain are serial,")
    print("   paid once per output block.  (T4's shift+MAC tile could in principle overlap the drain too, but")
    print("   only by re-steering each PE column's W bus to whichever output passes through it; not modelled.)")
    shapes = [(1, 1), (2, 3), (4, 4), (4, 8)] if not quick else [(1, 1), (2, 3)]
    Ls = (200, 1024, 1100) if not quick else (200, 1100)
    rows = []
    n_ok = 0
    for sch in SCHEDS + [T1G]:
        for prec in PREC:
            if not applies(sch, prec):
                continue
            for pr, pc in shapes:
                for L in Ls:
                    res = run_sim(sch, prec, L, pr, pc, seed=zlib.crc32(f"{sch.name}{prec}{pr}{pc}{L}".encode()))
                    t = block_terms(sch, prec, L, pr, pc)
                    per = [m["period"] for m in res["metas"]]
                    ok = (res["tile_mm"] == 0 and res["out_mm"] == 0 and res["feasible"]
                          and all(p == t["period"] for p in per) and res["maxabs"] <= TILE_MAX)
                    n_ok += ok
                    rows.append((sch.name, prec, f"{pr}x{pc}", L, per[0], t["period"], res["n_out"], ok))
                    if not ok:
                        fail(f"sim {sch.name} {prec} {pr}x{pc} L={L}: periods {per} vs {t['period']}, "
                             f"tile_mm {res['tile_mm']}, out_mm {res['out_mm']}, feasible {res['feasible']}")
    print(f"\n   {len(rows)} runs (2 back-to-back blocks each: uniform random, then all-minimum operands), "
          f"{n_ok} bit-exact with sim period = closed form:")
    print(f"   {'schedule':8s} {'prec':5s} " + " ".join(f"{f'{pr}x{pc}':>18s}" for pr, pc in shapes))
    for sch in SCHEDS + [T1G]:
        for prec in PREC:
            if not applies(sch, prec):
                continue
            cells = []
            for pr, pc in shapes:
                rs = [r for r in rows if r[0] == sch.name and r[1] == prec and r[2] == f"{pr}x{pc}"]
                cells.append("/".join(str(r[4]) for r in rs) + (" ok" if all(r[7] for r in rs) else " BAD"))
            print(f"   {sch.name:8s} {prec:5s} " + " ".join(f"{c:>18s}" for c in cells))
    print(f"   (cells: simulated block period at L = {'/'.join(map(str, Ls))})")

    print("\n   T1 / T1g simulator vs measured RTL periods (L=4096, 1 block, bit-exact):")
    for pr, pc, prec, lap, L, meas in MEASURED:
        if quick and (pr, pc) == (4, 8):
            continue
        sch = Sch("T1") if lap == "pe" else T1G
        res = run_sim(sch, prec, L, pr, pc, kinds=("uniform",), seed=7)
        p = res["metas"][0]["period"]
        ok = p == meas and res["tile_mm"] == 0 and res["out_mm"] == 0
        print(f"     {pr}x{pc} {prec:4s} {lap:6s}: sim {p:4d} measured {meas:4d}, "
              f"{res['n_out']} outputs bit-exact={res['out_mm'] == 0}  {'ok' if ok else 'MISMATCH'}")
        if not ok:
            fail(f"sim vs measured {pr}x{pc} {prec} {lap}")

    print("\n   Tightness: each closed-form term shortened by one edge must break the result")
    print("   (next_early: next block one edge early; drain_early: drain one edge early; gap_short: the first")
    print("   lap / doubling / rotation window one edge earlier):")
    nshapes = [(2, 3), (4, 8)] if not quick else [(2, 3)]
    nn = nfail = 0
    for sch in SCHEDS + [T1G]:
        for prec in ("INT8", "INT4"):
            if not applies(sch, prec):
                continue
            for pr, pc in nshapes:
                for L in (200, 1100):
                    for neg in ("next_early", "drain_early", "gap_short"):
                        if neg == "gap_short" and mapping(sch, prec)[4] == 1:
                            continue
                        res = run_sim(sch, prec, L, pr, pc, kinds=("uniform", "uniform"), neg=neg, seed=11)
                        caught = res["tile_mm"] > 0 or res["out_mm"] > 0
                        nn += 1
                        if not caught:
                            nfail += 1
                            fail(f"negative {neg} not caught: {sch.name} {prec} {pr}x{pc} L={L}")
    print(f"   {nn} negative runs, {nn - nfail} broke the result as required")


def hyb_rtl_runs():
    """Nominal RTL hybrid runs (grid bench check.json, single-PE top check.json), deduplicated by path."""
    runs = []
    for g in HYB_RTL_GLOBS:
        for p in sorted(REPO.glob(g)):
            js = json.loads(p.read_text())
            js["_path"] = str(p.relative_to(REPO))
            runs.append(js)
    return runs


def validate_hybrid(quick):
    print("\n== 2b. BP-hybrid H(TA,TW) / H3: closed form, RTL, simulator (review finding 1)")
    print("   H   period = TA*TW*NB + 8*(TA+TW-2) + (P_R+P_C-2) + 8*P_C, outputs/PE = (8*TA/BA)*(8*TW/BW)")
    print("   H3  period = TA*TW*NB + 1*(TA+TW-2) + (P_R+P_C-2) + 8*P_C   (T3 1-edge laps)")
    print("   Corners: H(1,BW) = T1, H(1,1) = T2 S=BW, H(BA,BW) = round-1 'HB'.")
    nc = 0
    for prec in PREC:
        ba, bw = PREC[prec]
        for L in LS:
            for pr, pc in SHAPES.values():
                for a, b in ((H(1, bw), Sch("T1")), (H(1, 1), Sch("T2", bw)), (H(1, bw, "H3"), Sch("T3"))):
                    nc += 1
                    if schedule(a, prec, L, pr, pc)["period"] != schedule(b, prec, L, pr, pc)["period"]:
                        fail(f"corner {a.name} != {b.name} {prec} L={L} {pr}x{pc}")
    print(f"   corner identities checked at {nc} points (periods incl. 24-bit splits): "
          f"{'all equal' if not [f for f in FAILS if f.startswith('corner')] else 'MISMATCH'}")

    print("\n   a) every nominal RTL hybrid run (unchanged csa_bp_20261004_lap RTL), measured vs closed form:")
    runs = hyb_rtl_runs()
    n_ok = n_tot = 0
    seen = {}
    for js in runs:
        if js.get("mode") != "nominal":
            continue
        n_tot += 1
        prec = js["precision"]
        pr, pc = map(int, js["grid"].split("x"))
        sch = H(js["TA"], js["TW"])
        t = block_terms(sch, prec, js["L"], pr, pc)
        _, _, rp, cp, _ = mapping(sch, prec)
        meas = js.get("measured_periods", [])
        ok = (js["status"] == "PASS" and js["block_len"] == t["period"] and all(x == t["period"] for x in meas)
              and js["outputs_per_pe"] == rp * cp and js["L"] <= lmax(sch, prec))
        n_ok += ok
        if not ok:
            fail(f"RTL hybrid run {js['_path']}: block_len {js['block_len']} measured {meas} vs model {t['period']}")
        key = (js["grid"] + (" top" if js.get("top") else ""), prec, sch.name, js["L"])
        seen.setdefault(key, set()).add(js["block_len"])
    src = sorted({str(Path(js["_path"]).parts[2]) for js in runs})
    print(f"     {n_tot} nominal runs in {', '.join(src)}: {n_ok} PASS with block period = closed form "
          f"(and every multi-block drain-start spacing)")
    for key in sorted(seen):
        print(f"       {key[0]:7s} {key[1]:4s} {key[2]:7s} L={key[3]:5d}: {'/'.join(map(str, sorted(seen[key])))}")
    if n_tot < 20:
        fail(f"only {n_tot} nominal RTL hybrid runs found")

    print("\n   b) simulator, bit-exact vs numpy (2 back-to-back blocks: uniform, then all-minimum operands):")
    shapes = [(1, 1), (2, 3), (4, 4), (4, 8)] if not quick else [(1, 1), (2, 3)]
    pts = {"INT8": [(2, 8), (4, 4), (4, 8), (8, 4), (8, 8), (2, 2)], "W4A8": [(4, 4), (8, 4), (8, 2), (4, 2)],
           "INT4": [(2, 4), (4, 4), (4, 2)]}
    nrun = nok = 0
    lines = []
    for key in ("H", "H3"):
        for prec, lst in pts.items():
            for ta, tw in lst:
                sch = H(ta, tw, key)
                lm = lmax(sch, prec)
                Ls = [x for x in ((200, 1024, 1100) if not quick else (200, 1100)) if x <= lm] or [200, 384, lm]
                cells = []
                for pr, pc in shapes:
                    pers = []
                    for L in Ls:
                        res = run_sim(sch, prec, L, pr, pc, seed=zlib.crc32(f"{sch.name}{prec}{pr}{pc}{L}".encode()))
                        t = block_terms(sch, prec, L, pr, pc)
                        per = [mt["period"] for mt in res["metas"]]
                        ok = (res["tile_mm"] == 0 and res["out_mm"] == 0 and all(p == t["period"] for p in per)
                              and res["maxabs"] <= TILE_MAX)
                        nrun += 1
                        nok += ok
                        pers.append(str(per[0]))
                        if not ok:
                            fail(f"sim {sch.name} {prec} {pr}x{pc} L={L}: {per} vs {t['period']}, "
                                 f"tile_mm {res['tile_mm']}, out_mm {res['out_mm']}")
                    cells.append("/".join(pers))
                lines.append(f"     {sch.name:8s} {prec:4s} L={'/'.join(map(str, Ls)):14s} "
                             + " ".join(f"{c:>16s}" for c in cells))
    print(f"     {nrun} runs, {nok} bit-exact with simulated period = closed form;  cells: period per shape "
          + " ".join(f"{pr}x{pc}" for pr, pc in shapes))
    for ln in lines:
        print(ln)

    print("\n   c) simulator vs RTL-measured hybrid periods (same shape / precision / (TA,TW) / L, 1 block, bit-exact):")
    done = set()
    for js in runs:
        if js.get("mode") != "nominal" or js["status"] != "PASS":
            continue
        pr, pc = map(int, js["grid"].split("x"))
        k = (pr, pc, js["precision"], js["TA"], js["TW"], js["L"])
        if k in done or (quick and pr * pc > 6):
            continue
        done.add(k)
        res = run_sim(H(js["TA"], js["TW"]), js["precision"], js["L"], pr, pc, kinds=("uniform",), seed=5)
        p = res["metas"][0]["period"]
        ok = p == js["block_len"] and res["tile_mm"] == 0 and res["out_mm"] == 0
        if not ok:
            fail(f"sim vs RTL hybrid {k}: sim {p} RTL {js['block_len']}")
    print(f"     {len(done)} distinct RTL points: "
          f"{'all equal, bit-exact' if not [f for f in FAILS if f.startswith('sim vs RTL hybrid')] else 'MISMATCH'}")

    print("\n   d) 24-bit range: at L = lmax with the worst-case operands the tile must fit and stay exact; at")
    print("      lmax+1 it must overflow (1x1, 1 block):")
    for prec, (ta, tw) in (("INT8", (4, 8)), ("INT8", (4, 4)), ("INT8", (8, 8)), ("INT8", (2, 8)),
                           ("W4A8", (8, 4)), ("INT4", (4, 4))):
        sch = H(ta, tw)
        lm = lmax(sch, prec)
        r0 = run_sim(sch, prec, lm, 1, 1, kinds=("range",), seed=1)
        r1 = run_sim(sch, prec, lm + 1, 1, 1, kinds=("range",), seed=1)
        ok = r0["tile_mm"] == 0 and r0["out_mm"] == 0 and r0["maxabs"] <= TILE_MAX and r1["maxabs"] > TILE_MAX
        print(f"     {prec} {sch.name}: lmax {lm:6,d}  max|tile| {r0['maxabs']:9,d} (exact {r0['out_mm'] == 0})  "
              f"at lmax+1 {r1['maxabs']:9,d} > {TILE_MAX:,}  {'ok' if ok else 'MISMATCH'}")
        if not ok:
            fail(f"range {prec} {sch.name}")

    print("\n   e) tightness: next block / drain / first lap one edge early must break the result:")
    nn = nc = 0
    for key in ("H", "H3"):
        for prec, (ta, tw) in (("INT8", (4, 8)), ("INT8", (2, 8)), ("W4A8", (8, 4)), ("INT4", (4, 4))):
            for pr, pc in ([(2, 3), (4, 8)] if not quick else [(2, 3)]):
                for L in (200, 1100):
                    for neg in ("next_early", "drain_early", "gap_short"):
                        res = run_sim(H(ta, tw, key), prec, L, pr, pc, kinds=("uniform", "uniform"), neg=neg, seed=11)
                        nn += 1
                        if res["tile_mm"] > 0 or res["out_mm"] > 0:
                            nc += 1
                        else:
                            fail(f"negative {neg} not caught: {key}({ta},{tw}) {prec} {pr}x{pc} L={L}")
    print(f"     {nn} negative runs, {nc} broke the result as required")


# ======================================================================= tables
def main_table(csv_rows):
    print("\n== 3. How skew, laps and drain enter each schedule's block period (edges, PE (0,0) view)")
    print("   NB = ceil(L/128), P = passes, S_k = P_R+P_C-2, drain = 8*P_C.  One output block:")
    print("   T1   P*NB + 8*(P-1)                       + S_k + 8*P_C     P = BW")
    print("   T1g  P*NB + (8+S_k)*(P-1)                 + S_k + 8*P_C     (every lap waits for the far PE)")
    print("   T2   P*NB + 8*(P-1)                       + S_k + 8*P_C     P = BW/S, 8/S output columns per PE")
    print("   T3   P*NB + 1*(P-1)                       + S_k + 8*P_C     P = BW")
    print("   T4   2*NB + (P-2)*max(NB,8) + (8-1)       + S_k + 8*P_C     P = BW >= 2 (= P*NB + 7 for NB >= 8)")
    print("   H    TA*TW*NB + 8*(TA+TW-2)               + S_k + 8*P_C     (8*TA/BA) x (8*TW/BW) outputs per PE")
    print("   H3   TA*TW*NB + 1*(TA+TW-2)               + S_k + 8*P_C     (H with T3's 1-edge laps)")
    print("   A lap (T1/T2) is 8 edges on every grid: the ring is PE-local (own row's east value <<1 into the")
    print("   west tile), riding the A wave, so PE (r,c) laps at offset r+c with no wait.  The drain crosses the")
    print("   whole PE row (8*P_C edges) on the global shift_in, after the skew wait.  Blocks whose 24-bit range")
    print("   is exceeded are split into equal sub-blocks, each paying laps + skew + drain (INT8 T1/T3/T4: L <= 65,535;")
    print("   T2 S=8: L <= 8,388,607).")

    print("\n== 4. Main table: edges per output block | outputs per PE per block | MAC/tile-cycle | % of peak | GMAC/s/mm2")
    print("   Areas: routed csa_bp_20261004_lap (1 PE 46,096.5 um2; composites as compare_grid_configs.py);")
    if T3SRC["mode"] == "ipd":
        print(f"   T3: routed lap blocks + SYNTHESIZED in-place-doubling delta (u_pe {T3SRC['d_pe']:+.1f} um2/PE, "
              f"u_peripheral {T3SRC['d_periph']:+.1f}; an estimate, not routed; the unsynthesized placeholder was "
              f"{PH['T3_pe']:.1f} um2/PE).")
    print(f"   PLACEHOLDERS (unsynthesized): "
          + ("" if T3SRC["mode"] == "ipd" else f"T3 +{PH['T3_pe']:.1f} um2/PE (7 x routed ring wrapper {A['ring']:.1f};"
             f" AO22 cell count {PH['T3_pe_cellcount']:.1f}); ")
          + f"T2 Horner +{PH['horner_row']:.1f} um2/PE row, ring -{A['ring']:.1f} um2/PE when S = BW;")
    print(f"   T4 +{PH['T4_tile']:.2f} um2/tile (64/PE) + {PH['T4_rot']:.0f} um2 W rotator per PE-column edge.")
    for shape in SHAPES:
        pr, pc = SHAPES[shape]
        print(f"\n   --- {shape} ---")
        print(f"   {'prec':4s} {'schedule':8s} {'area um2':>10s} | " + " | ".join(f"{f'L={L}':^34s}" for L in LS))
        for prec in PREC:
            for sch in [T1G] + SCHEDS:
                if not applies(sch, prec) or (sch is T1G and shape == "1PE"):
                    continue
                ar, note = area(sch, prec, shape)
                cells = []
                for L in LS:
                    s = schedule(sch, prec, L, pr, pc)
                    g = gmacs(s["macs"], s["period"], ar)
                    sp = f"x{s['nsplit']}" if s["nsplit"] > 1 else "  "
                    cells.append(f"{s['period']:6d}{sp} {s['outs']:2d} {s['mac_tc']:5.3f} {100 * s['pct']:5.1f}% {g:7,.0f}")
                    csv_rows.append(dict(shape=shape, prec=prec, schedule=sch.name, L=L, period=s["period"],
                                         nsplit=s["nsplit"], data_edges=s["D_tot"], lap_edges=s["nsplit"] * s["lap"],
                                         skew=s["nsplit"] * s["skew"], drain=s["nsplit"] * s["drain"],
                                         outs_pe=s["outs"], mac_tile_cycle=round(s["mac_tc"], 5),
                                         pct_peak=round(100 * s["pct"], 2), area_um2=round(ar, 1),
                                         gmacs_mm2=round(g, 2), area_basis=note))
                print(f"   {prec:4s} {sch.name:8s} {ar:10,.0f} | " + " | ".join(cells))
            # review fix: the hybrid family (unchanged PE), then the best (TA,TW) per L for H and H3
            for row in [H(*x) for x in HYB_SHOW[prec]] + ["H best", "H3 best"]:
                cells, picks = [], []
                for L in LS:
                    sch = best_h(prec, L, shape, row.split()[0]) if isinstance(row, str) else row
                    ar, note = area(sch, prec, shape)
                    s = schedule(sch, prec, L, pr, pc)
                    g = gmacs(s["macs"], s["period"], ar)
                    sp = f"x{s['nsplit']}" if s["nsplit"] > 1 else "  "
                    cells.append(f"{s['period']:6d}{sp} {s['outs']:2d} {s['mac_tc']:5.3f} {100 * s['pct']:5.1f}% {g:7,.0f}")
                    picks.append(f"({sch.TA},{sch.TW})")
                    csv_rows.append(dict(shape=shape, prec=prec, schedule=row if isinstance(row, str) else sch.name,
                                         L=L, period=s["period"], nsplit=s["nsplit"], data_edges=s["D_tot"],
                                         lap_edges=s["nsplit"] * s["lap"], skew=s["nsplit"] * s["skew"],
                                         drain=s["nsplit"] * s["drain"], outs_pe=s["outs"],
                                         mac_tile_cycle=round(s["mac_tc"], 5), pct_peak=round(100 * s["pct"], 2),
                                         area_um2=round(ar, 1), gmacs_mm2=round(g, 2), area_basis=note,
                                         choice=f"({sch.TA},{sch.TW})"))
                lab = row if isinstance(row, str) else row.name
                arw = "" if isinstance(row, str) else f"{area(row, prec, shape)[0]:10,.0f}"
                print(f"   {prec:4s} {lab:8s} {arw:>10s} | " + " | ".join(cells))
                if isinstance(row, str):
                    print(f"   {'':4s} {'':8s} {'(TA,TW)':>10s} | " + " | ".join(f"{p:^34s}" for p in picks))
    print("   (xN: split into N blocks by the 24-bit range.  H rows: unchanged PE + H combiner PLACEHOLDER "
          f"{PH['hyb_comb_row']:.1f} um2/PE row\n    (+ column Horner {PH['horner_row']:.1f} when TW < BW); "
          "H3 adds the T3 lap hardware.  'best' = the (TA,TW) with the highest GMAC/s/mm2 at that L.)")


def bandwidth_table():
    print("\n== 5. Operand bandwidth, sends and weight layout (identical for every L; per data edge)")
    print("   Every schedule streams 1,024 b per data edge on each edge half (A: 8 tile rows x 128 positions of")
    print("   one PE row; W: 8 tile columns x 128 of one PE column), and 0 on lap / skew / drain edges.")
    hdr = (f"   {'prec':4s} {'schedule':8s} {'A b/edge':>8s} {'W b/edge':>8s} {'b/MAC PE':>8s} {'b/MAC 4x4':>9s} "
           f"{'b/MAC 4x8':>9s} {'A sends/blk':>11s} {'W sends/blk':>11s} {'A sends/GEMM':>13s} {'W sends/GEMM':>13s}  "
           f"avg b/cyc per edge half, 4x4 L=1024 / 4096")
    print(hdr)
    for prec in PREC:
        ba, bw = PREC[prec]
        for sch in SCHEDS + [H(*HYB_HEAD[prec])]:
            if not applies(sch, prec):
                continue
            _, _, rows_pe, cols_pe, P = mapping(sch, prec)
            mac_edge_pe = 64 * peak_tc(prec)
            bpe = 2 * DEMAND / mac_edge_pe
            b44 = (4 + 4) * DEMAND / (16 * mac_edge_pe)
            b48 = (4 + 8) * DEMAND / (32 * mac_edge_pe)
            a_blk = DEMAND * P / (rows_pe * ba * SLOT)       # sends of each A bit per block
            w_blk = DEMAND * P / (cols_pe * bw * SLOT)       # sends of each W bit per block
            a_gemm = f"{a_blk / cols_pe:.2f} N/P_C"          # = P / cols_pe for T1..T4 (a_blk = P there)
            w_gemm = f"{w_blk / rows_pe:.2f} M/P_R"          # = 1 / rows_pe for T1..T4 (w_blk = 1 there)
            avg = []
            for L in (1024, 4096):
                s = schedule(sch, prec, L, 4, 4)
                avg.append(f"{DEMAND * s['D_tot'] / s['period']:.0f}")
            print(f"   {prec:4s} {sch.name:8s} {DEMAND:8d} {DEMAND:8d} {bpe:8.1f} {b44:9.2f} {b48:9.2f} "
                  f"{a_blk:11.0f} {w_blk:11.0f} {a_gemm:>13s} {w_gemm:>13s}  {' / '.join(avg)}")
    print("   b/MAC at the grid edge = (P_R + P_C) x 1,024 / (P_R P_C x 64 x peak MAC/tile-edge); the same for all")
    print("   schedules.  Per GEMM (M x L x N) the A sends simplify to BW*N/(8*P_C) and the W sends to")
    print("   BA*M/(8*P_R) for every schedule: T2 sends A once per block but has 8/S x more blocks along N;")
    print("   H sends each A bit TW times and each W bit TA times per block, over TA x more outputs per block.")
    print("   An L*BA-bit A replay buffer at each PE-row edge serves T1/T3/T4's BW re-sends (and T2's re-sends")
    print("   across consecutive blocks of one activation row) from one SRAM read.  W has no re-sends WITHIN a")
    print("   T1 block, but every M-block re-sends the same W block: a W block buffer (8 columns x BW x L bits per")
    print("   PE-column edge) with M as the inner loop serves those from one SRAM read per M sweep (section 6b;")
    print("   corrected from 'nothing comparable helps W', review finding 2).")
    print("\n   Per-block working set at each edge and its re-sends (what the edge buffers of section 6b hold):")
    print(f"   {'prec':4s} {'schedule':8s} {'A bits/PE row':>14s} {'A re-sends':>10s} {'W bits/PE col':>14s} "
          f"{'W re-sends':>10s}  (per output block, L in elements; KB at L=4096)")
    for prec in PREC:
        ba, bw = PREC[prec]
        for sch in [Sch("T1"), Sch("T2", bw), H(*HYB_HEAD[prec])]:
            _, _, rows_pe, cols_pe, P = mapping(sch, prec)
            a_blk = DEMAND * P / (rows_pe * ba * SLOT)
            w_blk = DEMAND * P / (cols_pe * bw * SLOT)
            print(f"   {prec:4s} {sch.name:8s} {f'{rows_pe * ba} L':>14s} {a_blk:10.0f} {f'{cols_pe * bw} L':>14s} "
                  f"{w_blk:10.0f}  ({rows_pe * ba * 4096 / 8192:.0f} KB / {cols_pe * bw * 4096 / 8192:.0f} KB)")
    print("   Spatial Booth (CNSB, doc 2.3), same terms: A 2 rows x 8 b (INT8/W4A8) or 4 x 4 b (INT4) = 16 L per PE")
    print("   row, W 4 x 8 b / 8 x 4 b / 8 x 4 b = 32 L per PE column, no re-sends within a block (each element once).")
    print("\n   Storage layout each schedule needs (A is byte-major everywhere: bit h of 128 activation bytes -> tile")
    print("   row h is pure wiring):")
    print("   T1, T3   W bit-plane-major: per edge, bit q of 128 weights x 8 output columns (one plane, 1,024 b).")
    print("            With W stored byte-major the feeder needs an offline transpose, or a transpose buffer of")
    print("            8 columns x L x BW bits per PE-column edge (32 KB at INT8 L=4096), or reads BW x the bits.")
    print("   T4       as T1, plus per-column plane addressing (the 8 values sit in different passes during the")
    print("            stagger) and a per-edge rotation of the 8 column buses during every window.")
    print("   T2 S=BW  W byte-major per output column: 128 consecutive reduction elements of W[:, j] (W^T rows,")
    print("            the natural K-contiguous layout), no transposition.  INT8 S=8: 128 bytes of one column;")
    print("            4-bit S=4: 128 nibbles x 2 columns.")
    print("   T2 S<BW  W 'bit-sliced' into BW/S slices of S bits (slice p = bits p, p+BW/S, ...): INT8 S=4 = odd /")
    print("            even bits, S=2 = bit pairs {p, p+4}; each edge reads one slice of 128 weights x 8/S columns.")
    print("   H(TA,TW) BOTH operands time-multiplexed: A 'bit-sliced' (INT8 H(4,8): bits {ta, 4+ta} of 128")
    print("            activations x 4 rows per edge), W as T1 when TW = BW.  So A must be stored bit-plane-major")
    print("            too (activations are written at run time by the previous layer: a transposing write path),")
    print("            or the A feeder selects the plane from byte words (TA:1 mux per line, section 4b).")


def sram_table(csv_rows):
    print("\n== 6. Throughput under the two SRAM readings of doc section 10 (per edge half, both sides)")
    print("   Section 10 method (no script exists; the numbers are peak x min(1, supply/1,024)): schedule-blind.")
    print("   Block level, two bounds: 'stall' = no prefetch, each data edge waits for its 1,024 b:")
    print("       period = D * max(1, 1024/s) + (non-data edges);")
    print("   'prefetch' = the feeder streams through laps / skew / drain into a buffer (fluid bound):")
    print("       period = max(period, D * 1024/s); buffer = the smallest one that reaches it, computed over the")
    print("       schedule's per-edge pattern: s x longest non-data stretch when memory-bound, else the largest")
    print("       deficit (1,024 x data edges - s x edges) of any window.  Bits per edge half, shown in kb.")
    for shape in ("1PE", "4x4", "4x8"):
        pr, pc = SHAPES[shape]
        for L in (1024, 4096):
            print(f"\n   --- {shape}, L={L} ---   cells: % of peak / GMAC/s/mm2")
            print(f"   {'prec':4s} {'schedule':8s} " + "  ".join(
                f"{lab + ': sec10 | stall | prefetch [buffer kb]':^62s}" for lab, _ in READINGS))
            for prec in PREC:
                pk = peak_tc(prec)
                hb = best_h(prec, L, shape)
                for sch in SCHEDS + [H(*HYB_HEAD[prec])] + ([hb] if hb != H(*HYB_HEAD[prec]) else []):
                    if not applies(sch, prec):
                        continue
                    ar, _ = area(sch, prec, shape)
                    s = schedule(sch, prec, L, pr, pc)
                    n = pr * pc
                    cells = []
                    for lab, sup in READINGS:
                        f10 = min(1.0, sup / DEMAND)
                        g10 = gmacs(n * 64 * pk * f10, 1, ar)
                        P, D = s["period"], s["D_tot"]
                        need = D * DEMAND / sup
                        st = D * max(1.0, DEMAND / sup) + (P - D)
                        pf = max(P, need)
                        buf = prefetch_buffer(data_pattern(sch, prec, L, pr, pc), sup)
                        cells.append(f"{100 * f10:4.1f}%/{g10:5,.0f} | {100 * D / st:4.1f}%/{gmacs(s['macs'], st, ar):5,.0f}"
                                     f" | {100 * D / pf:4.1f}%/{gmacs(s['macs'], pf, ar):5,.0f} [{buf / 1000:5.1f}]")
                        csv_rows.append(dict(shape=shape, prec=prec, schedule=sch.name, L=L, sram=lab,
                                             sec10_pct=round(100 * f10, 2), stall_pct=round(100 * D / st, 2),
                                             prefetch_pct=round(100 * D / pf, 2),
                                             stall_gmacs=round(gmacs(s["macs"], st, ar), 2),
                                             prefetch_gmacs=round(gmacs(s["macs"], pf, ar), 2),
                                             prefetch_buffer_kb=round(buf / 1000, 2)))
                    print(f"   {prec:4s} {sch.name:8s} " + "  ".join(f"{c:^62s}" for c in cells))
    print("   % of peak is the tile MAC rate over its peak (2 / 4 / 8 MAC/tile-cycle).  Under (i) every schedule")
    print("   is memory-bound by 14x: rescheduling the laps cannot move it.  Under (ii) prefetch hides the laps")
    print("   of T1, T3 and H alike (all reach 56.25%); T2 S=8 stays overhead-bound on grids; without prefetch")
    print("   H loses the least.  ASSUMPTION of this table (and of doc section 10): NO operand reuse at the array")
    print("   edge - every one of the 1,024 bits per data edge comes from the SRAM.  Section 6b relaxes it.")


CNSB = {"INT8": (2, 4, 8, 8, 1), "W4A8": (2, 8, 8, 4, 2), "INT4": (4, 8, 4, 4, 4)}   # rows, cols, BA, BW, peak


def cnsb_block(prec, L, pr, pc):
    """Spatial Booth (CNSB, doc 2.3) on the same grid: one reduction element per lane per data cycle
    (8 per tile), no laps; per data cycle A 128 b per PE row, W 256 b per PE column (doc section 10)."""
    rows_pe, cols_pe, ba, bw, pk = CNSB[prec]
    D = cdiv(L, K_LANES)
    P = D + pr + pc - 2 + NW * pc
    return dict(D=D, period=P, outs=rows_pe * cols_pe, macs=pr * pc * rows_pe * cols_pe * L, peak=pk,
                a_blk=rows_pe * L * ba, w_blk=cols_pe * L * bw, dA=rows_pe * K_LANES * ba, dW=cols_pe * K_LANES * bw,
                rows_pe=rows_pe, cols_pe=cols_pe, n_out=pr * pc * rows_pe * cols_pe)


K_LANES = 8


def buffered(P, D, a_blk, w_blk, rows_pe, cols_pe, pr, pc, sup):
    """Edge-buffered SRAM bound for one block.  Each edge half has its own sup b/cycle.  M-inner: the W block
    (w_blk bits per PE column) stays in a W buffer for the whole M sweep (refill stall amortised over the
    sweep's blocks); A comes through a double-buffered replay buffer refilled once per block (a_blk bits per
    PE row).  N-inner: the mirror image.  Returns (period, order, buffer bits on the grid)."""
    nM = GEMM_M / (pr * rows_pe)
    nN = GEMM_N / (pc * cols_pe)
    cand = [(max(P, a_blk / sup) + w_blk / (sup * nM), "M-inner", pr * 2 * a_blk + pc * w_blk),
            (max(P, w_blk / sup) + a_blk / (sup * nN), "N-inner", pc * 2 * w_blk + pr * a_blk)]
    best = min(c[0] for c in cand)
    return min((c for c in cand if c[0] <= 1.005 * best), key=lambda c: c[2])   # near-tie: smaller buffers


def sram_buffered(csv_rows):
    print("\n== 6b. Edge-reuse buffers: the SRAM readings with an A replay buffer and a W block buffer (review finding 2)")
    print(f"   Section 6 / doc section 10 assume no reuse at the array edge.  Here each PE-row edge has a double-")
    print(f"   buffered A replay buffer (one block's A: rows/PE x L x BA bits) and each PE-column edge a W block buffer")
    print(f"   (cols/PE x L x BW bits) that stays for the whole M sweep (M = {GEMM_M}, N = {GEMM_N}; or the mirror")
    print(f"   order, whichever is faster).  The SRAM then supplies each operand bit once per block (A) or once per")
    print(f"   sweep (W); the buffers must deliver the full 1,024 b per data edge per edge half (CNSB 128 / 256 b),")
    print(f"   i.e. they are wide local SRAMs.  Period = max(compute period, a_blk / s) + w_blk / (s x blocks per sweep).")
    print("   Spatial Booth (CNSB) is put on the same terms and on the same area basis as doc section 10 (the")
    print("   BP-lap composite; its own edge blocks not added).  Cells: % of peak / GMAC/s/mm2 [order, buffer KB on")
    print("   the grid].")
    # section 10's CNSB rows reproduced (peak x min(1, s / 256))
    ar44 = area(Sch("T1"), "INT8", "4x4")[0]
    for prec, doc in (("INT8", ((0.28, 217), (1.0, 771))), ("INT4", ((1.12, 867), (4.0, 3083)))):
        for (lab, s), (tc_doc, g_doc) in zip(READINGS, doc):
            tc = CNSB[prec][4] * min(1.0, s / 256)
            g = gmacs(16 * 64 * tc, 1, ar44)
            if abs(tc - tc_doc) > 0.006 or abs(g - g_doc) > 1.0:
                fail(f"section 10 CNSB {prec} {lab}: {tc:.3f}/{g:.1f} vs {tc_doc}/{g_doc}")
    print("   (section 10's spatial Booth rows reproduced: INT8 0.28/217 and 1.0/771, INT4 1.12/867 and 4.0/3,083)")
    for shape in ("4x4", "4x8"):
        pr, pc = SHAPES[shape]
        for L in (1024, 4096):
            print(f"\n   --- {shape}, L={L} ---")
            print(f"   {'prec':4s} {'schedule':8s} {'compute':>8s} | " + " | ".join(
                f"{lab + ': no buffer -> buffered':^58s}" for lab, _ in READINGS))
            for prec in PREC:
                ba, bw = PREC[prec]
                hb = best_h(prec, L, shape)
                rows = [Sch("T1"), Sch("T2", bw), Sch("T3"), H(*HYB_HEAD[prec])] + \
                       ([hb] if hb != H(*HYB_HEAD[prec]) else []) + [H(*HYB_HEAD[prec], "H3"), "CNSB"]
                for sch in rows:
                    if sch == "CNSB":
                        c = cnsb_block(prec, L, pr, pc)
                        ar = area(Sch("T1"), prec, shape)[0]
                        P, D, a_blk, w_blk, rp, cp, pk = c["period"], c["D"], c["a_blk"], c["w_blk"], \
                            c["rows_pe"], c["cols_pe"], c["peak"]
                        dmax, macs, name = max(c["dA"], c["dW"]), c["macs"], "CNSB"
                        pct_c = D / P
                    else:
                        s = schedule(sch, prec, L, pr, pc)
                        ar = area(sch, prec, shape)[0]
                        _, _, rp, cp, _ = mapping(sch, prec)
                        P, D, macs, name = s["period"], s["D_tot"], s["macs"], sch.name
                        a_blk, w_blk = rp * L * ba, cp * L * bw
                        dmax, pk, pct_c = DEMAND, peak_tc(prec), s["pct"]
                    cells = []
                    for lab, sup in READINGS:
                        p0 = max(P, D * dmax / sup)                         # no buffer, ideal prefetch (section 6)
                        pb, order, bits = buffered(P, D, a_blk, w_blk, rp, cp, pr, pc, sup)
                        g0, gb = gmacs(macs, p0, ar), gmacs(macs, pb, ar)
                        cells.append(f"{100 * D / p0:5.1f}%/{g0:6,.0f} -> {100 * D / pb:5.1f}%/{gb:6,.0f} "
                                     f"[{order[0]}, {bits / 8192:5.0f}]")
                        csv_rows.append(dict(shape=shape, prec=prec, schedule=name, L=L, sram=lab + " buffered",
                                             nobuf_prefetch_pct=round(100 * D / p0, 2),
                                             buffered_pct=round(100 * D / pb, 2), buffered_gmacs=round(gb, 2),
                                             buffered_mac_tile_cycle=round(pk * D / pb, 4),
                                             buffer_order=order, buffer_kb=round(bits / 8192, 1)))
                    print(f"   {prec:4s} {name:8s} {100 * pct_c:7.1f}% | " + " | ".join(f"{c:^58s}" for c in cells))
    print("   CNSB % is of its own peak (1 / 2 / 4 MAC/tile-cycle); BP of 2 / 4 / 8.  M = M-inner, N = N-inner.")

    def row(sch, prec, sup):     # (MAC/tile-cycle, GMAC/s/mm2, buffer KB) at 4x4 L=4096
        L, (pr, pc) = 4096, SHAPES["4x4"]
        ba, bw = PREC[prec]
        if sch == "CNSB":
            c = cnsb_block(prec, L, pr, pc)
            pb, _, bits = buffered(c["period"], c["D"], c["a_blk"], c["w_blk"], c["rows_pe"], c["cols_pe"], pr, pc, sup)
            return c["peak"] * c["D"] / pb, gmacs(c["macs"], pb, area(Sch("T1"), prec, "4x4")[0]), bits / 8192
        s = schedule(sch, prec, L, pr, pc)
        _, _, rp, cp, _ = mapping(sch, prec)
        pb, _, bits = buffered(s["period"], s["D_tot"], rp * L * ba, cp * L * bw, rp, cp, pr, pc, sup)
        return peak_tc(prec) * s["D_tot"] / pb, gmacs(s["macs"], pb, area(sch, prec, "4x4")[0]), bits / 8192
    print("   Reading (4x4, L=4096, reading (i) 72 b/cycle, MAC/tile-cycle / GMAC/s/mm2 / buffer KB on the grid):")
    for prec in PREC:
        cells = [f"{n} {t:.2f} / {g:,.0f} / {kb:.0f} KB" for n, (t, g, kb) in
                 (("T1", row(Sch("T1"), prec, 72)), (H(*HYB_HEAD[prec]).name, row(H(*HYB_HEAD[prec]), prec, 72)),
                  ("CNSB", row("CNSB", prec, 72)))]
        print(f"     {prec:4s} " + ";  ".join(cells))
    print("   With these buffers a BP block with 8 activation rows or 8 weight bits of reuse needs ~128 b per data")
    print("   edge from the SRAM on its streamed side and ~0 on the other; CNSB needs 128 b per cycle at half the")
    print("   MACs.  So under (i) BP INT8 / W4A8 (H) get about 2x CNSB and INT4 ties: reading (i) alone no longer")
    print("   picks spatial Booth.  T2 S=8 has no reuse inside a block and gains nothing.  The price is the")
    print("   buffers' capacity (above) and their full-width ports (1,024 b per edge half for BP).")


def sc_cost():
    print("\n== 7. SC-mode cost of each schedule's hardware (SC T=128, 64 MAC/cycle/PE, area only)")
    print(f"   {'hardware':42s} " + " ".join(f"{s:>16s}" for s in SHAPES))
    for sch, prec, lab in ((Sch("T1"), "INT8", "T1 as built (ring)"),
                           (Sch("T2", 8), "INT8", "T2 all-space (no ring, + Horner)"),
                           (Sch("T2", 4), "INT8", "T2 S<BW (ring + Horner)"),
                           (Sch("T3"), "INT8", "T3 (64 tile muxes, " + ("synth. est.)" if T3SRC["mode"] == "ipd"
                                                                         else "PLACEHOLDER)")),
                           (Sch("T4"), "INT8", "T4 (tile change + rotator, PLACEHOLDER)"),
                           (H(4, 8), "INT8", "H (H combiner, PLACEHOLDER)"),
                           (H(4, 8, "H3"), "INT8", "H3 (T3 laps + H combiner)")):
        cells = []
        for shape, (pr, pc) in SHAPES.items():
            ar, _ = area(sch, prec, shape)
            base, _ = area(Sch("T1"), prec, shape)
            cells.append(f"{gmacs(pr * pc * 64, 1, ar):7.1f} ({100 * (base / ar - 1):+5.2f}%)")
        print(f"   {lab:42s} " + " ".join(f"{c:>16s}" for c in cells))
    print("   T3's mux sits only on the acc_in (drain) path; T4's 9-bit mux sits on the heap input of every SC MAC.")


def row_skew_sensitivity():
    print("\n== 8. Sensitivity: per-PE-row drain (shift_in skewed by r; NOT in RTL) cuts the skew term to P_C-1")
    print(f"   {'schedule':8s} " + " ".join(f"{f'{sh} INT8 L=4096':>24s}" for sh in ("4x4", "4x8")) + "   (% of peak, as built -> row-skewed drain)")
    for sch in SCHEDS + [H(4, 8), H(4, 8, "H3")]:
        cells = []
        for sh in ("4x4", "4x8"):
            a = schedule(sch, "INT8", 4096, *SHAPES[sh])
            b = schedule(sch, "INT8", 4096, *SHAPES[sh], row_skew_drain=True)
            cells.append(f"{100 * a['pct']:5.1f}% -> {100 * b['pct']:5.1f}%")
        print(f"   {sch.name:8s} " + " ".join(f"{c:>24s}" for c in cells))


def verdict():
    print("\n== 9. The analytical expectation, checked")
    holds = []

    def claim(text, ok, detail):
        holds.append(ok)
        print(f"   [{'HOLDS' if ok else 'DOES NOT HOLD'}] {text}\n            {detail}")

    t1 = lambda prec, L, sh: schedule(Sch("T1"), prec, L, *SHAPES[sh])
    t2 = lambda prec, L, sh, S=8: schedule(Sch("T2", S), prec, L, *SHAPES[sh])
    claim("A lap is a drain that stays inside one PE (8 edges on every grid); the real drain is 8*P_C.",
          all(block_terms(Sch("T1"), "INT8", 4096, *SHAPES[s])["lap"] == 7 * 8 for s in SHAPES)
          and [block_terms(Sch("T1"), "INT8", 4096, *SHAPES[s])["drain"] for s in SHAPES] == [8, 32, 64],
          "RTL: ring west input = own row's east << 1 (PE-local), 8 edges of ring_q; drain = global shift_in "
          "through the PE-row chain, 8*P_C edges (8 / 32 / 64), both confirmed bit-exact in the simulator.")
    ties = []
    for L in LS:
        a, b = t1("INT8", L, "1PE"), t2("INT8", L, "1PE")
        ties.append((L, a["period"], 8 * b["period"]))
    tie_ok = all(x == y for L, x, y in ties if L <= lmax(Sch("T1"), "INT8"))
    claim("T2 S=8 ties T1 on one PE (8*NB + 64 edges per 8 outputs either way).", tie_ok,
          "per 8 outputs, T1 vs 8 x T2: " + ", ".join(f"L={L}: {x} vs {y}" for L, x, y in ties)
          + ".  Exception at L=65,536: T1 must split the block (24-bit range), T2 S=8 need not, so T2 wins by "
          f"{100 * (ties[-1][1] / ties[-1][2] - 1):.1f}%.")
    a, b = t1("INT8", 4096, "4x4"), t2("INT8", 4096, "4x4")
    a8, b8 = t1("INT8", 4096, "4x8"), t2("INT8", 4096, "4x8")
    claim("T2 S=8 loses on grids (4x4 INT8 L=4096: ~46% vs 73% of peak).",
          abs(100 * b["pct"] - 45.7) < 0.1 and abs(100 * a["pct"] - 73.1) < 0.1,
          f"4x4: T2 S=8 {100 * b['pct']:.1f}% ({8 * b['period']} edges per 8 outputs: 8 x (32 + 6 + 32)) vs T1 "
          f"{100 * a['pct']:.1f}% ({a['period']}); 4x8: {100 * b8['pct']:.1f}% vs {100 * a8['pct']:.1f}%.  "
          "T2 replaces 7 PE-local 8-edge laps by 7 extra row-wide drains AND 7 extra skew waits.")
    bw_ok = True
    for prec in PREC:     # b/MAC from each mapping: 2 x 1,024 b over (outputs x 128 / passes) MAC per data edge
        vals = {2 * DEMAND * mapping(s, prec)[4] / (schedule(s, prec, 4096, 1, 1)['outs'] * SLOT)
                for s in SCHEDS if applies(s, prec)}
        bw_ok &= len(vals) == 1
    claim("Operand bandwidth per MAC is identical (1,024 b per edge half per data edge on each side).", bw_ok,
          "16 / 8 / 4 b/MAC at the PE edge (INT8 / W4A8 / INT4), 4 / 2 / 1 at the 4x4 edge, 3 / 1.5 / 0.75 at "
          "4x8, for every schedule; per GEMM the A and W sends are equal too (section 5).")
    claim("T2 S=8 reads weights byte-major (no bit-plane transposition).", True,
          "each edge carries 128 weight bytes of one output column; T1/T3/T4 need bit-plane-major W (section 5).")
    c = schedule(Sch("T3"), "INT8", 4096, 4, 4)
    a1, _ = area(Sch("T1"), "INT8", "1PE")
    a3, _ = area(Sch("T3"), "INT8", "1PE")
    g44 = area(Sch("T3"), "INT8", "4x4")[0] / area(Sch("T1"), "INT8", "4x4")[0] - 1
    claim("T3 gives ~85% on 4x4 at L=4096 for roughly +2% area (unsynthesized guess).",
          abs(100 * c["pct"] - 85.0) < 0.2,
          f"{100 * c['pct']:.1f}% ({c['period']} edges).  Area ("
          + ("synthesized delta on routed blocks" if T3SRC["mode"] == "ipd" else "PLACEHOLDER")
          + f") +{100 * (a3 / a1 - 1):.2f}% per PE, "
          f"but +{100 * g44:.2f}% of the 4x4 composite (64 muxes in every PE do not amortize over shared edges).")
    t4 = schedule(Sch("T4"), "INT8", 4096, 4, 4)
    print(f"   [NOTE] T4 continuous rotation is never better than T3: its stagger costs N_W-1 = 7 edges per block,"
          f" exactly T3's 7 one-edge laps at INT8 (4x4 L=4096: {t4['period']} vs {c['period']}),\n"
          f"            more for BW=4 (7 vs 3) and much more at NB < 8 (rotation windows need 8 edges).")

    print("\n   Added after the adversarial review (the candidate set T1-T4 missed this family):")
    pts = [(sh, L) for sh in ("4x4", "4x8") for L in (1024, 4096)]
    g = lambda sch, prec, sh, L: gmacs(schedule(sch, prec, L, *SHAPES[sh])["macs"],
                                       schedule(sch, prec, L, *SHAPES[sh])["period"], area(sch, prec, sh)[0])
    det = []
    win = True
    for sh, L in pts:
        h, t1, t3 = (schedule(x, "INT8", L, *SHAPES[sh]) for x in (H(4, 8), Sch("T1"), Sch("T3")))
        gh, g1, g3 = g(H(4, 8), "INT8", sh, L), g(Sch("T1"), "INT8", sh, L), g(Sch("T3"), "INT8", sh, L)
        win &= gh > g1 and gh > g3
        det.append(f"{sh} L={L}: {100 * h['pct']:.1f}% / {gh:,.0f} vs T1 {100 * t1['pct']:.1f}% / {g1:,.0f}, "
                   f"T3 {100 * t3['pct']:.1f}% / {g3:,.0f}")
    claim("[NEW] INT8 H(4,8) (4 activation bits + 8 weight bits in time, 32 outputs/PE) beats T1 AND T3 on 4x4 and "
          "4x8 at L=1024 and 4096 with no PE change (GMAC/s/mm2 incl. the H combiner placeholder).", win,
          "; ".join(det) + f".  Range: L <= {lmax(H(4, 8), 'INT8'):,} per block.")
    h44 = schedule(H(4, 8), "INT8", 4096, 4, 4)
    claim("[NEW] Why T2 lost and H wins: the drain + skew is paid per output block, so the lever is outputs per PE "
          "per block (T2 S=8: 1, T1: 8, H(4,8): 32), not where the 2^s is applied.",
          8 * h44["period"] / h44["outs"] < schedule(Sch("T1"), "INT8", 4096, 4, 4)["period"],
          f"4x4 INT8 L=4096 edges per 8 outputs/PE: T2 S=8 {8 * schedule(Sch('T2', 8), 'INT8', 4096, 4, 4)['period']}, "
          f"T1 {schedule(Sch('T1'), 'INT8', 4096, 4, 4)['period']}, H(4,8) {8 * h44['period'] / h44['outs']:.1f}, "
          f"H3(4,8) {8 * schedule(H(4, 8, 'H3'), 'INT8', 4096, 4, 4)['period'] / h44['outs']:.1f}.")
    for prec in PREC:
        picks = []
        for L in LS:
            b = best_h(prec, L, "4x4")
            picks.append(f"L={L}: {b.name} {100 * schedule(b, prec, L, 4, 4)['pct']:.1f}%")
        print(f"   [NOTE] best H on 4x4, {prec}: " + ", ".join(picks))
    print("   [NOTE] W4A8 H(8,4) and INT4 H(4,4) are the round-1 'HB' mapping (model_bitplane_throughput.py,")
    print("          bitplane_throughput_costs.py 'HB-ring'), modelled there but not carried into the as-built schedule.")
    return all(holds)


def feeder_sensitivity():
    print("\n== 4b. Sensitivity: feeder bit-plane select muxes instead of bit-plane-major storage (INT8, GMAC/s/mm2)")
    print(f"   Main table: the SRAM stores the time-multiplexed operand bit-plane-major (T1/T3: W; H: A and W),")
    print(f"   not costed.  Here the feeder selects the plane from byte words instead: an n:1 mux per operand line")
    print(f"   (1,024 per edge half; 2:1 {MUX[2]:.3f}, 4:1 {MUX[4]:.3f}, 8:1 {MUX[8]:.3f} um2, cell count).  T2 S=8 needs none.")
    print(f"   {'schedule':8s} " + " ".join(f"{f'{sh} L={L}':>26s}" for sh in ("4x4", "4x8") for L in (1024, 4096))
          + "   (bit-plane-major -> feeder muxes)")
    for sch in [Sch("T1"), Sch("T2", 8), Sch("T3"), H(4, 8), H(4, 4), H(4, 8, "H3")]:
        cells = []
        for sh in ("4x4", "4x8"):
            for L in (1024, 4096):
                s = schedule(sch, "INT8", L, *SHAPES[sh])
                ar = area(sch, "INT8", sh)[0]
                cells.append(f"{gmacs(s['macs'], s['period'], ar):6,.0f} -> "
                             f"{gmacs(s['macs'], s['period'], ar + feeder_mux_area(sch, 'INT8', sh)):6,.0f}")
        print(f"   {sch.name:8s} " + " ".join(f"{c:>26s}" for c in cells))


# ========================================================================= main
def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--quick", action="store_true", help="smaller simulator matrix")
    ap.add_argument("--t3-pe-add-um2", type=float, default=None,
                    help="per-PE T3 area adder (um2) replacing the placeholder, e.g. from synthesis")
    ap.add_argument("--t3-placeholder", action="store_true",
                    help="use the unsynthesized T3 placeholder even if the In-place stage result exists")
    ap.add_argument("--csv", default=str(REPO / "sweeps/int_mode/bp/model_lap_schedules.csv"))
    args = ap.parse_args()
    if args.t3_pe_add_um2 is not None:
        PH["T3_pe"] = args.t3_pe_add_um2
    elif not args.t3_placeholder and (REPO / IPD_JSON).exists():
        js = json.loads((REPO / IPD_JSON).read_text())
        ri, rl = js["routed_ipd_estimate"], js["routed_lap"]
        T3SRC.update(mode="ipd", d_pe=ri["u_pe"] - rl["u_pe"], d_periph=ri["u_peripheral"] - rl["u_peripheral"],
                     d_total=ri["total"] - rl["total"])
    print("Lap schedules for BP INT on the PaYN carry-save array (TSMC22, 400 MHz, K8 M16 N8, OWIDTH 24)")
    print(f"Routed areas ({ROUTE_AREA}): total {A['total']:,.3f}, u_pe {A['u_pe']:,.3f} (core {A['core']:,.3f},"
          f" ring wrapper {A['ring']:.3f}), u_peripheral {A['periph']:,.3f}, u_combiner {A['comb']:.3f}, "
          f"Sobol {A['sobol']:,.3f} um2")
    for shape in SHAPES:
        print(f"  {shape} BP-lap area {area(Sch('T1'), 'INT8', shape)[0]:,.1f} um2")
    if args.t3_pe_add_um2 is not None:
        print(f"  T3 per-PE adder from the command line: {PH['T3_pe']:.1f} um2 (replaces the placeholder)")
    elif T3SRC["mode"] == "ipd":
        print(f"  T3 area: SYNTHESIZED in-place-doubling delta (csa_bp_ipd_20261004 - csa_bp_20261004_lap) added to the "
              f"routed lap blocks, from {IPD_JSON}:\n    u_pe {T3SRC['d_pe']:+.1f}, u_peripheral {T3SRC['d_periph']:+.1f},"
              f" 1-PE total {T3SRC['d_total']:+.1f} um2 (an ESTIMATE: synthesized, not routed).  The unsynthesized "
              f"placeholder was {PH['T3_pe']:.1f} um2/PE (--t3-placeholder uses it).")
    else:
        print(f"  T3 area: PLACEHOLDER {PH['T3_pe']:.1f} um2/PE (no In-place stage result at {IPD_JSON})")
    print(f"  H area: routed lap blocks (unchanged PE) + H combiner PLACEHOLDER {PH['hyb_comb_row']:.1f} um2 per PE row "
          f"(cell count; the routed u_combiner is {A['comb']:.1f}),\n    + column Horner {PH['horner_row']:.1f} um2 "
          f"per PE row when TW < BW; H(1,BW) = T1 uses the existing combiner.  H3 adds the T3 area.")
    validate_measured()
    validate_ipd()
    validate_sim(args.quick)
    validate_hybrid(args.quick)
    csv_rows = []
    main_table(csv_rows)
    feeder_sensitivity()
    bandwidth_table()
    sram_table(csv_rows)
    sram_buffered(csv_rows)
    sc_cost()
    row_skew_sensitivity()
    ok = verdict()
    keys = []
    for r in csv_rows:
        for k in r:
            if k not in keys:
                keys.append(k)
    with open(args.csv, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=keys)
        w.writeheader()
        w.writerows(csv_rows)
    print(f"\n-> {args.csv}")
    if FAILS:
        print(f"\nFAILED: {len(FAILS)} validation mismatch(es)")
        for f in FAILS:
            print("  " + f)
        return 1
    print(f"\nALL VALIDATIONS PASS (analytical expectation: {'holds in every listed point' if ok else 'see section 9'})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
