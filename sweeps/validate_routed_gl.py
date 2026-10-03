#!/usr/bin/env python3
"""Qualify routed VCS timing and SDF annotation for the PaYN power bench.

Startup timing reports are recorded and allowed only when every reported event
precedes the explicit reset-complete timestamp. Architectural correctness and
SAIF X-freeness are independently checked by cosim_streaming.py and the SAIF
validator; this helper does not replace either check.
"""
from __future__ import annotations

import argparse
from collections import Counter
import json
from pathlib import Path
import re


DEFAULT_WORKLOAD_PASS = "PASS: streaming SC SAIF captured; 384 batches x 8 cycles"


def _approve_ndi(text: str, max_ps: float, reasons: list[str]) -> list[dict]:
    """Opt-in: accept SDFCOM_NDI only for small negative IOPATH delays.

    VCS clamps a negative IOPATH delay to zero (and cannot honor it on a COND
    path even with -negdelay).  Each diagnostic must cite an SDF file and
    line; that line must be an IOPATH entry whose negative values are all no
    more negative than -max_ps.  Every approved clamp is returned for the
    qualification record.
    """
    approved = []
    blocks = re.findall(r"Warning-\[SDFCOM_NDI\](.*?)(?=\n\s*\n|\Z)", text, re.S)
    cache: dict[str, list[str]] = {}
    for block in blocks:
        where = re.search(r"(\S+\.sdf), (\d+)", block)
        inst = re.search(r'instance:\s*([^"\s]+)', block)
        if not where or not inst:
            reasons.append("SDFCOM_NDI diagnostic lacks SDF file/line or instance")
            continue
        path, line_no = where[1], int(where[2])
        try:
            lines = cache.setdefault(path, Path(path).read_text(errors="replace").splitlines())
            line = lines[line_no - 1]
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


def audit(text: str, expected_pass: str = DEFAULT_WORKLOAD_PASS,
          approve_negative_iopath_clamp_ps: float | None = None) -> dict:
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
    warnings = Counter(re.findall(r"Warning-\[([^]]+)\]", text))
    sdf_warnings = {key: value for key, value in warnings.items() if key.startswith("SDF")}
    # UHICD is the known hierarchical-output warning: VCS applies DEVICE delay
    # to the source port. Every other SDF diagnostic must be investigated,
    # including missing paths, checks, cells, or negative-limit conversions.
    allowed_sdf = {"SDFCOM_UHICD"}
    approved_clamps: list[dict] = []
    if approve_negative_iopath_clamp_ps is not None and "SDFCOM_NDI" in sdf_warnings:
        approved_clamps = _approve_ndi(text, approve_negative_iopath_clamp_ps, reasons)
        if len(approved_clamps) == sdf_warnings["SDFCOM_NDI"]:
            allowed_sdf.add("SDFCOM_NDI")
    unexpected_sdf = sorted(set(sdf_warnings) - allowed_sdf)
    if unexpected_sdf:
        reasons.append("unapproved SDF warnings: " + ", ".join(unexpected_sdf))
    if re.search(r"(?:Error|Fatal)-\[SDF|SDF (?:Error|Fatal)", text):
        reasons.append("SDF error diagnostic present")
    suppressed = "All future warnings not reported" in text
    if suppressed or sum(sdf_warning_totals) != sum(sdf_warnings.values()):
        reasons.append("SDF warning details incomplete; rerun with +sdfverbose")
    uhicd_blocks = re.findall(
        r"Warning-\[SDFCOM_UHICD\](.*?)(?=\n\s*\n|\Z)", text, re.S
    )
    if any("DEVICE Delay on port" not in block or "applied" not in block for block in uhicd_blocks):
        reasons.append("UHICD diagnostic lacks the expected DEVICE-delay fallback")

    resets = [float(x) for x in re.findall(r"Performed reset at time\s+(\d+(?:\.\d+)?)", text)]
    reset_ps = resets[0] if len(resets) == 1 else None
    if reset_ps is None:
        reasons.append("expected exactly one reset-complete timestamp")
    timings = []
    headers = list(re.finditer(r"Timing violation in[^\n]*\n", text))
    for index, header in enumerate(headers):
        end = headers[index + 1].start() if index + 1 < len(headers) else len(text)
        tail = text[header.end():end]
        match = re.match(r"\s*(\$(?:setuphold|recrem|setup|hold|width|period|recovery|removal|skew|timeskew|fullskew|nochange)\s*\(.*?\);)", tail, re.S)
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
    printed_checks = re.findall(r"(?m)^\s*\$(?:setuphold|recrem|setup|hold|width|period|recovery|removal|skew|timeskew|fullskew|nochange)\s*\(", text)
    if len(printed_checks) != len(headers):
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
        "reset_complete_time_ps": reset_ps,
        "timing_violation_reports": len(headers),
        "startup_timing_violations": sum(item["before_reset_complete"] for item in timings),
        "post_reset_timing_violations": late,
        "timing_records": timings,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    parser.add_argument("--json", type=Path, dest="json_path")
    parser.add_argument("--expected-pass", default=DEFAULT_WORKLOAD_PASS)
    parser.add_argument("--approve-negative-iopath-clamp-ps", type=float, metavar="PS",
                        help="opt-in: accept SDFCOM_NDI for IOPATH delays no more negative "
                             "than -PS (each clamp is listed in the JSON)")
    args = parser.parse_args()
    result = audit(args.log.read_text(errors="replace"), args.expected_pass,
                   args.approve_negative_iopath_clamp_ps)
    formatted = json.dumps(result, indent=2) + "\n"
    if args.json_path:
        args.json_path.write_text(formatted)
    print(formatted, end="")
    if result["status"] != "PASS":
        raise SystemExit(1)


if __name__ == "__main__":
    main()
