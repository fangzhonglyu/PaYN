#!/usr/bin/env python3
"""
Generate the retained TSMC22 area/energy plots from APR/PT run reports.

This script intentionally does not contain measured power or area numbers.
It reads the exact run IDs and architectural throughput from
retained_runs_<tech>.csv, then parses power, area, timing, and activity directly
from those runs. Measured numbers are never copied into this script.

  * updated_area_energy_breakdown_<tech>.csv
  * updated_area_energy_breakdown_<tech>.png
  * updated_area_energy_breakdown_<tech>_zoom.png

Each retained run must pass the 2.5 ns, routed-netlist, timing, geometry, and
zero-persistent-X checks before it is plotted.

The stacked energy bars use a CLOCK-PIN-CORRECTED decomposition: PrimeTime folds
every flop's clock-pin internal power into the clock_network group, so its raw
"register" understates sequential power and "clock_network" overstates clock
distribution. The flow (ASTRAEA apr/scripts/power.tcl) emits
reports/power_clock_split.rpt with the register clock-pin power per run; this
script moves it back into a "Sequential" bucket (see parse_clock_split /
corrected_buckets_mw). Runs without that report fall back to the raw split with a
warning. The CSV keeps both the corrected buckets and the raw PT groups.
"""

from __future__ import annotations

import argparse
import csv
import gzip
import math
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt


DEFAULT_PERIOD_NS = 2.5

# Plotted buckets are the CLOCK-PIN-CORRECTED decomposition, not PrimeTime's raw
# power groups. PT folds every flop's clock-pin internal power into the
# clock_network group, so raw "register" understates sequential and raw
# "clock_network" overstates clock distribution. We move the register clock-pin
# internal power (measured per run in reports/power_clock_split.rpt) back into a
# "sequential" bucket. See add_derived_metrics / parse_clock_split.
POWER_GROUP_ORDER = [
    ("combinational", "Combinational", "#B84A24"),
    ("sequential", "Sequential (regs incl. clock pins)", "#4A7A9E"),
    ("clock_dist", "Clock distribution", "#8A8580"),
    ("other", "Other", "#B89A6A"),
]

POWER_ROW_RE = re.compile(
    r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s+"
    r"([-+0-9.eE]+)\s+([-+0-9.eE]+)\s+([-+0-9.eE]+)\s+([-+0-9.eE]+)"
)
TOTAL_POWER_RE = re.compile(r"^\s*Total Power\s*=\s*([-+0-9.eE]+)")
TARGET_PERIOD_RE = re.compile(r"TARGET_PERIOD\s+([-+0-9.]+)\s*ns")
SAIF_DURATION_RE = re.compile(r"SAIF_DURATION\s+([-+0-9.]+)")
SAIF_DURATION_NS_RE = re.compile(r"SAIF_DURATION_NS\s+([-+0-9.eE]+)")
SAIF_TIMESCALE_RE = re.compile(
    r"SAIF_TIMESCALE\s+([-+0-9.eE]+)\s*(fs|ps|ns|us|ms|s)"
)
SAIF_FILE_DURATION_RE = re.compile(r"^\s*\(DURATION\s+([-+0-9.eE]+)\)")
SAIF_FILE_TIMESCALE_RE = re.compile(
    r"^\s*\(TIMESCALE\s+([-+0-9.eE]+)\s+(fs|ps|ns|us|ms|s)\)"
)
SAIF_FILE_RE = re.compile(r"SAIF_FILE\s+(\S+)")
SAIF_TIME_RE = re.compile(
    r"\(T0\s+([-+0-9.eE]+)\)\s+\(T1\s+([-+0-9.eE]+)\)\s+\(TX\s+([-+0-9.eE]+)\)"
)
SAIF_TC_RE = re.compile(r"\(TC\s+([-+0-9.eE]+)\)")
SAIF_SIGNAL_RE = re.compile(r"^\s*\(([^()\s]+)\s*$")
DEF_UNITS_RE = re.compile(r"^\s*UNITS\s+DISTANCE\s+MICRONS\s+([0-9.]+)")
DEF_DIEAREA_RE = re.compile(
    r"^\s*DIEAREA\s+\(\s*(-?\d+)\s+(-?\d+)\s*\)\s+\(\s*(-?\d+)\s+(-?\d+)\s*\)"
)
DEF_PINS_RE = re.compile(r"^\s*PINS\s+(\d+)\s*;")
DEF_PIN_PLACEMENT_RE = re.compile(r"\+\s+(?:FIXED|PLACED|COVER)\b")
PLACEMENT_DENSITY_RE = re.compile(
    r"Placement Density(?: \(including fixed std cells\))?:\s*"
    r"([0-9.]+)%\(([0-9.]+)/([0-9.]+)\)"
)
# Register clock-pin internal power (mW) emitted by the flow's clock-pin split
# report (ASTRAEA apr/scripts/power.tcl -> reports/power_clock_split.rpt).
CLKPIN_RE = re.compile(r"^\s*reg_clkpin_int\s+([-+0-9.eE]+)")


@dataclass
class RunRecord:
    target: str
    run: str
    run_dir: Path
    power_rpt: Path
    groups_mw: dict[str, float]
    total_mw: float
    mac_per_cycle: float
    label: str
    kind: str
    die_area_um2: float | None
    def_path: Path | None
    io_pins_total: int
    io_pins_assigned: int
    saif_target_period_ns: float | None
    saif_observed_period_ns: float | None
    saif_duration_ns: float | None
    saif_path: Path | None
    saif_file_pct: float | None
    saif_not_annotated_pct: float | None
    saif_tx_pct: float | None
    saif_acc_tx_pct: float | None
    saif_output_tx_pct: float | None
    saif_nonpersistent_tx_pct: float | None
    saif_persistent_tx_signals: int | None
    saif_tc_sum: float | None
    cell_area_um2: float | None
    place_area_um2: float | None
    placement_density_pct: float | None
    setup_wns_ns: float | None
    hold_wns_ns: float | None
    skipped_reason: str | None = None
    reg_clkpin_mw: float | None = None
    energy_pj_by_group: dict[str, float] = field(default_factory=dict)
    buckets_mw: dict[str, float] = field(default_factory=dict)
    total_pj_per_mac: float = math.nan
    mac_per_cycle_per_mm2: float = math.nan
    gmac_s_per_mm2: float = math.nan


def parse_args() -> argparse.Namespace:
    here = Path(__file__).resolve()
    repo_default = here.parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=repo_default)
    parser.add_argument("--tech", default="TSMC22")
    parser.add_argument("--period-ns", type=float, default=DEFAULT_PERIOD_NS)
    parser.add_argument("--out-dir", type=Path, default=here.parent)
    parser.add_argument("--prefix", default="updated_area_energy_breakdown")
    parser.add_argument(
        "--allow-period-mismatch",
        action="store_true",
        help="Include runs whose SAIF header TARGET_PERIOD differs from --period-ns.",
    )
    parser.add_argument(
        "--allow-missing-saif-header",
        action="store_true",
        help="Include runs that have no reports/saif_header.rpt. Default is to skip them.",
    )
    parser.add_argument(
        "--allow-missing-timing",
        action="store_true",
        help=(
            "Include runs without final post-route setup/hold summaries. "
            "Default is to require both and reject negative WNS."
        ),
    )
    parser.add_argument(
        "--allow-missing-geometry",
        action="store_true",
        help=(
            "Include runs without a final DRC report. Default is to require "
            "an explicitly clean report."
        ),
    )
    parser.add_argument(
        "--allow-stale-power",
        action="store_true",
        help=(
            "Include power reports older than their referenced SAIF. Default is to "
            "reject them because a SAIF path may have been overwritten after PT-PX ran."
        ),
    )
    parser.add_argument(
        "--max-saif-tx-pct",
        type=float,
        default=15.0,
        help=(
            "Skip runs whose referenced SAIF spends more than this percent of "
            "aggregate annotated signal time unknown (SAIF TX). Use a negative "
            "value to disable."
        ),
    )
    parser.add_argument(
        "--max-saif-acc-tx-pct",
        type=float,
        default=0.0,
        help=(
            "Allowed SC accumulator TX percentage beyond one SAIF reporter "
            "quantum. Default is zero."
        ),
    )
    parser.add_argument(
        "--max-saif-binary-output-tx-pct",
        type=float,
        default=0.0,
        help="Skip binary runs with any top-level ofm signal above this TX percentage.",
    )
    parser.add_argument(
        "--zoom-pj-max",
        type=float,
        default=1.0,
        help="Generate a second plot for designs at or below this pJ/MAC.",
    )
    parser.add_argument(
        "--max-label-len",
        type=int,
        default=40,
        help="Wrap y-axis labels after roughly this many characters.",
    )
    parser.add_argument(
        "--verbose-skips",
        action="store_true",
        help="Print every excluded run; the full list is always written to the exclusions file.",
    )
    return parser.parse_args()


def load_retained_runs(args: argparse.Namespace) -> list[dict[str, str]]:
    manifest = args.repo_root / "sweeps" / f"retained_runs_{args.tech.lower()}.csv"
    if not manifest.exists():
        raise FileNotFoundError(f"retained-run manifest not found: {manifest}")
    with manifest.open(newline="") as stream:
        rows = list(csv.DictReader(stream))
    if not rows:
        raise ValueError(f"retained-run manifest is empty: {manifest}")
    return rows


def parse_power_report(path: Path) -> tuple[dict[str, float], float]:
    groups_mw: dict[str, float] = {}
    total_mw: float | None = None

    for line in path.read_text(errors="replace").splitlines():
        total_match = TOTAL_POWER_RE.match(line)
        if total_match:
            total_mw = float(total_match.group(1)) * 1000.0
            continue

        row_match = POWER_ROW_RE.match(line)
        if not row_match:
            continue

        group = row_match.group(1)
        if group in {"Power", "Group"}:
            continue
        groups_mw[group] = float(row_match.group(5)) * 1000.0

    if total_mw is None:
        raise ValueError(f"could not find Total Power in {path}")

    return groups_mw, total_mw


def parse_saif_header(run_dir: Path) -> tuple[float | None, float | None, Path | None]:
    path = run_dir / "reports" / "saif_header.rpt"
    if not path.exists():
        return None, None, None

    period = None
    duration = None
    duration_raw = None
    timescale_to_ns = None
    saif_path = None
    for line in path.read_text(errors="replace").splitlines():
        m = SAIF_FILE_RE.search(line)
        if m:
            saif_path = Path(m.group(1))
        m = TARGET_PERIOD_RE.search(line)
        if m:
            period = float(m.group(1))
        m = SAIF_DURATION_RE.search(line)
        if m:
            duration_raw = float(m.group(1))
        m = SAIF_DURATION_NS_RE.search(line)
        if m:
            duration = float(m.group(1))
        m = SAIF_TIMESCALE_RE.search(line)
        if m:
            scale = float(m.group(1))
            unit_to_ns = {
                "fs": 1.0e-6,
                "ps": 1.0e-3,
                "ns": 1.0,
                "us": 1.0e3,
                "ms": 1.0e6,
                "s": 1.0e9,
            }
            timescale_to_ns = scale * unit_to_ns[m.group(2)]
    if duration is None and duration_raw is not None:
        duration = duration_raw * (timescale_to_ns if timescale_to_ns is not None else 1.0)
    local_saif = run_dir / "activity" / "dut.saif"
    if local_saif.exists() and (saif_path is None or not saif_path.exists()):
        saif_path = local_saif
    return period, duration, saif_path


def _saif_lines(path: Path | None, lines: list[str] | None) -> list[str] | None:
    if lines is not None:
        return lines
    if path is None or not path.exists():
        return None
    return path.read_text(errors="replace").splitlines()


def parse_saif_activity(
    path: Path | None, lines: list[str] | None = None
) -> tuple[float | None, float | None]:
    """Return aggregate unknown-time percentage and total toggle count."""
    lines = _saif_lines(path, lines)
    if lines is None:
        return None, None

    t0_sum = 0.0
    t1_sum = 0.0
    tx_sum = 0.0
    tc_sum = 0.0
    pending_tc = False

    for line in lines:
        m = SAIF_TIME_RE.search(line)
        if m:
            t0, t1, tx = (float(x) for x in m.groups())
            t0_sum += t0
            t1_sum += t1
            tx_sum += tx
            pending_tc = True
            continue

        if pending_tc:
            m = SAIF_TC_RE.search(line)
            if m:
                tc_sum += float(m.group(1))
                pending_tc = False

    total_time = t0_sum + t1_sum + tx_sum
    if total_time <= 0.0:
        return None, tc_sum
    return 100.0 * tx_sum / total_time, tc_sum


def parse_saif_stimulus_tc(
    path: Path | None, lines: list[str] | None = None
) -> tuple[float | None, float | None]:
    """Return clock and top-level SC operand toggle counts.

    TX records unknown-state occupancy; it is not a switching metric. These
    explicit TC checks prevent an all-static but fully known stimulus from
    passing the X-activity checks.
    """
    lines = _saif_lines(path, lines)
    if lines is None:
        return None, None

    current_signal: str | None = None
    clock_tc = 0.0
    operand_tc = 0.0
    for line in lines:
        signal_match = SAIF_SIGNAL_RE.match(line)
        if signal_match:
            current_signal = signal_match.group(1).replace(r"\[", "[")
            continue
        if current_signal is None:
            continue
        tc_match = SAIF_TC_RE.search(line)
        if not tc_match:
            continue
        tc = float(tc_match.group(1))
        if current_signal == "clk":
            clock_tc = max(clock_tc, tc)
        elif current_signal.startswith(
            ("in_bits", "w_bits", "in_sign", "w_sign", "a_bits", "a_sign")
        ):
            operand_tc += tc
        current_signal = None

    return clock_tc, operand_tc


def parse_saif_observed_clock_period_ns(
    path: Path | None, lines: list[str] | None = None
) -> float | None:
    """Recover clock period from SAIF duration, timescale, and clock toggles."""
    lines = _saif_lines(path, lines)
    if lines is None:
        return None

    duration = None
    timescale_ns = None
    for line in lines:
        duration_match = SAIF_FILE_DURATION_RE.match(line)
        if duration_match:
            duration = float(duration_match.group(1))
        timescale_match = SAIF_FILE_TIMESCALE_RE.match(line)
        if timescale_match:
            unit_ns = {
                "fs": 1.0e-6,
                "ps": 1.0e-3,
                "ns": 1.0,
                "us": 1.0e3,
                "ms": 1.0e6,
                "s": 1.0e9,
            }
            timescale_ns = float(timescale_match.group(1)) * unit_ns[timescale_match.group(2)]
        if duration is not None and timescale_ns is not None:
            break

    clock_tc, _ = parse_saif_stimulus_tc(path, lines)
    if duration is None or timescale_ns is None or clock_tc is None or clock_tc <= 0.0:
        return None
    return 2.0 * duration * timescale_ns / clock_tc


def parse_saif_nonpersistent_tx(
    path: Path | None, lines: list[str] | None = None
) -> tuple[float | None, int | None]:
    """TX percentage after separating signals unknown for the entire window.

    Full-window TX is counted separately so callers can reject it explicitly.
    A floating physical-hierarchy feedthrough is not safe merely because it has
    no architectural fanout: accepting it can hide a broken APR export.
    """
    lines = _saif_lines(path, lines)
    if lines is None:
        return None, None

    known_time = 0.0
    tx_time = 0.0
    persistent = 0
    for line in lines:
        match = SAIF_TIME_RE.search(line)
        if not match:
            continue
        t0, t1, tx = (float(value) for value in match.groups())
        total = t0 + t1 + tx
        if total <= 0.0:
            continue
        if tx == total:
            persistent += 1
            continue
        known_time += total
        tx_time += tx

    if known_time <= 0.0:
        return None, persistent
    return 100.0 * tx_time / known_time, persistent


def saif_unknown_activity_error(
    nonpersistent_tx_pct: float | None,
    persistent_signals: int | None,
    reporting_quantum_pct: float | None,
) -> str | None:
    """Return the fail-closed SAIF unknown-activity error, if any."""
    if reporting_quantum_pct is None:
        return "no SAIF duration/reporting quantum"
    if persistent_signals is None:
        return "cannot classify persistent X activity"
    if persistent_signals != 0:
        return f"persistent-X signals={persistent_signals}; required 0"
    if nonpersistent_tx_pct is None:
        return "no nonpersistent SAIF activity records"
    if nonpersistent_tx_pct > reporting_quantum_pct + 1.0e-12:
        return (
            f"nonpersistent TX={nonpersistent_tx_pct:.9f}% exceeds one "
            f"reporter quantum ({reporting_quantum_pct:.9f}%)"
        )
    return None


def parse_saif_binary_output_tx(
    path: Path | None, lines: list[str] | None = None
) -> float | None:
    """Maximum TX percentage on Top/dut's architectural binary outputs."""
    lines = _saif_lines(path, lines)
    if lines is None:
        return None

    depth = 0
    instances: list[tuple[str, int]] = []
    pending: tuple[tuple[str, ...], str] | None = None
    max_tx_pct: float | None = None
    reserved = {"SAIFILE", "INSTANCE", "NET", "PORT"}

    for line in lines:
        stripped = line.strip()
        before_depth = depth
        if stripped.startswith("(INSTANCE "):
            name = stripped.split(None, 1)[1].rstrip(")")
            instances.append((name, before_depth + 1))
        else:
            match = re.fullmatch(r"\(([^()\s]+)", stripped)
            if match and match.group(1) not in reserved:
                pending = (tuple(name for name, _ in instances), match.group(1))

        match = SAIF_TIME_RE.search(line)
        if match and pending is not None:
            instance_path, signal = pending
            if instance_path == ("Top", "dut") and signal.startswith(
                ("ofm\\[", "acc_value\\[", "drain_out\\[")
            ):
                t0, t1, tx = (float(value) for value in match.groups())
                total = t0 + t1 + tx
                if total > 0.0:
                    tx_pct = 100.0 * tx / total
                    max_tx_pct = tx_pct if max_tx_pct is None else max(max_tx_pct, tx_pct)
            pending = None

        depth += line.count("(") - line.count(")")
        while instances and depth < instances[-1][1]:
            instances.pop()

    return max_tx_pct


def parse_saif_reporting_quantum_pct(
    path: Path | None, lines: list[str] | None = None
) -> float | None:
    """Return one SAIF time-unit as a percentage of measured duration.

    VCS initializes monitored changing signals with one SAIF time-unit of TX,
    including a known clock. Event-driven testbench checks catch real X events;
    this function identifies only that fixed reporter bookkeeping quantum.
    """
    lines = _saif_lines(path, lines)
    if lines is None:
        return None
    for line in lines:
        match = SAIF_FILE_DURATION_RE.match(line)
        if match:
            duration = float(match.group(1))
            return 100.0 / duration if duration > 0.0 else None
    return None


def parse_saif_acc_tx(
    path: Path | None, lines: list[str] | None = None
) -> float | None:
    lines = _saif_lines(path, lines)
    if lines is None:
        return None

    pending_acc = False
    max_tx_pct: float | None = None
    for line in lines:
        if "acc_value\\[" in line or "acc_out\\[" in line:
            pending_acc = True
            continue
        if not pending_acc:
            continue
        match = SAIF_TIME_RE.search(line)
        if match:
            t0, t1, tx = (float(value) for value in match.groups())
            total = t0 + t1 + tx
            if total > 0.0:
                tx_pct = 100.0 * tx / total
                max_tx_pct = tx_pct if max_tx_pct is None else max(max_tx_pct, tx_pct)
            pending_acc = False
    return max_tx_pct


def netlist_interfaces_clean(path: Path) -> bool:
    """Reject hierarchical netlists with omitted, functionally used inputs."""
    text = path.read_text(errors="replace")
    module_re = re.compile(
        r"^\s*module\s+([^\s(]+)\s*\((.*?)\)\s*;(.*?)^\s*endmodule\b",
        re.MULTILINE | re.DOTALL,
    )
    modules: dict[str, tuple[set[str], set[str], str]] = {}
    for match in module_re.finditer(text):
        header = match.group(2)
        body = match.group(3)
        ports: set[str] = set()
        directions: dict[str, str] = {}
        current_direction: str | None = None
        for declaration in header.split(","):
            direction = re.search(r"\b(input|output|inout)\b", declaration)
            if direction:
                current_direction = direction.group(1)
            port = re.search(r"([A-Za-z_$][\w$]*)\s*$", declaration)
            if port:
                port_name = port.group(1)
                ports.add(port_name)
                if current_direction is not None:
                    directions[port_name] = current_direction
        for direction, declaration in re.findall(
            r"^\s*(input|output|inout)\b([^;]*);", body, re.MULTILINE
        ):
            for port_name in ports:
                if re.search(
                    rf"(?<![\w$]){re.escape(port_name)}(?![\w$])", declaration
                ):
                    directions[port_name] = direction
        functional_body = re.sub(
            r"^\s*(?:input|output|inout)\b[^;]*;",
            "",
            body,
            flags=re.MULTILINE,
        )
        required_ports = {
            port_name
            for port_name in ports
            if directions.get(port_name) in ("input", "inout")
            and re.search(
                rf"(?<![\w$]){re.escape(port_name)}(?![\w$])",
                functional_body,
            )
        }
        modules[match.group(1)] = (ports, required_ports, body)

    instance_re = re.compile(
        r"^\s*([^\s(]+)\s+([^\s(]+)\s*\((.*?)\)\s*;",
        re.MULTILINE | re.DOTALL,
    )
    for _, _, body in modules.values():
        for instance in instance_re.finditer(body):
            child = modules.get(instance.group(1))
            if child is None:
                continue
            connected = set(
                re.findall(r"\.([A-Za-z_$][\w$]*)\s*\(", instance.group(3))
            )
            if connected and child[1] - connected:
                return False
    return bool(modules)


def parse_geometry_clean(run_dir: Path) -> bool | None:
    reports = sorted(run_dir.glob("*.geom.rpt"))
    if not reports:
        return None
    text = reports[-1].read_text(errors="replace")
    if "No DRC violations were found" in text:
        return True
    if "Total Violations" in text:
        return False
    return None


def parse_timing_wns(run_dir: Path) -> tuple[float | None, float | None]:
    def parse_final(path: Path) -> float | None:
        slacks = [
            float(match.group(1))
            for match in re.finditer(
                r"^\s*(?:=\s*)?Slack Time\s+(-?[0-9.]+)",
                path.read_text(errors="replace"),
                re.MULTILINE,
            )
        ]
        return min(slacks) if slacks else None

    setup_final = run_dir / "reports" / "setup.rpt"
    hold_final = run_dir / "reports" / "hold.rpt"
    if setup_final.exists() and hold_final.exists():
        return parse_final(setup_final), parse_final(hold_final)

    # Legacy PT-PX runs deleted Innovus's final reports. Use their post-route
    # summaries as a fallback; current power runs preserve the final reports.
    timing_dir = run_dir / "timingReports"
    setup_reports = sorted(
        path for path in timing_dir.glob("*_postRoute.summary.gz")
        if not path.name.endswith("_hold.summary.gz")
    )
    hold_reports = sorted(timing_dir.glob("*_postRoute_hold.summary.gz"))

    def parse(path: Path) -> float | None:
        with gzip.open(path, "rt", errors="replace") as stream:
            match = re.search(r"\|\s*WNS \(ns\):\|\s*(-?[0-9.]+)", stream.read())
        return float(match.group(1)) if match else None

    setup_wns = parse(setup_reports[-1]) if setup_reports else None
    hold_wns = parse(hold_reports[-1]) if hold_reports else None
    return setup_wns, hold_wns


def parse_clock_split(run_dir: Path) -> float | None:
    """Register clock-pin internal power (mW) from reports/power_clock_split.rpt.

    Emitted by the flow (ASTRAEA apr/scripts/power.tcl). This is the power PT
    lumps into the clock_network group but that physically belongs to the flops;
    moving it back yields a true sequential-vs-clock-distribution split. Returns
    None when the report is absent (older runs) so callers can fall back.
    """
    path = run_dir / "reports" / "power_clock_split.rpt"
    if not path.exists():
        return None
    for line in path.read_text(errors="replace").splitlines():
        m = CLKPIN_RE.match(line)
        if m:
            return float(m.group(1))
    return None


def parse_saif_coverage(run_dir: Path) -> tuple[float | None, float | None]:
    path = run_dir / "reports" / "saif_coverage.rpt"
    if not path.exists():
        return None, None

    for line in path.read_text(errors="replace").splitlines():
        if not line.lstrip().startswith("Nets"):
            continue
        pcts = [float(x) for x in re.findall(r"\(([0-9.]+)%\)", line)]
        if len(pcts) >= 2:
            return pcts[0], pcts[-1]
    return None, None


def parse_def_area(run_dir: Path) -> tuple[float | None, Path | None]:
    candidates = sorted((run_dir / "outputs").glob("*.apr.def"))
    if not candidates:
        candidates = sorted(run_dir.glob("*.def"))

    for path in candidates:
        units = None
        with path.open(errors="replace") as stream:
            for line in stream:
                unit_match = DEF_UNITS_RE.match(line)
                if unit_match:
                    units = float(unit_match.group(1))
                    continue

                area_match = DEF_DIEAREA_RE.match(line)
                if area_match and units:
                    x1, y1, x2, y2 = [int(v) for v in area_match.groups()]
                    area_um2 = (x2 - x1) * (y2 - y1) / (units * units)
                    return area_um2, path

    return None, None


def parse_def_pin_placement(path: Path | None) -> tuple[int, int] | None:
    """Return total and physically assigned top-level pins from a routed DEF."""
    if path is None or not path.exists():
        return None

    expected: int | None = None
    assigned = 0
    in_pins = False
    current_pin = False
    current_assigned = False

    def finish_pin() -> None:
        nonlocal assigned, current_pin, current_assigned
        if current_pin and current_assigned:
            assigned += 1
        current_pin = False
        current_assigned = False

    with path.open(errors="replace") as stream:
        for line in stream:
            if not in_pins:
                match = DEF_PINS_RE.match(line)
                if match:
                    expected = int(match.group(1))
                    in_pins = True
                continue
            if line.lstrip().startswith("END PINS"):
                finish_pin()
                break
            if line.lstrip().startswith("-"):
                finish_pin()
                current_pin = True
            if current_pin and DEF_PIN_PLACEMENT_RE.search(line):
                current_assigned = True

    if expected is None:
        return None
    return expected, assigned


def parse_placement_area(run_dir: Path) -> tuple[float | None, float | None, float | None]:
    log_path = run_dir / "apr.log"
    if not log_path.exists():
        return None, None, None

    last = None
    for line in log_path.read_text(errors="replace").splitlines():
        m = PLACEMENT_DENSITY_RE.search(line)
        if m:
            last = (float(m.group(1)), float(m.group(2)), float(m.group(3)))

    if not last:
        return None, None, None

    density_pct, cell_area_um2, place_area_um2 = last
    return cell_area_um2, place_area_um2, density_pct


def wrap_label(text: str, max_len: int) -> str:
    words = text.split()
    lines: list[str] = []
    line = ""
    for word in words:
        candidate = f"{line} {word}".strip()
        if line and len(candidate) > max_len:
            lines.append(line)
            line = word
        else:
            line = candidate
    if line:
        lines.append(line)
    return "\n".join(lines)


def build_records(args: argparse.Namespace) -> tuple[list[RunRecord], list[str]]:
    build_root = args.repo_root / "apr" / "build" / args.tech
    warnings: list[str] = []
    candidates: list[RunRecord] = []

    for row in load_retained_runs(args):
        target = row["target"]
        run = row["apr_run"]
        run_dir = build_root / target / run
        label = row["label"]
        kind = row["kind"]
        mac_per_cycle = float(row["mac_per_cycle"])
        manifest_period = float(row["period_ns"])
        if abs(manifest_period - args.period_ns) > 1.0e-9:
            warnings.append(
                f"skip {target}/{run}: manifest period {manifest_period:g} ns "
                f"!= requested {args.period_ns:g} ns"
            )
            continue
        if kind == "sc":
            expected_mac_per_cycle = (
                int(row["k"]) * int(row["m"]) * int(row["nh"]) * int(row["nw"])
                / int(row["t"])
            )
            if abs(expected_mac_per_cycle - mac_per_cycle) > 1.0e-9:
                raise ValueError(
                    f"{target}: manifest MAC/cycle is {mac_per_cycle:g}, "
                    f"but K*M*NH*NW/T is {expected_mac_per_cycle:g}"
                )
        power_rpt = run_dir / "reports" / "power.rpt"
        if not power_rpt.exists():
            power_rpt = run_dir / "power.rpt"
        invalid_marker = run_dir / "INVALID_RUN"
        if invalid_marker.exists():
            reason = invalid_marker.read_text(errors="replace").strip().replace("\n", " ")
            warnings.append(f"skip {run_dir}: explicitly invalid run: {reason}")
            continue
        if not run_dir.is_dir():
            warnings.append(f"skip {target}/{run}: retained APR run is missing")
            continue
        if not power_rpt.exists():
            warnings.append(f"skip {target}/{run}: missing PrimeTime power report")
            continue

        die_area_um2, def_path = parse_def_area(run_dir)
        pin_placement = parse_def_pin_placement(def_path)
        if pin_placement is None:
            total_pins, assigned_pins = 0, 0
        else:
            total_pins, assigned_pins = pin_placement

        apr_log = run_dir / "apr.log"
        if not apr_log.exists():
            warnings.append(f"skip {target}/{run}: missing apr.log")
            continue
        apr_errors = [
            line.strip()
            for line in apr_log.read_text(errors="replace").splitlines()
            if "**ERROR:" in line or line.startswith("ERROR:")
        ]
        if apr_errors:
            warnings.append(
                f"skip {target}/{run}: APR error: {apr_errors[0]}"
            )
            continue

        apr_netlists = sorted((run_dir / "outputs").glob("*.apr.v"))
        if not apr_netlists:
            warnings.append(f"skip {target}/{run}: missing routed APR netlist")
            continue
        if any(not netlist_interfaces_clean(path) for path in apr_netlists):
            warnings.append(
                f"skip {target}/{run}: routed netlist has omitted module ports"
            )
            continue

        geometry_clean = parse_geometry_clean(run_dir)
        if geometry_clean is False:
            warnings.append(f"skip {target}/{run}: physical DRC violations")
            continue
        if geometry_clean is None and not args.allow_missing_geometry:
            warnings.append(f"skip {target}/{run}: missing final DRC report")
            continue

        setup_wns_ns, hold_wns_ns = parse_timing_wns(run_dir)
        if setup_wns_ns is None or hold_wns_ns is None:
            if not args.allow_missing_timing:
                warnings.append(
                    f"skip {target}/{run}: missing final post-route setup/hold WNS"
                )
                continue
        elif setup_wns_ns < 0.0 or hold_wns_ns < 0.0:
            warnings.append(
                f"skip {target}/{run}: negative post-route WNS "
                f"(setup={setup_wns_ns:.3f} ns, hold={hold_wns_ns:.3f} ns)"
            )
            continue

        try:
            groups_mw, total_mw = parse_power_report(power_rpt)
        except ValueError as exc:
            warnings.append(str(exc))
            continue

        saif_period, saif_duration, saif_path = parse_saif_header(run_dir)
        if saif_period is None and not args.allow_missing_saif_header:
            warnings.append(f"skip {target}/{run}: missing reports/saif_header.rpt")
            continue
        if (
            not args.allow_stale_power
            and saif_path is not None
            and saif_path.exists()
            and power_rpt.stat().st_mtime < saif_path.stat().st_mtime
        ):
            warnings.append(
                f"skip {target}/{run}: power report predates referenced SAIF; "
                "rerun PT-PX"
            )
            continue
        if (
            saif_period is not None
            and not args.allow_period_mismatch
            and abs(saif_period - args.period_ns) > 1e-6
        ):
            warnings.append(
                f"skip {target}/{run}: SAIF TARGET_PERIOD {saif_period:g} ns "
                f"!= requested {args.period_ns:g} ns"
            )
            continue

        saif_lines = _saif_lines(saif_path, None)
        saif_tx_pct, saif_tc_sum = parse_saif_activity(saif_path, saif_lines)
        saif_clock_tc, _ = parse_saif_stimulus_tc(saif_path, saif_lines)
        saif_quantum_pct = parse_saif_reporting_quantum_pct(saif_path, saif_lines)
        saif_nonpersistent_tx_pct, saif_persistent_tx_signals = (
            parse_saif_nonpersistent_tx(saif_path, saif_lines)
        )
        saif_observed_period_ns = None
        if saif_duration is not None and saif_clock_tc is not None and saif_clock_tc > 0.0:
            saif_observed_period_ns = 2.0 * saif_duration / saif_clock_tc
        if (
            not args.allow_period_mismatch
            and (
                saif_observed_period_ns is None
                or abs(saif_observed_period_ns - args.period_ns) > 0.01
            )
        ):
            observed = (
                "unavailable"
                if saif_observed_period_ns is None
                else f"{saif_observed_period_ns:.6f} ns"
            )
            warnings.append(
                f"skip {target}/{run}: observed SAIF clock period {observed} "
                f"!= requested {args.period_ns:g} ns"
            )
            continue

        unknown_error = saif_unknown_activity_error(
            saif_nonpersistent_tx_pct,
            saif_persistent_tx_signals,
            saif_quantum_pct,
        )
        if unknown_error is not None:
            warnings.append(
                f"skip {target}/{run}: invalid SAIF unknown activity: "
                f"{unknown_error} ({saif_path})"
            )
            continue
        if (
            args.max_saif_tx_pct >= 0.0
            and saif_tx_pct is not None
            and saif_tx_pct > args.max_saif_tx_pct
        ):
            warnings.append(
                f"skip {target}/{run}: SAIF aggregate unknown time {saif_tx_pct:.2f}% "
                f"> allowed {args.max_saif_tx_pct:.2f}% ({saif_path})"
            )
            continue

        saif_acc_tx_pct = (
            parse_saif_acc_tx(saif_path, saif_lines) if kind == "sc" else None
        )
        if kind == "sc" and saif_acc_tx_pct is None:
            warnings.append(
                f"skip {target}/{run}: no SC accumulator output activity "
                f"found in {saif_path}"
            )
            continue
        if (
            kind == "sc"
            and args.max_saif_acc_tx_pct >= 0.0
            and saif_acc_tx_pct is not None
            and saif_acc_tx_pct
            > args.max_saif_acc_tx_pct + (saif_quantum_pct or 0.0) + 1.0e-12
        ):
            warnings.append(
                f"skip {target}/{run}: accumulator SAIF TX "
                f"{saif_acc_tx_pct:.9f}% > one reporter quantum + allowed "
                f"extra {args.max_saif_acc_tx_pct:.9f}% ({saif_path})"
            )
            continue

        saif_output_tx_pct = (
            parse_saif_binary_output_tx(saif_path, saif_lines)
            if kind == "binary"
            else None
        )
        if kind == "binary" and saif_output_tx_pct is None:
            warnings.append(
                f"skip {target}/{run}: no top-level binary architectural output "
                f"activity found in {saif_path}"
            )
            continue
        if (
            kind == "binary"
            and args.max_saif_binary_output_tx_pct >= 0.0
            and saif_output_tx_pct is not None
            and saif_output_tx_pct
            > args.max_saif_binary_output_tx_pct + (saif_quantum_pct or 0.0) + 1.0e-12
        ):
            warnings.append(
                f"skip {target}/{run}: binary output SAIF TX {saif_output_tx_pct:.6f}% "
                f"> one reporter quantum + allowed extra "
                f"{args.max_saif_binary_output_tx_pct:.6f}% ({saif_path})"
            )
            continue

        saif_file_pct, saif_not_pct = parse_saif_coverage(run_dir)
        cell_area_um2, place_area_um2, placement_density_pct = parse_placement_area(run_dir)

        record = RunRecord(
            target=target,
            run=run,
            run_dir=run_dir,
            power_rpt=power_rpt,
            groups_mw=groups_mw,
            total_mw=total_mw,
            mac_per_cycle=mac_per_cycle,
            label=label,
            kind=kind,
            die_area_um2=die_area_um2,
            def_path=def_path,
            io_pins_total=total_pins,
            io_pins_assigned=assigned_pins,
            saif_target_period_ns=saif_period,
            saif_observed_period_ns=saif_observed_period_ns,
            saif_duration_ns=saif_duration,
            saif_path=saif_path,
            saif_file_pct=saif_file_pct,
            saif_not_annotated_pct=saif_not_pct,
            saif_tx_pct=saif_tx_pct,
            saif_acc_tx_pct=saif_acc_tx_pct,
            saif_output_tx_pct=saif_output_tx_pct,
            saif_nonpersistent_tx_pct=saif_nonpersistent_tx_pct,
            saif_persistent_tx_signals=saif_persistent_tx_signals,
            saif_tc_sum=saif_tc_sum,
            cell_area_um2=cell_area_um2,
            place_area_um2=place_area_um2,
            placement_density_pct=placement_density_pct,
            setup_wns_ns=setup_wns_ns,
            hold_wns_ns=hold_wns_ns,
            reg_clkpin_mw=parse_clock_split(run_dir),
        )
        add_derived_metrics(record, args.period_ns)
        candidates.append(record)

    candidates.sort(key=lambda r: (r.total_pj_per_mac, r.kind, r.label, r.run))

    for record in candidates:
        if record.reg_clkpin_mw is None:
            warnings.append(
                f"no clock-pin split for {record.target}/{record.run}: "
                "reports/power_clock_split.rpt missing — plotted 'Sequential'/'Clock "
                "distribution' are UNCORRECTED raw register/clock_network for this run "
                "(re-run power to generate it)"
            )
    return candidates, warnings


def corrected_buckets_mw(
    groups_mw: dict[str, float], reg_clkpin_mw: float | None
) -> dict[str, float]:
    """Clock-pin-corrected power buckets (mW) from PT's raw power groups.

    Moves the register clock-pin internal power out of clock_network and into a
    "sequential" bucket. Falls back to the raw register/clock split (clock-pin
    NOT corrected) when reg_clkpin_mw is None. combinational is unchanged, and
    the three buckets still sum to combinational+register+clock_network.
    """
    clkpin = reg_clkpin_mw or 0.0
    comb = groups_mw.get("combinational", 0.0)
    reg = groups_mw.get("register", 0.0)
    clk = groups_mw.get("clock_network", 0.0)
    return {
        "combinational": comb,
        "sequential": reg + clkpin,
        "clock_dist": max(0.0, clk - clkpin),
    }


def add_derived_metrics(record: RunRecord, period_ns: float) -> None:
    record.buckets_mw = corrected_buckets_mw(record.groups_mw, record.reg_clkpin_mw)

    pj_by_group: dict[str, float] = {}
    known_sum_mw = 0.0
    for key, _, _ in POWER_GROUP_ORDER:
        if key == "other":
            continue
        mw = record.buckets_mw.get(key, 0.0)
        known_sum_mw += mw
        pj_by_group[key] = mw * period_ns / record.mac_per_cycle

    other_mw = max(0.0, record.total_mw - known_sum_mw)
    pj_by_group["other"] = other_mw * period_ns / record.mac_per_cycle
    record.energy_pj_by_group = pj_by_group
    record.total_pj_per_mac = record.total_mw * period_ns / record.mac_per_cycle

    if record.die_area_um2 and record.die_area_um2 > 0:
        area_mm2 = record.die_area_um2 / 1e6
        record.mac_per_cycle_per_mm2 = record.mac_per_cycle / area_mm2
        record.gmac_s_per_mm2 = record.mac_per_cycle_per_mm2 / period_ns


def repo_path(path: Path | None, repo_root: Path) -> str:
    if path is None:
        return ""
    try:
        return str(path.resolve().relative_to(repo_root.resolve()))
    except ValueError:
        return str(path)


def write_csv(records: Iterable[RunRecord], path: Path, repo_root: Path) -> None:
    fieldnames = [
        "label",
        "kind",
        "target",
        "run",
        "run_dir",
        "power_rpt",
        "def_path",
        "io_pins_total",
        "io_pins_assigned",
        "mac_per_cycle",
        "power_mw",
        "pj_per_mac",
        # clock-pin-corrected energy buckets (what the plot stacks)
        "comb_pj_per_mac",
        "sequential_pj_per_mac",
        "clock_dist_pj_per_mac",
        "other_pj_per_mac",
        # clock-pin-corrected power buckets (mW)
        "comb_mw",
        "sequential_mw",
        "clock_dist_mw",
        "other_mw",
        # raw PrimeTime power groups (mW) + the clock-pin power moved reg<-clock
        "register_group_mw",
        "clock_network_mw",
        "reg_clkpin_mw",
        "clock_pin_corrected",
        "die_area_um2",
        "cell_area_um2",
        "place_area_um2",
        "placement_density_pct",
        "setup_wns_ns",
        "hold_wns_ns",
        "mac_per_cycle_per_mm2",
        "gmac_s_per_mm2",
        "saif_target_period_ns",
        "saif_observed_period_ns",
        "saif_duration_ns",
        "saif_path",
        "saif_file_pct",
        "saif_not_annotated_pct",
        "saif_tx_pct",
        "saif_acc_tx_pct",
        "saif_output_tx_pct",
        "saif_nonpersistent_tx_pct",
        "saif_persistent_tx_signals",
        "saif_tc_sum",
    ]
    with path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for r in records:
            known_mw = (
                r.groups_mw.get("combinational", 0.0)
                + r.groups_mw.get("register", 0.0)
                + r.groups_mw.get("clock_network", 0.0)
            )
            writer.writerow(
                {
                    "label": r.label,
                    "kind": r.kind,
                    "target": r.target,
                    "run": r.run,
                    "run_dir": repo_path(r.run_dir, repo_root),
                    "power_rpt": repo_path(r.power_rpt, repo_root),
                    "def_path": repo_path(r.def_path, repo_root),
                    "io_pins_total": r.io_pins_total,
                    "io_pins_assigned": r.io_pins_assigned,
                    "mac_per_cycle": r.mac_per_cycle,
                    "power_mw": r.total_mw,
                    "pj_per_mac": r.total_pj_per_mac,
                    "comb_pj_per_mac": r.energy_pj_by_group.get("combinational", 0.0),
                    "sequential_pj_per_mac": r.energy_pj_by_group.get("sequential", 0.0),
                    "clock_dist_pj_per_mac": r.energy_pj_by_group.get("clock_dist", 0.0),
                    "other_pj_per_mac": r.energy_pj_by_group.get("other", 0.0),
                    "comb_mw": r.buckets_mw.get("combinational", 0.0),
                    "sequential_mw": r.buckets_mw.get("sequential", 0.0),
                    "clock_dist_mw": r.buckets_mw.get("clock_dist", 0.0),
                    "other_mw": max(0.0, r.total_mw - known_mw),
                    "register_group_mw": r.groups_mw.get("register", 0.0),
                    "clock_network_mw": r.groups_mw.get("clock_network", 0.0),
                    "reg_clkpin_mw": r.reg_clkpin_mw if r.reg_clkpin_mw is not None else "",
                    "clock_pin_corrected": r.reg_clkpin_mw is not None,
                    "die_area_um2": r.die_area_um2 if r.die_area_um2 is not None else "",
                    "cell_area_um2": r.cell_area_um2 if r.cell_area_um2 is not None else "",
                    "place_area_um2": r.place_area_um2 if r.place_area_um2 is not None else "",
                    "placement_density_pct": (
                        r.placement_density_pct if r.placement_density_pct is not None else ""
                    ),
                    "setup_wns_ns": r.setup_wns_ns if r.setup_wns_ns is not None else "",
                    "hold_wns_ns": r.hold_wns_ns if r.hold_wns_ns is not None else "",
                    "mac_per_cycle_per_mm2": (
                        r.mac_per_cycle_per_mm2
                        if not math.isnan(r.mac_per_cycle_per_mm2)
                        else ""
                    ),
                    "gmac_s_per_mm2": (
                        r.gmac_s_per_mm2 if not math.isnan(r.gmac_s_per_mm2) else ""
                    ),
                    "saif_target_period_ns": (
                        r.saif_target_period_ns if r.saif_target_period_ns is not None else ""
                    ),
                    "saif_observed_period_ns": (
                        r.saif_observed_period_ns
                        if r.saif_observed_period_ns is not None
                        else ""
                    ),
                    "saif_duration_ns": r.saif_duration_ns if r.saif_duration_ns is not None else "",
                    "saif_path": repo_path(r.saif_path, repo_root),
                    "saif_file_pct": r.saif_file_pct if r.saif_file_pct is not None else "",
                    "saif_not_annotated_pct": (
                        r.saif_not_annotated_pct
                        if r.saif_not_annotated_pct is not None
                        else ""
                    ),
                    "saif_tx_pct": r.saif_tx_pct if r.saif_tx_pct is not None else "",
                    "saif_acc_tx_pct": (
                        r.saif_acc_tx_pct if r.saif_acc_tx_pct is not None else ""
                    ),
                    "saif_output_tx_pct": (
                        r.saif_output_tx_pct if r.saif_output_tx_pct is not None else ""
                    ),
                    "saif_nonpersistent_tx_pct": (
                        r.saif_nonpersistent_tx_pct
                        if r.saif_nonpersistent_tx_pct is not None
                        else ""
                    ),
                    "saif_persistent_tx_signals": (
                        r.saif_persistent_tx_signals
                        if r.saif_persistent_tx_signals is not None
                        else ""
                    ),
                    "saif_tc_sum": r.saif_tc_sum if r.saif_tc_sum is not None else "",
                }
            )


def plot_records(
    records: list[RunRecord],
    path: Path,
    period_ns: float,
    max_label_len: int,
    title_suffix: str = "",
) -> None:
    if not records:
        return

    labels = [wrap_label(r.label, max_label_len) for r in records]
    y = list(range(len(records)))
    fig_height = max(5.5, 0.46 * len(records) + 2.7)

    fig, axes = plt.subplots(
        1,
        3,
        figsize=(16.0, fig_height),
        sharey=True,
        gridspec_kw={"width_ratios": [2.35, 1.05, 1.15]},
    )
    ax_energy, ax_area, ax_density = axes

    left = [0.0 for _ in records]
    for key, label, color in POWER_GROUP_ORDER:
        vals = [r.energy_pj_by_group.get(key, 0.0) for r in records]
        ax_energy.barh(y, vals, left=left, color=color, edgecolor="white", linewidth=0.6, label=label)
        left = [a + b for a, b in zip(left, vals)]

    max_energy = max(r.total_pj_per_mac for r in records)
    for i, r in enumerate(records):
        ax_energy.text(
            r.total_pj_per_mac + max_energy * 0.012,
            i,
            f"{r.total_pj_per_mac:.3g}",
            va="center",
            ha="left",
            fontsize=8.0,
            fontweight="bold",
            color="#222222",
        )

    area_vals = [(r.die_area_um2 or 0.0) / 1000.0 for r in records]
    ax_area.barh(y, area_vals, color="#6A7D8F", edgecolor="white", linewidth=0.6)
    max_area = max(area_vals) if area_vals else 0.0
    for i, v in enumerate(area_vals):
        if v > 0:
            ax_area.text(v + max_area * 0.015, i, f"{v:.1f}", va="center", ha="left", fontsize=7.6)

    density_vals = [
        0.0 if math.isnan(r.gmac_s_per_mm2) else r.gmac_s_per_mm2 for r in records
    ]
    ax_density.barh(y, density_vals, color="#5F8A58", edgecolor="white", linewidth=0.6)
    max_density = max(density_vals) if density_vals else 0.0
    for i, v in enumerate(density_vals):
        if v > 0:
            ax_density.text(v + max_density * 0.015, i, f"{v:.0f}", va="center", ha="left", fontsize=7.6)

    ax_energy.set_yticks(y)
    ax_energy.set_yticklabels(labels, fontsize=8.1)
    ax_energy.invert_yaxis()
    ax_energy.set_xlabel("Energy per MAC (pJ/MAC)")
    ax_area.set_xlabel("Die area (k um2)")
    ax_density.set_xlabel(f"Throughput density (GMAC/s/mm2 @ {1000.0 / period_ns:.0f} MHz)")

    ax_energy.set_xlim(0, max_energy * 1.17)
    ax_area.set_xlim(0, max_area * 1.22 if max_area > 0 else 1.0)
    ax_density.set_xlim(0, max_density * 1.24 if max_density > 0 else 1.0)

    for ax in axes:
        ax.grid(axis="x", linestyle=":", linewidth=0.5, color="#B0AAA0", alpha=0.65)
        ax.set_axisbelow(True)
        ax.tick_params(axis="x", labelsize=8.0)
        for spine in ("top", "right"):
            ax.spines[spine].set_visible(False)
        ax.spines["left"].set_color("#666666")
        ax.spines["bottom"].set_color("#666666")

    ax_energy.legend(
        loc="lower center",
        bbox_to_anchor=(0.5, 1.01),
        ncol=4,
        frameon=False,
        fontsize=8.2,
        handlelength=1.3,
        columnspacing=1.0,
    )
    fig.suptitle(
        "Area and energy breakdown from APR/PT reports "
        f"({period_ns:g} ns, clock-pin corrected){title_suffix}",
        x=0.01,
        y=0.995,
        ha="left",
        fontsize=12.5,
        fontweight="bold",
    )
    fig.tight_layout(rect=(0.0, 0.0, 1.0, 0.965))
    fig.savefig(path, dpi=170, bbox_inches="tight", facecolor="white")
    plt.close(fig)


def print_summary(
    records: list[RunRecord], warnings: list[str], verbose_skips: bool
) -> None:
    print(f"selected {len(records)} MAC-capable APR/PT run(s)")
    print(
        f"{'design':34s} {'pJ/MAC':>9s} {'mW':>8s} {'MAC/cy':>8s} "
        f"{'area_um2':>10s} {'GMAC/mm2':>10s} {'period':>7s} "
        f"{'rawX%':>7s} {'archX%':>8s}"
    )
    print("-" * 113)
    for r in records:
        period = "" if r.saif_target_period_ns is None else f"{r.saif_target_period_ns:g}"
        tx_pct = "" if r.saif_tx_pct is None else f"{r.saif_tx_pct:.2f}"
        arch_tx_value = r.saif_output_tx_pct if r.kind == "binary" else r.saif_acc_tx_pct
        arch_tx_pct = "" if arch_tx_value is None else f"{arch_tx_value:.2f}"
        area = "" if r.die_area_um2 is None else f"{r.die_area_um2:.0f}"
        density = "" if math.isnan(r.gmac_s_per_mm2) else f"{r.gmac_s_per_mm2:.1f}"
        print(
            f"{r.label[:34]:34s} {r.total_pj_per_mac:9.3f} {r.total_mw:8.3f} "
            f"{r.mac_per_cycle:8.2f} {area:>10s} {density:>10s} {period:>7s} "
            f"{tx_pct:>7s} {arch_tx_pct:>8s}"
        )

    skipped = [warning for warning in warnings if warning.startswith("skip ")]
    other_warnings = [warning for warning in warnings if not warning.startswith("skip ")]
    if other_warnings:
        print()
        print("warnings:")
        for warning in other_warnings:
            print(f"  - {warning}")
    if skipped:
        print()
        print(f"excluded {len(skipped)} run(s); see the generated exclusions file")
        if verbose_skips:
            for warning in skipped:
                print(f"  - {warning}")


def main() -> None:
    args = parse_args()
    args.out_dir.mkdir(parents=True, exist_ok=True)
    records, warnings = build_records(args)

    tech_l = args.tech.lower()
    csv_path = args.out_dir / f"{args.prefix}_{tech_l}.csv"
    png_path = args.out_dir / f"{args.prefix}_{tech_l}.png"
    excluded_path = args.out_dir / f"{args.prefix}_{tech_l}_excluded.txt"
    write_csv(records, csv_path, args.repo_root)
    plot_records(records, png_path, args.period_ns, args.max_label_len)
    excluded = [warning for warning in warnings if warning.startswith("skip ")]
    excluded_path.write_text(
        "# Strict APR/PT runs excluded from the generated results\n"
        + "\n".join(excluded)
        + ("\n" if excluded else "")
    )

    zoom_records = [r for r in records if r.total_pj_per_mac <= args.zoom_pj_max]
    if 0 < len(zoom_records) < len(records):
        zoom_path = args.out_dir / f"{args.prefix}_{tech_l}_zoom.png"
        plot_records(
            zoom_records,
            zoom_path,
            args.period_ns,
            args.max_label_len,
            title_suffix=f" - <= {args.zoom_pj_max:g} pJ/MAC",
        )
        print(f"wrote {zoom_path}")

    print(f"wrote {csv_path}")
    print(f"wrote {png_path}")
    print(f"wrote {excluded_path}")
    print()
    print_summary(records, warnings, args.verbose_skips)


if __name__ == "__main__":
    main()
