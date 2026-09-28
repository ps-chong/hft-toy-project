library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library work;
  use work.hft_types_pkg.all;
  use work.hft_protocol_pkg.all;

entity itch_decoder is
  port (
    clk : in    std_logic;
    rst : in    std_logic;

    s_data     : in    byte_t;
    s_valid    : in    std_logic;
    s_sop      : in    std_logic;
    s_eop      : in    std_logic;
    s_sequence : in    unsigned(63 downto 0);
    s_ready    : out   std_logic;

    event_out   : out   market_event_t;
    event_valid : out   std_logic;
    event_ready : in    std_logic;

    malformed_pulse : out   std_logic;
    unknown_pulse   : out   std_logic
  );
end entity itch_decoder;

architecture rtl of itch_decoder is

  signal event_r       : market_event_t         := MARKET_EVENT_RESET;
  signal event_valid_r : std_logic              := '0';
  signal byte_index    : natural range 0 to 255 := 0;

  function expected_length (
    kind : byte_t
  ) return natural is
  begin

    case kind is

      when ITCH_SYSTEM_EVENT =>

        return 12;

      when ITCH_STOCK_DIRECTORY =>

        return 39;

      when ITCH_ADD_ORDER =>

        return 36;

      when ITCH_ADD_ORDER_MPID =>

        return 40;

      when ITCH_ORDER_EXECUTED =>

        return 31;

      when ITCH_ORDER_EXECUTED_WITH_PRICE =>

        return 36;

      when ITCH_ORDER_CANCEL =>

        return 23;

      when ITCH_ORDER_DELETE =>

        return 19;

      when ITCH_ORDER_REPLACE =>

        return 35;

      when ITCH_TRADE =>

        return 44;

      when ITCH_CROSS_TRADE =>

        return 40;

      when others =>

        return 0;

    end case;

  end function expected_length;

begin

  event_out   <= event_r;
  event_valid <= event_valid_r;
  s_ready     <= '1' when event_valid_r = '0' or event_ready = '1' else
                 '0';

  process (clk) is

    variable final_length : natural;

  begin

    if rising_edge(clk) then
      malformed_pulse <= '0';
      unknown_pulse   <= '0';

      if (rst = '1') then
        event_r       <= MARKET_EVENT_RESET;
        event_valid_r <= '0';
        byte_index    <= 0;
      else
        if (event_valid_r = '1' and event_ready = '1') then
          event_valid_r <= '0';
        end if;

        if (s_valid = '1' and s_ready = '1') then
          if (s_sop = '1') then
            event_r               <= MARKET_EVENT_RESET;
            event_r.kind          <= s_data;
            event_r.feed_sequence <= s_sequence;
            byte_index            <= 0;
          end if;

          if (byte_index >= 5 and byte_index <= 10) then
            event_r.timestamp_ns <= unsigned(
                                             shift_append(std_logic_vector(event_r.timestamp_ns), s_data)
                                           );
          end if;

          if (byte_index >= 11 and byte_index <= 18) then
            event_r.order_reference <= unsigned(
                                                shift_append(std_logic_vector(event_r.order_reference), s_data)
                                              );
          end if;

          if (event_r.kind = ITCH_ADD_ORDER or
              event_r.kind = ITCH_ADD_ORDER_MPID) then
            if (byte_index = 19) then
              event_r.side <= s_data;
            elsif (byte_index >= 20 and byte_index <= 23) then
              event_r.quantity <= unsigned(
                                           shift_append(std_logic_vector(event_r.quantity), s_data)
                                         );
            elsif (byte_index >= 24 and byte_index <= 31) then
              event_r.symbol <= shift_append(event_r.symbol, s_data);
            elsif (byte_index >= 32 and byte_index <= 35) then
              event_r.price(31 downto 0) <= unsigned(
                                                     shift_append(std_logic_vector(event_r.price(31 downto 0)), s_data)
                                                   );
            end if;
          elsif (event_r.kind = ITCH_ORDER_CANCEL or
                 event_r.kind = ITCH_ORDER_EXECUTED or
                 event_r.kind = ITCH_ORDER_EXECUTED_WITH_PRICE) then
            if (byte_index >= 19 and byte_index <= 22) then
              event_r.quantity <= unsigned(
                                           shift_append(std_logic_vector(event_r.quantity), s_data)
                                         );
            end if;
          end if;

          if (s_eop = '1') then
            final_length := byte_index + 1;
            if (expected_length(event_r.kind) = 0) then
              unknown_pulse <= '1';
            elsif (final_length /= expected_length(event_r.kind)) then
              malformed_pulse <= '1';
            else
              event_valid_r <= '1';
            end if;
            byte_index <= 0;
          else
            byte_index <= byte_index + 1;
          end if;
        end if;
      end if;
    end if;

  end process;

end architecture rtl;
