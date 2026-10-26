# Vivado 2026.1 batch build for the MYD-CZU5EV-V2 HFT pipeline.
#
# Arguments: repository_root output_directory profile goal
# profile: sim-dma | sfp10g
# goal: synth | bitstream
#
# Gates (each fails the build): setup and hold slack >= 0 on every
# constrained path, and no Critical clock-domain crossing in report_cdc.
# Every crossing must go through cdc_snapshot, cdc_sync_bit or reset_sync.

proc fail {message} {
  puts stderr "ERROR: $message"
  exit 1
}

if {$argc != 4} {
  fail "usage: build.tcl <repo-root> <output-dir> <sim-dma|sfp10g> <synth|bitstream>"
}

set repo_root [file normalize [lindex $argv 0]]
set output_dir [file normalize [lindex $argv 1]]
set profile [lindex $argv 2]
set goal [lindex $argv 3]
set board_repo [file join $repo_root zynq ultrascale+ board_files]
set part_name xczu5ev-sfvc784-2-e

if {$profile ni {sim-dma sfp10g}} {
  fail "unknown profile '$profile'"
}
if {$goal ni {synth bitstream}} {
  fail "unknown goal '$goal'"
}
if {[string first "2026.1" [version -short]] != 0} {
  fail "Vivado 2026.1 is required; found [version -short]"
}

file mkdir $output_dir
set existing_board_repos [get_param board.repoPaths]
set_param board.repoPaths [linsert $existing_board_repos 0 $board_repo]

create_project -force hft_pipeline [file join $output_dir project] \
  -part $part_name

set myd_board_parts [get_board_parts -quiet myirtech.com:myd_czu5ev_v2:*]
if {[llength $myd_board_parts] == 0} {
  fail "repo-local MYD-CZU5EV-V2 board definition was not discovered at '$board_repo'"
}
set_property board_part [lindex $myd_board_parts end] [current_project]

set_property target_language VHDL [current_project]
set_property simulator_language Mixed [current_project]
set_property default_lib hft [current_project]

# Same list and order as the simulation (sim/run.py).
set source_list [file join $repo_root zynq ultrascale+ rtl sources.f]
set handle [open $source_list r]
set sources {}
foreach line [split [read $handle] "\n"] {
  set line [string trim $line]
  if {$line eq "" || [string index $line 0] eq "#"} {
    continue
  }
  lappend sources [file normalize [file join $repo_root $line]]
}
close $handle

foreach source $sources {
  if {![file exists $source]} {
    fail "missing source '$source'"
  }
  read_vhdl -vhdl2008 -library hft $source
}

# Every RTL file must be in the list, so nothing is simulated but not built.
foreach rtl [glob -directory [file join $repo_root zynq ultrascale+ rtl] *.vhd] {
  if {[lsearch -exact $sources [file normalize $rtl]] < 0} {
    fail "RTL file '[file tail $rtl]' is not listed in sources.f"
  }
}

read_xdc [file join $repo_root zynq ultrascale+ constraints myd_czu5ev_v2_hft.xdc]
set_property top myd_czu5ev_v2_hft_top [current_fileset]

if {$profile eq "sfp10g"} {
  set ipdefs [get_ipdefs -all *xxv_ethernet*]
  if {[llength $ipdefs] == 0} {
    fail "10G/25G Ethernet subsystem is unavailable in this installation"
  }
  puts "INFO: sfp10g selected; this build verifies the license-independent VHDL pipeline."
  puts "INFO: MAC/PCS integration and licensed bitstream are deferred until board bring-up."
}

synth_design -mode out_of_context -top myd_czu5ev_v2_hft_top \
  -part $part_name
source [file join $repo_root zynq ultrascale+ constraints myd_czu5ev_v2_hft_cdc.xdc]
opt_design

report_timing_summary -delay_type min_max -max_paths 20 -report_unconstrained \
  -file [file join $output_dir timing_summary.rpt]
report_utilization -hierarchical \
  -file [file join $output_dir utilization_hierarchical.rpt]
report_utilization \
  -file [file join $output_dir utilization.rpt]
report_clock_interaction -delay_type min_max \
  -file [file join $output_dir clock_interaction.rpt]
report_cdc -details \
  -file [file join $output_dir cdc.rpt]
report_methodology \
  -file [file join $output_dir methodology.rpt]
report_drc \
  -file [file join $output_dir drc.rpt]
write_checkpoint -force [file join $output_dir hft_pipeline_synth.dcp]

# --- Gates ------------------------------------------------------------------

set setup_paths [get_timing_paths -delay_type max -max_paths 1 -nworst 1]
set hold_paths [get_timing_paths -delay_type min -max_paths 1 -nworst 1]
set wns [expr {[llength $setup_paths] ? [get_property SLACK [lindex $setup_paths 0]] : 0.0}]
set whs [expr {[llength $hold_paths] ? [get_property SLACK [lindex $hold_paths 0]] : 0.0}]
if {$wns eq ""} { set wns 0.0 }
if {$whs eq ""} { set whs 0.0 }

# report_cdc summary rows read "<rule> <severity> <count> <description>",
# e.g. "CDC-15  Warning  511  Clock enable controlled CDC structure detected".
set cdc_handle [open [file join $output_dir cdc.rpt] r]
set critical_cdc 0
set cdc_rules 0
foreach line [split [read $cdc_handle] "\n"] {
  if {[regexp {^(CDC-\d+)\s+(\w+)\s+(\d+)\s} $line -> rule severity count]} {
    incr cdc_rules
    if {$severity eq "Critical"} {
      incr critical_cdc $count
    }
  }
}
close $cdc_handle
if {$cdc_rules == 0} {
  fail "cdc.rpt has no summary table; the CDC gate cannot be evaluated"
}

set summary [open [file join $output_dir gates.txt] w]
puts $summary "profile=$profile"
puts $summary "wns_ns=$wns"
puts $summary "whs_ns=$whs"
puts $summary "critical_cdc=$critical_cdc"
close $summary

puts "INFO: WNS $wns ns, WHS $whs ns, critical CDC findings: $critical_cdc"
if {$wns < 0} {
  fail "setup timing not met (WNS $wns ns); see timing_summary.rpt"
}
if {$whs < 0} {
  fail "hold timing not met (WHS $whs ns); see timing_summary.rpt"
}
if {$critical_cdc > 0} {
  fail "$critical_cdc critical clock-domain crossing(s); see cdc.rpt"
}

if {$goal eq "bitstream"} {
  fail "Bitstream/XSA generation is blocked until MYIR DDR/PS presets and SFP cage routing are verified"
}

puts "INFO: MYD-CZU5EV-V2 HFT pipeline out-of-context synthesis completed successfully."
exit 0
