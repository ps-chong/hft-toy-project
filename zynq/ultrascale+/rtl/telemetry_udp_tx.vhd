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
    destination_port : natural range 0 to 65535      := TELEMETRY_DESTINATION_PORT
  );
  port (
    clk : in    std_logic;
    rst : in    std_logic;

    event_data   : in    market_event_t;
    event_valid  : in    std_logic;
    event_ready  : out   std_logic;
    status_flags : in    std_logic_vector(7 downto 0);
    rx_dropped   : in    unsigned(31 downto 0);

    m_axis_tdata  : out   std_logic_vector(63 downto 0);
    m_axis_tkeep  : out   std_logic_vector(7 downto 0);
    m_axis_tvalid : out   std_logic;
    m_axis_tlast  : out   std_logic;
    m_axis_tready : in    std_logic
  );
end entity telemetry_udp_tx;

architecture rtl of telemetry_udp_tx is

  constant ethernet_header_size : natural := 14;
  constant ipv4_header_size     : natural := 20;
  constant udp_header_size      : natural := 8;
  constant frame_size           : natural :=
                                             ethernet_header_size + ipv4_header_size + udp_header_size +
                                             TELEMETRY_PAYLOAD_SIZE;
  constant ip_total_length      : natural :=
                                             ipv4_header_size + udp_header_size + TELEMETRY_PAYLOAD_SIZE;
  constant udp_total_length     : natural :=
                                             udp_header_size + TELEMETRY_PAYLOAD_SIZE;

  type frame_t is array (0 to frame_size - 1) of std_logic_vector(7 downto 0);

  function octet (
    value : std_logic_vector;
    index : natural
  )
    return std_logic_vector is

    variable high_bit : natural;

  begin

    high_bit := value'high - (index * 8);
    return value(high_bit downto high_bit - 7);

  end function octet;

  function ipv4_checksum (
    source      : std_logic_vector(31 downto 0);
    destination : std_logic_vector(31 downto 0)
  )
    return unsigned is

    variable sum_i  : unsigned(19 downto 0);
    variable folded : unsigned(19 downto 0);

  begin

    sum_i  := to_unsigned(16#4500#, 20) +
              to_unsigned(ip_total_length, 20) +
              to_unsigned(16#4000#, 20) +
              to_unsigned(16#4011#, 20) +
              resize(unsigned(source(31 downto 16)), 20) +
              resize(unsigned(source(15 downto 0)), 20) +
              resize(unsigned(destination(31 downto 16)), 20) +
              resize(unsigned(destination(15 downto 0)), 20);
    folded := sum_i;

    for iteration in 0 to 1 loop

      folded := resize(folded(15 downto 0), 20) +
                resize(folded(19 downto 16), 20);

    end loop;

    return not folded(15 downto 0);

  end function ipv4_checksum;

  signal frame_i  : frame_t                       := (others => (others => '0'));
  signal offset_i : natural range 0 to frame_size := 0;
  signal busy_i   : std_logic                     := '0';

begin

  event_ready   <= not busy_i;
  m_axis_tvalid <= busy_i;
  m_axis_tlast  <= '1' when ((busy_i = '1') and (offset_i + 8 >= frame_size)) else
                   '0';

  drive_axis : process (all) is
  begin

    m_axis_tdata <= (others => '0');
    m_axis_tkeep <= (others => '0');

    for lane in 0 to 7 loop

      if ((busy_i = '1') and (offset_i + lane < frame_size)) then
        m_axis_tdata((lane * 8) + 7 downto lane * 8) <= frame_i(offset_i + lane);
        m_axis_tkeep(lane)                           <= '1';
      end if;

    end loop;

  end process drive_axis;

  transmit : process (clk) is

    variable checksum_i : unsigned(15 downto 0);

  begin

    if rising_edge(clk) then
      if (rst = '1') then
        frame_i  <= (others => (others => '0'));
        offset_i <= 0;
        busy_i   <= '0';
      else
        if ((busy_i = '0') and (event_valid = '1')) then
          checksum_i := ipv4_checksum(source_ip, destination_ip);

          for index in 0 to 5 loop

            frame_i(index)     <= octet(destination_mac, index);
            frame_i(index + 6) <= octet(source_mac, index);

          end loop;

          frame_i(12) <= x"08";
          frame_i(13) <= x"00";

          frame_i(14) <= x"45";
          frame_i(15) <= x"00";
          frame_i(16) <= std_logic_vector(to_unsigned(ip_total_length, 16)(15 downto 8));
          frame_i(17) <= std_logic_vector(to_unsigned(ip_total_length, 16)(7 downto 0));
          frame_i(18) <= x"00";
          frame_i(19) <= x"00";
          frame_i(20) <= x"40";
          frame_i(21) <= x"00";
          frame_i(22) <= x"40";
          frame_i(23) <= x"11";
          frame_i(24) <= std_logic_vector(checksum_i(15 downto 8));
          frame_i(25) <= std_logic_vector(checksum_i(7 downto 0));

          for index in 0 to 3 loop

            frame_i(index + 26) <= octet(source_ip, index);
            frame_i(index + 30) <= octet(destination_ip, index);

          end loop;

          frame_i(34) <= std_logic_vector(to_unsigned(source_port, 16)(15 downto 8));
          frame_i(35) <= std_logic_vector(to_unsigned(source_port, 16)(7 downto 0));
          frame_i(36) <= std_logic_vector(to_unsigned(destination_port, 16)(15 downto 8));
          frame_i(37) <= std_logic_vector(to_unsigned(destination_port, 16)(7 downto 0));
          frame_i(38) <= std_logic_vector(to_unsigned(udp_total_length, 16)(15 downto 8));
          frame_i(39) <= std_logic_vector(to_unsigned(udp_total_length, 16)(7 downto 0));
          frame_i(40) <= x"00";
          frame_i(41) <= x"00";

          frame_i(42) <= x"00";
          frame_i(43) <= std_logic_vector(to_unsigned(ABI_VERSION, 8));
          frame_i(44) <= x"01";
          frame_i(45) <= event_data.kind;
          frame_i(46) <= event_data.side;
          frame_i(47) <= status_flags;
          frame_i(48) <= x"00";
          frame_i(49) <= x"00";

          for index in 0 to 7 loop

            frame_i(index + 50) <= octet(std_logic_vector(event_data.feed_sequence), index);

          end loop;

          frame_i(58) <= x"00";
          frame_i(59) <= x"00";

          for index in 0 to 5 loop

            frame_i(index + 60) <= octet(std_logic_vector(event_data.timestamp_ns), index);

          end loop;

          for index in 0 to 7 loop

            frame_i(index + 66) <= octet(std_logic_vector(event_data.order_reference), index);
            frame_i(index + 74) <= octet(event_data.symbol, index);
            frame_i(index + 82) <= octet(std_logic_vector(event_data.price), index);

          end loop;

          for index in 0 to 3 loop

            frame_i(index + 90) <= octet(std_logic_vector(event_data.quantity), index);
            frame_i(index + 94) <= octet(std_logic_vector(rx_dropped), index);

          end loop;

          for index in 98 to frame_size - 1 loop

            frame_i(index) <= x"00";

          end loop;

          offset_i <= 0;
          busy_i   <= '1';
        elsif ((busy_i = '1') and (m_axis_tready = '1')) then
          if (offset_i + 8 >= frame_size) then
            offset_i <= 0;
            busy_i   <= '0';
          else
            offset_i <= offset_i + 8;
          end if;
        end if;
      end if;
    end if;

  end process transmit;

end architecture rtl;
