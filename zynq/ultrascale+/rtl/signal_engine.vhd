-- Top-of-book signal engine: every strategy evaluates in parallel each
-- cycle, and the committed strategy_select picks one registered result.
-- Switching strategy is therefore a one-cycle mux change, never a
-- reconfiguration of the datapath.
--
--   0 imbalance: buy at the ask when the book is crossed or the bid side
--     holds more than 2**imbalance_shift times the ask quantity; sell at the
--     bid in the mirror case (shift instead of multiply: no DSP, one LUT
--     level per bit)
--   1 cross only: buy at the ask when bid >= ask
--   others: no signals
--
-- A signal fires only when the top of book changed since the previous
-- cycle, so a static book cannot repeat a signal every cycle. Signals are
-- proposals: risk_guard gates them on the kill switch, enable and limits.
-- Latency: two cycles from the book.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library work;
  use work.hft_types_pkg.all;

entity signal_engine is
  generic (
    imbalance_shift : natural  := 1;
    signal_quantity : positive := 1
  );
  port (
    clk : in    std_logic;
    rst : in    std_logic;

    strategy_select : in    std_logic_vector(7 downto 0);

    best_bid_price : in    unsigned(63 downto 0);
    best_bid_qty   : in    unsigned(31 downto 0);
    best_ask_price : in    unsigned(63 downto 0);
    best_ask_qty   : in    unsigned(31 downto 0);
    book_valid     : in    std_logic;

    signal_valid : out   std_logic;
    signal_out   : out   signal_t
  );
end entity signal_engine;

architecture rtl of signal_engine is

  constant strategy_imbalance : natural := 0;
  constant strategy_cross     : natural := 1;
  constant strategy_count     : natural := 2;

  type candidates_t is array (0 to strategy_count - 1) of signal_t;

  signal candidate       : candidates_t                                  := (others => signal_reset);
  signal candidate_valid : std_logic_vector(strategy_count - 1 downto 0) := (others => '0');
  signal select_r        : std_logic_vector(7 downto 0)                  := (others => '0');

  signal previous_bid_price : unsigned(63 downto 0) := (others => '0');
  signal previous_ask_price : unsigned(63 downto 0) := (others => '0');
  signal previous_bid_qty   : unsigned(31 downto 0) := (others => '0');
  signal previous_ask_qty   : unsigned(31 downto 0) := (others => '0');

  signal valid_r  : std_logic := '0';
  signal signal_r : signal_t  := signal_reset;

begin

  signal_valid <= valid_r;
  signal_out   <= signal_r;

  evaluate : process (clk) is

    variable changed   : boolean;
    variable crossed   : boolean;
    variable bid_heavy : boolean;
    variable ask_heavy : boolean;
    variable buy       : signal_t;
    variable sell      : signal_t;

  begin

    if rising_edge(clk) then
      changed := (best_bid_price /= previous_bid_price) or
                 (best_ask_price /= previous_ask_price) or
                 (best_bid_qty /= previous_bid_qty) or
                 (best_ask_qty /= previous_ask_qty);

      crossed   := best_bid_price >= best_ask_price;
      bid_heavy := resize(best_bid_qty, 32 + imbalance_shift) >
                   shift_left(resize(best_ask_qty, 32 + imbalance_shift), imbalance_shift);
      ask_heavy := resize(best_ask_qty, 32 + imbalance_shift) >
                   shift_left(resize(best_bid_qty, 32 + imbalance_shift), imbalance_shift);

      buy  :=
      (
        side => side_buy,
        price => best_ask_price,
        qty => to_unsigned(signal_quantity, 32)
      );
      sell :=
      (
        side => side_sell,
        price => best_bid_price,
        qty => to_unsigned(signal_quantity, 32)
      );

      candidate_valid <= (others => '0');

      if ((book_valid = '1') and changed) then
        if (crossed or bid_heavy) then
          candidate(strategy_imbalance)       <= buy;
          candidate_valid(strategy_imbalance) <= '1';
        elsif (ask_heavy) then
          candidate(strategy_imbalance)       <= sell;
          candidate_valid(strategy_imbalance) <= '1';
        end if;

        if (crossed) then
          candidate(strategy_cross)       <= buy;
          candidate_valid(strategy_cross) <= '1';
        end if;
      end if;

      previous_bid_price <= best_bid_price;
      previous_ask_price <= best_ask_price;
      previous_bid_qty   <= best_bid_qty;
      previous_ask_qty   <= best_ask_qty;
      select_r           <= strategy_select;

      -- Registered select.
      valid_r <= '0';
      if (unsigned(select_r) < strategy_count) then
        valid_r  <= candidate_valid(to_integer(unsigned(select_r)));
        signal_r <= candidate(to_integer(unsigned(select_r)));
      end if;

      if (rst = '1') then
        candidate_valid    <= (others => '0');
        valid_r            <= '0';
        previous_bid_price <= (others => '0');
        previous_ask_price <= (others => '0');
        previous_bid_qty   <= (others => '0');
        previous_ask_qty   <= (others => '0');
      end if;
    end if;

  end process evaluate;

end architecture rtl;
