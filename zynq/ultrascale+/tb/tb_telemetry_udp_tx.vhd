library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library vunit_lib;
  context vunit_lib.vunit_context;

library hft;
  use hft.hft_types_pkg.all;

entity tb_telemetry_udp_tx is
  generic (
    runner_cfg : string
  );
end entity tb_telemetry_udp_tx;

architecture tb of tb_telemetry_udp_tx is

  constant clk_period : time    := 10 ns;
  constant frame_size : natural := 106;

  type byte_array_t is array (0 to frame_size - 1) of std_logic_vector(7 downto 0);

  signal clk : std_logic := '0';
  signal rst : std_logic := '1';

  signal event_data  : market_event_t := market_event_reset;
  signal event_valid : std_logic      := '0';
  signal event_ready : std_logic;

  signal axis_data  : std_logic_vector(63 downto 0);
  signal axis_keep  : std_logic_vector(7 downto 0);
  signal axis_valid : std_logic;
  signal axis_last  : std_logic;
  signal axis_ready : std_logic := '1';

  signal captured       : byte_array_t                  := (others => (others => '0'));
  signal captured_count : natural range 0 to frame_size := 0;
  signal last_keep      : std_logic_vector(7 downto 0)  := (others => '0');
  signal frame_done     : std_logic                     := '0';

begin

  clk <= not clk after clk_period / 2;

  dut : entity hft.telemetry_udp_tx
    port map (
      clk           => clk,
      rst           => rst,
      event_data    => event_data,
      event_valid   => event_valid,
      event_ready   => event_ready,
      status_flags  => x"24",
      rx_dropped    => to_unsigned(3, 32),
      m_axis_tdata  => axis_data,
      m_axis_tkeep  => axis_keep,
      m_axis_tvalid => axis_valid,
      m_axis_tlast  => axis_last,
      m_axis_tready => axis_ready
    );

  monitor : process (clk) is

    variable count_i : natural;

  begin

    if rising_edge(clk) then
      if (rst = '1') then
        captured       <= (others => (others => '0'));
        captured_count <= 0;
        last_keep      <= (others => '0');
        frame_done     <= '0';
      elsif ((axis_valid = '1') and (axis_ready = '1')) then
        count_i := captured_count;

        for lane in 0 to 7 loop

          if ((axis_keep(lane) = '1') and (count_i < frame_size)) then
            captured(count_i) <= axis_data((lane * 8) + 7 downto lane * 8);
            count_i           := count_i + 1;
          end if;

        end loop;

        captured_count <= count_i;
        if (axis_last = '1') then
          last_keep  <= axis_keep;
          frame_done <= '1';
        end if;
      end if;
    end if;

  end process monitor;

  main : process is

    procedure reset_dut is
    begin

      rst         <= '1';
      event_valid <= '0';
      axis_ready  <= '1';
      wait for 3 * clk_period;
      wait until rising_edge(clk);
      rst         <= '0';

    end procedure reset_dut;

  begin

    test_runner_setup(runner, runner_cfg);

    while test_suite loop

      if run("serializes normalized event as UDP telemetry") then
        reset_dut;
        event_data.kind            <= EVENT_ADD;
        event_data.side            <= SIDE_BUY;
        event_data.feed_sequence   <= to_unsigned(1, 64);
        event_data.timestamp_ns    <= to_unsigned(123456, 48);
        event_data.order_reference <= unsigned'(x"0102030405060708");
        event_data.symbol          <= x"41434D4520202020";
        event_data.price           <= to_unsigned(1234500, 64);
        event_data.quantity        <= to_unsigned(100, 32);
        event_valid                <= '1';
        wait until rising_edge(clk) and event_ready = '1';
        event_valid                <= '0';
        wait until frame_done = '1';
        wait until rising_edge(clk);

        check_equal(captured_count, frame_size);
        check_equal(captured(0), std_logic_vector'(x"02"));
        check_equal(captured(5), std_logic_vector'(x"02"));
        check_equal(captured(12), std_logic_vector'(x"08"));
        check_equal(captured(13), std_logic_vector'(x"00"));
        check_equal(captured(16), std_logic_vector'(x"00"));
        check_equal(captured(17), std_logic_vector'(x"5C"));
        check_equal(captured(36), std_logic_vector'(x"B7"));
        check_equal(captured(37), std_logic_vector'(x"99"));
        check_equal(captured(42), std_logic_vector'(x"00"));
        check_equal(captured(43), std_logic_vector'(x"01"));
        check_equal(captured(44), std_logic_vector'(x"01"));
        check_equal(captured(45), EVENT_ADD);
        check_equal(captured(46), SIDE_BUY);
        check_equal(captured(47), std_logic_vector'(x"24"));
        check_equal(captured(97), std_logic_vector'(x"03"));
        check_equal(last_keep, std_logic_vector'(x"03"));
      elsif run("holds telemetry frame under backpressure") then
        reset_dut;
        event_data.kind <= EVENT_ADD;
        event_data.side <= SIDE_BUY;
        event_valid     <= '1';
        wait until rising_edge(clk) and event_ready = '1';
        event_valid     <= '0';
        axis_ready      <= '0';
        wait for 3 * clk_period;
        check_equal(axis_valid, '1');
        check_equal(event_ready, '0');
        check_equal(captured_count, 0);
        axis_ready      <= '1';
        wait until frame_done = '1';
        check_equal(captured_count, frame_size);
      end if;

    end loop;

    test_runner_cleanup(runner);
    wait;

  end process main;

end architecture tb;
