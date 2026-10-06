#!/usr/bin/env python3
"""Debug helper (2026-10-05): walk back from one flop pin through a hierarchical gate netlist and print each
driver cell's pin nets with their transitions from a VCD window (sweeps/cbsg/rg/gl_window_probe.sv).
  gl_cone_trace.py NETLIST VCD SCOPE INSTANCE PIN [--depth N] [--t0 PS] [--t1 PS]
SCOPE is the VCD scope of the module holding INSTANCE (e.g. Top.dut.u_pe.u_array_core); the walk follows
drivers inside that module and crosses module ports upward/downward when the net is a port.
"""
import argparse, re, sys, collections

ap = argparse.ArgumentParser()
ap.add_argument('netlist'); ap.add_argument('vcd'); ap.add_argument('scope'); ap.add_argument('inst'); ap.add_argument('pin')
ap.add_argument('--depth', type=int, default=25); ap.add_argument('--t0', type=float, default=0); ap.add_argument('--t1', type=float, default=1e18)
a = ap.parse_args()

src = open(a.netlist).read()
mods = {}
for m in re.finditer(r'^module\s+(\S+)\s*\((.*?)\);(.*?)^endmodule', src, re.S | re.M):
    mods[m[1]] = m[3]
inst_re = re.compile(r'^\s*(\w+)\s+(\\\S+|\w+)\s*\((.*?)\);', re.S | re.M)
OUTPINS = {'Y', 'Q', 'QN', 'Q0', 'Q1', 'QN0', 'QN1', 'S', 'CO', 'CON', 'ECK'}
def parse(body):
    insts = {}
    for m in inst_re.finditer(body):
        if m[1] in ('input', 'output', 'wire', 'assign', 'module'):
            continue
        pins = {p: n.strip() for p, n in re.findall(r'\.(\w+)\(\s*([^()]*?)\s*\)', m[3])}
        insts[m[2].lstrip('\\')] = (m[1], pins)
    return insts
parsed = {k: parse(v) for k, v in mods.items()}
def assigns(body):
    return {l: r for l, r in re.findall(r'^\s*assign\s+(\S+(?:\s*\[\d+\])?)\s*=\s*(\S+(?:\s*\[\d+\])?)\s*;', body, re.M)}

# scope -> module name via instance chain from the top module
top = [k for k in mods if k == 'payn_array_signed_segmented_csa_cbsg_rg'][0]
def module_of(scope):
    parts = scope.split('.')[2:]          # drop Top.dut
    mod = top
    for p in parts:
        mod = parsed[mod][p][0]
    return mod

# VCD: map (scope, net) -> id, id -> transitions
ids = collections.defaultdict(list); names = {}
stack = []; trans = collections.defaultdict(list); t = 0
with open(a.vcd) as f:
    for line in f:
        s = line.split()
        if not s: continue
        if s[0] == '$scope': stack.append(s[2])
        elif s[0] == '$upscope': stack.pop()
        elif s[0] == '$var':
            ref = s[4] + (s[5] if s[5].startswith('[') else '')
            names[('.'.join(stack), ref)] = s[3]
        elif s[0].startswith('#'):
            t = int(s[0][1:])
        elif s[0][0] in '01xzXZ' and len(s) == 1:
            if a.t0 <= t <= a.t1: trans[s[0][1:]].append((t, s[0][0]))
        elif s[0][0] in 'bB' and len(s) == 2:
            if a.t0 <= t <= a.t1: trans[s[1]].append((t, s[0][1:]))
def bit_trans(scope, net):
    """Transitions of a scalar net or of one bit of a VCD vector var."""
    net = net.replace(' ', '').lstrip('\\')
    if (scope, net) in names:
        return trans.get(names[(scope, net)], [])
    m = re.match(r'(.*)\[(\d+)\]$', net)
    if not m:
        return None
    base, bit = m[1], int(m[2])
    for (sc, ref), i in names.items():
        mm = re.match(re.escape(base) + r'\[(\d+):(\d+)\]$', ref)
        if sc == scope and mm:
            hi, lo = int(mm[1]), int(mm[2])
            if not (lo <= bit <= hi): continue
            out, prev = [], None
            for tt, v in trans.get(i, []):
                v = v.rjust(hi - lo + 1, '0' if v[0] in '01' else v[0])
                b = v[hi - bit]
                if b != prev: out.append((tt, b)); prev = b
            return out
    return None
def show(scope, net):
    tr = bit_trans(scope, net)
    if tr is None:
        return f'{net}: (not in VCD)'
    return f'{net}: ' + ' '.join(f'{v}@{tt}' for tt, v in tr[-6:])

def driver(mod, net):
    for name, (cell, pins) in parsed[mod].items():
        for p, n in pins.items():
            if n.replace(' ', '') == net.replace(' ', '') and p in OUTPINS:
                return name, cell, pins, p
    return None

scope, mod = a.scope, module_of(a.scope)
cell, pins = parsed[mod][a.inst]
net = pins[a.pin]
print(f'{a.inst} ({cell}) {a.pin} <- {show(scope, net)}   CK: {show(scope, pins.get("CK", "?"))}')
seen = set()
for step in range(a.depth):
    d = driver(mod, net)
    if d is None:
        print(f'  net {net} has no driver cell in {mod} (port or assign); stop'); break
    name, cell, pins, op = d
    ins = {p: n for p, n in pins.items() if p not in OUTPINS}
    print(f'[{step}] {scope}/{name} ({cell}) out {op}={show(scope, pins[op])}')
    for p, n in ins.items():
        print(f'        in {p}: {show(scope, n)}')
    # follow the input whose last transition is latest
    best = None
    for p, n in ins.items():
        tr = bit_trans(scope, n) or []
        if tr and (best is None or tr[-1][0] > best[0]): best = (tr[-1][0], n)
    if best is None: print('  no input transitions in window; stop'); break
    net = best[1]
    if net in seen: break
    seen.add(net)
