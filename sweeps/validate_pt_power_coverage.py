#!/usr/bin/env python3
"""Require measured/static activity and complete pin-to-pin RC for PT-PX."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re


def audit_reports(reports: Path, power_log: Path) -> dict:
    activity = (reports / 'saif_coverage.rpt').read_text()
    rows = re.findall(r'^[ \t]*Nets[ \t]+(?=\d)(.+)$', activity, re.M)
    if len(rows) != 2:
        raise ValueError('Expected switching and static-probability net coverage rows')
    log = power_log.read_text(errors='replace')
    forced = re.findall(r'Forced\s+(\d+)\s+pinless net\(s\) to static-zero activity', log)
    if len(forced) != 1:
        raise ValueError('Missing explicit ZERO_PINLESS_NET_ACTIVITY=1 execution evidence')
    pinless = int(forced[0])
    counts_by_kind = {}
    for kind, row in zip(('switching', 'static_probability'), rows):
        counts = [int(x) for x in re.findall(r'(\d+)\([0-9.]+%\)', row)]
        total_match = re.search(r'\s(\d+)\s*$', row)
        if len(counts) != 10 or not total_match:
            raise ValueError(f'Unrecognized {kind} activity coverage format')
        total = int(total_match[1])
        if total <= 0 or sum(counts) != total:
            raise ValueError(f'Inconsistent {kind} activity counts')
        # PT report column order: file, SSA, SSA-force-annotated,
        # SSA-force-implied, SCA, clock, default, propagated, implied, missing.
        if counts[6] or counts[9]:
            raise ValueError(f'{kind} has {counts[6]} default and {counts[9]} unannotated nets')
        if counts[1] != pinless:
            raise ValueError(f'{kind} static-activity nets do not match explicit pinless policy')
        counts_by_kind[kind] = counts
    if counts_by_kind['switching'] != counts_by_kind['static_probability']:
        raise ValueError('Switching and static-probability annotation sources disagree')

    parasitics = (reports / 'parasitics_coverage.rpt').read_text()
    pin_rows = re.findall(r'^\s*- Pin to pin nets\s*\|([^\n]+)', parasitics, re.M)
    if len(pin_rows) != 2:
        raise ValueError('Expected internal and boundary pin-to-pin parasitic coverage')
    pin_counts = []
    for row in pin_rows:
        values = [int(x) for x in re.findall(r'\d+', row)]
        if len(values) != 5 or sum(values[1:]) != values[0]:
            raise ValueError('Unrecognized/inconsistent pin-to-pin parasitic coverage')
        if values[-1]:
            raise ValueError(f'{values[-1]} pin-to-pin nets lack annotated parasitics')
        pin_counts.append(values)
    counts = counts_by_kind['switching']
    return {
        'status': 'PASS',
        'zero_pinless_net_activity': 1,
        'activity_file_nets': counts[0],
        'static_pinless_nets': pinless,
        'default_activity_nets': counts[6],
        'unannotated_activity_nets': counts[9],
        'internal_pin_to_pin_nets': pin_counts[0][0],
        'boundary_pin_to_pin_nets': pin_counts[1][0],
        'unannotated_pin_to_pin_nets': sum(row[-1] for row in pin_counts),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('reports', type=Path)
    parser.add_argument('--power-log', type=Path, required=True)
    parser.add_argument('--json', type=Path, dest='json_path')
    args = parser.parse_args()
    try:
        result = audit_reports(args.reports, args.power_log)
    except (ValueError, OSError) as error:
        result = {'status': 'FAIL', 'reason': str(error)}
    formatted = json.dumps(result, indent=2) + '\n'
    if args.json_path:
        args.json_path.write_text(formatted)
    print(formatted, end='')
    if result['status'] != 'PASS':
        raise SystemExit(1)


if __name__ == '__main__':
    main()
