#!/usr/bin/env python3
"""Qualify a completed routed design using actual physical/timing reports."""
import argparse,json,re
from pathlib import Path


def audit(route: Path, top: str) -> dict:
    log=(route/"apr.log").read_text(errors="replace")
    assert "Innovus script finished" in log or "CHECKPOINT_REPAIR_COMPLETE" in log, "Missing flow completion"
    assert '--- Ending "Innovus"' in log, "Missing normal tool termination"
    errors=re.findall(r"Message Summary:\s*\d+ warning\(s\),\s*(\d+) error\(s\)",log)
    assert errors and all(int(x)==0 for x in errors), "Innovus errors or absent summary"
    assert not re.search(r"\*\*\s*ERROR:|(?m:^\s*(?:ERROR|Error):)",log), "Error diagnostic"
    for suffix in ("apr.v","apr.sdf","spef"):
        p=route/"outputs"/f"{top}.{suffix}"
        assert p.is_file() and p.stat().st_size, f"Missing {p}"
    geo=(route/f"{top}.geom.rpt").read_text()
    m=re.search(r"Total Violations\s*:\s*(\d+)",geo)
    assert (not m or int(m[1])==0) and (m or re.search(r"(?m)^No DRC violations were found\s*$",geo)), "Geometry violations"
    ant=(route/f"{top}.antenna.rpt").read_text()
    m=re.search(r"Total number of process antenna violations:\s*(\d+)",ant)
    assert (not m or int(m[1])==0) and (m or re.search(r"(?m)^No Violations Found\s*$",ant)), "Antenna violations"
    conn=re.findall(r"\*+ Start: VERIFY CONNECTIVITY \*+(.*?)\*+ End: VERIFY CONNECTIVITY \*+",log,re.S)
    assert conn and "Found no problems or warnings." in conn[-1], "Connectivity failed"
    checks=list(re.finditer(r"Begin checking placement.*?Finished checkPlace[^\n]*",log,re.S))
    assert checks, "Missing final placement check"
    last=checks[-1]
    m=re.search(r"Unplaced\s*=\s*(\d+)",last[0])
    assert m and int(m[1])==0, "Unplaced instances"
    violations=re.findall(r"^([^*\n]+):\s*([1-9]\d*)\s*$",last[0],re.M)
    assert not violations and "NRDB-2082" not in log[last.end():], "Placement violations"
    result=dict(status="PASS",geometry_drc=0,antenna_violations=0,connectivity_violations=0,placement_violations=0)
    for kind in ("setup","hold"):
        s=(route/"reports"/f"{kind}.rpt").read_text()
        m=re.search(r"Slack Time\s*([-+0-9.]+)",s)
        assert m and float(m[1])>=0, f"{kind} timing violation"
        result[kind+"_wns_ns"]=float(m[1])
    area=[line.split() for line in (route/"reports/area.rpt").read_text().splitlines() if line.split() and line.split()[0]==top]
    assert len(area)==1
    result["area_um2"]=float(area[0][2])
    assert result["area_um2"]>0
    return result


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("route",type=Path);parser.add_argument("top");parser.add_argument("--json",type=Path,dest="json_path")
    args=parser.parse_args()
    result=audit(args.route,args.top)
    output=json.dumps(result,indent=2)+"\n"
    if args.json_path:args.json_path.write_text(output)
    print(output,end="")

if __name__=="__main__":main()
