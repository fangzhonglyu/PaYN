#!/usr/bin/env python3
"""PaYN physical flow for one shape: synthesis to a qualified, gated, functionally verified final route.

  python3 flow/route.py SHAPE SYNTH_RUN                      # every stage, in order
  python3 flow/route.py k16m8 payn_k16m8_20261006 --dry-run   # the plan, with each stage's state
  python3 flow/route.py k16m8 payn_k16m8_20261006 --retry-failed
  python3 flow/route.py k16m8 payn_k16m8_20261006 --stages syn-gl   # one stage (its needs must have passed)
SHAPE is k16m8 or k8m16 (PAYN_M = 8 / 16).  Runs: synthesis syn/build/TSMC22/PAYN/<SYNTH_RUN>, bootstrap route
apr/build/TSMC22/PAYN/<SYNTH_RUN>_distguide, final route .../<SYNTH_RUN>_final.  Stage markers, attempt logs and
evidence: build/flow/<SYNTH_RUN>/route/; post-synthesis GL: build/flow/<SYNTH_RUN>/syn_gl/; routed functional GL:
build/flow/<SYNTH_RUN>/routed_func/.  Every tool command runs in flow/env.sh's environment.

Stages (each resumes only from its explicit PASS marker; a failed stage keeps its output until --retry-failed
moves it aside; --adopt accepts a synthesis or bootstrap route launched outside the flow with this environment,
after the same checks):
  synth        make synth TARGET=TSMC22/PAYN, SYN_DEFINES for the shape; checks: netlist / SDC / SDF written, setup
               met, 1.25 ns input delays, the netlist's port widths match the shape
  syn-gl       post-synthesis gate-level checks (flow/regress.py --gl syn-unit,syn-sdf): SC goldens, INT bit-plane
               blocks, SC <-> INT switching and negative controls, each on the netlist and on RTL with the same
               inputs; unit delay (functional) and the ideal-clock synthesis SDF (timing checks on, qualify.py
               routed-gl + syn-gl)
  boot-apr     make apr <SYNTH_RUN>_distguide with SC_DISTRIBUTION_GUIDES=1 (soft A-row / W-column guides, floating
               pins, no workload power optimization); the guide line must match the netlist's own count; qualify.py
               routed-apr --stage bootstrap (residual markers allowed: the route only seeds activity)
  boot-sim     full-timing max-SDF GL of the bootstrap route with the SC uniform L=128 power bench (flow/measure.py's
               gl, audit and saif steps: bit-exact drain, sdf-clock, gl-audit strict first, saif-sc), then the
               audited SAIF becomes the bootstrap route's activity/dut.saif, the final pass's power-optimization seed
  final-apr    make apr <SYNTH_RUN>_final: PRE_PLACE_SCRIPT=apr/scripts/payn_pre_place.tcl (the same guides, every
               pin fixed on the tile grid, the post-fill search-and-repair hook), workload power optimization from
               the bootstrap SAIF, leakage ratio 0, detail wire-length effort high; log checks: guide line, every
               pin fixed (#fixedPin = port count, #floatPin = 0), the hook ran, the final placement check ran
  qualify      qualify.py routed-apr --stage final; if only residual geometry / antenna markers remain (fewer than
               1,000, no placement overlap), the targeted repair (flow/tcl/repair_route.tcl, from the route's
               final checkpoint, in place; the original run archived inside the route) and qualify again;
               route/qualification.json
  gate         qualify.py basin: tile-grid correlation and product-AND operand skew (grid vs collapsed basin) and
               the pin proof against the pre-place plan; route/basin/basin_gate.json; a collapsed basin fails
  routed-func  routed functional GL (flow/regress.py --gl apr): SC goldens at reset settle 2 and 0, INT bit-plane and
               all-bits-in-time blocks, switching, negative controls, on the routed netlist with the raw routed
               SDF, every log through qualify.py gl-audit (strict first)
GL approvals (--gl-approve) are used only after a strict audit failure and only with a rationale file citing each
flag: route/bootstrap/gl_validator_args_rationale.txt (boot-sim), routed_func/<SHAPE>/apr/gl_validator_args_rationale.txt
(routed-func).
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from flowlib import (REPO, SHAPES, TARGET, TOP, FlowError, Log, Runner, Stage, apr_dir, expected_guide_line,  # noqa: E402
                     first_match, grep, make_cmd, netlist_modules, port_count, qualify, qualify_cmd, quote, require,
                     sh, stamp, syn_dir, text, tool_env, write_manifest, sha256)
import measure  # noqa: E402

PRE_PLACE = "apr/scripts/payn_pre_place.tcl"
GUIDES = "apr/scripts/sc_distribution_guides.tcl"
POSTFILL = "apr/scripts/payn_postfill_repair.tcl"
TARGET_HOOK = "apr/scripts/check_final_placement.tcl"
REPAIR_TCL = REPO / "flow/tcl/repair_route.tcl"
MAX_REPAIR_MARKERS = 1000


class Flow:
    def __init__(self, shape: str, synth: str, approvals: tuple[str, ...], jobs: int, retry: bool = False):
        self.shape, self.synth, self.approvals, self.jobs, self.retry = shape, synth, approvals, jobs, retry
        self.K, self.M = SHAPES[shape]
        self.syn = syn_dir() / synth
        self.boot_run, self.final_run = f"{synth}_distguide", f"{synth}_final"
        self.boot, self.final = apr_dir() / self.boot_run, apr_dir() / self.final_run
        self.base = REPO / "build/flow" / synth
        self.work = self.base / "route"
        self.netlist = self.syn / f"{TOP}.syn.v"
        self.boot_saif = self.boot / "activity/dut.saif"

    # ------------------------------------------------------------------------------------------- synth --
    def syn_defines(self) -> str:
        return f"PAYN_M={self.M} PAYN_NH=8 PAYN_NW=8 PAYN_LOW_W=9"

    def synth_cmd(self) -> list[str]:
        return make_cmd("synth", f"TARGET={TARGET}")

    def synth_env(self) -> dict:
        return dict(SYN_DEFINES=self.syn_defines(), RUN_NAME=self.synth)

    def check_synth(self, log: Log) -> None:
        for f in (self.netlist, self.syn / f"{TOP}.syn.sdc", self.syn / f"{TOP}.syn.sdf", self.syn / "timing.rpt"):
            require(f.is_file() and f.stat().st_size, f"synthesis output missing: {f}")
        require(not first_match(self.syn / "synth.log", r"^(Error:|ERROR:)"), "errors in synth.log")
        slacks = [float(x) for x in re.findall(r"slack \((?:MET|VIOLATED)\)\s+([-+0-9.]+)", text(self.syn / "timing.rpt"))]
        require(slacks and min(slacks) >= 0, f"synthesis setup slack {min(slacks) if slacks else 'missing'}")
        delays = re.findall(r"^set_input_delay\b[^\n]*?\s([0-9]+(?:\.[0-9]+)?)\s+\[get_ports",
                            text(self.syn / f"{TOP}.syn.sdc"), re.M)
        require(delays and all(float(x) == 1.25 for x in delays), f"unexpected input delays {sorted(set(delays))}")
        body = netlist_modules(self.netlist)[TOP]

        def width(port):
            m = re.search(rf"^\s*(?:input|output)\s*\[(\d+):(\d+)\]\s+{port}\s*;", body, re.M)
            require(m, f"netlist port {port} missing")
            return abs(int(m[1]) - int(m[2])) + 1
        k = width("a_signs_in") // 8
        m = width("a_raw_in") // (8 * k)
        require((k, m) == (self.K, self.M), f"netlist is K{k}/M{m}, shape {self.shape} is K{self.K}/M{self.M}")
        area = first_match(self.syn / "area.rpt", r"Total cell area:\s*([0-9.]+)")
        log(f"synthesis {self.syn}: setup slack {min(slacks):+.3f} ns, K{k}/M{m}, area {area[1] if area else '?'} um2")

    def do_synth(self, log: Log) -> None:
        rc = sh(self.synth_cmd(), log, env=tool_env(self.synth_env()))
        require(rc == 0, f"make synth returned {rc}")
        self.check_synth(log)

    # ---------------------------------------------------------------------------------------- GL suites --
    def syn_gl_cmd(self) -> list[str]:
        return [sys.executable, str(REPO / "flow/regress.py"), "--shape", self.shape, "--gl", "syn-unit,syn-sdf",
                "--synth-run", self.synth, "--out", str(self.base / "syn_gl"), "--jobs", str(self.jobs)]

    def do_syn_gl(self, log: Log) -> None:
        rc = sh(self.syn_gl_cmd(), log)
        log(text(self.base / "syn_gl" / self.shape / "summary.txt"))
        require(rc == 0, f"post-synthesis GL checks failed ({self.base / 'syn_gl' / self.shape / 'summary.txt'})")

    def routed_func_cmd(self) -> list[str]:
        cmd = [sys.executable, str(REPO / "flow/regress.py"), "--shape", self.shape, "--gl", "apr",
               "--route", str(self.final), "--out", str(self.base / "routed_func"), "--jobs", str(self.jobs)]
        return cmd + ([f"--gl-approve={' '.join(self.approvals)}"] if self.approvals else [])

    def do_routed_func(self, log: Log) -> None:
        rc = sh(self.routed_func_cmd(), log)
        log(text(self.base / "routed_func" / self.shape / "summary.txt"))
        require(rc == 0, f"routed functional GL failed ({self.base / 'routed_func' / self.shape / 'summary.txt'})")

    # ------------------------------------------------------------------------------------ bootstrap APR --
    def boot_env(self) -> dict:
        return dict(SC_DISTRIBUTION_GUIDES=1, APR_WORKLOAD_POWER_OPT=0, SYNTH_RUN=self.synth, RUN_NAME=self.boot_run)

    def apr_cmd(self) -> list[str]:
        return make_cmd("apr", f"TARGET={TARGET}")

    def check_boot(self, log: Log) -> None:
        apr_log = self.boot / "apr.log"
        require(grep(apr_log, f"Running PRE_PLACE_SCRIPT script: {REPO}/{GUIDES}"), "the guide script did not run")
        want = expected_guide_line(self.netlist)
        got = first_match(apr_log, r"^SC_DISTRIBUTION_GUIDES:.*$")
        require(got and got[0] == want, f"guide line {got[0] if got else None!r} != netlist prediction {want!r}")
        require(not grep(apr_log, "Enabling workload-aware dynamic-power optimization"),
                "the bootstrap ran workload power optimization")
        require(text(self.boot / "TARGET_DEF") == text(REPO / "apr/targets" / TARGET), "TARGET_DEF differs")
        rc = qualify("routed-apr", self.boot, TOP, "--stage", "bootstrap", "--json",
                     self.work / "bootstrap_qualification.json", log=log)
        require(rc == 0, "bootstrap route not qualified (qualify.py routed-apr --stage bootstrap)")
        log(f"{want}; bootstrap qualified: {text(self.work / 'bootstrap_qualification.json').strip()}")

    def do_boot_apr(self, log: Log) -> None:
        rc = sh(self.apr_cmd(), log, env=tool_env(self.boot_env()))
        log(f"make apr returned {rc} (residual seed markers are allowed; qualification below decides)")
        self.check_boot(log)

    def adopt_boot(self, log: Log) -> None:
        log(f"adopting {self.boot}, routed outside the flow; it must pass the bootstrap stage's checks")
        require(grep(self.boot / "apr.log", '--- Ending "Innovus"'), "the adopted route has not finished")
        self.check_boot(log)

    def adopt_synth(self, log: Log) -> None:
        log(f"adopting synthesis {self.syn}; it must pass the synthesis stage's checks")
        defs = first_match(self.syn / "synth.log", r"PAYN_M=(\d+)")
        if defs:
            require(int(defs[1]) == self.M, f"synth.log names PAYN_M={defs[1]}")
        self.check_synth(log)

    # ------------------------------------------------------------------------------------ bootstrap SAIF --
    def boot_point(self) -> measure.PointRun:
        r = measure.Route(self.shape, self.boot, TOP, self.work / "bootstrap", TARGET, self.approvals)
        return measure.PointRun(r, measure.POINTS["sc_uniform"], classes=False)

    def do_boot_sim(self, log: Log) -> None:
        pr = self.boot_point()
        pr.r.out.mkdir(parents=True, exist_ok=True)
        inner = Runner(pr.dir, retry=self.retry, label=f"[{self.synth} boot-sim] ")
        inner.run([st for st in pr.stages() if st.name in ("gl", "audit", "saif")])
        log(f"bootstrap GL: {text(pr.gl / 'trace_check.log').strip().splitlines()[-1]}")
        log(text(pr.dir / "saif/saif_validation.log").strip())
        self.boot_saif.parent.mkdir(exist_ok=True)
        if self.boot_saif.exists():
            shutil.copy2(self.boot_saif, pr.dir / "previous_route_activity.saif")
        shutil.copy2(pr.saif, self.boot_saif)
        log(f"installed the audited SAIF {pr.saif} -> {self.boot_saif}")

    # ---------------------------------------------------------------------------------------- final APR --
    def final_env(self) -> dict:
        return dict(SC_DISTRIBUTION_GUIDES=0, PRE_PLACE_SCRIPT=PRE_PLACE, SC_DIST_HIER_PREFIX="u_pe/u_array_core",
                    APR_WORKLOAD_POWER_OPT=1, APR_ACTIVITY_FILE=str(self.boot_saif), APR_ACTIVITY_SCOPE="Top/dut",
                    APR_LEAKAGE_TO_DYNAMIC_RATIO="0.0", APR_DETAIL_WIRE_LENGTH_OPT_EFFORT="high",
                    SYNTH_RUN=self.synth, RUN_NAME=self.final_run)

    def do_final_apr(self, log: Log) -> None:
        require(self.boot_saif.is_file(), f"no bootstrap SAIF {self.boot_saif}")
        guide = first_match(self.boot / "apr.log", r"^SC_DISTRIBUTION_GUIDES:.*$")[0]
        require(guide == expected_guide_line(self.netlist), "bootstrap guide line differs from the netlist's")
        pins = port_count(self.netlist, TOP)
        rc = sh(self.apr_cmd(), log, env=tool_env(self.final_env()))
        log(f"make apr returned {rc} (the qualify stage decides)")
        apr_log = self.final / "apr.log"
        checks = [
            ("Enabling workload-aware dynamic-power optimization", "workload power optimization"),
            ("leakageToDynamicRatio=0.0 detail_wirelength_effort=high", "leakage ratio 0 / wire-length effort high"),
            (f"INFO: activity_file={self.boot_saif} scope='Top/dut'", "the bootstrap SAIF as the activity file"),
            (f"Running PRE_PLACE_SCRIPT script: {REPO}/{PRE_PLACE}", "the pre-place script"),
            (guide, "the bootstrap's guide line"),
            (f"POSTFILL_HOOK: PRE_REPORT_SCRIPT={REPO}/{POSTFILL} next_hook={TARGET_HOOK}", "the post-fill hook armed"),
            ("POSTFILL_DRC_REPAIR_END", "the post-fill repair ran"),
            ("FINAL_PLACEMENT_CHECK_END", "the final placement check ran"),
            ("Innovus script finished", "Innovus completion"),
        ]
        for needle, what in checks:
            require(grep(apr_log, needle), f"apr.log lacks {what}: {needle}")
        require(not first_match(apr_log, r"^(ERROR|WARNING): SC_PIN_PLACEMENT"), "pin script error or warning")
        m = first_match(apr_log, r"^SC_PIN_PLACEMENT: fixed=(\d+) .* len_bus=a_len_in LEN_W=8$")
        require(m and int(m[1]) == pins, f"pin plan fixed {m[1] if m else None} pins, the netlist has {pins}")
        require(first_match(apr_log, rf"#fixedPin={pins}, #floatPin=0\b"), "GigaPlace did not see every pin fixed")
        require(not first_match(apr_log, r"#floatPin=[1-9]"), "GigaPlace saw floating pins")
        require(first_match(apr_log, r"Illegally Assigned Pins\s*:\s*0"), "illegally assigned pins")
        for f in ("sc_pin_plan.tsv", "sc_pin_plan.checkPin.rpt"):
            shutil.copy2(self.final / f, self.work / f)
        for line in text(apr_log).splitlines():
            if line.startswith(("SC_PIN_PLACEMENT", "SC_DISTRIBUTION_GUIDES", "POSTFILL_DRC_REPAIR:")):
                log(line)

    # ------------------------------------------------------------------------------------------ qualify --
    def qualify_final(self, log: Log, stage: str = "final") -> bool:
        return qualify("routed-apr", self.final, TOP, "--stage", stage, "--json",
                       self.work / f"route_{stage}.json", log=log) == 0

    def do_qualify(self, log: Log) -> None:
        repaired = False
        if self.qualify_final(log):
            log("the completed route passes the final qualification")
        else:
            log("final qualification failed; checking for residual geometry / antenna markers only")
            require(self.qualify_final(log, "bootstrap"), "connectivity, timing or completion failed: not a "
                                                         "residual-marker case")
            q = json.loads((self.work / "route_bootstrap.json").read_text())
            require(q["placement_overlapping_instances"] == 0 and not q["placement_late_overlap_warning"],
                    f"placement overlaps: not a residual-marker repair case ({q})")
            require(q["geometry_drc"] > 0 or q["antenna_violations"] > 0, f"no residual markers to repair ({q})")
            require(q["geometry_drc"] < MAX_REPAIR_MARKERS, f"{q['geometry_drc']} geometry markers (verify_drc limit): "
                                                            "a wholesale failure, not a residual-marker case")
            for f in ("geom.rpt", "antenna.rpt"):
                shutil.copy2(self.final / f"{TOP}.{f}", self.work / f"first_route_{f.replace('.rpt', '')}.rpt")
            repair_route(self.final, log, self.work)
            require(self.qualify_final(log), "the repaired route does not pass the final qualification")
            repaired = True
        q = json.loads((self.work / "route_final.json").read_text())
        require(q["qualification"] == "final", "unexpected qualification record")
        area = first_match(self.final / "reports/area.rpt", rf"^{TOP}\s+\S+\s+([0-9.]+)")
        q.update(targeted_repair=repaired, area_um2=float(area[1]) if area else None, route=str(self.final))
        if repaired:
            q["repair_plan"] = json.loads((self.final / "repair_plan.json").read_text())
            q["original_route_archive"] = [str(p) for p in sorted(self.final.glob("before_legalization_*"))]
        (self.work / "qualification.json").write_text(json.dumps(q, indent=2) + "\n")
        log(json.dumps(q))

    # ------------------------------------------------------------------------------------------- gate --
    def gate_cmd(self) -> list[str]:
        return qualify_cmd("basin", self.final, TOP, self.work / "basin", f"{self.synth}_final",
                           "--plan", self.work / "sc_pin_plan.tsv")

    def do_gate(self, log: Log) -> None:
        rc = sh(self.gate_cmd(), log)
        j = json.loads(text(self.work / "basin/basin_gate.json") or "{}")
        if j:
            log(f"basin {j['gate']['basin']} corr {j['corr_x_col']:.3f} skew {j['abs_skew_mean_ps']:.1f} ps, pin proof "
                f"{j['pin_proof']['status']} ({j['pin_proof']['fixed_in_def']} fixed, "
                f"{j['pin_proof']['mismatches']} mismatches)")
        require(rc == 0, f"basin gate returned {rc} (3: collapsed basin or failed pin proof, 2: no metrics)")

    # ------------------------------------------------------------------------------------------ stages --
    def stages(self) -> list[Stage]:
        boot_pr = self.boot_point()
        return [
            Stage("synth", self.syn, self.do_synth, lambda: [
                f"env      SYN_DEFINES='{self.syn_defines()}' RUN_NAME={self.synth}",
                f"run      {quote(self.synth_cmd())}"], adopt=self.adopt_synth),
            Stage("syn-gl", self.base / "syn_gl" / self.shape / "summary.txt", self.do_syn_gl,
                  lambda: [f"run      {quote(self.syn_gl_cmd())}"], needs=("synth",)),
            Stage("boot-apr", self.boot, self.do_boot_apr, lambda: [
                "env      " + " ".join(f"{k}={v}" for k, v in self.boot_env().items()),
                f"run      {quote(self.apr_cmd())}",
                f"expect   {expected_guide_line(self.netlist) if self.netlist.is_file() else '(netlist pending)'}",
                f"gate     qualify.py routed-apr {self.boot} {TOP} --stage bootstrap"],
                  needs=("synth",), adopt=self.adopt_boot),
            Stage("boot-sim", self.boot_saif, self.do_boot_sim, lambda: [
                f"sim      {quote(boot_pr.gl_cmd())}",
                f"check    {quote(boot_pr.check_cmd())}",
                f"gate     qualify.py sdf-clock, {quote(boot_pr.audit_cmd())}, saif-sc",
                f"install  {boot_pr.saif} -> {self.boot_saif}"], needs=("boot-apr",)),
            Stage("final-apr", self.final, self.do_final_apr, lambda: [
                "env      " + " ".join(f"{k}={v}" for k, v in self.final_env().items()),
                f"run      {quote(self.apr_cmd())}",
                f"expect   SC_PIN_PLACEMENT: fixed="
                f"{port_count(self.netlist, TOP) if self.netlist.is_file() else '?'} ... len_bus=a_len_in LEN_W=8, "
                "#floatPin=0, POSTFILL_DRC_REPAIR_END, FINAL_PLACEMENT_CHECK_END"], needs=("boot-sim",)),
            Stage("qualify", self.work / "qualification.json", self.do_qualify, lambda: [
                f"gate     qualify.py routed-apr {self.final} {TOP} --stage final",
                f"repair   only residual geometry/antenna markers (< {MAX_REPAIR_MARKERS}, no overlap): "
                f"innovus -files {REPAIR_TCL.relative_to(REPO)} from the final checkpoint, in place; qualify again"],
                  needs=("final-apr",)),
            Stage("gate", self.work / "basin/basin_gate.json", self.do_gate,
                  lambda: [f"gate     {quote(self.gate_cmd())}"], needs=("qualify",)),
            Stage("routed-func", self.base / "routed_func" / self.shape / "summary.txt", self.do_routed_func,
                  lambda: [f"run      {quote(self.routed_func_cmd())}"], needs=("gate",)),
        ]


# ------------------------------------------------------------------------------------------ the repair --
def repair_plan(source: Path, top: str) -> dict:
    """What the targeted repair touches, from the route's reports: every geometry marker (diagnosed nets, box) and
    every antenna sink, or, if the last placement check reports overlaps, the overlapping instances."""
    log = text(source / "apr.log")
    checks = list(re.finditer(r"Begin checking placement.*?Finished checkPlace[^\n]*", log, re.S))
    require(checks, "no placement diagnosis in apr.log")
    m = re.search(r"Overlapping with other instance:\s*(\d+)", checks[-1][0])
    overlap = (int(m[1]) if m else 0) or "NRDB-2082" in log[checks[-1].end():]
    plan = dict(mode="overlap" if overlap else "targeted", checkpoint="route" if overlap else "final",
                overlap_instances=[], geometry=[], antenna_pins=[])
    if overlap:
        names = [n for pair in re.findall(r"NRDB-2082\) INST (\S+) and INST (\S+) are overlapped\.", log) for n in pair]
        require(names, "no overlap instance names in apr.log")
        plan["overlap_instances"] = sorted(set(names))
    else:
        geometry = text(source / f"{top}.geom.rpt")
        for g in re.finditer(r"([^\n]+)\nBounds\s*:\s*\(\s*([-0-9.]+),\s*([-0-9.]+)\s*\)\s*\(\s*([-0-9.]+),\s*"
                             r"([-0-9.]+)\s*\)", geometry):
            nets = sorted(set(re.findall(r"Regular Wire of Net\s+(\S+)", g[1])))
            require(nets, f"geometry marker without a regular-net diagnosis: {g[1]}")
            plan["geometry"].append(dict(diagnosis=g[1], nets=nets, box=[float(g[i]) for i in range(2, 6)]))
        tot = re.search(r"Total Violations\s*:\s*(\d+)", geometry)
        require(not tot or int(tot[1]) == len(plan["geometry"]), "some geometry markers were not parsed")
        net, seen = None, set()
        for line in text(source / f"{top}.antenna.rpt").splitlines():
            n = re.match(r"^(\S+)\s+\(\d+\)\s*$", line)
            if n:
                net = n[1]
            p = re.match(r"^\s+(\S+)\s+\(([^)]+)\)\s+(\S+)\s*$", line)
            if p:
                require(net, "antenna pin without a net")
                if (net, p[1], p[3]) not in seen:
                    plan["antenna_pins"].append(dict(net=net, inst=p[1], pin=p[3], cell=p[2]))
                    seen.add((net, p[1], p[3]))
        require(plan["geometry"] or plan["antenna_pins"], "no residual geometry / antenna markers")
    for f in (f"{top}.{plan['checkpoint']}.enc", f"{top}.{plan['checkpoint']}.enc.dat", f"{top}.syn.v",
              f"{top}.syn.sdc", "TARGET_DEF"):
        require((source / f).exists(), f"missing repair input {f}")
    return plan


def tcl_word(x) -> str:
    return "{" + str(x).replace("\\", "\\\\").replace("{", "\\{").replace("}", "\\}") + "}"


def tcl_list(xs) -> str:
    return "[list " + " ".join(tcl_word(x) for x in xs) + "]"


def repair_route(route: Path, log: Log, work: Path) -> None:
    """Targeted repair in place: archive every file of the route into route/before_legalization_<stamp>/, restore
    its checkpoint into the route directory, run flow/tcl/repair_route.tcl there."""
    plan = repair_plan(route, TOP)
    (work / "repair_plan.json").write_text(json.dumps(plan, indent=2) + "\n")
    log(f"repair plan: {plan['mode']} from {plan['checkpoint']}.enc, {len(plan['geometry'])} geometry markers, "
        f"{len(plan['antenna_pins'])} antenna sinks, {len(plan['overlap_instances'])} overlap instances")
    archive = route / f"before_legalization_{stamp()}_{os.getpid()}"
    archive.mkdir()
    for p in list(route.iterdir()):
        if p != archive:
            shutil.move(str(p), str(archive / p.name))
    cp = plan["checkpoint"]
    for name in (f"{TOP}.{cp}.enc", f"{TOP}.{cp}.enc.dat"):
        src = archive / name
        (shutil.copytree(src, route / name, symlinks=True) if src.is_dir() else shutil.copy2(src, route / name))
    for name in (f"{TOP}.syn.v", f"{TOP}.syn.sdc", "TARGET_DEF"):
        shutil.copy2(archive / name, route / name)
    tcf = archive / "astraea_placement_activity.tcf"
    if tcf.is_file():
        # Saved power constraints point at the run's local TCF through a symlink: restore it and repoint the link.
        shutil.copy2(tcf, route / tcf.name)
        link = route / f"{TOP}.{cp}.enc.dat/libs/power/{tcf.name}"
        if link.is_symlink():
            link.unlink()
            link.symlink_to(route / tcf.name)
    (route / "repair_plan.json").write_text(json.dumps(plan, indent=2) + "\n")
    flow = Path(tool_env()["ASTRAEA_FLOW"])
    (route / "repair_inputs.txt").write_text(f"source={archive}\noutput={route}\nflow={flow}\nmode={plan['mode']}\n"
                                            f"checkpoint={cp}\n")
    # The flow's procedures and setup: apr.tcl up to its resume branch, its script directory pinned.
    s = (flow / "apr/scripts/apr.tcl").read_text()
    cut = "if {[info exists env(APR_RESUME_FINAL)] &&"
    require(s.count(cut) == 1, "unexpected apr.tcl structure (resume branch)")
    s = s.split(cut)[0]
    line = "set SCRIPT_DIR [file dirname [file normalize [info script]]]"
    require(s.count(line) == 1, "unexpected apr.tcl structure (SCRIPT_DIR)")
    s = s.replace(line, "set SCRIPT_DIR $env(FLOW_APR_SCRIPTS)")
    if plan["mode"] == "targeted":
        old = "\tif {!$skip_strong_drc_fix} {\n\t    editDeleteViolations\n\t    globalDetailRoute\n\t}"
        require(old in s, "unexpected apr.tcl final DRC fallback structure")
        s = s.replace(old, "    if {!$skip_strong_drc_fix} {\n        error \"Targeted checkpoint repair leaves geometry "
                           "markers; refusing a blind global reroute\"\n    }")
    (route / "repair_flow_procedures.tcl").write_text(s)
    lines = [f"set repair_mode {tcl_word(plan['mode'])}", f"set repair_checkpoint {tcl_word(cp)}",
             f"set repair_instances {tcl_list(plan['overlap_instances'])}", "set repair_ant_pins [list]",
             "set repair_geometry [list]"]
    lines += [f"lappend repair_ant_pins {tcl_list([p['inst'], p['pin'], p['net']])}" for p in plan["antenna_pins"]]
    lines += [f"lappend repair_geometry [list {tcl_list(g['nets'])} {tcl_list(g['box'])}]" for g in plan["geometry"]]
    (route / "repair_targets.tcl").write_text("\n".join(lines) + "\n")
    shutil.copy2(REPAIR_TCL, route / "repair.tcl")
    # The bootstrap/final stages' APR environment plus the checkpoint-repair knobs; the target's own hooks.
    env = tool_env(dict(SYNTH_RUN="checkpoint_only_repair", APR_LOCAL_CPUS=32, SC_DISTRIBUTION_GUIDES=1,
                        SKIP_FINAL_HOLD_OPT=1, FORCE_FINAL_HOLD_OPT=0, SKIP_FILLER=0, FORCE_STRONG_FINAL_DRC=0,
                        DISABLE_POSTROUTE_SWAPVIA=1, DESIGN_ROOT=str(REPO), FLOW_ROOT=str(flow),
                        FLOW_APR_SCRIPTS=str(flow / "apr/scripts")))
    cmd = f"set -a; . {REPO}/apr/targets/{TARGET}; set +a; innovus -batch -no_gui -files repair.tcl > apr.log 2>&1"
    rc = sh(cmd, log, cwd=route, env=env)
    log(f"repair innovus returned {rc}")
    require(grep(route / "apr.log", "POP_COUNT_CHECKPOINT_REPAIR_COMPLETE"), f"repair did not complete ({route}/apr.log)")
    (route / "repair.status").write_text("PASS\n")


# ------------------------------------------------------------------------------------------------ driver --
def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("shape", choices=list(SHAPES))
    ap.add_argument("synth", metavar="SYNTH_RUN")
    ap.add_argument("--stages", help="comma list: run only these stages (their needs must have passed)")
    ap.add_argument("--adopt", action="store_true", help="accept an existing synthesis / bootstrap route that passes "
                                                         "the stage's checks")
    ap.add_argument("--gl-approve", default="", help="gl-audit approvals (only after a strict failure, with the "
                                                    "rationale file the stage names)")
    ap.add_argument("--jobs", type=int, default=12, help="parallel GL runs in syn-gl / routed-func")
    ap.add_argument("--retry-failed", action="store_true", default=os.environ.get("RETRY_FAILED") == "1")
    ap.add_argument("--dry-run", action="store_true", default=os.environ.get("DRY_RUN") == "1")
    a = ap.parse_args()
    require(re.fullmatch(r"[A-Za-z0-9_]+", a.synth), "SYNTH_RUN must match [A-Za-z0-9_]+")
    flow = Flow(a.shape, a.synth, tuple(a.gl_approve.split()), a.jobs, a.retry_failed)
    runner = Runner(flow.work, retry=a.retry_failed, dry=a.dry_run, allow_adopt=a.adopt, label=f"[{a.synth}] ")
    if a.dry_run:
        print(f"DRY RUN: {a.shape} (K{flow.K}/M{flow.M}), synthesis {flow.syn}")
        print(f"  bootstrap route {flow.boot}\n  final route     {flow.final}\n  work            {flow.work}")
        print(f"  environment     flow/env.sh (ASTRAEA_FLOW={tool_env()['ASTRAEA_FLOW']})")
        print(f"  GL approvals    {a.gl_approve or '(none: a strict audit failure stops the stage)'}")
    else:
        flow.work.mkdir(parents=True, exist_ok=True)
        write_manifest(flow.work / "inputs.txt", [
            f"shape={a.shape} K={flow.K} M={flow.M}", f"target={TARGET} top={TOP}", f"synthesis={flow.syn}",
            f"bootstrap_route={flow.boot}", f"final_route={flow.final}", f"astraea={tool_env()['ASTRAEA_FLOW']}",
            f"apr.tcl sha256={sha256(Path(tool_env()['ASTRAEA_FLOW']) / 'apr/scripts/apr.tcl')}",
            *(f"{sha256(REPO / f)}  {f}" for f in (f"apr/targets/{TARGET}", PRE_PLACE, GUIDES, POSTFILL,
                                                   TARGET_HOOK))])
    try:
        runner.run(flow.stages(), set(a.stages.split(",")) if a.stages else None)
    except FlowError as error:
        print(f"[{a.synth}] FAIL: {error}", file=sys.stderr)
        return 1
    if not a.dry_run:
        print(f"[{a.synth}] done: {', '.join(runner.done)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
