"""Shared per-component taxonomy for the PE breakdown plots.

Unifies the SC-GEMM PE buckets (popcount / bit-pipe / sign / acc / drain) and the
uSystolic binary buckets (mult+add / ireg / wreg / psum) onto one comparable set
of display segments, so SC and binary designs appear in the same per-component
plots. Consumed by plot_pe_components.py (APR) and plot_synth_vs_apr.py (synth).

Component reports are produced by:
  SC:     pt_pe_area.tcl / pt_pe_components.tcl
  binary: pt_binary_area.tcl / pt_binary_power.tcl
"""
from __future__ import annotations

import re
from pathlib import Path

# Unified display segments (bottom->top of each stacked bar).
SEGMENTS = [
    ("compute", "Compute (popcount / mult+add)", "#B84A24"),
    ("input", "Input regs", "#4A7A9E"),
    ("weight", "Weight regs", "#79B0CE"),
    ("acc", "Accumulator regs", "#3E8A6E"),
    ("output", "Output / drain regs", "#C77D3A"),
    ("peripheral", "Asymmetric correction peripheral", "#8064A2"),
    ("clock", "Clock tree", "#8A8580"),
    ("glue", "Glue / control", "#B89A6A"),
]

# Raw report keys (superset of SC + binary). parse_kv reads whichever are present.
AREA_KEYS = [
    # SC
    "in_bit_area", "w_bit_area", "in_sign_area", "w_sign_area", "acc_area",
    "drain_area", "load_area", "other_reg_area", "popcount_area",
    # binary
    "bin_ireg_area", "bin_wreg_area", "bin_acc_reg_area", "bin_mul_area",
    "bin_acc_add_area", "bin_ctrl_area",
    "bin_asym_sum_area", "bin_asym_corr_area",
    # shared
    "clock_area", "glue_area",
]
PWR_KEYS = [
    # SC
    "in_bit_reg", "w_bit_reg", "in_sign_reg", "w_sign_reg", "acc_reg",
    "drain_reg", "load_ctrl_reg", "other_reg", "popcount_logic",
    # binary
    "bin_ireg", "bin_wreg", "bin_acc_reg", "bin_mul", "bin_acc_add", "bin_ctrl",
    "bin_asym_sum", "bin_asym_corr",
    # shared
    "clock_dist", "glue_other",
]


def parse_kv(path: Path, keys: list[str]) -> dict[str, float] | None:
    if not path.exists():
        return None
    v: dict[str, float] = {}
    for line in path.read_text(errors="replace").splitlines():
        m = re.match(r"^([a-z_]+)\s+([-+0-9.eE]+)\s*$", line)
        if m and m.group(1) in keys:
            v[m.group(1)] = float(m.group(2))
    return v or None


def _g(v: dict[str, float], *keys: str) -> float:
    return sum(v.get(k, 0.0) for k in keys)


def area_seg(v: dict[str, float]) -> dict[str, float]:
    return {
        "compute": _g(v, "popcount_area", "bin_mul_area", "bin_acc_add_area"),
        "input": _g(v, "in_bit_area", "in_sign_area", "bin_ireg_area"),
        "weight": _g(v, "w_bit_area", "w_sign_area", "bin_wreg_area"),
        "acc": _g(v, "acc_area", "bin_acc_reg_area"),
        "output": _g(v, "drain_area"),
        "peripheral": _g(v, "bin_asym_sum_area", "bin_asym_corr_area"),
        "clock": _g(v, "clock_area"),
        "glue": _g(v, "glue_area", "load_area", "other_reg_area", "bin_ctrl_area"),
    }


def pwr_seg(v: dict[str, float]) -> dict[str, float]:
    # popcount_logic is inferred from hierarchical inner-tile power. Small
    # negative residuals can result when PrimeTime's hierarchy totals overlap
    # clock-pin power; fold that correction back into the inferred compute
    # bucket so plotted components remain non-negative and reconcile to Total.
    residual = v.get("glue_other", 0.0)
    return {
        "compute": _g(v, "popcount_logic", "bin_mul", "bin_acc_add") + min(0.0, residual),
        "input": _g(v, "in_bit_reg", "in_sign_reg", "bin_ireg"),
        "weight": _g(v, "w_bit_reg", "w_sign_reg", "bin_wreg"),
        "acc": _g(v, "acc_reg", "bin_acc_reg"),
        "output": _g(v, "drain_reg"),
        "peripheral": _g(v, "bin_asym_sum", "bin_asym_corr"),
        "clock": _g(v, "clock_dist"),
        "glue": max(0.0, residual)
        + _g(v, "load_ctrl_reg", "other_reg", "bin_ctrl"),
    }
