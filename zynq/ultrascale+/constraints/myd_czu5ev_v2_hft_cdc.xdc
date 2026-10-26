# Clock-domain crossings between axis_clk and ps_clk. Sourced by build.tcl
# after synth_design, because the patterns name synthesized registers.
#
# Each cdc_snapshot instance moves a multi-bit word with a req/ack toggle
# handshake: the holding register is stable for at least two destination
# cycles before the destination captures it. Its data paths are therefore
# not timed as synchronous paths; instead they are bounded to one period of
# the faster clock and their skew is limited, so every bit is settled when
# the synchronized request arrives. The toggles themselves enter two-flop
# ASYNC_REG synchronizers.

set cdc_bound 6.400

foreach instance {config_cdc status_cdc} {
  set hold_regs [get_cells -hierarchical -filter "NAME =~ $instance/hold_reg*"]
  set captured_regs [get_cells -hierarchical -filter "NAME =~ $instance/captured_reg*"]
  set req_reg [get_cells -hierarchical -filter "NAME =~ $instance/req_reg"]
  set req_sync [get_cells -hierarchical -filter "NAME =~ $instance/req_sync_reg\[0\]"]
  set ack_reg [get_cells -hierarchical -filter "NAME =~ $instance/ack_reg"]
  set ack_sync [get_cells -hierarchical -filter "NAME =~ $instance/ack_sync_reg\[0\]"]

  if {[llength $hold_regs] == 0 || [llength $captured_regs] == 0} {
    error "cdc constraints: no holding/captured registers found for $instance"
  }

  set_max_delay -datapath_only -from $hold_regs -to $captured_regs $cdc_bound
  set_bus_skew -from $hold_regs -to $captured_regs $cdc_bound
  set_max_delay -datapath_only -from $req_reg -to $req_sync $cdc_bound
  set_max_delay -datapath_only -from $ack_reg -to $ack_sync $cdc_bound
}
