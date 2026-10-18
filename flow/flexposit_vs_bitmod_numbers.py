"""python3 flow/flexposit_vs_bitmod_numbers.py -- derived numbers for doc/flexposit_vs_bitmod.md, from the measured campaigns (inputs copied from
doc/flexposit_results.md, doc/bitmod_breakdown.md and the FlexPosit PE sub-block PrimeTime split)."""
# ---- FlexPosit fp_20261015b (8x8 core, routed 44,568.9 um2) ----
FP_AREA = 44568.9
fp_area = dict(acc=26120, mult=7870, pipe=2409, decode=4404.4, readout=988.8, cycgen=37.9, rest=2738.7)
fp = {4: dict(mW=8.391, win=4329, pj=1.3857, mult=2.90, acc=2.40, pipe=0.58, decode=0.972, readout=0.026, cycgen=0.022, rest=1.496),
      5: dict(pj=1.5562), 6: dict(pj=1.7336), 7: dict(pj=1.9202),
      8: dict(mW=6.431, win=8553, pj=2.0982, mult=2.65, acc=1.20, pipe=0.44, decode=0.773, readout=0.012, cycgen=0.017, rest=1.347)}
FP_MAC = 65536
# ---- BitMoD bm_20261016b (8x8 tile, routed 81,791.2 um2; flat synth 2.5 ns 69,783) ----
BM_AREA, BM_FLAT = 81791.192, 69783
bm_area = dict(lanes=3489, align=15612, pairadd=9612, merge=10344, acc=16879, norm=7338, scale=8652, peglue=327,
               rf=3418, fpadd=1609, dreg=1174, common=437, rest=2898)
bm_pj = {4: dict(mpc=128, pj=0.6975, lanes=0.0222, align=0.1654, pairadd=0.1243, merge=0.1182, acc=0.1431, norm=0.0056, scale=0.0087,
                 peglue=0.0126, rf=0.0043, fpadd=0.0058, dreg=0.0076, common=0.0008, rest=0.0787),
         6: dict(mpc=85.333, pj=1.0579, lanes=0.0244, align=0.2210, pairadd=0.2137, merge=0.1981, acc=0.2393, norm=0.0069, scale=0.0092),
         8: dict(mpc=64, pj=1.3523, lanes=0.0293, align=0.2745, pairadd=0.2733, merge=0.2585, acc=0.3146, norm=0.0078, scale=0.0093,
                 peglue=0.0233, rf=0.0047, fpadd=0.0059, dreg=0.0078, common=0.0011, rest=0.1415)}

print("== throughput density (GMAC/s/mm2, 400 MHz) and area per MAC/cycle (um2)")
for b in (4, 6, 8):
    fmpc = 64 / b
    print(f" {b}b: FlexPosit {fmpc*0.4/(FP_AREA*1e-6):6.0f}  {FP_AREA/fmpc:6.0f} | BitMoD routed {bm_pj[b]['mpc']*0.4/(BM_AREA*1e-6):6.0f} "
          f"{BM_AREA/bm_pj[b]['mpc']:5.0f}  flat {bm_pj[b]['mpc']*0.4/(BM_FLAT*1e-6):6.0f}  | ratio routed "
          f"{(bm_pj[b]['mpc']/BM_AREA)/(fmpc/FP_AREA):.2f}  flat {(bm_pj[b]['mpc']/BM_FLAT)/(fmpc/FP_AREA):.2f}  energy ratio {fp[b]['pj']/bm_pj[b]['pj']:.2f}")

print("== area per MAC/cycle at 4 b by function (um2)")
F = {k: v / 16 for k, v in fp_area.items()}
B = {k: v / 128 for k, v in bm_area.items()}
rows = [("weight decode (in core)", F["decode"], 0.0),
        ("product formation (+ in-PE lane reduction)", F["mult"], B["lanes"] + B["align"] + B["pairadd"] + B["merge"]),
        ("accumulation", F["acc"], B["acc"]),
        ("scale / dequant", 234 / 16, B["norm"] + B["scale"]),
        ("column output (readout ex. rescale / fpadd + output RF)", F["readout"] - 234 / 16, B["rf"] + B["fpadd"]),
        ("PE pipe regs, staging, control, clock tree, glue", F["pipe"] + F["cycgen"] + F["rest"], B["peglue"] + B["dreg"] + B["common"] + B["rest"])]
tf = tb = 0
for n, a, c in rows:
    tf += a; tb += c
    print(f" {n:58s} {a:7.1f} {c:7.1f}  gap {a-c:7.1f}")
print(f" {'total':58s} {tf:7.1f} {tb:7.1f}  gap {tf-tb:7.1f}")

print("== energy per MAC by function (pJ)")
def fpj(p):
    f = fp[p]["win"] * 2.5 / FP_MAC
    d = fp[p]
    return dict(decode=d["decode"]*f, product=d["mult"]*f, acc=d["acc"]*f, scale=d["readout"]*f,
                rest=(d["pipe"] + d["cycgen"] + d["rest"])*f, total=d["mW"]*f)
def bpj(b):
    d = bm_pj[b]
    return dict(decode=0.0, product=d["lanes"]+d["align"]+d["pairadd"]+d["merge"], acc=d["acc"], scale=d["norm"]+d["scale"]+d.get("fpadd",0)+d.get("rf",0),
                rest=d.get("peglue",0)+d.get("dreg",0)+d.get("common",0)+d.get("rest",0), total=d["pj"])
for (pf, pb) in ((4, 4), (8, 8)):
    a, c = fpj(pf), bpj(pb)
    print(f" FlexPosit P={pf} vs BitMoD {pb}b")
    for k in ("decode", "product", "acc", "scale", "rest", "total"):
        print(f"   {k:8s} {a[k]:.3f} {c[k]:.3f}  gap {a[k]-c[k]:+.3f}")
for b in (4, 6, 8):
    print(f" product path per weight bit: BitMoD {b}b {bpj(b)['product']/b:.3f} pJ/bit" if b in bm_pj else "")
for p in (4, 8):
    print(f" product path per weight bit: FlexPosit P={p} {fpj(p)['product']/p:.3f} pJ/bit")
print(f" accumulation per MAC: FlexPosit P=4 {fpj(4)['acc']:.3f}, P=8 {fpj(8)['acc']:.3f}; BitMoD 4b {bm_pj[4]['acc']:.3f}, 6b {bm_pj[6]['acc']:.3f}, 8b {bm_pj[8]['acc']:.3f}")

print("== linear fit E/MAC = slope*bits + fixed")
import statistics
def fit(xs, ys):
    mx, my = statistics.mean(xs), statistics.mean(ys)
    s = sum((x-mx)*(y-my) for x, y in zip(xs, ys)) / sum((x-mx)**2 for x in xs)
    return s, my - s*mx
s, i = fit([4,5,6,7,8], [fp[p]["pj"] for p in (4,5,6,7,8)]); print(f" FlexPosit slope {s:.3f} pJ/bit, fixed {i:.3f} pJ/MAC")
s, i = fit([4,6,8], [bm_pj[b]["pj"] for b in (4,6,8)]); print(f" BitMoD    slope {s:.3f} pJ/bit, fixed {i:.3f} pJ/MAC")

print("== cell classes (pJ/MAC): clock, register, combinational")
cls = {"FlexPosit P=4": (1.3857, 0.4851, 0.1449, 0.3700), "FlexPosit P=8": (2.0982, 0.5876, 0.1309, 0.2815),
       "BitMoD 4b": (0.6975, 0.1594, 0.1054, 0.7352), "BitMoD 8b": (1.3523, 0.1582, 0.1094, 0.7324)}
for k, (pj, c, r, x) in cls.items():
    print(f" {k:14s} clock {pj*c:.3f} reg {pj*r:.3f} comb {pj*x:.3f} seq {pj*(c+r):.3f}")

print("== system, batch-1 decode: DRAM 8 pJ/bit x stored bits + compute pJ/MAC")
peb = [4.2, 4.1, 4.5, 4.1, 4.6, 4.4, 4.3, 4.6, 5.0]
pm = sum(peb) / len(peb)
fp_c = 1.3857 + (pm - 4) * (1.5562 - 1.3857)
bm_bits = 4 + 8/128 + 3/128
print(f" FlexPosit iso-PPL mean precision {pm:.2f} b: DRAM {8*pm:.1f} + compute {fp_c:.2f} = {8*pm+fp_c:.1f} pJ")
for name, c in (("measured", 0.6975), ("reported", 0.592)):
    print(f" BitMoD 4 b ({bm_bits:.3f} stored b), {name}: DRAM {8*bm_bits:.1f} + compute {c:.2f} = {8*bm_bits+c:.1f} pJ")
for B_ in (1, 4, 16, 64, 256):
    f = 8*pm/B_ + fp_c; b = 8*bm_bits/B_ + 0.6975
    print(f"  batch {B_:3d}: FlexPosit {f:6.2f}  BitMoD {b:6.2f}  ratio {f/b:.2f}")
fb = 4.8; fc = 1.3857 + 0.8*(1.5562-1.3857)
i6 = 6 + 8/128 + 3/128
print(f" Best-PPL target (mean dPPL 0.20): FlexPosit {fb} b: {8*fb+fc:.1f} pJ (compute {fc:.2f}); BitMoD i6 {i6:.3f} b: {8*i6+1.0579:.1f} pJ")

print("== paper reconciliation (16 nm Table VII)")
print(f" paper real PE ratio FlexPosit/BitMoD {214.3/887.2:.3f}")
fp_real = 568.7 + 4404.4/64
bm_real_r, bm_real_s = BM_AREA/64, 70867/64
print(f" ours: FlexPosit test-chip real PE {fp_real:.0f}; BitMoD real PE routed {bm_real_r:.0f} / synth {bm_real_s:.0f} -> ratio {fp_real/bm_real_r:.2f}/{fp_real/bm_real_s:.2f}")
shared = 123 + 38 + 408/4 + 4404.4/64
print(f" FlexPosit with 4-way shared accumulator (estimate) real PE {shared:.0f} -> ratio {shared/bm_real_r:.2f}/{shared/bm_real_s:.2f}")
fl_tp = 512 / pm
print(f" paper iso-area: 512 FlexPosit PEs at {pm:.2f} b -> {fl_tp:.0f} MAC/cycle; 1.8x speedup implies BitMoD 128 PEs at {fl_tp/1.8/128:.2f} MAC/cycle/PE; "
      f"RTL BitMoD PE at 4 b = 2 MAC/cycle -> {256:.0f} MAC/cycle ({256/fl_tp:.1f}x FlexPosit)")
print(f" shared-acc FlexPosit core area estimate {FP_AREA - 64*408*0.75:.0f} um2 -> {16/(FP_AREA-64*408*0.75):.2e} vs BitMoD {128/BM_AREA:.2e} MAC/cycle/um2 "
      f"-> BitMoD {(128/BM_AREA)/(16/(FP_AREA-64*408*0.75)):.1f}x")
