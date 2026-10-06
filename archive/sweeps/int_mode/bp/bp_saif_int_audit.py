#!/usr/bin/env python3
"""INT-mode audit of a BP energy SAIF (power_payn_array_bp_int.sv on
payn_array_signed_segmented_csa_bp), complementing validate_sc_power_saif.py.

The SC validator proves the measurement is clean (period, X, stimulus).  This
proves, from the measured activity itself, that the window ran under the BP INT
contract with the SC side quiet:

  zero  (held at 0 for the whole window: TC = 0, T1 = 0, TX = 0)
        Top/dut: a_binary_in, w_binary_in, rng_en, acc_in_west
        Top/dut/u_peripheral/u_sc: a_bits, w_bits   (the comparator outputs: silent)
  static (TC = 0): Top/dut/u_a_rng, u_w_rng: random_values   (Sobol outputs frozen)
  high  (T1 = duration, TC = 0): Top/dut: int_mode
  clock-only: every toggling net under Top/dut/u_a_rng and Top/dut/u_w_rng
        toggles exactly as often as Top/dut clk (clock tree / gate inputs only)
  bypass transparency: Top/dut/u_peripheral a_bits[n] (w_bits[n]) toggles
        exactly as often as Top/dut a_raw_in[n] (w_raw_in[n]), for every n, and
        the raw planes toggle at all.  With silent comparators the AO21 bypass
        output is the raw plane.
Every group must be present (fail closed: these are port nets of preserved
hierarchy).  Exits 1 on any violation.

  bp_saif_int_audit.py dut.saif [--json out.json]
"""
from __future__ import annotations

import argparse
import json
import re
from collections import defaultdict
from pathlib import Path

TIME_RE = re.compile(r"\(T0 (\d+)\)\s*\(T1 (\d+)\)\s*\(TX (\d+)\)")
TC_RE = re.compile(r"\(TC (\d+)\)")
DUR_RE = re.compile(r"^\(DURATION\s+([0-9.eE+-]+)\)")
RESERVED = {"SAIFILE", "INSTANCE", "NET", "PORT"}


def parse(path: Path):
    """{instance path: {net name: (T0, T1, TX, TC)}} and the duration."""
    nets: dict[str, dict[str, tuple[int, int, int, int]]] = defaultdict(dict)
    inst: list[tuple[str, int]] = []
    depth = 0
    cur = None
    times = None
    duration = None
    with path.open(errors="replace") as stream:
        for line in stream:
            s = line.strip()
            if duration is None:
                m = DUR_RE.match(s)
                if m:
                    duration = float(m[1])
            if s.startswith("(INSTANCE "):
                inst.append((s.split(None, 1)[1].rstrip(")"), depth + 1))
            else:
                m = re.fullmatch(r"\(([^()\s]+)", s)
                if m and m[1] not in RESERVED:
                    cur, times = m[1].replace("\\", ""), None
            m = TIME_RE.search(line)
            if m and cur is not None:
                times = tuple(int(x) for x in m.groups())
            m = TC_RE.search(line)
            if m and cur is not None and times is not None:
                nets["/".join(n for n, _ in inst)][cur] = times + (int(m[1]),)
                cur = None
            depth += line.count("(") - line.count(")")
            while inst and depth < inst[-1][1]:
                inst.pop()
    return nets, duration


def group(nets, inst: str, base: str) -> dict[str, tuple[int, int, int, int]]:
    """Nets named base or base[...] in instance inst."""
    return {n: v for n, v in nets.get(inst, {}).items()
            if n == base or n.startswith(base + "[")}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("saif", type=Path)
    ap.add_argument("--json", type=Path, dest="json_path")
    args = ap.parse_args()
    nets, duration = parse(args.saif)
    reasons: list[str] = []
    record: dict[str, dict] = {}
    top, periph, sc = "Top/dut", "Top/dut/u_peripheral", "Top/dut/u_peripheral/u_sc"

    def need(inst, base):
        g = group(nets, inst, base)
        if not g:
            reasons.append(f"{inst}/{base}: not in the SAIF")
        return g

    for inst, base in ((top, "a_binary_in"), (top, "w_binary_in"), (top, "rng_en"),
                       (top, "acc_in_west"), (sc, "a_bits"), (sc, "w_bits")):
        g = need(inst, base)
        bad = [n for n, (t0, t1, tx, tc) in g.items() if tc or t1 or tx]
        record[f"{inst}/{base}"] = dict(rule="zero", nets=len(g), violations=len(bad))
        if bad:
            reasons.append(f"{inst}/{base}: {len(bad)} of {len(g)} nets not held at 0 (e.g. {bad[0]})")
    for inst, base in ((f"{top}/u_a_rng", "random_values"), (f"{top}/u_w_rng", "random_values")):
        g = need(inst, base)
        bad = [n for n, v in g.items() if v[3]]
        record[f"{inst}/{base}"] = dict(rule="static", nets=len(g), violations=len(bad))
        if bad:
            reasons.append(f"{inst}/{base}: {len(bad)} of {len(g)} nets toggle (Sobol not frozen)")
    g = need(top, "int_mode")
    for n, (t0, t1, tx, tc) in g.items():
        record[f"{top}/int_mode"] = dict(rule="high", T1=t1, TC=tc, duration=duration)
        if tc or duration is None or t1 != int(round(duration)):
            reasons.append(f"{top}/int_mode not held high for the whole window (T1={t1}, TC={tc}, duration={duration})")

    clk = group(nets, top, "clk").get("clk")
    clock_tc = clk[3] if clk else None
    if not clock_tc:
        reasons.append(f"{top}/clk missing or static")
    for bank in ("u_a_rng", "u_w_rng"):
        prefix = f"{top}/{bank}"
        insts = [i for i in nets if i == prefix or i.startswith(prefix + "/")]
        toggling = [(i, n, v[3]) for i in insts for n, v in nets[i].items() if v[3]]
        bad = [t for t in toggling if t[2] != clock_tc]
        record[prefix] = dict(rule="clock-only", instances=len(insts),
                              toggling_nets=len(toggling), non_clock_toggling=len(bad))
        if not insts:
            reasons.append(f"{prefix}: not in the SAIF")
        if bad:
            reasons.append(f"{prefix}: {len(bad)} nets toggle unlike the clock (e.g. {bad[0]})")

    for side in ("a", "w"):
        raw, bits = need(top, f"{side}_raw_in"), need(periph, f"{side}_bits")
        idx = lambda d, base: {n[len(base):]: v[3] for n, v in d.items()}
        r, b = idx(raw, f"{side}_raw_in"), idx(bits, f"{side}_bits")
        mismatch = [k for k in set(r) | set(b) if r.get(k) != b.get(k)]
        raw_tc = sum(r.values())
        record[f"bypass_{side}"] = dict(rule="bits == raw per bit", bits=len(b), raw=len(r),
                                        raw_tc=raw_tc, bits_tc=sum(b.values()), mismatches=len(mismatch))
        if mismatch:
            k = sorted(mismatch)[0]
            reasons.append(f"bypass {side}: {len(mismatch)} bits where u_peripheral {side}_bits TC != "
                           f"{side}_raw_in TC (e.g. {k}: {b.get(k)} vs {r.get(k)})")
        if raw and not raw_tc:
            reasons.append(f"{side}_raw_in never toggles: no INT stimulus in the window")

    result = dict(status="FAIL" if reasons else "PASS", rejection_reasons=reasons,
                  duration=duration, clock_tc=clock_tc, groups=record)
    text = json.dumps(result, indent=2) + "\n"
    if args.json_path:
        args.json_path.write_text(text)
    print(text, end="")
    if reasons:
        print("[FAIL] BP INT SAIF audit: " + "; ".join(reasons))
        return 1
    print(f"[PASS] BP INT SAIF audit: SC side quiet (magnitudes, comparators, rng_en, acc_in_west at 0; "
          f"Sobol static, clock-only), int_mode high, bypass transparent "
          f"(a {record['bypass_a']['raw_tc']} / w {record['bypass_w']['raw_tc']} raw toggles = bits toggles)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
