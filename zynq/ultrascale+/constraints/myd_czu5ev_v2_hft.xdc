# MYD-CZU5EV-V2 core-only constraints. The public MYIR pinout defines the
# Bank 224 GTH pins, but an integrated PS/XSA build remains blocked until the
# vendor DDR/PS preset and physical SFP cage routing are verified.
create_clock -name axis_clk -period 6.400 [get_ports axis_clk]

set_input_delay 0.500 -clock axis_clk \
  [get_ports {s_rx_axis_tdata[*] s_rx_axis_tkeep[*] s_rx_axis_tvalid s_rx_axis_tlast s_rx_axis_tuser m_tx_axis_tready m_event_ready control_enable control_kill control_clear risk_max_quantity[*] risk_price_floor[*] risk_price_ceiling[*] sfp_rx_link_up sfp_tx_link_up}]
set_output_delay 0.500 -clock axis_clk \
  [get_ports {s_rx_axis_tready m_tx_axis_tdata[*] m_tx_axis_tkeep[*] m_tx_axis_tvalid m_tx_axis_tlast m_event_kind[*] m_event_side[*] m_event_sequence[*] m_event_timestamp[*] m_event_reference[*] m_event_symbol[*] m_event_price[*] m_event_quantity[*] m_event_valid signal_valid signal_side[*] signal_price[*] signal_qty[*] status_killed status_gap status_malformed status_unknown status_overflow status_rejected expected_sequence[*] udp_dropped_count[*]}]
