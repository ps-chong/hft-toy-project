library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library vunit_lib;
context vunit_lib.vunit_context;

library hft;
use hft.hft_types_pkg.all;

entity tb_risk_guard is
  generic (runner_cfg : string);
end entity;

architecture tb of tb_risk_guard is
  constant CLK_PERIOD : time := 10 ns;
  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal event_i : market_event_t := MARKET_EVENT_RESET;
  signal event_valid : std_logic := '0';
  signal event_ready : std_logic;
  signal approved : market_event_t;
  signal approved_valid : std_logic;
  signal reject : std_logic;
  signal kill : std_logic := '0';
begin
  clk <= not clk after CLK_PERIOD / 2;

  dut : entity hft.risk_guard
    port map (
      clk => clk,
      rst => rst,
      event_in => event_i,
      event_valid => event_valid,
      event_ready => event_ready,
      approved_event => approved,
      approved_valid => approved_valid,
      approved_ready => '1',
      trading_enable => '1',
      kill_latched => kill,
      max_quantity => to_unsigned(100, 32),
      price_floor => to_unsigned(10, 64),
      price_ceiling => to_unsigned(1000, 64),
      reject_pulse => reject
    );

  main : process
    procedure reset_dut is
    begin
      rst <= '1';
      event_valid <= '0';
      wait for 3 * CLK_PERIOD;
      wait until rising_edge(clk);
      rst <= '0';
    end procedure;

    procedure stage_add(quantity : natural; price : natural) is
    begin
      event_i <= MARKET_EVENT_RESET;
      event_i.kind <= EVENT_ADD;
      event_i.side <= SIDE_BUY;
      event_i.quantity <= to_unsigned(quantity, 32);
      event_i.price <= to_unsigned(price, 64);
      event_valid <= '1';
      wait for 1 ns;
    end procedure;
  begin
    test_runner_setup(runner, runner_cfg);

    while test_suite loop
      if run("approves bounded order") then
        reset_dut;
        stage_add(50, 100);
        check_equal(approved_valid, '1');
        check_equal(approved.quantity, to_unsigned(50, 32));
      elsif run("rejects oversized order") then
        reset_dut;
        stage_add(101, 100);
        check_equal(approved_valid, '0');
        wait until rising_edge(clk);
        event_valid <= '0';
        wait for 1 ns;
        check_equal(reject, '1');
      elsif run("kill blocks new order but permits cancel") then
        reset_dut;
        kill <= '1';
        stage_add(10, 100);
        check_equal(approved_valid, '0');
        event_valid <= '0';
        wait until rising_edge(clk);
        event_i.kind <= EVENT_CANCEL;
        event_valid <= '1';
        wait for 1 ns;
        check_equal(approved_valid, '1');
        kill <= '0';
      end if;
    end loop;

    test_runner_cleanup(runner);
    wait;
  end process;
end architecture;
