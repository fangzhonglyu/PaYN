#!/usr/bin/env python3
"""Report only fully qualified routed native BOS precision results."""
import argparse,csv,json,re
from pathlib import Path
from validate_routed_apr import audit as audit_apr
from validate_routed_gl import audit as audit_gl
from validate_pt_power_coverage import audit_reports

REPO=Path(__file__).resolve().parent.parent
PASS='PASS: binary OS power SAIF captured + output-checked; 4096 cycles (4096 MAC, 0 drain), 262144 useful MAC'

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--campaign',default='bos_precision_20261002')
    parser.add_argument('--widths',nargs='+',type=int,default=[6,4])
    args=parser.parse_args()
    assert re.fullmatch(r'[A-Za-z0-9_]+',args.campaign)
    root=REPO/'build/bos_precision'/args.campaign
    rows=[]
    for width in args.widths:
        assert width in (6,4)
        work=root/f'int{width}'
        for stage in ('apr','simulation','power'):
            assert (work/f'{stage}.status').read_text().strip()=='PASS', f'Incomplete {width}/{stage}'
        with (work/'result.csv').open() as f: row=next(csv.DictReader(f))
        assert int(row['IWIDTH'])==width and row['status']=='PASS'
        route=REPO/'apr/build'/row['target']/row['run']
        q=audit_apr(route,f'binary_os_array_int{width}')
        timing=audit_gl((work/'gl_final/simulation.log').read_text(errors='replace'),PASS)
        assert timing['status']=='PASS',timing['rejection_reasons']
        assert 'validated binary SAIF:' in (work/'gl_final/saif_validation.log').read_text()
        coverage=audit_reports(route/'reports',route/'power_apr.log')
        power=float(re.search(r'Total Power\s*=\s*([0-9.eE+-]+)',(route/'reports/power.rpt').read_text())[1])*1000
        assert abs(power-float(row['power_mW']))<1e-6
        assert abs(q['area_um2']-float(row['area_um2']))<1e-6
        row.update({k:v for k,v in coverage.items() if k!='status'})
        row.update(sdf_errors=sum(timing['sdf_errors']),startup_timing_violations=timing['startup_timing_violations'],post_reset_timing_violations=timing['post_reset_timing_violations'])
        rows.append(row)
        print(f"INT{width}: {q['area_um2']:.3f} um2; {power:.6f} mW; {power*2.5/64:.6f} pJ/MAC; setup/hold {q['setup_wns_ns']:+.3f}/{q['hold_wns_ns']:+.3f} ns; PASS")
    with (root/'results.csv').open('w') as f:
        writer=csv.DictWriter(f,fieldnames=rows[0]);writer.writeheader();writer.writerows(rows)
    print(root/'results.csv')

if __name__=='__main__':main()
