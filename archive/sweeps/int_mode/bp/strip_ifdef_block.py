#!/usr/bin/env python3
"""Remove every `ifdef <MACRO> ... matching `endif block (nesting-aware) from a
Verilog file and print the rest.  Used to prove that an opt-in `ifdef hook is
the only change to a bench: strip(current) must equal the committed file.

    strip_ifdef_block.py PAYN_INT_PORTS designs/payn/tb/test_payn_array.sv
"""
import re
import sys


def strip(lines, macro):
    out, depth = [], 0
    for line in lines:
        tok = line.strip()
        if depth == 0:
            if re.match(r"`ifdef\s+%s\b" % re.escape(macro), tok):
                depth = 1
                continue
            out.append(line)
            continue
        if re.match(r"`if(n)?def\b", tok):
            depth += 1
        elif re.match(r"`endif\b", tok):
            depth -= 1
        elif depth == 1 and re.match(r"`(else|elsif)\b", tok):
            sys.exit("`else/`elsif at the hook's top level: not a pure opt-in block")
    if depth:
        sys.exit("unterminated `ifdef %s block" % macro)
    return out


if __name__ == "__main__":
    macro, path = sys.argv[1], sys.argv[2]
    with open(path) as f:
        sys.stdout.write("".join(strip(f.readlines(), macro)))
