-- itch_decoder: normalization checked byte for byte against the generated
-- replay expectation (the same bytes the A53 software model produces).

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library vunit_lib;
  context vunit_lib.vunit_context;

library hft;
  use hft.hft_types_pkg.all;
  use hft.hft_tb_pkg.all;

entity tb_itch_decoder is
  generic (
    runner_cfg : string;
    vector_dir : string
  );
end entity tb_itch_decoder;

architecture tb of tb_itch_decoder is

  constant clk_period : time := 6.4 ns;

  signal clk : std_logic := '0';
  signal rst : std_logic := '1';

  signal message   : itch_message_t := itch_message_reset;
  signal valid     : std_logic      := '0';
  signal gap       : std_logic      := '0';
  signal event     : market_event_t;
  signal event_v   : std_logic;
  signal malformed : std_logic;
  signal unknown   : std_logic;

  type events_t is array (0 to 15) of market_event_t;

  signal events          : events_t := (others => market_event_reset);
  signal event_count     : natural  := 0;
  signal malformed_count : natural  := 0;
  signal unknown_count   : natural  := 0;

begin

  clk <= not clk after clk_period / 2;

  dut : entity hft.itch_decoder
    port map (
      clk             => clk,
      rst             => rst,
      s_message       => message,
      s_valid         => valid,
      s_gap           => gap,
      event_out       => event,
      event_valid     => event_v,
      malformed_pulse => malformed,
      unknown_pulse   => unknown
    );

  monitor : process (clk) is
  begin

    if rising_edge(clk) then
      if (rst = '1') then
        event_count     <= 0;
        malformed_count <= 0;
        unknown_count   <= 0;
      else
        if (event_v = '1') then
          events(event_count) <= event;
          event_count         <= event_count + 1;
        end if;
        if (malformed = '1') then
          malformed_count <= malformed_count + 1;
        end if;
        if (unknown = '1') then
          unknown_count <= unknown_count + 1;
        end if;
      end if;
    end if;

  end process monitor;

  main : process is

    variable mixed    : file_buffer_t;
    variable mixed_n  : natural;
    variable expected : file_buffer_t;
    variable expect_n : natural;

    procedure reset is
    begin

      rst <= '1';
      wait until rising_edge(clk);
      rst <= '0';
      wait until rising_edge(clk);

    end procedure reset;

    procedure drive_message (
      bytes    : byte_array_t;
      feed_seq : natural
    ) is

      variable next_message : itch_message_t;

    begin

      next_message := itch_message_reset;

      for index in 0 to bytes'length - 1 loop

        if (index < itch_buffer_bytes) then
          next_message.bytes(index) := bytes(bytes'low + index);
        end if;

      end loop;

      next_message.length        := to_unsigned(bytes'length, 7);
      next_message.feed_sequence := to_unsigned(feed_seq, 64);
      message                    <= next_message;
      valid                      <= '1';
      wait until rising_edge(clk);
      valid                      <= '0';
      wait until rising_edge(clk);

    end procedure drive_message;

    procedure settle is
    begin

      wait until rising_edge(clk);
      wait until rising_edge(clk);
      wait for 1 ns;

    end procedure settle;

    -- Message `index` of the mixed vector.

    procedure push_mixed (
      index : natural
    ) is

      variable offset : natural;
      variable size   : natural;

    begin

      offset := 20;

      for skip in 0 to index loop

        size := to_integer(be16(mixed(offset), mixed(offset + 1)));

        if (skip < index) then
          offset := offset + 2 + size;
        end if;

      end loop;

      drive_message(mixed(offset + 2 to offset + 1 + size), 10 + index);

    end procedure push_mixed;

  begin

    test_runner_setup(runner, runner_cfg);
    read_bytes(vector_dir & "/mold_mixed.bin", mixed, mixed_n);
    read_bytes(vector_dir & "/replay_expected.bin", expected, expect_n);

    while test_suite loop

      reset;

      if run("normalizes every book message like the software model") then
        -- The replay session reaches the mixed packet through a gap.
        gap <= '1';
        wait until rising_edge(clk);
        gap <= '0';

        for index in 0 to 6 loop

          push_mixed(index);

        end loop;

        settle;
        check_equal(event_count, 7);

        for index in 0 to 6 loop

          check_equal(to_hex(encode_event(events(index))),
                      to_hex(expected((index + 2) * 64 to ((index + 3) * 64) - 1)),
                      "event " & integer'image(index));

        end loop;

        check_equal(malformed_count, 0);
      elsif run("wrong length for a known type is malformed") then
        push_mixed(0);
        settle;
        check_equal(event_count, 1);
        -- An add order one byte short.
        drive_message(mixed(22 to 22 + 34), 11);
        settle;
        check_equal(event_count, 1);
        check_equal(malformed_count, 1);
      elsif run("invalid side is malformed") then
        mixed(22 + 19) := x"58";
        drive_message(mixed(22 to 22 + 35), 10);
        settle;
        check_equal(event_count, 0);
        check_equal(malformed_count, 1);
      elsif run("unknown types are reported, not decoded") then
        drive_message((x"5A", x"00", x"01", x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00"), 3);
        settle;
        check_equal(event_count, 0);
        check_equal(unknown_count, 1);
        check_equal(malformed_count, 0);
      elsif run("system events are well formed but not book events") then
        drive_message((x"53", x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"4F"), 4);
        settle;
        check_equal(event_count, 0);
        check_equal(unknown_count, 0);
        check_equal(malformed_count, 0);
      end if;

    end loop;

    test_runner_cleanup(runner);
    wait;

  end process main;

end architecture tb;
