-- UDP telemetry transmitter: one 106-byte Ethernet/IPv4/UDP frame per
-- approved event, 64 bits per beat (14 beats, the last carrying 2 bytes).
--
-- The trading path never waits for telemetry. Events enter a small FIFO
-- that only ever accepts; when it is full the event is dropped from
-- telemetry and drop_count increments (reported in TELEMETRY_DROP_COUNT).
-- The Ethernet, IPv4 and UDP headers depend only on generics, so they are
-- elaboration-time constants, including the IPv4 header checksum. The UDP
-- checksum is zero, as IPv4 allows. Payload layout:
-- protocol/schema/telemetry_udp.yaml, big-endian.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library work;
  use work.hft_types_pkg.all;
  use work.hft_protocol_pkg.all;

entity telemetry_udp_tx is
  generic (
    source_mac       : std_logic_vector(47 downto 0) := x"020000000001";
    destination_mac  : std_logic_vector(47 downto 0) := x"020000000002";
    source_ip        : std_logic_vector(31 downto 0) := x"C0A80164";
    destination_ip   : std_logic_vector(31 downto 0) := x"C0A80165";
    source_port      : natural range 0 to 65535      := TELEMETRY_SOURCE_PORT;
    destination_port : natural range 0 to 65535      := TELEMETRY_DESTINATION_PORT;
    fifo_bits        : positive                      := 4
  );
  port (
    clk : in    std_logic;
    rst : in    std_logic;

    event_data   : in    market_event_t;
    event_valid  : in    std_logic;
    status_flags : in    std_logic_vector(7 downto 0);
    rx_dropped   : in    unsigned(31 downto 0);

    drop_count : out   unsigned(31 downto 0);

    m_axis_tdata  : out   std_logic_vector(63 downto 0);
    m_axis_tkeep  : out   std_logic_vector(7 downto 0);
    m_axis_tvalid : out   std_logic;
    m_axis_tlast  : out   std_logic;
    m_axis_tready : in    std_logic
  );
end entity telemetry_udp_tx;

architecture rtl of telemetry_udp_tx is

  constant header_size      : natural := 42;
  constant frame_size       : natural := header_size + TELEMETRY_PAYLOAD_SIZE;
  constant beats            : natural := (frame_size + 7) / 8;
  constant ip_total_length  : natural := 20 + 8 + TELEMETRY_PAYLOAD_SIZE;
  constant udp_total_length : natural := 8 + TELEMETRY_PAYLOAD_SIZE;

  subtype frame_t is byte_array_t(0 to (beats * 8) - 1);

  function octet (
    value : std_logic_vector;
    index : natural
  ) return byte_t is

    variable high_bit : natural;

  begin

    high_bit := value'high - (index * 8);
    return value(high_bit downto high_bit - 7);

  end function octet;

  function u16_octet (
    value : natural;
    index : natural
  ) return byte_t is
  begin

    return octet(std_logic_vector(to_unsigned(value, 16)), index);

  end function u16_octet;

  function ipv4_checksum return std_logic_vector is

    variable sum : unsigned(15 downto 0);

  begin

    sum := x"4500";
    sum := ones_add(sum, to_unsigned(ip_total_length, 16));
    sum := ones_add(sum, x"0000");
    sum := ones_add(sum, x"4000");
    sum := ones_add(sum, x"4011");
    sum := ones_add(sum, unsigned(source_ip(31 downto 16)));
    sum := ones_add(sum, unsigned(source_ip(15 downto 0)));
    sum := ones_add(sum, unsigned(destination_ip(31 downto 16)));
    sum := ones_add(sum, unsigned(destination_ip(15 downto 0)));
    return std_logic_vector(not sum);

  end function ipv4_checksum;

  function build_header return byte_array_t is

    variable header   : byte_array_t(0 to header_size - 1);
    variable checksum : std_logic_vector(15 downto 0);

  begin

    header   := (others => x"00");
    checksum := ipv4_checksum;

    for index in 0 to 5 loop

      header(index)     := octet(destination_mac, index);
      header(index + 6) := octet(source_mac, index);

    end loop;

    header(12) := x"08";
    header(13) := x"00";
    header(14) := x"45";
    header(16) := u16_octet(ip_total_length, 0);
    header(17) := u16_octet(ip_total_length, 1);
    header(20) := x"40";
    header(22) := x"40";
    header(23) := x"11";
    header(24) := checksum(15 downto 8);
    header(25) := checksum(7 downto 0);

    for index in 0 to 3 loop

      header(index + 26) := octet(source_ip, index);
      header(index + 30) := octet(destination_ip, index);

    end loop;

    header(34) := u16_octet(source_port, 0);
    header(35) := u16_octet(source_port, 1);
    header(36) := u16_octet(destination_port, 0);
    header(37) := u16_octet(destination_port, 1);
    header(38) := u16_octet(udp_total_length, 0);
    header(39) := u16_octet(udp_total_length, 1);
    return header;

  end function build_header;

  constant header : byte_array_t(0 to header_size - 1) := build_header;

  -- FIFO entry: the event fields telemetry carries plus the status sampled
  -- when the event was accepted.

  type entry_t is record
    event      : market_event_t;
    flags      : std_logic_vector(7 downto 0);
    rx_dropped : unsigned(31 downto 0);
  end record entry_t;

  -- Stored flat so the FIFO infers as distributed RAM.
  constant entry_bits : natural := market_event_bits + 8 + 32;

  type fifo_t is array (0 to (2 ** fifo_bits) - 1) of std_logic_vector(entry_bits - 1 downto 0);

  signal fifo    : fifo_t;
  signal wr_ptr  : unsigned(fifo_bits downto 0) := (others => '0');
  signal rd_ptr  : unsigned(fifo_bits downto 0) := (others => '0');
  signal drops   : unsigned(31 downto 0)        := (others => '0');
  signal current : entry_t;
  signal busy    : std_logic                    := '0';
  signal beat    : natural range 0 to beats - 1 := 0;

  attribute ram_style : string;
  attribute ram_style of fifo : signal is "distributed";

  function build_frame (
    entry : entry_t
  ) return frame_t is

    variable frame   : frame_t;
    variable payload : natural;

  begin

    frame                       := (others => x"00");
    frame(0 to header_size - 1) := header;
    payload                     := header_size;

    frame(payload + 0) := u16_octet(ABI_VERSION, 0);
    frame(payload + 1) := u16_octet(ABI_VERSION, 1);
    frame(payload + 2) := x"01";
    frame(payload + 3) := entry.event.kind;
    frame(payload + 4) := entry.event.side;
    frame(payload + 5) := entry.flags;

    for index in 0 to 7 loop

      frame(payload + 8 + index)  := octet(std_logic_vector(entry.event.feed_sequence), index);
      frame(payload + 16 + index) := octet(std_logic_vector(resize(entry.event.timestamp_ns, 64)), index);
      frame(payload + 24 + index) := octet(std_logic_vector(entry.event.order_reference), index);
      frame(payload + 32 + index) := octet(entry.event.symbol, index);
      frame(payload + 40 + index) := octet(std_logic_vector(entry.event.price), index);
      frame(payload + 56 + index) := octet(std_logic_vector(entry.event.ingress_cycles), index);

    end loop;

    for index in 0 to 3 loop

      frame(payload + 48 + index) := octet(std_logic_vector(entry.event.quantity), index);
      frame(payload + 52 + index) := octet(std_logic_vector(entry.rx_dropped), index);

    end loop;

    return frame;

  end function build_frame;

  signal frame   : frame_t;
  signal fifo_in : std_logic_vector(entry_bits - 1 downto 0);

begin

  drop_count    <= drops;
  m_axis_tvalid <= busy;
  m_axis_tlast  <= busy when beat = beats - 1 else
                   '0';

  frame   <= build_frame(current);
  fifo_in <= pack_event(event_data) & status_flags & std_logic_vector(rx_dropped);

  -- Beat mux: lane l of beat b is frame byte 8b + l.
  drive_axis : process (all) is

    constant last_keep : natural := frame_size - ((beats - 1) * 8);

  begin

    for lane in 0 to 7 loop

      m_axis_tdata((lane * 8) + 7 downto lane * 8) <= frame((beat * 8) + lane);

      if ((beat < beats - 1) or (lane < last_keep)) then
        m_axis_tkeep(lane) <= busy;
      else
        m_axis_tkeep(lane) <= '0';
      end if;

    end loop;

  end process drive_axis;

  accept : process (clk) is
  begin

    if rising_edge(clk) then
      if (rst = '1') then
        wr_ptr <= (others => '0');
        drops  <= (others => '0');
      elsif (event_valid = '1') then
        if ((wr_ptr - rd_ptr) = 2 ** fifo_bits) then
          drops <= drops + 1;
        else
          fifo(to_integer(wr_ptr(fifo_bits - 1 downto 0))) <= fifo_in;
          wr_ptr                                           <= wr_ptr + 1;
        end if;
      end if;
    end if;

  end process accept;

  transmit : process (clk) is

    variable head : std_logic_vector(entry_bits - 1 downto 0);

  begin

    if rising_edge(clk) then
      if (rst = '1') then
        rd_ptr <= (others => '0');
        busy   <= '0';
        beat   <= 0;
      elsif (busy = '0') then
        if (rd_ptr /= wr_ptr) then
          head               := fifo(to_integer(rd_ptr(fifo_bits - 1 downto 0)));
          current.event      <= unpack_event(head(entry_bits - 1 downto 40));
          current.flags      <= head(39 downto 32);
          current.rx_dropped <= unsigned(head(31 downto 0));
          rd_ptr             <= rd_ptr + 1;
          busy               <= '1';
          beat               <= 0;
        end if;
      elsif (m_axis_tready = '1') then
        if (beat = beats - 1) then
          busy <= '0';
        else
          beat <= beat + 1;
        end if;
      end if;
    end if;

  end process transmit;

end architecture rtl;
