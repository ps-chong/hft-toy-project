-- Top level across both clock domains: AXI-Lite configuration and commit
-- (ps_clk), market frames and events (axis_clk), status read back through
-- the status snapshot, telemetry, and link-loss fail-closed behaviour.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library vunit_lib;
  context vunit_lib.vunit_context;

library hft;
  use hft.hft_types_pkg.all;
  use hft.hft_protocol_pkg.all;
  use hft.hft_tb_pkg.all;

entity tb_myd_czu5ev_v2_hft_top is
  generic (
    runner_cfg : string;
    vector_dir : string
  );
end entity tb_myd_czu5ev_v2_hft_top;

architecture tb of tb_myd_czu5ev_v2_hft_top is

  constant axis_period : time := 6.4 ns;
  -- Deliberately not a rational multiple of axis_period.
  constant ps_period : time := 9.7 ns;

  signal axis_clk : std_logic := '0';
  signal ps_clk   : std_logic := '0';
  signal axis_rst : std_logic := '1';
  signal ps_rstn  : std_logic := '0';

  signal rx_beat : axis64_t := axis64_idle;

  signal tx_tdata  : std_logic_vector(63 downto 0);
  signal tx_tkeep  : std_logic_vector(7 downto 0);
  signal tx_tvalid : std_logic;
  signal tx_tlast  : std_logic;

  signal rx_link : std_logic := '1';

  signal ev_kind   : std_logic_vector(7 downto 0);
  signal ev_seq    : std_logic_vector(63 downto 0);
  signal ev_qty    : std_logic_vector(31 downto 0);
  signal ev_locate : std_logic_vector(15 downto 0);
  signal ev_valid  : std_logic;
  signal killed    : std_logic;

  signal awaddr  : std_logic_vector(15 downto 0) := (others => '0');
  signal awvalid : std_logic                     := '0';
  signal awready : std_logic;
  signal wdata   : std_logic_vector(31 downto 0) := (others => '0');
  signal wvalid  : std_logic                     := '0';
  signal wready  : std_logic;
  signal bvalid  : std_logic;
  signal bready  : std_logic                     := '0';
  signal araddr  : std_logic_vector(15 downto 0) := (others => '0');
  signal arvalid : std_logic                     := '0';
  signal arready : std_logic;
  signal rdata   : std_logic_vector(31 downto 0);
  signal rvalid  : std_logic;
  signal rready  : std_logic                     := '0';

  signal event_count     : natural                       := 0;
  signal last_kind       : std_logic_vector(7 downto 0)  := (others => '0');
  signal last_locate     : std_logic_vector(15 downto 0) := (others => '0');
  signal telemetry_count : natural                       := 0;

  -- axis_clk cycle stamps of the first frame and what it produced.
  signal cycle       : natural := 0;
  signal first_beat  : integer := -1;
  signal last_beat   : integer := -1;
  signal event_cycle : integer := -1;
  signal tx_cycle    : integer := -1;

begin

  axis_clk <= not axis_clk after axis_period / 2;
  ps_clk   <= not ps_clk after ps_period / 2;

  dut : entity hft.myd_czu5ev_v2_hft_top
    generic map (
      book_set_bits => 4,
      stale_bits    => 8
    )
    port map (
      axis_clk          => axis_clk,
      axis_rst          => axis_rst,
      ps_clk            => ps_clk,
      ps_rstn           => ps_rstn,
      s_rx_axis_tdata   => rx_beat.data,
      s_rx_axis_tkeep   => rx_beat.keep,
      s_rx_axis_tvalid  => rx_beat.valid,
      s_rx_axis_tlast   => rx_beat.last,
      s_rx_axis_tuser   => rx_beat.user,
      m_tx_axis_tdata   => tx_tdata,
      m_tx_axis_tkeep   => tx_tkeep,
      m_tx_axis_tvalid  => tx_tvalid,
      m_tx_axis_tlast   => tx_tlast,
      m_tx_axis_tready  => '1',
      sfp_rx_link_up    => rx_link,
      sfp_tx_link_up    => '1',
      m_event_kind      => ev_kind,
      m_event_side      => open,
      m_event_flags     => open,
      m_event_sequence  => ev_seq,
      m_event_timestamp => open,
      m_event_reference => open,
      m_event_symbol    => open,
      m_event_price     => open,
      m_event_quantity  => ev_qty,
      m_event_locate    => ev_locate,
      m_event_new_ref   => open,
      m_event_valid     => ev_valid,
      m_event_ready     => '1',
      signal_valid      => open,
      signal_side       => open,
      signal_price      => open,
      signal_qty        => open,
      s_axil_awaddr     => awaddr,
      s_axil_awvalid    => awvalid,
      s_axil_awready    => awready,
      s_axil_wdata      => wdata,
      s_axil_wvalid     => wvalid,
      s_axil_wready     => wready,
      s_axil_bresp      => open,
      s_axil_bvalid     => bvalid,
      s_axil_bready     => bready,
      s_axil_araddr     => araddr,
      s_axil_arvalid    => arvalid,
      s_axil_arready    => arready,
      s_axil_rdata      => rdata,
      s_axil_rresp      => open,
      s_axil_rvalid     => rvalid,
      s_axil_rready     => rready,
      status_killed     => killed
    );

  watch : process (axis_clk) is
  begin

    if rising_edge(axis_clk) then
      cycle <= cycle + 1;
      if (ev_valid = '1') then
        event_count <= event_count + 1;
        last_kind   <= ev_kind;
        last_locate <= ev_locate;
        if (event_cycle < 0) then
          event_cycle <= cycle;
        end if;
      end if;
      if ((tx_tvalid = '1') and (tx_tlast = '1')) then
        telemetry_count <= telemetry_count + 1;
      end if;
      if ((tx_tvalid = '1') and (tx_cycle < 0)) then
        tx_cycle <= cycle;
      end if;
      if ((rx_beat.valid = '1') and (first_beat < 0)) then
        first_beat <= cycle;
      end if;
      if ((rx_beat.valid = '1') and (rx_beat.last = '1') and (last_beat < 0)) then
        last_beat <= cycle;
      end if;
    end if;

  end process watch;

  main : process is

    variable add   : file_buffer_t;
    variable add_n : natural;
    variable value : std_logic_vector(31 downto 0);

    procedure axil_write (
      offset : natural;
      data   : natural
    ) is
    begin

      wait until rising_edge(ps_clk);
      awaddr  <= std_logic_vector(to_unsigned(offset, 16));
      wdata   <= std_logic_vector(to_unsigned(data, 32));
      awvalid <= '1';
      wvalid  <= '1';
      bready  <= '1';

      loop

        wait until rising_edge(ps_clk);
        exit when awready = '1';

      end loop;

      awvalid <= '0';
      wvalid  <= '0';
      bready  <= '0';

    end procedure axil_write;

    procedure axil_read (
      offset : natural;
      data   : out std_logic_vector(31 downto 0)
    ) is
    begin

      wait until rising_edge(ps_clk);
      araddr  <= std_logic_vector(to_unsigned(offset, 16));
      arvalid <= '1';
      rready  <= '1';

      loop

        wait until rising_edge(ps_clk);
        exit when arready = '1';

      end loop;

      data    := rdata;
      arvalid <= '0';
      rready  <= '0';

    end procedure axil_read;

    -- Status crosses back through a snapshot; give it a few round trips.

    procedure wait_status is
    begin

      for cycle in 1 to 40 loop

        wait until rising_edge(ps_clk);

      end loop;

    end procedure wait_status;

    procedure reset is
    begin

      axis_rst <= '1';
      ps_rstn  <= '0';
      wait for 100 ns;
      axis_rst <= '0';
      ps_rstn  <= '1';
      wait for 100 ns;

    end procedure reset;

    procedure configure_and_commit (
      control : natural
    ) is
    begin

      axil_write(REG_RISK_MAX_QTY, 1000);
      axil_write(REG_RISK_PRICE_FLOOR, 1);
      axil_write(REG_RISK_PRICE_CEILING, 1000000000);
      axil_write(REG_STOCK_LOCATE, 1);
      axil_write(REG_TOB_ANCHOR_PRICE, 1234000);
      axil_write(REG_CONTROL, control);
      axil_write(REG_COMMIT, 1);
      wait_status;

    end procedure configure_and_commit;

  begin

    test_runner_setup(runner, runner_cfg);
    read_bytes(vector_dir & "/mold_add_order.bin", add, add_n);

    while test_suite loop

      rx_link <= '1';
      reset;

      if run("identity registers") then
        axil_read(REG_BUILD_ID, value);
        check_equal(value, std_logic_vector'(x"48544654"));
        axil_read(REG_ABI_VERSION, value);
        check_equal(unsigned(value), to_unsigned(ABI_VERSION, 32));
      elsif run("fails closed until the first commit") then
        wait_status;
        check_equal(killed, '1');
        axil_read(REG_STATUS, value);
        check_equal(value(REG_STATUS_KILLED_BIT), '1');
        send_frame(axis_clk, rx_beat, udp_frame(add(0 to add_n - 1)));
        wait for 200 ns;
        check_equal(event_count, 0, "entries are blocked before the first commit");
        check_equal(telemetry_count, 0);
      elsif run("commit arms the pipeline and frames reach the event port") then
        -- enable | clear_faults
        configure_and_commit(2#101#);
        axil_read(REG_CONFIG_REVISION, value);
        check_equal(unsigned(value), to_unsigned(1, 32), "one commit applied");
        check_equal(killed, '0');
        send_frame(axis_clk, rx_beat, udp_frame(add(0 to add_n - 1)));
        wait for 200 ns;
        check_equal(event_count, 1);
        check_equal(last_kind, event_add);
        check_equal(last_locate, std_logic_vector(to_unsigned(1, 16)));
        check_equal(telemetry_count, 1, "one telemetry frame per approved event");
        wait_status;
        axil_read(REG_PACKET_COUNT_LO, value);
        check_equal(unsigned(value), to_unsigned(1, 32));
        axil_read(REG_EXPECTED_SEQUENCE_LO, value);
        check_equal(unsigned(value), to_unsigned(2, 32));
        axil_read(REG_STATUS, value);
        check_equal(value(REG_STATUS_KILLED_BIT), '0');
        check_equal(value(REG_STATUS_LINK_UP_BIT), '1');
        check_equal(value(REG_STATUS_STALE_BIT), '0');
      elsif run("link loss kills and stays killed until a clear") then
        configure_and_commit(2#101#);
        check_equal(killed, '0');
        rx_link <= '0';
        wait for 50 ns;
        check_equal(killed, '1', "link down");
        rx_link <= '1';
        wait for 50 ns;
        check_equal(killed, '1', "latched after the link returns");
        axil_write(REG_COMMIT, 1);
        wait_status;
        check_equal(killed, '0', "re-armed by a commit with clear_faults");
        axil_read(REG_CONFIG_REVISION, value);
        check_equal(unsigned(value), to_unsigned(2, 32));
      elsif run("wire to event port latency") then
        -- The figures quoted in docs/latency.md and the README.
        configure_and_commit(2#101#);
        send_frame(axis_clk, rx_beat, udp_frame(add(0 to add_n - 1)));
        wait for 300 ns;
        info("first beat " & integer'image(first_beat) & ", last beat " &
             integer'image(last_beat) & ", event " & integer'image(event_cycle) &
             ", telemetry " & integer'image(tx_cycle));
        check_equal(last_beat - first_beat, 12, "a 100-byte frame is 13 beats");
        check_equal(event_cycle - last_beat, 5, "last beat to R5 event port");
        check_equal(tx_cycle - event_cycle, 1, "event to first telemetry beat");
      elsif run("control kill holds the switch") then
        -- enable | kill | clear_faults: kill wins.
        configure_and_commit(2#111#);
        check_equal(killed, '1');
      end if;

    end loop;

    test_runner_cleanup(runner);
    wait;

  end process main;

end architecture tb;
