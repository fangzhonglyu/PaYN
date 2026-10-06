# SC arithmetic model and RTL comparison

`sc_kernel.py` is the restored NumPy array-level arithmetic model. It models
the shared Sobol banks, XOR scrambling, binary-to-stochastic comparators,
signed stochastic products, accumulation, and single-PE GEMM tiling.

Run its standalone array-level self-test with:

```bash
python3 verify/scmp_cosim/sc_kernel.py
```

The current bit-exact RTL comparison targets the restored input periphery:

```bash
bash verify/scmp_cosim/run_peripheral_v1.sh
```

That comparison checks 260 cycles so the 8-bit Sobol wrap is covered. It
compares both random banks, both scramble salts, all packed comparator outputs,
and the held sign registers against `sc_kernel.py`.

`stim_gen.py` and `compare.py` are retained from the original full-array flow.
They remain useful for stimulus and result formatting, but the old full-array
RTL testbench depended on array modules removed during the architecture cleanup.
