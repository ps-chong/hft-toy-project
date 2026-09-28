library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library work;
  use work.hft_types_pkg.all;

entity myd_czu5ev_v2_hft_top is
  generic (
    local_mac        : std_logic_vector(47 downto 0) := x"020000000001";
    local_ip         : std_logic_vector(31 downto 0) := x"C0A80164";
    market_data_port : natural range 0 to 65535      := 47000;
    telemetry_mac    : std_logic_vector(47 downto 0) := x"020000000002";
    telemetry_ip     : std_logic_vector(31 downto 0) := x"C0A80165";
    telemetry_port   : natural range 0 to 65535      := 47001
  );
  port (
    axis_clk : in    std_logic;
    axis_rst : in    std_logic;

    s_rx_axis_tdata  : in    std_logic_vector(63 downto 0);
    s_rx_axis_tkeep  : in    std_logic_vector(7 downto 0);
    s_rx_axis_tvalid : in    std_logic;
    s_rx_axis_tlast  : in    std_logic;
    s_rx_axis_tuser  : in    std_logic;
    s_rx_axis_tready : out   std_logic;

    m_tx_axis_tdata  : out   std_logic_vector(63 downto 0);
    m_tx_axis_tkeep  : out   std_logic_vector(7 downto 0);
    m_tx_axis_tvalid : out   std_logic;
    m_tx_axis_tlast  : out   std_logic;
    m_tx_axis_tready : in    std_logic;

    sfp_rx_link_up : in    std_logic;
    sfp_tx_link_up : in    std_logic;

    m_event_kind      : out   std_logic_vector(7 downto 0);
    m_event_side      : out   std_logic_vector(7 downto 0);
    m_event_sequence  : out   std_logic_vector(63 downto 0);
    m_event_timestamp : out   std_logic_vector(47 downto 0);
    m_event_reference : out   std_logic_vector(63 downto 0);
    m_event_symbol    : out   std_logic_vector(63 downto 0);
    m_event_price     : out   std_logic_vector(63 downto 0);
    m_event_quantity  : out   std_logic_vector(31 downto 0);
    m_event_valid     : out   std_logic;
    m_event_ready     : in    std_logic;

    control_enable     : in    std_logic;
    control_kill       : in    std_logic;
    control_clear      : in    std_logic;
    risk_max_quantity  : in    std_logic_vector(31 downto 0);
    risk_price_floor   : in    std_logic_vector(63 downto 0);
    risk_price_ceiling : in    std_logic_vector(63 downto 0);

    signal_valid : out   std_logic;
    signal_side  : out   std_logic_vector(7 downto 0);
    signal_price : out   std_logic_vector(63 downto 0);
    signal_qty   : out   std_logic_vector(31 downto 0);

    status_killed     : out   std_logic;
    status_gap        : out   std_logic;
    status_malformed  : out   std_logic;
    status_unknown    : out   std_logic;
    status_overflow   : out   std_logic;
    status_rejected   : out   std_logic;
    expected_sequence : out   std_logic_vector(63 downto 0);
    udp_dropped_count : out   std_logic_vector(31 downto 0)
  );
end entity myd_czu5ev_v2_hft_top;

architecture rtl of myd_czu5ev_v2_hft_top is

  signal frame_data_i  : byte_t;
  signal frame_valid_i : std_logic;
  signal frame_sop_i   : std_logic;
  signal frame_eop_i   : std_logic;
  signal frame_ready_i : std_logic;

  signal payload_data_i  : byte_t;
  signal payload_valid_i : std_logic;
  signal payload_sop_i   : std_logic;
  signal payload_eop_i   : std_logic;
  signal payload_ready_i : std_logic;

  signal event_i             : market_event_t;
  signal event_valid_i       : std_logic;
  signal event_ready_i       : std_logic;
  signal telemetry_ready_i   : std_logic;
  signal signal_side_i       : byte_t;
  signal signal_price_i      : unsigned(63 downto 0);
  signal signal_qty_i        : unsigned(31 downto 0);
  signal expected_sequence_i : unsigned(63 downto 0);

  signal pipeline_killed_i    : std_logic;
  signal pipeline_gap_i       : std_logic;
  signal pipeline_malformed_i : std_logic;
  signal pipeline_unknown_i   : std_logic;
  signal pipeline_overflow_i  : std_logic;
  signal pipeline_rejected_i  : std_logic;

  signal udp_dropped_i   : unsigned(31 downto 0);
  signal udp_drop_i      : std_logic;
  signal udp_malformed_i : std_logic;
  signal network_fault_i : std_logic := '1';
  signal kill_i          : std_logic;
  signal status_flags_i  : std_logic_vector(7 downto 0);

begin

  m_event_kind      <= event_i.kind;
  m_event_side      <= event_i.side;
  m_event_sequence  <= std_logic_vector(event_i.feed_sequence);
  m_event_timestamp <= std_logic_vector(event_i.timestamp_ns);
  m_event_reference <= std_logic_vector(event_i.order_reference);
  m_event_symbol    <= event_i.symbol;
  m_event_price     <= std_logic_vector(event_i.price);
  m_event_quantity  <= std_logic_vector(event_i.quantity);
  signal_side       <= signal_side_i;
  signal_price      <= std_logic_vector(signal_price_i);
  signal_qty        <= std_logic_vector(signal_qty_i);
  expected_sequence <= std_logic_vector(expected_sequence_i);
  udp_dropped_count <= std_logic_vector(udp_dropped_i);

  event_ready_i <= m_event_ready and telemetry_ready_i;
  m_event_valid <= event_valid_i and telemetry_ready_i;

  kill_i <= control_kill or network_fault_i or not sfp_rx_link_up;

  status_killed    <= pipeline_killed_i;
  status_gap       <= pipeline_gap_i;
  status_malformed <= pipeline_malformed_i or udp_malformed_i;
  status_unknown   <= pipeline_unknown_i;
  status_overflow  <= pipeline_overflow_i;
  status_rejected  <= pipeline_rejected_i;

  status_flags_i(0) <= pipeline_killed_i;
  status_flags_i(1) <= pipeline_gap_i;
  status_flags_i(2) <= pipeline_malformed_i or udp_malformed_i;
  status_flags_i(3) <= pipeline_unknown_i;
  status_flags_i(4) <= pipeline_overflow_i;
  status_flags_i(5) <= pipeline_rejected_i;
  status_flags_i(6) <= udp_drop_i;
  status_flags_i(7) <= not sfp_tx_link_up;

  unpack_mac_stream : entity work.axis64_to_byte
    port map (
      clk           => axis_clk,
      rst           => axis_rst,
      s_axis_tdata  => s_rx_axis_tdata,
      s_axis_tkeep  => s_rx_axis_tkeep,
      s_axis_tvalid => s_rx_axis_tvalid,
      s_axis_tlast  => s_rx_axis_tlast,
      s_axis_tready => s_rx_axis_tready,
      byte_data     => frame_data_i,
      byte_valid    => frame_valid_i,
      byte_sop      => frame_sop_i,
      byte_eop      => frame_eop_i,
      byte_ready    => frame_ready_i
    );

  market_udp : entity work.udp_ipv4_rx
    generic map (
      destination_mac  => local_mac,
      destination_ip   => local_ip,
      destination_port => market_data_port
    )
    port map (
      clk             => axis_clk,
      rst             => axis_rst,
      frame_data      => frame_data_i,
      frame_valid     => frame_valid_i,
      frame_sop       => frame_sop_i,
      frame_eop       => frame_eop_i,
      frame_ready     => frame_ready_i,
      payload_data    => payload_data_i,
      payload_valid   => payload_valid_i,
      payload_sop     => payload_sop_i,
      payload_eop     => payload_eop_i,
      payload_ready   => payload_ready_i,
      dropped_count   => udp_dropped_i,
      drop_pulse      => udp_drop_i,
      malformed_pulse => udp_malformed_i
    );

  pipeline : entity work.hft_pipeline
    port map (
      clk               => axis_clk,
      rst               => axis_rst,
      packet_data       => payload_data_i,
      packet_valid      => payload_valid_i,
      packet_sop        => payload_sop_i,
      packet_eop        => payload_eop_i,
      packet_ready      => payload_ready_i,
      event_out         => event_i,
      event_valid       => event_valid_i,
      event_ready       => event_ready_i,
      trading_enable    => control_enable,
      external_kill     => kill_i,
      clear_faults      => control_clear,
      max_quantity      => unsigned(risk_max_quantity),
      price_floor       => unsigned(risk_price_floor),
      price_ceiling     => unsigned(risk_price_ceiling),
      signal_valid      => signal_valid,
      signal_side       => signal_side_i,
      signal_price      => signal_price_i,
      signal_qty        => signal_qty_i,
      killed            => pipeline_killed_i,
      gap_pulse         => pipeline_gap_i,
      malformed_pulse   => pipeline_malformed_i,
      unknown_pulse     => pipeline_unknown_i,
      overflow_pulse    => pipeline_overflow_i,
      risk_reject_pulse => pipeline_rejected_i,
      expected_sequence => expected_sequence_i
    );

  telemetry_udp : entity work.telemetry_udp_tx
    generic map (
      source_mac       => local_mac,
      destination_mac  => telemetry_mac,
      source_ip        => local_ip,
      destination_ip   => telemetry_ip,
      source_port      => market_data_port,
      destination_port => telemetry_port
    )
    port map (
      clk           => axis_clk,
      rst           => axis_rst,
      event_data    => event_i,
      event_valid   => event_valid_i and m_event_ready,
      event_ready   => telemetry_ready_i,
      status_flags  => status_flags_i,
      rx_dropped    => udp_dropped_i,
      m_axis_tdata  => m_tx_axis_tdata,
      m_axis_tkeep  => m_tx_axis_tkeep,
      m_axis_tvalid => m_tx_axis_tvalid,
      m_axis_tlast  => m_tx_axis_tlast,
      m_axis_tready => m_tx_axis_tready
    );

  network_faults : process (axis_clk) is
  begin

    if rising_edge(axis_clk) then
      if (axis_rst = '1') then
        network_fault_i <= '1';
      elsif ((control_clear = '1') and (control_kill = '0') and
             (sfp_rx_link_up = '1')) then
        network_fault_i <= '0';
      elsif ((sfp_rx_link_up = '0') or (udp_malformed_i = '1') or
             ((s_rx_axis_tvalid = '1') and (s_rx_axis_tready = '1') and
               (s_rx_axis_tlast = '1') and (s_rx_axis_tuser = '1'))) then
        network_fault_i <= '1';
      end if;
    end if;

  end process network_faults;

end architecture rtl;
