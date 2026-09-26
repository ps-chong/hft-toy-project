library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library vunit_lib;
context vunit_lib.vunit_context;

library hft;
use hft.hft_types_pkg.all;

entity tb_order_book is
  generic (runner_cfg : string);
end entity;

architecture tb of tb_order_book is
  constant CLK_PERIOD : time := 10 ns;
  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal event_i : market_event_t := MARKET_EVENT_RESET;
  signal event_valid : std_logic := '0';
  signal bid_price : unsigned(63 downto 0);
  signal bid_qty : unsigned(31 downto 0);
  signal ask_price : unsigned(63 downto 0);
  signal ask_qty : unsigned(31 downto 0);
  signal book_valid : std_logic;
  signal overflow : std_logic;
begin
  clk <= not clk after CLK_PERIOD / 2;

  dut : entity hft.order_book
    generic map (ORDER_CAPACITY => 2)
    port map (
      clk => clk,
      rst => rst,
      event_in => event_i,
      event_valid => event_valid,
      event_ready => open,
      best_bid_price => bid_price,
      best_bid_qty => bid_qty,
      best_ask_price => ask_price,
      best_ask_qty => ask_qty,
      book_valid => book_valid,
      overflow_pulse => overflow
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

    procedure send_event(
      kind : byte_t;
      reference : natural;
      side : byte_t;
      price : natural;
      quantity : natural
    ) is
    begin
      event_i <= MARKET_EVENT_RESET;
      event_i.kind <= kind;
      event_i.order_reference <= to_unsigned(reference, 64);
      event_i.side <= side;
      event_i.price <= to_unsigned(price, 64);
      event_i.quantity <= to_unsigned(quantity, 32);
      event_valid <= '1';
      wait until rising_edge(clk);
      event_valid <= '0';
      wait for 1 ns;
    end procedure;
  begin
    test_runner_setup(runner, runner_cfg);

    while test_suite loop
      if run("maintains top of book") then
        reset_dut;
        send_event(EVENT_ADD, 1, SIDE_BUY, 100, 20);
        check_equal(book_valid, '0');
        send_event(EVENT_ADD, 2, SIDE_SELL, 105, 30);
        check_equal(book_valid, '1');
        check_equal(bid_price, to_unsigned(100, 64));
        check_equal(bid_qty, to_unsigned(20, 32));
        check_equal(ask_price, to_unsigned(105, 64));
        check_equal(ask_qty, to_unsigned(30, 32));
        send_event(EVENT_CANCEL, 2, SIDE_SELL, 0, 10);
        check_equal(ask_qty, to_unsigned(20, 32));
      elsif run("reports capacity overflow") then
        reset_dut;
        send_event(EVENT_ADD, 1, SIDE_BUY, 100, 20);
        send_event(EVENT_ADD, 2, SIDE_SELL, 105, 30);
        event_i <= MARKET_EVENT_RESET;
        event_i.kind <= EVENT_ADD;
        event_i.order_reference <= to_unsigned(3, 64);
        event_i.side <= SIDE_BUY;
        event_i.price <= to_unsigned(99, 64);
        event_i.quantity <= to_unsigned(10, 32);
        event_valid <= '1';
        wait until rising_edge(clk);
        event_valid <= '0';
        wait for 1 ns;
        check_equal(overflow, '1');
      end if;
    end loop;

    test_runner_cleanup(runner);
    wait;
  end process;
end architecture;
