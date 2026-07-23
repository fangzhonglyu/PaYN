# PaYN W-DBI variants

These are independent architecture points.  The baseline modules in
`designs/payn/` do not contain a DBI mode parameter or preprocessor switch.

Both variants encode each `M`-bit W stochastic word against the previously
transmitted encoded word.  `keep=1` sends the raw word and `keep=0` sends its
complement.  Equal-distance decisions retain the previous polarity.  The wide
encoded register bank remains resetless; one valid bit makes the first
post-reset word unencoded.

- `bitdecode/`: XNOR-decodes every W bit beside its partial-product AND.
- `countcorrect/`: computes `count(A)` once per row/depth and uses
  `count(A&W) = count(A) - count(A&encoded_W)` when W was inverted.
- `common/dbi_word_encode_next.sv`: shared combinational DBI decision, ensuring
  the two receiver experiments transmit exactly the same encoded words.

The tops and flow targets are deliberately distinct:

| design | top | target |
|---|---|---|
| bit decode | `payn_array_wdbi_bitdecode` | `TSMC22/PAYN_SC_WDBI_BITDECODE` |
| count correction | `payn_array_wdbi_countcorrect` | `TSMC22/PAYN_SC_WDBI_COUNTCORRECT` |

Only test infrastructure uses `PAYN_ARRAY_DUT` to run the same bit-exact bench
against each top.  Architectural selection never occurs inside synthesizable
baseline RTL.

At K8·M16·8×8 and 2.5 ns, bit decode synthesizes to 54,870.6 µm² with
+0.77 ns slack; count correction synthesizes to 56,336.8 µm² with +0.76 ns
slack.  Both are bit-exact, but neither has routed power data yet.  See
[`doc/SC_dbi.md`](../../../../doc/SC_dbi.md) for equations, qualification, and
reproduction commands.
