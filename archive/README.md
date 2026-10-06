# Archive

Superseded designs, studies and scripts, moved here untouched on 2026-10-06 when the repo was cleaned up. Nothing
here is maintained or expected to run: paths inside these files still name their original locations.

**Path rule:** `archive/<path>` is the file that lived at `<path>` in commit `8da2bf4`. To restore one, `git mv` it
back (or check out `8da2bf4`). The archived documents in `archive/doc/` cite `sweeps/...`,
`designs/payn/variants/...` etc.: read those as `archive/sweeps/...`, `archive/designs/...`.  Their numbers came from
runs under `build/`, `syn/build/` and `apr/build/`, which were not moved.

What is here:

| path | what it was |
|---|---|
| `designs/payn/variants/` | every earlier PaYN variant: signed segmented (plain, clean, popcount), carry-save (CSA, the SC reference of the C-BSG comparisons), bit-plane INT (BP, SR, IPD, hybrid), C-BSG A-first (AF), C-BSG per-row gating (RG), and AF-IPD, which `designs/payn/rtl/` replaces |
| `designs/payn/*.sv`, `designs/payn/cosim/` | the original PaYN RTL (Sobol SNG, inner PE/tile) and its Python cosim |
| `designs/payn/tb/`, `designs/payn/power/` | the benches of all of the above |
| `designs/baselines/soft_error/`, `roc_flow/` | the GF22 soft-error (ROC) study |
| `sweeps/` | every campaign, study, probe, review and debug script (C-BSG, INT-mode exploration, popcount, K/M/N, wire, T-sweep, pending-bit, ROC, ...) |
| `syn/targets/`, `apr/targets/` | targets of the archived designs and studies |
| `syn/scripts/`, `apr/scripts/` | hook scripts only those targets used |
| `doc/` | results and handoff notes of the archived designs and studies: the A7/SVT and A6P5 results, the SC breakdown, timing, wire and area-efficiency studies, the INT-mode exploration and its datapath figure, the C-BSG port plan and variant comparison (AF / RG / CSA, AF-IPD), the low-corner GL-X note, the ROC study, the bitmod comparison, the experiment index |
| `equivalence/` | the Formality proof that `designs/payn/rtl` equals the AF-IPD variant (below) |

## Equivalence of the cleaned RTL

`designs/payn/rtl/` is the AF-IPD variant (`designs/payn/variants/signed_segmented_csa_cbsg_af_ipd/`, the qualified
route `cbsg_af_ipd_20261005_distguide_spp_pins_postfill`) with plain module names, one file per block and the K16/M8
shape added. At the old shape it is the same hardware:

- **Formality** (`bash archive/equivalence/run.sh`, S-2021.06-SP1, K8/M16/N8x8/LOW_W 9): `payn_array` vs
  `payn_array_signed_segmented_csa_cbsg_af_ipd`, 5,682 of 5,682 compare points pass; `PaynPeGrid` vs
  `InnerPESignedSegmentedCsaBpIpdGridAfIpd` (2x2), 20,114 of 20,114 pass; no unmatched points.
- **Synthesis** (`syn/build/TSMC22/PAYN/payn_k8m16_20261006` vs `syn/build/TSMC22/PAYN_SC_CSA_CBSG_AF_IPD/cbsg_af_ipd_20261005`,
  same knobs): 58,232 cells, 2,880 sequential, 44,690.646 um2, slack +0.88 ns in both.
