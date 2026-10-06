#!/usr/bin/env python3
"""Check the VCS dump of WoFeederA / WoFeederW against the WO-ring model.

For every dumped lane: INT mode must give code = CODE_[side][k][|d|] and
sign = (d < 0), where d is the model's own booth_digits() digit of the raw byte;
SC mode must pass magnitude and sign through. Also confirms through the model's
comparator thresholds that the produced code gives |d| ones on the right
positions (so the synthesized feeder is the function the model was verified with).

Usage: python3 check_wo_feeder.py feeder_dump.txt
"""
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
import model_weight_outer_horner as mdl  # noqa: E402


def main(path):
    n = {"A": 0, "W": 0}
    for line in open(path):
        f = line.split()
        if f[0] == "A":
            im, p, L, din, sin, code, sgn = map(int, f[1:])
            k = L % 8
            byte = din - 256 if din >= 128 else din
            d = int(mdl.booth_digits(byte, 8, 2)[p])
            if im:
                assert code == mdl.CODE_A[k][abs(d)], (line, d)
                assert sgn == int(d < 0), (line, d)
                assert int(np.sum(code > mdl.THR_A[k])) == 8 * abs(d), line
            else:
                assert code == din and sgn == sin, line
        else:
            im, hys, q, L, din, sin, code, sgn = map(int, f[1:])
            v, k = L // 8, L % 8
            qe = (v & 1) if hys else q
            byte = din - 256 if din >= 128 else din
            d = int(mdl.booth_digits(byte, 8, 4)[qe])
            if im:
                assert code == mdl.CODE_W[k][abs(d)], (line, d)
                assert sgn == int(d < 0), (line, d)
                assert int(np.sum(code > mdl.THR_W[k])) == 2 * abs(d), line
            else:
                assert code == din and sgn == sin, line
        n[f[0]] += 1
    assert n["A"] == 2 * 4 * 256 * 64 and n["W"] == 2 * 4 * 256 * 64, n
    print(f"PASS feeder dump: {n['A']} A-lane and {n['W']} W-lane vectors match the "
          f"model's booth_digits + CODE tables (INT) and pass-through (SC)")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "feeder_dump.txt")
