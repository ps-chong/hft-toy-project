library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library vunit_lib;
context vunit_lib.vunit_context;

library hft;
use hft.hft_types_pkg.all;

entity tb_itch_decoder is
  generic (runner_cfg : string);
end entity;

architecture tb of tb_itch_decoder is
  constant CLK_PERIOD : time := 10 ns;
  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal data : std_logic_vector(7 downto 0) := (others => '0');
  signal valid : std_logic := '0';
  signal sop : std_logic := '0';
  signal eop : std_logic := '0';
  signal sequence_i : unsigned(63 downto 0) := (others => '0');
  signal ready : std_logic;
  signal event_o : market_event_t;
  signal event_valid : std_logic;
  signal malformed : std_logic;
  signal unknown : std_logic;

  type byte_array_t is array (natural range <>) of std_logic_vector(7 downto 0);
  constant ADD_ORDER : byte_array_t := (
    x"41", x"00", x"01", x"00", x"02", x"00", x"00", x"00", x"01", x"E2", x"40",
    x"01", x"02", x"03", x"04", x"05", x"06", x"07", x"08", x"42",
    x"00", x"00", x"00", x"64",
    x"41", x"43", x"4D", x"45", x"20", x"20", x"20", x"20",
    x"00", x"12", x"D6", x"44"
  );
begin
  clk <= not clk after CLK_PERIOD / 2;

  dut : entity hft.itch_decoder
    port map (
      clk => clk,
      rst => rst,
      s_data => data,
      s_valid => valid,
      s_sop => sop,
      s_eop => eop,
      s_sequence => sequence_i,
      s_ready => ready,
      event_out => event_o,
      event_valid => event_valid,
      event_ready => '1',
      malformed_pulse => malformed,
      unknown_pulse => unknown
    );

  main : process
    procedure reset_dut is
    begin
      rst <= '1';
      valid <= '0';
      wait for 3 * CLK_PERIOD;
      wait until rising_edge(clk);
      rst <= '0';
    end procedure;

    procedure send_message(payload : byte_array_t) is
    begin
      for index in payload'range loop
        data <= payload(index);
        valid <= '1';
        if index = payload'low then sop <= '1'; else sop <= '0'; end if;
        if index = payload'high then eop <= '1'; else eop <= '0'; end if;
        loop
          wait until rising_edge(clk);
          exit when ready = '1';
        end loop;
      end loop;
      valid <= '0';
      sop <= '0';
      eop <= '0';
    end procedure;
  begin
    test_runner_setup(runner, runner_cfg);

    while test_suite loop
      if run("decodes add order") then
        reset_dut;
        sequence_i <= to_unsigned(77, 64);
        send_message(ADD_ORDER);
        wait for 1 ns;
        check_equal(event_valid, '1');
        check_equal(event_o.kind, EVENT_ADD);
        check_equal(event_o.side, SIDE_BUY);
        check_equal(event_o.feed_sequence, to_unsigned(77, 64));
        check_equal(event_o.timestamp_ns, to_unsigned(123456, 48));
        check_equal(event_o.order_reference, x"0102030405060708");
        check_equal(event_o.symbol, x"41434D4520202020");
        check_equal(event_o.quantity, to_unsigned(100, 32));
        check_equal(event_o.price, to_unsigned(1234500, 64));
        check_equal(malformed, '0');
      elsif run("rejects truncated message") then
        reset_dut;
        for index in 0 to 20 loop
          data <= ADD_ORDER(index);
          valid <= '1';
          if index = 0 then sop <= '1'; else sop <= '0'; end if;
          if index = 20 then eop <= '1'; else eop <= '0'; end if;
          wait until rising_edge(clk);
        end loop;
        valid <= '0';
        wait for 1 ns;
        check_equal(malformed, '1');
        check_equal(event_valid, '0');
      elsif run("counts unknown message") then
        reset_dut;
        data <= x"5A";
        valid <= '1';
        sop <= '1';
        eop <= '1';
        wait until rising_edge(clk);
        valid <= '0';
        wait for 1 ns;
        check_equal(unknown, '1');
        check_equal(event_valid, '0');
      end if;
    end loop;

    test_runner_cleanup(runner);
    wait;
  end process;
end architecture;
