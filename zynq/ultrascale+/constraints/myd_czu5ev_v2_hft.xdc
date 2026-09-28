# MYD-CZU5EV-V2 core-only constraints. The public MYIR pinout defines the
# Bank 224 GTH pins, but an integrated PS/XSA build remains blocked until the
# vendor DDR/PS preset and physical SFP cage routing are verified.
create_clock -name axis_clk -period 6.400 [get_ports axis_clk]

set_input_delay 0.500 -clock axis_clk \
  [get_ports {s_rx_axis_tdata[*] s_rx_axis_tkeep[*] s_rx_axis_tvalid s_rx_axis_tlast s_rx_axis_tuser}]
set_output_delay 0.500 -clock axis_clk \
  [get_ports {s_rx_axis_tready m_tx_axis_* m_event_* signal_* status_* expected_sequence[*] udp_dropped_count[*]}]
