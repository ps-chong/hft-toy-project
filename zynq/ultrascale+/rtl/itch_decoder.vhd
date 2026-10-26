-- ITCH 5.0 decoder for complete, lane-0 aligned messages from moldudp64_rx.
--
-- Field extraction uses the generated offsets in hft_protocol_pkg with
-- constant indices, so it synthesizes to wiring. Normalization matches the
-- A53 software model (hft-protocol ItchMessage::to_event) field for field:
-- F (add with MPID) becomes an add, C (executed with price) becomes an
-- execute carrying the execution price, U carries both references, and P
-- becomes a trade. The first normalized event after a MoldUDP64 gap carries
-- the feed_gap flag, so the R5 can fail closed even when it is fed by
-- software.
--
-- Latency: one cycle. Throughput: one message per cycle (at most one arrives
-- per beat).

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

    s_message : in    itch_message_t;
    s_valid   : in    std_logic;
    s_gap     : in    std_logic;

    event_out   : out   market_event_t;
    event_valid : out   std_logic;

    malformed_pulse : out   std_logic;
    unknown_pulse   : out   std_logic
  );
end entity itch_decoder;

architecture rtl of itch_decoder is

  constant execution_price_offset : natural := ITCH_ORDER_EXECUTED_WITH_PRICE_EXECUTION_PRICE_OFFSET;

  signal event_r     : market_event_t := market_event_reset;
  signal valid_r     : std_logic      := '0';
  signal malformed_r : std_logic      := '0';
  signal unknown_r   : std_logic      := '0';
  signal gap_pending : std_logic      := '0';

  function expected_length (
    kind : byte_t
  ) return natural is
  begin

    case kind is

      when ITCH_SYSTEM_EVENT =>

        return ITCH_SYSTEM_EVENT_LENGTH;

      when ITCH_STOCK_DIRECTORY =>

        return ITCH_STOCK_DIRECTORY_LENGTH;

      when ITCH_ADD_ORDER =>

        return ITCH_ADD_ORDER_LENGTH;

      when ITCH_ADD_ORDER_MPID =>

        return ITCH_ADD_ORDER_MPID_LENGTH;

      when ITCH_ORDER_EXECUTED =>

        return ITCH_ORDER_EXECUTED_LENGTH;

      when ITCH_ORDER_EXECUTED_WITH_PRICE =>

        return ITCH_ORDER_EXECUTED_WITH_PRICE_LENGTH;

      when ITCH_ORDER_CANCEL =>

        return ITCH_ORDER_CANCEL_LENGTH;

      when ITCH_ORDER_DELETE =>

        return ITCH_ORDER_DELETE_LENGTH;

      when ITCH_ORDER_REPLACE =>

        return ITCH_ORDER_REPLACE_LENGTH;

      when ITCH_TRADE =>

        return ITCH_TRADE_LENGTH;

      when ITCH_CROSS_TRADE =>

        return ITCH_CROSS_TRADE_LENGTH;

      when others =>

        return 0;

    end case;

  end function expected_length;

  function valid_side (
    side : byte_t
  ) return boolean is
  begin

    return (side = side_buy) or (side = side_sell);

  end function valid_side;

begin

  event_out       <= event_r;
  event_valid     <= valid_r;
  malformed_pulse <= malformed_r;
  unknown_pulse   <= unknown_r;

  decode : process (clk) is

    variable bytes   : byte_array_t(0 to itch_buffer_bytes - 1);
    variable kind    : byte_t;
    variable decoded : market_event_t;
    variable emit    : boolean;
    variable side    : byte_t;

  begin

    if rising_edge(clk) then
      valid_r     <= '0';
      malformed_r <= '0';
      unknown_r   <= '0';

      if (rst = '1') then
        gap_pending <= '0';
      else
        if (s_gap = '1') then
          gap_pending <= '1';
        end if;

        if (s_valid = '1') then
          bytes   := s_message.bytes;
          kind    := bytes(0);
          emit    := false;
          decoded := market_event_reset;

          decoded.feed_sequence  := s_message.feed_sequence;
          decoded.ingress_cycles := s_message.ingress_cycles;
          decoded.stock_locate   := be_field(bytes, ITCH_STOCK_LOCATE_OFFSET, 2);
          decoded.timestamp_ns   := be_field(bytes, ITCH_TIMESTAMP_OFFSET, 6);

          if (expected_length(kind) = 0) then
            unknown_r <= '1';
          elsif (to_integer(s_message.length) /= expected_length(kind)) then
            malformed_r <= '1';
          else

            case kind is

              when ITCH_ADD_ORDER | ITCH_ADD_ORDER_MPID =>

                -- F shares A's layout up to the attribution field.
                side := bytes(ITCH_ADD_ORDER_SIDE_OFFSET);
                if (valid_side(side)) then
                  decoded.kind            := event_add;
                  decoded.side            := side;
                  decoded.order_reference := be_field(bytes, ITCH_ADD_ORDER_ORDER_REFERENCE_OFFSET, 8);
                  decoded.quantity        := be_field(bytes, ITCH_ADD_ORDER_SHARES_OFFSET, 4);
                  decoded.symbol          := be_bytes(bytes, ITCH_ADD_ORDER_STOCK_OFFSET, 8);
                  decoded.price           := resize(be_field(bytes, ITCH_ADD_ORDER_PRICE_OFFSET, 4), 64);
                  emit                    := true;
                else
                  malformed_r <= '1';
                end if;

              when ITCH_ORDER_EXECUTED =>

                decoded.kind            := event_execute;
                decoded.order_reference := be_field(bytes, ITCH_ORDER_EXECUTED_ORDER_REFERENCE_OFFSET, 8);
                decoded.quantity        := be_field(bytes, ITCH_ORDER_EXECUTED_EXECUTED_SHARES_OFFSET, 4);
                emit                    := true;

              when ITCH_ORDER_EXECUTED_WITH_PRICE =>

                decoded.kind            := event_execute;
                decoded.order_reference := be_field(bytes, ITCH_ORDER_EXECUTED_WITH_PRICE_ORDER_REFERENCE_OFFSET, 8);
                decoded.quantity        := be_field(bytes, ITCH_ORDER_EXECUTED_WITH_PRICE_EXECUTED_SHARES_OFFSET, 4);
                decoded.price           := resize(be_field(bytes, execution_price_offset, 4), 64);
                emit                    := true;

              when ITCH_ORDER_CANCEL =>

                decoded.kind            := event_cancel;
                decoded.order_reference := be_field(bytes, ITCH_ORDER_CANCEL_ORDER_REFERENCE_OFFSET, 8);
                decoded.quantity        := be_field(bytes, ITCH_ORDER_CANCEL_CANCELLED_SHARES_OFFSET, 4);
                emit                    := true;

              when ITCH_ORDER_DELETE =>

                decoded.kind            := event_delete;
                decoded.order_reference := be_field(bytes, ITCH_ORDER_DELETE_ORDER_REFERENCE_OFFSET, 8);
                emit                    := true;

              when ITCH_ORDER_REPLACE =>

                decoded.kind                := event_replace;
                decoded.order_reference     := be_field(bytes, ITCH_ORDER_REPLACE_ORIGINAL_ORDER_REFERENCE_OFFSET, 8);
                decoded.new_order_reference := be_field(bytes, ITCH_ORDER_REPLACE_NEW_ORDER_REFERENCE_OFFSET, 8);
                decoded.quantity            := be_field(bytes, ITCH_ORDER_REPLACE_SHARES_OFFSET, 4);
                decoded.price               := resize(be_field(bytes, ITCH_ORDER_REPLACE_PRICE_OFFSET, 4), 64);
                emit                        := true;

              when ITCH_TRADE =>

                side := bytes(ITCH_TRADE_SIDE_OFFSET);
                if (valid_side(side)) then
                  decoded.kind            := event_trade;
                  decoded.side            := side;
                  decoded.order_reference := be_field(bytes, ITCH_TRADE_ORDER_REFERENCE_OFFSET, 8);
                  decoded.quantity        := be_field(bytes, ITCH_TRADE_SHARES_OFFSET, 4);
                  decoded.symbol          := be_bytes(bytes, ITCH_TRADE_STOCK_OFFSET, 8);
                  decoded.price           := resize(be_field(bytes, ITCH_TRADE_PRICE_OFFSET, 4), 64);
                  emit                    := true;
                else
                  malformed_r <= '1';
                end if;

              when others =>

                -- Well-formed but not an order-book event (S, R, Q).
                null;

            end case;

          end if;

          if (emit) then
            decoded.flags(EVENT_FLAG_FEED_GAP_BIT) := gap_pending or s_gap;
            gap_pending                            <= '0';
            event_r                                <= decoded;
            valid_r                                <= '1';
          end if;
        end if;
      end if;
    end if;

  end process decode;

end architecture rtl;
