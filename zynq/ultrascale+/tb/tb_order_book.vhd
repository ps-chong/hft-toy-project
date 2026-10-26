-- order_store + tob_ladder: top of book through adds, executions, cancels,
-- deletes and replaces; same-set forwarding; overflow; flush.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library vunit_lib;
  context vunit_lib.vunit_context;

library hft;
  use hft.hft_types_pkg.all;

entity tb_order_book is
  generic (
    runner_cfg : string
  );
end entity tb_order_book;

architecture tb of tb_order_book is

  -- vunit_context also exports a byte_t.

  subtype byte_t is hft.hft_types_pkg.byte_t;

  constant clk_period : time    := 6.4 ns;
  constant anchor     : natural := 1000;

  signal clk   : std_logic := '0';
  signal rst   : std_logic := '1';
  signal flush : std_logic := '0';

  signal event   : market_event_t := market_event_reset;
  signal event_v : std_logic      := '0';

  signal delta_valid : std_logic;
  signal delta_buy   : std_logic;
  signal delta_add   : std_logic;
  signal delta_price : unsigned(31 downto 0);
  signal delta_qty   : unsigned(31 downto 0);
  signal flushing    : std_logic;
  signal overflow    : std_logic;

  signal bid_price  : unsigned(63 downto 0);
  signal bid_qty    : unsigned(31 downto 0);
  signal ask_price  : unsigned(63 downto 0);
  signal ask_qty    : unsigned(31 downto 0);
  signal book_valid : std_logic;
  signal oob        : std_logic;

  signal overflow_count : natural := 0;
  signal oob_count      : natural := 0;

begin

  clk <= not clk after clk_period / 2;

  store : entity hft.order_store
    generic map (
      set_bits => 2
    )
    port map (
      clk            => clk,
      rst            => rst,
      flush          => flush,
      event_in       => event,
      event_valid    => event_v,
      book_locate    => to_unsigned(1, 16),
      delta_valid    => delta_valid,
      delta_buy      => delta_buy,
      delta_add      => delta_add,
      delta_price    => delta_price,
      delta_qty      => delta_qty,
      flushing       => flushing,
      overflow_pulse => overflow,
      miss_pulse     => open
    );

  ladder : entity hft.tob_ladder
    port map (
      clk               => clk,
      rst               => rst,
      flush             => flush,
      anchor_price      => to_unsigned(anchor, 32),
      delta_valid       => delta_valid,
      delta_buy         => delta_buy,
      delta_add         => delta_add,
      delta_price       => delta_price,
      delta_qty         => delta_qty,
      best_bid_price    => bid_price,
      best_bid_qty      => bid_qty,
      best_ask_price    => ask_price,
      best_ask_qty      => ask_qty,
      book_valid        => book_valid,
      out_of_band_pulse => oob
    );

  count : process (clk) is
  begin

    if rising_edge(clk) then
      if (rst = '1') then
        overflow_count <= 0;
        oob_count      <= 0;
      else
        if (overflow = '1') then
          overflow_count <= overflow_count + 1;
        end if;
        if (oob = '1') then
          oob_count <= oob_count + 1;
        end if;
      end if;
    end if;

  end process count;

  main : process is

    procedure reset is
    begin

      rst <= '1';
      wait until rising_edge(clk);
      rst <= '0';
      wait until rising_edge(clk) and flushing = '0';
      wait until rising_edge(clk);

    end procedure reset;

    -- One event, then the one-cycle gap the feed always leaves.

    procedure send (
      kind      : byte_t;
      order_ref : natural;
      side      : byte_t  := side_none;
      qty       : natural := 0;
      price     : natural := 0;
      new_ref   : natural := 0;
      locate    : natural := 1
    ) is

      variable next_event : market_event_t;

    begin

      next_event                     := market_event_reset;
      next_event.kind                := kind;
      next_event.side                := side;
      next_event.order_reference     := to_unsigned(order_ref, 64);
      next_event.quantity            := to_unsigned(qty, 32);
      next_event.price               := to_unsigned(price, 64);
      next_event.new_order_reference := to_unsigned(new_ref, 64);
      next_event.stock_locate        := to_unsigned(locate, 16);
      event                          <= next_event;
      event_v                        <= '1';
      wait until rising_edge(clk);
      event_v                        <= '0';
      wait until rising_edge(clk);

    end procedure send;

    procedure settle is
    begin

      for cycle in 1 to 10 loop

        wait until rising_edge(clk);

      end loop;

      wait for 1 ns;

    end procedure settle;

    procedure check_top (
      bid_px : natural;
      bid_q  : natural;
      ask_px : natural;
      ask_q  : natural
    ) is
    begin

      check_equal(book_valid, '1', "book valid");
      check_equal(bid_price, to_unsigned(bid_px, 64), "best bid price");
      check_equal(bid_qty, to_unsigned(bid_q, 32), "best bid qty");
      check_equal(ask_price, to_unsigned(ask_px, 64), "best ask price");
      check_equal(ask_qty, to_unsigned(ask_q, 32), "best ask qty");

    end procedure check_top;

  begin

    test_runner_setup(runner, runner_cfg);

    while test_suite loop

      reset;

      if run("builds the top of book") then
        send(event_add, 1, side_buy, 100, 1500);
        send(event_add, 2, side_buy, 50, 1600);
        send(event_add, 3, side_sell, 70, 1700);
        send(event_add, 6, side_sell, 20, 1650);
        send(event_add, 7, side_buy, 5, 1600);
        settle;
        check_top(1600, 55, 1650, 20);
      elsif run("executions cancels and deletes reduce levels") then
        send(event_add, 1, side_buy, 100, 1500);
        send(event_add, 2, side_buy, 50, 1600);
        send(event_add, 3, side_sell, 70, 1700);
        send(event_add, 6, side_sell, 20, 1650);
        send(event_execute, 2, qty => 50);
        settle;
        check_top(1500, 100, 1650, 20);
        send(event_cancel, 6, qty => 15);
        settle;
        check_top(1500, 100, 1650, 5);
        send(event_delete, 6);
        settle;
        check_top(1500, 100, 1700, 70);
        -- Over-execution clamps at the resting quantity.
        send(event_execute, 1, qty => 500);
        settle;
        check_equal(book_valid, '0', "bid side emptied");
      elsif run("replace moves the order and keeps its side") then
        send(event_add, 1, side_buy, 100, 1500);
        send(event_add, 3, side_sell, 70, 1700);
        send(event_replace, 1, qty => 40, price => 1550, new_ref => 9);
        settle;
        check_top(1550, 40, 1700, 70);
        -- The original reference is gone, the new one is live.
        send(event_execute, 1, qty => 10);
        send(event_execute, 9, qty => 10);
        settle;
        check_top(1550, 30, 1700, 70);
      elsif run("back to back updates to one set forward correctly") then
        -- References 4 and 8 share set 0 with set_bits = 2.
        send(event_add, 4, side_buy, 10, 1500);
        send(event_add, 8, side_buy, 20, 1500);
        send(event_add, 3, side_sell, 70, 1700);
        settle;
        check_top(1500, 30, 1700, 70);
        send(event_execute, 4, qty => 10);
        send(event_execute, 8, qty => 5);
        settle;
        check_top(1500, 15, 1700, 70);
      elsif run("a full set overflows") then
        send(event_add, 4, side_buy, 10, 1500);
        send(event_add, 8, side_buy, 20, 1500);
        send(event_add, 12, side_buy, 30, 1500);
        settle;
        check_equal(overflow_count, 1);
      elsif run("other instruments and out of band prices are ignored") then
        send(event_add, 1, side_buy, 100, 1500, locate => 2);
        send(event_add, 2, side_buy, 100, 999);
        send(event_add, 3, side_sell, 100, anchor + 1024);
        settle;
        check_equal(book_valid, '0');
        check_equal(oob_count, 2);
      elsif run("flush empties the book") then
        send(event_add, 1, side_buy, 100, 1500);
        send(event_add, 3, side_sell, 70, 1700);
        settle;
        check_equal(book_valid, '1');
        flush <= '1';
        wait until rising_edge(clk);
        flush <= '0';
        wait until rising_edge(clk) and flushing = '0';
        settle;
        check_equal(book_valid, '0');
        -- A delete for a flushed order finds nothing.
        send(event_add, 5, side_buy, 10, 1400);
        send(event_add, 7, side_sell, 10, 1800);
        send(event_delete, 1);
        settle;
        check_top(1400, 10, 1800, 10);
      end if;

    end loop;

    test_runner_cleanup(runner);
    wait;

  end process main;

end architecture tb;
