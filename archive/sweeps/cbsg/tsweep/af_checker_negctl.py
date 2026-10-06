#!/usr/bin/env python3
"""Negative controls for the AF L-sweep drain check (sweeps/cbsg/tsweep/check_af_power_trace_vart.py).

For every uniform-L point's GL trace, two mutated copies (in a temporary directory) must FAIL the checker:
  relabel   the LADDER line and every ALEN line rewritten to L-1 (same ceil(L/16) cycle count, so the schedule checks
            still pass and only the drained values can tell L from L-1),
  drain+1   one drained accumulator incremented by 1.
The unmodified trace must PASS.  Writes OUT/negctl.json.

  python3 sweeps/cbsg/tsweep/af_checker_negctl.py [--sweep DIR]
"""
import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
SWEEP = REPO / "build/power_char/cbsg_20261005/tsweep/af"
TB = "designs/payn/power/power_payn_array_cbsg_af_vart.sv"
CHECKER = REPO / "sweeps/cbsg/tsweep/check_af_power_trace_vart.py"


def run(trace):
    p = subprocess.run([sys.executable, "-B", str(CHECKER), str(trace)], capture_output=True, text=True)
    return p.returncode, (p.stdout + p.stderr).strip().splitlines()[0][:200]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sweep", default=str(SWEEP))
    sweep = Path(ap.parse_args().sweep)
    out, ok = {}, True
    with tempfile.TemporaryDirectory() as td:
        for d in sorted(sweep.glob("u[0-9][0-9][0-9]")):
            tr = d / "gl" / TB / "array_streaming_cbsg_af_rtl.txt"
            if not tr.is_file():
                continue
            L = int(d.name[1:])
            lines = tr.read_text().splitlines()
            assert lines[1] == f"LADDER {L}", lines[1]
            rc0, msg0 = run(tr)
            Lw = L - 1
            assert -(-Lw // 16) == -(-L // 16)
            rel = [f"LADDER {Lw}" if i == 1 else (" ".join(["ALEN"] + [str(Lw)] * (len(ln.split()) - 1))
                                                  if ln.startswith("ALEN") else ln) for i, ln in enumerate(lines)]
            p1 = Path(td) / f"{d.name}_relabel.txt"
            p1.write_text("\n".join(rel) + "\n")
            rc1, msg1 = run(p1)
            dr = []
            for ln in lines:
                if ln.startswith("DRAIN"):
                    t = ln.split()
                    t[1] = str(int(t[1]) + 1)
                    ln = " ".join(t)
                dr.append(ln)
            p2 = Path(td) / f"{d.name}_drain.txt"
            p2.write_text("\n".join(dr) + "\n")
            rc2, msg2 = run(p2)
            good = rc0 == 0 and rc1 != 0 and rc2 != 0
            ok &= good
            out[d.name] = dict(L=L, original=dict(rc=rc0, msg=msg0), relabel_to=Lw, relabel=dict(rc=rc1, msg=msg1),
                               drain_plus_1=dict(rc=rc2, msg=msg2), status="PASS" if good else "FAIL")
            print(f"{d.name}: original rc {rc0}, relabel L={Lw} rc {rc1} ({msg1[:90]}), drain+1 rc {rc2} -> "
                  f"{out[d.name]['status']}")
    out["status"] = "PASS" if ok else "FAIL"
    (sweep / "negctl.json").write_text(json.dumps(out, indent=1) + "\n")
    print(f"negative controls {out['status']} -> {sweep / 'negctl.json'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
