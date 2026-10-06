# Read-only probe of a routed checkpoint (sweeps/cbsg/af/run_drc_population.sh): restores ENC, runs verify_drc with
# no practical marker limit (the flow's limit is 1000, so its geom.rpt is a sample) and dumps every instance's
# name, master and box, so sweeps/cbsg/af/drc_population.py can classify all markers (second object: second-pass
# filler, cell pin, wire; net hierarchy; distance from the east edge) and map the second-pass fillers.
# Env: ENC (the .enc.dat directory), TOP.  Writes drc_full.rpt and insts.tsv in the current directory.
restoreDesign $env(ENC) $env(TOP)
setMultiCpuUsage -localCpu 16
set fp [dbFPlanBox [dbHeadFPlan]]
puts "DRCPOP_DIE [dbDBUToMicrons [lindex $fp 2]] [dbDBUToMicrons [lindex $fp 3]]"
set cb [dbGet top.fPlan.coreBox]
puts "DRCPOP_CORE $cb"
clearDrc
verify_drc -limit 10000000 -report drc_full.rpt
set fo [open insts.tsv w]
puts $fo "name\tcell\tllx\tlly\turx\tury"
foreach p [dbGet top.insts] {
    lassign [lindex [dbGet $p.box] 0] x1 y1 x2 y2
    puts $fo "[dbGet $p.name]\t[dbGet $p.cell.name]\t$x1\t$y1\t$x2\t$y2"
}
close $fo
puts "DRCPOP_DONE"
exit
