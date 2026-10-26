-- MYD-CZU5EV-V2 HFT PL top level.
--
-- Clock domains:
--   axis_clk (156.25 MHz, 10G MAC user clock): the whole market-data path.
--   ps_clk   (100 MHz, PS AXI-Lite clock): the register block only.
--
-- Crossings, and nothing else crosses (report_cdc gates this in build.tcl):
--   config: ps_clk -> axis_clk through one cdc_snapshot, so risk limits,
--           control bits and book settings change atomically per COMMIT;
--   status: axis_clk -> ps_clk through one cdc_snapshot, reloaded whenever
--           the previous transfer completes, so counters read coherently;
--   SFP link-up levels: cdc_sync_bit; resets: reset_sync per domain.
--
-- The kill switch fails closed: it is set out of reset and until the first
-- commit, by any pipeline or network fault (link down, IPv4 header error,
-- MAC frame error), and by CONTROL.kill. Clearing it takes a commit with
-- CONTROL.clear_faults while no fault is present.

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
    telemetry_port   : natural range 0 to 65535      := 47001;
    book_set_bits    : positive                      := 12;
    -- axis_clk cycles without a market packet before STATUS.stale (~107 ms).
    stale_bits : positive := 24
  );
  port (
    axis_clk : in    std_logic;
    axis_rst : in    std_logic;
    ps_clk   : in    std_logic;
    ps_rstn  : in    std_logic;

    -- 10G MAC RX (no tready) and TX.
    s_rx_axis_tdata  : in    std_logic_vector(63 downto 0);
    s_rx_axis_tkeep  : in    std_logic_vector(7 downto 0);
    s_rx_axis_tvalid : in    std_logic;
    s_rx_axis_tlast  : in    std_logic;
    s_rx_axis_tuser  : in    std_logic;

    m_tx_axis_tdata  : out   std_logic_vector(63 downto 0);
    m_tx_axis_tkeep  : out   std_logic_vector(7 downto 0);
    m_tx_axis_tvalid : out   std_logic;
    m_tx_axis_tlast  : out   std_logic;
    m_tx_axis_tready : in    std_logic;

    -- Asynchronous to both clocks.
    sfp_rx_link_up : in    std_logic;
    sfp_tx_link_up : in    std_logic;

    -- Approved events towards the R5 ring writer (axis_clk).
    m_event_kind      : out   std_logic_vector(7 downto 0);
    m_event_side      : out   std_logic_vector(7 downto 0);
    m_event_flags     : out   std_logic_vector(7 downto 0);
    m_event_sequence  : out   std_logic_vector(63 downto 0);
    m_event_timestamp : out   std_logic_vector(47 downto 0);
    m_event_reference : out   std_logic_vector(63 downto 0);
    m_event_symbol    : out   std_logic_vector(63 downto 0);
    m_event_price     : out   std_logic_vector(63 downto 0);
    m_event_quantity  : out   std_logic_vector(31 downto 0);
    m_event_locate    : out   std_logic_vector(15 downto 0);
    m_event_new_ref   : out   std_logic_vector(63 downto 0);
    m_event_valid     : out   std_logic;
    m_event_ready     : in    std_logic;

    -- Approved PL signals (axis_clk).
    signal_valid : out   std_logic;
    signal_side  : out   std_logic_vector(7 downto 0);
    signal_price : out   std_logic_vector(63 downto 0);
    signal_qty   : out   std_logic_vector(31 downto 0);

    -- AXI4-Lite register slave (ps_clk).
    s_axil_awaddr  : in    std_logic_vector(15 downto 0);
    s_axil_awvalid : in    std_logic;
    s_axil_awready : out   std_logic;
    s_axil_wdata   : in    std_logic_vector(31 downto 0);
    s_axil_wvalid  : in    std_logic;
    s_axil_wready  : out   std_logic;
    s_axil_bresp   : out   std_logic_vector(1 downto 0);
    s_axil_bvalid  : out   std_logic;
    s_axil_bready  : in    std_logic;
    s_axil_araddr  : in    std_logic_vector(15 downto 0);
    s_axil_arvalid : in    std_logic;
    s_axil_arready : out   std_logic;
    s_axil_rdata   : out   std_logic_vector(31 downto 0);
    s_axil_rresp   : out   std_logic_vector(1 downto 0);
    s_axil_rvalid  : out   std_logic;
    s_axil_rready  : in    std_logic;

    -- Kill indicator (axis_clk), e.g. for an LED.
    status_killed : out   std_logic
  );
end entity myd_czu5ev_v2_hft_top;

architecture rtl of myd_czu5ev_v2_hft_top is

  constant config_bits : natural := 219;
  constant status_bits : natural := 292;

  signal rst          : std_logic;
  signal ps_rst_async : std_logic;
  signal ps_rst       : std_logic;

  signal rx_link_up : std_logic;
  signal tx_link_up : std_logic;

  signal rx_beat : axis64_t;

  -- Ingress timestamp: free-running cycle counter latched at frame start.
  signal cycle_counter : unsigned(63 downto 0) := (others => '0');
  signal frame_start   : unsigned(63 downto 0) := (others => '0');
  signal in_frame      : std_logic             := '0';

  signal payload       : axis64_t;
  signal payload_first : std_logic;
  signal udp_dropped   : unsigned(31 downto 0);
  signal udp_drop      : std_logic;
  signal udp_malformed : std_logic;
  signal udp_frame_err : std_logic;
  signal udp_packet    : std_logic;

  -- Committed configuration in axis_clk.
  signal config_ps      : std_logic_vector(config_bits - 1 downto 0);
  signal config_load    : std_logic;
  signal config_busy    : std_logic;
  signal config_axis    : std_logic_vector(config_bits - 1 downto 0);
  signal config_arrived : std_logic;
  signal committed      : std_logic := '0';

  signal cfg_enable   : std_logic                    := '0';
  signal cfg_kill     : std_logic                    := '1';
  signal clear_pulse  : std_logic                    := '0';
  signal cfg_limits   : risk_limits_t                :=
        (
        max_quantity  => (others => '0'),
        price_floor   => (others => '1'),
        price_ceiling => (others => '0')
       );
  signal cfg_locate   : unsigned(15 downto 0)        := (others => '0');
  signal cfg_strategy : std_logic_vector(7 downto 0) := (others => '0');
  signal cfg_anchor   : unsigned(31 downto 0)        := (others => '0');
  signal revision     : unsigned(31 downto 0)        := (others => '0');

  signal network_fault : std_logic;

  signal decoded_event  : market_event_t;
  signal approved_event : market_event_t;
  signal approved_valid : std_logic;
  signal event_i        : market_event_t;
  signal signal_i       : signal_t;
  signal expected       : unsigned(63 downto 0);

  signal killed_i    : std_logic;
  signal gap_i       : std_logic;
  signal malformed_i : std_logic;
  signal unknown_i   : std_logic;
  signal overflow_i  : std_logic;
  signal rejected_i  : std_logic;

  -- Status counters and flags (axis_clk).
  signal packet_count    : unsigned(63 downto 0)             := (others => '0');
  signal malformed_count : unsigned(31 downto 0)             := (others => '0');
  signal gap_count       : unsigned(31 downto 0)             := (others => '0');
  signal telemetry_drops : unsigned(31 downto 0);
  signal overflow_seen   : std_logic                         := '0';
  signal idle_cycles     : unsigned(stale_bits - 1 downto 0) := (others => '0');
  signal stale           : std_logic                         := '1';

  signal status_axis  : std_logic_vector(status_bits - 1 downto 0);
  signal status_busy  : std_logic;
  signal status_load  : std_logic;
  signal status_ps    : std_logic_vector(status_bits - 1 downto 0);
  signal status_fresh : std_logic;

  signal telemetry_flags : std_logic_vector(7 downto 0);

begin

  ---------------------------------------------------------------------------
  -- Resets and asynchronous levels
  ---------------------------------------------------------------------------

  ps_rst_async <= not ps_rstn;

  axis_reset : entity work.reset_sync
    port map (
      clk       => axis_clk,
      async_rst => axis_rst,
      sync_rst  => rst
    );

  ps_reset : entity work.reset_sync
    port map (
      clk       => ps_clk,
      async_rst => ps_rst_async,
      sync_rst  => ps_rst
    );

  rx_link_sync : entity work.cdc_sync_bit
    port map (
      dst_clk => axis_clk,
      dst_rst => rst,
      src     => sfp_rx_link_up,
      dst     => rx_link_up
    );

  tx_link_sync : entity work.cdc_sync_bit
    port map (
      dst_clk => axis_clk,
      dst_rst => rst,
      src     => sfp_tx_link_up,
      dst     => tx_link_up
    );

  ---------------------------------------------------------------------------
  -- Ingress
  ---------------------------------------------------------------------------

  rx_beat.data  <= s_rx_axis_tdata;
  rx_beat.keep  <= s_rx_axis_tkeep;
  rx_beat.valid <= s_rx_axis_tvalid;
  rx_beat.last  <= s_rx_axis_tlast;
  rx_beat.user  <= s_rx_axis_tuser;

  ingress_clock : process (axis_clk) is
  begin

    if rising_edge(axis_clk) then
      cycle_counter <= cycle_counter + 1;
      if (s_rx_axis_tvalid = '1') then
        if (in_frame = '0') then
          frame_start <= cycle_counter;
        end if;
        in_frame <= not s_rx_axis_tlast;
      end if;
      if (rst = '1') then
        cycle_counter <= (others => '0');
        in_frame      <= '0';
      end if;
    end if;

  end process ingress_clock;

  market_udp : entity work.eth_ipv4_udp_rx
    generic map (
      destination_mac  => local_mac,
      destination_ip   => local_ip,
      destination_port => market_data_port
    )
    port map (
      clk               => axis_clk,
      rst               => rst,
      s_axis            => rx_beat,
      m_payload         => payload,
      m_first           => payload_first,
      dropped_count     => udp_dropped,
      drop_pulse        => udp_drop,
      malformed_pulse   => udp_malformed,
      frame_error_pulse => udp_frame_err,
      packet_pulse      => udp_packet
    );

  network_fault <= (not rx_link_up) or udp_malformed or udp_frame_err;

  ---------------------------------------------------------------------------
  -- Configuration: ps_clk shadow registers -> committed snapshot
  ---------------------------------------------------------------------------

  registers : entity work.hft_regs_axil
    port map (
      clk          => ps_clk,
      rst          => ps_rst,
      s_awaddr     => s_axil_awaddr,
      s_awvalid    => s_axil_awvalid,
      s_awready    => s_axil_awready,
      s_wdata      => s_axil_wdata,
      s_wvalid     => s_axil_wvalid,
      s_wready     => s_axil_wready,
      s_bresp      => s_axil_bresp,
      s_bvalid     => s_axil_bvalid,
      s_bready     => s_axil_bready,
      s_araddr     => s_axil_araddr,
      s_arvalid    => s_axil_arvalid,
      s_arready    => s_axil_arready,
      s_rdata      => s_axil_rdata,
      s_rresp      => s_axil_rresp,
      s_rvalid     => s_axil_rvalid,
      s_rready     => s_axil_rready,
      config_data  => config_ps,
      config_load  => config_load,
      config_busy  => config_busy,
      status_data  => status_ps,
      status_fresh => status_fresh
    );

  config_cdc : entity work.cdc_snapshot
    generic map (
      width => config_bits
    )
    port map (
      src_clk   => ps_clk,
      src_rst   => ps_rst,
      src_data  => config_ps,
      src_load  => config_load,
      src_busy  => config_busy,
      dst_clk   => axis_clk,
      dst_rst   => rst,
      dst_data  => config_axis,
      dst_valid => config_arrived
    );

  -- Layout (hft_regs_axil, msb first): control(3) max_quantity(32)
  -- ceiling(64) floor(64) stock_locate(16) strategy(8) anchor(32).
  apply_config : process (axis_clk) is
  begin

    if rising_edge(axis_clk) then
      clear_pulse <= '0';
      if (rst = '1') then
        committed  <= '0';
        cfg_enable <= '0';
        cfg_kill   <= '1';
        revision   <= (others => '0');
        cfg_limits <=
        (
          max_quantity  => (others => '0'),
          price_floor   => (others => '1'),
          price_ceiling => (others => '0')
        );
      elsif (config_arrived = '1') then
        committed                <= '1';
        cfg_enable               <= config_axis(216);
        cfg_kill                 <= config_axis(217);
        clear_pulse              <= config_axis(218);
        cfg_limits.max_quantity  <= unsigned(config_axis(215 downto 184));
        cfg_limits.price_ceiling <= unsigned(config_axis(183 downto 120));
        cfg_limits.price_floor   <= unsigned(config_axis(119 downto 56));
        cfg_locate               <= unsigned(config_axis(55 downto 40));
        cfg_strategy             <= config_axis(39 downto 32);
        cfg_anchor               <= unsigned(config_axis(31 downto 0));
        revision                 <= revision + 1;
      end if;
    end if;

  end process apply_config;

  ---------------------------------------------------------------------------
  -- Pipeline
  ---------------------------------------------------------------------------

  pipeline : entity work.hft_pipeline
    generic map (
      set_bits => book_set_bits
    )
    port map (
      clk               => axis_clk,
      rst               => rst,
      s_payload         => payload,
      s_first           => payload_first,
      s_ingress_cycles  => frame_start,
      trading_enable    => cfg_enable,
      external_kill     => cfg_kill,
      clear_faults      => clear_pulse,
      external_fault    => network_fault,
      limits            => cfg_limits,
      book_locate       => cfg_locate,
      strategy_select   => cfg_strategy,
      anchor_price      => cfg_anchor,
      decoded_event     => decoded_event,
      decoded_valid     => open,
      approved_event    => approved_event,
      approved_valid    => approved_valid,
      event_out         => event_i,
      event_valid       => m_event_valid,
      event_ready       => m_event_ready,
      signal_valid      => signal_valid,
      signal_out        => signal_i,
      best_bid_price    => open,
      best_bid_qty      => open,
      best_ask_price    => open,
      best_ask_qty      => open,
      book_valid        => open,
      book_flushing     => open,
      killed            => killed_i,
      gap_pulse         => gap_i,
      duplicate_pulse   => open,
      malformed_pulse   => malformed_i,
      unknown_pulse     => unknown_i,
      overflow_pulse    => overflow_i,
      risk_reject_pulse => rejected_i,
      expected_sequence => expected
    );

  m_event_kind      <= event_i.kind;
  m_event_side      <= event_i.side;
  m_event_flags     <= event_i.flags;
  m_event_sequence  <= std_logic_vector(event_i.feed_sequence);
  m_event_timestamp <= std_logic_vector(event_i.timestamp_ns);
  m_event_reference <= std_logic_vector(event_i.order_reference);
  m_event_symbol    <= event_i.symbol;
  m_event_price     <= std_logic_vector(event_i.price);
  m_event_quantity  <= std_logic_vector(event_i.quantity);
  m_event_locate    <= std_logic_vector(event_i.stock_locate);
  m_event_new_ref   <= std_logic_vector(event_i.new_order_reference);
  signal_side       <= signal_i.side;
  signal_price      <= std_logic_vector(signal_i.price);
  signal_qty        <= std_logic_vector(signal_i.qty);
  status_killed     <= killed_i;

  ---------------------------------------------------------------------------
  -- Telemetry
  ---------------------------------------------------------------------------

  telemetry_flags <= (not tx_link_up) & udp_drop & rejected_i & overflow_i &
                     unknown_i & (malformed_i or udp_malformed) & gap_i & killed_i;

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
      rst           => rst,
      event_data    => approved_event,
      event_valid   => approved_valid,
      status_flags  => telemetry_flags,
      rx_dropped    => udp_dropped,
      drop_count    => telemetry_drops,
      m_axis_tdata  => m_tx_axis_tdata,
      m_axis_tkeep  => m_tx_axis_tkeep,
      m_axis_tvalid => m_tx_axis_tvalid,
      m_axis_tlast  => m_tx_axis_tlast,
      m_axis_tready => m_tx_axis_tready
    );

  ---------------------------------------------------------------------------
  -- Status: axis_clk counters -> coherent ps_clk snapshot
  ---------------------------------------------------------------------------

  counters : process (axis_clk) is
  begin

    if rising_edge(axis_clk) then
      if (rst = '1') then
        packet_count    <= (others => '0');
        malformed_count <= (others => '0');
        gap_count       <= (others => '0');
        overflow_seen   <= '0';
        idle_cycles     <= (others => '0');
        stale           <= '1';
      else
        if (udp_packet = '1') then
          packet_count <= packet_count + 1;
          idle_cycles  <= (others => '0');
          stale        <= '0';
        elsif (idle_cycles = (idle_cycles'range => '1')) then
          stale <= '1';
        else
          idle_cycles <= idle_cycles + 1;
        end if;
        if ((malformed_i = '1') or (udp_malformed = '1')) then
          malformed_count <= malformed_count + 1;
        end if;
        if (gap_i = '1') then
          gap_count <= gap_count + 1;
        end if;
        if (overflow_i = '1') then
          overflow_seen <= '1';
        elsif (clear_pulse = '1') then
          overflow_seen <= '0';
        end if;
      end if;
    end if;

  end process counters;

  -- Layout must match the aliases in hft_regs_axil.
  status_axis <= std_logic_vector(revision) &
                 std_logic_vector(telemetry_drops) &
                 std_logic_vector(gap_count) &
                 std_logic_vector(malformed_count) &
                 std_logic_vector(udp_dropped) &
                 std_logic_vector(packet_count) &
                 std_logic_vector(expected) &
                 (killed_i or not committed) & overflow_seen & stale & rx_link_up;

  status_load <= not status_busy;

  status_cdc : entity work.cdc_snapshot
    generic map (
      width => status_bits
    )
    port map (
      src_clk   => axis_clk,
      src_rst   => rst,
      src_data  => status_axis,
      src_load  => status_load,
      src_busy  => status_busy,
      dst_clk   => ps_clk,
      dst_rst   => ps_rst,
      dst_data  => status_ps,
      dst_valid => status_fresh
    );

end architecture rtl;
