-- Resting-order store: 2-way set-associative table indexed by the low bits of
-- the ITCH order reference, held in UltraRAM.
--
-- Each event is one read-modify-write. The read is issued in the cycle the
-- event arrives, and the hit/miss decision and write-back happen in the next
-- cycle (stage S1). A write lands on the same edge as the following read, so
-- the RAM output would be stale for back-to-back accesses to one set: the
-- last write is kept in a forwarding register and overrides the RAM output
-- on a set match. Replace (U) runs as two micro-ops on consecutive cycles,
-- remove-original then add-new, and the second inherits the side of the
-- first. Events are at least two cycles apart (a MoldUDP64 message plus its
-- length prefix is longer than one beat), so the add-new slot is always free.
--
-- Every change to resting quantity leaves as one price-level delta for
-- tob_ladder. A full set on add raises overflow_pulse, which latches the
-- pipeline kill switch: the book would otherwise silently diverge.
--
-- flush clears every entry by sweeping the sets (2**set_bits cycles); events
-- arriving during the sweep are ignored and `flushing` stays high.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library work;
  use work.hft_types_pkg.all;

entity order_store is
  generic (
    set_bits : positive := 12
  );
  port (
    clk   : in    std_logic;
    rst   : in    std_logic;
    flush : in    std_logic;

    event_in    : in    market_event_t;
    event_valid : in    std_logic;
    -- Only events for this instrument update the book; 0 accepts all.
    book_locate : in    unsigned(15 downto 0);

    delta_valid : out   std_logic;
    delta_buy   : out   std_logic;
    delta_add   : out   std_logic;
    delta_price : out   unsigned(31 downto 0);
    delta_qty   : out   unsigned(31 downto 0);

    flushing       : out   std_logic;
    overflow_pulse : out   std_logic;
    miss_pulse     : out   std_logic
  );
end entity order_store;

architecture rtl of order_store is

  constant sets : positive := 2 ** set_bits;

  -- Entry layout: valid(129) buy(128) reference(127:64) price(63:32) qty(31:0).

  subtype entry_t is std_logic_vector(129 downto 0);

  constant entry_empty : entry_t := (others => '0');

  type way_ram_t is array (0 to sets - 1) of entry_t;

  signal way0 : way_ram_t := (others => entry_empty);
  signal way1 : way_ram_t := (others => entry_empty);

  attribute ram_style : string;
  attribute ram_style of way0 : signal is "ultra";
  attribute ram_style of way1 : signal is "ultra";

  type op_code_t is (op_none, op_add, op_reduce, op_delete, op_replace_remove, op_replace_add);

  type op_t is record
    code      : op_code_t;
    order_ref : unsigned(63 downto 0);
    buy       : std_logic;
    price     : unsigned(31 downto 0);
    qty       : unsigned(31 downto 0);
    -- Replace: the order that the add-new micro-op will create.
    new_order_ref : unsigned(63 downto 0);
    new_price     : unsigned(31 downto 0);
    new_qty       : unsigned(31 downto 0);
  end record op_t;

  constant op_idle : op_t :=
  (
    code          => op_none,
    order_ref     => (others => '0'),
    buy           => '0',
    price         => (others => '0'),
    qty           => (others => '0'),
    new_order_ref => (others => '0'),
    new_price     => (others => '0'),
    new_qty       => (others => '0')
  );

  signal s1 : op_t := op_idle;

  -- RAM read port (issued in S0, consumed in S1).
  signal read_set : unsigned(set_bits - 1 downto 0);
  signal rd0      : entry_t := entry_empty;
  signal rd1      : entry_t := entry_empty;

  -- RAM write port (driven from S1).
  signal wr_set  : unsigned(set_bits - 1 downto 0);
  signal wr_en0  : std_logic;
  signal wr_en1  : std_logic;
  signal wr_data : entry_t;

  -- One-deep forwarding of the previous S1 write.
  signal fwd_valid : std_logic                       := '0';
  signal fwd_set   : unsigned(set_bits - 1 downto 0) := (others => '0');
  signal fwd_way1  : std_logic                       := '0';
  signal fwd_data  : entry_t                         := entry_empty;

  -- Side of the order removed by a replace, for the add-new micro-op.
  signal replace_found : std_logic := '0';
  signal replace_buy   : std_logic := '0';

  signal sweeping  : std_logic                       := '1';
  signal sweep_set : unsigned(set_bits - 1 downto 0) := (others => '0');

  -- S1 decision, registered into the outputs.
  signal next_delta_valid : std_logic;
  signal next_delta_buy   : std_logic;
  signal next_delta_add   : std_logic;
  signal next_delta_price : unsigned(31 downto 0);
  signal next_delta_qty   : unsigned(31 downto 0);
  signal next_overflow    : std_logic;
  signal next_miss        : std_logic;
  signal next_found       : std_logic;
  signal next_found_buy   : std_logic;

  signal delta_valid_r : std_logic             := '0';
  signal delta_buy_r   : std_logic             := '0';
  signal delta_add_r   : std_logic             := '0';
  signal delta_price_r : unsigned(31 downto 0) := (others => '0');
  signal delta_qty_r   : unsigned(31 downto 0) := (others => '0');
  signal overflow_r    : std_logic             := '0';
  signal miss_r        : std_logic             := '0';

  function set_of (
    order_ref : unsigned(63 downto 0)
  ) return unsigned is
  begin

    return order_ref(set_bits - 1 downto 0);

  end function set_of;

  function make_entry (
    buy       : std_logic;
    order_ref : unsigned(63 downto 0);
    price     : unsigned(31 downto 0);
    qty       : unsigned(31 downto 0)
  ) return entry_t is
  begin

    return '1' & buy & std_logic_vector(order_ref) & std_logic_vector(price) & std_logic_vector(qty);

  end function make_entry;

  function hits (
    entry     : entry_t;
    order_ref : unsigned(63 downto 0)
  ) return boolean is
  begin

    return (entry(129) = '1') and (unsigned(entry(127 downto 64)) = order_ref);

  end function hits;

begin

  flushing       <= sweeping;
  delta_valid    <= delta_valid_r;
  delta_buy      <= delta_buy_r;
  delta_add      <= delta_add_r;
  delta_price    <= delta_price_r;
  delta_qty      <= delta_qty_r;
  overflow_pulse <= overflow_r;
  miss_pulse     <= miss_r;

  -- The add-new half of a replace reads its own set one cycle after the event.
  read_set <= set_of(s1.new_order_ref) when s1.code = op_replace_remove else
              set_of(event_in.order_reference);

  ram : process (clk) is
  begin

    if rising_edge(clk) then
      if (wr_en0 = '1') then
        way0(to_integer(wr_set)) <= wr_data;
      end if;
      if (wr_en1 = '1') then
        way1(to_integer(wr_set)) <= wr_data;
      end if;
      rd0 <= way0(to_integer(read_set));
      rd1 <= way1(to_integer(read_set));
    end if;

  end process ram;

  -- Stage S1: tag compare on the (forwarded) set contents, then write-back.
  decide : process (all) is

    variable e0      : entry_t;
    variable e1      : entry_t;
    variable set_v   : unsigned(set_bits - 1 downto 0);
    variable ref_v   : unsigned(63 downto 0);
    variable hit0    : boolean;
    variable hit1    : boolean;
    variable hit_e   : entry_t;
    variable held    : unsigned(31 downto 0);
    variable taken   : unsigned(31 downto 0);
    variable new_e   : entry_t;
    variable add_buy : std_logic;
    variable add_ref : unsigned(63 downto 0);
    variable add_px  : unsigned(31 downto 0);
    variable add_qty : unsigned(31 downto 0);
    variable do_add  : boolean;

  begin

    wr_en0           <= '0';
    wr_en1           <= '0';
    wr_data          <= entry_empty;
    next_delta_valid <= '0';
    next_delta_buy   <= '0';
    next_delta_add   <= '0';
    next_delta_price <= (others => '0');
    next_delta_qty   <= (others => '0');
    next_overflow    <= '0';
    next_miss        <= '0';
    next_found       <= '0';
    next_found_buy   <= '0';

    if (s1.code = op_replace_add) then
      ref_v := s1.new_order_ref;
    else
      ref_v := s1.order_ref;
    end if;

    set_v  := set_of(ref_v);
    wr_set <= set_v;

    e0 := rd0;
    e1 := rd1;

    if ((fwd_valid = '1') and (fwd_set = set_v)) then
      if (fwd_way1 = '1') then
        e1 := fwd_data;
      else
        e0 := fwd_data;
      end if;
    end if;

    hit0  := hits(e0, ref_v);
    hit1  := hits(e1, ref_v) and not hit0;
    hit_e := e1;

    if (hit0) then
      hit_e := e0;
    end if;

    held := unsigned(hit_e(31 downto 0));

    do_add  := false;
    add_buy := s1.buy;
    add_ref := s1.order_ref;
    add_px  := s1.price;
    add_qty := s1.qty;

    if (sweeping = '1') then
      wr_set  <= sweep_set;
      wr_en0  <= '1';
      wr_en1  <= '1';
      wr_data <= entry_empty;
    else

      case s1.code is

        when op_add =>

          do_add := true;

        when op_replace_add =>

          if (replace_found = '1') then
            do_add  := true;
            add_buy := replace_buy;
            add_ref := s1.new_order_ref;
            add_px  := s1.new_price;
            add_qty := s1.new_qty;
          end if;

        when op_reduce | op_delete | op_replace_remove =>

          if (hit0 or hit1) then
            taken := held;
            if ((s1.code = op_reduce) and (s1.qty < held)) then
              taken := s1.qty;
            end if;
            new_e := hit_e;
            if (held = taken) then
              new_e := entry_empty;
            else
              new_e(31 downto 0) := std_logic_vector(held - taken);
            end if;
            wr_data <= new_e;
            if (hit0) then
              wr_en0 <= '1';
            else
              wr_en1 <= '1';
            end if;
            next_delta_valid <= '1';
            next_delta_buy   <= hit_e(128);
            next_delta_add   <= '0';
            next_delta_price <= unsigned(hit_e(63 downto 32));
            next_delta_qty   <= taken;
            next_found       <= '1';
            next_found_buy   <= hit_e(128);
          else
            next_miss <= '1';
          end if;

        when op_none =>

          null;

      end case;

      -- Adds take the first free way; an already-resting reference is
      -- refused (the exchange never reuses a live one).
      if (do_add) then
        if (hit0 or hit1) then
          next_miss <= '1';
        elsif ((e0(129) = '1') and (e1(129) = '1')) then
          next_overflow <= '1';
        else
          wr_data <= make_entry(add_buy, add_ref, add_px, add_qty);
          if (e0(129) = '0') then
            wr_en0 <= '1';
          else
            wr_en1 <= '1';
          end if;
          next_delta_valid <= '1';
          next_delta_buy   <= add_buy;
          next_delta_add   <= '1';
          next_delta_price <= add_px;
          next_delta_qty   <= add_qty;
        end if;
      end if;
    end if;

  end process decide;

  -- Stage S0: classify the event into a micro-op and register state.
  classify : process (clk) is

    variable op : op_t;

  begin

    if rising_edge(clk) then
      delta_valid_r <= next_delta_valid;
      delta_buy_r   <= next_delta_buy;
      delta_add_r   <= next_delta_add;
      delta_price_r <= next_delta_price;
      delta_qty_r   <= next_delta_qty;
      overflow_r    <= next_overflow;
      miss_r        <= next_miss;

      fwd_valid <= wr_en0 or wr_en1;
      fwd_set   <= wr_set;
      fwd_way1  <= wr_en1 and not wr_en0;
      fwd_data  <= wr_data;

      if (s1.code = op_replace_remove) then
        replace_found <= next_found;
        replace_buy   <= next_found_buy;
      end if;

      if ((rst = '1') or (flush = '1')) then
        sweeping  <= '1';
        sweep_set <= (others => '0');
        s1        <= op_idle;
        fwd_valid <= '0';
      elsif (sweeping = '1') then
        s1 <= op_idle;
        if (sweep_set = sets - 1) then
          sweeping <= '0';
        end if;
        sweep_set <= sweep_set + 1;
      elsif (s1.code = op_replace_remove) then
        -- Second micro-op of the replace; the event slot is free (see header).
        assert event_valid = '0'
          report "order_store: event arrived in the replace add-new slot"
          severity failure;
        op      := s1;
        op.code := op_replace_add;
        s1      <= op;
      else
        op := op_idle;
        if ((event_valid = '1') and
            ((book_locate = 0) or (event_in.stock_locate = book_locate))) then
          op.order_ref := event_in.order_reference;
          op.buy       := '0';
          if (event_in.side = side_buy) then
            op.buy := '1';
          end if;
          op.price         := event_in.price(31 downto 0);
          op.qty           := event_in.quantity;
          op.new_order_ref := event_in.new_order_reference;
          op.new_price     := event_in.price(31 downto 0);
          op.new_qty       := event_in.quantity;

          case event_in.kind is

            when event_add =>

              op.code := op_add;

            when event_execute | event_cancel =>

              op.code := op_reduce;

            when event_delete =>

              op.code := op_delete;

            when event_replace =>

              op.code := op_replace_remove;

            when others =>

              op.code := op_none;

          end case;

        end if;
        s1 <= op;
      end if;
    end if;

  end process classify;

end architecture rtl;
