# Vivado 2026.1 batch build for the MYD-CZU5EV-V2 HFT pipeline.
#
# Arguments: repository_root output_directory profile goal
# profile: sim-dma | sfp10g
# goal: synth | impl | bitstream
#   synth: out-of-context synthesis and its gates
#   impl:  synth, then out-of-context place and route and the routed gates
#
# Gates (each fails the build): setup and hold slack >= 0 on every
# constrained path, and no Critical clock-domain crossing in report_cdc.
# Every crossing must go through cdc_snapshot, cdc_sync_bit or reset_sync.
# impl repeats the slack gates on the routed design (hold from input ports
# excepted; see below) and requires that no net has routing errors.

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
if {$goal ni {synth impl bitstream}} {
  fail "unknown goal '$goal'"
}
if {[string first "2026.1" [version -short]] != 0} {
  fail "Vivado 2026.1 is required; found [version -short]"
}

file mkdir $output_dir
# Vivado on Windows defaults to 2 threads; 8 is the most placement, routing
# and timing analysis use.
set_param general.maxThreads 8
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

proc worst_slack {delay_type} {
  set paths [get_timing_paths -delay_type $delay_type -max_paths 1 -nworst 1]
  set slack [expr {[llength $paths] ? [get_property SLACK [lindex $paths 0]] : 0.0}]
  return [expr {$slack eq "" ? 0.0 : $slack}]
}

set wns [worst_slack max]
set whs [worst_slack min]

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
if {$goal eq "synth"} {
  puts "INFO: MYD-CZU5EV-V2 HFT pipeline out-of-context synthesis completed successfully."
  exit 0
}

# --- Out-of-context implementation -----------------------------------------

# Out of context, nothing buffers the clock ports, so without HD.CLK_SRC the
# router treats both clocks as ideal. Drive them from BUFGCE sites in the
# clock region nearest the vertical middle of the device, as the board's
# global buffers would; on the XCZU5EV only the X1 column has BUFGCEs.
set rows [get_property ROW_INDEX [get_clock_regions]]
set middle [expr {([tcl::mathfunc::max {*}$rows] + [tcl::mathfunc::min {*}$rows]) / 2.0}]
set best_region ""
set best_distance ""
foreach name [lsort -dictionary [get_clock_regions]] {
  set region [get_clock_regions $name]
  set buffers [get_sites -quiet -of_objects $region -filter {SITE_TYPE == BUFGCE}]
  set distance [expr {abs([get_property ROW_INDEX $region] - $middle)}]
  if {[llength $buffers] >= 2 && ($best_region eq "" || $distance < $best_distance)} {
    set best_region $region
    set best_distance $distance
  }
}
if {$best_region eq ""} {
  fail "no clock region of $part_name offers two BUFGCE sites for the clock sources"
}
set buffers [lsort -dictionary [get_sites -of_objects $best_region -filter {SITE_TYPE == BUFGCE}]]
set_property HD.CLK_SRC [lindex $buffers 0] [get_ports axis_clk]
set_property HD.CLK_SRC [lindex $buffers 1] [get_ports ps_clk]
puts "INFO: clock sources axis_clk=[lindex $buffers 0] ps_clk=[lindex $buffers 1] ($best_region)"

# The ports still see an ideal clock while the registers behind them now see
# the BUFGCE tree (about 1.7 ns), so every input path would fail hold by that
# much. On the board the registers driving these ports (MAC, PS AXI master)
# hang off the same tree; their hold belongs to the integrated build, and the
# router must not pad the paths for it.
set_false_path -hold -from [all_inputs]

place_design
phys_opt_design
route_design

report_timing_summary -delay_type min_max -max_paths 20 -report_unconstrained \
  -file [file join $output_dir timing_summary_routed.rpt]
report_utilization \
  -file [file join $output_dir utilization_routed.rpt]
report_route_status \
  -file [file join $output_dir route_status_routed.rpt]
report_drc \
  -file [file join $output_dir drc_routed.rpt]
report_methodology \
  -file [file join $output_dir methodology_routed.rpt]
write_checkpoint -force [file join $output_dir hft_pipeline_routed.dcp]

set route_wns [worst_slack max]
set route_whs [worst_slack min]
set route_errors 0
set status_handle [open [file join $output_dir route_status_routed.rpt] r]
foreach line [split [read $status_handle] "\n"] {
  if {[regexp {# of nets with routing errors\.*\s*:\s*(\d+)} $line -> count]} {
    set route_errors $count
  }
}
close $status_handle

set summary [open [file join $output_dir gates.txt] a]
puts $summary "route_wns_ns=$route_wns"
puts $summary "route_whs_ns=$route_whs"
puts $summary "route_errors=$route_errors"
close $summary

puts "INFO: routed WNS $route_wns ns, WHS $route_whs ns, nets with routing errors: $route_errors"
if {$route_wns < 0} {
  fail "routed setup timing not met (WNS $route_wns ns); see timing_summary_routed.rpt"
}
if {$route_whs < 0} {
  fail "routed hold timing not met (WHS $route_whs ns); see timing_summary_routed.rpt"
}
if {$route_errors > 0} {
  fail "$route_errors net(s) with routing errors; see route_status_routed.rpt"
}

puts "INFO: MYD-CZU5EV-V2 HFT pipeline out-of-context implementation completed successfully."
exit 0
