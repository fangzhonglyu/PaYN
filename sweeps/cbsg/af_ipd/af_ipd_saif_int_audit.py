#!/usr/bin/env python3
"""INT-mode audit of an AF-IPD energy SAIF (power_payn_array_cbsg_af_ipd_int.sv on
payn_array_signed_segmented_csa_cbsg_af_ipd), complementing validate_sc_power_saif.py.

[CBSG-AF-IPD COPY] of sweeps/int_mode/bp/bp_saif_int_audit.py (sha256 in
designs/payn/variants/signed_segmented_csa_cbsg_af_ipd/copied_from.sha256).  The SAIF parser and the rules' form
are the original's; the groups follow the AF edge instead of the Sobol edge (the BP top's u_sc comparators and
u_a_rng / u_w_rng banks do not exist here).  It proves, from the measured activity itself, that the window ran
under the INT contract with the AF side quiet:

  zero  (held at 0 for the whole window: TC = 0, T1 = 0, TX = 0)
        Top/dut: a_binary_in, w_binary_in, a_len_in, rng_en, acc_in_west, block_start, slice_start
        Top/dut/u_peripheral: a_binary_q, a_len_q, w_binary_q (the edge registers: every INT load carried zero
              magnitudes and L = 0), ka_flat (the 64 kA encoder outputs: kA = 0, so every thermometer bit is 0)
        Top/dut/u_peripheral/*u_ka: ka (each encoder's output port)
  static (TC = 0): Top/dut/u_rng: cyc, phase, w_words (the AF block clock outputs: rng_en low, so the counter,
        phase and W lane words are frozen; with zero W magnitudes every W comparator 0 > threshold is false)
  high  (T1 = duration, TC = 0): Top/dut: int_mode
  bypass transparency: the bypass output a_bits[n] (w_bits[n]) toggles exactly as often as Top/dut
        a_raw_in[n] (w_raw_in[n]), for every n of 1024, and the raw planes toggle at all (silent AF streams: the
        bypass OR output is the raw plane).  The bit net is read in Top/dut/u_peripheral, else on the top-level wire,
        else as Top/dut/u_pe <side>_bits_in (the same wire: VCS records a port-collapsed net in one scope only).
Information only: u_rng nets that toggle other than at the clock rate (the slice-restart flag that INT drains arm,
see the top's contract) are listed.  Every group must be present (fail closed: port nets of preserved hierarchy).
Exits 1 on any violation.

  af_ipd_saif_int_audit.py dut.saif [--json out.json]
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
    top, periph = "Top/dut", "Top/dut/u_peripheral"

    def need(inst, base):
        g = group(nets, inst, base)
        if not g:
            reasons.append(f"{inst}/{base}: not in the SAIF")
        return g

    rng = f"{top}/u_rng"
    zero = [(top, "a_binary_in"), (top, "w_binary_in"), (top, "a_len_in"), (top, "rng_en"), (top, "acc_in_west"),
            (top, "block_start"), (top, "slice_start"),
            (periph, "a_binary_q"), (periph, "a_len_q"), (periph, "w_binary_q"), (periph, "ka_flat")]
    for inst, base in zero:
        g = need(inst, base)
        bad = [n for n, (t0, t1, tx, tc) in g.items() if tc or t1 or tx]
        record[f"{inst}/{base}"] = dict(rule="zero", nets=len(g), violations=len(bad))
        if bad:
            reasons.append(f"{inst}/{base}: {len(bad)} of {len(g)} nets not held at 0 (e.g. {bad[0]})")
    encs = sorted(i for i in nets if i.startswith(periph + "/") and i.endswith("u_ka"))
    enc_bad = []
    for inst in encs:
        g = group(nets, inst, "ka")
        if not g:
            enc_bad.append(f"{inst}: no ka nets")
        enc_bad += [f"{inst}/{n}" for n, (t0, t1, tx, tc) in g.items() if tc or t1 or tx]
    record[f"{periph}/*u_ka/ka"] = dict(rule="zero", instances=len(encs), violations=len(enc_bad))
    if len(encs) != 64:
        reasons.append(f"{periph}: {len(encs)} kA encoder instances in the SAIF, expected 64")
    if enc_bad:
        reasons.append(f"kA encoder outputs not held at 0: {len(enc_bad)} (e.g. {enc_bad[0]})")
    for base in ("cyc", "phase", "w_words"):
        g = need(rng, base)
        bad = [n for n, v in g.items() if v[3]]
        record[f"{rng}/{base}"] = dict(rule="static", nets=len(g), violations=len(bad))
        if bad:
            reasons.append(f"{rng}/{base}: {len(bad)} of {len(g)} nets toggle (AF block clock not frozen)")
    g = need(top, "int_mode")
    for n, (t0, t1, tx, tc) in g.items():
        record[f"{top}/int_mode"] = dict(rule="high", T1=t1, TC=tc, duration=duration)
        if tc or duration is None or t1 != int(round(duration)):
            reasons.append(f"{top}/int_mode not held high for the whole window (T1={t1}, TC={tc}, duration={duration})")

    clk = group(nets, top, "clk").get("clk")
    clock_tc = clk[3] if clk else None
    if not clock_tc:
        reasons.append(f"{top}/clk missing or static")
    insts = [i for i in nets if i == rng or i.startswith(rng + "/")]
    toggling = [(i, n, v[3]) for i in insts for n, v in nets[i].items() if v[3]]
    other = [t for t in toggling if t[2] != clock_tc]
    record[rng] = dict(rule="info: nets toggling unlike the clock", instances=len(insts),
                       toggling_nets=len(toggling), non_clock_toggling=len(other),
                       non_clock_nets=[f"{i}/{n}:{tc}" for i, n, tc in other[:20]])
    if not insts:
        reasons.append(f"{rng}: not in the SAIF")

    for side in ("a", "w"):
        raw = need(top, f"{side}_raw_in")
        idx = lambda d, base: {n[len(base):]: v[3] for n, v in d.items()}
        r = idx(raw, f"{side}_raw_in")
        # [AF-IPD] The bypass output u_peripheral <side>_bits[n] is one top-level wire with u_pe <side>_bits_in[n];
        # VCS records a port-collapsed net in one scope only (on the routed netlist most w_bits bits appear only as
        # u_pe/w_bits_in), so each bit is looked up in u_peripheral, then the top wire, then u_pe.
        scopes = [(periph, f"{side}_bits"), (top, f"{side}_bits"), (f"{top}/u_pe", f"{side}_bits_in")]
        found = [idx(group(nets, i, base), base) for i, base in scopes]
        b, where = {}, {f"{i}/{base}": 0 for i, base in scopes}
        for k in r:
            for (i, base), f in zip(scopes, found):
                if k in f:
                    b[k] = f[k]; where[f"{i}/{base}"] += 1
                    break
        mismatch = [k for k in set(r) | set(b) if r.get(k) != b.get(k)]
        raw_tc = sum(r.values())
        record[f"bypass_{side}"] = dict(rule="bits == raw per bit", bits=len(b), raw=len(r), bits_found_in=where,
                                        raw_tc=raw_tc, bits_tc=sum(b.values()), mismatches=len(mismatch))
        if len(r) != 1024 or len(b) != 1024:
            reasons.append(f"bypass {side}: {len(r)} raw and {len(b)} bit nets found, expected 1024 each")
        if mismatch:
            k = sorted(mismatch)[0]
            reasons.append(f"bypass {side}: {len(mismatch)} bits where the {side}_bits TC != "
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
        print("[FAIL] AF-IPD INT SAIF audit: " + "; ".join(reasons))
        return 1
    print(f"[PASS] AF-IPD INT SAIF audit: AF side quiet (magnitudes, row L, edge registers, 64 kA encoder outputs, "
          f"rng_en, acc_in_west, block/slice_start at 0; AF block clock outputs static), int_mode high, bypass "
          f"transparent (a {record['bypass_a']['raw_tc']} / w {record['bypass_w']['raw_tc']} raw toggles = bits "
          f"toggles); u_rng non-clock toggling nets: {record[rng]['non_clock_toggling']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
