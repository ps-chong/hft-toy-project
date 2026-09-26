library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.hft_types_pkg.all;

entity moldudp64_decoder is
  port (
    clk : in std_logic;
    rst : in std_logic;

    s_data  : in  byte_t;
    s_valid : in  std_logic;
    s_sop   : in  std_logic;
    s_eop   : in  std_logic;
    s_ready : out std_logic;

    m_data     : out byte_t;
    m_valid    : out std_logic;
    m_sop      : out std_logic;
    m_eop      : out std_logic;
    m_sequence : out unsigned(63 downto 0);
    m_ready    : in  std_logic;

    gap_pulse       : out std_logic;
    malformed_pulse : out std_logic;
    heartbeat_pulse : out std_logic;
    expected_sequence : out unsigned(63 downto 0)
  );
end entity;

architecture rtl of moldudp64_decoder is
  type state_t is (HEADER, LENGTH_HIGH, LENGTH_LOW, MESSAGE, EXPECT_END);
  signal state : state_t := HEADER;

  signal header_index       : natural range 0 to 19 := 0;
  signal sequence_shift     : unsigned(63 downto 0) := (others => '0');
  signal packet_sequence_r  : unsigned(63 downto 0) := (others => '0');
  signal expected_sequence_r : unsigned(63 downto 0) := (others => '0');
  signal expected_valid     : std_logic := '0';
  signal count_high         : byte_t := (others => '0');
  signal message_count      : natural range 0 to 65535 := 0;
  signal message_number     : natural range 0 to 65535 := 0;
  signal message_length_high : byte_t := (others => '0');
  signal message_remaining  : natural range 0 to 65535 := 0;
  signal message_index      : natural range 0 to 65535 := 0;
begin
  s_ready <= m_ready when state = MESSAGE else '1';
  m_data <= s_data;
  m_valid <= s_valid when state = MESSAGE else '0';
  m_sop <= '1' when state = MESSAGE and message_index = 0 else '0';
  m_eop <= '1' when state = MESSAGE and message_remaining = 1 else '0';
  m_sequence <= packet_sequence_r + to_unsigned(message_number, 64);
  expected_sequence <= expected_sequence_r;

  process (clk)
    variable count_value  : natural range 0 to 65535;
    variable length_value : natural range 0 to 65535;
    variable next_expected : unsigned(63 downto 0);
  begin
    if rising_edge(clk) then
      gap_pulse <= '0';
      malformed_pulse <= '0';
      heartbeat_pulse <= '0';

      if rst = '1' then
        state <= HEADER;
        header_index <= 0;
        sequence_shift <= (others => '0');
        packet_sequence_r <= (others => '0');
        expected_sequence_r <= (others => '0');
        expected_valid <= '0';
        count_high <= (others => '0');
        message_count <= 0;
        message_number <= 0;
        message_length_high <= (others => '0');
        message_remaining <= 0;
        message_index <= 0;
      elsif s_valid = '1' and s_ready = '1' then
        case state is
          when HEADER =>
            if header_index = 0 and s_sop = '0' then
              malformed_pulse <= '1';
            end if;

            if header_index >= 10 and header_index <= 17 then
              if s_eop = '1' then
                malformed_pulse <= '1';
                state <= HEADER;
                header_index <= 0;
              else
                sequence_shift <= sequence_shift(55 downto 0) & unsigned(s_data);
                header_index <= header_index + 1;
              end if;
            elsif header_index = 18 then
              if s_eop = '1' then
                malformed_pulse <= '1';
                state <= HEADER;
                header_index <= 0;
              else
                count_high <= s_data;
                header_index <= header_index + 1;
              end if;
            elsif header_index = 19 then
              count_value := to_integer(unsigned(count_high & s_data));
              packet_sequence_r <= sequence_shift;
              message_count <= count_value;
              message_number <= 0;

              if expected_valid = '1' and sequence_shift /= expected_sequence_r then
                gap_pulse <= '1';
              end if;
              next_expected := sequence_shift + to_unsigned(count_value, 64);
              expected_sequence_r <= next_expected;
              expected_valid <= '1';

              if count_value = 0 then
                heartbeat_pulse <= '1';
                if s_eop = '1' then
                  state <= HEADER;
                  header_index <= 0;
                else
                  state <= EXPECT_END;
                end if;
              elsif s_eop = '1' then
                malformed_pulse <= '1';
                state <= HEADER;
                header_index <= 0;
              else
                state <= LENGTH_HIGH;
                header_index <= 0;
              end if;
            else
              if s_eop = '1' then
                malformed_pulse <= '1';
                state <= HEADER;
                header_index <= 0;
              else
                header_index <= header_index + 1;
              end if;
            end if;

          when LENGTH_HIGH =>
            if s_eop = '1' then
              malformed_pulse <= '1';
              state <= HEADER;
            else
              message_length_high <= s_data;
              state <= LENGTH_LOW;
            end if;

          when LENGTH_LOW =>
            length_value := to_integer(unsigned(message_length_high & s_data));
            if length_value = 0 or s_eop = '1' then
              malformed_pulse <= '1';
              state <= HEADER;
            else
              message_remaining <= length_value;
              message_index <= 0;
              state <= MESSAGE;
            end if;

          when MESSAGE =>
            if message_remaining = 1 then
              if message_number + 1 = message_count then
                if s_eop = '1' then
                  state <= HEADER;
                  header_index <= 0;
                else
                  state <= EXPECT_END;
                end if;
              elsif s_eop = '1' then
                malformed_pulse <= '1';
                state <= HEADER;
                header_index <= 0;
              else
                message_number <= message_number + 1;
                state <= LENGTH_HIGH;
              end if;
              message_remaining <= 0;
              message_index <= 0;
            elsif s_eop = '1' then
              malformed_pulse <= '1';
              state <= HEADER;
              header_index <= 0;
              message_remaining <= 0;
              message_index <= 0;
            else
              message_remaining <= message_remaining - 1;
              message_index <= message_index + 1;
            end if;

          when EXPECT_END =>
            malformed_pulse <= '1';
            if s_eop = '1' then
              state <= HEADER;
              header_index <= 0;
            end if;
        end case;
      end if;
    end if;
  end process;
end architecture;
