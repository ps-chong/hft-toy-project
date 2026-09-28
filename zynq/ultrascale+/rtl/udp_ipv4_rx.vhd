library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

entity udp_ipv4_rx is
  generic (
    destination_mac  : std_logic_vector(47 downto 0) := x"020000000001";
    destination_ip   : std_logic_vector(31 downto 0) := x"C0A80164";
    destination_port : natural range 0 to 65535      := 47000
  );
  port (
    clk : in    std_logic;
    rst : in    std_logic;

    frame_data  : in    std_logic_vector(7 downto 0);
    frame_valid : in    std_logic;
    frame_sop   : in    std_logic;
    frame_eop   : in    std_logic;
    frame_ready : out   std_logic;

    payload_data  : out   std_logic_vector(7 downto 0);
    payload_valid : out   std_logic;
    payload_sop   : out   std_logic;
    payload_eop   : out   std_logic;
    payload_ready : in    std_logic;

    dropped_count   : out   unsigned(31 downto 0);
    drop_pulse      : out   std_logic;
    malformed_pulse : out   std_logic
  );
end entity udp_ipv4_rx;

architecture rtl of udp_ipv4_rx is

  type receive_state_t is (waiting, header, payload, dropping);

  function checksum_valid (
    value : unsigned(19 downto 0)
  )
    return boolean is

    variable folded : unsigned(19 downto 0);

  begin

    folded := value;

    for iteration in 0 to 1 loop

      folded := resize(folded(15 downto 0), folded'length) +
                resize(folded(19 downto 16), folded'length);

    end loop;

    return folded(15 downto 0) = x"FFFF";

  end function checksum_valid;

  signal state_i             : receive_state_t          := waiting;
  signal frame_index_i       : natural range 0 to 65535 := 0;
  signal payload_remaining_i : unsigned(15 downto 0)    := (others => '0');
  signal payload_first_i     : std_logic                := '0';

  signal destination_mac_i   : std_logic_vector(47 downto 0) := (others => '0');
  signal destination_ip_i    : std_logic_vector(31 downto 0) := (others => '0');
  signal ethertype_high_i    : std_logic_vector(7 downto 0)  := (others => '0');
  signal fragment_high_i     : std_logic_vector(7 downto 0)  := (others => '0');
  signal destination_port_i  : std_logic_vector(7 downto 0)  := (others => '0');
  signal udp_checksum_high_i : std_logic_vector(7 downto 0)  := (others => '0');
  signal ip_word_high_i      : std_logic_vector(7 downto 0)  := (others => '0');

  signal total_length_i : unsigned(15 downto 0) := (others => '0');
  signal udp_length_i   : unsigned(15 downto 0) := (others => '0');
  signal checksum_sum_i : unsigned(19 downto 0) := (others => '0');

  signal mac_match_i       : std_logic := '0';
  signal ethertype_match_i : std_logic := '0';
  signal version_match_i   : std_logic := '0';
  signal fragment_clear_i  : std_logic := '0';
  signal protocol_match_i  : std_logic := '0';
  signal ip_match_i        : std_logic := '0';
  signal port_match_i      : std_logic := '0';
  signal checksum_match_i  : std_logic := '0';

  signal dropped_count_i   : unsigned(31 downto 0) := (others => '0');
  signal drop_pulse_i      : std_logic             := '0';
  signal malformed_pulse_i : std_logic             := '0';

begin

  frame_ready <= payload_ready when state_i = payload else
                 '1';

  payload_data  <= frame_data;
  payload_valid <= frame_valid when state_i = payload else
                   '0';
  payload_sop   <= payload_first_i when state_i = payload else
                   '0';
  payload_eop   <= '1'
                   when ((state_i = payload) and (payload_remaining_i = 1)) else
                   '0';

  dropped_count   <= dropped_count_i;
  drop_pulse      <= drop_pulse_i;
  malformed_pulse <= malformed_pulse_i;

  receive : process (clk) is

    variable checksum_with_current : unsigned(19 downto 0);
    variable filters_match         : boolean;
    variable structure_valid       : boolean;

  begin

    if rising_edge(clk) then
      drop_pulse_i      <= '0';
      malformed_pulse_i <= '0';

      if (rst = '1') then
        state_i             <= waiting;
        frame_index_i       <= 0;
        payload_remaining_i <= (others => '0');
        payload_first_i     <= '0';
        destination_mac_i   <= (others => '0');
        destination_ip_i    <= (others => '0');
        total_length_i      <= (others => '0');
        udp_length_i        <= (others => '0');
        checksum_sum_i      <= (others => '0');
        dropped_count_i     <= (others => '0');
        mac_match_i         <= '0';
        ethertype_match_i   <= '0';
        version_match_i     <= '0';
        fragment_clear_i    <= '0';
        protocol_match_i    <= '0';
        ip_match_i          <= '0';
        port_match_i        <= '0';
        checksum_match_i    <= '0';
      elsif ((frame_valid = '1') and (frame_ready = '1')) then

        case state_i is

          when waiting =>

            if (frame_sop = '1') then
              state_i           <= header;
              frame_index_i     <= 1;
              destination_mac_i <= destination_mac_i(39 downto 0) & frame_data;
              checksum_sum_i    <= (others => '0');
              mac_match_i       <= '0';
              ethertype_match_i <= '0';
              version_match_i   <= '0';
              fragment_clear_i  <= '0';
              protocol_match_i  <= '0';
              ip_match_i        <= '0';
              port_match_i      <= '0';
              checksum_match_i  <= '0';
              payload_first_i   <= '0';
            else
              state_i <= dropping;
            end if;

          when header =>

            frame_index_i <= frame_index_i + 1;

            if (frame_index_i <= 5) then
              destination_mac_i <= destination_mac_i(39 downto 0) & frame_data;
              if (frame_index_i = 5) then
                if ((destination_mac_i(39 downto 0) & frame_data) =
                    destination_mac) then
                  mac_match_i <= '1';
                end if;
              end if;
            end if;

            case frame_index_i is

              when 12 =>

                ethertype_high_i <= frame_data;

              when 13 =>

                if ((ethertype_high_i & frame_data) = x"0800") then
                  ethertype_match_i <= '1';
                end if;

              when 14 =>

                if (frame_data = x"45") then
                  version_match_i <= '1';
                end if;

              when 16 =>

                total_length_i(15 downto 8) <= unsigned(frame_data);

              when 17 =>

                total_length_i(7 downto 0) <= unsigned(frame_data);

              when 20 =>

                fragment_high_i <= frame_data;

              when 21 =>

                if (((fragment_high_i & frame_data) and x"3FFF") = x"0000") then
                  fragment_clear_i <= '1';
                end if;

              when 23 =>

                if (frame_data = x"11") then
                  protocol_match_i <= '1';
                end if;

              when 30 to 33 =>

                destination_ip_i <= destination_ip_i(23 downto 0) & frame_data;
                if (frame_index_i = 33) then
                  if ((destination_ip_i(23 downto 0) & frame_data) =
                      destination_ip) then
                    ip_match_i <= '1';
                  end if;
                end if;

              when 36 =>

                destination_port_i <= frame_data;

              when 37 =>

                if (unsigned(destination_port_i & frame_data) =
                    to_unsigned(destination_port, 16)) then
                  port_match_i <= '1';
                end if;

              when 38 =>

                udp_length_i(15 downto 8) <= unsigned(frame_data);

              when 39 =>

                udp_length_i(7 downto 0) <= unsigned(frame_data);

              when 40 =>

                udp_checksum_high_i <= frame_data;

              when 41 =>

                filters_match   := (mac_match_i = '1') and
                                   (ethertype_match_i = '1') and
                                   (version_match_i = '1') and
                                   (fragment_clear_i = '1') and
                                   (protocol_match_i = '1') and
                                   (ip_match_i = '1') and
                                   (port_match_i = '1');
                structure_valid := (checksum_match_i = '1') and
                                   (udp_checksum_high_i = x"00") and
                                   (frame_data = x"00") and
                                   (udp_length_i >= 8) and
                                   (total_length_i = udp_length_i + 20);

                if (not filters_match) then
                  state_i         <= dropping;
                  drop_pulse_i    <= '1';
                  dropped_count_i <= dropped_count_i + 1;
                elsif (not structure_valid) then
                  state_i           <= dropping;
                  malformed_pulse_i <= '1';
                  dropped_count_i   <= dropped_count_i + 1;
                elsif (udp_length_i = 8) then
                  state_i <= dropping;
                else
                  state_i             <= payload;
                  payload_remaining_i <= udp_length_i - 8;
                  payload_first_i     <= '1';
                end if;

              when others =>

                null;

            end case;

            if ((frame_index_i >= 14) and (frame_index_i <= 33)) then
              if ((frame_index_i mod 2) = 0) then
                ip_word_high_i <= frame_data;
              else
                checksum_with_current := checksum_sum_i +
                                         resize(unsigned(ip_word_high_i & frame_data), checksum_sum_i'length);
                checksum_sum_i        <= checksum_with_current;
                if ((frame_index_i = 33) and
                    checksum_valid(checksum_with_current)) then
                  checksum_match_i <= '1';
                end if;
              end if;
            end if;

            if (frame_eop = '1') then
              if (not ((frame_index_i = 41) and (udp_length_i = 8))) then
                malformed_pulse_i <= '1';
                dropped_count_i   <= dropped_count_i + 1;
              end if;
              state_i <= waiting;
            end if;

          when payload =>

            payload_first_i <= '0';
            if (payload_remaining_i > 0) then
              payload_remaining_i <= payload_remaining_i - 1;
            end if;

            if (payload_remaining_i = 1) then
              if (frame_eop = '1') then
                state_i <= waiting;
              else
                state_i <= dropping;
              end if;
            elsif (frame_eop = '1') then
              malformed_pulse_i <= '1';
              dropped_count_i   <= dropped_count_i + 1;
              state_i           <= waiting;
            end if;

          when dropping =>

            if (frame_eop = '1') then
              state_i <= waiting;
            end if;

        end case;

      end if;
    end if;

  end process receive;

end architecture rtl;
