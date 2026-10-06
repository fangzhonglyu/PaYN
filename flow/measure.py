#!/usr/bin/env python3
"""Routed gate-level power of a qualified PaYN route: SC and INT points, each measured and gated end to end.

  python3 flow/measure.py SHAPE SYNTH_RUN                    # route apr/build/TSMC22/PAYN/<SYNTH_RUN>_final
  python3 flow/measure.py k16m8 payn_k16m8_20261006 --points sc,bp_int8_L1024_dr --jobs 6
  python3 flow/measure.py --shape k8m16 --route DIR --top NAME --evidence DIR --out DIR ...   # any qualified route
  ... --dry-run   (print every point's plan)    ... --retry-failed   (redo the failed step of a point)

Route gate (before anything runs): the route's qualification evidence (default build/flow/<SYNTH_RUN>/route, written
by flow/route.py) must hold qualification.json (final, setup and hold met) and basin/basin_gate.json (grid basin, pin
proof PASS); for a flow route its qualify, gate and routed-func stages must have passed.

Points (--points: names or the groups sc, tsweep, bp, abit, ctl, int, all; default sc,int):
  sc_uniform, sc_ladder   designs/payn/power/power_payn_sc.sv: uniform L=128, or the per-row ladder; SC_BATCHES =
                          --sc-columns / K blocks (3,072 columns: 384 blocks at K8/M16, 192 at K16/M8; the same window
                          of 3,072 edges at L=128 and the same 196,608 kernel MACs at either shape)
  sc_T<L>                 uniform L = T for every row (the stream-length sweep: T in 16..112 by 16; bench define
                          SC_UNIFORM_L)
  bp_<prec>_L<L>_<win>    designs/payn/power/power_payn_int.sv +MODE=bp (bit-plane), operands int_workload.py energy
  abit_<prec>_L<L>_<win>  the same bench with INT_ABIT (all bits in time), operands int_workload.py abit --dist plain
  bp_..._ctl              bit-plane controls on the abit operands (same MACs, same data cycles)
  windows: dr = data + laps (drain excluded, the headline), d = data only (peak), all = drain included
Per point, each step resumable by its own PASS marker under OUT/<point>/:
  gl       make sim GL=apr with the route's raw max-corner SDF (+neg_tchk +sdfverbose), on the route itself or on a
           view directory of it; the bench's exact PASS line, SDF annotation, the trace checker (sc_trace.py /
           int_trace.py bp-power, abit-power: bit-exact, SAIF window counts), qualify.py sdf-clock
  audit    qualify.py gl-audit: strict first; --gl-approve flags only after a strict failure and only with
           OUT/gl_validator_args_rationale.txt citing each one
  saif     qualify.py saif-sc (every point) and saif-int (INT points)
  power    make power_apr (PrimeTime PX, routed SPEF) on a PT-only view apr/build/TSMC22/PAYN/<route>_pt_<point>
           (symlinks to the route's outputs and SDC; the route is never written), qualify.py pt-coverage, the view's
           SAIF snapshot byte-identical to the audited SAIF
  row      OUT/<point>/row.csv: totals, first-level hierarchy, MAC accounting, pJ/MAC
  classes  (sc_uniform, sc_ladder and --classes points) flow/tcl/pt_power_classes.tcl: power and area by functional
           class; must reproduce the point's PT total
Results: OUT/sc_results.csv, OUT/int_results.csv (every point whose row passed), OUT/inputs.txt.
"""
from __future__ import annotations

import argparse
import csv
import filecmp
import json
import os
import re
import shutil
import sys
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from flowlib import (REPO, SHAPES, TARGET, TOP, PERIOD_NS, FlowError, Log, Runner, Stage, apr_dir, grep,  # noqa: E402
                     make_cmd, model_cmd, qualify, qualify_cmd, quote, require, sha256, sh, text, tool_env,
                     write_manifest)

SC_TB = "designs/payn/power/power_payn_sc.sv"
INT_TB = "designs/payn/power/power_payn_int.sv"
GL_FLAGS = "+neg_tchk +sdfverbose"
SC_COLUMNS = 3072
T_POINTS = (16, 32, 48, 64, 80, 96, 112)
PREC = {"int8": (8, 8), "int6": (6, 6), "int4": (4, 4), "w4a8": (8, 4), "w6a8": (8, 6)}
WINDOW = {"dr": 0, "d": 1, "all": 2}
HIER = ("u_pe", "u_peripheral", "u_combiner", "u_rng")


# ------------------------------------------------------------------------------------------------- points --
@dataclass(frozen=True)
class Point:
    name: str
    kind: str                     # sc | bp | abit
    workload: str = ""            # sc: uniform | ladder | T<L>
    ba: int = 0
    bw: int = 0
    L: int = 0
    mrows: int = 0
    ncols: int = 0
    seed: int = 1
    window: str = "dr"

    @property
    def tb(self) -> str:
        return SC_TB if self.kind == "sc" else INT_TB

    @property
    def mode(self) -> int:
        return WINDOW[self.window]

    @property
    def nb(self) -> int:
        return self.L // 128

    @property
    def blocks(self) -> int:
        rows_pe = 8 if self.kind == "abit" else 8 // self.ba
        return (self.mrows // rows_pe) * (self.ncols // 8)

    @property
    def active(self) -> int:
        """SAIF intervals of the window (the benches' window rules)."""
        if self.kind == "abit":
            data, laps = self.ba * self.bw * self.nb, self.ba + self.bw - 2
        else:
            data, laps = self.bw * self.nb, self.bw - 1
        per = {0: data + laps, 1: data, 2: data + laps + 8}[self.mode]
        return self.blocks * per


def int_point(kind: str, prec: str, L: int, win: str, mrows: int, ncols: int, seed: int, suffix: str = "") -> Point:
    ba, bw = PREC[prec]
    return Point(f"{kind}_{prec}_L{L}_{win}{suffix}", kind, ba=ba, bw=bw, L=L, mrows=mrows, ncols=ncols, seed=seed,
                 window=win)


def point_table() -> dict[str, Point]:
    pts = [Point("sc_uniform", "sc", "uniform"), Point("sc_ladder", "sc", "ladder")]
    pts += [Point(f"sc_T{t:03d}", "sc", f"T{t}") for t in T_POINTS]
    # bit-plane: ~3,072 data cycles per point (INT8 48 blocks, INT4 / W4A8 96); long L = one block at the peak
    pts += [int_point("bp", "int8", 1024, "dr", 6, 64, 1), int_point("bp", "int8", 1024, "all", 6, 64, 1),
            int_point("bp", "int8", 49152, "d", 1, 8, 1), int_point("bp", "w4a8", 1024, "dr", 8, 96, 5),
            int_point("bp", "int4", 1024, "dr", 12, 128, 3), int_point("bp", "int4", 1024, "all", 12, 128, 3),
            int_point("bp", "int4", 98304, "d", 2, 8, 3)]
    # all bits in time: per (precision, L) a fixed operand shape of ~3,072 data cycles
    shapes = {("int8", 384): (16, 64, 1), ("int8", 256): (24, 64, 1), ("int6", 1024): (24, 32, 9),
              ("int6", 4096): (8, 24, 9), ("int4", 1024): (24, 64, 3), ("int4", 4096): (16, 24, 3),
              ("w4a8", 1024): (8, 96, 5)}
    for prec, L, win in (("int8", 384, "dr"), ("int8", 384, "all"), ("int8", 384, "d"), ("int8", 256, "dr"),
                         ("int6", 1024, "dr"), ("int6", 1024, "all"), ("int6", 4096, "dr"), ("int6", 4096, "d"),
                         ("int4", 1024, "dr"), ("int4", 1024, "all"), ("int4", 4096, "dr"), ("int4", 4096, "d"),
                         ("w4a8", 1024, "dr")):
        pts.append(int_point("abit", prec, L, win, *shapes[(prec, L)]))
    # bit-plane controls on the abit operands
    for prec, L, win in (("int8", 384, "dr"), ("int8", 384, "all"), ("int8", 256, "dr"), ("int4", 1024, "dr"),
                         ("int4", 1024, "all"), ("int4", 4096, "dr")):
        pts.append(int_point("bp", prec, L, win, *shapes[(prec, L)], suffix="_ctl"))
    return {p.name: p for p in pts}


POINTS = point_table()
GROUPS = {
    "sc": ["sc_uniform", "sc_ladder"],
    "tsweep": [f"sc_T{t:03d}" for t in T_POINTS],
    "bp": [n for n, p in POINTS.items() if p.kind == "bp" and not n.endswith("_ctl")],
    "abit": [n for n, p in POINTS.items() if p.kind == "abit"],
    "ctl": [n for n in POINTS if n.endswith("_ctl")],
}
GROUPS["int"] = GROUPS["bp"] + GROUPS["abit"] + GROUPS["ctl"]
GROUPS["all"] = GROUPS["sc"] + GROUPS["tsweep"] + GROUPS["int"]


def select(spec: str) -> list[str]:
    out: list[str] = []
    for item in spec.split(","):
        names = GROUPS.get(item, [item])
        for n in names:
            if n not in POINTS:
                raise SystemExit(f"unknown point or group {n} (groups: {', '.join(GROUPS)})")
            if n not in out:
                out.append(n)
    return out


# ---------------------------------------------------------------------------------------------- the route --
@dataclass
class Route:
    """A qualified route and where its measurements go."""
    shape: str
    route: Path
    top: str
    out: Path
    target: str = TARGET
    approvals: tuple[str, ...] = ()
    sc_columns: int = SC_COLUMNS

    @property
    def K(self) -> int:
        return SHAPES[self.shape][0]

    @property
    def M(self) -> int:
        return SHAPES[self.shape][1]

    @property
    def run(self) -> str:
        return self.route.name

    @property
    def sc_batches(self) -> int:
        return self.sc_columns // self.K

    def file(self, suffix: str) -> Path:
        return self.route / "outputs" / f"{self.top}.{suffix}"

    @property
    def sdc(self) -> Path:
        return self.route / f"{self.top}.syn.sdc"

    @property
    def native(self) -> bool:
        """Route directly under the target with the target's top: GL can read it in place."""
        return self.route.parent.resolve() == apr_dir(self.target).resolve() and self.top == TOP

    def view(self, point: str) -> Path:
        return apr_dir(self.target) / f"{self.run}_pt_{point}"

    def env(self) -> dict:
        return {"PAYN_TOP": self.top} if self.top != TOP else {}


def gate_route(r: Route, evidence: Path, flow_route: bool) -> dict:
    """The route gate: final qualification and grid basin, from the route's qualification evidence."""
    for f in (r.file("apr.v"), r.file("apr.sdf"), r.file("spef"), r.sdc):
        require(f.is_file() and f.stat().st_size, f"route {r.route} lacks {f.name}")
    if flow_route:
        for st in ("qualify", "gate", "routed-func"):
            require(text(evidence / f"{st}.status").strip() == "PASS", f"{evidence}/{st}.status is not PASS")
    q = json.loads(text(evidence / "qualification.json") or "{}")
    b = json.loads(text(evidence / "basin/basin_gate.json") or "{}")
    require(q.get("qualification") == "final" and q.get("setup_wns_ns", -1) >= 0 and q.get("hold_wns_ns", -1) >= 0,
            f"{evidence}/qualification.json: route not final-qualified")
    require(b.get("gate", {}).get("basin") == "grid" and b.get("gate", {}).get("status") == "PASS"
            and b.get("pin_proof", {}).get("status") == "PASS", f"{evidence}/basin/basin_gate.json: not a grid basin "
                                                                 f"with a passing pin proof")
    return dict(qualification=q, basin=b)


# -------------------------------------------------------------------------------------------- GL settings --
def vcs_args(r: Route, p: Point) -> str:
    d = [f"+define+PAYN_M={r.M}"]
    if r.top != TOP:
        d.append(f"+define+PAYN_DUT={r.top}")
    if p.kind == "sc":
        # Read the post-window drain at the SDC output-delay point (OUTPUT_DELAY 0.05 ns): a routed drain
        # rail settles up to ~1.45 ns after the edge, later than the bench's default negedge sample.
        # Outside the SAIF window, so the measured energy does not depend on it.
        d.append("+define+SC_DRAIN_SAMPLE_LATE_PS=50")
        d.append(f"+define+SC_BATCHES={r.sc_batches}")
        if p.workload == "ladder":
            d.append("+define+SC_LADDER")
        elif p.workload.startswith("T"):
            d.append(f"+define+SC_UNIFORM_L={p.workload[1:]}")
    else:
        if p.kind == "abit":
            d.append("+define+INT_ABIT")
        d += [f"+define+INT_BA={p.ba}", f"+define+INT_BW={p.bw}", f"+define+INT_L={p.L}",
              f"+define+INT_MROWS={p.mrows}", f"+define+INT_NCOLS={p.ncols}", f"+define+INT_SAIF_MODE={p.mode}"]
    return " ".join(d + [GL_FLAGS])


SC_PASS_RE = (r"^PASS: PaYN SC power bench; workload (?P<wl>uniform L=\d+|ladder), (?P<blocks>\d+) blocks, "
              r"(?P<window>\d+) window edges, drain dumped \(check with sc_trace\.py\)$")


def int_pass_line(p: Point) -> str:
    head = "PaYN abit INT power bench" if p.kind == "abit" else "PaYN bit-plane INT power bench"
    line = (f"PASS: {head}; BA={p.ba} BW={p.bw} L={p.L} blocks={p.blocks} mode={p.mode} active={p.active} "
            f"drained={p.blocks * 8} combined={p.blocks * 8}")
    if p.kind == "abit":
        return line + f" block_len={p.ba * p.bw * p.nb + p.ba + p.bw - 2 + 8}"
    return line + " lap_ring_only=1"


def sc_workload_name(p: Point) -> str:
    return {"uniform": "uniform L=128", "ladder": "ladder"}.get(p.workload, f"uniform L={p.workload[1:]}")


def bench_supports(p: Point) -> str | None:
    """None if the bench can run this point, else why not."""
    if p.kind == "sc" and p.workload.startswith("T"):
        if not re.search(r"`ifndef SC_UNIFORM_L\b", text(REPO / SC_TB)):
            return f"{SC_TB} has no uniform-L workload (no SC_UNIFORM_L define)"
    return None


def gl_run_dir(r: Route, p: Point) -> tuple[str, Path]:
    """(RUN for make sim, its directory): the route itself when native, else the point's view."""
    if r.native:
        return r.run, r.route
    return r.view(p.name).name, r.view(p.name)


def make_view(r: Route, view: Path) -> None:
    """A PT/GL-only view of the route: symlinked outputs/ and SDC, its own activity/ and reports/."""
    view.mkdir(parents=True)
    (view / "outputs").symlink_to(r.route / "outputs")
    (view / r.sdc.name).symlink_to(r.sdc)
    lines = [f"View of {r.route} (outputs/ and {r.sdc.name} symlinked); written by flow/measure.py, the route is "
             "never written."]
    lines += [f"{sha256(f)}  {f.relative_to(r.route)}" for f in (r.file("apr.v"), r.file("apr.sdf"),
                                                                    r.file("spef"), r.sdc)]
    (view / "VIEW_OF.txt").write_text("\n".join(lines) + "\n")


def is_view_of(view: Path, r: Route) -> bool:
    return (view / "outputs").is_symlink() and (view / "outputs").resolve() == (r.route / "outputs").resolve()


# ------------------------------------------------------------------------------------------- point steps --
class PointRun:
    def __init__(self, r: Route, p: Point, classes: bool):
        self.r, self.p, self.classes = r, p, classes
        self.dir = r.out / p.name
        self.gl = self.dir / "gl"
        self.rundir = self.gl / p.tb                  # make sim runs the bench in BUILD_DIR/<TB>
        self.saif = self.rundir / "dut.saif"

    # ---- gl
    def gl_cmd(self) -> list[str]:
        run, _ = gl_run_dir(self.r, self.p)
        return make_cmd("sim", "GL=apr", f"TARGET={self.r.target}", f"RUN={run}", f"TB={self.p.tb}",
                        f"BUILD_DIR={self.gl}", "SDF_CORNER=max", "NO_SDF=", "RTL_PREFLIGHT_CMD=true",
                        f"VCS={tool_env()['FLOW_VCS']}", f"VCS_ARGS={vcs_args(self.r, self.p)}")

    def stim_cmd(self) -> list[str]:
        p, stim = self.p, self.dir / "stim"
        common = ["--ba", p.ba, "--bw", p.bw, "--L", p.L, "--mrows", p.mrows, "--ncols", p.ncols, "--seed", p.seed,
                  "--shape", self.r.shape, "--out-dir", stim]
        if p.kind == "abit" or p.name.endswith("_ctl"):
            unit = 8 if p.kind == "abit" else 8 // p.ba
            return model_cmd("int_workload.py", "abit", "--dist", "plain", "--plain-dist", "uniform",
                             "--row-unit", unit, *common)
        return model_cmd("int_workload.py", "energy", "--dist", "uniform", *common)

    def check_cmd(self) -> list[str]:
        j = self.gl / "trace_check.json"
        if self.p.kind == "sc":
            return model_cmd("sc_trace.py", self.rundir / "sc_trace.txt", "--json", j, "--shape", self.r.shape)
        if self.p.kind == "abit":
            return model_cmd("int_trace.py", "abit-power", self.rundir, "--json", j, "--shape", self.r.shape)
        return model_cmd("int_trace.py", "bp-power", self.rundir, "--json", j, "--shape", self.r.shape,
                         "--lap-ring-only")

    def do_gl(self, log: Log) -> None:
        r, p = self.r, self.p
        why = bench_supports(p)
        require(why is None, f"{p.name}: {why}")
        run, run_dir = gl_run_dir(r, p)
        if not r.native:
            if run_dir.exists():
                require(is_view_of(run_dir, r), f"{run_dir} exists but is not a view of {r.route}")
            else:
                make_view(r, run_dir)
        self.rundir.mkdir(parents=True)
        if p.kind != "sc":
            require(sh(self.stim_cmd(), log) == 0, "operand generation failed")
            stim = self.dir / "stim"
            prefix = "bpt" if (stim / "bpt_a.hex").is_file() else "intb"
            for side in ("a", "w"):
                shutil.copy2(stim / f"{prefix}_{side}.hex", self.rundir / f"bpt_{side}.hex")
        simlog = self.gl / "simulation.log"
        log(f"GL simulation -> {simlog}")
        rc = sh(self.gl_cmd(), simlog, env=tool_env(r.env()))
        body = text(simlog)
        if p.kind == "sc":
            m = re.search(SC_PASS_RE, body, re.M)
            require(m and m["wl"] == sc_workload_name(p) and int(m["blocks"]) == r.sc_batches,
                    f"bench PASS line for {sc_workload_name(p)}, {r.sc_batches} blocks missing (make rc {rc})")
            line, window = m[0], int(m["window"])
            if p.workload == "uniform":
                require(window == r.sc_batches * 128 // r.M, f"uniform window {window} edges")
        else:
            line = int_pass_line(p)
            require(re.search(rf"^{re.escape(line)}$", body, re.M), f"bench PASS line missing: {line} (make rc {rc})")
        (self.gl / "expected_pass.txt").write_text(line + "\n")
        require("sdf corner = max" in body and "[INFO] $sdf_annotate(" in body, "no max-corner SDF annotation")
        require(self.saif.is_file() and self.saif.stat().st_size, "no SAIF")
        require(sh(self.check_cmd(), self.gl / "trace_check.log") == 0, f"trace check failed ({self.gl}/trace_check.log)")
        chk = json.loads((self.gl / "trace_check.json").read_text())
        if p.kind == "sc":
            require(chk["window_edges"] == window and chk["blocks"] == r.sc_batches and not chk["errors"],
                    f"trace window/blocks {chk['window_edges']}/{chk['blocks']} vs PASS line {window}/{r.sc_batches}")
        else:
            require(chk["status"] == "PASS" and chk["saif_window"]["active"] == p.active,
                    f"INT trace check {chk['status']}, window {chk['saif_window']}")
        log(text(self.gl / "trace_check.log").strip().splitlines()[-1])
        rc = qualify("sdf-clock", r.file("apr.sdf"), "--period-ns", PERIOD_NS, "--sim-log", simlog,
                     "--json", self.gl / "sdf_clock_audit.json", log=self.gl / "sdf_clock_audit.log")
        require(rc == 0, f"sdf-clock failed: {text(self.gl / 'sdf_clock_audit.log').strip()}")
        for junk in (self.gl / f"{p.tb}.obj", self.rundir / "simv.daidir", self.rundir / "simv", self.rundir / "csrc"):
            if junk.is_dir():
                shutil.rmtree(junk)
            elif junk.exists():
                junk.unlink()

    # ---- audit
    def audit_cmd(self) -> list[str]:
        return qualify_cmd("gl-audit", self.gl, "--work", self.r.out, *self.r.approvals)

    def do_audit(self, log: Log) -> None:
        rc = sh(self.audit_cmd(), self.gl / "timing_audit.log")
        log(text(self.gl / "timing_audit.log").strip().splitlines()[-1] if text(self.gl / "timing_audit.log") else "")
        require(rc == 0, f"gl-audit failed ({self.gl}/timing_audit.log)")

    # ---- saif
    def do_saif(self, log: Log) -> None:
        d = self.dir / "saif"
        d.mkdir()
        rc = qualify("saif-sc", self.saif, "--expected-period-ns", PERIOD_NS, log=d / "saif_validation.log")
        require(rc == 0 and "validated SC SAIF" in text(d / "saif_validation.log"),
                f"saif-sc failed: {text(d / 'saif_validation.log').strip()[-400:]}")
        log(text(d / "saif_validation.log").strip())
        if self.p.kind != "sc":
            rc = qualify("saif-int", self.saif, "--json", d / "saif_int_audit.json", log=d / "saif_int_audit.log")
            reasons = json.loads(text(d / "saif_int_audit.json") or "{}").get("rejection_reasons", ["no verdict"])
            require(rc == 0, f"saif-int rejected the SAIF: {'; '.join(reasons)}")
            log(text(d / "saif_int_audit.log").strip().splitlines()[-1])

    # ---- power
    def power_cmd(self) -> list[str]:
        return make_cmd("power_apr", f"TARGET={self.r.target}", f"RUN={self.r.view(self.p.name).name}",
                        f"SAIF={self.saif}", "SAIF_STRIP_PATH=Top/dut")

    def do_power(self, log: Log) -> None:
        r, view, out = self.r, self.r.view(self.p.name), self.dir / "power"
        if view.exists() and (view / "reports").exists():
            require(is_view_of(view, r), f"{view} exists but is not a view of {r.route}")
            aside = view.with_name(f"{view.name}.failed_{os.getpid()}")
            view.rename(aside)
            log(f"previous view moved aside to {aside}")
        if not view.exists():
            make_view(r, view)
        out.mkdir()
        rc = sh(self.power_cmd(), out / "power_make.log", env=tool_env(r.env()))
        require(rc == 0 and grep(view / "reports/power.rpt", "Report : Averaged Power"),
                f"make power_apr failed (rc {rc}, {out}/power_make.log)")
        rc = qualify("pt-coverage", view / "reports", "--power-log", view / "power_apr.log",
                     "--json", view / "reports/power_coverage.json", log=out / "power_coverage.log")
        require(rc == 0, f"pt-coverage failed: {text(out / 'power_coverage.log')[-400:]}")
        require(filecmp.cmp(self.saif, view / "activity/dut.saif", shallow=False),
                "the view's SAIF snapshot differs from the audited SAIF")
        for f in [view / "power_apr.log", view / "VIEW_OF.txt", view / "reports/power_coverage.json",
                  *sorted((view / "reports").glob("*.rpt"))]:
            shutil.copy2(f, out / f.name)
        log(f"PT total: {total(out / 'power.rpt', 'Total Power'):.6f} mW")

    # ---- row
    def do_row(self, log: Log) -> None:
        row = sc_row(self) if self.p.kind == "sc" else int_row(self)
        with (self.dir / "row.csv").open("w", newline="") as stream:
            w = csv.DictWriter(stream, fieldnames=list(row))
            w.writeheader()
            w.writerow(row)
        log(json.dumps(row))

    # ---- classes
    def classes_env(self) -> dict:
        ref = total(self.dir / "power/power.rpt", "Total Power") / 1e3
        return dict(ROUTE_DIR=str(self.r.route), TOP=self.r.top, SAIF_FILE=str(self.saif), REF_TOTAL_W=f"{ref:.6e}")

    def do_classes(self, log: Log) -> None:
        d = self.dir / "classes"
        d.mkdir()
        tcl = REPO / "flow/tcl/pt_power_classes.tcl"
        lines = [f"route={self.r.route}", f"top={self.r.top}", f"saif={self.saif} sha256={sha256(self.saif)}"]
        lines += [f"{sha256(f)}  {f.relative_to(self.r.route)}" for f in (self.r.file("apr.v"), self.r.file("spef"),
                                                                          self.r.sdc)]
        (d / "inputs.txt").write_text("\n".join(lines) + "\n")
        env = tool_env(self.classes_env())
        sh(["pt_shell", "-file", tcl], d / "pt_power_classes.log", cwd=d, env=env)
        body = text(d / "pt_power_classes.log")
        require(not re.search(r"(?m)^(Error|ERROR):", body), f"PT errors in {d}/pt_power_classes.log")
        require("PWR_CHECK total_vs_route_power_rpt" in body, "class run lacks the total check")
        res = summarize_classes(d / "pt_power_classes.log")
        (d / "power_classes.json").write_text(json.dumps(res, indent=2) + "\n")
        (d / "power_classes.txt").write_text(classes_table(res))
        log(classes_table(res))

    def stages(self) -> list[Stage]:
        p, r = self.p, self.r
        view = r.view(p.name)
        gl_where = r.route if r.native else view
        st = [
            Stage("gl", self.gl, self.do_gl, lambda: [
                *([f"operands  {quote(self.stim_cmd())}"] if p.kind != "sc" else []),
                f"GL on    {gl_where}",
                f"sim      {quote(self.gl_cmd())}",
                f"expect   {int_pass_line(p) if p.kind != 'sc' else 'PASS: PaYN SC power bench; workload ' + sc_workload_name(p) + f', {r.sc_batches} blocks, ...'}",
                f"check    {quote(self.check_cmd())}",
                f"gate     qualify.py sdf-clock {r.file('apr.sdf')} --sim-log gl/simulation.log"]),
            Stage("audit", self.gl / "timing_qualification.json", self.do_audit,
                  lambda: [f"gate     {quote(self.audit_cmd())}"], needs=("gl",)),
            Stage("saif", self.dir / "saif", self.do_saif,
                  lambda: ["gate     qualify.py saif-sc" + ("" if p.kind == "sc" else " + saif-int")], needs=("audit",)),
            Stage("power", self.dir / "power", self.do_power, lambda: [
                f"view     {view}",
                f"pt       {quote(self.power_cmd())}",
                "gate     qualify.py pt-coverage; SAIF snapshot == audited SAIF"], needs=("saif",)),
            Stage("row", self.dir / "row.csv", self.do_row, lambda: ["row.csv"], needs=("power",)),
        ]
        if self.classes:
            st.append(Stage("classes", self.dir / "classes", self.do_classes,
                            lambda: ["pt_shell -file flow/tcl/pt_power_classes.tcl (total == power.rpt)"],
                            needs=("power",)))
        return st


# ------------------------------------------------------------------------------------------------- rows --
def total(power_rpt: Path, name: str) -> float:
    m = re.search(name + r"\s*=\s*([0-9.eE+-]+)", text(power_rpt))
    require(m, f"{power_rpt} lacks {name}")
    return float(m[1]) * 1e3


def hierarchy(power_dir: Path) -> dict[str, float]:
    """First-level hierarchy power (mW) from cell_power.rpt (7 significant digits), cross-checked against
    power_hier.rpt (3 significant digits)."""
    precise: dict[str, float] = {}
    for line in text(power_dir / "cell_power.rpt").splitlines():
        f = line.split()
        if len(f) >= 6 and f[0] in HIER and f[-1] == "h":
            require(f[0] not in precise, f"cell_power.rpt lists {f[0]} twice")
            precise[f[0]] = float(f[4]) * 1e3
    coarse: dict[str, float] = {}
    for line in text(power_dir / "power_hier.rpt").splitlines():
        m = re.match(r"  (\S+) \(\S+\)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)", line)
        if m and m[1] in HIER and m[1] not in coarse:
            coarse[m[1]] = float(m[5]) * 1e3
    require(set(precise) == set(HIER) == set(coarse), f"hierarchy powers incomplete: {sorted(precise)}")
    for name in HIER:
        require(abs(precise[name] - coarse[name]) <= 0.0051 * abs(coarse[name]) + 1e-6,
                f"{name}: cell_power {precise[name]} mW vs power_hier {coarse[name]} mW")
    return precise


def common_row(pr: PointRun) -> tuple[dict, dict]:
    timing = json.loads((pr.gl / "timing_qualification.json").read_text())
    require(timing["status"] == "PASS", "GL timing audit did not pass")
    sdfc = json.loads((pr.gl / "sdf_clock_audit.json").read_text())
    power_dir = pr.dir / "power"
    p_tot = total(power_dir / "power.rpt", "Total Power")
    hier = hierarchy(power_dir)
    base = dict(point=pr.p.name, kind=pr.p.kind, shape=pr.r.shape, route=pr.r.run, top=pr.r.top,
                power_mW=p_tot, internal_mW=total(power_dir / "power.rpt", "Cell Internal Power"),
                switching_mW=total(power_dir / "power.rpt", "Net Switching Power"),
                leakage_mW=total(power_dir / "power.rpt", "Cell Leakage Power"),
                **{f"{h}_mW": hier[h] for h in HIER},
                toplevel_mW=p_tot - sum(hier.values()))
    tail = dict(gl_strict=json.loads((pr.gl / "timing_qualification_strict.json").read_text())["status"],
                gl_approved_iwsba=len(timing["approved_annotated_interconnects"]),
                gl_approved_ndi_clamps=len(timing["approved_negative_iopath_clamps"]),
                gl_sdf_warnings=json.dumps(timing["sdf_warning_categories"], sort_keys=True),
                post_reset_timing_violations=timing["post_reset_timing_violations"],
                worst_icg_ck_eck_ns=sdfc["worst_icg_iopath_ns"],
                saif_validation=text(pr.dir / "saif/saif_validation.log").strip().splitlines()[-1].split("  [note")[0],
                status="PASS")
    return base, tail


def sc_row(pr: PointRun) -> dict:
    chk = json.loads((pr.gl / "trace_check.json").read_text())
    require(not chk["errors"], "SC trace check has errors")
    base, tail = common_row(pr)
    window, blocks = chk["window_edges"], chk["blocks"]
    macs = blocks * pr.r.K * 64                     # K columns x 8 x 8 tiles per block
    row = dict(base, workload=chk["workload"], K=pr.r.K, M=pr.r.M, blocks=blocks, columns=chk["columns"],
               window_edges=window, kernel_macs=macs, mac_per_cycle=macs / window,
               mean_cycles_per_block=window / blocks, mean_L=chk["mean_L"], mean_kA=chk["mean_kA"],
               a_one_density=chk["a_one_density"],
               pJ_MAC=base["power_mW"] * window * PERIOD_NS / macs,
               array_pJ_MAC=base["u_pe_mW"] * window * PERIOD_NS / macs)
    row.update(tail)
    return row


def int_row(pr: PointRun) -> dict:
    chk = json.loads((pr.gl / "trace_check.json").read_text())
    require(chk["status"] == "PASS" and chk.get("lap_len") == 1, "INT trace check not PASS with 1-edge laps")
    saif_int = json.loads((pr.dir / "saif/saif_int_audit.json").read_text())
    require(saif_int["status"] == "PASS", "saif-int did not pass")
    base, tail = common_row(pr)
    ba, bw, win = chk["ba"], chk["bw"], chk["saif_window"]
    require(win["data"] * 64 * 128 == chk["macs"] * ba * bw, "window data cycles x 8192 / (BA*BW) != checked MACs")
    mpc = chk["macs"] / win["active"]
    sched = chk.get("schedule", "bp")
    nb = chk["L"] // 128
    period = (ba * bw * nb + ba + bw - 2 + 8) if sched == "abit" else (bw * nb + bw - 1 + 8)
    row = dict(base, schedule=sched, precision=chk["precision"], ba=ba, bw=bw, L=chk["L"], mrows=chk["mrows"],
               ncols=chk["ncols"], blocks=chk["blocks"], saif_mode=chk["saif_mode"], window=pr.p.window,
               active_cycles=win["active"], data_cycles=win["data"], lap_cycles=win["ring"],
               drain_cycles=win["drain"], block_period=period, mac_per_data_cycle=64 * 128 / (ba * bw),
               macs=chk["macs"], mac_per_cycle=mpc,
               pJ_MAC=base["power_mW"] * PERIOD_NS / mpc, array_pJ_MAC=base["u_pe_mW"] * PERIOD_NS / mpc,
               max_abs_output=chk["max_abs_output"], outputs_checked=chk["outputs_checked"])
    row.update(tail)
    return row


# ------------------------------------------------------------------------------------------ class split --
def summarize_classes(log_path: Path) -> dict:
    """Block rows (mW and um2) from pt_power_classes.tcl's output; the rows sum to PT's Total Power (checked) and,
    as cell area, to the leaf total.
      u_pe            tiles + pe_pipes_glue (core_seq + core_glue + pe_local) + dbl_mux + dbl_sel + pe_clk_buf
      a_edge          a_regs + ka_enc + ka_in_buf + therm_byp (thermometer + A INT bypass: a_logic + byp_a + sel_a)
      w_edge          w_regs + w_cmp_byp (W comparators + W INT bypass: w_logic + byp_w + sel_w)
      sel_shared      bypass select buffering feeding both bit cones
      w_bank          u_rng (block clock)
      combiner        u_combiner
      periph_clk_buf  CTS buffers in u_peripheral
      other           u_peripheral leftovers + top glue + top CTS buffers + input-port net switching"""
    d: dict = {"class": {}, "hier": {}, "info": [], "other": []}
    for line in text(log_path).splitlines():
        f = line.split()
        if not f:
            continue
        if f[0] == "PWR_TOTAL":
            d["total"] = float(f[1])
        elif f[0] == "PWR_CLASS":
            d["class"][(f[1], f[2])] = dict(cells=int(f[3]), int=float(f[4]), sw=float(f[5]), leak=float(f[6]),
                                             tot=float(f[7]), area=float(f[8]) if len(f) > 8 else None)
        elif f[0] == "PWR_HIER":
            d["hier"][f[1]] = dict(int=float(f[2]), sw=float(f[3]), leak=float(f[4]), tot=float(f[5]))
        elif f[0] == "PWR_CHECK" and f[1] == "leaf_sum":
            d["leaf_sum"], d["port_nets"] = float(f[2]), float(f[4])
        elif f[0] in ("PWR_INFO", "PWR_CHECK"):
            d["info"].append(" ".join(f[1:]))
        elif f[0] == "PWR_OTHER":
            d["other"].append(" ".join(f[1:]))
    require("total" in d and "port_nets" in d, f"{log_path}: no PWR_TOTAL / leaf_sum")

    def n(s, k):
        return d["class"].get((s, k), dict(cells=0))["cells"]

    def build(field: str, scale: float, tot: float | None, port: float) -> dict:
        def c(s, k):
            return (d["class"].get((s, k), {}).get(field) or 0.0) * scale
        r = dict(tiles=c("u_pe", "tiles"), pe_core_seq=c("u_pe", "core_seq"), pe_core_glue=c("u_pe", "core_glue"),
                 pe_local=c("u_pe", "pe_local"), dbl_mux=c("u_pe", "dbl_mux"), dbl_sel=c("u_pe", "dbl_sel"),
                 pe_clk_buf=c("u_pe", "clk_buf"), a_regs=c("u_peripheral", "a_regs"),
                 ka_enc=c("u_peripheral", "ka_enc"), ka_in_buf=c("u_peripheral", "ka_in_buf"),
                 therm=c("u_peripheral", "a_logic"), byp_a=c("u_peripheral", "byp_a"),
                 sel_a=c("u_peripheral", "sel_a"), w_regs=c("u_peripheral", "w_regs"),
                 w_cmp=c("u_peripheral", "w_logic"), byp_w=c("u_peripheral", "byp_w"),
                 sel_w=c("u_peripheral", "sel_w"), sel_shared=c("u_peripheral", "sel_both"),
                 rng_words=c("u_rng", "rng_words"), rng_ctrl=c("u_rng", "rng_ctrl"), rng_clk_buf=c("u_rng", "clk_buf"),
                 w_bank=c("u_rng", "ALL"), combiner=c("u_combiner", "ALL"),
                 combiner_clk_buf=c("u_combiner", "clk_buf"), periph_clk_buf=c("u_peripheral", "clk_buf"),
                 periph_other=c("u_peripheral", "p_other"), top_glue=c("top", "glue"), top_clk_buf=c("top", "clk_buf"),
                 port_nets=port, u_peripheral_leaf_sum=c("u_peripheral", "ALL"), u_pe_leaf_sum=c("u_pe", "ALL"),
                 clock_buffers_all=c("top", "CLOCK_BUFFERS_ALL"))
        r["pe_pipes_glue"] = r["pe_core_seq"] + r["pe_core_glue"] + r["pe_local"]
        r["u_pe"] = r["tiles"] + r["pe_pipes_glue"] + r["dbl_mux"] + r["dbl_sel"] + r["pe_clk_buf"]
        r["therm_byp"] = r["therm"] + r["byp_a"] + r["sel_a"]
        r["a_edge"] = r["a_regs"] + r["ka_enc"] + r["ka_in_buf"] + r["therm_byp"]
        r["w_cmp_byp"] = r["w_cmp"] + r["byp_w"] + r["sel_w"]
        r["w_edge"] = r["w_regs"] + r["w_cmp_byp"]
        r["other"] = r["periph_other"] + r["top_glue"] + r["top_clk_buf"] + r["port_nets"]
        r["total"] = tot if tot is not None else c("top", "ALL_LEAF")
        r["int_additions"] = (r["dbl_mux"] + r["dbl_sel"] + r["pe_local"] + r["byp_a"] + r["sel_a"] + r["byp_w"]
                              + r["sel_w"] + r["sel_shared"] + r["combiner"] + r["top_glue"])
        parts = (r["u_pe"] + r["a_edge"] + r["w_edge"] + r["sel_shared"] + r["w_bank"] + r["combiner"]
                 + r["periph_clk_buf"] + r["other"])
        require(abs(parts - r["total"]) <= 1e-6 * r["total"] + 1e-3, f"{field}: class rows sum {parts} != {r['total']}")
        require(abs(r["u_pe"] - r["u_pe_leaf_sum"]) <= 1e-6 * r["total"] + 1e-3, f"{field}: u_pe classes != leaf sum")
        return r

    rows = build("tot", 1e3, d["total"] * 1e3, d["port_nets"] * 1e3)
    area = build("area", 1.0, None, 0.0) if all(v.get("area") is not None for v in d["class"].values()) else None
    pk = ["ka_enc", "a_regs", "w_regs", "clk_buf", "ka_in_buf", "byp_a", "byp_w", "sel_a", "sel_w", "sel_both",
          "a_logic", "w_logic", "p_other"]
    require(sum(n("u_peripheral", k) for k in pk) == n("u_peripheral", "ALL"), "u_peripheral classes do not partition")
    ek = ["tiles", "clk_buf", "core_seq", "dbl_mux", "dbl_sel", "core_glue", "pe_local"]
    require(sum(n("u_pe", k) for k in ek) == n("u_pe", "ALL"), "u_pe classes do not partition")
    return dict(rows_mW=rows, rows_area_um2=area, hier_attr_mW={k: v["tot"] * 1e3 for k, v in d["hier"].items()},
                cells={f"{s}/{k}": v["cells"] for (s, k), v in d["class"].items()}, info=d["info"],
                top_p_other=d["other"])


CLASS_ORDER = ["total", "u_pe", "tiles", "pe_pipes_glue", "pe_core_seq", "pe_core_glue", "pe_local", "dbl_mux",
               "dbl_sel", "pe_clk_buf", "a_edge", "a_regs", "ka_enc", "ka_in_buf", "therm_byp", "therm", "byp_a",
               "sel_a", "w_edge", "w_regs", "w_cmp_byp", "w_cmp", "byp_w", "sel_w", "sel_shared", "w_bank",
               "rng_words", "rng_ctrl", "rng_clk_buf", "combiner", "combiner_clk_buf", "periph_clk_buf", "other",
               "periph_other", "top_glue", "top_clk_buf", "port_nets", "u_peripheral_leaf_sum", "clock_buffers_all",
               "int_additions"]


def classes_table(res: dict) -> str:
    rows, area = res["rows_mW"], res["rows_area_um2"]
    out = []
    for k in CLASS_ORDER:
        ar = f"{area[k]:11.1f} um2 ({100 * area[k] / area['total']:5.2f} %)" if area else ""
        out.append(f"{k:22s} {rows[k]:10.4f} mW  ({100 * rows[k] / rows['total']:5.2f} %)  {ar}")
    out += [f"info {i}" for i in res["info"]]
    return "\n".join(out) + "\n"


# ------------------------------------------------------------------------------------------------- driver --
def collect(out: Path) -> None:
    for kind, name in (("sc", "sc_results.csv"), ("int", "int_results.csv")):
        rows = []
        for f in sorted(out.glob("*/row.csv")):
            if text(f.parent / "row.status").strip() != "PASS":
                continue
            row = next(csv.DictReader(f.open()))
            if (row["kind"] == "sc") == (kind == "sc"):
                rows.append(row)
        if rows:
            fields = list(dict.fromkeys(k for r in rows for k in r))
            with (out / name).open("w", newline="") as stream:
                w = csv.DictWriter(stream, fieldnames=fields)
                w.writeheader()
                w.writerows(rows)
            print(f"{len(rows)} {kind} points -> {out / name}")


def manifest(r: Route, evidence: Path) -> list[str]:
    lines = [f"route={r.route}", f"top={r.top}", f"target={r.target}", f"shape={r.shape} K={r.K} M={r.M}",
             f"evidence={evidence}", f"sc_columns={r.sc_columns} sc_batches={r.sc_batches}",
             f"approvals={' '.join(r.approvals) or '(none)'}"]
    lines += [f"{sha256(f)}  {f.relative_to(r.route)}" for f in (r.file("apr.v"), r.file("apr.sdf"), r.file("spef"),
                                                                 r.sdc)]
    lines += [f"{sha256(REPO / tb)}  {tb}" for tb in (SC_TB, INT_TB)]
    return lines


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("shape_pos", nargs="?", metavar="SHAPE", choices=list(SHAPES))
    ap.add_argument("synth", nargs="?", metavar="SYNTH_RUN", help="synthesis run; the route is <SYNTH_RUN>_final")
    ap.add_argument("--shape", choices=list(SHAPES))
    ap.add_argument("--route", type=Path, help="route directory (default apr/build/TSMC22/PAYN/<SYNTH_RUN>_final)")
    ap.add_argument("--top", default=TOP, help="netlist top of the route (default payn_array)")
    ap.add_argument("--target", default=TARGET)
    ap.add_argument("--evidence", type=Path, help="qualification evidence (default build/flow/<SYNTH_RUN>/route)")
    ap.add_argument("--out", type=Path, help="measurement directory (default build/flow/<SYNTH_RUN>/measure)")
    ap.add_argument("--points", default="sc,int")
    ap.add_argument("--classes", default="sc_uniform,sc_ladder", help="points that also get the per-class split")
    ap.add_argument("--sc-columns", type=int, default=SC_COLUMNS)
    ap.add_argument("--gl-approve", default="", help="gl-audit approvals, used only after a strict failure and only "
                                                    "with OUT/gl_validator_args_rationale.txt citing them")
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--retry-failed", action="store_true", default=os.environ.get("RETRY_FAILED") == "1")
    ap.add_argument("--dry-run", action="store_true", default=os.environ.get("DRY_RUN") == "1")
    a = ap.parse_args()
    shape = a.shape or a.shape_pos
    if not shape:
        ap.error("give SHAPE (positional or --shape)")
    if not a.route and not a.synth:
        ap.error("give SYNTH_RUN or --route")
    route = (a.route or apr_dir(a.target) / f"{a.synth}_final").resolve()
    flow_route = a.evidence is None
    evidence = (a.evidence or REPO / "build/flow" / a.synth / "route").resolve()
    out = (a.out or REPO / "build/flow" / (a.synth or route.name) / "measure").resolve()
    approvals = tuple(a.gl_approve.split())
    for tok in approvals:
        if not (tok.startswith("--approve-") or re.fullmatch(r"[0-9]+(\.[0-9]+)?", tok)):
            ap.error(f"--gl-approve takes only qualify.py --approve-* flags (got {tok})")
    r = Route(shape, route, a.top, out, a.target, approvals, a.sc_columns)
    require(r.sc_columns % (8 * r.K) == 0, "--sc-columns must be a multiple of 8 K")
    names = select(a.points)
    classes = set(select(a.classes)) if a.classes else set()

    print(f"route {r.route} (top {r.top}, {shape}); out {out}")
    try:
        g = gate_route(r, evidence, flow_route)
    except FlowError as error:
        if not a.dry_run:
            print(f"[refused] {error}", file=sys.stderr)
            return 3
        print(f"DRY RUN note: route gate not passed yet: {error}")
        g = None
    if g:
        q = g["qualification"]
        print(f"route gate PASS: final qualification (setup {q['setup_wns_ns']:+.3f} / hold {q['hold_wns_ns']:+.3f} ns, "
              f"{q.get('area_um2', '?')} um2), grid basin, pin proof PASS")
    if not a.dry_run:
        out.mkdir(parents=True, exist_ok=True)
        write_manifest(out / "inputs.txt", manifest(r, evidence))
    blocked = {n: bench_supports(POINTS[n]) for n in names if bench_supports(POINTS[n])}

    def one(name: str) -> tuple[str, str]:
        pr = PointRun(r, POINTS[name], name in classes)
        runner = Runner(pr.dir, retry=a.retry_failed, dry=a.dry_run, label=f"[{name}] ")
        if name in blocked:
            if a.dry_run:
                print(f"[{name}] BLOCKED: {blocked[name]}")
            return name, f"BLOCKED ({blocked[name]})"
        try:
            runner.run(pr.stages())
        except FlowError as error:
            print(f"[{name}] FAIL: {error}", file=sys.stderr, flush=True)
            return name, f"FAIL ({error})"
        return name, "planned" if a.dry_run else "PASS"

    if a.dry_run:
        print(f"DRY RUN: {len(names)} points, jobs {a.jobs}, approvals {' '.join(approvals) or '(none)'}, "
              f"SC_BATCHES {r.sc_batches}")
        results = [one(n) for n in names]
    else:
        with ThreadPoolExecutor(a.jobs) as ex:
            results = list(ex.map(one, names))
        collect(out)
    bad = [f"{n}: {s}" for n, s in results if not s.startswith(("PASS", "planned"))]
    print(f"measure: {len(results) - len(bad)}/{len(results)} points {'planned' if a.dry_run else 'PASS'}")
    for line in bad:
        print("  " + line)
    return 1 if bad and not a.dry_run else 0


if __name__ == "__main__":
    sys.exit(main())
