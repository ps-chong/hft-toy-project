library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library work;
  use work.hft_types_pkg.all;

entity signal_engine is
  generic (
    imbalance_ratio : positive := 2;
    signal_quantity : positive := 1
  );
  port (
    clk : in    std_logic;
    rst : in    std_logic;

    best_bid_price : in    unsigned(63 downto 0);
    best_bid_qty   : in    unsigned(31 downto 0);
    best_ask_price : in    unsigned(63 downto 0);
    best_ask_qty   : in    unsigned(31 downto 0);
    book_valid     : in    std_logic;

    signal_valid : out   std_logic;
    signal_side  : out   byte_t;
    signal_price : out   unsigned(63 downto 0);
    signal_qty   : out   unsigned(31 downto 0)
  );
end entity signal_engine;

architecture rtl of signal_engine is

  signal previous_bid_price : unsigned(63 downto 0) := (others => '0');
  signal previous_ask_price : unsigned(63 downto 0) := (others => '0');
  signal previous_bid_qty   : unsigned(31 downto 0) := (others => '0');
  signal previous_ask_qty   : unsigned(31 downto 0) := (others => '0');

begin

  process (clk) is

    variable changed : boolean;

  begin

    if rising_edge(clk) then
      signal_valid <= '0';

      if (rst = '1') then
        previous_bid_price <= (others => '0');
        previous_ask_price <= (others => '0');
        previous_bid_qty   <= (others => '0');
        previous_ask_qty   <= (others => '0');
        signal_side        <= (others => '0');
        signal_price       <= (others => '0');
        signal_qty         <= (others => '0');
      else
        changed := best_bid_price /= previous_bid_price or
                   best_ask_price /= previous_ask_price or
                   best_bid_qty /= previous_bid_qty or
                   best_ask_qty /= previous_ask_qty;

        if (book_valid = '1' and changed) then
          if (best_bid_price >= best_ask_price or
              resize(best_bid_qty, 64) >
              resize(best_ask_qty, 64) * imbalance_ratio) then
            signal_valid <= '1';
            signal_side  <= SIDE_BUY;
            signal_price <= best_ask_price;
            signal_qty   <= to_unsigned(signal_quantity, signal_qty'length);
          elsif (resize(best_ask_qty, 64) >
                 resize(best_bid_qty, 64) * imbalance_ratio) then
            signal_valid <= '1';
            signal_side  <= SIDE_SELL;
            signal_price <= best_bid_price;
            signal_qty   <= to_unsigned(signal_quantity, signal_qty'length);
          end if;
        end if;

        previous_bid_price <= best_bid_price;
        previous_ask_price <= best_ask_price;
        previous_bid_qty   <= best_bid_qty;
        previous_ask_qty   <= best_ask_qty;
      end if;
    end if;

  end process;

end architecture rtl;
