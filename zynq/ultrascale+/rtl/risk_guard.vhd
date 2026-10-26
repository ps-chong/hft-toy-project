-- PL pre-trade risk gate for both feed events and PL signals (one cycle).
--
-- Order-entry traffic (ADD events forwarded to the R5, and every PL signal)
-- passes only while trading is enabled, the kill switch is clear, and the
-- quantity and price sit inside the committed limits. Book lifecycle events
-- (execute, cancel, delete, replace, trade) always pass, so the R5 book
-- stays consistent while entries are blocked.
--
-- ITCH prices are 32-bit, so the comparisons are 32 bits wide. The 64-bit
-- limit registers are reduced once per commit to a low word plus a flag
-- (floor above 2**32 rejects everything; ceiling above 2**32 is no bound),
-- registered so that the limits do not lengthen the event path.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library work;
  use work.hft_types_pkg.all;

entity risk_guard is
  port (
    clk : in    std_logic;
    rst : in    std_logic;

    event_in    : in    market_event_t;
    event_valid : in    std_logic;
    signal_in   : in    signal_t;
    signal_vld  : in    std_logic;

    trading_enable : in    std_logic;
    killed         : in    std_logic;
    limits         : in    risk_limits_t;

    approved_event   : out   market_event_t;
    approved_valid   : out   std_logic;
    approved_signal  : out   signal_t;
    approved_sig_vld : out   std_logic;

    event_reject_pulse  : out   std_logic;
    signal_reject_pulse : out   std_logic
  );
end entity risk_guard;

architecture rtl of risk_guard is

  signal max_qty_r      : unsigned(31 downto 0) := (others => '0');
  signal floor_lo_r     : unsigned(31 downto 0) := (others => '1');
  signal floor_over_r   : std_logic             := '1';
  signal ceiling_lo_r   : unsigned(31 downto 0) := (others => '0');
  signal ceiling_over_r : std_logic             := '0';
  signal open_r         : std_logic             := '0';

  signal event_r      : market_event_t := market_event_reset;
  signal event_vld_r  : std_logic      := '0';
  signal signal_r     : signal_t       := signal_reset;
  signal signal_vld_r : std_logic      := '0';
  signal ev_reject_r  : std_logic      := '0';
  signal sig_reject_r : std_logic      := '0';

  function within (
    side         : byte_t;
    price        : unsigned(63 downto 0);
    qty          : unsigned(31 downto 0);
    max_qty      : unsigned(31 downto 0);
    floor_lo     : unsigned(31 downto 0);
    floor_over   : std_logic;
    ceiling_lo   : unsigned(31 downto 0);
    ceiling_over : std_logic
  ) return boolean is
  begin

    return ((side = side_buy) or (side = side_sell)) and
           (qty /= 0) and (qty <= max_qty) and
           (price(63 downto 32) = 0) and
           (floor_over = '0') and (price(31 downto 0) >= floor_lo) and
           ((ceiling_over = '1') or (price(31 downto 0) <= ceiling_lo));

  end function within;

begin

  approved_event      <= event_r;
  approved_valid      <= event_vld_r;
  approved_signal     <= signal_r;
  approved_sig_vld    <= signal_vld_r;
  event_reject_pulse  <= ev_reject_r;
  signal_reject_pulse <= sig_reject_r;

  gate : process (clk) is

    variable entry_ok  : boolean;
    variable signal_ok : boolean;

  begin

    if rising_edge(clk) then
      -- Limit reduction (changes only on commit).
      max_qty_r      <= limits.max_quantity;
      floor_lo_r     <= limits.price_floor(31 downto 0);
      floor_over_r   <= or limits.price_floor(63 downto 32);
      ceiling_lo_r   <= limits.price_ceiling(31 downto 0);
      ceiling_over_r <= or limits.price_ceiling(63 downto 32);
      open_r         <= trading_enable and not killed;

      event_vld_r  <= '0';
      signal_vld_r <= '0';
      ev_reject_r  <= '0';
      sig_reject_r <= '0';

      -- `killed` is used unregistered as well, so a kill blocks entries on
      -- the very cycle it asserts.
      entry_ok := (open_r = '1') and (killed = '0') and
                  within(event_in.side, event_in.price, event_in.quantity, max_qty_r,
                         floor_lo_r, floor_over_r, ceiling_lo_r, ceiling_over_r);

      signal_ok := (open_r = '1') and (killed = '0') and
                   within(signal_in.side, signal_in.price, signal_in.qty, max_qty_r,
                          floor_lo_r, floor_over_r, ceiling_lo_r, ceiling_over_r);

      if (event_valid = '1') then
        event_r <= event_in;
        if ((event_in.kind /= event_add) or entry_ok) then
          event_vld_r <= '1';
        else
          ev_reject_r <= '1';
        end if;
      end if;

      if (signal_vld = '1') then
        signal_r <= signal_in;
        if (signal_ok) then
          signal_vld_r <= '1';
        else
          sig_reject_r <= '1';
        end if;
      end if;

      if (rst = '1') then
        open_r       <= '0';
        event_vld_r  <= '0';
        signal_vld_r <= '0';
        ev_reject_r  <= '0';
        sig_reject_r <= '0';
      end if;
    end if;

  end process gate;

end architecture rtl;
