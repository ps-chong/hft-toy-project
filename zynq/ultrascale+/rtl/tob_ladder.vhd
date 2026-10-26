-- Top-of-book ladder: aggregated resting quantity per price level for a band
-- of 2**level_bits levels starting at the committed anchor price, one level
-- per 2**tick_shift price units.
--
-- Per side, the level quantities live in a distributed RAM read twice per
-- cycle (the read-modify-write of incoming deltas, and the best level)
-- and an occupancy bitmap lives in flops. The best bid is the highest
-- occupied bid level and the best ask the lowest occupied ask level, found
-- by a two-stage priority encoder (32 groups of 32 levels: per-group search,
-- then group select). A level's RAM quantity is only trusted while its
-- bitmap bit is set, so flush clears the book in one cycle without sweeping
-- the RAM.
--
-- Pipeline: L0 level computation, L1 RAM read, L2 update (forwarded against
-- the previous L2 write, since deltas can arrive on consecutive cycles), E1
-- group search, E2 group select, E3 best-level quantity read. Prices outside
-- the band are counted on out_of_band_pulse and not tracked.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

entity tob_ladder is
  generic (
    level_bits : positive := 10;
    tick_shift : natural  := 0
  );
  port (
    clk   : in    std_logic;
    rst   : in    std_logic;
    flush : in    std_logic;

    anchor_price : in    unsigned(31 downto 0);

    delta_valid : in    std_logic;
    delta_buy   : in    std_logic;
    delta_add   : in    std_logic;
    delta_price : in    unsigned(31 downto 0);
    delta_qty   : in    unsigned(31 downto 0);

    best_bid_price : out   unsigned(63 downto 0);
    best_bid_qty   : out   unsigned(31 downto 0);
    best_ask_price : out   unsigned(63 downto 0);
    best_ask_qty   : out   unsigned(31 downto 0);
    -- Both sides have at least one level.
    book_valid : out   std_logic;

    out_of_band_pulse : out   std_logic
  );
end entity tob_ladder;

architecture rtl of tob_ladder is

  constant levels     : positive := 2 ** level_bits;
  constant group_size : positive := 32;
  constant groups     : positive := levels / group_size;
  constant group_bits : positive := level_bits - 5;

  subtype level_t is unsigned(level_bits - 1 downto 0);

  type qty_ram_t is array (0 to levels - 1) of unsigned(31 downto 0);

  signal bid_ram : qty_ram_t := (others => (others => '0'));
  signal ask_ram : qty_ram_t := (others => (others => '0'));

  -- Three accesses per cycle (L1 read, L2 write, E3 best-level read) exceed
  -- a block RAM's two ports, so each side is distributed RAM (64 Kb total).
  attribute ram_style : string;
  attribute ram_style of bid_ram : signal is "distributed";
  attribute ram_style of ask_ram : signal is "distributed";

  -- Index 1 = bid, 0 = ask.

  type bitmap_t is array (0 to 1) of std_logic_vector(levels - 1 downto 0);

  signal occupied : bitmap_t := (others => (others => '0'));

  -- L0 -> L1 -> L2 delta pipeline.
  signal l1_valid : std_logic             := '0';
  signal l1_buy   : std_logic             := '0';
  signal l1_add   : std_logic             := '0';
  signal l1_level : level_t               := (others => '0');
  signal l1_qty   : unsigned(31 downto 0) := (others => '0');

  signal l2_valid : std_logic             := '0';
  signal l2_buy   : std_logic             := '0';
  signal l2_add   : std_logic             := '0';
  signal l2_level : level_t               := (others => '0');
  signal l2_qty   : unsigned(31 downto 0) := (others => '0');
  signal l2_old   : unsigned(31 downto 0) := (others => '0');

  signal fwd_valid : std_logic             := '0';
  signal fwd_buy   : std_logic             := '0';
  signal fwd_level : level_t               := (others => '0');
  signal fwd_qty   : unsigned(31 downto 0) := (others => '0');

  signal oob_r : std_logic := '0';

  -- Encoder stages.

  type group_index_t is array (0 to groups - 1) of unsigned(4 downto 0);

  signal e1_bid_any : std_logic_vector(groups - 1 downto 0) := (others => '0');
  signal e1_ask_any : std_logic_vector(groups - 1 downto 0) := (others => '0');
  signal e1_bid_hi  : group_index_t                         := (others => (others => '0'));
  signal e1_ask_lo  : group_index_t                         := (others => (others => '0'));

  signal e2_bid_level : level_t   := (others => '0');
  signal e2_ask_level : level_t   := (others => '0');
  signal e2_bid_any   : std_logic := '0';
  signal e2_ask_any   : std_logic := '0';

  signal e3_bid_qty   : unsigned(31 downto 0) := (others => '0');
  signal e3_ask_qty   : unsigned(31 downto 0) := (others => '0');
  signal e3_bid_price : unsigned(63 downto 0) := (others => '0');
  signal e3_ask_price : unsigned(63 downto 0) := (others => '0');
  signal e3_valid     : std_logic             := '0';

  function side_index (
    buy : std_logic
  ) return natural is
  begin

    if (buy = '1') then
      return 1;
    end if;

    return 0;

  end function side_index;

  function highest_set (
    bits : std_logic_vector(31 downto 0)
  ) return unsigned is

    variable index : unsigned(4 downto 0);

  begin

    index := (others => '0');

    for bit_index in 0 to 31 loop

      if (bits(bit_index) = '1') then
        index := to_unsigned(bit_index, 5);
      end if;

    end loop;

    return index;

  end function highest_set;

  function lowest_set (
    bits : std_logic_vector(31 downto 0)
  ) return unsigned is

    variable index : unsigned(4 downto 0);

  begin

    index := (others => '0');

    for bit_index in 31 downto 0 loop

      if (bits(bit_index) = '1') then
        index := to_unsigned(bit_index, 5);
      end if;

    end loop;

    return index;

  end function lowest_set;

  function level_price (
    anchor : unsigned(31 downto 0);
    level  : level_t
  ) return unsigned is
  begin

    return resize(anchor, 64) + shift_left(resize(level, 64), tick_shift);

  end function level_price;

begin

  best_bid_price    <= e3_bid_price;
  best_bid_qty      <= e3_bid_qty;
  best_ask_price    <= e3_ask_price;
  best_ask_qty      <= e3_ask_qty;
  book_valid        <= e3_valid;
  out_of_band_pulse <= oob_r;

  update : process (clk) is

    variable offset : unsigned(31 downto 0);
    variable band   : unsigned(31 downto 0);
    variable old    : unsigned(31 downto 0);
    variable result : unsigned(31 downto 0);
    variable side   : natural range 0 to 1;

  begin

    if rising_edge(clk) then
      oob_r <= '0';

      -- L0: band check and level index.
      offset   := delta_price - anchor_price;
      band     := shift_right(offset, tick_shift);
      l1_valid <= '0';
      if (delta_valid = '1') then
        if ((delta_price >= anchor_price) and (band < levels)) then
          l1_valid <= '1';
        else
          oob_r <= '1';
        end if;
      end if;
      l1_buy   <= delta_buy;
      l1_add   <= delta_add;
      l1_level <= band(level_bits - 1 downto 0);
      l1_qty   <= delta_qty;

      -- L1: update-path read.
      l2_valid <= l1_valid;
      l2_buy   <= l1_buy;
      l2_add   <= l1_add;
      l2_level <= l1_level;
      l2_qty   <= l1_qty;
      if (l1_buy = '1') then
        l2_old <= bid_ram(to_integer(l1_level));
      else
        l2_old <= ask_ram(to_integer(l1_level));
      end if;

      -- L2: read-modify-write. An unoccupied level holds zero regardless of
      -- what the RAM says.
      fwd_valid <= '0';
      if (l2_valid = '1') then
        side := side_index(l2_buy);
        old  := l2_old;
        if ((fwd_valid = '1') and (fwd_buy = l2_buy) and (fwd_level = l2_level)) then
          old := fwd_qty;
        end if;
        if (occupied(side)(to_integer(l2_level)) = '0') then
          old := (others => '0');
        end if;
        if (l2_add = '1') then
          result := old + l2_qty;
        elsif (l2_qty < old) then
          result := old - l2_qty;
        else
          result := (others => '0');
        end if;
        if (l2_buy = '1') then
          bid_ram(to_integer(l2_level)) <= result;
        else
          ask_ram(to_integer(l2_level)) <= result;
        end if;
        if (result = 0) then
          occupied(side)(to_integer(l2_level)) <= '0';
        else
          occupied(side)(to_integer(l2_level)) <= '1';
        end if;
        fwd_valid <= '1';
        fwd_buy   <= l2_buy;
        fwd_level <= l2_level;
        fwd_qty   <= result;
      end if;

      if ((rst = '1') or (flush = '1')) then
        occupied  <= (others => (others => '0'));
        l1_valid  <= '0';
        l2_valid  <= '0';
        fwd_valid <= '0';
      end if;
    end if;

  end process update;

  encode : process (clk) is

    variable bid_level : level_t;
    variable ask_level : level_t;
    variable bid_any   : std_logic;
    variable ask_any   : std_logic;

  begin

    if rising_edge(clk) then
      -- E1: per-group search.
      for g in 0 to groups - 1 loop

        e1_bid_any(g) <= or occupied(1)((g * group_size) + 31 downto g * group_size);
        e1_ask_any(g) <= or occupied(0)((g * group_size) + 31 downto g * group_size);
        e1_bid_hi(g)  <= highest_set(occupied(1)((g * group_size) + 31 downto g * group_size));
        e1_ask_lo(g)  <= lowest_set(occupied(0)((g * group_size) + 31 downto g * group_size));

      end loop;

      -- E2: highest bid group, lowest ask group.
      bid_level := (others => '0');
      ask_level := (others => '0');
      bid_any   := '0';
      ask_any   := '0';

      for g in 0 to groups - 1 loop

        if (e1_bid_any(g) = '1') then
          bid_level := to_unsigned(g, group_bits) & e1_bid_hi(g);
          bid_any   := '1';
        end if;

      end loop;

      for g in groups - 1 downto 0 loop

        if (e1_ask_any(g) = '1') then
          ask_level := to_unsigned(g, group_bits) & e1_ask_lo(g);
          ask_any   := '1';
        end if;

      end loop;

      e2_bid_level <= bid_level;
      e2_ask_level <= ask_level;
      e2_bid_any   <= bid_any;
      e2_ask_any   <= ask_any;

      -- E3: best-level read; price from the same level.
      e3_bid_qty   <= bid_ram(to_integer(e2_bid_level));
      e3_ask_qty   <= ask_ram(to_integer(e2_ask_level));
      e3_bid_price <= level_price(anchor_price, e2_bid_level);
      e3_ask_price <= level_price(anchor_price, e2_ask_level);
      e3_valid     <= e2_bid_any and e2_ask_any;

      if ((rst = '1') or (flush = '1')) then
        e1_bid_any <= (others => '0');
        e1_ask_any <= (others => '0');
        e2_bid_any <= '0';
        e2_ask_any <= '0';
        e3_valid   <= '0';
      end if;
    end if;

  end process encode;

end architecture rtl;
