library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library vunit_lib;
context vunit_lib.vunit_context;

library hft;
use hft.hft_types_pkg.all;

entity tb_hft_pipeline is
  generic (runner_cfg : string);
end entity;

architecture tb of tb_hft_pipeline is
  constant CLK_PERIOD : time := 10 ns;
  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal packet_data : byte_t := (others => '0');
  signal packet_valid : std_logic := '0';
  signal packet_sop : std_logic := '0';
  signal packet_eop : std_logic := '0';
  signal packet_ready : std_logic;
  signal event_o : market_event_t;
  signal event_valid : std_logic;
  signal clear_faults : std_logic := '0';
  signal killed : std_logic;
  signal gap : std_logic;
  signal malformed : std_logic;
  signal unknown : std_logic;
  signal overflow : std_logic;
  signal rejected : std_logic;
  signal expected : unsigned(63 downto 0);

  type byte_array_t is array (natural range <>) of byte_t;
  constant MOLD_ADD : byte_array_t := (
    x"54", x"45", x"53", x"54", x"53", x"45", x"53", x"53", x"30", x"31",
    x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"01", x"00", x"01",
    x"00", x"24",
    x"41", x"00", x"01", x"00", x"02", x"00", x"00", x"00", x"01", x"E2", x"40",
    x"01", x"02", x"03", x"04", x"05", x"06", x"07", x"08", x"42",
    x"00", x"00", x"00", x"64",
    x"41", x"43", x"4D", x"45", x"20", x"20", x"20", x"20",
    x"00", x"12", x"D6", x"44"
  );
begin
  clk <= not clk after CLK_PERIOD / 2;

  dut : entity hft.hft_pipeline
    generic map (ORDER_CAPACITY => 4)
    port map (
      clk => clk,
      rst => rst,
      packet_data => packet_data,
      packet_valid => packet_valid,
      packet_sop => packet_sop,
      packet_eop => packet_eop,
      packet_ready => packet_ready,
      event_out => event_o,
      event_valid => event_valid,
      event_ready => '1',
      trading_enable => '1',
      external_kill => '0',
      clear_faults => clear_faults,
      max_quantity => to_unsigned(1000, 32),
      price_floor => to_unsigned(1, 64),
      price_ceiling => to_unsigned(1000000000, 64),
      signal_valid => open,
      signal_side => open,
      signal_price => open,
      signal_qty => open,
      killed => killed,
      gap_pulse => gap,
      malformed_pulse => malformed,
      unknown_pulse => unknown,
      overflow_pulse => overflow,
      risk_reject_pulse => rejected,
      expected_sequence => expected
    );

  main : process
    procedure reset_and_arm is
    begin
      rst <= '1';
      packet_valid <= '0';
      wait for 3 * CLK_PERIOD;
      wait until rising_edge(clk);
      rst <= '0';
      clear_faults <= '1';
      wait until rising_edge(clk);
      clear_faults <= '0';
      wait for 1 ns;
      check_equal(killed, '0');
    end procedure;

    procedure send_packet(payload : byte_array_t) is
    begin
      for index in payload'range loop
        packet_data <= payload(index);
        packet_valid <= '1';
        if index = payload'low then packet_sop <= '1'; else packet_sop <= '0'; end if;
        if index = payload'high then packet_eop <= '1'; else packet_eop <= '0'; end if;
        loop
          wait until rising_edge(clk);
          exit when packet_ready = '1';
        end loop;
      end loop;
      packet_valid <= '0';
      packet_sop <= '0';
      packet_eop <= '0';
    end procedure;
  begin
    test_runner_setup(runner, runner_cfg);

    while test_suite loop
      if run("packet to normalized event") then
        reset_and_arm;
        send_packet(MOLD_ADD);
        wait for 1 ns;
        check_equal(event_valid, '1');
        check_equal(event_o.kind, EVENT_ADD);
        check_equal(event_o.quantity, to_unsigned(100, 32));
        check_equal(event_o.price, to_unsigned(1234500, 64));
        check_equal(event_o.feed_sequence, to_unsigned(1, 64));
        check_equal(expected, to_unsigned(2, 64));
        check_equal(killed, '0');
        check_equal(malformed, '0');
      end if;
    end loop;

    test_runner_cleanup(runner);
    wait;
  end process;
end architecture;
