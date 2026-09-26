# The packet pipeline is synthesized out-of-context until the generated ZynqMP
# block design supplies its AXI clock/reset and DMA or 10G MAC stream.
create_clock -name axis_clk -period 6.400 [get_ports axis_clk]

set_input_delay  0.500 -clock axis_clk [get_ports {s_axis_tdata[*] s_axis_tvalid s_axis_tuser s_axis_tlast}]
set_output_delay 0.500 -clock axis_clk [get_ports {s_axis_tready m_event_* signal_* status_* expected_sequence[*]}]
