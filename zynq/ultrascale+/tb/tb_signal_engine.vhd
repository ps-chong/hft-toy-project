-- signal_engine: strategy results, change detection, registered select.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library vunit_lib;
  context vunit_lib.vunit_context;

library hft;
  use hft.hft_types_pkg.all;

entity tb_signal_engine is
  generic (
    runner_cfg : string
  );
end entity tb_signal_engine;

architecture tb of tb_signal_engine is

  constant clk_period : time := 6.4 ns;

  signal clk : std_logic := '0';
  signal rst : std_logic := '1';

  signal strategy   : std_logic_vector(7 downto 0) := x"00";
  signal bid_price  : unsigned(63 downto 0)        := to_unsigned(1000, 64);
  signal bid_qty    : unsigned(31 downto 0)        := to_unsigned(10, 32);
  signal ask_price  : unsigned(63 downto 0)        := to_unsigned(1010, 64);
  signal ask_qty    : unsigned(31 downto 0)        := to_unsigned(10, 32);
  signal book_valid : std_logic                    := '1';

  signal fired      : std_logic;
  signal proposal   : signal_t;
  signal fire_count : natural  := 0;
  signal last       : signal_t := signal_reset;

begin

  clk <= not clk after clk_period / 2;

  dut : entity hft.signal_engine
    port map (
      clk             => clk,
      rst             => rst,
      strategy_select => strategy,
      best_bid_price  => bid_price,
      best_bid_qty    => bid_qty,
      best_ask_price  => ask_price,
      best_ask_qty    => ask_qty,
      book_valid      => book_valid,
      signal_valid    => fired,
      signal_out      => proposal
    );

  count : process (clk) is
  begin

    if rising_edge(clk) then
      if (rst = '1') then
        fire_count <= 0;
      elsif (fired = '1') then
        fire_count <= fire_count + 1;
        last       <= proposal;
      end if;
    end if;

  end process count;

  main : process is

    procedure reset is
    begin

      rst <= '1';
      wait until rising_edge(clk);
      rst <= '0';

      for cycle in 1 to 4 loop

        wait until rising_edge(clk);

      end loop;

    end procedure reset;

    procedure settle is
    begin

      for cycle in 1 to 4 loop

        wait until rising_edge(clk);

      end loop;

      wait for 1 ns;

    end procedure settle;

  begin

    test_runner_setup(runner, runner_cfg);

    while test_suite loop

      strategy  <= x"00";
      bid_price <= to_unsigned(1000, 64);
      ask_price <= to_unsigned(1010, 64);
      bid_qty   <= to_unsigned(10, 32);
      ask_qty   <= to_unsigned(10, 32);
      reset;

      if run("imbalance buys at the ask and sells at the bid") then
        bid_qty <= to_unsigned(21, 32);
        settle;
        check_equal(fire_count, 1);
        check_equal(last.side, side_buy);
        check_equal(last.price, to_unsigned(1010, 64));
        bid_qty <= to_unsigned(10, 32);
        ask_qty <= to_unsigned(21, 32);
        settle;
        check_equal(fire_count, 2);
        check_equal(last.side, side_sell);
        check_equal(last.price, to_unsigned(1000, 64));
      elsif run("a static book fires once") then
        bid_qty <= to_unsigned(50, 32);
        settle;
        settle;
        check_equal(fire_count, 1);
      elsif run("balanced books do not fire") then
        bid_qty <= to_unsigned(20, 32);
        settle;
        check_equal(fire_count, 0, "exactly twice is not more than twice");
      elsif run("cross only strategy ignores imbalance") then
        strategy  <= x"01";
        settle;
        bid_qty   <= to_unsigned(50, 32);
        settle;
        check_equal(fire_count, 0);
        bid_price <= to_unsigned(1010, 64);
        settle;
        check_equal(fire_count, 1);
        check_equal(last.side, side_buy);
      elsif run("unknown strategies never fire") then
        strategy  <= x"07";
        settle;
        bid_price <= to_unsigned(1020, 64);
        settle;
        check_equal(fire_count, 0);
      end if;

    end loop;

    test_runner_cleanup(runner);
    wait;

  end process main;

end architecture tb;
