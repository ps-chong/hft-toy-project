-- Shared testbench helpers: binary vector files, Ethernet/IPv4/UDP framing,
-- 64-bit beat drivers, and the IPC encoding of normalized events used to
-- compare RTL output byte for byte with the software model.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library hft;
  use hft.hft_types_pkg.all;

package hft_tb_pkg is

  subtype file_buffer_t is byte_array_t(0 to 16383);

  type char_file_t is file of character;

  constant tb_local_mac : std_logic_vector(47 downto 0) := x"020000000001";
  constant tb_peer_mac  : std_logic_vector(47 downto 0) := x"020000000009";
  constant tb_local_ip  : std_logic_vector(31 downto 0) := x"C0A80164";
  constant tb_peer_ip   : std_logic_vector(31 downto 0) := x"C0A80109";
  constant tb_port      : natural                       := 47000;

  -- Whole file into `data`; `length` is the byte count.

  procedure read_bytes (
    path   : string;
    data   : out file_buffer_t;
    length : out natural
  );

  -- Ethernet II / IPv4 / UDP frame carrying `payload` (no FCS), padded to
  -- the 60-byte minimum, IPv4 header checksum filled in.

  function udp_frame (
    payload  : byte_array_t;
    dst_port : natural := tb_port;
    dst_ip   : std_logic_vector(31 downto 0) := tb_local_ip;
    dst_mac  : std_logic_vector(47 downto 0) := tb_local_mac
  ) return byte_array_t;

  -- One frame, lane 0 first, then `idle` empty cycles.

  procedure send_frame (
    signal clk  : in std_logic;
    signal beat : out axis64_t;
    frame       : byte_array_t;
    mac_error   : std_logic := '0';
    idle        : natural   := 1
  );

  -- A UDP payload directly as moldudp64_rx input, first byte in `lane`.

  procedure send_payload (
    signal clk   : in std_logic;
    signal beat  : out axis64_t;
    signal first : out std_logic;
    payload      : byte_array_t;
    lane         : natural := 2;
    idle         : natural := 1
  );

  -- normalized_event (ipc.yaml), little-endian, 64 bytes.

  function encode_event (
    event : market_event_t
  ) return byte_array_t;

  function to_hex (
    bytes : byte_array_t
  ) return string;

end package hft_tb_pkg;

package body hft_tb_pkg is

  procedure read_bytes (
    path   : string;
    data   : out file_buffer_t;
    length : out natural
  ) is

    file     source : char_file_t open read_mode is path;
    variable value  : character;
    variable count  : natural;

  begin

    data  := (others => x"00");
    count := 0;

    while not endfile(source) loop

      read(source, value);
      data(count) := std_logic_vector(to_unsigned(character'pos(value), 8));
      count       := count + 1;

    end loop;

    file_close(source);
    length := count;

  end procedure read_bytes;

  function udp_frame (
    payload  : byte_array_t;
    dst_port : natural := tb_port;
    dst_ip   : std_logic_vector(31 downto 0) := tb_local_ip;
    dst_mac  : std_logic_vector(47 downto 0) := tb_local_mac
  ) return byte_array_t is

    constant used   : natural := 42 + payload'length;
    constant length : natural := maximum(60, used);

    variable frame   : byte_array_t(0 to length - 1);
    variable sum     : unsigned(15 downto 0);
    variable ip_len  : unsigned(15 downto 0);
    variable udp_len : unsigned(15 downto 0);

    procedure put16 (
      offset : natural;
      value  : unsigned(15 downto 0)
    ) is
    begin

      frame(offset)     := std_logic_vector(value(15 downto 8));
      frame(offset + 1) := std_logic_vector(value(7 downto 0));

    end procedure put16;

  begin

    frame   := (others => x"00");
    ip_len  := to_unsigned(28 + payload'length, 16);
    udp_len := to_unsigned(8 + payload'length, 16);

    for index in 0 to 5 loop

      frame(index)     := dst_mac(47 - (index * 8) downto 40 - (index * 8));
      frame(index + 6) := tb_peer_mac(47 - (index * 8) downto 40 - (index * 8));

    end loop;

    frame(12) := x"08";
    frame(13) := x"00";
    frame(14) := x"45";
    put16(16, ip_len);
    frame(20) := x"40";
    frame(22) := x"40";
    frame(23) := x"11";

    for index in 0 to 3 loop

      frame(26 + index) := tb_peer_ip(31 - (index * 8) downto 24 - (index * 8));
      frame(30 + index) := dst_ip(31 - (index * 8) downto 24 - (index * 8));

    end loop;

    sum := (others => '0');

    for word in 0 to 9 loop

      sum := ones_add(sum, be16(frame(14 + (word * 2)), frame(15 + (word * 2))));

    end loop;

    put16(24, not sum);
    put16(34, to_unsigned(tb_port + 1, 16));
    put16(36, to_unsigned(dst_port, 16));
    put16(38, udp_len);

    for index in 0 to payload'length - 1 loop

      frame(42 + index) := payload(payload'low + index);

    end loop;

    return frame;

  end function udp_frame;

  procedure send_frame (
    signal clk  : in std_logic;
    signal beat : out axis64_t;
    frame       : byte_array_t;
    mac_error   : std_logic := '0';
    idle        : natural   := 1
  ) is

    constant beats : natural := (frame'length + 7) / 8;

    variable next_beat : axis64_t;
    variable index     : natural;

  begin

    for beat_index in 0 to beats - 1 loop

      next_beat       := axis64_idle;
      next_beat.valid := '1';

      for lane in 0 to 7 loop

        index := (beat_index * 8) + lane;

        if (index < frame'length) then
          next_beat.data((lane * 8) + 7 downto lane * 8) := frame(frame'low + index);
          next_beat.keep(lane)                           := '1';
        end if;

      end loop;

      if (beat_index = beats - 1) then
        next_beat.last := '1';
        next_beat.user := mac_error;
      end if;

      beat <= next_beat;
      wait until rising_edge(clk);

    end loop;

    beat <= axis64_idle;

    for cycle in 1 to idle loop

      wait until rising_edge(clk);

    end loop;

  end procedure send_frame;

  procedure send_payload (
    signal clk   : in std_logic;
    signal beat  : out axis64_t;
    signal first : out std_logic;
    payload      : byte_array_t;
    lane         : natural := 2;
    idle         : natural := 1
  ) is

    variable next_beat  : axis64_t;
    variable position   : natural;
    variable start      : natural;
    variable first_beat : boolean;

  begin

    position   := 0;
    start      := lane;
    first_beat := true;

    while position < payload'length loop

      next_beat       := axis64_idle;
      next_beat.valid := '1';

      for slot in start to 7 loop

        if (position < payload'length) then
          next_beat.data((slot * 8) + 7 downto slot * 8) := payload(payload'low + position);
          next_beat.keep(slot)                           := '1';
          position                                       := position + 1;
        end if;

      end loop;

      if (position = payload'length) then
        next_beat.last := '1';
      end if;

      if (first_beat) then
        first <= '1';
      else
        first <= '0';
      end if;

      first_beat := false;
      start      := 0;
      beat       <= next_beat;
      wait until rising_edge(clk);

    end loop;

    beat  <= axis64_idle;
    first <= '0';

    for cycle in 1 to idle loop

      wait until rising_edge(clk);

    end loop;

  end procedure send_payload;

  function encode_event (
    event : market_event_t
  ) return byte_array_t is

    variable bytes : byte_array_t(0 to 63);

    procedure put_le (
      offset : natural;
      value  : unsigned
    ) is

      variable wide : unsigned(63 downto 0);

    begin

      wide := resize(value, 64);

      for index in 0 to (value'length / 8) - 1 loop

        bytes(offset + index) := std_logic_vector(wide((index * 8) + 7 downto index * 8));

      end loop;

    end procedure put_le;

  begin

    bytes    := (others => x"00");
    put_le(0, to_unsigned(2, 16));
    bytes(2) := event.kind;
    bytes(3) := event.side;
    put_le(4, resize(unsigned(event.flags), 32));
    put_le(8, event.feed_sequence);
    put_le(16, resize(event.timestamp_ns, 64));
    put_le(24, event.order_reference);

    for index in 0 to 7 loop

      bytes(32 + index) := event.symbol(63 - (index * 8) downto 56 - (index * 8));

    end loop;

    put_le(40, event.price);
    put_le(48, event.quantity);
    put_le(52, event.stock_locate);
    put_le(56, event.new_order_reference);
    return bytes;

  end function encode_event;

  function to_hex (
    bytes : byte_array_t
  ) return string is

    constant digits : string(1 to 16) := "0123456789abcdef";

    variable text : string(1 to 2 * bytes'length);
    variable value : natural;

  begin

    for index in 0 to bytes'length - 1 loop

      value                 := to_integer(unsigned(bytes(bytes'low + index)));
      text((2 * index) + 1) := digits((value / 16) + 1);
      text((2 * index) + 2) := digits((value mod 16) + 1);

    end loop;

    return text;

  end function to_hex;

end package body hft_tb_pkg;
