library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package hft_types_pkg is
  subtype byte_t is std_logic_vector(7 downto 0);
  subtype symbol_t is std_logic_vector(63 downto 0);

  constant EVENT_NONE    : byte_t := x"00";
  constant EVENT_ADD     : byte_t := x"41";
  constant EVENT_EXECUTE : byte_t := x"45";
  constant EVENT_CANCEL  : byte_t := x"58";
  constant EVENT_DELETE  : byte_t := x"44";
  constant EVENT_REPLACE : byte_t := x"55";
  constant EVENT_TRADE   : byte_t := x"50";

  constant SIDE_BUY  : byte_t := x"42";
  constant SIDE_SELL : byte_t := x"53";

  type market_event_t is record
    kind            : byte_t;
    side            : byte_t;
    feed_sequence   : unsigned(63 downto 0);
    timestamp_ns    : unsigned(47 downto 0);
    order_reference : unsigned(63 downto 0);
    symbol          : symbol_t;
    price           : unsigned(63 downto 0);
    quantity        : unsigned(31 downto 0);
  end record;

  constant MARKET_EVENT_RESET : market_event_t := (
    kind            => EVENT_NONE,
    side            => (others => '0'),
    feed_sequence   => (others => '0'),
    timestamp_ns    => (others => '0'),
    order_reference => (others => '0'),
    symbol          => (others => '0'),
    price           => (others => '0'),
    quantity        => (others => '0')
  );

  type order_intent_t is record
    action       : byte_t;
    side         : byte_t;
    user_ref     : unsigned(31 downto 0);
    source_sequence : unsigned(63 downto 0);
    timestamp_ns : unsigned(63 downto 0);
    symbol       : symbol_t;
    price        : unsigned(63 downto 0);
    quantity     : unsigned(31 downto 0);
  end record;

  constant ORDER_INTENT_RESET : order_intent_t := (
    action       => EVENT_NONE,
    side         => (others => '0'),
    user_ref     => (others => '0'),
    source_sequence => (others => '0'),
    timestamp_ns => (others => '0'),
    symbol       => (others => '0'),
    price        => (others => '0'),
    quantity     => (others => '0')
  );

  function shift_append(value : std_logic_vector; octet : byte_t)
    return std_logic_vector;
end package;

package body hft_types_pkg is
  function shift_append(value : std_logic_vector; octet : byte_t)
    return std_logic_vector is
    variable result : std_logic_vector(value'range);
  begin
    if value'length = 8 then
      result := octet;
    else
      result := value(value'high - 8 downto value'low) & octet;
    end if;
    return result;
  end function;
end package body;
