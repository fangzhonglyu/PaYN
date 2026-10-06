# Generates doc/payn_datapath.html (inline-SVG architecture page).
# Usage: python3 doc/gen_payn_datapath.py
import pathlib
OUT = pathlib.Path(__file__).resolve().parent / "payn_datapath.html"

def markers(p):
    out = ["<defs>"]
    for name, cls in (("fg", "mk-fg"), ("rand", "mk-rand"), ("bin", "mk-bin"), ("int", "mk-int"), ("mut", "mk-mut")):
        out.append(f'<marker id="{p}-{name}" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" class="{cls}"/></marker>')
    out.append(f'<pattern id="{p}-hatch" width="6" height="6" patternUnits="userSpaceOnUse" patternTransform="rotate(45)"><line x1="0" y1="0" x2="0" y2="6" class="hatch"/></pattern>')
    out.append("</defs>")
    return "".join(out)

def R(x, y, w, h, cls="box", rx=4): return f'<rect class="{cls}" x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}"/>'
def T(x, y, s, cls="", anchor="start", extra=""):
    c = f' class="{cls}"' if cls else ""
    return f'<text x="{x}" y="{y}" text-anchor="{anchor}"{c}{extra}>{s}</text>'
def L(pts, cls, mk=None, p=None):
    d = " ".join(f"{x},{y}" for x, y in pts)
    m = f' marker-end="url(#{p}-{mk})"' if mk else ""
    return f'<polyline class="w {cls}" points="{d}"{m}/>'

# ---------------------------------------------------------------- Fig 1: grid
def fig_grid():
    p = "g"; s = [markers(p)]
    s.append(R(40, 22, 130, 50, "box-rand"))
    s.append(T(105, 43, "Sobol RNG pair", "tb", "middle")); s.append(T(105, 60, "16 values / cycle, shared", "ts", "middle"))
    cols = [210 + 128 * c for c in range(4)]; rows = [118 + 82 * r for r in range(4)]
    for c, x in enumerate(cols):
        s.append(R(x, 22, 96, 50)); s.append(T(x + 48, 43, f"W edge {c}", "tb", "middle")); s.append(T(x + 48, 59, "compare | raw", "ts", "middle"))
        s.append(L([(x + 38, 2), (x + 38, 21)], "w-bin", "bin", p)); s.append(L([(x + 58, 2), (x + 58, 21)], "w-int", "int", p))
        prev = 170 if c == 0 else cols[c - 1] + 96
        s.append(L([(prev, 47), (x - 1, 47)], "w-rand", "rand", p))
    for r, y in enumerate(rows):
        s.append(R(60, y, 110, 60)); s.append(T(115, y + 26, f"A edge {r}", "tb", "middle")); s.append(T(115, y + 42, "compare | raw", "ts", "middle"))
        s.append(L([(4, y + 20), (59, y + 20)], "w-bin", "bin", p)); s.append(L([(4, y + 40), (59, y + 40)], "w-int", "int", p))
        top = 72 if r == 0 else rows[r - 1] + 60
        s.append(L([(115, top), (115, y - 1)], "w-rand", "rand", p))
        for c, x in enumerate(cols):
            s.append(R(x, y, 96, 60))
            s.append(T(x + 10, y + 22, f"PE {r},{c}", "tm"))
            cx, cy = x + 70, y + 38
            s.append(f'<path class="w w-int" d="M{cx+9},{cy} A9,9 0 1 1 {cx},{cy-9}" marker-end="url(#{p}-int)"/>')
            src = 170 if c == 0 else cols[c - 1] + 96
            s.append(L([(src, y + 16), (x - 1, y + 16)], "w-sto", "fg", p))
            if c > 0: s.append(L([(cols[c - 1] + 96, y + 46), (x - 1, y + 46)], "w-bin", "bin", p))
            vsrc = 72 if r == 0 else rows[r - 1] + 60
            s.append(L([(x + 26, vsrc), (x + 26, y - 1)], "w-sto", "fg", p))
        s.append(L([(cols[-1] + 96, y + 46), (729, y + 46)], "w-bin", "bin", p))
        s.append(R(730, y, 100, 60, "box-new")); s.append(T(780, y + 26, "combiner", "tb", "middle")); s.append(T(780, y + 42, "Σ 2^h · row h", "ts", "middle"))
        s.append(L([(830, y + 30), (871, y + 30)], "w-int", "int", p))
    s.append(T(780, 108, "INT only", "ts tint", "middle"))
    s.append(T(852, 140, "int_out", "ts", "middle"))
    s.append(T(60, 452, "Operands reach PE (r,c) r + c cycles after the edge (systolic skew). Drain and a bits move east, w bits move south.", "ts"))
    s.append(T(60, 468, "↺ marks each PE's own ring: between INT passes it doubles that PE's tile rows; it never crosses a PE boundary.", "ts"))
    return ('<svg viewBox="0 0 880 476" role="img" aria-label="P by P grid of PEs. A operands enter from west edge peripherals, W operands from north edge '
            'peripherals, both fed by one shared Sobol RNG pair; results drain east into INT-only combiners; each PE has its own doubling ring.">' + "".join(s) + "</svg>")

# ---------------------------------------------------------------- Fig 2: edge lane
def fig_edge():
    p = "e"; s = [markers(p)]
    s.append(R(24, 10, 500, 240, "region", 8)); s.append(T(36, 28, "edge peripheral (per edge half)", "ts"))
    s.append(R(544, 10, 320, 240, "region", 8)); s.append(T(556, 28, "PE", "ts"))
    # sign row
    s.append(T(34, 42, "sign", "ts")); s.append(L([(30, 48), (249, 48)], "w-bin", "bin", p))
    s.append(R(250, 36, 90, 24, "box-bin")); s.append(T(295, 52, "sign reg", "ts", "middle"))
    s.append(L([(340, 48), (569, 48)], "w-bin", "bin", p)); s.append(R(570, 36, 70, 24)); s.append(T(605, 52, "sign pipe", "ts", "middle"))
    s.append(L([(640, 48), (699, 48)], "w-bin", "bin", p)); s.append(T(706, 52, "sign[k] → tiles", "ts"))
    # magnitude
    s.append(T(34, 88, "binary", "ts")); s.append(L([(30, 94), (89, 94)], "w-bin", "bin", p))
    s.append(R(90, 74, 110, 40, "box-bin")); s.append(T(145, 92, "magnitude reg", "tb", "middle")); s.append(T(145, 106, "8 b, held", "ts", "middle"))
    # random + scramble
    s.append(T(34, 164, "Sobol r_m", "ts")); s.append(L([(30, 170), (89, 170)], "w-rand", "rand", p))
    s.append(R(90, 150, 110, 40, "box-rand")); s.append(T(145, 168, "⊕ mask(k,m)", "tb", "middle")); s.append(T(145, 182, "scramble", "ts", "middle"))
    # comparator
    s.append('<polygon class="box" points="250,96 250,176 326,136"/>'); s.append(T(262, 140, "a &gt; r", "ts"))
    s.append(L([(200, 94), (234, 94), (234, 112), (249, 112)], "w-bin", "bin", p))
    s.append(L([(200, 170), (234, 170), (234, 160), (249, 160)], "w-rand", "rand", p))
    s.append(L([(326, 136), (366, 136), (366, 126), (397, 126)], "w-sto", "fg", p)); s.append(T(332, 154, "SC: stream bit", "ts")); s.append(T(332, 167, "INT: always 0 (mag = 0)", "ts tint"))
    # raw AND
    s.append(T(34, 198, "raw plane bit · new port, from the edge buffer", "ts tint")); s.append(L([(30, 204), (299, 204)], "w-int", "int", p))
    s.append(T(34, 238, "int_mode_q (0 in SC blocks the raw bit)", "ts")); s.append(L([(30, 222), (299, 222)], "w-ctl", "int", p))
    s.append('<path class="box-new" d="M300,196 H318 A15,15 0 0 1 318,226 H300 Z"/>'); s.append(T(306, 216, "&amp;", "ts"))
    s.append(L([(333, 211), (382, 211), (382, 146), (397, 146)], "w-int", "int", p))
    # OR
    s.append('<path class="box-new" d="M398,114 Q414,136 398,158 Q436,158 456,136 Q436,114 398,114 Z"/>'); s.append(T(414, 140, "OR", "ts")); s.append(T(398, 176, "one input is always 0,", "ts")); s.append(T(398, 189, "so it acts as a mux", "ts"))
    s.append(L([(456, 136), (569, 136)], "w-sto", "fg", p))
    s.append(R(570, 118, 70, 36)); s.append(T(605, 140, "bit pipe", "ts", "middle"))
    s.append(L([(640, 136), (846, 136)], "w-sto"))
    for i, x in enumerate((664, 714, 764)):
        s.append(L([(x + 16, 136), (x + 16, 171)], "w-sto", "fg", p)); s.append(R(x, 172, 32, 26)); s.append(T(x + 16, 189, f"T{i}", "ts", "middle"))
    s.append(T(806, 190, "… T7", "ts"))
    s.append(T(560, 230, "×16 positions per lane · ×8 lanes per row", "ts"))
    return ('<svg viewBox="0 0 880 260" role="img" aria-label="One operand position at the edge: a held magnitude is compared with a scrambled Sobol value to make a '
            'stochastic bit; in INT mode the magnitude is zero and the raw bit-plane bit passes through an OR gate gated by int_mode; the result is registered '
            'in the PE bit pipe and broadcast to the 8 tiles of the row.">' + "".join(s) + "</svg>")


# ---------------------------------------------------------------- Fig 3: one cycle in one PE
def fig_layout():
    p = "l"; s = [markers(p)]
    s.append(f'<defs><pattern id="{p}-and" x="0" y="0" width="2.5" height="2.5" patternUnits="userSpaceOnUse">'
             f'<rect width="1.5" height="1.5" class="anddot"/></pattern></defs>')
    # ---------------- panel 1: the bit-matrix product
    s.append(R(12, 8, 876, 256, "region", 8))
    s.append(T(24, 28, "1 · Each cycle the PE multiplies two bit matrices and adds the product into its 64 accumulators", "tb"))
    ax, ay = 70, 86
    for k in range(8):
        x = ax + 36 * k
        for h in range(8):
            s.append(R(x, ay + 12 * h, 32, 12, "mat", 0))
        s.append(T(x + 16, ay + 110, f"k={k}", "ts", "middle"))
    for h in range(8):
        s.append(T(ax - 6, ay + 12 * h + 9, f"h={h}", "ts", "end"))
    s.append(R(ax - 1, ay + 24, 36 * 7 + 34, 12, "outl", 0))
    s.append(R(ax + 36 * 3 + 14, ay, 2, 96, "hl", 0))
    s.append(T(ax, 54, "A-bits (8 × 128)", "tb"))
    s.append(T(ax, 68, "row h = bit h of the 128 activations A[i, x]", "ts"))
    s.append(T(ax, ay + 128, "columns = the 128 elements x of this cycle,", "ts"))
    s.append(T(ax, ay + 142, "x = 128b + 16k + m: lane k (group) × position m (16)", "ts"))
    s.append(T(366, ay + 55, "×", "big", "middle"))
    wx, wy = 392, 46
    for k in range(8):
        y = wy + 20 * k
        for v in range(8):
            s.append(R(wx + 10 * v, y, 10, 18, "mat", 0))
        s.append(T(wx + 86, y + 13, f"k={k}", "ts"))
    for v in range(8):
        s.append(T(wx + 10 * v + 5, wy - 4, str(v), "ts", "middle"))
    s.append(T(wx - 4, wy - 4, "v", "ts", "end"))
    s.append(R(wx + 70, wy - 1, 10, 160, "outl", 0))
    s.append(R(wx - 1, wy + 60 + 7, 82, 2, "hl", 0))
    s.append(T(wx, 222, "W-bits (128 × 8)", "tb"))
    s.append(T(wx, 236, "column v = bit q of the weights", "ts"))
    s.append(T(wx, 250, "W[x, j_v] of output column j_v", "ts"))
    s.append(T(522, ay + 55, "+=", "big", "middle"))
    cx = 546
    for h in range(8):
        for v in range(8):
            s.append(R(cx + 12 * v, ay + 12 * h, 12, 12, "tile-hi" if (h, v) == (2, 7) else "mat2", 0))
    s.append(T(cx, ay + 114, "64 accumulators", "tb"))
    s.append(T(cx, ay + 128, "(h, v) is in tile (h, v)", "ts"))
    ex = 662
    lines = [("Accumulator (2, 7) adds row 2 of A-bits", "ts"), ("dotted with column 7 of W-bits: the", "ts"),
             ("number of x where both bits are 1.", "ts"), None,
             ("INT8, weight pass q, cycle b", "ts tb tint"), ("inner dimension = 128 different elements", "ts"),
             ("A-bits: one activation row i, 8 bit rows", "ts"), ("W-bits: 8 output columns j_0 … j_7", "ts"), None,
             ("SC mode, same wires and shapes", "ts tb"), ("inner dimension = 8 elements × 16 samples", "ts"),
             ("A rows = 8 activation rows", "ts"), None, ("teal: element x = 128b + 55 (k = 3, m = 7)", "ts tint")]
    y = 52
    for ln in lines:
        if ln is None: y += 8; continue
        s.append(T(ex, y, ln[0], ln[1])); y += 14
    # ---------------- panel 2: where the matrices sit
    s.append(R(12, 280, 876, 438, "region", 8))
    s.append(T(24, 300, "2 · Where they sit: row h of A-bits is row bus h, column v of W-bits is column bus v, tile (h, v) is at the crossing", "tb"))
    gx, gy, pxx, pyy, tw, th = 150, 370, 60, 37.5, 50, 30
    s.append(T(24, 322, "column bus v = 128 wires = column v of W-bits (output column j_v), broadcast down to the 8 tiles of column v; 8 different buses", "ts"))
    yb = gy + pyy * 7 + th
    for v in range(8):
        xc = gx + pxx * v + tw / 2
        s.append(T(xc, 340, f"v={v}", "ts", "middle"))
        s.append(R(xc - 20, 345, 40, 16)); s.append(T(xc, 357, "128 b", "ts", "middle"))
        s.append(L([(xc, 361), (xc, yb + 6)], "w-sto", "fg", p))
    for h in range(8):
        y = gy + pyy * h
        s.append(T(44, y + 18, f"h={h}", "ts", "end"))
        s.append(R(52, y + 6, 40, 16)); s.append(T(72, y + 18, "128 b", "ts", "middle"))
        s.append(L([(92, y + 12), (633, y + 12)], "w-sto", "fg", p))
        for v in range(7):
            s.append(L([(gx + pxx * v + tw, y + 24), (gx + pxx * (v + 1) - 1, y + 24)], "w-bin", "bin", p))
        s.append(L([(gx + pxx * 7 + tw, y + 24), (633, y + 24)], "w-bin", "bin", p))
    for h in range(8):
        for v in range(8):
            x, y = gx + pxx * v, gy + pyy * h
            s.append(R(x, y, tw, th, "tile-hi" if (h, v) == (2, 7) else "box", 3))
            s.append(f'<rect x="{x + 5}" y="{y + 5}" width="40" height="20" fill="url(#{p}-and)"/>')
            s.append(R(x + 5 + 7 * 2.5 - 0.5, y + 5 + 3 * 2.5 - 0.5, 2.5, 2.5, "hl", 0))
    s.append(T(24, yb + 26, "row bus h = 128 wires = row h of A-bits, broadcast across the 8 tiles of row h. Buses come from the edge or the", "ts"))
    s.append(T(24, yb + 40, "neighbouring PE and leave east / south to the next PE. Dots: one AND per element, 16 positions × 8 lanes per tile.", "ts"))
    s.append(T(24, yb + 54, "Orange: the 24-bit accumulators chain east; they move only for the drain and the ring lap (Fig. 5).", "ts"))
    # zoom of tile (2, 5)
    zx, zy = gx + pxx * 7 + tw, gy + pyy * 2
    s.append(f'<line class="region" x1="{zx}" y1="{zy}" x2="644" y2="330"/>')
    s.append(f'<line class="region" x1="{zx}" y1="{zy + th}" x2="644" y2="700"/>')
    s.append(R(644, 316, 240, 396, "region", 8))
    zl = 656
    s.append(T(zl, 336, "tile (2, 7) up close", "tb"))
    s.append(T(zl, 352, "AND (k, m) takes wire (k, m) of row bus 2", "ts"))
    s.append(T(zl, 366, "and wire (k, m) of column bus 7. Both", "ts"))
    s.append(T(zl, 380, "carry element x = 128b + 16k + m.", "ts"))
    gx0, gy0 = 686, 404
    s.append(T(gx0, 399, "m=0", "ts")); s.append(T(gx0 + 15 * 12 + 10, 399, "15", "ts", "end"))
    for k in range(8):
        s.append(T(gx0 - 5, gy0 + 12 * k + 9, f"k={k}", "ts", "end"))
        for m in range(16):
            s.append(R(gx0 + 12 * m, gy0 + 12 * k, 10, 10, "bitcell-on" if (k, m) == (3, 7) else "bitcell", 1.5))
    zt = [("AND (3, 7) is element x = 128b + 55:", "ts tb"), ("bit 2 of A[i, x] AND bit q of W[x, j_7]", "ts"), None,
          ("Each lane counts its 16 ANDs and the tile", "ts"), ("adds the 8 lane counts (128 products) to", "ts"),
          ("its 24-bit accumulator, which stays in", "ts"), ("the tile until the drain.", "ts"), None,
          ("The same 128 A bits also reach the other", "ts"), ("7 tiles of row 2 (other output columns);", "ts"),
          ("the same 128 W bits reach the other 7", "ts"), ("tiles of column 7 (other activation bits).", "ts")]
    y = 518
    for ln in zt:
        if ln is None: y += 8; continue
        s.append(T(zl, y, ln[0], ln[1])); y += 14
    return ('<svg viewBox="0 0 900 726" role="img" aria-label="Panel 1: each cycle the PE multiplies an 8 by 128 bit matrix (bit h of 128 activations) by a 128 by 8 '
            'bit matrix (bit q of the matching weights of 8 output columns) and adds the 8 by 8 result into 64 accumulators. Panel 2: row h of the first matrix is '
            'row bus h, column v of the second is column bus v, each 128 wires, broadcast along the row or column; tile (h, v) sits at the crossing and has one AND '
            'per element, 16 positions by 8 lanes; the zoom shows that AND (k, m) pairs the two wires that carry the same element.">' + "".join(s) + "</svg>")

# ---------------------------------------------------------------- Fig 4: a whole block
def fig_exec():
    p = "x"; s = [markers(p)]
    s.append(T(16, 22, "One block computes Y[i, j_0 … j_7]: INT8, L = 4,096, so each pass is 32 cycles of 128 elements", "tb"))
    x0, x1 = 150, 878
    sc = (x1 - x0) / 320
    X = lambda c: x0 + c * sc
    segs = []
    for q in range(7, -1, -1):
        c = 40 * (7 - q)
        segs.append(("pass", q, c, c + 32))
        if q: segs.append(("lap", q, c + 32, c + 40))
    segs.append(("drain", None, 312, 320))
    rows = [(42, "time", ""), (76, "row buses", "(A-bits)"), (108, "column buses", "(W-bits)"), (140, "accumulators", "")]
    for y, a, b in rows:
        s.append(T(16, y + 13 if not b else y + 9, a, "ts tb"))
        if b: s.append(T(16, y + 21, b, "ts"))
    for c in [0, 40, 80, 120, 160, 200, 240, 280, 312]:
        s.append(T(X(c), 38, str(c), "ts", "middle" if c else "start"))
    for kind, q, c0, c1 in segs:
        xa, w = X(c0), X(c1) - X(c0)
        mid = xa + w / 2
        if kind == "pass":
            s.append(R(xa, 42, w, 20, "blk-pass", 0)); s.append(T(mid, 56, f"pass {q}", "ts", "middle"))
            s.append(R(xa, 76, w, 22, "mat", 0)); s.append(T(mid, 91, "chunks 0–31", "ts", "middle"))
            s.append(R(xa, 108, w, 22, "mat", 0)); s.append(T(mid, 123, f"bit {q} · 0–31", "ts", "middle"))
            s.append(R(xa, 140, w, 22, "blk-pass", 0)); s.append(T(mid, 155, "stay, add", "ts", "middle"))
        elif kind == "lap":
            s.append(R(xa, 42, w, 20, "blk-lap", 0))
            for y in (76, 108): s.append(f'<rect class="blk-idle" x="{xa}" y="{y}" width="{w}" height="22" fill="url(#{p}-hatch)"/>')
            s.append(R(xa, 140, w, 22, "blk-lap", 0)); s.append(T(mid, 155, "×2", "ts lapt", "middle"))
        else:
            s.append(R(xa, 42, w, 20, "blk-drain", 0))
            for y in (76, 108): s.append(f'<rect class="blk-idle" x="{xa}" y="{y}" width="{w}" height="22" fill="url(#{p}-hatch)"/>')
            s.append(R(xa, 140, w, 22, "blk-drain", 0))
    s.append(T(x1, 178, "lap = 8 cycles, no MAC, buses idle (hatched) · drain = last 8 cycles, results move east", "ts", "end"))
    # ---- what every accumulator holds before the drain
    s.append(f'<line class="region" x1="16" y1="194" x2="884" y2="194"/>')
    s.append(T(16, 216, "After pass 0, before the drain:", "tb"))
    txt = [("accumulator (h, v) holds", "ts"), ("T(h, v) = the sum of output column j_v's", "ts"),
           ("weights W[x, j_v] over every element x", "ts"), ("whose activation A[i, x] has bit h = 1.", "ts"),
           ("Row 7 (the sign bit) holds minus that sum.", "ts"), None,
           ("Each is a 24-bit integer. The 8 passes put", "ts"), ("each weight in one bit at a time; the laps", "ts"),
           ("give each bit its 2^q.", "ts"), None,
           ("Column j_5 shows the worked example below:", "ts tint"), ("A = 3, −2, 1 and W = 2, 5, −3, so the", "ts tint"),
           ("combiner gives −7 = 3·2 − 2·5 − 1·3.", "ts tint")]
    y = 234
    for ln in txt:
        if ln is None: y += 8; continue
        s.append(T(16, y, ln[0], ln[1])); y += 14
    gx, gy, cw, ch, pxx, pyy = 300, 236, 48, 24, 52, 28
    ex = [-1, 7, 5, 5, 5, 5, 5, -5]
    for v in range(8): s.append(T(gx + pxx * v + cw / 2, gy - 6, f"j_{v}", "ts", "middle"))
    for h in range(8):
        y = gy + pyy * h
        s.append(T(gx - 6, y + 16, f"h={h}", "ts", "end"))
        for v in range(8):
            x = gx + pxx * v
            if v == 5:
                s.append(R(x, y, cw, ch, "tile-hi", 3)); s.append(T(x + cw / 2, y + 16, f"{ex[h]:+d}".replace("-", "−"), "tm", "middle"))
            else:
                s.append(R(x, y, cw, ch, "box", 3)); s.append(T(x + cw / 2, y + 16, f"T({h},{v})", "ts", "middle"))
            if v < 7: s.append(L([(x + cw, y + ch / 2), (x + pxx - 1, y + ch / 2)], "w-bin"))
        s.append(L([(gx + pxx * 7 + cw, y + ch / 2), (735, y + ch / 2)], "w-bin", "bin", p))
    s.append(R(736, gy, 148, pyy * 7 + ch, "box-new"))
    ct = [("combiner", "tb"), ("one column per drain", "ts"), ("cycle, j_7 first:", "ts"), None,
          ("Y[i, j_v] =", "tm"), ("Σ_h 2^h · T(h, v)", "tm"), None, ("8 outputs in 8 cycles", "ts"), None,
          ("example column j_5:", "ts tint"), ("−1 + 2·7 + 124·5", "tm tint"), ("− 128·5 = −7", "tm tint")]
    y = gy + 18
    for ln in ct:
        if ln is None: y += 8; continue
        s.append(T(746, y, ln[0], ln[1])); y += 14
    return ('<svg viewBox="0 0 900 474" role="img" aria-label="Timeline of one INT8 block: eight 32-cycle passes, each sending the same 32 chunks of activation bits and one '
            'bit plane of the weights while the accumulators stay in place and add, separated by 8-cycle laps that double them, then an 8-cycle drain. Below: '
            'before the drain, accumulator (h, v) holds the sum of output column j_v weights over the elements whose activation has bit h set, negated for row 7; '
            'the combiner forms each output as the sum of 2 to the h times the column.">' + "".join(s) + "</svg>")

# ---------------------------------------------------------------- Fig 5: PE row + ring
def fig_pe():
    p = "p"; s = [markers(p)]
    s.append(R(14, 10, 872, 270, "region", 8)); s.append(T(26, 28, "inside one PE: tile row h (one of 8)", "ts"))
    s.append(L([(16, 56), (39, 56)], "w-sto", "fg", p))
    s.append(R(40, 40, 60, 32)); s.append(T(70, 60, "a pipe h", "ts", "middle"))
    s.append(L([(100, 56), (866, 56)], "w-sto")); s.append(L([(866, 56), (885, 56)], "w-sto", "fg", p)); s.append(T(884, 48, "to east PE", "ts", "end"))
    s.append(T(470, 48, "a_bits[h] broadcast to all 8 tiles", "ts", "middle"))
    tiles = [150 + 86 * v for v in range(8)]
    for v, x in enumerate(tiles):
        s.append(L([(x + 16, 56), (x + 16, 99)], "w-sto", "fg", p))
        s.append(L([(x + 48, 76), (x + 48, 99)], "w-sto", "fg", p))
        s.append(R(x, 100, 66, 56)); s.append(T(x + 33, 133, f"T(h,{v})", "tm", "middle"))
        if v < 7: s.append(L([(x + 66, 143), (tiles[v + 1] - 1, 143)], "w-bin", "bin", p))
    s.append(T(x + 52, 84, "w_bits[v]", "ts"))
    # mux, inputs
    s.append('<polygon class="box" points="100,118 130,128 130,158 100,168"/>')
    s.append(L([(130, 143), (149, 143)], "w-bin", "bin", p))
    s.append(T(22, 122, "acc_in_west", "ts")); s.append(L([(16, 128), (99, 128)], "w-bin", "bin", p))
    s.append(T(22, 78, "ring_in", "ts")); s.append(L([(16, 84), (93, 84)], "w-ctl", "int", p))
    s.append(R(94, 72, 54, 24, "box-new")); s.append(T(121, 88, "ring_q", "ts", "middle"))
    s.append(L([(121, 96), (121, 123)], "w-ctl", "int", p))
    # east exit + back edge
    s.append(L([(818, 143), (885, 143)], "w-bin", "bin", p)); s.append(T(884, 136, "acc_out_east", "ts", "end"))
    s.append('<circle cx="848" cy="143" r="3" class="mk-int"/>')
    s.append(L([(848, 143), (848, 262), (70, 262), (70, 158), (99, 158)], "w-int", "int", p))
    s.append(T(460, 256, "back edge: acc_out_east &lt;&lt; 1 (×2), only during a ring lap", "ts tint", "middle"))
    s.append(R(170, 190, 320, 42, "box-new")); s.append(T(330, 207, "tile shift = shift_in OR ring_q", "tm", "middle"))
    s.append(T(330, 223, "per-PE lap enable: each PE laps on its own skewed schedule", "ts", "middle"))
    s.append(T(520, 207, "ring lap = 8 shifts: every tile ends", "ts")); s.append(T(520, 222, "with its own value doubled", "ts"))
    return ('<svg viewBox="0 0 900 290" role="img" aria-label="One row of 8 tiles inside a PE: the a pipe broadcasts to all tiles, column pipes feed w bits, '
            'results shift east through the drain chain; a mux at the west input selects either the west neighbour or the row\'s own east output shifted left '
            'by one, which doubles every tile after 8 shifts; ring_q selects the loop and also enables the tile shift.">' + "".join(s) + "</svg>")

# ---------------------------------------------------------------- Fig 6: tile
def fig_tile():
    p = "t"; s = [markers(p)]
    s.append(R(14, 10, 872, 320, "region", 8)); s.append(T(26, 28, "one tile: K = 8 lanes × M = 16 positions, one output element", "ts"))
    for k, y0 in (("0", 60), ("1", 140), ("K−1", 250)):
        s.append(T(26, y0 + 14, f"a_bits[{k}]", "ts")); s.append(L([(26, y0 + 20), (77, y0 + 20)], "w-sto", "fg", p))
        s.append(T(26, y0 + 34, f"w_bits[{k}]", "ts")); s.append(L([(26, y0 + 40), (77, y0 + 40)], "w-sto", "fg", p))
        s.append(f'<path class="box" d="M78,{y0+10} H96 A20,20 0 0 1 96,{y0+50} H78 Z"/>'); s.append(T(88, y0 + 34, "&amp;", "ts", "middle"))
        s.append(L([(116, y0 + 30), (149, y0 + 30)], "w-sto", "fg", p)); s.append(T(132, y0 + 24, "16", "ts", "middle"))
        s.append(R(150, y0 + 8, 96, 44)); s.append(T(198, y0 + 28, "11-FA counter", "tb", "middle")); s.append(T(198, y0 + 42, "weights 1,1,2,4,8", "ts", "middle"))
        s.append(L([(246, y0 + 30), (281, y0 + 30)], "w-sto", "fg", p))
        s.append(f'<circle class="box" cx="296" cy="{y0+30}" r="14"/><path class="w w-sto" d="M284,{y0+30} H308 M296,{y0+18} V{y0+42}"/>')
        s.append(L([(296, y0 + 60), (296, y0 + 45)], "w-bin", "bin", p)); s.append(T(306, y0 + 62, "sign[k]", "ts"))
        s.append(L([(310, y0 + 30), (399, y0 + 30)], "w-sto", "fg", p)); s.append(T(354, y0 + 24, "5 bits", "ts", "middle"))
    s.append(T(198, 226, "⋮", "tb", "middle"))
    s.append(R(400, 40, 72, 278)); s.append(T(436, 179, "carry-save heap (DW02 tree)", "tb", "middle", ' transform="rotate(-90 436 179)"'))
    s.append(T(326, 44, "−16·N (N = negative lanes)", "ts", "end")); s.append(L([(330, 50), (399, 50)], "w-bin", "bin", p))
    s.append(L([(472, 150), (509, 150)], "w-bin", "bin", p)); s.append(L([(472, 166), (509, 166)], "w-bin", "bin", p)); s.append(T(490, 140, "2 rows", "ts", "middle"))
    s.append(R(510, 136, 50, 44)); s.append(T(535, 158, "+", "tb", "middle")); s.append(T(535, 172, "11 b", "ts", "middle"))
    s.append(L([(560, 150), (590, 150), (590, 128), (619, 128)], "w-bin", "bin", p)); s.append(T(566, 122, "low 9 b", "ts"))
    s.append(L([(560, 168), (590, 168), (590, 186), (619, 186)], "w-bin", "bin", p)); s.append(T(562, 214, "carry / borrow", "ts"))
    s.append(R(620, 110, 70, 36, "box-bin")); s.append(T(655, 126, "acc_low", "tb", "middle")); s.append(T(655, 140, "9 b", "ts", "middle"))
    s.append(R(620, 170, 70, 32)); s.append(T(655, 190, "pending", "ts", "middle"))
    s.append(L([(690, 186), (739, 196)], "w-bin", "bin", p)); s.append(T(714, 176, "±1", "ts", "middle"))
    s.append(R(740, 180, 80, 36, "box-bin")); s.append(T(780, 196, "acc_high", "tb", "middle")); s.append(T(780, 210, "15 b", "ts", "middle"))
    s.append(L([(690, 118), (839, 118)], "w-bin", "bin", p)); s.append(L([(820, 198), (839, 198)], "w-bin", "bin", p))
    s.append(R(840, 104, 40, 120)); s.append(T(860, 164, "acc_out", "tb", "middle", ' transform="rotate(-90 860 164)"'))
    s.append(L([(690, 132), (712, 132), (712, 324), (436, 324), (436, 319)], "w-bin", "bin", p)); s.append(T(574, 320, "acc_low feeds back into the heap", "ts", "middle"))
    s.append(T(620, 92, "on shift: acc ← acc_in (west tile, or the ring mux at T(h,0))", "ts"))
    return ('<svg viewBox="0 0 900 340" role="img" aria-label="One tile: each of 8 lanes ANDs 16 a and w bits, an 11-full-adder counter leaves 5 redundant count bits, '
            'they are XORed with the lane sign, and all lanes plus a minus 16 times N correction and the low accumulator enter one carry-save heap; an 11-bit adder '
            'updates the 9-bit low accumulator, carries become pending plus or minus one on the 15-bit high part.">' + "".join(s) + "</svg>")

# ---------------------------------------------------------------- Fig 7: schedule
def fig_sched():
    p = "s"; s = [markers(p)]
    def blk(x0, x1, y, cls, label=None):
        s.append(f'<rect class="{cls}" x="{x0}" y="{y}" width="{x1-x0}" height="22"/>')
        if label: s.append(T((x0 + x1) / 2, y + 15, label, "ts", "middle"))
    def idle(x0, x1, y): s.append(f'<rect class="blk-idle" x="{x0}" y="{y}" width="{x1-x0}" height="22" fill="url(#{p}-hatch)"/>')
    s.append(T(16, 50, "SC, T = 128", "tb")); s.append(T(16, 64, "8-cycle blocks", "ts"))
    for i in range(30): blk(180 + 16 * i, 196 + 16 * i, 38, "blk-sc")
    blk(660, 676, 38, "blk-drain"); s.append(T(684, 54, "drain (one PE: 8 cycles)", "ts"))
    s.append(T(16, 100, "INT8, one PE", "tb")); s.append(T(16, 114, "L = 4096", "ts"))
    blk(180, 250, 88, "blk-pass", "pass 7"); blk(250, 266, 88, "blk-lap"); blk(266, 336, 88, "blk-pass", "pass 6"); blk(336, 352, 88, "blk-lap")
    s.append(T(376, 104, "…", "tb", "middle")); blk(400, 470, 88, "blk-pass", "pass 0"); blk(470, 486, 88, "blk-drain")
    s.append(T(258, 82, "lap", "ts", "middle")); s.append(T(494, 104, "32 data cycles per pass, 8 per lap", "ts"))
    s.append(T(16, 140, "4×4 grid, first route (03b): laps on the global shift_in", "tb"))
    s.append(T(16, 166, "PE 0,0", "tm")); s.append(T(16, 196, "PE 3,3", "tm"))
    y0, y1 = 150, 180
    blk(180, 250, y0, "blk-pass", "pass 7"); idle(250, 262, y0); blk(262, 278, y0, "blk-lap"); blk(278, 348, y0, "blk-pass", "pass 6"); idle(348, 360, y0); blk(360, 376, y0, "blk-lap")
    s.append(T(398, y0 + 16, "…", "tb", "middle")); blk(420, 490, y0, "blk-pass", "pass 0"); idle(490, 502, y0); blk(502, 566, y0, "blk-drain", "drain")
    blk(192, 262, y1, "blk-pass", "pass 7"); blk(262, 278, y1, "blk-lap"); blk(290, 360, y1, "blk-pass", "pass 6"); blk(360, 376, y1, "blk-lap")
    s.append(T(410, y1 + 16, "…", "tb", "middle")); blk(432, 502, y1, "blk-pass", "pass 0"); blk(502, 566, y1, "blk-drain", "drain")
    s.append(T(586, 172, "every pass waits 6 cycles for the far PE", "ts")); s.append(T(586, 188, "INT8, L = 4096: 392 cycles/block, 65% busy", "ts"))
    s.append(T(16, 232, "4×4 grid, per-PE lap enable (as built)", "tb"))
    s.append(T(16, 258, "PE 0,0", "tm")); s.append(T(16, 288, "PE 3,3", "tm"))
    y0, y1 = 242, 272
    blk(180, 250, y0, "blk-pass", "pass 7"); blk(250, 266, y0, "blk-lap"); blk(266, 336, y0, "blk-pass", "pass 6"); blk(336, 352, y0, "blk-lap")
    s.append(T(374, y0 + 16, "…", "tb", "middle")); blk(396, 466, y0, "blk-pass", "pass 0"); idle(466, 478, y0); blk(478, 542, y0, "blk-drain", "drain")
    blk(192, 262, y1, "blk-pass", "pass 7"); blk(262, 278, y1, "blk-lap"); blk(278, 348, y1, "blk-pass", "pass 6"); blk(348, 364, y1, "blk-lap")
    s.append(T(386, y1 + 16, "…", "tb", "middle")); blk(408, 478, y1, "blk-pass", "pass 0"); blk(478, 542, y1, "blk-drain", "drain")
    s.append(T(562, 264, "each PE laps when its own pass ends", "ts")); s.append(T(562, 280, "350 cycles/block, 73% busy", "ts"))
    # legend
    lx = 180
    for cls, lab in (("blk-sc", "SC block"), ("blk-pass", "INT data pass"), ("blk-lap", "ring lap"), ("blk-idle", "idle"), ("blk-drain", "drain")):
        if cls == "blk-idle": s.append(f'<rect class="blk-idle" x="{lx}" y="306" width="14" height="12" fill="url(#{p}-hatch)"/>')
        else: s.append(f'<rect class="{cls}" x="{lx}" y="306" width="14" height="12"/>')
        s.append(T(lx + 20, 316, lab, "ts")); lx += 120
    return ('<svg viewBox="0 0 900 330" role="img" aria-label="Timelines: SC accumulates 8-cycle blocks then drains; INT8 runs 8 weight-bit passes separated by 8-cycle '
            'ring laps; in a grid with global laps every pass waits for the farthest PE, while per-PE laps let each PE lap on its own skewed schedule.">' + "".join(s) + "</svg>")

CSS = r"""
:root{
  /* Layout: one reading column, figures break out to a wider measure; zoom order grid -> edge -> PE -> tile -> schedule */
  --bg:#f5f7fa; --surface:#ffffff; --fg:#17202b; --muted:#5b6574; --line:#c6ced9;
  --rand:#c0392b; --bin:#c26f12; --int:#0d7f8a;
  --rand-tint:#fbe9e7; --bin-tint:#fcf0e2; --int-tint:#e3f4f5; --sto-tint:#eef1f5;
  --f-display:"Archivo", "Helvetica Neue", Arial, sans-serif;
  --f-body:"Atkinson Hyperlegible", "Segoe UI", Arial, sans-serif;
  --f-mono:"JetBrains Mono", ui-monospace, "SFMono-Regular", Menlo, monospace;
}
@media (prefers-color-scheme: dark){ :root:not([data-theme="light"]){
  --bg:#0f141b; --surface:#161d26; --fg:#e4e9f0; --muted:#9aa5b3; --line:#334050;
  --rand:#ff7a6b; --bin:#f2a24a; --int:#43c3cf;
  --rand-tint:#3a1d1a; --bin-tint:#382a16; --int-tint:#123236; --sto-tint:#1d2531; color-scheme:dark } }
:root[data-theme="dark"]{
  --bg:#0f141b; --surface:#161d26; --fg:#e4e9f0; --muted:#9aa5b3; --line:#334050;
  --rand:#ff7a6b; --bin:#f2a24a; --int:#43c3cf;
  --rand-tint:#3a1d1a; --bin-tint:#382a16; --int-tint:#123236; --sto-tint:#1d2531; color-scheme:dark }
body{background:var(--bg); color:var(--fg); font-family:var(--f-body); font-size:16px; line-height:1.55}
.wrap{max-width:1000px; margin:0 auto; padding-inline:20px; padding-block:40px 64px}
header{display:grid; gap:10px; margin-bottom:28px}
.eyebrow{font-family:var(--f-mono); font-size:12px; letter-spacing:.06em; text-transform:uppercase; color:var(--muted)}
h1{font-family:var(--f-display); font-weight:700; font-size:clamp(30px,5vw,44px); line-height:1.05; margin:0; text-wrap:balance}
h2{font-family:var(--f-display); font-weight:600; font-size:22px; margin:0; text-wrap:balance}
.lede{max-width:68ch; margin:0; color:var(--fg)}
.legend{display:flex; flex-wrap:wrap; gap:10px 22px; padding:12px 14px; border:1px solid var(--line); border-radius:6px; background:var(--surface); font-size:13px; margin-bottom:34px}
.legend span{display:inline-flex; align-items:center; gap:8px}
.sw{width:26px; height:0; border-top:2.5px solid; display:inline-block}
.sw.rand{border-color:var(--rand)} .sw.sto{border-color:var(--fg)} .sw.bin{border-color:var(--bin)} .sw.int{border-color:var(--int)}
.sw.ctl{border-top:2.5px dashed var(--int)} .sw.box{width:16px; height:12px; border:1.5px solid var(--int); background:var(--int-tint)}
section{display:grid; gap:12px; margin-bottom:44px}
section > p{max-width:68ch; margin:0}
.fig{margin:0; background:var(--surface); border:1px solid var(--line); border-radius:8px; padding:14px 14px 10px}
.scroll{overflow-x:auto}
.fig svg{display:block; width:100%; min-width:760px; height:auto; color:var(--fg); font-family:var(--f-body)}
figcaption{font-size:14px; color:var(--muted); max-width:78ch; padding-top:8px}
code,.mono{font-family:var(--f-mono); font-size:.88em}
svg text{fill:currentColor; font-size:12px}
svg .ts{font-size:10.5px; fill:var(--muted)}
svg .tm{font-family:var(--f-mono); font-size:11px}
svg .tb{font-weight:700}
svg .tint{fill:var(--int)}
.region{fill:none; stroke:var(--line); stroke-dasharray:5 4}
.box{fill:var(--surface); stroke:currentColor; stroke-width:1.2}
.box-rand{fill:var(--rand-tint); stroke:var(--rand); stroke-width:1.2}
.box-bin{fill:var(--bin-tint); stroke:var(--bin); stroke-width:1.2}
.box-new{fill:var(--int-tint); stroke:var(--int); stroke-width:1.4}
.w{fill:none; stroke-width:1.6}
.w-sto{stroke:currentColor} .w-rand{stroke:var(--rand)} .w-bin{stroke:var(--bin)} .w-int{stroke:var(--int)}
.w-ctl{stroke:var(--int); stroke-dasharray:4 3}
.mk-fg{fill:currentColor} .mk-rand{fill:var(--rand)} .mk-bin{fill:var(--bin)} .mk-int{fill:var(--int)} .mk-mut{fill:var(--muted)}
.hatch{stroke:var(--muted); stroke-width:1.4}
.bitcell{fill:var(--surface); stroke:var(--line); stroke-width:1}
.bitcell-on{fill:var(--int); stroke:var(--int)}
.bitcell-a{fill:var(--sto-tint); stroke:currentColor; stroke-width:1}
.mat{fill:var(--sto-tint); stroke:var(--line); stroke-width:.8}
.mat2{fill:var(--surface); stroke:var(--line); stroke-width:.8}
.outl{fill:none; stroke:var(--int); stroke-width:1.6}
.hl{fill:var(--int)}
.anddot{fill:var(--muted)}
svg .big{font-size:20px; font-weight:700}
.tile-hi{fill:var(--int-tint); stroke:var(--int); stroke-width:2}
.blk-lap-sm{fill:var(--int); stroke:var(--int)}
svg .lapt{fill:var(--surface)}
.blk-sc{fill:var(--sto-tint); stroke:currentColor; stroke-width:.8}
.blk-pass{fill:var(--int-tint); stroke:var(--int); stroke-width:1}
.blk-lap{fill:var(--int); stroke:var(--int)}
.blk-idle{stroke:var(--muted); stroke-width:.8}
.blk-drain{fill:var(--bin-tint); stroke:var(--bin); stroke-width:1}
table{border-collapse:collapse; width:100%; font-size:14px; background:var(--surface)}
.tablewrap{overflow-x:auto; border:1px solid var(--line); border-radius:8px}
th,td{text-align:left; vertical-align:top; padding:9px 12px; border-bottom:1px solid var(--line)}
th{font-family:var(--f-display); font-weight:600; font-size:13px; letter-spacing:.02em; background:var(--sto-tint)}
td.num{font-family:var(--f-mono); font-variant-numeric:tabular-nums; white-space:nowrap}
tr:last-child td{border-bottom:0}
.new{color:var(--int); font-weight:700}
.facts{display:grid; grid-template-columns:repeat(auto-fit,minmax(220px,1fr)); gap:12px}
.fact{background:var(--surface); border:1px solid var(--line); border-radius:8px; padding:12px 14px; display:grid; gap:4px; min-width:0}
.fact b{font-family:var(--f-mono); font-size:20px; font-variant-numeric:tabular-nums}
.fact span{font-size:13px; color:var(--muted)}
footer{font-size:13px; color:var(--muted); border-top:1px solid var(--line); padding-top:14px}
@media (max-width:520px){ .wrap{padding-inline:16px} }
"""

HTML = f"""<title>PaYN Datapath</title>
<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Archivo:wght@500;600;700&family=Atkinson+Hyperlegible:wght@400;700&family=JetBrains+Mono:wght@400;500&display=swap">
<style>{CSS}</style>
<div class="wrap">
<header>
  <div class="eyebrow">TSMC22 · 400 MHz · K = 8 lanes · M = 16 positions · 8 × 8 tiles per PE</div>
  <h1>PaYN Datapath</h1>
  <p class="lede">One PaYN array runs two modes on the same tiles. In <b>SC mode</b> each AND gate multiplies two stochastic bits and a tile counts them,
  so a length-T stream gives an approximate product in T/16 cycles. In <b>bit-plane INT mode</b> each AND gate multiplies one real bit of an activation by one
  real bit of a weight, so an INT8 MAC is exactly 64 one-bit products. The binary weights 2<sup>i+j</sup> are applied by doubling the accumulators between
  passes and by one shift-add at the east edge, never inside the tile.</p>
</header>

<div class="legend" aria-label="Legend">
  <span><i class="sw rand"></i>random values</span>
  <span><i class="sw sto"></i>stream bits (SC) or bit-plane bits (INT)</span>
  <span><i class="sw bin"></i>binary values, signs, accumulators</span>
  <span><i class="sw int"></i>INT-only data path</span>
  <span><i class="sw ctl"></i>INT control</span>
  <span><i class="sw box"></i>hardware added for INT</span>
</div>

<section>
  <h2>Fig. 1 · The grid</h2>
  <figure class="fig"><div class="scroll">{fig_grid()}</div>
  <figcaption>Operands enter from two edges and are re-exported PE to PE, so each value is fetched once per grid row or column. Edge peripherals exist only on the
  west and north boundary. The east combiners and the per-PE rings are the only grid-level additions for INT; inner PEs receive bit-planes over the same forwarding
  wires SC already uses.</figcaption></figure>
</section>

<section>
  <h2>Fig. 2 · Edge peripheral, one operand position</h2>
  <figure class="fig"><div class="scroll">{fig_edge()}</div>
  <figcaption><b>SC:</b> the 8-bit magnitude is held for T/16 cycles and compared each cycle with a scrambled Sobol value, so <code>bit = (mag &gt; r)</code> is 1 with probability mag/256, and <code>int_mode_q = 0</code> blocks the raw input. <b>INT:</b> the Sobol banks stop and the magnitudes are loaded as 0, so the comparator outputs <code>0 &gt; r = 0</code> and the raw bit passes. In each mode one OR input is forced to 0, so <code>cmp | (raw &amp; int_mode)</code> equals <code>int_mode ? raw : cmp</code>; one AND-OR gate per bit is smaller than a 2:1 mux (2,048 per PE edge pair, about 1,244 µm²). The raw bits arrive on new ports (<code>a_raw_in</code>, <code>w_raw_in</code>) from the edge buffer. A side: row h, lane k, position m gets bit h of activation <code>A[128b + 16k + m]</code>, which is just the next 128 activation bytes rewired by bit. W side: column v gets bit q of <code>W[x, v]</code> for the current pass q, so weights are stored bit-plane-major. Only edge PEs have these ports; inner PEs receive planes over the existing PE-to-PE forwarding.</figcaption></figure>
</section>

<section>
  <h2>Fig. 3 · One cycle in one PE</h2>
  <p>In INT8 mode one PE computes 8 outputs, <code>Y[i, j_0 … j_7]</code>, for one activation row i and 8 output columns. Each cycle it takes a chunk of
  128 reduction elements, <code>x = 128b … 128b + 127</code>, and the 8 bits of each activation go to the 8 tile rows.</p>
  <figure class="fig"><div class="scroll">{fig_layout()}</div>
  <figcaption>The PE is the same in both modes: 64 tiles, each with 128 ANDs (8 lanes × 16 positions) and one 24-bit accumulator, at the crossings of 8 row
  buses and 8 column buses of 128 wires each. The <code>128 b</code> boxes are the pipe registers that capture each bus once per PE. What changes between
  modes is only what the edge puts on the wires (table). In INT8, wire (k, m) of every bus carries element <code>x = 128b + 16k + m</code>, so an element
  occupies the same AND position (k, m) in all 64 tiles: tile (h, v)'s copy multiplies bit h of the activation by bit q of the weight in column j_v.</figcaption></figure>
  <div class="tablewrap"><table>
    <thead><tr><th></th><th>SC mode, T = 128</th><th>INT8 mode, weight pass q, cycle b</th></tr></thead>
    <tbody>
      <tr><td>Row bus h, wire (k, m)</td><td>random sample m of activation <code>A[h, x]</code>, x = 8j + k (8 elements per block, held 8 cycles)</td><td>bit h of activation <code>A[i, x]</code>, x = 128b + 16k + m (128 elements, new every cycle)</td></tr>
      <tr><td>Column bus v, wire (k, m)</td><td>random sample m of weight <code>W[x, v]</code></td><td>bit q of weight <code>W[x, j_v]</code>, same x</td></tr>
      <tr><td>Tile row h / column v</td><td>activation row h / weight column v</td><td>activation bit h of row i / output column j_v</td></tr>
      <tr><td>Accumulator (h, v) adds per cycle</td><td>the number of matching samples, signed</td><td>the number of x with both bits 1, signed by (h = 7) ⊕ (q = 7)</td></tr>
      <tr><td>Accumulator (h, v) holds before the drain</td><td>≈ <code>Σ_x A[h, x]·W[x, v]</code>, one output</td><td><code>Σ W[x, j_v]</code> over the x whose <code>A[i, x]</code> has bit h set (row 7 negated): one part of an output (Fig. 4)</td></tr>
      <tr><td>Results per PE</td><td>8 × 8 outputs</td><td>8 outputs, formed by the combiner from 8 accumulators each</td></tr>
    </tbody>
  </table></div>
</section>

<section>
  <h2>Fig. 4 · One block: what is sent, what stays, what each accumulator ends with</h2>
  <figure class="fig"><div class="scroll">{fig_exec()}</div>
  <figcaption>The accumulators stay in their tiles for the whole block except during the laps and the drain. Each pass streams the whole reduction again: the row
  buses repeat the same 32 chunks of activation bits, and the column buses carry one bit of every weight. After the last pass, accumulator (h, v) holds a
  weight sum over the elements whose activation has bit h set. The combiner adds the 8 rows of a column with weights 2<sup>h</sup>, with row 7 already
  negated, and that sum is the output.</figcaption></figure>
  <p>Worked example for output column j_5, with only three nonzero elements, all in chunk 0, lane 0, positions 0, 1, 2:
  <code>A[i, 0..2] = 3, −2, 1</code> and <code>W[0..2, j_5] = 2, 5, −3</code>, so <code>Y = 3·2 + (−2)·5 + 1·(−3) = −7</code>.</p>
  <div class="tablewrap"><table>
    <thead><tr><th>Tile row h</th><th>bit h of 3, −2, 1<br><span class="mono">00000011, 11111110, 00000001</span></th><th>accumulator (h, 5) before the drain</th><th>× 2<sup>h</sup> in the combiner</th></tr></thead>
    <tbody>
      <tr><td>0</td><td class="num">1, 0, 1</td><td class="num">2 + (−3) = −1</td><td class="num">−1</td></tr>
      <tr><td>1</td><td class="num">1, 1, 0</td><td class="num">2 + 5 = 7</td><td class="num">14</td></tr>
      <tr><td>2 … 6</td><td class="num">0, 1, 0</td><td class="num">5</td><td class="num">20, 40, 80, 160, 320</td></tr>
      <tr><td>7 (sign bit)</td><td class="num">0, 1, 0</td><td class="num">−5</td><td class="num">−640</td></tr>
      <tr><td><b>output</b></td><td></td><td></td><td class="num"><b>−7</b></td></tr>
    </tbody>
  </table></div>
  <div class="tablewrap"><table>
    <thead><tr><th>Bit</th><th>Used by, within one cycle</th><th>Sent to the array</th><th>Why it cannot be kept</th></tr></thead>
    <tbody>
      <tr><td>bit h of an activation A[i, x]</td><td>8 tiles (row h, all 8 output columns)</td><td>once per pass: 8 times for INT8 (held, not re-read, when L ≤ 128)</td><td>a pass covers the whole reduction before the lap, so A[i, x] is needed again in the next pass; the array has no storage for it (an edge replay buffer would)</td></tr>
      <tr><td>bit q of a weight W[x, j_v]</td><td>8 tiles (column v, all 8 activation bits)</td><td>once</td><td>each weight bit has its own pass</td></tr>
      <tr><td>SC magnitude (for comparison)</td><td>expanded to 16 stream bits per cycle, for T/16 = 8 cycles, by 8 tiles</td><td>once per block</td><td>no need: stream bits are random samples of one value, so the edge regenerates them from the held value</td></tr>
    </tbody>
  </table></div>
</section>

<section>
  <h2>Fig. 5 · Inside a PE: the drain chain becomes a doubling ring</h2>
  <figure class="fig"><div class="scroll">{fig_pe()}</div>
  <figcaption>Each row of 8 tiles is already a shift register for draining results east. INT adds one 24-bit mux per row at the west input. During a ring lap it feeds the
  row's own east output back in, shifted left by one, so after 8 shifts tile <code>T(h,v)</code> holds <code>2 × T(h,v)</code>. This is Horner's rule over weight bits:
  <code>out = ((S₇·2 + S₆)·2 + …)·2 + S₀</code>. The loop stays inside the PE (192 return wires, about 138 µm² per PE). <code>ring_q</code> is registered and
  re-exported east with the a bits, so with the per-PE lap enable each PE laps exactly when its own pass ends.</figcaption></figure>
</section>

<section>
  <h2>Fig. 6 · The tile (unchanged by INT)</h2>
  <figure class="fig"><div class="scroll">{fig_tile()}</div>
  <figcaption>Per lane, <code>count[k] = Σ_m a_bits[k][m] &amp; w_bits[k][m]</code>. The counter stops at five redundant bits whose weights sum to 16, so a negative lane
  is <code>Σ_j (bit_j ⊕ 1)·weight_j − 16</code>: five XORs plus one shared <code>−16·N</code> row. The heap adds every lane, the correction and <code>acc_low</code>
  in carry-save form. Only the 9-bit low part is added each cycle; carries and borrows reach the 15-bit high part as a lazy ±1. In INT mode the same tile counts
  1-bit products of 16 different reduction elements per lane, all with the same weight that cycle.</figcaption></figure>
</section>

<section>
  <h2>Fig. 7 · Schedule</h2>
  <figure class="fig"><div class="scroll">{fig_sched()}</div>
  <figcaption>INT8 runs 8 weight-bit passes, top bit first, with a ring lap between passes, then one drain. Tile row h always carries activation bit h, and the combiner
  applies 2<sup>h</sup>. In a grid each PE's passes are skewed by its position. With laps on the global <code>shift_in</code> every pass waits for the far PE; the
  per-PE lap enable removes that wait. Bars are not to scale: a pass is 32 cycles at L = 4096.</figcaption></figure>
</section>

<section>
  <h2>What each block does in each mode</h2>
  <div class="tablewrap"><table>
    <thead><tr><th>Block</th><th>SC mode</th><th>Bit-plane INT mode</th><th>Added for INT (synthesized)</th></tr></thead>
    <tbody>
      <tr><td>Sobol RNG pair</td><td>Advances every cycle; 16 values shared by all edges</td><td>Stopped</td><td class="num">none</td></tr>
      <tr><td>Edge peripheral</td><td>Compares held magnitudes with scrambled random values: 16 stream bits per lane per cycle</td><td>Magnitudes 0; raw plane bits pass the OR</td><td class="num"><span class="new">+1,244 µm²</span> per edge pair</td></tr>
      <tr><td>Bit and sign pipes</td><td>Register and broadcast stream bits; signs per block</td><td>Register and broadcast plane bits; sign = top-bit pass</td><td class="num">none</td></tr>
      <tr><td>Tile</td><td>AND, counters, sign XOR, heap, segmented accumulator</td><td>Same logic, 128 one-bit products per cycle</td><td class="num">none</td></tr>
      <tr><td>Drain chain</td><td>Shifts results east after the reduction</td><td>Also runs ring laps that double every tile between passes</td><td class="num"><span class="new">+138 µm²</span> per PE</td></tr>
      <tr><td>East combiner</td><td>Idle</td><td>Σ 2<sup>h</sup> · row h; two 4-row groups for INT4</td><td class="num"><span class="new">+681 µm²</span> per PE row</td></tr>
      <tr><td>Control</td><td><code>mac_en</code>, <code>shift_in</code>, <code>load_*</code></td><td>+ registered <code>int_mode</code>, <code>ring_in</code> wave, MAC guard</td><td class="num"><span class="new">+5.5 µm²</span></td></tr>
    </tbody>
  </table></div>
</section>

<section>
  <h2>Measured on the routed array</h2>
  <div class="facts">
    <div class="fact"><b>+2.0%</b><span>4×4 grid area for the INT mode (+5.0% on one PE)</span></div>
    <div class="fact"><b>+4.9%</b><span>SC power at T = 128 with the INT hardware present</span></div>
    <div class="fact"><b>0.348 pJ</b><span>per INT8 MAC at peak, 128 MAC/cycle per PE</span></div>
    <div class="fact"><b>0.087 pJ</b><span>per INT4 MAC at peak, 512 MAC/cycle per PE</span></div>
  </div>
  <p>Single-PE routes with grid-matched fixed pins, full-timing gate-level simulation, PrimeTime power. Grid figures are composites of routed blocks; operand
  delivery and SRAM energy are not included.</p>
</section>

<footer>Sources: <span class="mono">designs/payn/variants/signed_segmented_csa_bp/</span> (RTL and README),
<span class="mono">doc/INT_mode_on_PaYN.md</span>, <span class="mono">build/power_char/pinned_pass2_csa_bp_20261004_lap/</span>,
<span class="mono">build/power_char/int_mode_energy_20261004_lap/bp/</span>. Measured on the per-PE lap-enable netlist (<span class="mono">csa_bp_20261004_lap</span>, pinned IO),
the design shown in Fig. 5 and Fig. 7.</footer>
</div>
"""
open(OUT, "w").write(HTML)
print("wrote", OUT, len(HTML))
