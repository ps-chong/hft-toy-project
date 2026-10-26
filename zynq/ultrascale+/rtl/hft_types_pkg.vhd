-- Shared types for the MYD-CZU5EV-V2 HFT pipeline.
--
-- The datapath is 64 bits wide at 156.25 MHz (10 Gb/s). Byte lane 0 of an
-- AXI4-Stream beat (tdata(7 downto 0)) carries the earliest wire byte, so a
-- frame byte at offset o sits in beat o / 8, lane o mod 8.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

package hft_types_pkg is

  subtype byte_t is std_logic_vector(7 downto 0);

  subtype symbol_t is std_logic_vector(63 downto 0);

  type byte_array_t is array (natural range <>) of byte_t;

  -- Normalized event kinds (wire values of normalized_event.kind).
  constant event_none    : byte_t := x"00";
  constant event_add     : byte_t := x"41";
  constant event_execute : byte_t := x"45";
  constant event_cancel  : byte_t := x"58";
  constant event_delete  : byte_t := x"44";
  constant event_replace : byte_t := x"55";
  constant event_trade   : byte_t := x"50";

  constant side_none : byte_t := x"00";
  constant side_buy  : byte_t := x"42";
  constant side_sell : byte_t := x"53";

  -- Eight ASCII spaces: the symbol of events that carry none.
  constant blank_symbol : symbol_t := x"2020202020202020";

  -- One 64-bit AXI4-Stream beat from the 10G MAC. The MAC RX interface has
  -- no tready: every stage downstream must accept one beat per cycle.

  type axis64_t is record
    data  : std_logic_vector(63 downto 0);
    keep  : std_logic_vector(7 downto 0);
    valid : std_logic;
    last  : std_logic;
    user  : std_logic;
  end record axis64_t;

  constant axis64_idle : axis64_t :=
  (
    data  => (others => '0'),
    keep  => (others => '0'),
    valid => '0',
    last  => '0',
    user  => '0'
  );

  -- Normalized market event (normalized_event in ipc.yaml, plus the
  -- PL-only ingress timestamp used by telemetry).

  type market_event_t is record
    kind                : byte_t;
    side                : byte_t;
    flags               : std_logic_vector(7 downto 0);
    feed_sequence       : unsigned(63 downto 0);
    timestamp_ns        : unsigned(47 downto 0);
    order_reference     : unsigned(63 downto 0);
    symbol              : symbol_t;
    price               : unsigned(63 downto 0);
    quantity            : unsigned(31 downto 0);
    stock_locate        : unsigned(15 downto 0);
    new_order_reference : unsigned(63 downto 0);
    ingress_cycles      : unsigned(63 downto 0);
  end record market_event_t;

  constant market_event_reset : market_event_t :=
  (
    kind                => event_none,
    side                => side_none,
    flags               => (others => '0'),
    feed_sequence       => (others => '0'),
    timestamp_ns        => (others => '0'),
    order_reference     => (others => '0'),
    symbol              => blank_symbol,
    price               => (others => '0'),
    quantity            => (others => '0'),
    stock_locate        => (others => '0'),
    new_order_reference => (others => '0'),
    ingress_cycles      => (others => '0')
  );

  -- Flat width of market_event_t, for FIFOs and skid buffers.
  constant market_event_bits : natural := 504;

  -- Longest message buffered by moldudp64_rx; every decoded type fits.
  constant itch_buffer_bytes : positive := 48;

  -- One complete ITCH message, lane-0 aligned, as moldudp64_rx hands it to
  -- itch_decoder.

  type itch_message_t is record
    bytes          : byte_array_t(0 to itch_buffer_bytes - 1);
    length         : unsigned(6 downto 0);
    feed_sequence  : unsigned(63 downto 0);
    ingress_cycles : unsigned(63 downto 0);
  end record itch_message_t;

  constant itch_message_reset : itch_message_t :=
  (
    bytes          => (others => (others => '0')),
    length         => (others => '0'),
    feed_sequence  => (others => '0'),
    ingress_cycles => (others => '0')
  );

  -- One trading signal (price/quantity proposal) from the signal engine.

  type signal_t is record
    side  : byte_t;
    price : unsigned(63 downto 0);
    qty   : unsigned(31 downto 0);
  end record signal_t;

  constant signal_reset : signal_t :=
  (
    side  => side_none,
    price => (others => '0'),
    qty   => (others => '0')
  );

  -- Risk limits applied in axis_clk. Updated only through the committed
  -- control snapshot (see hft_regs_axil and cdc_snapshot).

  type risk_limits_t is record
    max_quantity  : unsigned(31 downto 0);
    price_floor   : unsigned(63 downto 0);
    price_ceiling : unsigned(63 downto 0);
  end record risk_limits_t;

  -- Byte lane `lane` of a 64-bit beat.

  function lane_byte (
    data : std_logic_vector(63 downto 0);
    lane : natural range 0 to 7
  ) return byte_t;

  -- Big-endian field of `size` bytes at `offset` in a byte array.

  function be_field (
    bytes  : byte_array_t;
    offset : natural;
    size   : natural
  ) return unsigned;

  -- The same field as raw bytes, first byte most significant.

  function be_bytes (
    bytes  : byte_array_t;
    offset : natural;
    size   : natural
  ) return std_logic_vector;

  -- Ones'-complement add of two 16-bit words with end-around carry.

  function ones_add (
    left  : unsigned(15 downto 0);
    right : unsigned(15 downto 0)
  ) return unsigned;

  -- Big-endian 16-bit value from two bytes. (`high & low` on two byte_t is
  -- ambiguous: it can also build a two-element byte_array_t.)

  function be16 (
    high : byte_t;
    low  : byte_t
  ) return unsigned;

  function pack_event (
    event : market_event_t
  ) return std_logic_vector;

  function unpack_event (
    bits : std_logic_vector(market_event_bits - 1 downto 0)
  ) return market_event_t;

end package hft_types_pkg;

package body hft_types_pkg is

  function lane_byte (
    data : std_logic_vector(63 downto 0);
    lane : natural range 0 to 7
  ) return byte_t is
  begin

    return data((lane * 8) + 7 downto lane * 8);

  end function lane_byte;

  function be_bytes (
    bytes  : byte_array_t;
    offset : natural;
    size   : natural
  ) return std_logic_vector is

    variable result : std_logic_vector((size * 8) - 1 downto 0);

  begin

    for index in 0 to size - 1 loop

      result(((size - index) * 8) - 1 downto (size - 1 - index) * 8) := bytes(bytes'low + offset + index);

    end loop;

    return result;

  end function be_bytes;

  function be_field (
    bytes  : byte_array_t;
    offset : natural;
    size   : natural
  ) return unsigned is
  begin

    return unsigned(be_bytes(bytes, offset, size));

  end function be_field;

  function ones_add (
    left  : unsigned(15 downto 0);
    right : unsigned(15 downto 0)
  ) return unsigned is

    variable sum : unsigned(16 downto 0);

  begin

    sum := resize(left, 17) + resize(right, 17);
    return sum(15 downto 0) + resize(sum(16 downto 16), 16);

  end function ones_add;

  function be16 (
    high : byte_t;
    low  : byte_t
  ) return unsigned is

    variable word : unsigned(15 downto 0);

  begin

    word(15 downto 8) := unsigned(high);
    word(7 downto 0)  := unsigned(low);
    return word;

  end function be16;

  function pack_event (
    event : market_event_t
  ) return std_logic_vector is

    variable bits : std_logic_vector(market_event_bits - 1 downto 0);

  begin

    bits := event.kind & event.side & event.flags &
            std_logic_vector(event.feed_sequence) &
            std_logic_vector(event.timestamp_ns) &
            std_logic_vector(event.order_reference) &
            event.symbol &
            std_logic_vector(event.price) &
            std_logic_vector(event.quantity) &
            std_logic_vector(event.stock_locate) &
            std_logic_vector(event.new_order_reference) &
            std_logic_vector(event.ingress_cycles);
    return bits;

  end function pack_event;

  function unpack_event (
    bits : std_logic_vector(market_event_bits - 1 downto 0)
  ) return market_event_t is

    variable event : market_event_t;

  begin

    event.kind                := bits(503 downto 496);
    event.side                := bits(495 downto 488);
    event.flags               := bits(487 downto 480);
    event.feed_sequence       := unsigned(bits(479 downto 416));
    event.timestamp_ns        := unsigned(bits(415 downto 368));
    event.order_reference     := unsigned(bits(367 downto 304));
    event.symbol              := bits(303 downto 240);
    event.price               := unsigned(bits(239 downto 176));
    event.quantity            := unsigned(bits(175 downto 144));
    event.stock_locate        := unsigned(bits(143 downto 128));
    event.new_order_reference := unsigned(bits(127 downto 64));
    event.ingress_cycles      := unsigned(bits(63 downto 0));
    return event;

  end function unpack_event;

end package body hft_types_pkg;
