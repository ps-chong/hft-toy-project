library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library vunit_lib;
  context vunit_lib.vunit_context;

library hft;

entity tb_myd_czu5ev_v2_hft_top is
  generic (
    runner_cfg : string
  );
end entity tb_myd_czu5ev_v2_hft_top;

architecture tb of tb_myd_czu5ev_v2_hft_top is

  constant clk_period : time := 10 ns;

  signal clk : std_logic := '0';
  signal rst : std_logic := '1';

  signal control_clear : std_logic := '0';
  signal rx_link_up    : std_logic := '0';
  signal tx_link_up    : std_logic := '0';
  signal killed        : std_logic;

begin

  clk <= not clk after clk_period / 2;

  dut : entity hft.myd_czu5ev_v2_hft_top
    port map (
      axis_clk           => clk,
      axis_rst           => rst,
      s_rx_axis_tdata    => (others => '0'),
      s_rx_axis_tkeep    => (others => '0'),
      s_rx_axis_tvalid   => '0',
      s_rx_axis_tlast    => '0',
      s_rx_axis_tuser    => '0',
      s_rx_axis_tready   => open,
      m_tx_axis_tdata    => open,
      m_tx_axis_tkeep    => open,
      m_tx_axis_tvalid   => open,
      m_tx_axis_tlast    => open,
      m_tx_axis_tready   => '1',
      sfp_rx_link_up     => rx_link_up,
      sfp_tx_link_up     => tx_link_up,
      m_event_kind       => open,
      m_event_side       => open,
      m_event_sequence   => open,
      m_event_timestamp  => open,
      m_event_reference  => open,
      m_event_symbol     => open,
      m_event_price      => open,
      m_event_quantity   => open,
      m_event_valid      => open,
      m_event_ready      => '1',
      control_enable     => '1',
      control_kill       => '0',
      control_clear      => control_clear,
      risk_max_quantity  => std_logic_vector(to_unsigned(1000, 32)),
      risk_price_floor   => std_logic_vector(to_unsigned(1, 64)),
      risk_price_ceiling => std_logic_vector(to_unsigned(1000000000, 64)),
      signal_valid       => open,
      signal_side        => open,
      signal_price       => open,
      signal_qty         => open,
      status_killed      => killed,
      status_gap         => open,
      status_malformed   => open,
      status_unknown     => open,
      status_overflow    => open,
      status_rejected    => open,
      expected_sequence  => open,
      udp_dropped_count  => open
    );

  main : process is
  begin

    test_runner_setup(runner, runner_cfg);

    while test_suite loop

      if run("fails closed on RX link loss and requires explicit clear") then
        rst <= '1';
        wait for 3 * clk_period;
        wait until rising_edge(clk);
        rst <= '0';
        wait for 1 ns;
        check_equal(killed, '1');

        rx_link_up    <= '1';
        tx_link_up    <= '1';
        control_clear <= '1';
        wait for 3 * clk_period;
        wait until rising_edge(clk);
        control_clear <= '0';
        wait for 1 ns;
        check_equal(killed, '0');

        rx_link_up <= '0';
        wait for 1 ns;
        check_equal(killed, '1');

        rx_link_up <= '1';
        wait for 2 * clk_period;
        check_equal(killed, '1');
      end if;

    end loop;

    test_runner_cleanup(runner);
    wait;

  end process main;

end architecture tb;
