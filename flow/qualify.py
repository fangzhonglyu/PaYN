#!/usr/bin/env python3
"""Qualification gates for PaYN routes, gate-level simulations, SAIFs and PrimeTime power runs.

A measured number is quoted only when every artifact behind it passes its gate here.  Each subcommand reads
tool outputs, prints its verdict and exits 0 on PASS, nonzero otherwise; the JSON records it writes are the
evidence kept beside the run.  Every gate fails closed: a missing, truncated or unrecognized report rejects.

  routed-apr       routed design: Innovus ended cleanly, outputs written, no geometry/antenna/connectivity/
                   placement violation, setup and hold met.  Default rules read the report files; --stage
                   reads the Innovus log's final checks (bootstrap: an activity-seed route may keep markers)
  routed-gl        routed GL log: max-corner SDF annotated without errors, every SDF diagnostic understood,
                   no timing-check violation at or after reset completion; opt-in approvals are itemized
  gl-audit         routed-gl strict first; approvals only after a strict failure and only with a rationale
                   file citing each one; every outcome is appended to a record
  syn-gl           post-synthesis GL timing view: a routed-gl verdict whose only rejection is SDFCOM_CFTC on
                   DFFRPQ async-reset removal checks
  saif-sc          SC power SAIF: X-free accumulator, transient X within one reporter quantum, clock period,
                   enough clock and operand toggles
  saif-binary      binary power SAIF: X-free architectural outputs, transient X, clock period
  saif-int         INT-mode SAIF of payn_array: SC side held quiet, int_mode high, bypass transparent per bit
  pt-coverage      PT-PX run: every net annotated from the SAIF or by the explicit pinless policy, complete
                   pin-to-pin parasitics
  sdf-clock        routed SDF: every clock gate's CK->ECK well below the period; the GL run used this SDF
  ideal-clock-sdf  writes the ideal-clock view of a synthesis SDF (ICG IOPATHs zeroed) for pre-CTS GL
  basin            routed single-PE layout: tile-grid correlation and product-AND operand skew (PrimeTime,
                   tcl/pt_basin_skew.tcl) decide grid vs collapsed basin; top-level pins fixed as planned

Why gates and not eyeballing: persistent X on a live net, an unannotated SDF arc, a default-activity net or a
collapsed placement stops neither the simulation nor the power report, but each silently changes the number.
Functional correctness itself is established by the output-checking benches; these gates protect the
measurement.  Persistent X on dead nets is reported, not rejected (--strict-persistent-x restores rejection).
"""
from __future__ import annotations

import argparse
import collections
import csv
import datetime
import json
import math
import os
import re
import shlex
import shutil
import statistics
import subprocess
import sys
from pathlib import Path

FLOW = Path(__file__).resolve().parent
EDA_MODULES = ("synopsys-lib-compiler/2022.03-SP3", "synopsys-synth/2021.06-SP1", "primetime/2021.06-SP1",
               "vcs/2020.12-SP2-1", "innovus/21.14.000", "genus/21.14.000")


class QualifyError(ValueError):
    """A gate's rejection; the message names the failed criterion."""


def require(condition, message: str) -> None:
    if not condition:
        raise QualifyError(message)


def emit_json(result: dict, json_path: Path | None) -> None:
    """Print a result as indented JSON and, if asked, write the same text to a file."""
    text = json.dumps(result, indent=2) + "\n"
    if json_path:
        json_path.write_text(text)
    print(text, end="")


# ------------------------------------------------------------------------------------------- routed APR --

MESSAGE_SUMMARY_RE = re.compile(r"Message Summary:\s*\d+ warning\(s\),\s*(\d+) error\(s\)")
INNOVUS_ERROR_RE = re.compile(r"\*\*\s*ERROR:|(?m:^\s*(?:ERROR|Error):)")
CONNECTIVITY_RE = re.compile(r"\*+ Start: VERIFY CONNECTIVITY \*+(.*?)\*+ End: VERIFY CONNECTIVITY \*+", re.S)
PLACEMENT_CHECK_RE = re.compile(r"Begin checking placement.*?Finished checkPlace[^\n]*", re.S)


def require_nonempty(path: Path, what: str) -> None:
    require(path.is_file() and path.stat().st_size, f"missing {what} {path}")


def innovus_ended_cleanly(log: str) -> None:
    require('--- Ending "Innovus"' in log, "missing normal Innovus termination")
    errors = MESSAGE_SUMMARY_RE.findall(log)
    require(errors and all(int(n) == 0 for n in errors), "Innovus reported errors or lacks an error summary")
    require(not INNOVUS_ERROR_RE.search(log), "Innovus error diagnostic present")


def route_outputs(route: Path, top: str) -> None:
    for suffix in ("apr.v", "apr.sdf", "spef"):
        require_nonempty(route / "outputs" / f"{top}.{suffix}", "APR output")


def route_slacks(route: Path) -> dict[str, float]:
    slacks = {}
    for kind in ("setup", "hold"):
        match = re.search(r"Slack Time\s*([-+0-9.]+)", (route / "reports" / f"{kind}.rpt").read_text())
        require(match, f"missing {kind} slack")
        require(float(match[1]) >= 0, f"{kind} timing violation {match[1]}")
        slacks[f"{kind}_wns_ns"] = float(match[1])
    return slacks


def last_placement_check(log: str) -> re.Match:
    checks = list(PLACEMENT_CHECK_RE.finditer(log))
    require(checks, "missing final placement check")
    return checks[-1]


def report_clean(text: str, count_re: str, clean_re: str) -> bool:
    """A violation report is clean if its total is 0, or it has no total and states it found none."""
    count = re.search(count_re, text)
    return (not count or int(count[1]) == 0) and bool(count or re.search(clean_re, text))


def audit_route_reports(route: Path, top: str) -> dict:
    """Report-file rules: geometry/antenna reports, the last checkPlace in the log, the area report."""
    log = (route / "apr.log").read_text(errors="replace")
    require("Innovus script finished" in log or "CHECKPOINT_REPAIR_COMPLETE" in log, "missing flow completion")
    innovus_ended_cleanly(log)
    route_outputs(route, top)
    require(report_clean((route / f"{top}.geom.rpt").read_text(), r"Total Violations\s*:\s*(\d+)",
                         r"(?m)^No DRC violations were found\s*$"), "geometry violations")
    require(report_clean((route / f"{top}.antenna.rpt").read_text(),
                         r"Total number of process antenna violations:\s*(\d+)", r"(?m)^No Violations Found\s*$"),
            "antenna violations")
    connectivity = CONNECTIVITY_RE.findall(log)
    require(connectivity and "Found no problems or warnings." in connectivity[-1], "connectivity failed")
    last = last_placement_check(log)
    unplaced = re.search(r"Unplaced\s*=\s*(\d+)", last[0])
    require(unplaced and int(unplaced[1]) == 0, "unplaced instances")
    require(not re.findall(r"^([^*\n]+):\s*([1-9]\d*)\s*$", last[0], re.M) and "NRDB-2082" not in log[last.end():],
            "placement violations")
    result = dict(status="PASS", geometry_drc=0, antenna_violations=0, connectivity_violations=0,
                  placement_violations=0)
    result.update(route_slacks(route))
    rows = [f for f in (line.split() for line in (route / "reports/area.rpt").read_text().splitlines())
            if f and f[0] == top]
    require(len(rows) == 1, f"expected one {top} row in reports/area.rpt, found {len(rows)}")
    result["area_um2"] = float(rows[0][2])
    require(result["area_um2"] > 0, "zero design area")
    return result


def audit_route_log(route: Path, top: str, stage: str) -> dict:
    """Innovus-log rules: the final verifyGeometry/verifyConnectivity/verifyProcessAntenna counts and checkPlace.

    A bootstrap route only seeds switching activity for the independent final APR, so it may keep geometry or
    antenna markers and placement overlaps; connectivity, timing and a clean Innovus run are still required.
    """
    route_outputs(route, top)
    log = (route / "apr.log").read_text(errors="replace")
    require("Innovus script finished" in log or "POP_COUNT_CHECKPOINT_REPAIR_COMPLETE" in log,
            "missing APR or checkpoint-repair completion")
    innovus_ended_cleanly(log)
    for name in (f"{top}.syn.sdc", "reports/area.rpt"):
        require_nonempty(route / name, "APR input/report")
    drc = re.findall(r"Verification Complete\s*:\s*(\d+) Viols\.", log)   # [-2] geometry, [-1] connectivity
    antenna = re.findall(r"Verification Complete:\s*(\d+) Violations", log)
    connectivity = CONNECTIVITY_RE.findall(log)
    require(len(drc) >= 2 and antenna and connectivity, "missing final physical checks")
    final = stage == "final"
    require(not final or int(drc[-2]) == 0, f"final geometry DRC {drc[-2]}")
    require(int(drc[-1]) == 0 and "Found no problems or warnings." in connectivity[-1], "final connectivity failed")
    require(not final or int(antenna[-1]) == 0, f"final antenna violations {antenna[-1]}")
    slacks = route_slacks(route)
    last = last_placement_check(log)
    overlap = re.search(r"Overlapping with other instance:\s*(\d+)", last[0])
    overlaps = int(overlap[1]) if overlap else 0
    late_overlap = "NRDB-2082" in log[last.end():]
    require(not final or (overlaps == 0 and not late_overlap),
            f"final placement overlaps: instances={overlaps}, later_router_warning={late_overlap}")
    return dict(slacks, geometry_drc=int(drc[-2]), connectivity_violations=0, antenna_violations=int(antenna[-1]),
                placement_overlapping_instances=overlaps, placement_late_overlap_warning=late_overlap,
                qualification=stage)


def cmd_routed_apr(args) -> int:
    try:
        if args.stage:
            result = audit_route_log(args.route, args.top, args.stage)
        else:
            result = audit_route_reports(args.route, args.top)
    except (QualifyError, OSError) as error:
        raise SystemExit(f"route not qualified: {error}")
    if args.stage:
        if args.json_path:
            args.json_path.write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps(result))
    else:
        emit_json(result, args.json_path)
    return 0


# -------------------------------------------------------------------------------------------- routed GL --

DEFAULT_WORKLOAD_PASS = "PASS: streaming SC SAIF captured; 384 batches x 8 cycles"
TIMING_CHECK = r"\$(?:setuphold|recrem|setup|hold|width|period|recovery|removal|skew|timeskew|fullskew|nochange)"
SDF_CITE_RE = re.compile(r"(\S+\.sdf), (\d+)")
RATIONALE_NAME = "gl_validator_args_rationale.txt"
RECORD_NAME = "gl_validator_args.txt"


def warning_blocks(text: str, category: str) -> list[str]:
    """Bodies of every VCS 'Warning-[category]' diagnostic (up to the next blank line)."""
    return re.findall(rf"Warning-\[{category}\](.*?)(?=\n\s*\n|\Z)", text, re.S)


class SdfLines:
    """SDF files cited by VCS diagnostics, each read once."""

    def __init__(self) -> None:
        self.files: dict[str, list[str]] = {}

    def line(self, path: str, line_no: int) -> str:
        if path not in self.files:
            self.files[path] = Path(path).read_text(errors="replace").splitlines()
        return self.files[path][line_no - 1]


def approve_negative_iopath(text: str, max_ps: float, sdf: SdfLines, reasons: list[str]) -> list[dict]:
    """Opt-in: accept SDFCOM_NDI only for small negative IOPATH delays.

    VCS clamps a negative IOPATH delay to zero (and cannot honor it on a COND path even with -negdelay).  Each
    diagnostic must cite an SDF file and line; that line must be an IOPATH entry whose negative values are all no
    more negative than -max_ps.  Every approved clamp is returned for the qualification record.
    """
    approved = []
    for block in warning_blocks(text, "SDFCOM_NDI"):
        where = SDF_CITE_RE.search(block)
        inst = re.search(r'instance:\s*([^"\s]+)', block)
        if not where or not inst:
            reasons.append("SDFCOM_NDI diagnostic lacks SDF file/line or instance")
            continue
        path, line_no = where[1], int(where[2])
        try:
            line = sdf.line(path, line_no)
        except (OSError, IndexError):
            reasons.append(f"SDFCOM_NDI cites unreadable SDF line {path}:{line_no}")
            continue
        negatives = [float(x) for x in re.findall(r"(-\d+(?:\.\d+)?)", line)]
        if "IOPATH" not in line or not negatives:
            reasons.append(f"SDFCOM_NDI at {path}:{line_no} is not a negative IOPATH entry")
            continue
        worst_ps = min(negatives) * 1000.0
        if worst_ps < -max_ps:
            reasons.append(f"SDFCOM_NDI at {path}:{line_no} is {worst_ps:.1f} ps, beyond -{max_ps} ps")
            continue
        approved.append({"instance": inst[1], "sdf": path, "line": line_no,
                         "entry": " ".join(line.split()), "most_negative_ps": worst_ps})
    return approved


def approve_annotated_interconnect(text: str, sdf: SdfLines, reasons: list[str]) -> list[dict]:
    """Opt-in: accept SDFCOM_IWSBA only where VCS still annotates the delay.

    Innovus can write a netlist `assign` alias between a flop output and a port net.  VCS then warns that the SDF
    INTERCONNECT crosses that continuous assignment or instance boundary, and states that the interconnect is
    still annotated.  Each diagnostic must carry that statement, name the source and destination pins, and cite
    an SDF line that is a non-negative INTERCONNECT entry.  Every approval is returned.
    """
    approved = []
    for block in warning_blocks(text, "SDFCOM_IWSBA"):
        where = SDF_CITE_RE.search(block)
        pins = re.search(r"INTERCONNECT from\s+(\S+)\s+to\s+(\S+)\s+has (Continuous Assignment|Instance) at"
                         r"\s+(\S+?):(\d+)", block)
        if "INTERCONNECT will still be annotated" not in block or not where or not pins:
            reasons.append("SDFCOM_IWSBA diagnostic lacks the annotated-interconnect statement, SDF line or pins")
            continue
        path, line_no = where[1], int(where[2])
        try:
            line = sdf.line(path, line_no)
        except (OSError, IndexError):
            reasons.append(f"SDFCOM_IWSBA cites unreadable SDF line {path}:{line_no}")
            continue
        if not line.lstrip().startswith("(INTERCONNECT") or re.search(r"\(-|:-", line):
            reasons.append(f"SDFCOM_IWSBA at {path}:{line_no} is not a non-negative INTERCONNECT entry")
            continue
        approved.append({"sdf": path, "line": line_no, "entry": " ".join(line.split()),
                         "source": pins[1], "destination": pins[2], "netlist_object": pins[3],
                         "netlist": f"{pins[4]}:{pins[5]}"})
    return approved


def audit_routed_gl(text: str, expected_pass: str = DEFAULT_WORKLOAD_PASS,
                    approve_negative_iopath_clamp_ps: float | None = None,
                    approve_iwsba: bool = False) -> dict:
    """Timing qualification of one GL simulation log (VCS compile + run output, +sdfverbose)."""
    text = re.sub(r"\x1b\[[0-9;]*m", "", text)
    reasons: list[str] = []
    if "sdf corner = max" not in text or "[INFO] $sdf_annotate(" not in text:
        reasons.append("missing max-corner SDF annotation evidence")
    if not re.search(r"SDF annotation completed:", text):
        reasons.append("SDF annotation did not complete")
    if expected_pass not in text:
        reasons.append("missing complete expected workload: " + expected_pass)
    if re.search(r"\+define\+(?:ARM_UD_MODEL|ARM_EN_X_SQUASH|NO_SDF)\b|\+notimingcheck\b|\+nospecify\b", text):
        reasons.append("timing model or timing checks disabled in command")

    sdf_errors = [int(x) for x in re.findall(r"Total errors:\s*(\d+)", text)]
    sdf_warning_totals = [int(x) for x in re.findall(r"Total warnings:\s*(\d+)", text)]
    if not sdf_errors or any(sdf_errors):
        reasons.append("SDF annotation errors or absent error summary")
    if not sdf_warning_totals:
        reasons.append("missing SDF warning summary")
    warnings = collections.Counter(re.findall(r"Warning-\[([^]]+)\]", text))
    sdf_warnings = {key: value for key, value in warnings.items() if key.startswith("SDF")}
    # UHICD is the known hierarchical-output warning: VCS applies the DEVICE delay to the source port.  Every
    # other SDF diagnostic must be investigated: missing paths, checks, cells, negative-limit conversions.
    allowed_sdf = {"SDFCOM_UHICD"}
    sdf = SdfLines()
    approved_clamps: list[dict] = []
    if approve_negative_iopath_clamp_ps is not None and "SDFCOM_NDI" in sdf_warnings:
        approved_clamps = approve_negative_iopath(text, approve_negative_iopath_clamp_ps, sdf, reasons)
        if len(approved_clamps) == sdf_warnings["SDFCOM_NDI"]:
            allowed_sdf.add("SDFCOM_NDI")
    approved_interconnects: list[dict] = []
    if approve_iwsba and "SDFCOM_IWSBA" in sdf_warnings:
        approved_interconnects = approve_annotated_interconnect(text, sdf, reasons)
        if len(approved_interconnects) == sdf_warnings["SDFCOM_IWSBA"]:
            allowed_sdf.add("SDFCOM_IWSBA")
    unexpected_sdf = sorted(set(sdf_warnings) - allowed_sdf)
    if unexpected_sdf:
        reasons.append("unapproved SDF warnings: " + ", ".join(unexpected_sdf))
    if re.search(r"(?:Error|Fatal)-\[SDF|SDF (?:Error|Fatal)", text):
        reasons.append("SDF error diagnostic present")
    suppressed = "All future warnings not reported" in text
    if suppressed or sum(sdf_warning_totals) != sum(sdf_warnings.values()):
        reasons.append("SDF warning details incomplete; rerun with +sdfverbose")
    if any("DEVICE Delay on port" not in block or "applied" not in block
           for block in warning_blocks(text, "SDFCOM_UHICD")):
        reasons.append("UHICD diagnostic lacks the expected DEVICE-delay fallback")

    # Startup timing reports are allowed only when every reported event precedes reset completion.
    resets = [float(x) for x in re.findall(r"Performed reset at time\s+(\d+(?:\.\d+)?)", text)]
    reset_ps = resets[0] if len(resets) == 1 else None
    if reset_ps is None:
        reasons.append("expected exactly one reset-complete timestamp")
    timings = []
    headers = list(re.finditer(r"Timing violation in[^\n]*\n", text))
    for index, header in enumerate(headers):
        end = headers[index + 1].start() if index + 1 < len(headers) else len(text)
        match = re.match(rf"\s*({TIMING_CHECK}\s*\(.*?\);)", text[header.end():end], re.S)
        if not match:
            reasons.append("unparsed timing-violation record: " + header[0].strip())
            continue
        check = " ".join(match[1].split())
        events = [float(m[2]) for m in re.finditer(r"([^,():]+):\s*(\d+(?:\.\d+)?)", check)
                  if m[1].strip().lower() not in {"limit", "limits", "threshold"}]
        if not events:
            reasons.append("timing-violation record lacks event timestamps")
        startup = bool(events) and reset_ps is not None and max(events) < reset_ps
        timings.append({"header": header[0].strip(), "check": check,
                        "event_times_ps": events, "before_reset_complete": startup})
    # Fail closed if a simulator emits a timing check without the known header.
    if len(re.findall(rf"(?m)^\s*{TIMING_CHECK}\s*\(", text)) != len(headers):
        reasons.append("timing-check and violation-header counts disagree")
    late = sum(not item["before_reset_complete"] for item in timings)
    if late:
        reasons.append(f"{late} timing violations reach or follow reset completion")
    return {
        "status": "FAIL" if reasons else "PASS",
        "rejection_reasons": reasons,
        "sdf_errors": sdf_errors,
        "sdf_warning_totals": sdf_warning_totals,
        "sdf_warning_categories": sdf_warnings,
        "all_warning_categories": dict(warnings),
        "sdf_warning_details_suppressed": suppressed,
        "approve_negative_iopath_clamp_ps": approve_negative_iopath_clamp_ps,
        "approved_negative_iopath_clamps": approved_clamps,
        "approve_annotated_interconnect": approve_iwsba,
        "approved_annotated_interconnects": approved_interconnects,
        "reset_complete_time_ps": reset_ps,
        "timing_violation_reports": len(headers),
        "startup_timing_violations": sum(item["before_reset_complete"] for item in timings),
        "post_reset_timing_violations": late,
        "timing_records": timings,
    }


def cmd_routed_gl(args) -> int:
    result = audit_routed_gl(args.log.read_text(errors="replace"), args.expected_pass,
                             args.approve_negative_iopath_clamp_ps, args.approve_annotated_interconnect)
    emit_json(result, args.json_path)
    return 0 if result["status"] == "PASS" else 1


def clamp_ps(text: str) -> str:
    if not re.fullmatch(r"[0-9]+(\.[0-9]+)?", text):
        raise argparse.ArgumentTypeError(f"needs a non-negative number of ps (got '{text}')")
    return text


def write_gl_record(result: dict, json_path: Path, log_path: Path) -> None:
    text = json.dumps(result, indent=2) + "\n"
    json_path.write_text(text)
    log_path.write_text(text)


def cmd_gl_audit(args) -> int:
    """Strict first; approvals only after a strict failure, each cited by WORK/gl_validator_args_rationale.txt.

    Writes SIMDIR/timing_qualification_strict.json (+ timing_validation_strict.log) and the governing
    SIMDIR/timing_qualification.json (+ timing_validation.log when approvals were applied), and appends one
    line per audit to WORK/gl_validator_args.txt.  Approvals listed there must be reviewed before quoting.
    """
    simdir, work = args.simdir, args.work
    expected = args.expected_pass or (simdir / "expected_pass.txt").read_text().rstrip("\n")
    text = (simdir / "simulation.log").read_text(errors="replace")
    strict = audit_routed_gl(text, expected)
    write_gl_record(strict, simdir / "timing_qualification_strict.json", simdir / "timing_validation_strict.log")
    flags = ([("--approve-negative-iopath-clamp-ps", args.approve_negative_iopath_clamp_ps)]
             if args.approve_negative_iopath_clamp_ps is not None else []) + \
            ([("--approve-annotated-interconnect", None)] if args.approve_annotated_interconnect else [])
    used = " ".join(f"{flag} {value}" if value else flag for flag, value in flags)
    if strict["status"] == "PASS":
        used = ""
        shutil.copy2(simdir / "timing_qualification_strict.json", simdir / "timing_qualification.json")
    else:
        print("strict audit FAILED:", strict["rejection_reasons"], file=sys.stderr)
        rationale = work / RATIONALE_NAME
        if not flags:
            print(f"No approvals given. Investigate, write {rationale}, then rerun with the --approve-* flags "
                  "it cites.", file=sys.stderr)
            return 1
        if not (rationale.is_file() and rationale.stat().st_size):
            print(f"Approvals '{used}' need a rationale file: {rationale}", file=sys.stderr)
            return 1
        cited = rationale.read_text(errors="replace")
        for flag, _ in flags:
            if flag not in cited:
                print(f"{rationale} does not cite {flag}", file=sys.stderr)
                return 1
        ps = args.approve_negative_iopath_clamp_ps
        approved = audit_routed_gl(text, expected, float(ps) if ps is not None else None,
                                   args.approve_annotated_interconnect)
        write_gl_record(approved, simdir / "timing_qualification.json", simdir / "timing_validation.log")
    final = json.loads((simdir / "timing_qualification.json").read_text())
    clamps = final["approved_negative_iopath_clamps"]
    line = (f"{datetime.datetime.now().isoformat(timespec='seconds')} {simdir} strict={strict['status']} "
            f"strict_reasons={strict['rejection_reasons']} approvals_used='{used}' "
            f"sdf_warnings={final['sdf_warning_categories']} ndi_clamps={len(clamps)} "
            f"worst_clamp_ps={min([c['most_negative_ps'] for c in clamps] or [0])} "
            f"iwsba={len(final['approved_annotated_interconnects'])} "
            f"post_reset_violations={final['post_reset_timing_violations']} status={final['status']}")
    with (work / RECORD_NAME).open("a") as record:
        record.write(line + "\n")
    print(line)
    return 0 if final["status"] == "PASS" else 1


def cmd_syn_gl(args) -> int:
    """Pre-CTS GL on the ideal-clock synthesis SDF: VCS reports SDFCOM_CFTC for the async-reset removal checks
    of DFFRPQ flops ($hold(posedge CK, negedge R) in the library); that is the only rejection excused."""
    log = args.log.read_text(errors="replace")
    verdict = json.loads(args.json.read_text())
    reasons = [r for r in verdict["rejection_reasons"] if r != "unapproved SDF warnings: SDFCOM_CFTC"]
    blocks = warning_blocks(log, "SDFCOM_CFTC")
    bad = [b for b in blocks if not (re.search(r"module: DFFRPQ\w+", b)
                                     and re.search(r"\$hold\(posedge CK[^,]*,\s*negedge R", " ".join(b.split())))]
    if bad:
        reasons.append(f"{len(bad)} SDFCOM_CFTC not of the async-reset removal kind")
    print("timing violations %d (post-reset %d), SDF errors %s, SDF warnings %s, %d SDFCOM_CFTC all DFFRPQ removal "
          "checks%s" % (verdict["timing_violation_reports"], verdict["post_reset_timing_violations"],
                        verdict["sdf_errors"], verdict["sdf_warning_categories"] or "{}", len(blocks),
                        "; REJECT: " + "; ".join(reasons) if reasons else ""))
    return 1 if reasons else 0


# ------------------------------------------------------------------------------------------------- SAIF --

UNIT_NS = {"fs": 1.0e-6, "ps": 1.0e-3, "ns": 1.0, "us": 1.0e3, "ms": 1.0e6, "s": 1.0e9}
SAIF_DURATION_RE = re.compile(r"^\s*\(DURATION\s+([-+0-9.eE]+)\)")
SAIF_TIMESCALE_RE = re.compile(r"^\s*\(TIMESCALE\s+([-+0-9.eE]+)\s+(fs|ps|ns|us|ms|s)\)")
SAIF_TIME_RE = re.compile(r"\(T0\s+([-+0-9.eE]+)\)\s+\(T1\s+([-+0-9.eE]+)\)\s+\(TX\s+([-+0-9.eE]+)\)")
SAIF_TC_RE = re.compile(r"\(TC\s+([-+0-9.eE]+)\)")
SAIF_SIGNAL_RE = re.compile(r"^\s*\(([^()\s]+)\s*$")
SAIF_HEADER_RE = re.compile(r"\(([^()\s]+)")
SAIF_RESERVED = {"SAIFILE", "INSTANCE", "NET", "PORT"}
# Operand nets whose toggles prove a productive SC stimulus.  SDF-aware VCS optimization can remove the named
# comparator outputs from a mapped SAIF while the RNG bank stays visible and drives the same workload.
SC_OPERANDS = ("in_bits", "w_bits", "in_sign", "w_sign", "a_bits", "a_sign", "random_values")
SC_ACCUMULATORS = ("acc_value\\[", "acc_out\\[")
# Top/dut architectural outputs of the binary arrays (BOS acc_out_east; bitmod tile drain rails).
BINARY_OUTPUTS = ("ofm\\[", "acc_value\\[", "drain_out\\[", "acc_out_east\\[", "o_drain_row\\[", "o_drain_dat\\[")


def saif_lines(path: Path) -> list[str] | None:
    return path.read_text(errors="replace").splitlines() if path.exists() else None


def iter_saif_nets(lines: list[str]):
    """Yield (instance path, raw net name, T0, T1, TX, TC) for every net record, scoped by INSTANCE nesting."""
    depth = 0
    scope: list[tuple[str, int]] = []
    name = times = None
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("(INSTANCE "):
            scope.append((stripped.split(None, 1)[1].rstrip(")"), depth + 1))
        else:
            header = SAIF_HEADER_RE.fullmatch(stripped)
            if header and header[1] not in SAIF_RESERVED:
                name, times = header[1], None
        if name is not None:
            match = SAIF_TIME_RE.search(line)
            if match:
                times = tuple(float(v) for v in match.groups())
            match = SAIF_TC_RE.search(line)
            if match and times is not None:
                yield (tuple(n for n, _ in scope), name, *times, float(match[1]))
                name = None
        depth += line.count("(") - line.count(")")
        while scope and depth < scope[-1][1]:
            scope.pop()


def saif_activity(lines: list[str]) -> tuple[float | None, float]:
    """Aggregate unknown-time percentage over all records, and the total toggle count."""
    t0_sum = t1_sum = tx_sum = tc_sum = 0.0
    pending_tc = False
    for line in lines:
        match = SAIF_TIME_RE.search(line)
        if match:
            t0, t1, tx = (float(x) for x in match.groups())
            t0_sum += t0
            t1_sum += t1
            tx_sum += tx
            pending_tc = True
            continue
        if pending_tc:
            match = SAIF_TC_RE.search(line)
            if match:
                tc_sum += float(match[1])
                pending_tc = False
    total = t0_sum + t1_sum + tx_sum
    return (100.0 * tx_sum / total if total > 0.0 else None), tc_sum


def saif_stimulus_tc(lines: list[str]) -> tuple[float, float]:
    """Clock toggles (max over nets named clk) and SC operand toggles.

    TX is unknown-state occupancy, not switching; these explicit TC checks keep an all-static but fully known
    stimulus from passing the X-activity checks.
    """
    signal = None
    clock_tc = operand_tc = 0.0
    for line in lines:
        header = SAIF_SIGNAL_RE.match(line)
        if header:
            signal = header[1].replace(r"\[", "[")
            continue
        if signal is None:
            continue
        match = SAIF_TC_RE.search(line)
        if not match:
            continue
        tc = float(match[1])
        if signal == "clk":
            clock_tc = max(clock_tc, tc)
        elif signal.startswith(SC_OPERANDS):
            operand_tc += tc
        signal = None
    return clock_tc, operand_tc


def saif_clock_period_ns(lines: list[str]) -> float | None:
    """Clock period from the SAIF duration, timescale and clock toggles."""
    duration = timescale_ns = None
    for line in lines:
        match = SAIF_DURATION_RE.match(line)
        if match:
            duration = float(match[1])
        match = SAIF_TIMESCALE_RE.match(line)
        if match:
            timescale_ns = float(match[1]) * UNIT_NS[match[2]]
        if duration is not None and timescale_ns is not None:
            break
    clock_tc, _ = saif_stimulus_tc(lines)
    if duration is None or timescale_ns is None or clock_tc <= 0.0:
        return None
    return 2.0 * duration * timescale_ns / clock_tc


def saif_quantum_pct(lines: list[str]) -> float | None:
    """One SAIF time unit as a percentage of the window.

    VCS initializes monitored changing signals with one time unit of TX, a known clock included; that fixed
    reporter bookkeeping is tolerated.  Real X events are caught by the benches' event-driven checks.
    """
    for line in lines:
        match = SAIF_DURATION_RE.match(line)
        if match:
            duration = float(match[1])
            return 100.0 / duration if duration > 0.0 else None
    return None


def saif_nonpersistent_tx(lines: list[str]) -> tuple[float | None, int]:
    """TX percentage over the nets that are known part of the window, and the count of nets X throughout."""
    known = unknown = 0.0
    persistent = 0
    for line in lines:
        match = SAIF_TIME_RE.search(line)
        if not match:
            continue
        t0, t1, tx = (float(v) for v in match.groups())
        total = t0 + t1 + tx
        if total <= 0.0:
            continue
        if tx == total:
            persistent += 1
            continue
        known += total
        unknown += tx
    return (100.0 * unknown / known if known > 0.0 else None), persistent


def saif_acc_tx(lines: list[str]) -> float | None:
    """Worst TX percentage over the SC accumulator/drain output bits."""
    pending = False
    worst = None
    for line in lines:
        if any(name in line for name in SC_ACCUMULATORS):
            pending = True
            continue
        if not pending:
            continue
        match = SAIF_TIME_RE.search(line)
        if match:
            t0, t1, tx = (float(v) for v in match.groups())
            if t0 + t1 + tx > 0.0:
                pct = 100.0 * tx / (t0 + t1 + tx)
                worst = pct if worst is None else max(worst, pct)
            pending = False
    return worst


def saif_output_tx(lines: list[str]) -> float | None:
    """Worst TX percentage over Top/dut's architectural binary output bits."""
    worst = None
    for scope, name, t0, t1, tx, _tc in iter_saif_nets(lines):
        if scope == ("Top", "dut") and name.startswith(BINARY_OUTPUTS) and t0 + t1 + tx > 0.0:
            pct = 100.0 * tx / (t0 + t1 + tx)
            worst = pct if worst is None else max(worst, pct)
    return worst


def unknown_activity_error(nonpersistent_tx: float | None, persistent: int, quantum: float | None) -> str | None:
    if quantum is None:
        return "no SAIF duration/reporting quantum"
    if persistent != 0:
        return f"persistent-X signals={persistent}; required 0"
    if nonpersistent_tx is None:
        return "no nonpersistent SAIF activity records"
    if nonpersistent_tx > quantum + 1.0e-12:
        return f"nonpersistent TX={nonpersistent_tx:.9f}% exceeds one reporter quantum ({quantum:.9f}%)"
    return None


def persistent_note(persistent: int, checked_by: str) -> str:
    if persistent == 0:
        return ""
    return (f"  [note: {persistent} internal/dead net(s) X for the whole window; benign given {checked_by}]")


def cmd_saif_sc(args) -> int:
    lines = saif_lines(args.saif) or []
    aggregate, total_tc = saif_activity(lines)
    clock_tc, operand_tc = saif_stimulus_tc(lines)
    acc_tx = saif_acc_tx(lines)
    quantum = saif_quantum_pct(lines)
    nonpersistent, persistent = saif_nonpersistent_tx(lines)
    if aggregate is None:
        raise SystemExit(f"invalid SC SAIF: no activity records in {args.saif}")
    if clock_tc < args.min_clock_tc:
        raise SystemExit(f"invalid SC SAIF: clock TC={clock_tc} is below {args.min_clock_tc}")
    period = saif_clock_period_ns(lines)
    if period is None:
        raise SystemExit(f"invalid SC SAIF: cannot recover clock period from {args.saif}")
    if abs(period - args.expected_period_ns) > args.period_tolerance_ns:
        raise SystemExit(f"invalid SC SAIF: observed clock period={period:.6f} ns, expected "
                         f"{args.expected_period_ns:.6f} +/- {args.period_tolerance_ns:.6f} ns")
    if operand_tc < args.min_operand_tc:
        raise SystemExit(f"invalid SC SAIF: operand TC={operand_tc} is below {args.min_operand_tc}")
    if acc_tx is None:
        raise SystemExit(f"invalid SC SAIF: no accumulator output activity in {args.saif}")
    if quantum is None:
        raise SystemExit(f"invalid SC SAIF: no duration in {args.saif}")
    error = unknown_activity_error(nonpersistent, persistent if args.strict_persistent_x else 0, quantum)
    if error is not None:
        raise SystemExit(f"invalid SC SAIF: {error} in {args.saif}")
    # Architectural correctness gate: the accumulator/drain output must be X-free.
    if acc_tx > quantum + args.max_extra_acc_tx_pct + 1.0e-12:
        raise SystemExit(f"invalid SC SAIF: accumulator TX={acc_tx:.9f}% exceeds one reporter quantum "
                         f"({quantum:.9f}%) + allowed extra ({args.max_extra_acc_tx_pct:.9f}%) -- accumulator is "
                         "X, execution is not clean")
    print(f"validated SC SAIF: acc TX={acc_tx:.9f}%, aggregate unknown-time={aggregate:.6f}%, "
          f"nonpersistent TX={nonpersistent:.6f}%, persistent-X signals={persistent}, period={period:.6f} ns, "
          f"clock TC={clock_tc:.0f}, operand TC={operand_tc:.0f}, total TC={total_tc:.0f}"
          + persistent_note(persistent, "X-free accumulator -- correctness is checked by the array cosim"))
    return 0


def cmd_saif_binary(args) -> int:
    lines = saif_lines(args.saif) or []
    aggregate, _ = saif_activity(lines)
    output_tx = saif_output_tx(lines)
    quantum = saif_quantum_pct(lines)
    nonpersistent, persistent = saif_nonpersistent_tx(lines)
    period = saif_clock_period_ns(lines)
    if aggregate is None:
        raise SystemExit(f"invalid binary SAIF: no activity records in {args.saif}")
    if output_tx is None:
        raise SystemExit(f"invalid binary SAIF: no Top/dut architectural output activity in {args.saif}")
    if quantum is None:
        raise SystemExit(f"invalid binary SAIF: no duration in {args.saif}")
    error = unknown_activity_error(nonpersistent, persistent if args.strict_persistent_x else 0, quantum)
    if error is not None:
        raise SystemExit(f"invalid binary SAIF: {error} in {args.saif}")
    if period is None:
        raise SystemExit(f"invalid binary SAIF: cannot recover clock period from {args.saif}")
    if abs(period - args.expected_period_ns) > args.period_tolerance_ns:
        raise SystemExit(f"invalid binary SAIF: observed clock period={period:.6f} ns, expected "
                         f"{args.expected_period_ns:.6f} +/- {args.period_tolerance_ns:.6f} ns")
    # Architectural correctness gate: the measured outputs must be X-free.
    if output_tx > quantum + args.max_output_tx_pct + 1.0e-12:
        raise SystemExit(f"invalid binary SAIF: architectural output TX={output_tx:.9f}% exceeds one reporter "
                         f"quantum ({quantum:.9f}%) + allowed extra ({args.max_output_tx_pct:.9f}%) -- outputs "
                         "are X, execution is not clean")
    print(f"validated binary SAIF: architectural output TX={output_tx:.9f}% (reporter quantum={quantum:.9f}%), "
          f"aggregate TX={aggregate:.6f}%, nonpersistent TX={nonpersistent:.6f}%, "
          f"persistent-X signals={persistent}, period={period:.6f} ns"
          + persistent_note(persistent, "X-free outputs -- correctness is checked by the output-checking bench"))
    return 0


def cmd_saif_int(args) -> int:
    """INT-mode contract of designs/payn/power/power_payn_int.sv on payn_array, read from the SAIF.

      zero    (TC = T1 = TX = 0 all window) Top/dut: a_binary_in, w_binary_in, a_len_in, rng_en, acc_in_west,
              block_start, slice_start; Top/dut/u_peripheral: a_binary_q, a_len_q, w_binary_q (every INT load
              carried zero magnitudes and L = 0), ka_flat; each u_peripheral/*u_ka encoder's ka output (kA = 0)
      static  (TC = 0) Top/dut/u_rng: cyc, phase, w_words (rng_en low froze the AF block clock outputs)
      high    (T1 = duration, TC = 0) Top/dut/int_mode
      bypass  a_bits[n] / w_bits[n] toggle exactly as Top/dut a_raw_in[n] / w_raw_in[n] for all 1024 n, and the
              raw planes toggle.  A bit net is read in u_peripheral, else on the top-level wire, else as
              u_pe <side>_bits_in: VCS records a port-collapsed net in one scope only.
    u_rng nets toggling other than at the clock rate are listed for information.  Every group must be present.
    """
    lines = saif_lines(args.saif) or []
    nets: dict[str, dict[str, tuple[int, int, int, int]]] = collections.defaultdict(dict)
    for scope, name, t0, t1, tx, tc in iter_saif_nets(lines):
        nets["/".join(scope)][name.replace("\\", "")] = (int(t0), int(t1), int(tx), int(tc))
    duration = next((float(m[1]) for m in map(SAIF_DURATION_RE.match, lines) if m), None)
    reasons: list[str] = []
    record: dict[str, dict] = {}
    top, periph = "Top/dut", "Top/dut/u_peripheral"
    rng = f"{top}/u_rng"

    def group(inst: str, base: str) -> dict[str, tuple[int, int, int, int]]:
        return {n: v for n, v in nets.get(inst, {}).items() if n == base or n.startswith(base + "[")}

    def need(inst: str, base: str) -> dict[str, tuple[int, int, int, int]]:
        found = group(inst, base)
        if not found:
            reasons.append(f"{inst}/{base}: not in the SAIF")
        return found

    zero = [(top, "a_binary_in"), (top, "w_binary_in"), (top, "a_len_in"), (top, "rng_en"), (top, "acc_in_west"),
            (top, "block_start"), (top, "slice_start"),
            (periph, "a_binary_q"), (periph, "a_len_q"), (periph, "w_binary_q"), (periph, "ka_flat")]
    for inst, base in zero:
        found = need(inst, base)
        bad = [n for n, (_, t1, tx, tc) in found.items() if tc or t1 or tx]
        record[f"{inst}/{base}"] = dict(rule="zero", nets=len(found), violations=len(bad))
        if bad:
            reasons.append(f"{inst}/{base}: {len(bad)} of {len(found)} nets not held at 0 (e.g. {bad[0]})")
    encoders = sorted(i for i in nets if i.startswith(periph + "/") and i.endswith("u_ka"))
    enc_bad = []
    for inst in encoders:
        found = group(inst, "ka")
        if not found:
            enc_bad.append(f"{inst}: no ka nets")
        enc_bad += [f"{inst}/{n}" for n, (_, t1, tx, tc) in found.items() if tc or t1 or tx]
    record[f"{periph}/*u_ka/ka"] = dict(rule="zero", instances=len(encoders), violations=len(enc_bad))
    n_elements = len(group(periph, "a_binary_q")) // 8     # one encoder per A element (8-bit magnitudes)
    if len(encoders) != n_elements:
        reasons.append(f"{periph}: {len(encoders)} kA encoder instances in the SAIF, expected {n_elements} "
                       f"(one per A element, |a_binary_q| / 8)")
    if enc_bad:
        reasons.append(f"kA encoder outputs not held at 0: {len(enc_bad)} (e.g. {enc_bad[0]})")
    for base in ("cyc", "phase", "w_words"):
        found = need(rng, base)
        bad = [n for n, v in found.items() if v[3]]
        record[f"{rng}/{base}"] = dict(rule="static", nets=len(found), violations=len(bad))
        if bad:
            reasons.append(f"{rng}/{base}: {len(bad)} of {len(found)} nets toggle (AF block clock not frozen)")
    for _, (_, t1, _, tc) in need(top, "int_mode").items():
        record[f"{top}/int_mode"] = dict(rule="high", T1=t1, TC=tc, duration=duration)
        if tc or duration is None or t1 != int(round(duration)):
            reasons.append(f"{top}/int_mode not held high for the whole window (T1={t1}, TC={tc}, "
                           f"duration={duration})")

    clk = group(top, "clk").get("clk")
    clock_tc = clk[3] if clk else None
    if not clock_tc:
        reasons.append(f"{top}/clk missing or static")
    rng_insts = [i for i in nets if i == rng or i.startswith(rng + "/")]
    toggling = [(i, n, v[3]) for i in rng_insts for n, v in nets[i].items() if v[3]]
    other = [t for t in toggling if t[2] != clock_tc]
    record[rng] = dict(rule="info: nets toggling unlike the clock", instances=len(rng_insts),
                       toggling_nets=len(toggling), non_clock_toggling=len(other),
                       non_clock_nets=[f"{i}/{n}:{tc}" for i, n, tc in other[:20]])
    if not rng_insts:
        reasons.append(f"{rng}: not in the SAIF")

    for side in ("a", "w"):
        raw = need(top, f"{side}_raw_in")
        bit_tc = lambda found, base: {n[len(base):]: v[3] for n, v in found.items()}   # noqa: E731
        raw_tc = bit_tc(raw, f"{side}_raw_in")
        scopes = [(periph, f"{side}_bits"), (top, f"{side}_bits"), (f"{top}/u_pe", f"{side}_bits_in")]
        found_in = [bit_tc(group(i, base), base) for i, base in scopes]
        bits, where = {}, {f"{i}/{base}": 0 for i, base in scopes}
        for k in raw_tc:
            for (i, base), found in zip(scopes, found_in):
                if k in found:
                    bits[k] = found[k]
                    where[f"{i}/{base}"] += 1
                    break
        mismatch = [k for k in set(raw_tc) | set(bits) if raw_tc.get(k) != bits.get(k)]
        raw_total = sum(raw_tc.values())
        record[f"bypass_{side}"] = dict(rule="bits == raw per bit", bits=len(bits), raw=len(raw_tc),
                                        bits_found_in=where, raw_tc=raw_total, bits_tc=sum(bits.values()),
                                        mismatches=len(mismatch))
        if len(raw_tc) != 1024 or len(bits) != 1024:
            reasons.append(f"bypass {side}: {len(raw_tc)} raw and {len(bits)} bit nets found, expected 1024 each")
        if mismatch:
            k = sorted(mismatch)[0]
            reasons.append(f"bypass {side}: {len(mismatch)} bits where the {side}_bits TC != {side}_raw_in TC "
                           f"(e.g. {k}: {bits.get(k)} vs {raw_tc.get(k)})")
        if raw and not raw_total:
            reasons.append(f"{side}_raw_in never toggles: no INT stimulus in the window")

    result = dict(status="FAIL" if reasons else "PASS", rejection_reasons=reasons,
                  duration=duration, clock_tc=clock_tc, groups=record)
    emit_json(result, args.json_path)
    if reasons:
        print("[FAIL] INT SAIF audit: " + "; ".join(reasons))
        return 1
    print(f"[PASS] INT SAIF audit: SC side quiet (magnitudes, row L, edge registers, {len(encoders)} kA encoder outputs, "
          f"rng_en, acc_in_west, block/slice_start at 0; AF block clock outputs static), int_mode high, bypass "
          f"transparent (a {record['bypass_a']['raw_tc']} / w {record['bypass_w']['raw_tc']} raw toggles = bits "
          f"toggles); u_rng non-clock toggling nets: {record[rng]['non_clock_toggling']}")
    return 0


# ---------------------------------------------------------------------------------------- PT-PX coverage --

def audit_pt_coverage(reports: Path, power_log: Path) -> dict:
    """Every net's activity is from the SAIF or the explicit static-zero pinless policy, none defaulted or
    missing, and every pin-to-pin net (internal and boundary) has annotated parasitics."""
    rows = re.findall(r"^[ \t]*Nets[ \t]+(?=\d)(.+)$", (reports / "saif_coverage.rpt").read_text(), re.M)
    require(len(rows) == 2, "Expected switching and static-probability net coverage rows")
    forced = re.findall(r"Forced\s+(\d+)\s+pinless net\(s\) to static-zero activity",
                        power_log.read_text(errors="replace"))
    require(len(forced) == 1, "Missing explicit ZERO_PINLESS_NET_ACTIVITY=1 execution evidence")
    pinless = int(forced[0])
    counts_by_kind = {}
    for kind, row in zip(("switching", "static_probability"), rows):
        counts = [int(x) for x in re.findall(r"(\d+)\([0-9.]+%\)", row)]
        total = re.search(r"\s(\d+)\s*$", row)
        require(len(counts) == 10 and total, f"Unrecognized {kind} activity coverage format")
        require(int(total[1]) > 0 and sum(counts) == int(total[1]), f"Inconsistent {kind} activity counts")
        # PT column order: file, SSA, SSA-force-annotated, SSA-force-implied, SCA, clock, default, propagated,
        # implied, missing.
        require(not (counts[6] or counts[9]), f"{kind} has {counts[6]} default and {counts[9]} unannotated nets")
        require(counts[1] == pinless, f"{kind} static-activity nets do not match explicit pinless policy")
        counts_by_kind[kind] = counts
    require(counts_by_kind["switching"] == counts_by_kind["static_probability"],
            "Switching and static-probability annotation sources disagree")
    pin_rows = re.findall(r"^\s*- Pin to pin nets\s*\|([^\n]+)", (reports / "parasitics_coverage.rpt").read_text(),
                          re.M)
    require(len(pin_rows) == 2, "Expected internal and boundary pin-to-pin parasitic coverage")
    pin_counts = []
    for row in pin_rows:
        values = [int(x) for x in re.findall(r"\d+", row)]
        require(len(values) == 5 and sum(values[1:]) == values[0],
                "Unrecognized/inconsistent pin-to-pin parasitic coverage")
        require(not values[-1], f"{values[-1]} pin-to-pin nets lack annotated parasitics")
        pin_counts.append(values)
    counts = counts_by_kind["switching"]
    return {
        "status": "PASS",
        "zero_pinless_net_activity": 1,
        "activity_file_nets": counts[0],
        "static_pinless_nets": pinless,
        "default_activity_nets": counts[6],
        "unannotated_activity_nets": counts[9],
        "internal_pin_to_pin_nets": pin_counts[0][0],
        "boundary_pin_to_pin_nets": pin_counts[1][0],
        "unannotated_pin_to_pin_nets": sum(row[-1] for row in pin_counts),
    }


def cmd_pt_coverage(args) -> int:
    try:
        result = audit_pt_coverage(args.reports, args.power_log)
    except (ValueError, OSError) as error:
        result = {"status": "FAIL", "reason": str(error)}
    emit_json(result, args.json_path)
    return 0 if result["status"] == "PASS" else 1


# -------------------------------------------------------------------------------------- SDF clock gates --

SDF_CELL_RE = re.compile(r'\(CELL\s*\(CELLTYPE\s+"([^"]+)"\)\s*\(INSTANCE\s*([^)]*)\)')
SDF_NUMBER_RE = re.compile(r"-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?")
SDF_TRIPLE_RE = re.compile(r"\((-?[\d.]+):(-?[\d.]+):(-?[\d.]+)\)")


def icg_delay_sections(text: str, icg_regex: str):
    """(celltype, instance, start, end) of the DELAY part of every clock-gate cell (CELLTYPE matching
    icg_regex): from its INSTANCE to its TIMINGCHECK, else to the next CELL."""
    icg = re.compile(icg_regex)
    for match in SDF_CELL_RE.finditer(text):
        if not icg.search(match[1]):
            continue
        start = match.end()
        following = text.find("(CELL", start)
        end = following if following >= 0 else len(text)
        check = text.find("(TIMINGCHECK", start, end)
        yield match[1], match[2].strip(), start, check if check >= 0 else end


def cmd_sdf_clock(args) -> int:
    """Is the ideal-clock view of pre-layout GL needed for this SDF?  Synthesis SDF gives the unbuffered shared
    ICGs CK->ECK beyond the period (no gated pulse survives); after CTS the ICGs are cloned into buffered trees
    and the routed SDF must be simulated as written.  PASS iff every ICG's worst IOPATH is below
    --max-fraction of the period, and (with --sim-log) the GL run compiled against and annotated this file."""
    text = args.sdf.read_text(errors="replace")
    cells = []
    for celltype, instance, start, end in icg_delay_sections(text, args.icg_regex):
        values = [float(x) for line in text[start:end].splitlines() if "IOPATH" in line
                  for x in SDF_NUMBER_RE.findall(line.split("IOPATH", 1)[1])]
        cells.append(dict(instance=instance, celltype=celltype, worst_iopath_ns=max(values) if values else None))
    limit = args.max_fraction * args.period_ns
    timed = [c for c in cells if c["worst_iopath_ns"] is not None]
    worst = max((c["worst_iopath_ns"] for c in timed), default=None)
    reasons = []
    if not timed:
        reasons.append("no clock-gate cell with IOPATH delays found")
    elif worst >= limit:
        reasons.append(f"worst clock-gate IOPATH {worst:.3f} ns >= {limit:.3f} ns: the ideal-clock problem is present")
    out = dict(sdf=str(args.sdf.resolve()), period_ns=args.period_ns, limit_ns=limit, icg_cells=len(cells),
               icg_cells_with_iopath=len(timed), worst_icg_iopath_ns=worst,
               worst_cells=sorted(timed, key=lambda c: -c["worst_iopath_ns"])[:8])
    if args.sim_log:
        log = args.sim_log.read_text(errors="replace")
        compiled = re.search(r"^\s*sdf\s*=\s*(\S+)", log, re.M)            # the flow's "sdf = <path>" line
        annotated = re.search(r'\*\*\*\s+SDF file:\s*"([^"]+)"', log)       # VCS's $sdf_annotate banner
        used = compiled[1] if compiled else None
        out.update(sim_log=str(args.sim_log.resolve()), sdf_used_by_gl=used,
                   sdf_annotated=annotated[1] if annotated else None)
        if not used or Path(used).resolve() != args.sdf.resolve():
            reasons.append(f"GL compiled against {used}, not {args.sdf}")
        if not annotated or Path(annotated[1]).resolve() != args.sdf.resolve():
            reasons.append(f"bench annotated {annotated[1] if annotated else None}, not {args.sdf}")
    out["status"] = "FAIL" if reasons else "PASS"
    out["reasons"] = reasons
    args.json.write_text(json.dumps(out, indent=2) + "\n")
    print(f"[{out['status']}] {len(cells)} clock-gate cells, worst CK->ECK "
          f"{worst if worst is None else round(worst, 3)} ns (limit {limit:.3f} ns)"
          f"{'; ' + '; '.join(reasons) if reasons else ''}")
    return 1 if reasons else 0


def cmd_ideal_clock_sdf(args) -> int:
    """DC times the clock network as ideal (zero latency through clock gates) and never buffers a gated clock,
    yet its SDF gives each ICG its real CK->ECK into the unbuffered gated net: on the PaYN arrays the shared ICGs
    get 2.8-3.8 ns, longer than the 2.5 ns period, so VCS's inertial delay swallows every gated pulse.  This
    writes a copy with only the ICG cells' IOPATH delays set to 0 (the clock model STA used); every data-path
    delay and timing check stays as written.  APR's clock tree replaces this pre-CTS artifact."""
    text = args.sdf_in.read_text()
    pieces, pos, zeroed = [], 0, []
    for celltype, instance, start, end in icg_delay_sections(text, args.icg_regex):
        block = text[start:end]
        values = [float(x) for triple in SDF_TRIPLE_RE.findall(block) for x in triple]
        pieces += [text[pos:start], SDF_TRIPLE_RE.sub("(0.000:0.000:0.000)", block)]
        pos = end
        zeroed.append((max(values) if values else 0.0, instance, celltype))
    pieces.append(text[pos:])
    args.sdf_out.parent.mkdir(parents=True, exist_ok=True)
    args.sdf_out.write_text("".join(pieces))
    zeroed.sort(reverse=True)
    head = (f"{args.sdf_in} -> {args.sdf_out}: zeroed the IOPATH delays of {len(zeroed)} ICG cells "
            f"({sum(1 for z in zeroed if z[0] > 0.5)} had CK->ECK > 0.5 ns); data paths and timing checks unchanged")
    lines = [head] + [f"  {d:.3f} ns  {inst}  ({ct})" for d, inst, ct in zeroed]
    print("\n".join(lines[:9]))
    if args.report:
        args.report.write_text("\n".join(lines) + "\n")
    return 0


# ------------------------------------------------------------------------------------------- basin gate --

TILE_RE = re.compile(r"^u_pe/u_array_core/g_row_(\d+)__g_col_(\d+)__u_inner/")
DEF_POINT_RE = re.compile(r"\(\s*(\S+)\s+(\S+)(?:\s+\S+)?\s*\)")
DEF_NET_PROPERTIES = (" + SOURCE", " + USE", " + WEIGHT", " + FREQUENCY", " + FIXEDBUMP", " + PROPERTY",
                      " + NONDEFAULTRULE", " + SHIELDNET", " + ORIGINAL")


def def_route_length(text: str, units: float) -> dict[str, float]:
    """Routed length per layer (um) of one NETS statement: Manhattan length of each ROUTED/NEW segment."""
    lengths: dict[str, float] = {}
    start = text.find("+ ROUTED")
    if start < 0:
        return lengths
    route = text[start + len("+ ROUTED"):]
    for keyword in DEF_NET_PROPERTIES:
        cut = route.find(keyword)
        if cut >= 0:
            route = route[:cut]
    for statement in route.split(" NEW "):
        statement = statement.strip()
        if not statement:
            continue
        tokens = statement.split(None, 1)
        rest = re.sub(r"TAPER(RULE \S+)?", "", re.sub(r"RECT\s*\([^)]*\)", "", tokens[1] if len(tokens) > 1 else ""))
        px = py = None
        total = 0.0
        for xs, ys in DEF_POINT_RE.findall(rest):
            x = px if xs == "*" else float(xs)
            y = py if ys == "*" else float(ys)
            if px is not None:
                total += abs(x - px) + abs(y - py)
            px, py = x, y
        if total:
            lengths[tokens[0]] = lengths.get(tokens[0], 0.0) + total / units
    return lengths


def parse_def(path: Path) -> dict:
    """Units, die area (um), placed components {name: (cell, x_um, y_um)} and per-net routed length."""
    units, die = 2000.0, None
    comps: dict[str, tuple] = {}
    nets: dict[str, dict[str, float]] = {}
    section, buf = None, []

    def flush() -> None:
        text = " ".join(buf)
        if section == "COMP":
            name, cell = re.match(r"-\s+(\S+)\s+(\S+)", text).groups()
            placed = re.search(r"\+ (?:PLACED|FIXED|COVER)\s*\(\s*(-?\d+)\s+(-?\d+)\s*\)\s*(\S+)", text)
            x, y = (int(placed[1]) / units, int(placed[2]) / units) if placed else (None, None)
            comps[name] = (cell, x, y)
        elif section == "NETS":
            nets[re.match(r"-\s+(\S+)", text)[1]] = def_route_length(text, units)

    with open(path, errors="replace") as stream:
        for line in stream:
            s = line.strip()
            if section is None:
                if s.startswith("UNITS DISTANCE MICRONS"):
                    units = float(s.split()[3])
                elif s.startswith("DIEAREA"):
                    die = tuple(float(v) / units for v in re.findall(r"-?\d+", s))
                elif s.startswith(("COMPONENTS ", "PINS ", "NETS ")):
                    section = {"C": "COMP", "P": "PINS", "N": "NETS"}[s[0]]
                continue
            if s.startswith("END "):
                if buf:
                    flush()
                    buf = []
                section = None
                continue
            if s.startswith("- ") and buf:
                flush()
                buf = []
            buf.append(s)
    return dict(units=units, die=die, comps=comps, nets=nets)


def corr(a: list[float], b: list[float]) -> float:
    ma, mb = sum(a) / len(a), sum(b) / len(b)
    sa = math.sqrt(sum((x - ma) ** 2 for x in a))
    sb = math.sqrt(sum((y - mb) ** 2 for y in b))
    return sum((x - ma) * (y - mb) for x, y in zip(a, b)) / (sa * sb)


def tile_metrics(layout: dict) -> dict:
    """corr(tile x, column) etc. from tile centroids (all u_inner components), and d_col / d_row / tile radius
    from the logic centroids (no FILL/DECAP/ANTENNA cells)."""
    allc = collections.defaultdict(list)
    logic = collections.defaultdict(list)
    for name, (cell, x, y) in layout["comps"].items():
        match = TILE_RE.match(name)
        if not match or x is None:
            continue
        key = (int(match[1]), int(match[2]))
        allc[key].append((x, y))
        if not cell.startswith(("FILL", "DECAP", "ANTENNA")):
            logic[key].append((x, y))
    keys = sorted(allc)
    cx = [sum(p[0] for p in allc[k]) / len(allc[k]) for k in keys]
    cy = [sum(p[1] for p in allc[k]) / len(allc[k]) for k in keys]
    hs = [k[0] for k in keys]
    vs = [k[1] for k in keys]
    c = {k: (sum(p[0] for p in v) / len(v), sum(p[1] for p in v) / len(v)) for k, v in logic.items()}
    rad = [math.sqrt(sum((x - c[k][0]) ** 2 + (y - c[k][1]) ** 2 for x, y in v) / len(v)) for k, v in logic.items()]
    nh, nw = max(hs) + 1, max(vs) + 1
    dist = lambda a, b: math.hypot(c[a][0] - c[b][0], c[a][1] - c[b][1])   # noqa: E731
    dcol = [dist((h, v), (h, v + 1)) for h in range(nh) for v in range(nw - 1)]
    drow = [dist((h, v), (h + 1, v)) for h in range(nh - 1) for v in range(nw)]
    grid = {f"{h},{v}": [round(c[(h, v)][0], 1), round(c[(h, v)][1], 1)] for h, v in sorted(c)}
    return dict(tiles=len(keys), nh=nh, nw=nw,
                corr_x_col=corr(cx, vs), corr_y_negrow=corr(cy, [-h for h in hs]),
                corr_x_negrow=corr(cx, [-h for h in hs]), corr_y_col=corr(cy, vs),
                d_col_um=sum(dcol) / len(dcol), d_row_um=sum(drow) / len(drow),
                tile_radius_um=sum(rad) / len(rad), tile_centroids=grid)


def skew_metrics(path: Path) -> dict:
    """Operand arrival skew w_arr - a_arr (ps) at the product AND2s, from tcl/pt_basin_skew.tcl's TSV."""
    with open(path) as stream:
        rows = list(csv.DictReader(stream, delimiter="\t"))
    require(rows, f"no product ANDs in {path}")
    sk = [(float(r["w_arr"]) - float(r["a_arr"])) * 1000 for r in rows]
    ab = sorted(abs(s) for s in sk)
    n = len(rows)
    per_tile = collections.defaultdict(list)
    for r, s in zip(rows, sk):
        per_tile[(int(r["tile_row"]), int(r["tile_col"]))].append(abs(s))
    return dict(product_ands=n,
                a_arr_mean_ps=statistics.mean(float(r["a_arr"]) for r in rows) * 1000,
                w_arr_mean_ps=statistics.mean(float(r["w_arr"]) for r in rows) * 1000,
                skew_mean_ps=statistics.mean(sk), abs_skew_mean_ps=statistics.mean(ab),
                abs_skew_p50_ps=ab[n // 2], abs_skew_p90_ps=ab[int(0.9 * n)],
                a_slew_mean_ps=statistics.mean(float(r["a_slew"]) for r in rows if r["a_slew"]) * 1000,
                w_slew_mean_ps=statistics.mean(float(r["w_slew"]) for r in rows if r["w_slew"]) * 1000,
                worst_tile_abs_skew_ps=max(sum(v) / len(v) for v in per_tile.values()))


def def_pin_status(path: Path) -> dict[str, tuple]:
    """{pin: (layer, FIXED|PLACED|COVER|UNPLACED, x, y)} in DEF units."""
    pins, buf, section = {}, "", False
    with open(path, errors="replace") as stream:
        for line in stream:
            if line.startswith("PINS "):
                section = True
                continue
            if line.startswith("END PINS"):
                break
            if not section:
                continue
            buf += line
            if line.rstrip().endswith(";"):
                name = re.match(r"\s*-\s+(\S+)", buf)[1]
                layer = re.search(r"\+ LAYER (\S+)", buf)
                st = re.search(r"\+ (FIXED|PLACED|COVER)\s*\(\s*(-?\d+)\s+(-?\d+)\s*\)\s*(\S+)", buf)
                pins[name] = (layer[1] if layer else None, st[1] if st else "UNPLACED",
                              int(st[2]) if st else None, int(st[3]) if st else None)
                buf = ""
    return pins


def pin_proof(def_path: Path, plan_path: Path, units: float) -> dict:
    """Every pin of the PRE_PLACE plan is FIXED in the final DEF at exactly the planned layer and location."""
    pins = def_pin_status(def_path)
    with open(plan_path) as stream:
        plan = list(csv.DictReader(stream, delimiter="\t"))
    bad = []
    for r in plan:
        got = pins.get(r["pin"])
        want = (r["layer"], "FIXED", round(float(r["x"]) * units), round(float(r["y"]) * units))
        if got != want:
            bad.append({"pin": r["pin"], "planned": want, "def": got})
    return dict(def_pins=len(pins), planned_pins=len(plan),
                fixed_in_def=sum(1 for v in pins.values() if v[1] == "FIXED"),
                unplanned_def_pins=sorted(set(pins) - {r["pin"] for r in plan})[:20],
                mismatches=len(bad), mismatch_examples=bad[:20],
                planned_by_edge=dict(collections.Counter(r["edge"] for r in plan)),
                status="PASS" if not bad and len(pins) == len(plan) else "FAIL")


def basin_gate(def_path: Path, skew_path: Path, plan: Path | None, label: str, min_corr: float,
               max_skew_ps: float) -> dict:
    """Grid basin iff corr(tile x, column) >= min_corr and mean |a - w skew| <= max_skew_ps."""
    layout = parse_def(def_path)
    tm = tile_metrics(layout)
    sm = skew_metrics(skew_path)
    wire_mm = sum(sum(lengths.values()) for lengths in layout["nets"].values()) / 1e3
    grid = tm["corr_x_col"] >= min_corr and sm["abs_skew_mean_ps"] <= max_skew_ps
    out = dict(label=label, def_file=str(def_path.resolve()), skew_file=str(skew_path.resolve()),
               die_um=[layout["die"][2], layout["die"][3]], wire_mm=wire_mm,
               gate=dict(min_corr_x_col=min_corr, max_abs_skew_ps=max_skew_ps,
                         basin="grid" if grid else "collapsed", status="PASS" if grid else "FAIL"),
               **{k: v for k, v in tm.items() if k != "tile_centroids"}, **sm, tile_centroids=tm["tile_centroids"])
    if plan:
        out["pin_proof"] = pin_proof(def_path, plan, layout["units"])
    return out


def run_pt_basin_skew(route: Path, top: str, out_dir: Path) -> Path:
    """Run tcl/pt_basin_skew.tcl on the routed netlist + SPEF; returns the TSV (pt_skew.log beside it)."""
    tsv, log = out_dir / "product_and_skew.tsv", out_dir / "pt_skew.log"
    env = dict(os.environ, RUN_DIR=str(route), TOP=top, OUT=str(tsv))
    script = shlex.quote(str(FLOW / "tcl/pt_basin_skew.tcl"))
    shell = ("{ source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash; } && "
             f"module load {' '.join(EDA_MODULES)} && pt_shell -file {script}")
    with log.open("w") as stream:
        subprocess.run(["bash", "-c", shell], cwd=out_dir, env=env, stdout=stream, stderr=subprocess.STDOUT)
    text = log.read_text(errors="replace")
    done = [line for line in text.splitlines() if line.startswith("BASIN_SKEW_DONE")]
    require(done, f"PrimeTime did not finish: {log}")
    require(not re.search(r"(?m)^(Error|ERROR):", text), f"PT errors in {log}")
    print(done[-1])
    return tsv


def cmd_basin(args) -> int:
    """Writes OUT_DIR/basin_gate.json and basin_gate.log (and, unless --skew reuses a measurement,
    OUT_DIR/product_and_skew.tsv + pt_skew.log).  Exit 0: grid basin (and pin proof PASS); 3: collapsed basin
    or failed pin proof (verdict in the JSON); 2: the metrics could not be produced."""
    route = args.route.resolve()
    def_path = route / "outputs" / f"{args.top}.apr.def"
    try:
        needed = [def_path]
        if not args.skew:     # PrimeTime reads the routed netlist, SPEF and constraints
            needed += [route / f"outputs/{args.top}.apr.v", route / f"outputs/{args.top}.spef",
                       route / f"{args.top}.syn.sdc"]
        for path in needed:
            require(path.is_file() and path.stat().st_size, f"Missing {path}")
        args.out_dir.mkdir(parents=True, exist_ok=True)
        out_dir = args.out_dir.resolve()
        skew = args.skew if args.skew else run_pt_basin_skew(route, args.top, out_dir)
        out = basin_gate(def_path, skew, args.plan, args.label, args.min_corr, args.max_skew_ps)
    except (QualifyError, OSError) as error:
        print(f"basin: {error}", file=sys.stderr)
        return 2
    (out_dir / "basin_gate.json").write_text(json.dumps(out, indent=2) + "\n")
    summary = {k: out[k] for k in ("label", "wire_mm", "corr_x_col", "corr_y_negrow", "d_col_um", "d_row_um",
                                   "tile_radius_um", "product_ands", "abs_skew_mean_ps", "abs_skew_p90_ps")}
    summary["basin"] = out["gate"]["basin"]
    if args.plan:
        summary["pin_proof"] = out["pin_proof"]["status"]
        summary["pins_fixed"] = out["pin_proof"]["fixed_in_def"]
    line = json.dumps(summary)
    (out_dir / "basin_gate.log").write_text(line + "\n")
    print(line)
    failed = out["gate"]["status"] != "PASS" or ("pin_proof" in out and out["pin_proof"]["status"] != "PASS")
    return 3 if failed else 0


# ------------------------------------------------------------------------------------------------- CLI --

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True, metavar="COMMAND")

    def command(name: str, func, help_text: str) -> argparse.ArgumentParser:
        p = sub.add_parser(name, help=help_text, description=func.__doc__ or help_text,
                           formatter_class=argparse.RawDescriptionHelpFormatter)
        p.set_defaults(func=func)
        return p

    def approvals(p: argparse.ArgumentParser, ps_type) -> None:
        p.add_argument("--approve-negative-iopath-clamp-ps", type=ps_type, metavar="PS",
                       help="opt-in: accept SDFCOM_NDI for IOPATH delays no more negative than -PS "
                            "(each clamp is listed in the JSON)")
        p.add_argument("--approve-annotated-interconnect", action="store_true",
                       help="opt-in: accept SDFCOM_IWSBA where VCS states the INTERCONNECT is still annotated "
                            "across a netlist assign/instance boundary (each one is listed in the JSON)")

    p = command("routed-apr", cmd_routed_apr, "qualify a completed routed design")
    p.add_argument("route", type=Path)
    p.add_argument("top")
    p.add_argument("--stage", choices=("final", "bootstrap"),
                   help="judge from the Innovus log's final checks (C-BSG/CSA campaigns); bootstrap tolerates "
                        "residual DRC/antenna markers and placement overlaps")
    p.add_argument("--json", type=Path, dest="json_path")

    p = command("routed-gl", cmd_routed_gl, "qualify routed VCS timing and SDF annotation of a GL log")
    p.add_argument("log", type=Path)
    p.add_argument("--json", type=Path, dest="json_path")
    p.add_argument("--expected-pass", default=DEFAULT_WORKLOAD_PASS)
    approvals(p, float)

    p = command("gl-audit", cmd_gl_audit, "routed-gl strict first, approvals only after a strict failure")
    p.add_argument("simdir", type=Path, help="GL run directory holding simulation.log")
    p.add_argument("--work", type=Path, required=True,
                   help=f"campaign directory holding {RATIONALE_NAME}; {RECORD_NAME} is appended there")
    p.add_argument("--expected-pass", help="workload PASS line (default: SIMDIR/expected_pass.txt)")
    approvals(p, clamp_ps)

    p = command("syn-gl", cmd_syn_gl, "post-synthesis GL timing view from a routed-gl verdict")
    p.add_argument("log", type=Path, help="the log routed-gl audited")
    p.add_argument("json", type=Path, help="routed-gl's JSON for that log")

    p = command("saif-sc", cmd_saif_sc, "validate an SC power SAIF")
    p.add_argument("saif", type=Path)
    p.add_argument("--max-extra-acc-tx-pct", type=float, default=0.0)
    p.add_argument("--min-clock-tc", type=float, default=100.0)
    p.add_argument("--min-operand-tc", type=float, default=100.0)
    p.add_argument("--expected-period-ns", type=float, default=2.5)
    p.add_argument("--period-tolerance-ns", type=float, default=0.01)
    p.add_argument("--strict-persistent-x", action="store_true",
                   help="also fail if any net is unknown for the entire window")

    p = command("saif-binary", cmd_saif_binary, "validate a binary power SAIF")
    p.add_argument("saif", type=Path)
    p.add_argument("--max-output-tx-pct", type=float, default=0.0)
    p.add_argument("--expected-period-ns", type=float, default=2.5)
    p.add_argument("--period-tolerance-ns", type=float, default=0.01)
    p.add_argument("--strict-persistent-x", action="store_true",
                   help="also fail if any net is unknown for the entire window")

    p = command("saif-int", cmd_saif_int, "INT-mode audit of a payn_array energy SAIF")
    p.add_argument("saif", type=Path)
    p.add_argument("--json", type=Path, dest="json_path")

    p = command("pt-coverage", cmd_pt_coverage, "require measured/static activity and complete RC for PT-PX")
    p.add_argument("reports", type=Path)
    p.add_argument("--power-log", type=Path, required=True)
    p.add_argument("--json", type=Path, dest="json_path")

    p = command("sdf-clock", cmd_sdf_clock, "clock-gate delay audit of a routed SDF")
    p.add_argument("sdf", type=Path)
    p.add_argument("--period-ns", type=float, required=True)
    p.add_argument("--max-fraction", type=float, default=0.5)
    p.add_argument("--icg-regex", default=r"ICG")
    p.add_argument("--sim-log", type=Path)
    p.add_argument("--json", type=Path, required=True)

    p = command("ideal-clock-sdf", cmd_ideal_clock_sdf, "write the ideal-clock view of a synthesis SDF")
    p.add_argument("sdf_in", type=Path)
    p.add_argument("sdf_out", type=Path)
    p.add_argument("--icg-regex", default=r"ICG")
    p.add_argument("--report", type=Path)

    p = command("basin", cmd_basin, "basin QoR gate and pin-survival proof of a routed single-PE layout")
    p.add_argument("route", type=Path)
    p.add_argument("top")
    p.add_argument("out_dir", type=Path)
    p.add_argument("label")
    p.add_argument("--plan", type=Path, help="PRE_PLACE pin plan (sc_pin_plan.tsv) to prove against the DEF")
    p.add_argument("--skew", type=Path, help="reuse this product_and_skew.tsv instead of running PrimeTime")
    p.add_argument("--min-corr", type=float, default=0.8)
    p.add_argument("--max-skew-ps", type=float, default=50.0)
    return parser


def main() -> None:
    args = build_parser().parse_args()
    sys.exit(args.func(args))


if __name__ == "__main__":
    main()
