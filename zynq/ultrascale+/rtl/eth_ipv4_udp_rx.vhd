-- 10G Ethernet II / IPv4 / UDP receiver, 64 bits per beat (II = 1).
--
-- The 10G/25G MAC RX interface has no tready, so this stage accepts one beat
-- every cycle and never stalls. The header occupies frame bytes 0..41 (beats
-- 0..5). Each check runs in the beat whose lanes carry its bytes; the verdict
-- is formed in beat 5, and payload lanes (frame byte 42 onwards) are then
-- forwarded cut-through, unshifted, with keep marking exactly the UDP
-- payload. A frame-level MAC error (tuser on tlast) arrives after the payload
-- has been forwarded: it is reported on frame_error_pulse, and the top level
-- latches the kill switch, which fails closed.
--
-- Latency: one cycle (registered output). Accepted: fixed 20-byte IPv4
-- header (IHL 5), unfragmented, protocol UDP, destination MAC/IP/port match
-- (optionally the IPv4 multicast MAC of destination_ip), UDP checksum zero
-- unless allow_udp_checksum. IPv4 header checksum verified.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library work;
  use work.hft_types_pkg.all;

entity eth_ipv4_udp_rx is
  generic (
    destination_mac    : std_logic_vector(47 downto 0) := x"020000000001";
    destination_ip     : std_logic_vector(31 downto 0) := x"C0A80164";
    destination_port   : natural range 0 to 65535      := 47000;
    accept_multicast   : boolean                       := false;
    allow_udp_checksum : boolean                       := false
  );
  port (
    clk : in    std_logic;
    rst : in    std_logic;

    -- MAC receive stream (no backpressure).
    s_axis : in    axis64_t;

    -- UDP payload: frame-aligned beats, keep marks payload bytes only.
    m_payload : out   axis64_t;
    m_first   : out   std_logic;

    dropped_count     : out   unsigned(31 downto 0);
    drop_pulse        : out   std_logic;
    malformed_pulse   : out   std_logic;
    frame_error_pulse : out   std_logic;
    packet_pulse      : out   std_logic
  );
end entity eth_ipv4_udp_rx;

architecture rtl of eth_ipv4_udp_rx is

  -- idle:    waiting for beat 0 of a frame
  -- header:  beats 1..5; fields checked as their lanes arrive
  -- payload: forwarding UDP payload lanes
  -- discard: rest of a rejected frame, or Ethernet padding after the payload

  type state_t is (idle, header, payload, discard);

  signal state : state_t := idle;

  attribute fsm_encoding : string;
  attribute fsm_encoding of state   : signal is "one_hot";
  attribute fsm_safe_state : string;
  attribute fsm_safe_state of state : signal is "reset_state";

  -- IPv4 multicast MAC for destination_ip: 01:00:5E + low 23 address bits.
  constant multicast_mac : std_logic_vector(47 downto 0) :=
                                                            x"01005E" & '0' & destination_ip(22 downto 0);

  signal beat_index : unsigned(2 downto 0) := (others => '0');

  signal mac_ok       : std_logic := '0';
  signal ethertype_ok : std_logic := '0';
  signal version_ok   : std_logic := '0';
  signal fragment_ok  : std_logic := '0';
  signal protocol_ok  : std_logic := '0';
  signal ip_ok        : std_logic := '0';
  signal port_ok      : std_logic := '0';
  signal checksum_ok  : std_logic := '0';

  signal total_length : unsigned(15 downto 0)         := (others => '0');
  signal udp_length   : unsigned(15 downto 0)         := (others => '0');
  signal ip_high      : std_logic_vector(15 downto 0) := (others => '0');
  signal checksum     : unsigned(15 downto 0)         := (others => '0');
  signal remaining    : unsigned(15 downto 0)         := (others => '0');

  signal payload_r     : axis64_t              := axis64_idle;
  signal first_r       : std_logic             := '0';
  signal dropped_r     : unsigned(31 downto 0) := (others => '0');
  signal drop_r        : std_logic             := '0';
  signal malformed_r   : std_logic             := '0';
  signal frame_error_r : std_logic             := '0';
  signal packet_r      : std_logic             := '0';

  -- Big-endian 16-bit word from two adjacent lanes.

  function word (
    data : std_logic_vector(63 downto 0);
    lane : natural range 0 to 6
  ) return unsigned is
  begin

    return be16(lane_byte(data, lane), lane_byte(data, lane + 1));

  end function word;

  -- keep mask for the first `count` payload bytes starting at lane `first`.

  function payload_keep (
    first : natural range 0 to 7;
    count : unsigned(15 downto 0)
  ) return std_logic_vector is

    variable keep : std_logic_vector(7 downto 0);

  begin

    keep := (others => '0');

    for lane in 0 to 7 loop

      if ((lane >= first) and (to_unsigned(lane - first, 16) < count)) then
        keep(lane) := '1';
      end if;

    end loop;

    return keep;

  end function payload_keep;

  function popcount (
    keep : std_logic_vector(7 downto 0)
  ) return unsigned is

    variable total : unsigned(15 downto 0);

  begin

    total := (others => '0');

    for lane in 0 to 7 loop

      if (keep(lane) = '1') then
        total := total + 1;
      end if;

    end loop;

    return total;

  end function popcount;

begin

  m_payload         <= payload_r;
  m_first           <= first_r;
  dropped_count     <= dropped_r;
  drop_pulse        <= drop_r;
  malformed_pulse   <= malformed_r;
  frame_error_pulse <= frame_error_r;
  packet_pulse      <= packet_r;

  receive : process (clk) is

    variable data          : std_logic_vector(63 downto 0);
    variable sum           : unsigned(15 downto 0);
    variable filters_match : boolean;
    variable structure_ok  : boolean;
    variable keep          : std_logic_vector(7 downto 0);
    variable count         : unsigned(15 downto 0);

  begin

    if rising_edge(clk) then
      payload_r.valid <= '0';
      payload_r.last  <= '0';
      payload_r.user  <= '0';
      first_r         <= '0';
      drop_r          <= '0';
      malformed_r     <= '0';
      frame_error_r   <= '0';
      packet_r        <= '0';

      if (rst = '1') then
        state     <= idle;
        dropped_r <= (others => '0');
      elsif (s_axis.valid = '1') then
        data := s_axis.data;

        case state is

          when idle =>

            -- Beat 0: destination MAC in lanes 0..5.
            if ((data(7 downto 0) & data(15 downto 8) & data(23 downto 16) &
                 data(31 downto 24) & data(39 downto 32) & data(47 downto 40)) = destination_mac or
                (accept_multicast and
                  (data(7 downto 0) & data(15 downto 8) & data(23 downto 16) &
                    data(31 downto 24) & data(39 downto 32) & data(47 downto 40)) = multicast_mac)) then
              mac_ok <= '1';
            else
              mac_ok <= '0';
            end if;
            beat_index <= to_unsigned(1, 3);
            state      <= header;
            if (s_axis.last = '1') then
              -- A one-beat frame is a runt.
              state <= idle;
            end if;

          when header =>

            beat_index <= beat_index + 1;

            case to_integer(beat_index) is

              when 1 =>

                ethertype_ok <= '1' when word(data, 4) = x"0800" else '0';
                version_ok   <= '1' when lane_byte(data, 6) = x"45" else '0';
                checksum     <= word(data, 6);

              when 2 =>

                total_length <= word(data, 0);
                fragment_ok  <= '1' when (word(data, 4) and x"3FFF") = x"0000" else '0';
                protocol_ok  <= '1' when lane_byte(data, 7) = x"11" else '0';
                -- Adder tree: four words per beat into the running sum.
                sum      := ones_add(ones_add(word(data, 0), word(data, 2)),
                                     ones_add(word(data, 4), word(data, 6)));
                checksum <= ones_add(checksum, sum);

              when 3 =>

                ip_high  <= std_logic_vector(word(data, 6));
                sum      := ones_add(ones_add(word(data, 0), word(data, 2)),
                                     ones_add(word(data, 4), word(data, 6)));
                checksum <= ones_add(checksum, sum);

              when 4 =>

                ip_ok       <= '1' when (ip_high & std_logic_vector(word(data, 0))) = destination_ip else '0';
                port_ok     <= '1' when word(data, 4) = to_unsigned(destination_port, 16) else '0';
                udp_length  <= word(data, 6);
                checksum_ok <= '1' when ones_add(checksum, word(data, 0)) = x"FFFF" else '0';

              when others =>

                -- Beat 5: UDP checksum in lanes 0..1, payload from lane 2.
                filters_match := (mac_ok = '1') and (ethertype_ok = '1') and (ip_ok = '1') and
                                 (port_ok = '1') and (protocol_ok = '1');
                structure_ok  := (version_ok = '1') and (fragment_ok = '1') and
                                 (checksum_ok = '1') and (udp_length >= 8) and
                                 (total_length = udp_length + 20) and
                                 (allow_udp_checksum or (word(data, 0) = x"0000"));
                if (not filters_match) then
                  drop_r    <= '1';
                  dropped_r <= dropped_r + 1;
                  state     <= discard;
                elsif (not structure_ok) then
                  malformed_r <= '1';
                  dropped_r   <= dropped_r + 1;
                  state       <= discard;
                else
                  packet_r        <= '1';
                  count           := udp_length - 8;
                  keep            := payload_keep(2, count);
                  payload_r.data  <= data;
                  payload_r.keep  <= keep;
                  payload_r.valid <= '1';
                  first_r         <= '1';
                  remaining       <= count - popcount(keep);
                  state           <= payload;
                  if (count <= 6) then
                    payload_r.last <= '1';
                    state          <= discard;
                    if (count = 0) then
                      payload_r.valid <= '0';
                    end if;
                  elsif (s_axis.last = '1') then
                    malformed_r    <= '1';
                    dropped_r      <= dropped_r + 1;
                    payload_r.last <= '1';
                    payload_r.user <= '1';
                  end if;
                end if;

            end case;

            if ((s_axis.last = '1') and (beat_index < 5)) then
              -- Frame ended inside the headers.
              if (mac_ok = '1') then
                malformed_r <= '1';
                dropped_r   <= dropped_r + 1;
              end if;
              state <= idle;
            end if;

          when payload =>

            keep            := payload_keep(0, remaining);
            payload_r.data  <= data;
            payload_r.keep  <= keep;
            payload_r.valid <= '1';
            remaining       <= remaining - popcount(keep);
            if (remaining <= 8) then
              payload_r.last <= '1';
              state          <= discard;
            elsif (s_axis.last = '1') then
              -- The frame ended before the UDP length was satisfied.
              payload_r.last <= '1';
              payload_r.user <= '1';
              malformed_r    <= '1';
              dropped_r      <= dropped_r + 1;
            end if;

          when discard =>

            null;

        end case;

        -- Every frame end returns to idle; a MAC error on a frame that got
        -- past beat 0 is a fault even if its payload was already forwarded.
        if (s_axis.last = '1') then
          if ((state /= idle) and (s_axis.user = '1')) then
            frame_error_r <= '1';
          end if;
          state <= idle;
        end if;
      end if;
    end if;

  end process receive;

end architecture rtl;
