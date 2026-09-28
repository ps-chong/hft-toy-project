# Vivado 2026.1 batch build for the MYD-CZU5EV-V2 HFT pipeline.
#
# Arguments: repository_root output_directory profile goal
# profile: sim-dma | sfp10g
# goal: synth | bitstream

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

set sources [list \
  [file join $repo_root protocol generated vhdl hft_protocol_pkg.vhd] \
  [file join $repo_root zynq ultrascale+ rtl hft_types_pkg.vhd] \
  [file join $repo_root zynq ultrascale+ rtl moldudp64_decoder.vhd] \
  [file join $repo_root zynq ultrascale+ rtl itch_decoder.vhd] \
  [file join $repo_root zynq ultrascale+ rtl order_book.vhd] \
  [file join $repo_root zynq ultrascale+ rtl risk_guard.vhd] \
  [file join $repo_root zynq ultrascale+ rtl signal_engine.vhd] \
  [file join $repo_root zynq ultrascale+ rtl hft_pipeline.vhd] \
  [file join $repo_root zynq ultrascale+ rtl axis64_to_byte.vhd] \
  [file join $repo_root zynq ultrascale+ rtl udp_ipv4_rx.vhd] \
  [file join $repo_root zynq ultrascale+ rtl telemetry_udp_tx.vhd] \
  [file join $repo_root zynq ultrascale+ rtl myd_czu5ev_v2_hft_top.vhd]]

foreach source $sources {
  if {![file exists $source]} {
    fail "missing source '$source'"
  }
  read_vhdl -vhdl2008 $source
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
opt_design

report_timing_summary -delay_type max -max_paths 20 -report_unconstrained \
  -file [file join $output_dir timing_summary.rpt]
report_utilization -hierarchical \
  -file [file join $output_dir utilization_hierarchical.rpt]
report_methodology \
  -file [file join $output_dir methodology.rpt]
report_drc \
  -file [file join $output_dir drc.rpt]
write_checkpoint -force [file join $output_dir hft_pipeline_synth.dcp]

if {$goal eq "bitstream"} {
  fail "Bitstream/XSA generation is blocked until MYIR DDR/PS presets and SFP cage routing are verified"
}

puts "INFO: MYD-CZU5EV-V2 HFT pipeline out-of-context synthesis completed successfully."
exit 0
