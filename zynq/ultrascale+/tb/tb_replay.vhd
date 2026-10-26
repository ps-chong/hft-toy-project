-- RTL replay: feed a datagram capture (u16 big-endian length + UDP payload,
-- the format hft-plsim writes with --capture) through eth_ipv4_udp_rx and
-- hft_pipeline, and encode every decoded event as a 64-byte IPC record.
--
-- With expected_path set, the records must equal that file exactly (CI uses
-- the generated replay vectors; the demo uses the events hft-plsim produced
-- from the same capture). With events_path set, the records are written
-- there for inspection.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library vunit_lib;
  context vunit_lib.vunit_context;

library hft;
  use hft.hft_types_pkg.all;
  use hft.hft_tb_pkg.all;

entity tb_replay is
  generic (
    runner_cfg    : string;
    capture_path  : string;
    expected_path : string := "";
    events_path   : string := ""
  );
end entity tb_replay;

architecture tb of tb_replay is

  -- Trading stays closed: the replay compares decoded events, before risk.
  constant closed_limits : risk_limits_t :=
  (
    max_quantity  => (others => '0'),
    price_floor   => (others => '1'),
    price_ceiling => (others => '0')
  );

  constant clk_period : time := 6.4 ns;

  signal clk : std_logic := '0';
  signal rst : std_logic := '1';

  signal rx_beat : axis64_t := axis64_idle;
  signal payload : axis64_t;
  signal first   : std_logic;

  signal decoded   : market_event_t;
  signal decoded_v : std_logic;

  signal finished    : boolean := false;
  signal closed      : boolean := false;
  signal event_total : natural := 0;
  signal datagrams   : natural := 0;

begin

  clk <= not clk after clk_period / 2;

  rx : entity hft.eth_ipv4_udp_rx
    port map (
      clk               => clk,
      rst               => rst,
      s_axis            => rx_beat,
      m_payload         => payload,
      m_first           => first,
      dropped_count     => open,
      drop_pulse        => open,
      malformed_pulse   => open,
      frame_error_pulse => open,
      packet_pulse      => open
    );

  pipeline : entity hft.hft_pipeline
    generic map (
      set_bits => 4
    )
    port map (
      clk               => clk,
      rst               => rst,
      s_payload         => payload,
      s_first           => first,
      s_ingress_cycles  => (others => '0'),
      trading_enable    => '0',
      external_kill     => '1',
      clear_faults      => '0',
      external_fault    => '0',
      limits            => closed_limits,
      book_locate       => (others => '0'),
      strategy_select   => x"00",
      anchor_price      => (others => '0'),
      decoded_event     => decoded,
      decoded_valid     => decoded_v,
      approved_event    => open,
      approved_valid    => open,
      event_out         => open,
      event_valid       => open,
      event_ready       => '1',
      signal_valid      => open,
      signal_out        => open,
      best_bid_price    => open,
      best_bid_qty      => open,
      best_ask_price    => open,
      best_ask_qty      => open,
      book_valid        => open,
      book_flushing     => open,
      killed            => open,
      gap_pulse         => open,
      duplicate_pulse   => open,
      malformed_pulse   => open,
      unknown_pulse     => open,
      overflow_pulse    => open,
      risk_reject_pulse => open,
      expected_sequence => open
    );

  monitor : process is

    file     sink          : char_file_t;
    file     expected_file : char_file_t;
    variable record_v      : byte_array_t(0 to 63);
    variable value         : character;
    variable expected_v    : byte_array_t(0 to 63);
    variable count         : natural;

  begin

    if (events_path'length > 0) then
      file_open(sink, events_path, write_mode);
    end if;

    if (expected_path'length > 0) then
      file_open(expected_file, expected_path, read_mode);
    end if;

    while not finished loop

      wait until rising_edge(clk) or finished;

      if (rising_edge(clk) and (decoded_v = '1')) then
        record_v := encode_event(decoded);
        if (events_path'length > 0) then

          for index in record_v'range loop

            write(sink, character'val(to_integer(unsigned(record_v(index)))));

          end loop;

        end if;
        if (expected_path'length > 0) then
          if (endfile(expected_file)) then
            error("RTL produced more events than expected (event " & integer'image(count) & ")");
          else

            for index in expected_v'range loop

              read(expected_file, value);
              expected_v(index) := std_logic_vector(to_unsigned(character'pos(value), 8));

            end loop;

            check_equal(to_hex(record_v), to_hex(expected_v), "event " & integer'image(count));
          end if;
        end if;
        count := count + 1;
      end if;

    end loop;

    if (expected_path'length > 0) then
      check(endfile(expected_file), "RTL produced fewer events than expected");
      file_close(expected_file);
    end if;

    if (events_path'length > 0) then
      file_close(sink);
    end if;

    event_total <= count;
    closed      <= true;
    wait;

  end process monitor;

  main : process is

    file     capture  : char_file_t;
    variable high     : character;
    variable low      : character;
    variable value    : character;
    variable length   : natural;
    variable datagram : byte_array_t(0 to 2047);
    variable sent     : natural;

  begin

    test_runner_setup(runner, runner_cfg);

    while test_suite loop

      if run("rtl matches the software model on the capture") then
        rst <= '1';
        wait until rising_edge(clk);
        wait until rising_edge(clk);
        rst <= '0';
        wait until rising_edge(clk);

        file_open(capture, capture_path, read_mode);

        while not endfile(capture) loop

          read(capture, high);
          read(capture, low);
          length := (character'pos(high) * 256) + character'pos(low);

          for index in 0 to length - 1 loop

            read(capture, value);
            datagram(index) := std_logic_vector(to_unsigned(character'pos(value), 8));

          end loop;

          send_frame(clk, rx_beat, udp_frame(datagram(0 to length - 1)), idle => 2);
          sent := sent + 1;

        end loop;

        file_close(capture);

        for cycle in 1 to 32 loop

          wait until rising_edge(clk);

        end loop;

        finished  <= true;
        wait until closed;
        datagrams <= sent;
        info("replayed " & integer'image(sent) & " datagrams, " &
             integer'image(event_total) & " events");
        check(event_total > 0, "no events decoded");
      end if;

    end loop;

    test_runner_cleanup(runner);
    wait;

  end process main;

end architecture tb;
