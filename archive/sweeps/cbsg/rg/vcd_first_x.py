#!/usr/bin/env python3
"""Find where X first appears in a gate-level VCD (debug helper for sweeps/cbsg/rg/gl_x_ladder.sh / gl_xprobe.sv).

Prints, for every timestamp after --after (ps), the signals that become X/Z (bit-level for vectors), up to --max-times
timestamps, and the X census at the end of the dump.  Names are full VCD scopes below the dump root.
  python3 sweeps/cbsg/rg/vcd_first_x.py build/cbsg/rg/gl/<run>/xprobe/xprobe.vcd --after 13000
"""
import argparse
import re
from collections import defaultdict

ap = argparse.ArgumentParser()
ap.add_argument("vcd")
ap.add_argument("--after", type=int, default=0, help="report X transitions at or after this time (ps)")
ap.add_argument("--max-times", type=int, default=12)
ap.add_argument("--max-names", type=int, default=25)
ap.add_argument("--grep", default=None, help="only report signals matching this regex")
ap.add_argument("--trace", default=None, help="instead: print every value change of signals matching this regex")
ap.add_argument("--until", type=int, default=None, help="with --trace: stop at this time (ps)")
args = ap.parse_args()

names = defaultdict(list)     # id -> [full names]
scope = []
val = {}
timescale_ps = 1
t = 0
reported_times = 0
xcount_at = {}
pat = re.compile(args.grep) if args.grep else None
trace = re.compile(args.trace) if args.trace else None
with open(args.vcd) as fh:
    in_defs = True
    for line in fh:
        if in_defs:
            f = line.split()
            if not f:
                continue
            if f[0] == "$scope":
                scope.append(f[2])
            elif f[0] == "$upscope":
                scope.pop()
            elif f[0] == "$var":
                width, code, ref = int(f[2]), f[3], f[4]
                names[code].append(("/".join(scope[1:]) + "/" + ref, width))
            elif f[0] == "$timescale":
                pass
            elif f[0] == "$enddefinitions":
                in_defs = False
            continue
        line = line.strip()
        if not line or line.startswith("$"):
            continue
        c = line[0]
        if c == "#":
            t = int(line[1:])
            continue
        if c in "01xzXZ":
            code, v = line[1:], c.lower()
        elif c in "bB":
            v, code = line[1:].split()
            v = v.lower()
        else:
            continue
        old = val.get(code)
        val[code] = v
        if trace is not None:
            if args.until is not None and t > args.until:
                break
            for n, w in names[code]:
                if trace.search(n):
                    print(f"t={t} {n} = {v}")
            continue
        newx = ("x" in v or "z" in v) and not (old is not None and ("x" in old or "z" in old))
        if newx and t >= args.after:
            xcount_at.setdefault(t, []).append(code)

if trace is not None:
    raise SystemExit(0)
times = sorted(xcount_at)
print(f"{len(names)} signal codes; X transitions at {len(times)} timestamps >= {args.after} ps")
shown = 0
for tt in times:
    nm = []
    for code in xcount_at[tt]:
        for n, w in names[code]:
            if pat is None or pat.search(n):
                nm.append(f"{n}[{w}]" if w > 1 else n)
    if not nm:
        continue
    print(f"t={tt} ps: {len(nm)} signals -> X, e.g.")
    for n in sorted(nm)[: args.max_names]:
        print(f"    {n}")
    shown += 1
    if shown >= args.max_times:
        break
nx = sum(1 for code, v in val.items() if "x" in v or "z" in v)
print(f"end of dump t={t}: {nx} of {len(val)} codes hold X/Z")
