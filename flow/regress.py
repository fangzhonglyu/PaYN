#!/usr/bin/env python3
"""PaYN functional regression: RTL benches against the bit-exact models.

Suites (case tables in flow/cases/, benches in designs/payn/tb and designs/payn/power):
  cases      emit the SC golden / extra / review case sets for the shape (model/sc_cases.py)
  units      test_payn_units.sv: kA encoder exhaustive, W stream, INT silence, raw bypass
  sc         test_payn_array.sv +MODE=sc: every case alone, the chained robustness runs and the
             negative controls (cases/sc.txt), drains bit-exact against the C-BSG kernel
  int        +MODE=int, bit-plane INT matrix (cases/int.txt), model/int_trace.py bp
  switch     +MODE=switch, SC <-> INT on one DUT without reset (cases/switch.txt)
  abit       +MODE=abit, all-bits-in-time INT matrix (cases/abit.txt), int_trace.py abit
  grid-bp    test_payn_pe_grid.sv +MODE=bp, 2x2 and 4x4 (cases/grid_bp.txt), int_trace.py bp-grid
  grid-abit  test_payn_pe_grid.sv +MODE=abit (cases/grid_abit.txt), int_trace.py abit-grid
  power      the power benches on RTL: SC uniform / ladder (sc_trace.py) and INT bp
             (cases/power_bp.txt, int_trace.py bp-power) and INT abit (cases/power_abit.txt,
             int_trace.py abit-power)
A negative control passes when the bench or checker catches it the way its table row says.

  python3 flow/regress.py                              # every suite, K16/M8
  python3 flow/regress.py --shape both --suite sc,int  # both shapes, two suites
Run dirs: <out>/<shape>/<suite>/<label>/.  Summary: <out>/<shape>/summary.txt.  Exit 0 iff all pass.

Gate-level mode (--gl MODES): the same functional bench on a netlist and on RTL, the same inputs on both, for the
rows of cases/gl_sc.txt, gl_int.txt, gl_switch.txt and gl_abit.txt whose modes column names the mode:
  syn-unit   synthesis netlist (--synth-run), unit delay, timing checks off (ARM_UD_MODEL + ARM_EN_X_SQUASH):
             the functional proof of clock gating, multibit banking, register merging and reset mapping
  syn-sdf    synthesis netlist with the ideal-clock view of its SDF (qualify.py ideal-clock-sdf), max corner,
             +neg_tchk, timing checks on; each log through qualify.py routed-gl + syn-gl
  apr        routed netlist (--route) with its raw max-corner SDF; each log through qualify.py gl-audit (strict
             first; --gl-approve flags only after a strict failure, with <out>/<shape>/apr/
             gl_validator_args_rationale.txt citing them); SC and switch drains read at the SDC output-delay point
Pass criteria: the GL RESULT fields equal RTL's (SC), GL traces byte-identical to RTL's (INT, abit, switch
segments), the model checkers pass (or catch the negative control), the audit passes.
  python3 flow/regress.py --shape k16m8 --gl syn-unit,syn-sdf --synth-run payn_k16m8_20261006 --out DIR
  python3 flow/regress.py --shape k16m8 --gl apr --route apr/build/TSMC22/PAYN/payn_k16m8_20261006_final --out DIR
Run dirs: <out>/<shape>/<mode>/<kind>/<label>/ (GL sim.log, rtl/sim.log); summary <out>/<shape>/summary.txt.
"""
from __future__ import annotations

import argparse
import filecmp
import json
import os
import re
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
MODEL = REPO / "designs/payn/model"
CASES = REPO / "flow/cases"
TB = REPO / "designs/payn/tb"
PWR = REPO / "designs/payn/power"
SHAPES = {"k16m8": 8, "k8m16": 16}          # shape -> PAYN_M
SUITES = ["cases", "units", "sc", "int", "switch", "abit", "grid-bp", "grid-abit", "power"]
DW = "/usr/caen/synopsys-synth-2021.06-SP1/dw/sim_ver"


# ------------------------------------------------------------------ helpers --
def sh(cmd: list[str], cwd: Path, log: Path) -> int:
    """Run cmd in cwd with stdout+stderr to log; return the exit code."""
    with open(log, "w") as f:
        return subprocess.run(cmd, cwd=cwd, stdout=f, stderr=subprocess.STDOUT,
                              env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"}).returncode


def fresh_dir(d: Path) -> Path:
    if d.exists():
        shutil.rmtree(d)
    d.mkdir(parents=True)
    return d


def plusargs(flags: str) -> list[str]:
    return [] if flags == "-" else ["+" + f for f in flags.split(",")]


ONLY: re.Pattern | None = None                  # --only: run just the rows whose label matches


def selected(label: str) -> bool:
    return ONLY is None or ONLY.search(label) is not None


def table(name: str, sep: str | None = None) -> list[list[str]]:
    rows = []
    for line in (CASES / name).read_text().splitlines():
        if line.strip() and not line.lstrip().startswith("#"):
            row = [x.strip() for x in line.split(sep)] if sep else line.split()
            if selected(row[0]):
                rows.append(row)
    return rows


def last_line(p: Path) -> str:
    lines = p.read_text(errors="replace").strip().splitlines() if p.is_file() else []
    return lines[-1] if lines else ""


def tag_present(log: str, tag: str) -> bool:
    return re.search(rf"^\[{tag}\] [0-9]", log, re.M) is not None


def contract_count(log: str, pass_prefix: str) -> int:
    m = re.search(rf"^{re.escape(pass_prefix)}.*sc_contract=(\d+)", log, re.M)
    return int(m[1]) if m else -1


class Ctx:
    def __init__(self, shape: str, out: Path, jobs: int):
        self.shape, self.m, self.out, self.jobs = shape, SHAPES[shape], (out / shape).resolve(), jobs
        self.builds: dict[str, Path] = {}

    def simv(self, key: str, tb: Path, defines: list[str] = (), top: str = "Top") -> Path:
        """Compile tb once per (key, shape); return the simv path."""
        if key in self.builds:
            return self.builds[key]
        b = fresh_dir(self.out / "build" / key)
        cmd = ["vcs", "-sverilog", "+vc", "-Mupdate", "-line", "-full64", "-xprop=tmerge", "-lca",
               "-debug_access+pp", f"+incdir+{REPO / 'designs'}", "-assert", "svaext",
               "-timescale=1ns/1ps", f"+define+PAYN_M={self.m}", *defines,
               "-o", str(b / "simv"), f"-Mdir={b / 'obj'}", "-y", DW, "+libext+.v+",
               f"+incdir+{DW}", str(tb), "-top", top]
        if sh(cmd, b, b / "compile.log") != 0 or not (b / "simv").is_file():
            raise RuntimeError(f"compile failed: {b / 'compile.log'}")
        self.builds[key] = b / "simv"
        return self.builds[key]

    def model(self, tool: str, *args: str, cwd: Path, log: Path) -> int:
        return sh([sys.executable, str(MODEL / tool), *args], cwd, log)

    def run_all(self, fn, rows) -> list[tuple[bool, str]]:
        with ThreadPoolExecutor(self.jobs) as ex:
            return list(ex.map(lambda r: fn(*r), rows))


# -------------------------------------------------------------------- cases --
CASE_SETS = ("golden", "extra", "rv")
EMIT_SET = {"golden": "base", "extra": "extra", "rv": "review"}   # sc_cases.py --set


def suite_cases(c: Ctx) -> list[tuple[bool, str]]:
    res = []
    for s in CASE_SETS:
        d = fresh_dir(c.out / "cases" / s)
        rc = c.model("sc_cases.py", "emit", "--set", EMIT_SET[s], "--shape", c.shape, "--out", str(d),
                     cwd=REPO, log=c.out / "cases" / f"{s}.log")
        n = len([x for x in d.iterdir() if x.is_dir()])
        res.append((rc == 0 and n > 0, f"emit {s}: {n} cases" + ("" if rc == 0 else f" (rc {rc})")))
    return res


def resolve(c: Ctx, spec: str) -> str:
    """Comma list of case names / @golden / @extra / @rv / @all -> comma list of case dirs."""
    root, out = c.out / "cases", []
    for x in spec.split(","):
        sets = {"@golden": ["golden"], "@extra": ["extra"], "@rv": ["rv"], "@all": list(CASE_SETS)}.get(x)
        if sets:
            out += [str(d) for s in sets for d in sorted((root / s).iterdir()) if d.is_dir()]
            continue
        hit = [root / s / x for s in CASE_SETS if (root / s / x).is_dir()]
        if not hit:
            raise ValueError(f"unknown case {x}")
        out.append(str(hit[0]))
    return ",".join(out)


# ----------------------------------------------------------------------- sc --
SC_TAGS = ("CHECK", "BLOCK", "KA", "PHASE", "CONTRACT")


def sc_case(c: Ctx, label: str, cases: str, flags: str, expect: str) -> tuple[bool, str]:
    d = fresh_dir(c.out / "sc" / label)
    simv = c.simv("array", TB / "test_payn_array.sv")
    rc = sh([str(simv), "+MODE=sc", "+CASES=" + resolve(c, cases), *plusargs(flags)], d, d / "sim.log")
    log = (d / "sim.log").read_text(errors="replace")
    tags = {t for t in SC_TAGS if tag_present(log, t)}
    res = re.search(r"^RESULT (.*)", log, re.M)
    if expect == "pass":
        ok = rc == 0 and "PASS: PaYN array bench" in log and not tags
        return ok, f"{label}: {'PASS' if ok else 'FAIL'} ({res[1] if res else 'no RESULT'}" + \
            (f"; tags {sorted(tags)})" if tags else ")")
    if "FAIL: PaYN array bench" not in log:
        return False, f"{label}: FAIL (negative control not caught)"
    for t in expect.removeprefix("fail:").split("+"):
        if t.startswith("!") and t[1:] in tags:
            return False, f"{label}: FAIL (tag {t[1:]} present, expected absent; tags {sorted(tags)})"
        if not t.startswith("!") and t not in tags:
            return False, f"{label}: FAIL (tag {t} missing; tags {sorted(tags)})"
    return True, f"{label}: PASS (negative control caught, tags {sorted(tags)})"


def suite_sc(c: Ctx) -> list[tuple[bool, str]]:
    rows = [[f"{s}_{d.name}", d.name, "INT_JUNK", "pass"]
            for s in CASE_SETS for d in sorted((c.out / "cases" / s).iterdir())
            if d.is_dir() and selected(f"{s}_{d.name}")]
    rows += table("sc.txt")
    c.simv("array", TB / "test_payn_array.sv")
    return c.run_all(lambda *r: sc_case(c, *r), rows)


# ---------------------------------------------------------------------- int --
def int_workload(c: Ctx, kind: str, d: Path, ba, bw, L, mrows, ncols, dist, seed) -> None:
    rc = c.model("int_workload.py", kind, "--ba", str(ba), "--bw", str(bw), "--L", str(L),
                 "--mrows", str(mrows), "--ncols", str(ncols), "--dist", dist, "--seed", str(seed),
                 "--shape", c.shape, "--out-dir", str(d), cwd=REPO, log=d / "gen.log")
    if rc != 0:
        raise RuntimeError(f"workload generation failed: {d / 'gen.log'}")


def int_check(c: Ctx, kind: str, d: Path, *extra: str) -> bool:
    return c.model("int_trace.py", kind, str(d), "--json", str(d / "check.json"), "--shape", c.shape,
                   *extra, cwd=REPO, log=d / "check.log") == 0


def int_case(c: Ctx, label, ba, bw, L, mrows, ncols, dist, seed, flags, expect) -> tuple[bool, str]:
    d = fresh_dir(c.out / "int" / label)
    int_workload(c, "bp", d, ba, bw, L, mrows, ncols, dist, seed)
    simv = c.simv("array", TB / "test_payn_array.sv")
    rc = sh([str(simv), "+MODE=int", f"+BA={ba}", f"+BW={bw}", f"+L={L}", f"+MROWS={mrows}",
             f"+NCOLS={ncols}", *plusargs(flags)], d, d / "sim.log")
    log = (d / "sim.log").read_text(errors="replace")
    prefix = "PASS: PaYN bit-plane INT bench"
    bench_pass = rc == 0 and prefix in log
    if expect in ("fail:TIMING", "fail:CONTRACT"):
        tag = "TIMING-FAIL" if expect == "fail:TIMING" else "INT-CONTRACT"
        ok = not bench_pass and f"[{tag}]" in log
        return ok, f"{label}: {'PASS (negative control caught by [' + tag + '])' if ok else 'FAIL (expected [' + tag + '])'}"
    if not bench_pass:
        return False, f"{label}: FAIL (simulation error, {d / 'sim.log'})"
    scc = contract_count(log, prefix)
    if int_check(c, "bp", d):
        if expect == "fail:SCCONTRACT":
            return scc > 0, f"{label}: {'PASS' if scc > 0 else 'FAIL'} (bit-exact; [SC-CONTRACT] {scc})"
        if expect != "pass":
            return False, f"{label}: FAIL (negative control not caught)"
        return scc == 0, f"{label}: {'PASS' if scc == 0 else 'FAIL'} {last_line(d / 'check.log')}" + \
            ("" if scc == 0 else f" ([SC-CONTRACT] {scc} in a legal run)")
    caught = expect == "fail:CHECK" and last_line(d / "check.log").startswith("[FAIL]")
    return caught, f"{label}: {'PASS (caught by the checker)' if caught else 'FAIL'} {last_line(d / 'check.log')}"


def coverage(c: Ctx, suite: str, formula) -> tuple[bool, str]:
    """Lap coverage over the passing runs (pending carry and borrow folded by laps) and periods."""
    cov = dict(lap_edges=0, tile_laps=0, with_pending_carry=0, with_pending_borrow=0)
    silent, rows, bad = 0, 0, []
    for d in sorted((c.out / suite).iterdir()):
        j = d / "check.json"
        if not j.is_file() or json.loads(j.read_text()).get("status") != "PASS":
            continue
        log = (d / "sim.log").read_text(errors="replace")
        m = re.search(r"LAP_COVERAGE (.*)", log)
        for k, v in re.findall(r"(\w+)=(\d+)", m[1] if m else ""):
            cov[k] += int(v)
        s = re.search(r"INT_SILENT_MAC_SAMPLES (\d+)", log)
        silent += int(s[1]) if s else 0
        rows += 1
        if not formula(d, json.loads(j.read_text())):
            bad.append(d.name)
    ok = rows > 0 and not bad and cov["with_pending_carry"] > 0 and cov["with_pending_borrow"] > 0
    if ONLY is not None:                       # a filtered run need not cover both pending kinds
        ok = rows > 0 and not bad
    return ok, (f"{suite} totals: {rows} bit-exact runs, block periods = formula in {rows - len(bad)}"
                f"{' (mismatch: ' + ','.join(bad) + ')' if bad else ''}; lap coverage "
                + ", ".join(f"{k} {v}" for k, v in cov.items())
                + f"; {silent} INT MACs consumed with the SC streams silent")


def bp_period_ok(d: Path, _j: dict) -> bool:
    lines = (d / "bpt_sched.txt").read_text().split("\n")
    kv = {k: int(v) for k, v in re.findall(r"(\w+)=(-?\d+)", lines[0])}
    starts = [int(x.split()[2]) for x in lines[1:] if x.startswith("DRAIN_START")]
    spacing = {b - a for a, b in zip(starts, starts[1:])}
    blk = kv["bw"] * kv["nb"] + (kv["bw"] - 1) + 8
    return kv["lap_len"] == 1 and kv["blk_len"] == kv["formula"] == blk and spacing <= {blk}


def suite_int(c: Ctx) -> list[tuple[bool, str]]:
    c.simv("array", TB / "test_payn_array.sv")
    res = c.run_all(lambda *r: int_case(c, *r), table("int.txt"))
    return res + [coverage(c, "int", bp_period_ok)]


# ------------------------------------------------------------------- switch --
SW_CFGS = ["8:8:256:1:8:0:0:1", "8:4:384:1:8:1:1:0", "4:4:256:2:8:2:0:1",
           "8:8:128:1:16:3:1:1", "4:4:384:2:8:0:1:0", "8:4:128:1:8:0:0:0"]


def sw_case(c: Ctx, label, flags, expect, items) -> tuple[bool, str]:
    d = fresh_dir(c.out / "switch" / label)
    seq, segs = [], []
    for it in items.split():
        if it.startswith("i:"):
            ba, bw, L, mr, nc, mode_at, junk, lro, dist, seed = it.split(":")[1:]
            s = d / f"i{len(segs)}"
            s.mkdir()
            int_workload(c, "bp", s, ba, bw, L, mr, nc, dist, seed)
            (s / "bpt_cfg.txt").write_text(f"{ba} {bw} {L} {mr} {nc} {mode_at} {junk} {lro}\n")
            seq.append(f"int:{s}")
            segs.append(s)
        else:
            seq.append("sc:" + resolve(c, it))
    simv = c.simv("array", TB / "test_payn_array.sv")
    rc = sh([str(simv), "+MODE=switch", "+SWITCH=" + ",".join(seq), *plusargs(flags)], d, d / "sim.log")
    log = (d / "sim.log").read_text(errors="replace")
    if expect == "pass":
        if rc != 0 or "PASS: PaYN switch bench" not in log:
            return False, f"{label}: FAIL (bench, {d / 'sim.log'})"
        bad = sum(not int_check(c, "bp", s) for s in segs)
        return bad == 0, f"{label}: {'PASS' if bad == 0 else 'FAIL'} ({len(segs)} INT segments, {bad} not bit-exact)"
    if expect in ("fail:TIMING", "fail:INTCONTRACT"):
        tag = "TIMING-FAIL" if expect == "fail:TIMING" else "INT-CONTRACT"
        ok = f"[{tag}]" in log and not re.search(r"^PASS:", log, re.M)
        return ok, f"{label}: {'PASS (caught by [' + tag + '])' if ok else 'FAIL (expected [' + tag + '])'}"
    if "FAIL: PaYN switch bench" not in log:
        return False, f"{label}: FAIL (negative control not caught)"
    tags = {t for t in (*SC_TAGS, "INTCOUNT") if re.search(rf"^\[{t}\] ", log, re.M)}
    if "cuts a block" in log:
        tags.add("CUT")
    missing = [t for t in expect.removeprefix("fail:").split("+") if t not in tags]
    return not missing, f"{label}: {'PASS (negative control caught' if not missing else 'FAIL (missing ' + ','.join(missing)}, tags {sorted(tags)})"


def suite_switch(c: Ctx) -> list[tuple[bool, str]]:
    every = [d.name for s in CASE_SETS for d in sorted((c.out / "cases" / s).iterdir()) if d.is_dir()]
    allseq = " ".join(f"{n} i:{SW_CFGS[k % 6]}:uniform:{100 + k}" for k, n in enumerate(every))
    rows = [[lab, fl, ex, allseq if it == "@ALL" else it] for lab, fl, ex, it in table("switch.txt", "|")]
    c.simv("array", TB / "test_payn_array.sv")
    return c.run_all(lambda *r: sw_case(c, *r), rows)


# --------------------------------------------------------------------- abit --
def abit_case(c: Ctx, label, ba, bw, L, mrows, ncols, dist, seed, flags, expect) -> tuple[bool, str]:
    d = fresh_dir(c.out / "abit" / label)
    int_workload(c, "abit", d, ba, bw, L, mrows, ncols, dist, seed)
    simv = c.simv("array", TB / "test_payn_array.sv")
    rc = sh([str(simv), "+MODE=abit", f"+BA={ba}", f"+BW={bw}", f"+L={L}", f"+MROWS={mrows}",
             f"+NCOLS={ncols}", f"+SEED={seed}", *plusargs(flags)], d, d / "sim.log")
    log = (d / "sim.log").read_text(errors="replace")
    prefix = "PASS: PaYN abit INT bench"
    bench_pass = rc == 0 and prefix in log
    if expect == "fail:CONTRACT":
        ok = not bench_pass and "[INT-CONTRACT]" in log
        return ok, f"{label}: {'PASS (caught by [INT-CONTRACT])' if ok else 'FAIL (expected [INT-CONTRACT])'}"
    if not bench_pass:
        return False, f"{label}: FAIL (simulation error, {d / 'sim.log'})"
    scc = contract_count(log, prefix)
    if expect == "caught":
        ok = int_check(c, "abit", d, "--expect-fail") and scc == 0
        return ok, f"{label}: {'PASS' if ok else 'FAIL'} (negative control {last_line(d / 'check.log')})"
    if not int_check(c, "abit", d):
        return False, f"{label}: FAIL {last_line(d / 'check.log')}"
    if expect == "fail:SCCONTRACT":
        return scc > 0, f"{label}: {'PASS' if scc > 0 else 'FAIL'} (bit-exact; [SC-CONTRACT] {scc})"
    return scc == 0, f"{label}: {'PASS' if scc == 0 else 'FAIL'} {last_line(d / 'check.log')}"


def abit_period_ok(_d: Path, j: dict) -> bool:
    return j["period_ok"] and j["measured_periods"] == [j["formula"]]


def suite_abit(c: Ctx) -> list[tuple[bool, str]]:
    c.simv("array", TB / "test_payn_array.sv")
    res = c.run_all(lambda *r: abit_case(c, *r), table("abit.txt"))
    return res + [coverage(c, "abit", abit_period_ok)]


# ------------------------------------------------------------- grid suites --
def grid_simv(c: Ctx, shape: str) -> Path:
    pr, pc = shape.split("x")
    return c.simv(f"grid{shape}", TB / "test_payn_pe_grid.sv",
                  [f"+define+GRID_PR={pr}", f"+define+GRID_PC={pc}"])


def grid_case(c: Ctx, mode, label, shape, ba, bw, L, mrows, ncols, dist, seed, flags, expect) -> tuple[bool, str]:
    suite = f"grid-{mode}"
    d = fresh_dir(c.out / suite / label)
    int_workload(c, mode, d, ba, bw, L, mrows, ncols, dist, seed)
    rc = sh([str(grid_simv(c, shape)), f"+MODE={mode}", f"+BA={ba}", f"+BW={bw}", f"+L={L}",
             f"+MROWS={mrows}", f"+NCOLS={ncols}", *plusargs(flags)], d, d / "sim.log")
    log = (d / "sim.log").read_text(errors="replace")
    if rc != 0 or not re.search(r"^PASS: PaYN .*grid bench", log, re.M):
        return False, f"{label}: FAIL (simulation error, {d / 'sim.log'})"
    kind = "bp-grid" if mode == "bp" else "abit-grid"
    if expect == "caught":
        ok = int_check(c, kind, d, "--expect-fail")
        return ok, f"{label}: {'PASS' if ok else 'FAIL'} (negative control {last_line(d / 'check.log')})"
    passed = int_check(c, kind, d)
    if expect == "pass":
        return passed, f"{label}: {'PASS' if passed else 'FAIL'} {last_line(d / 'check.log')}"
    nm = json.loads((d / "check.json").read_text()).get("n_mismatch", 0) if (d / "check.json").is_file() else 0
    ok = not passed and nm > 0
    return ok, f"{label}: {'PASS (caught: ' + str(nm) + ' mismatches)' if ok else 'FAIL (not caught)'}"


def suite_grid(c: Ctx, mode: str) -> list[tuple[bool, str]]:
    rows = []
    if mode == "bp":
        for label, shape, ba, bw, L, nig, njg, dist, seed, flags, expect in table("grid_bp.txt"):
            pr, pc = (int(x) for x in shape.split("x"))
            rows.append([label, shape, ba, bw, L, pr * (8 // int(ba)) * int(nig), 8 * pc * int(njg),
                         dist, seed, flags, expect])
    else:
        rows = table("grid_abit.txt")
    for shape in sorted({r[1] for r in rows}):
        grid_simv(c, shape)
    return c.run_all(lambda *r: grid_case(c, mode, *r), rows)


# -------------------------------------------------------------------- units --
def suite_units(c: Ctx) -> list[tuple[bool, str]]:
    d = fresh_dir(c.out / "units" / "run")
    simv = c.simv("units", TB / "test_payn_units.sv")
    rc = sh([str(simv)], d, d / "sim.log")
    log = (d / "sim.log").read_text(errors="replace")
    ok = rc == 0 and re.search(r"^PASS: PaYN units", log, re.M) is not None
    return [(ok, f"units: {'PASS' if ok else 'FAIL'} {last_line(d / 'sim.log') if not ok else ''}")]


# -------------------------------------------------------------------- power --
def power_sc(c: Ctx, workload: str, junk: bool) -> tuple[bool, str]:
    label = f"sc_{workload}" + ("_junk" if junk else "")
    d = fresh_dir(c.out / "power" / label)
    defines = (["+define+SC_LADDER"] if workload == "ladder" else []) + (["+define+SC_INT_JUNK"] if junk else [])
    simv = c.simv(f"power_{label}", PWR / "power_payn_sc.sv", defines)
    rc = sh([str(simv)], d, d / "sim.log")
    log = (d / "sim.log").read_text(errors="replace")
    if rc != 0 or not re.search(r"^PASS: PaYN SC power bench", log, re.M):
        return False, f"{label}: FAIL (bench, {d / 'sim.log'})"
    ok = c.model("sc_trace.py", str(d / "sc_trace.txt"), "--json", str(d / "check.json"), "--shape", c.shape,
                 cwd=REPO, log=d / "check.log") == 0
    return ok, f"{label}: {'PASS' if ok else 'FAIL'} {last_line(d / 'check.log')}"


def power_int(c: Ctx, mode, label, ba, bw, L, mrows, ncols, saif_mode, flags, chk="-") -> tuple[bool, str]:
    name = f"{mode}_{label}"
    d = fresh_dir(c.out / "power" / name)
    if mode == "bp":
        int_workload(c, "bp", d, ba, bw, L, mrows, ncols, "uniform", 1)
    else:
        rc = c.model("int_workload.py", "abit", "--ba", ba, "--bw", bw, "--L", L, "--mrows", mrows,
                     "--ncols", ncols, "--dist", "plain", "--plain-dist", "uniform", "--seed", "1",
                     "--row-unit", "8", "--shape", c.shape, "--out-dir", str(d), cwd=REPO, log=d / "gen.log")
        if rc != 0:
            return False, f"{name}: FAIL (workload, {d / 'gen.log'})"
    simv = c.simv("power_int", PWR / "power_payn_int.sv")
    rc = sh([str(simv), f"+MODE={mode}", f"+BA={ba}", f"+BW={bw}", f"+L={L}", f"+MROWS={mrows}",
             f"+NCOLS={ncols}", f"+SAIF_MODE={saif_mode}", *plusargs(flags)], d, d / "sim.log")
    log = (d / "sim.log").read_text(errors="replace")
    bench = "bit-plane" if mode == "bp" else "abit"
    if rc != 0 or not re.search(rf"^PASS: PaYN {bench} INT power bench", log, re.M):
        return False, f"{name}: FAIL (bench, {d / 'sim.log'})"
    ok = int_check(c, f"{mode}-power", d, *([] if chk == "-" else [chk]))
    return ok, f"{name}: {'PASS' if ok else 'FAIL'} {last_line(d / 'check.log')}"


def suite_power(c: Ctx) -> list[tuple[bool, str]]:
    jobs = [lambda w=w, j=j: power_sc(c, w, j) for w in ("uniform", "ladder") for j in (False, True)
            if selected(f"sc_{w}" + ("_junk" if j else ""))]
    jobs += [lambda r=r: power_int(c, "bp", *r) for r in table("power_bp.txt")]
    jobs += [lambda r=r: power_int(c, "abit", *r) for r in table("power_abit.txt")]
    for key, tb, defs in [("power_int", "power_payn_int.sv", [])] + \
            [(f"power_sc_{w}" + ("_junk" if j else ""), "power_payn_sc.sv",
              (["+define+SC_LADDER"] if w == "ladder" else []) + (["+define+SC_INT_JUNK"] if j else []))
             for w in ("uniform", "ladder") for j in (False, True)]:
        c.simv(key, PWR / tb, defs)                # compile serially before the parallel runs
    with ThreadPoolExecutor(c.jobs) as ex:
        return list(ex.map(lambda f: f(), jobs))


# --------------------------------------------------------------- gate-level --
GL_MODES = ("syn-unit", "syn-sdf", "apr")
GL_SETTLE = {"syn-unit": 0, "syn-sdf": 2, "apr": 2}     # default +RESET_SETTLE per mode
GL_TB = "designs/payn/tb/test_payn_array.sv"
GL_UNIT = "+define+ARM_UD_MODEL +define+ARM_EN_X_SQUASH +delay_mode_unit +notimingcheck"
GL_SDF = "+neg_tchk +sdfverbose"
DRAIN_LATE = "+DRAIN_SAMPLE_LATE_PS=50"                   # the SDC output-delay point (OUTPUT_DELAY 0.05 ns)
SC_ERRORS = re.compile(r"Error-\[|\[TIMEOUT\]|\$fatal|Fatal:|\[X-FAIL\]")
INT_ERRORS = re.compile(r"Error-\[|\[TIMEOUT\]|\[X-FAIL\]|\[TIMING-FAIL\]")
RESULT_RE = re.compile(r"^RESULT cases=(\d+) calls=(\d+) blocks=(\d+) drains=(\d+) edges=(\d+) \| drain values (\d+) "
                       r"bad (\d+) .*stalls (\d+) stray loads (\d+)", re.M)


def text(p: Path) -> str:
    return p.read_text(errors="replace") if p.is_file() else ""


def first_line(log: str, tag: str) -> str | None:
    m = re.search(rf"^.*{re.escape(tag)}.*$", log, re.M)
    return m[0] if m else None


class Gl:
    """One gate-level mode on one shape: the netlist simv (make sim through ASTRAEA, compiled once; its compile run
    plays plain_u128), the RTL reference simv (the RTL suites' compile) and the audit of every log."""

    def __init__(self, c: Ctx, mode: str, a):
        self.c, self.mode = c, mode
        self.dir = c.out / mode
        self.target, self.top, self.synth = a.target, a.top, a.synth_run
        self.route = a.route.resolve() if a.route else None
        self.approvals = a.gl_approve.split()
        self.simv: Path | None = None
        self.head = ""

    def make_env(self) -> dict:
        return {**os.environ, "PYTHONDONTWRITEBYTECODE": "1", **({"PAYN_TOP": self.top} if self.top != "payn_array" else {})}

    def apr_run(self) -> str:
        """RUN for make sim GL=apr: the route itself when it is under the target with the target's top, else a view
        directory beside the target's runs (symlinked outputs)."""
        runs = REPO / "apr/build" / self.target
        if self.route.parent == runs.resolve() and self.top == "payn_array":
            return self.route.name
        view = runs / f"{self.route.name}_gl_view"
        if not view.exists():
            view.mkdir(parents=True)
            (view / "outputs").symlink_to(self.route / "outputs")
        if (view / "outputs").resolve() != (self.route / "outputs").resolve():
            raise RuntimeError(f"{view} is not a view of {self.route}")
        return view.name

    def compile(self) -> None:
        b = fresh_dir(self.dir / "build")
        run_dir = b / GL_TB
        run_dir.mkdir(parents=True)
        (run_dir / "cases.txt").write_text(resolve(self.c, "plain_u128") + "\n")
        defs = [f"+define+PAYN_M={self.c.m}"] + ([f"+define+PAYN_DUT={self.top}"] if self.top != "payn_array" else [])
        if self.mode == "syn-unit":
            args, vargs = ["GL=syn", f"RUN={self.synth}", "NO_SDF=1"], defs + [GL_UNIT, "+define+TB_RESET_SETTLE=0"]
        elif self.mode == "syn-sdf":
            src = REPO / "syn/build" / self.target / self.synth
            view = self.dir / "idealclk"
            d = view / self.target / self.synth
            d.mkdir(parents=True)
            (d / f"{self.top}.syn.v").symlink_to(src / f"{self.top}.syn.v")
            rc = sh([sys.executable, str(REPO / "flow/qualify.py"), "ideal-clock-sdf", str(src / f"{self.top}.syn.sdf"),
                     str(d / f"{self.top}.syn.sdf"), "--report", str(self.dir / "idealclk_report.txt")],
                    self.dir, self.dir / "idealclk.log")
            if rc != 0:
                raise RuntimeError(f"ideal-clock SDF view failed: {self.dir / 'idealclk.log'}")
            args = ["GL=syn", f"RUN={self.synth}", "SDF_CORNER=max", "NO_SDF=", f"SYN_DIR={view}"]
            vargs = defs + [GL_SDF, f"+define+TB_RESET_SETTLE={GL_SETTLE[self.mode]}"]
        else:
            args = ["GL=apr", f"RUN={self.apr_run()}", "SDF_CORNER=max", "NO_SDF="]
            vargs = defs + [GL_SDF, f"+define+TB_RESET_SETTLE={GL_SETTLE[self.mode]}"]
        cmd = ["make", "--no-print-directory", "sim", f"TARGET={self.target}", f"TB={GL_TB}", f"BUILD_DIR={b}",
               "RTL_PREFLIGHT_CMD=true", f"VCS={os.environ['FLOW_VCS']}", f"VCS_ARGS={' '.join(vargs)}", *args,
               "NTFY_CHNL=", f"ASTRAEA_FLOW={os.environ['ASTRAEA_FLOW']}"]
        with open(b / "compile.log", "w") as f:
            subprocess.run(cmd, cwd=REPO, env=self.make_env(), stdout=f, stderr=subprocess.STDOUT)
        log = text(b / "compile.log")
        if "PASS: PaYN array bench" not in log or not (run_dir / "simv").is_file():
            raise RuntimeError(f"netlist compile / smoke run failed: {b / 'compile.log'}")
        if self.mode != "syn-unit" and not ("sdf corner = max" in log and "[INFO] $sdf_annotate(" in log):
            raise RuntimeError(f"no max-corner SDF annotation in {b / 'compile.log'}")
        cut = log.find("Running gate-level simulation")
        self.head = log[:log.index("\n", cut) + 1] if cut >= 0 else log
        self.simv = run_dir / "simv"

    def run2(self, d: Path, args: list[str]) -> tuple[str, str]:
        """The same plusargs on the netlist (in d) and on RTL (in d/rtl); returns both logs."""
        sh([str(self.simv), "+vcs+lic+wait", *args], d, d / "sim.log")
        sh([str(self.c.simv("array", TB / "test_payn_array.sv")), *args], d / "rtl", d / "rtl" / "sim.log")
        return text(d / "sim.log"), text(d / "rtl" / "sim.log")

    def audit(self, d: Path, expected: str) -> tuple[bool, str]:
        if self.mode == "syn-unit":
            return True, "unit delay (no timing audit)"
        body = self.head + text(d / "sim.log")
        q = [sys.executable, str(REPO / "flow/qualify.py")]
        if self.mode == "syn-sdf":
            (d / "validation_input.log").write_text(body)
            sh(q + ["routed-gl", str(d / "validation_input.log"), "--expected-pass", expected,
                    "--json", str(d / "timing_qualification.json")], d, d / "timing_validation.log")
            rc = sh(q + ["syn-gl", str(d / "validation_input.log"), str(d / "timing_qualification.json")],
                    d, d / "syn_gl.log")
            return rc == 0, f"timing view {'OK' if rc == 0 else 'FAIL'}: {last_line(d / 'syn_gl.log')}"
        (d / "simulation.log").write_text(body)
        rc = sh(q + ["gl-audit", str(d), "--work", str(self.dir), "--expected-pass", expected, *self.approvals],
                d, d / "audit.log")
        if rc != 0:
            return False, f"audit FAIL ({last_line(d / 'audit.log')[:200]})"
        fin = json.loads((d / "timing_qualification.json").read_text())
        strict = json.loads((d / "timing_qualification_strict.json").read_text())
        how = "strict" if strict["status"] == "PASS" else \
            (f"strict FAIL {strict['rejection_reasons']} -> approved {len(fin['approved_annotated_interconnects'])} "
             f"IWSBA, {len(fin['approved_negative_iopath_clamps'])} NDI")
        return True, f"audit PASS ({how}; post-reset violations {fin['post_reset_timing_violations']})"


def gl_sc_case(g: Gl, label, cases, flags, settle, expect) -> tuple[bool, str]:
    d = fresh_dir(g.dir / "sc" / label)
    (d / "rtl").mkdir()
    st = GL_SETTLE[g.mode] if settle == "-" else int(settle)
    args = ["+MODE=sc", "+CASES=" + resolve(g.c, cases), *plusargs(flags), f"+RESET_SETTLE={st}"]
    if g.mode == "apr":
        args.append(DRAIN_LATE)
    gl, rtl = g.run2(d, args)
    fg, fr = RESULT_RE.search(gl), RESULT_RE.search(rtl)
    if not fg or not fr:
        return False, f"{label}: FAIL [{expect}] (missing RESULT; {d})"
    same = fg.groups() == fr.groups()
    dvals, dbad = int(fg[6]), int(fg[7])
    if expect == "pass":
        ok = "PASS: PaYN array bench" in gl and "PASS: PaYN array bench" in rtl and dbad == 0
    else:
        ok = ("FAIL: PaYN array bench" in gl and "FAIL: PaYN array bench" in rtl and dbad > 0
              and re.search(r"^\[CHECK\] [0-9]", gl, re.M) is not None)
    ok = ok and same and not SC_ERRORS.search(gl)
    a_ok, a_msg = g.audit(d, "PASS: PaYN array bench" if expect == "pass" else "RESULT cases=")
    ok = ok and a_ok
    return ok, (f"{label}: {'PASS' if ok else 'FAIL'} [{expect}] settle {st} {flags} | drains {dbad}/{dvals} wrong, "
                f"{fg[5]} edges, stalls {fg[8]}, stray {fg[9]} | GL == RTL: {'yes' if same else 'NO'} | {a_msg}")


def gl_int_case(g: Gl, label, ba, bw, L, mrows, ncols, dist, seed, flags, expect) -> tuple[bool, str]:
    d = fresh_dir(g.dir / "int" / label)
    (d / "rtl").mkdir()
    int_workload(g.c, "bp", d, ba, bw, L, mrows, ncols, dist, seed)
    for f in ("bpt_a.hex", "bpt_w.hex"):
        shutil.copy2(d / f, d / "rtl" / f)
    gl, rtl = g.run2(d, ["+MODE=int", f"+BA={ba}", f"+BW={bw}", f"+L={L}", f"+MROWS={mrows}", f"+NCOLS={ncols}",
                         *plusargs(flags)])
    if expect == "fail:TIMING":
        tg, tr = first_line(gl, "[TIMING-FAIL]"), first_line(rtl, "[TIMING-FAIL]")
        ok = bool(tg and tr and tg == tr) and not re.search(r"^PASS:", gl, re.M)
        return ok, f"{label}: {'PASS' if ok else 'FAIL'} [{expect}] {'caught by the same [TIMING-FAIL] line in GL and RTL' if ok else 'expected one [TIMING-FAIL] line in GL and RTL'}"
    ok = "PASS: PaYN bit-plane INT bench" in gl and not INT_ERRORS.search(gl)
    if expect.startswith("glonly"):
        twin = "[INT-CONTRACT]" in rtl and not re.search(r"^PASS:", rtl, re.M)
        note = "RTL stopped by [INT-CONTRACT] (a monitor not in the netlist)" if twin else "RTL did not stop at [INT-CONTRACT]"
    else:
        twin = ("PASS: PaYN bit-plane INT bench" in rtl
                and filecmp.cmp(d / "bpt_trace.txt", d / "rtl/bpt_trace.txt", shallow=False))
        note = "GL trace == RTL trace" if twin else "GL trace / RTL run differ"
    chk = int_check(g.c, "bp", d)
    caught = not chk and last_line(d / "check.log").startswith("[FAIL]")
    ok = ok and twin and (chk if expect == "pass" else caught)
    a_ok, a_msg = g.audit(d, "PASS: PaYN bit-plane INT bench")
    ok = ok and a_ok
    return ok, f"{label}: {'PASS' if ok else 'FAIL'} [{expect}] {flags} | {note}; checker: {last_line(d / 'check.log')[:150]} | {a_msg}"


def gl_sw_case(g: Gl, label, flags, expect, items) -> tuple[bool, str]:
    d = fresh_dir(g.dir / "switch" / label)
    (d / "rtl").mkdir()
    seq, rseq, segs = [], [], []
    for it in items.split():
        if it.startswith("i:"):
            ba, bw, L, mr, nc, mode_at, junk, lro, dist, seed = it.split(":")[1:]
            s, rs = d / f"i{len(segs)}", d / "rtl" / f"i{len(segs)}"
            s.mkdir()
            rs.mkdir()
            int_workload(g.c, "bp", s, ba, bw, L, mr, nc, dist, seed)
            (s / "bpt_cfg.txt").write_text(f"{ba} {bw} {L} {mr} {nc} {mode_at} {junk} {lro}\n")
            for f in ("bpt_a.hex", "bpt_w.hex", "bpt_cfg.txt"):
                shutil.copy2(s / f, rs / f)
            seq.append(f"int:{s}")
            rseq.append(f"int:{rs}")
            segs.append(s)
        else:
            seq.append("sc:" + resolve(g.c, it))
            rseq.append(seq[-1])
    extra = [DRAIN_LATE] if g.mode == "apr" else []
    sh([str(g.simv), "+vcs+lic+wait", "+MODE=switch", "+SWITCH=" + ",".join(seq), *plusargs(flags), *extra],
       d, d / "sim.log")
    sh([str(g.c.simv("array", TB / "test_payn_array.sv")), "+MODE=switch", "+SWITCH=" + ",".join(rseq),
        *plusargs(flags), *extra], d / "rtl", d / "rtl" / "sim.log")
    gl, rtl = text(d / "sim.log"), text(d / "rtl" / "sim.log")
    if expect == "fail:TIMING":
        tg, tr = first_line(gl, "[TIMING-FAIL]"), first_line(rtl, "[TIMING-FAIL]")
        ok = bool(tg and tr and tg == tr) and not re.search(r"^PASS:", gl, re.M)
        return ok, f"{label}: {'PASS' if ok else 'FAIL'} [{expect}] {'caught by the same [TIMING-FAIL] line in GL and RTL' if ok else 'expected one [TIMING-FAIL] line in GL and RTL'}"
    msg = []
    fg, fr = RESULT_RE.search(gl), RESULT_RE.search(rtl)
    if not fg or not fr or fg.groups() != fr.groups():
        msg.append("SC RESULT GL != RTL")
    for k, s in enumerate(segs):
        if not filecmp.cmp(s / "bpt_trace.txt", d / "rtl" / s.name / "bpt_trace.txt", shallow=False):
            msg.append(f"segment {k} trace differs")
        if not int_check(g.c, "bp", s):
            msg.append(f"segment {k} not bit-exact")
    if INT_ERRORS.search(gl):
        msg.append("GL error tag")
    if expect == "pass":
        if not ("PASS: PaYN switch bench" in gl and "PASS: PaYN switch bench" in rtl):
            msg.append("no bench PASS")
    elif not ("FAIL: PaYN switch bench" in gl and "FAIL: PaYN switch bench" in rtl
              and re.search(r"^\[CHECK\] [0-9]", gl, re.M)):
        msg.append("negative control not caught")
    a_ok, a_msg = g.audit(d, "PASS: PaYN switch bench" if expect == "pass" else "SWITCH_RESULT")
    ok = not msg and a_ok
    res = re.search(r"^SWITCH_RESULT (.*)$", gl, re.M)
    return ok, (f"{label}: {'PASS' if ok else 'FAIL'} [{expect}] {flags} | {len(segs)} INT segments, traces GL == RTL"
                f"{'' if 'trace differs' not in ' '.join(msg) else ' NO'}; {res[1] if res else 'no SWITCH_RESULT'}"
                f"{' | ' + '; '.join(msg) if msg else ''} | {a_msg}")


def gl_abit_case(g: Gl, label, ba, bw, L, mrows, ncols, dist, seed, flags, expect) -> tuple[bool, str]:
    d = fresh_dir(g.dir / "abit" / label)
    (d / "rtl").mkdir()
    int_workload(g.c, "abit", d, ba, bw, L, mrows, ncols, dist, seed)
    for f in ("bpt_a.hex", "bpt_w.hex"):
        shutil.copy2(d / f, d / "rtl" / f)
    gl, rtl = g.run2(d, ["+MODE=abit", f"+BA={ba}", f"+BW={bw}", f"+L={L}", f"+MROWS={mrows}", f"+NCOLS={ncols}",
                         f"+SEED={seed}", *plusargs(flags)])
    ok = ("PASS: PaYN abit INT bench" in gl and "PASS: PaYN abit INT bench" in rtl and not INT_ERRORS.search(gl))
    same = filecmp.cmp(d / "abit_trace.txt", d / "rtl/abit_trace.txt", shallow=False) if ok else False
    chk = int_check(g.c, "abit", d, *(["--expect-fail"] if expect == "caught" else []))
    a_ok, a_msg = g.audit(d, "PASS: PaYN abit INT bench")
    ok = ok and same and chk and a_ok
    return ok, (f"{label}: {'PASS' if ok else 'FAIL'} [{expect}] {flags} | GL trace {'==' if same else '!='} RTL trace"
                f" | {last_line(d / 'check.log')[:170]} | {a_msg}")


def gl_rows(name: str, mode: str, sep: str | None = None) -> list[list[str]]:
    """Rows of a gate-level table whose last column (modes) names the mode, without that column."""
    return [r[:-1] for r in table(name, sep) if mode in r[-1].split(",")]


def gl_mode(c: Ctx, mode: str, a) -> list[tuple[str, list[tuple[bool, str]]]]:
    g = Gl(c, mode, a)
    g.dir.mkdir(parents=True, exist_ok=True)
    try:
        g.compile()
    except Exception as e:                     # a compile failure fails every kind of this mode
        return [(f"{mode}", [(False, f"{mode}: FAIL ({e})")])]
    every = [d.name for s in CASE_SETS for d in sorted((c.out / "cases" / s).iterdir()) if d.is_dir()]
    allseq = " ".join(f"{n} i:{SW_CFGS[k % 6]}:uniform:{100 + k}" for k, n in enumerate(every))
    jobs = {"sc": [(gl_sc_case, r) for r in gl_rows("gl_sc.txt", mode)],
            "int": [(gl_int_case, r) for r in gl_rows("gl_int.txt", mode)],
            "switch": [(gl_sw_case, [lab, fl, ex, allseq if it == "@ALL" else it])
                       for lab, fl, ex, it in gl_rows("gl_switch.txt", mode, "|")],
            "abit": [(gl_abit_case, r) for r in gl_rows("gl_abit.txt", mode)]}
    flat = [(kind, fn, row) for kind, rows in jobs.items() for fn, row in rows]

    def one(job):
        kind, fn, row = job
        try:
            return kind, fn(g, *row)
        except Exception as e:
            return kind, (False, f"{row[0]}: FAIL ({e})")
    with ThreadPoolExecutor(c.jobs) as ex:
        done = list(ex.map(one, flat))
    out = []
    for kind in jobs:
        res = [r for k, r in done if k == kind]
        if res:
            out.append((f"{mode} {kind}", res))
    (g.dir / "runs.log").write_text("\n".join(f"{mode} {k} {r[1]}" for k, r in sorted(done, key=lambda x: x[1][1])) + "\n")
    return out


def main_gl(a) -> int:
    modes = a.gl.split(",")
    for m in modes:
        if m not in GL_MODES:
            raise SystemExit(f"unknown gate-level mode {m} (modes: {', '.join(GL_MODES)})")
    if a.shape == "both":
        raise SystemExit("--gl checks one netlist: give one --shape")
    if any(m.startswith("syn") for m in modes) and not a.synth_run:
        raise SystemExit("syn-unit / syn-sdf need --synth-run")
    if "apr" in modes and not a.route:
        raise SystemExit("apr needs --route")
    sys.path.insert(0, str(REPO / "flow"))
    from flowlib import tool_env
    os.environ.update(tool_env())               # VCS, licenses, the libraries' environment for every run
    c = Ctx(a.shape, a.out, a.jobs)
    c.out.mkdir(parents=True, exist_ok=True)
    where = ", ".join(x for x in (f"synthesis {a.synth_run}" if a.synth_run else "",
                                  f"route {a.route}" if a.route else "") if x)
    lines = [f"PaYN gate-level checks, shape {a.shape}, modes {','.join(modes)}, {where}, top {a.top}"]
    status = 0
    groups = [("cases", suite_cases(c))]
    if all(r[0] for r in groups[0][1]):
        c.simv("array", TB / "test_payn_array.sv")      # the RTL reference, compiled before the parallel runs
        for m in modes:
            groups += gl_mode(c, m, a)
    for name, res in groups:
        ok = all(r[0] for r in res)
        status |= not ok
        lines += [f"== {name}: {'PASS' if ok else 'FAIL'} ({sum(r[0] for r in res)}/{len(res)})"]
        lines += ["  " + r[1] for r in sorted(res, key=lambda r: (r[0], r[1]))]
        print(lines[-len(res) - 1], flush=True)
    lines.append(f"PaYN gate-level checks {a.shape}: {'PASS' if not status else 'FAIL'}")
    (c.out / "summary.txt").write_text("\n".join(lines) + "\n")
    print(f"{lines[-1]}  ({c.out / 'summary.txt'})")
    return status


# ------------------------------------------------------------------- driver --
RUNNERS = {
    "cases": suite_cases, "units": suite_units, "sc": suite_sc, "int": suite_int,
    "switch": suite_switch, "abit": suite_abit, "grid-bp": lambda c: suite_grid(c, "bp"),
    "grid-abit": lambda c: suite_grid(c, "abit"), "power": suite_power,
}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--shape", choices=[*SHAPES, "both"], default="k16m8")
    ap.add_argument("--suite", default=",".join(SUITES), help="comma list of " + ", ".join(SUITES))
    ap.add_argument("--jobs", type=int, default=12)
    ap.add_argument("--out", type=Path, default=REPO / "build/regress")
    ap.add_argument("--gl", help="gate-level mode: comma list of " + ", ".join(GL_MODES) + " (replaces --suite)")
    ap.add_argument("--synth-run", help="synthesis run for syn-unit / syn-sdf (syn/build/<target>/<run>)")
    ap.add_argument("--route", type=Path, help="routed run directory for apr")
    ap.add_argument("--top", default="payn_array", help="netlist top (gate-level mode)")
    ap.add_argument("--target", default="TSMC22/PAYN", help="ASTRAEA target (gate-level mode)")
    ap.add_argument("--gl-approve", default="", help="apr: gl-audit approvals, used only after a strict failure")
    ap.add_argument("--only", help="run only the case-table rows whose label matches this regular expression")
    a = ap.parse_args()
    global ONLY
    ONLY = re.compile(a.only) if a.only else None
    if a.gl:
        return main_gl(a)
    suites = a.suite.split(",")
    for s in suites:
        if s not in RUNNERS:
            ap.error(f"unknown suite {s}")
    if any(s in suites for s in ("sc", "switch")) and "cases" not in suites:
        print("note: sc/switch use the case sets from the last `cases` run")
    status = 0
    for shape in (SHAPES if a.shape == "both" else [a.shape]):
        c = Ctx(shape, a.out, a.jobs)
        c.out.mkdir(parents=True, exist_ok=True)
        lines = [f"PaYN regression, shape {shape}, suites {','.join(suites)}"]
        for s in [x for x in SUITES if x in suites]:
            try:
                res = RUNNERS[s](c)
            except Exception as e:             # a compile or setup failure fails the suite
                res = [(False, f"{s}: FAIL ({e})")]
            ok = all(r[0] for r in res)
            status |= not ok
            lines += [f"== {s}: {'PASS' if ok else 'FAIL'} ({sum(r[0] for r in res)}/{len(res)})"]
            lines += ["  " + r[1] for r in sorted(res, key=lambda r: (r[0], r[1]))]
            print(lines[-len(res) - 1], flush=True)
        lines.append(f"PaYN regression {shape}: {'PASS' if not status else 'FAIL'}")
        (c.out / "summary.txt").write_text("\n".join(lines) + "\n")
        print(f"{lines[-1]}  ({c.out / 'summary.txt'})")
    return status


if __name__ == "__main__":
    sys.exit(main())
