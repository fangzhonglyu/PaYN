#!/usr/bin/env python3
"""4-state (0/1/X) evaluator for the PaYN tile netlists.

Question answered: at t=0 (reset=1, shift_in=0, every flop/ICG output X,
operand inputs X), do the acc_low D inputs resolve to a known value, or does
the X-pessimistic cone latch X at the first clock edge?

Cell semantics are parsed from the ARM library Verilog models themselves
(primitive gate graphs), not guessed.
"""
import re, sys, random

X = 'x'

# ---------------------------------------------------------------- preprocess
def preprocess(text, defines=frozenset()):
    """Minimal `ifdef handling with a given define set; strips specify blocks."""
    out = []
    stack = []  # each entry: currently-active?
    active = True
    for line in text.split('\n'):
        s = line.strip()
        if s.startswith('`ifdef') or s.startswith('`ifndef'):
            name = s.split()[1] if len(s.split()) > 1 else ''
            cond = (name in defines) if s.startswith('`ifdef') else (name not in defines)
            stack.append(active)
            active = active and cond
            continue
        if s.startswith('`else'):
            if stack:
                parent = stack[-1]
                # active was parent&cond; flip cond
                was = active
                active = parent and not (was)
                # note: this simple flip is wrong if active was False due to parent False,
                # but parent False keeps active False either way.
                if not parent:
                    active = False
            continue
        if s.startswith('`endif'):
            if stack:
                active = stack.pop()
            continue
        if active:
            out.append(line)
    text = '\n'.join(out)
    text = re.sub(r'\bspecify\b.*?\bendspecify\b', '', text, flags=re.S)
    text = re.sub(r'`(celldefine|endcelldefine|timescale[^\n]*)', '', text)
    text = re.sub(r'`ARM_UD_\w+', '', text)  # delay macros between prim and inst name
    return text

# ---------------------------------------------------------------- lib parse
PRIMS = {'and', 'nand', 'or', 'nor', 'xor', 'xnor', 'not', 'buf'}

def parse_lib_cells(paths):
    """name -> dict(outputs=[...], inputs=[...], prims=[(type, out, [ins])], seq=bool)"""
    cells = {}
    for p in paths:
        text = preprocess(open(p).read())
        for m in re.finditer(
                r'module\s+([A-Za-z_][\w$]*)\s*\((.*?)\);(.*?)endmodule', text, re.S):
            name, ports, body = m.group(1), m.group(2), m.group(3)
            if name in cells:
                continue
            outs = re.findall(r'^\s*output\s+(.+?);', body, re.M)
            ins = re.findall(r'^\s*input\s+(.+?);', body, re.M)
            flat = lambda ls: [x.strip() for chunk in ls for x in chunk.split(',')]
            sup1 = flat(re.findall(r'^\s*supply1\s+(.+?);', body, re.M))
            sup0 = flat(re.findall(r'^\s*supply0\s+(.+?);', body, re.M))
            prims, seq = [], False
            for pm in re.finditer(r'^\s*([a-z_][\w$]*)\s+([A-Za-z_][\w$]*)?\s*\((.*?)\);',
                                  body, re.M | re.S):
                ptype, args = pm.group(1), pm.group(3)
                if ptype in ('wire', 'reg', 'input', 'output', 'supply1', 'supply0',
                             'assign', 'initial', 'always', 'table', 'endtable'):
                    continue
                arglist = [a.strip() for a in args.replace('\n', ' ').split(',')]
                if ptype in PRIMS:
                    prims.append((ptype, arglist[0], arglist[1:]))
                elif ptype.startswith('udp_mux2'):
                    prims.append(('mux2', arglist[0], arglist[1:4]))  # in0,in1,sel
                elif 'udp_dff' in ptype or 'udp_tlat' in ptype or ptype.startswith('leaf_udp'):
                    seq = True
                else:
                    seq = True  # unknown submodule -> treat cell as opaque/sequential
            cells[name] = dict(outputs=flat(outs), inputs=flat(ins),
                               sup1=sup1, sup0=sup0, prims=prims, seq=seq)
    return cells

# ---------------------------------------------------------------- 4-state ops
def v_and(vals):
    if any(v == 0 for v in vals): return 0
    if all(v == 1 for v in vals): return 1
    return X
def v_or(vals):
    if any(v == 1 for v in vals): return 1
    if all(v == 0 for v in vals): return 0
    return X
def v_xor(vals):
    if any(v == X for v in vals): return X
    r = 0
    for v in vals: r ^= v
    return r
def v_not(v): return X if v == X else 1 - v
def v_mux2(in0, in1, sel):
    if sel == 0: return in0
    if sel == 1: return in1
    if in0 == in1 and in0 != X: return in0
    return 0 if (in0 == 0 and in1 == 0) else (1 if (in0 == 1 and in1 == 1) else X)

def eval_cell(cell, pinvals):
    """pinvals: dict input pin -> value. Returns dict output pin -> value."""
    nets = dict(pinvals)
    for s in cell['sup1']: nets[s] = 1
    for s in cell['sup0']: nets[s] = 0
    # iterate cell-internal primitive graph to fixed point (tiny graphs)
    for _ in range(30):
        changed = False
        for ptype, out, ins in cell['prims']:
            vals = [nets.get(i, X) for i in ins]
            if ptype == 'and': nv = v_and(vals)
            elif ptype == 'nand': nv = v_not(v_and(vals))
            elif ptype == 'or': nv = v_or(vals)
            elif ptype == 'nor': nv = v_not(v_or(vals))
            elif ptype == 'xor': nv = v_xor(vals)
            elif ptype == 'xnor': nv = v_not(v_xor(vals))
            elif ptype == 'not': nv = v_not(vals[0])
            elif ptype == 'buf': nv = vals[0]
            elif ptype == 'mux2': nv = v_mux2(*vals)
            else: continue
            if nets.get(out, X) != nv or out not in nets:
                nets[out] = nv; changed = True
        if not changed: break
    return {o: nets.get(o, X) for o in cell['outputs']}

# ---------------------------------------------------------------- netlist parse
def parse_netlist_modules(path):
    text = open(path).read()
    text = re.sub(r'//[^\n]*', '', text)
    mods = {}
    for m in re.finditer(r'\bmodule\s+([\w$]+)\s*\((.*?)\);(.*?)\bendmodule', text, re.S):
        mods[m.group(1)] = m.group(3)
    return mods

INST_RE = re.compile(r'([A-Za-z_][\w$]*)\s+([A-Za-z_][\w$\[\]]*)\s*\(\s*(\.[^;]*?)\)\s*;',
                     re.S)
PIN_RE = re.compile(r'\.([\w$]*)\s*\(\s*([^)]*?)\s*\)')

def parse_instances(body):
    insts = []
    for m in INST_RE.finditer(body):
        cell, iname, pins = m.group(1), m.group(2), m.group(3)
        pinmap = {p: n.replace('\n', ' ').strip() for p, n in PIN_RE.findall(pins)}
        insts.append((cell, iname, pinmap))
    return insts

def netval_const(net):
    if re.fullmatch(r"1'b0", net): return 0
    if re.fullmatch(r"1'b1", net): return 1
    return None

# ---------------------------------------------------------------- tile eval
def eval_tile(body, lib, q_value=X, seed=None):
    """Evaluate one uniquified tile module under t=0/reset conditions.
    q_value: X for the startup analysis, or 'random' with seed for mini-LEC.
    Returns dict: reg bit label -> D value, plus list of unknown cells."""
    rng = random.Random(seed)
    insts = parse_instances(body)
    nets = {}

    def setbus(prefix, val):
        # ports referenced as prefix[i] or bare prefix
        nets[prefix] = val  # scalar use

    # primary inputs (conservative: operands X, control known)
    forced = {'reset': 1, 'shift_in': 0}
    for k, v in forced.items(): nets[k] = v
    if q_value == 'random':
        # true reset-LEC mode: binary operands as well, so any D != 0 is a
        # genuine failure of the netlist to implement the sync reset
        for m2 in re.finditer(r'\binput\s*(?:\[(\d+):(\d+)\])?\s*([\w$,\s]+?);', body):
            hi, lo, names = m2.group(1), m2.group(2), m2.group(3)
            for nm in [s.strip() for s in names.split(',')]:
                if nm in ('clk', 'clk_clone1', 'reset', 'shift_in') or not nm:
                    continue
                if hi is None:
                    nets.setdefault(nm, rng.randint(0, 1))
                else:
                    for b in range(int(lo), int(hi) + 1):
                        nets.setdefault(f'{nm}[{b}]', rng.randint(0, 1))

    state_pins = []  # (inst, pin, net)
    unknown = set()

    def is_seq_name(c):
        # note: CGEN/CGENI are ARM *carry generator* cells (combinational),
        # not clock gates -- they must go through normal lib evaluation
        return (c.startswith('DFF') or c.startswith('SDF')
                or c.startswith('PREICG') or c.startswith('SNPS_CLOCK_GATE')
                or c.startswith('LAT'))

    # collect state outputs -> assign q_value
    for cell, iname, pins in insts:
        base = cell.split('_X')[0] if '_X' in cell else cell
        if is_seq_name(cell):
            for p, n in pins.items():
                if p.startswith('Q') or p in ('ENCLK', 'ECK'):
                    if q_value == 'random':
                        v = rng.randint(0, 1)
                        if p.startswith('QN'): v = v  # independent bit; fine for LEC use
                    else:
                        v = q_value
                    nets[n] = v
                    state_pins.append((iname, p, n))
        elif cell.startswith('TIELO'):
            for p, n in pins.items(): nets[n] = 0
        elif cell.startswith('TIEHI'):
            for p, n in pins.items(): nets[n] = 1
        elif cell not in lib and not cell.startswith(('ANTENNA', 'DCAP', 'FILL', 'BOUNDARY')):
            unknown.add(cell)

    # iterate netlist to fixed point
    for it in range(200):
        changed = False
        for cell, iname, pins in insts:
            if is_seq_name(cell) or cell.startswith(('TIELO', 'TIEHI', 'ANTENNA',
                                                     'DCAP', 'FILL', 'BOUNDARY')):
                continue
            if cell not in lib:
                continue
            c = lib[cell]
            if c['seq']:
                continue
            pv = {}
            for p, n in pins.items():
                cv = netval_const(n)
                pv[p] = cv if cv is not None else nets.get(n, X)
            outs = eval_cell(c, pv)
            for p, v in outs.items():
                n = pins.get(p)
                if n is None: continue
                if nets.get(n, X) != v or n not in nets:
                    # never overwrite a state/forced net
                    nets[n] = v; changed = True
        if not changed: break

    # collect D pins of acc_low/acc_high/pending regs
    result = {}
    for cell, iname, pins in insts:
        if not is_seq_name(cell) or 'reg' not in iname:
            continue
        names = [s for s in re.findall(r'(\w+?_reg(?:_\d+_?)?)(?:__|$)', iname)]
        # robust label: parse bit indices out of the instance name
        bits = re.findall(r'([A-Za-z_]+)_reg_?(\d+)?', iname)
        dpins = [p for p in pins if p == 'D' or re.fullmatch(r'D\d', p)]
        for i, dp in enumerate(sorted(dpins)):
            if bits:
                nm, idx = bits[min(i, len(bits)-1)]
                nm = nm.lstrip('_')
                label = f"{nm}[{idx}]" if idx else nm
            else:
                label = f"{iname}.{dp}"
            n = pins[dp]
            cv = netval_const(n)
            result[label] = cv if cv is not None else nets.get(n, X)
    return result, unknown

# ---------------------------------------------------------------- main
def main():
    base = '/afs/eecs.umich.edu/kits/ARM/TSMC_22ULL/arm_2020q4'
    libs = [f'{base}/sc7mcpp140z_base_svt_c30/r3p0/verilog/sc7mcpp140z_cln22ul_base_svt_c30.v',
            f'{base}/sc7mcpp140z_hpk_svt_c30/r3p0/verilog/sc7mcpp140z_cln22ul_hpk_svt_c30.v']
    lib = parse_lib_cells(libs)
    sys.stderr.write(f"lib cells parsed: {len(lib)}\n")

    root = ('/home/barrylyu/repos/PaYN/apr/build/TSMC22/'
            'PAYN_SC_SIGNED_SEGMENTED_CLEAN')
    shapes = sys.argv[1:] or ['k1m1n1', 'k1m1n2', 'k1m1n4', 'k1m1n6', 'k1m1n8',
                              'k1m2n1', 'k1m4n1', 'k4m1n1',
                              'k2m1n1', 'k8m1n1', 'k1m8n1', 'k1m16n1', 'k16m1n1']
    observed = {s: 'FAIL' for s in ['k1m1n1','k1m1n2','k1m1n4','k1m1n6','k1m1n8',
                                    'k1m2n1','k1m4n1','k4m1n1']}
    observed.update({s: 'PASS' for s in ['k2m1n1','k8m1n1','k1m8n1','k1m16n1','k16m1n1']})

    print(f"{'shape':10s} {'tiles':>5s}  {'acc_low D X-bits (any tile)':32s} "
          f"{'predict':8s} {'observed':8s} {'LEC-reset':9s}")
    for shape in shapes:
        path = f'{root}/{shape}_lw9_id125_noguide/outputs/payn_array_signed_segmented_clean.apr.v'
        mods = parse_netlist_modules(path)
        tiles = {n: b for n, b in mods.items()
                 if n.startswith('InnerTileSignedSegmentedClean')}
        xbits, unknown_all, lec_ok = set(), set(), True
        for tname, tbody in tiles.items():
            res, unknown = eval_tile(tbody, lib, q_value=X)
            unknown_all |= unknown
            for label, v in res.items():
                if v == X:
                    xbits.add(label)
            # reset-LEC: random binary registers AND operands; reset must force D=0
            for trial in range(20):
                res2, _ = eval_tile(tbody, lib, q_value='random', seed=trial)
                for label, v in res2.items():
                    if v != 0:
                        lec_ok = False
                        sys.stderr.write(f"[LEC] {shape}/{tname} trial{trial} "
                                         f"{label} = {v}\n")
        pred = 'FAIL' if xbits else 'PASS'
        mark = 'MATCH' if pred == observed.get(shape, '?') else '*** MISMATCH ***'
        xs = ','.join(sorted(xbits, key=lambda s: (s.split('[')[0],
                     int(re.search(r'\[(\d+)\]', s).group(1)) if '[' in s else -1)))
        print(f"{shape:10s} {len(tiles):5d}  {xs:32s} {pred:8s} "
              f"{observed.get(shape,'?'):8s} {'ok' if lec_ok else 'FAILED':9s} {mark}")
        if unknown_all:
            sys.stderr.write(f"[warn] {shape}: unknown cells {sorted(unknown_all)}\n")

if __name__ == '__main__':
    main()
