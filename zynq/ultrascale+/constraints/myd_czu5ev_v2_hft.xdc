# MYD-CZU5EV-V2 core-only constraints. The public MYIR pinout defines the
# Bank 224 GTH pins, but an integrated PS/XSA build remains blocked until the
# vendor DDR/PS preset and physical SFP cage routing are verified.
#
# Clock-domain crossing constraints live in myd_czu5ev_v2_hft_cdc.xdc,
# applied to the synthesized netlist (they name synthesized registers).

# 10G MAC user clock and PS AXI-Lite clock; unrelated.
create_clock -name axis_clk -period 6.400 [get_ports axis_clk]
create_clock -name ps_clk -period 10.000 [get_ports ps_clk]

# Out-of-context I/O budgets.
set_input_delay 0.500 -clock axis_clk \
  [get_ports {s_rx_axis_tdata[*] s_rx_axis_tkeep[*] s_rx_axis_tvalid s_rx_axis_tlast s_rx_axis_tuser m_tx_axis_tready m_event_ready}]
set_output_delay 0.500 -clock axis_clk \
  [get_ports {m_tx_axis_tdata[*] m_tx_axis_tkeep[*] m_tx_axis_tvalid m_tx_axis_tlast m_event_kind[*] m_event_side[*] m_event_flags[*] m_event_sequence[*] m_event_timestamp[*] m_event_reference[*] m_event_symbol[*] m_event_price[*] m_event_quantity[*] m_event_locate[*] m_event_new_ref[*] m_event_valid signal_valid signal_side[*] signal_price[*] signal_qty[*] status_killed}]

set_input_delay 1.000 -clock ps_clk \
  [get_ports {s_axil_awaddr[*] s_axil_awvalid s_axil_wdata[*] s_axil_wvalid s_axil_bready s_axil_araddr[*] s_axil_arvalid s_axil_rready}]
set_output_delay 1.000 -clock ps_clk \
  [get_ports {s_axil_awready s_axil_wready s_axil_bresp[*] s_axil_bvalid s_axil_arready s_axil_rdata[*] s_axil_rresp[*] s_axil_rvalid}]

# Asynchronous inputs, each synchronized in the destination domain
# (cdc_sync_bit for the SFP link levels, reset_sync for the resets).
set_false_path -from [get_ports {sfp_rx_link_up sfp_tx_link_up axis_rst ps_rstn}]
