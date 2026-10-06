#!/usr/bin/env python3
"""Print value changes of selected VCD signals in a time window (debug helper).

  vcd_window.py FILE.vcd T0_PS T1_PS SCOPE_SUFFIX:SIGNAL [...]
SCOPE_SUFFIX matches the end of the dotted scope path, SIGNAL the reference
name (bus names without the index match every bit / the vector).
"""
import sys
from collections import defaultdict


def main():
    path, t0, t1 = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    wants = [w.split(':', 1) for w in sys.argv[4:]]
    scope, ids = [], defaultdict(list)
    with open(path) as f:
        for line in f:
            tok = line.split()
            if not tok:
                continue
            if tok[0] == '$scope':
                scope.append(tok[2])
            elif tok[0] == '$upscope':
                scope.pop()
            elif tok[0] == '$var':
                code, ref = tok[3], ' '.join(tok[4:-1])
                sp = '.'.join(scope)
                for s, n in wants:
                    if sp.endswith(s) and (ref == n or ref.split('[')[0] == n or ref.split(' ')[0] == n):
                        ids[code].append(f'{s}:{ref}')
            elif tok[0] == '$enddefinitions':
                break
        t = 0
        for line in f:
            line = line.strip()
            if not line:
                continue
            if line[0] == '#':
                t = int(line[1:])
                if t > t1:
                    break
                continue
            if line[0] in 'bBrR':
                val, code = line[1:].split()
            else:
                val, code = line[0], line[1:]
            if t >= t0 and code in ids:
                for name in ids[code]:
                    print(f'{t:>9} {name:60s} {val}')


if __name__ == '__main__':
    main()
