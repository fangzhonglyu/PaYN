#!/usr/bin/env python3
"""Regression tests for flow/qualify.py on small synthetic inputs.

The SAIF X-policy tests encode the measurement methodology: correctness is established by the output-checking
bench; the SAIF gate rejects what would invalidate the measurement (architectural-output X, transient X beyond
one reporter quantum, a wrong clock period).  Persistent X on a dead or internal net is benign by default and
rejected only under --strict-persistent-x.  The other tests pin each gate's verdict on minimal fixtures in the
formats VCS, Innovus and PrimeTime write: a clean case passes, and the one broken criterion rejects it.

  python3 -m pytest flow/tests        or        python3 flow/tests/test_qualify.py
"""
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

QUALIFY = Path(__file__).resolve().parents[1] / "qualify.py"
DURATION = 1000000


def qualify(*args: str | Path, cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run([sys.executable, "-B", str(QUALIFY), *map(str, args)], text=True,
                          capture_output=True, check=False, cwd=cwd)


class TempDirTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def write(self, name: str, text: str) -> Path:
        path = self.tmp / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path


# ------------------------------------------------------------------------------------------- SAIF X policy --

def make_saif(*, output: str, floating_tx: int = 0, transient_tx: int = 0, output_tx: int = 0) -> str:
    floating = ""
    if floating_tx:
        floating = f"""
        (floating
          (T0 0) (T1 0) (TX {floating_tx})
          (TC 0)
        )"""
    transient = f"""
        (transient
          (T0 {DURATION - transient_tx}) (T1 0) (TX {transient_tx})
          (TC 2)
        )"""
    # The architectural output net; output_tx == DURATION makes it fully X, exercising the output gate directly.
    out_t0 = 0 if output_tx >= DURATION else 500000
    out_t1 = max(0, 500000 - output_tx)
    output_net = f"""
        ({output}\\[0\\]
          (T0 {out_t0}) (T1 {out_t1}) (TX {output_tx})
          (TC 200)
        )"""
    return f"""(SAIFILE
  (TIMESCALE 1 ps)
  (DURATION {DURATION})
  (INSTANCE Top
    (INSTANCE dut
      (NET
        (clk
          (T0 500000) (T1 499999) (TX 1)
          (TC 800)
        )
        (a_bits_in\\[0\\]
          (T0 500000) (T1 500000) (TX 0)
          (TC 200)
        ){output_net}{transient}{floating}
      )
    )
  )
)
"""


class SaifXPolicyTest(TempDirTest):
    def validate(self, command: str, saif_text: str, *extra: str) -> subprocess.CompletedProcess[str]:
        return qualify(command, self.write("dut.saif", saif_text), *extra)

    # clean runs pass
    def test_clean_sc_passes(self) -> None:
        result = self.validate("saif-sc", make_saif(output="acc_out"))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_clean_binary_passes(self) -> None:
        result = self.validate("saif-binary", make_saif(output="ofm"))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    # dead-net persistent X is benign by default
    def test_dead_net_persistent_x_benign_sc(self) -> None:
        result = self.validate("saif-sc", make_saif(output="acc_out", floating_tx=DURATION))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("benign", result.stdout + result.stderr)

    def test_dead_net_persistent_x_benign_binary(self) -> None:
        result = self.validate("saif-binary", make_saif(output="ofm", floating_tx=DURATION))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("benign", result.stdout + result.stderr)

    # but --strict-persistent-x still rejects any persistent X
    def test_dead_net_persistent_x_strict_fails(self) -> None:
        result = self.validate("saif-binary", make_saif(output="ofm", floating_tx=DURATION), "--strict-persistent-x")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("persistent-X signals=1", result.stdout + result.stderr)

    # persistent X on the architectural OUTPUT always fails (broken execution): the dedicated output gate
    # survives the persistent-X relaxation
    def test_output_x_fails_sc(self) -> None:
        result = self.validate("saif-sc", make_saif(output="acc_out", output_tx=DURATION))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("accumulator", result.stdout + result.stderr)

    def test_output_x_fails_binary(self) -> None:
        result = self.validate("saif-binary", make_saif(output="ofm", output_tx=DURATION))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("output TX", result.stdout + result.stderr)

    # transient X beyond one reporter quantum fails
    def test_transient_sc_x_beyond_reporter_quantum_fails(self) -> None:
        result = self.validate("saif-sc", make_saif(output="acc_out", transient_tx=10))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("exceeds one reporter quantum", result.stdout + result.stderr)

    # additional regression cases
    def test_wrong_clock_period_fails(self) -> None:
        result = self.validate("saif-sc", make_saif(output="acc_out"), "--expected-period-ns", "2.0")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("observed clock period=2.500000 ns", result.stderr)

    def test_binary_output_outside_top_dut_is_not_counted(self) -> None:
        text = make_saif(output="ofm").replace("(INSTANCE dut", "(INSTANCE other")
        result = self.validate("saif-binary", text)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no Top/dut architectural output activity", result.stderr)

    def test_missing_saif_fails(self) -> None:
        result = qualify("saif-sc", self.tmp / "absent.saif")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no activity records", result.stderr)


# ---------------------------------------------------------------------------------------------- INT SAIF --

def net(name: str, t0: int, t1: int, tx: int, tc: int, indent: str) -> str:
    return f"{indent}({name}\n{indent}  (T0 {t0}) (T1 {t1}) (TX {tx})\n{indent}  (TC {tc}) (IG 0)\n{indent})\n"


def make_int_saif(*, a_bin_tc: int = 0, encoders: int = 64) -> str:
    """The INT-mode contract at minimal width: one bit per zero group, 1024 raw/bypass bits per side."""
    zero = lambda n, i: net(n, DURATION, 0, 0, 0, i)    # noqa: E731
    top = "      "
    nets = net("clk", 500000, 500000, 0, 800, top) + net("int_mode", 0, DURATION, 0, 0, top)
    nets += net("a_binary_in\\[0\\]", DURATION - (a_bin_tc and 10), a_bin_tc and 10, 0, a_bin_tc, top)
    for base in ("w_binary_in", "a_len_in", "rng_en", "acc_in_west", "block_start", "slice_start"):
        nets += zero(f"{base}\\[0\\]" if base.endswith("_in") else base, top)
    for side in ("a", "w"):
        for n in range(1024):
            tc = n % 7
            nets += net(f"{side}_raw_in\\[{n}\\]", DURATION - 1, 1, 0, tc, top)
            nets += net(f"{side}_bits\\[{n}\\]", DURATION - 1, 1, 0, tc, top)
    sub = "          "
    # 64 A elements (N_H*K at K8/M16): 512 magnitude bits, one encoder each.
    periph = "".join(zero(f"a_binary_q\\[{n}\\]", sub) for n in range(64 * 8))
    periph += "".join(zero(f"{b}\\[0\\]", sub) for b in ("a_len_q", "w_binary_q", "ka_flat"))
    kas = "".join(f"        (INSTANCE g_{k}__u_ka\n          (NET\n{zero('ka', '            ')}          )\n        )\n"
                  for k in range(encoders))
    rng = "".join(net(b, DURATION, 0, 0, 0, sub) for b in ("cyc", "phase", "w_words"))
    return (f"(SAIFILE\n(TIMESCALE 1 ps)\n(DURATION {DURATION})\n"
            f"(INSTANCE Top\n  (INSTANCE dut\n    (NET\n{nets}    )\n"
            f"      (INSTANCE u_peripheral\n        (NET\n{periph}        )\n{kas}      )\n"
            f"      (INSTANCE u_rng\n        (NET\n{rng}        )\n      )\n  )\n)\n)\n")


class SaifIntTest(TempDirTest):
    def test_contract_passes(self) -> None:
        result = qualify("saif-int", self.write("dut.saif", make_int_saif()), "--json", self.tmp / "audit.json")
        self.assertEqual(result.returncode, 0, result.stdout)
        audit = json.loads((self.tmp / "audit.json").read_text())
        self.assertEqual(audit["groups"]["bypass_a"]["bits"], 1024)
        self.assertEqual(audit["groups"]["Top/dut/u_peripheral/*u_ka/ka"]["instances"], 64)

    def test_toggling_magnitude_fails(self) -> None:
        result = qualify("saif-int", self.write("dut.saif", make_int_saif(a_bin_tc=2)))
        self.assertEqual(result.returncode, 1)
        self.assertIn("Top/dut/a_binary_in: 1 of 1 nets not held at 0", result.stdout)

    def test_missing_encoder_fails(self) -> None:
        result = qualify("saif-int", self.write("dut.saif", make_int_saif(encoders=63)))
        self.assertEqual(result.returncode, 1)
        self.assertIn("63 kA encoder instances", result.stdout)


# ------------------------------------------------------------------------------------------------ GL logs --

PASS_LINE = "PASS: streaming SC SAIF captured; 384 batches x 8 cycles"


def make_gl_log(sdf: Path, *, extra_warnings: str = "", warning_total: int = 1, tail: str = "") -> str:
    uhicd = (f"Warning-[SDFCOM_UHICD] Up-hierarchy Interconnect Delay ignored\n{sdf}, 2\n"
             'module: XOR3, "instance: Top.dut.u0"\n'
             "  SDF Warning: INTERCONNECT Delay to up-hierarchy destination acc is \n"
             "  ignored, DEVICE Delay on port 'Y' applied.\n\n")
    return ("vcs ... +neg_tchk +sdfverbose\n  sdf corner = max\n   ***   $sdf_annotate() version 1.2R\n"
            f"{uhicd}{extra_warnings}"
            f"          Total errors: 0\n          Total warnings: {warning_total}\n"
            "   ***    SDF annotation completed: Mon Oct  5 08:39:19 2026\n"
            "[INFO] $sdf_annotate(`SDF_FILE, dut)\n[INFO] Performed reset at time 13000\n"
            f"{PASS_LINE}\n{tail}")


IWSBA = ("Warning-[SDFCOM_IWSBA] INTERCONNECT will still be annotated\n{sdf}, 3\n"
         'module: BUFH, "instance: Top.dut.u_combiner.buf0"\n'
         "  SDF Warning: INTERCONNECT from u_combiner.buf0.Y to   \n  int_out has Instance at \n"
         "  /x/top.apr.v:404354,\n  delay will still be annotated.\n\n")
NDI = ("Warning-[SDFCOM_NDI] Negative Delay Ignored\n{sdf}, 4\n"
       'module: AOI211, "instance: Top.dut.u_peripheral.U1"\n'
       "  SDF Warning: Negative delay is ignored and replaced by 0.\n  Please use -negdelay to support it. \n\n")


class RoutedGlTest(TempDirTest):
    def setUp(self) -> None:
        super().setUp()
        self.sdf = self.write("top.apr.sdf", "(DELAYFILE\n(INTERCONNECT u0/Y acc (0.010::0.012))\n"
                                             "(INTERCONNECT u_combiner/buf0/Y int_out[60] (0.000::0.000))\n"
                                             "(COND A0==1'b0 (IOPATH C0 Y (0.087::0.105) (-0.007::-0.002)))\n")

    def audit(self, text: str, *extra: str) -> tuple[int, dict]:
        result = qualify("routed-gl", self.write("sim.log", text), "--json", self.tmp / "q.json", *extra)
        return result.returncode, json.loads((self.tmp / "q.json").read_text())

    def test_clean_log_passes(self) -> None:
        rc, q = self.audit(make_gl_log(self.sdf))
        self.assertEqual((rc, q["rejection_reasons"]), (0, []))
        self.assertEqual(q["sdf_warning_categories"], {"SDFCOM_UHICD": 1})

    def test_timing_checks_disabled_fails(self) -> None:
        rc, q = self.audit(make_gl_log(self.sdf).replace("+neg_tchk", "+notimingcheck"))
        self.assertEqual(rc, 1)
        self.assertIn("timing model or timing checks disabled in command", q["rejection_reasons"])

    def test_iwsba_needs_the_approval(self) -> None:
        text = make_gl_log(self.sdf, extra_warnings=IWSBA.format(sdf=self.sdf), warning_total=2)
        rc, q = self.audit(text)
        self.assertEqual((rc, q["rejection_reasons"]), (1, ["unapproved SDF warnings: SDFCOM_IWSBA"]))
        rc, q = self.audit(text, "--approve-annotated-interconnect")
        self.assertEqual(rc, 0, q["rejection_reasons"])
        self.assertEqual(q["approved_annotated_interconnects"][0]["destination"], "int_out")

    def test_ndi_clamp_limit(self) -> None:
        text = make_gl_log(self.sdf, extra_warnings=NDI.format(sdf=self.sdf), warning_total=2)
        rc, q = self.audit(text, "--approve-negative-iopath-clamp-ps", "10")
        self.assertEqual(rc, 0, q["rejection_reasons"])
        self.assertEqual(q["approved_negative_iopath_clamps"][0]["most_negative_ps"], -7.0)
        rc, q = self.audit(text, "--approve-negative-iopath-clamp-ps", "5")
        self.assertEqual(rc, 1)
        self.assertIn("beyond -5.0 ps", q["rejection_reasons"][0])

    def test_post_reset_violation_fails_startup_passes(self) -> None:
        def violation(t: int) -> str:
            return (f'"/x/DFF.v", 9: Timing violation in Top.dut.r0\n'
                    f"    $setuphold( posedge CK:{t}, posedge D:{t - 5}, 30 : 30, 20 : 20 );\n\n")
        rc, q = self.audit(make_gl_log(self.sdf, tail=violation(9000)))
        self.assertEqual((rc, q["startup_timing_violations"]), (0, 1))
        rc, q = self.audit(make_gl_log(self.sdf, tail=violation(20000)))
        self.assertEqual((rc, q["post_reset_timing_violations"]), (1, 1))

    def test_gl_audit_strict_first_with_rationale(self) -> None:
        sim, work = self.tmp / "sim", self.tmp / "work"
        work.mkdir()
        self.write("sim/simulation.log", make_gl_log(self.sdf, extra_warnings=IWSBA.format(sdf=self.sdf),
                                                     warning_total=2))
        self.write("sim/expected_pass.txt", PASS_LINE + "\n")
        flag = "--approve-annotated-interconnect"
        self.assertEqual(qualify("gl-audit", sim, "--work", work).returncode, 1)          # no approval
        result = qualify("gl-audit", sim, "--work", work, flag)
        self.assertEqual(result.returncode, 1)                                            # no rationale
        self.assertIn("need a rationale file", result.stderr)
        self.write("work/gl_validator_args_rationale.txt", "investigated: the combiner sign-extension aliases\n")
        self.assertIn("does not cite", qualify("gl-audit", sim, "--work", work, flag).stderr)
        self.write("work/gl_validator_args_rationale.txt", f"Approval: {flag}\n")
        result = qualify("gl-audit", sim, "--work", work, flag)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads((sim / "timing_qualification_strict.json").read_text())["status"], "FAIL")
        self.assertEqual(json.loads((sim / "timing_qualification.json").read_text())["status"], "PASS")
        record = (work / "gl_validator_args.txt").read_text().splitlines()
        self.assertEqual(len(record), 1)
        self.assertIn(f"strict=FAIL strict_reasons=['unapproved SDF warnings: SDFCOM_IWSBA'] approvals_used='{flag}'",
                      record[0])
        self.assertTrue(record[0].endswith("iwsba=1 post_reset_violations=0 status=PASS"))

    def test_syn_gl_excuses_only_reset_removal_cftc(self) -> None:
        def cftc(module: str) -> str:
            return (f"Warning-[SDFCOM_CFTC] Cannot find timing check \n{self.sdf}, 5\n"
                    f'module: {module}, "instance: Top.dut.r0"\n'
                    "  SDF Warning: Cannot find timing check $hold(posedge CK,negedge R,...)\n      \n\n")
        for module, rc in (("DFFRPQA2W_X1M", 0), ("SDFFQ_X1M", 1)):
            log = self.write("syn.log", make_gl_log(self.sdf, extra_warnings=cftc(module), warning_total=2))
            qualify("routed-gl", log, "--json", self.tmp / "syn.json")
            result = qualify("syn-gl", log, self.tmp / "syn.json")
            self.assertEqual(result.returncode, rc, result.stdout)


# ------------------------------------------------------------------------------------------- routed APR --

def make_route(root: Path, *, geometry_viols: int = 0, setup_slack: str = "0.104") -> Path:
    route = root / "route"
    (route / "outputs").mkdir(parents=True)
    (route / "reports").mkdir()
    for suffix in ("apr.v", "apr.sdf", "spef"):
        (route / "outputs" / f"top.{suffix}").write_text("x\n")
    (route / "top.syn.sdc").write_text("create_clock\n")
    (route / "apr.log").write_text(
        "Begin checking placement ...\nUnplaced = 0\nFinished checkPlace (total: 1s)\n"
        f"Verification Complete : {geometry_viols} Viols.\n"
        "******** Start: VERIFY CONNECTIVITY ********\nFound no problems or warnings.\n"
        "******** End: VERIFY CONNECTIVITY ********\nVerification Complete : 0 Viols.\n"
        "Verification Complete: 0 Violations\nMessage Summary: 12 warning(s), 0 error(s)\n"
        'Innovus script finished\n--- Ending "Innovus" (totcpu=0:01:00)\n')
    (route / "top.geom.rpt").write_text(f"Total Violations : {geometry_viols}\n" if geometry_viols
                                        else "No DRC violations were found\n")
    (route / "top.antenna.rpt").write_text("No Violations Found\n")
    (route / "reports/setup.rpt").write_text(f"Slack Time {setup_slack}\n")
    (route / "reports/hold.rpt").write_text("Slack Time 0.142\n")
    (route / "reports/area.rpt").write_text("Hinst Name  Module Name  Inst Count  Total Area\ntop 81234 44430.554\n")
    return route


class RoutedAprTest(TempDirTest):
    def test_clean_route_passes_both_rule_sets(self) -> None:
        route = make_route(self.tmp)
        result = qualify("routed-apr", route, "top", "--json", self.tmp / "q.json")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads((self.tmp / "q.json").read_text())["area_um2"], 44430.554)
        result = qualify("routed-apr", route, "top", "--stage", "final")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["qualification"], "final")

    def test_markers_fail_final_pass_bootstrap(self) -> None:
        route = make_route(self.tmp, geometry_viols=5)
        self.assertIn("geometry violations", qualify("routed-apr", route, "top").stderr)
        self.assertIn("final geometry DRC 5", qualify("routed-apr", route, "top", "--stage", "final").stderr)
        result = qualify("routed-apr", route, "top", "--stage", "bootstrap")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["geometry_drc"], 5)

    def test_negative_slack_fails(self) -> None:
        route = make_route(self.tmp, setup_slack="-0.002")
        result = qualify("routed-apr", route, "top", "--stage", "bootstrap")
        self.assertEqual(result.returncode, 1)
        self.assertIn("setup timing violation -0.002", result.stderr)


# ------------------------------------------------------------------------------------------ PT coverage --

def coverage_row(file_nets: int, static: int, default: int) -> str:
    cells = [file_nets, static, 0, 0, 0, 0, default, 0, 0, 0]
    total = sum(cells)
    return " Nets  " + "  ".join(f"{c}({100 * c / total:.2f}%)" for c in cells) + f"  {total}\n"


class PtCoverageTest(TempDirTest):
    def reports(self, default: int = 0, boundary_missing: int = 0) -> Path:
        self.write("r/saif_coverage.rpt", coverage_row(1000, 47, default) + "\n" + coverage_row(1000, 47, default))
        self.write("r/parasitics_coverage.rpt",
                   "  - Pin to pin nets |   6807 |       0 |       0 |   6807 |       0 |\n"
                   f"  - Pin to pin nets |    372 |       0 |       0 |  {372 - boundary_missing} |"
                   f"    {boundary_missing} |\n")
        self.write("r/power_apr.log", "Forced 47 pinless net(s) to static-zero activity\n")
        return self.tmp / "r"

    def test_complete_coverage_passes(self) -> None:
        r = self.reports()
        result = qualify("pt-coverage", r, "--power-log", r / "power_apr.log")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(json.loads(result.stdout)["boundary_pin_to_pin_nets"], 372)

    def test_default_activity_fails(self) -> None:
        r = self.reports(default=3)
        result = qualify("pt-coverage", r, "--power-log", r / "power_apr.log")
        self.assertEqual(json.loads(result.stdout), {"status": "FAIL",
                                                     "reason": "switching has 3 default and 0 unannotated nets"})

    def test_unannotated_parasitics_fail(self) -> None:
        r = self.reports(boundary_missing=2)
        result = qualify("pt-coverage", r, "--power-log", r / "power_apr.log")
        self.assertEqual(json.loads(result.stdout)["reason"], "2 pin-to-pin nets lack annotated parasitics")


# ------------------------------------------------------------------------------------- SDF clock gates --

def make_sdf(icg_delay: str) -> str:
    return ("(DELAYFILE\n(CELL\n  (CELLTYPE \"PREICG_X0P5B\")\n  (INSTANCE u_pe/clk_gate_acc/latch)\n"
            f"  (DELAY\n    (ABSOLUTE\n    (IOPATH CK ECK ({icg_delay}:{icg_delay}:{icg_delay}) "
            f"({icg_delay}:{icg_delay}:{icg_delay}))\n    )\n  )\n"
            "  (TIMINGCHECK\n    (SETUP E (posedge CK) (0.050:0.050:0.050))\n  )\n)\n"
            "(CELL\n  (CELLTYPE \"AND2_X1\")\n  (INSTANCE u_pe/U1)\n"
            "  (DELAY\n    (ABSOLUTE\n    (IOPATH A Y (0.020:0.020:0.020) (0.021:0.021:0.021))\n    )\n  )\n)\n)\n")


class SdfClockTest(TempDirTest):
    def test_routed_icg_passes_synthesis_icg_fails(self) -> None:
        for delay, rc in (("0.035", 0), ("3.281", 1)):
            sdf = self.write("top.sdf", make_sdf(delay))
            result = qualify("sdf-clock", sdf, "--period-ns", "2.5", "--json", self.tmp / "a.json")
            self.assertEqual(result.returncode, rc, result.stdout)
            self.assertEqual(json.loads((self.tmp / "a.json").read_text())["worst_icg_iopath_ns"], float(delay))

    def test_sim_log_must_name_this_sdf(self) -> None:
        sdf = self.write("top.sdf", make_sdf("0.035"))
        log = self.write("sim.log", f'  sdf     = {sdf}\n   ***    SDF file: "{self.tmp}/ideal/top.sdf"\n')
        result = qualify("sdf-clock", sdf, "--period-ns", "2.5", "--sim-log", log, "--json", self.tmp / "a.json")
        self.assertEqual(result.returncode, 1)
        self.assertIn("bench annotated", result.stdout)

    def test_ideal_clock_view_zeroes_only_icg_iopaths(self) -> None:
        text = make_sdf("3.281")
        out = self.tmp / "view/top.sdf"
        result = qualify("ideal-clock-sdf", self.write("top.sdf", text), out, "--report", self.tmp / "r.txt")
        self.assertEqual(result.returncode, 0, result.stderr)
        expected = text.replace("(3.281:3.281:3.281)", "(0.000:0.000:0.000)")
        self.assertEqual(out.read_text(), expected)          # timing check and the AND2 delays unchanged
        self.assertIn("3.281 ns  u_pe/clk_gate_acc/latch  (PREICG_X0P5B)", (self.tmp / "r.txt").read_text())


# ------------------------------------------------------------------------------------------- basin gate --

def make_def(collapse: bool = False) -> str:
    """2x2 tiles, two cells each; collapse lays each tile row out along x, so x no longer follows the column."""
    comps = []
    for h in range(2):
        for v in range(2):
            x = (h if collapse else v) * 20000 + 1000
            y = (1 - h) * 20000 + 1000
            for k in range(2):
                comps.append(f"- u_pe/u_array_core/g_row_{h}__g_col_{v}__u_inner/U{k} AND2_X1 "
                             f"+ PLACED ( {x + k * 400} {y} ) N ;")
    pins = ["- a_binary_in[0] + NET a_binary_in[0] + DIRECTION INPUT + USE SIGNAL",
            "  + LAYER M2 ( -50 0 ) ( 50 100 )", "  + FIXED ( 548120 540500 ) W ;"]
    nets = ["- n1 ( U0 A ) ( U1 Y )", "  + ROUTED M2 ( 1000 1000 ) ( 3000 * )", "  NEW M3 ( 3000 1000 ) ( * 5000 ) ;"]
    return ("VERSION 5.8 ;\nUNITS DISTANCE MICRONS 2000 ;\nDIEAREA ( 0 0 ) ( 80000 80000 ) ;\n"
            f"COMPONENTS {len(comps)} ;\n" + "\n".join(comps) + "\nEND COMPONENTS\n"
            "PINS 1 ;\n" + "\n".join(pins) + "\nEND PINS\nNETS 1 ;\n" + "\n".join(nets) + "\nEND NETS\nEND DESIGN\n")


class BasinTest(TempDirTest):
    def route(self, collapse: bool = False, skew_ns: float = 0.02) -> Path:
        self.write("route/outputs/top.apr.def", make_def(collapse))
        rows = ["tile_row\ttile_col\tcell\ta_pin\tw_pin\ta_arr\tw_arr\ta_slew\tw_slew"]
        for h in range(2):
            for v in range(2):
                rows.append(f"{h}\t{v}\tc\ta\tw\t0.150\t{0.150 + skew_ns:.3f}\t0.2\t0.3")
        self.write("skew.tsv", "\n".join(rows) + "\n")
        self.write("plan.tsv", "pin\tedge\tlayer\tx\ty\n" "a_binary_in[0]\tW\tM2\t274.06\t270.25\n")
        return self.tmp / "route"

    def gate(self, route: Path) -> tuple[int, dict]:
        result = qualify("basin", route, "top", self.tmp / "out", "t", "--skew", self.tmp / "skew.tsv",
                         "--plan", self.tmp / "plan.tsv")
        return result.returncode, json.loads((self.tmp / "out/basin_gate.json").read_text())

    def test_grid_basin_passes(self) -> None:
        rc, j = self.gate(self.route())
        self.assertEqual((rc, j["gate"]["basin"], j["pin_proof"]["status"]), (0, "grid", "PASS"))
        self.assertAlmostEqual(j["corr_x_col"], 1.0)
        self.assertAlmostEqual(j["wire_mm"], (1.0 + 2.0) / 1e3)   # 2000 + 4000 DEF units at 2000/um
        self.assertEqual(j["die_um"], [40.0, 40.0])

    def test_large_skew_collapses(self) -> None:
        rc, j = self.gate(self.route(skew_ns=0.145))
        self.assertEqual((rc, j["gate"]["basin"]), (3, "collapsed"))

    def test_stacked_columns_collapse(self) -> None:
        rc, j = self.gate(self.route(collapse=True))
        self.assertEqual(rc, 3)
        self.assertLess(j["corr_x_col"], 0.8)

    def test_moved_pin_fails_proof(self) -> None:
        route = self.route()
        self.write("plan.tsv", "pin\tedge\tlayer\tx\ty\n" "a_binary_in[0]\tW\tM2\t274.56\t270.25\n")
        rc, j = self.gate(route)
        self.assertEqual((rc, j["pin_proof"]["mismatches"]), (3, 1))

    def test_missing_layout_is_an_error(self) -> None:
        result = qualify("basin", self.tmp / "none", "top", self.tmp / "out", "t", "--skew", self.tmp / "s.tsv")
        self.assertEqual(result.returncode, 2)


if __name__ == "__main__":
    unittest.main()
