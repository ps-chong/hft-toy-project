-- moldudp64_rx: message splitting at every lane alignment, sequence rules.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library vunit_lib;
  context vunit_lib.vunit_context;

library hft;
  use hft.hft_types_pkg.all;
  use hft.hft_tb_pkg.all;

entity tb_moldudp64_rx is
  generic (
    runner_cfg : string;
    vector_dir : string
  );
end entity tb_moldudp64_rx;

architecture tb of tb_moldudp64_rx is

  constant clk_period : time := 6.4 ns;

  signal clk : std_logic := '0';
  signal rst : std_logic := '1';

  signal beat      : axis64_t  := axis64_idle;
  signal first     : std_logic := '0';
  signal message   : itch_message_t;
  signal valid     : std_logic;
  signal gap       : std_logic;
  signal duplicate : std_logic;
  signal malformed : std_logic;
  signal heartbeat : std_logic;
  signal expected  : unsigned(63 downto 0);

  type messages_t is array (0 to 15) of itch_message_t;

  signal received        : messages_t := (others => itch_message_reset);
  signal received_count  : natural    := 0;
  signal gap_count       : natural    := 0;
  signal duplicate_count : natural    := 0;
  signal malformed_count : natural    := 0;
  signal heartbeat_count : natural    := 0;

begin

  clk <= not clk after clk_period / 2;

  dut : entity hft.moldudp64_rx
    port map (
      clk               => clk,
      rst               => rst,
      s_payload         => beat,
      s_first           => first,
      s_ingress_cycles  => to_unsigned(77, 64),
      m_message         => message,
      m_valid           => valid,
      gap_pulse         => gap,
      duplicate_pulse   => duplicate,
      malformed_pulse   => malformed,
      heartbeat_pulse   => heartbeat,
      expected_sequence => expected
    );

  monitor : process (clk) is
  begin

    if rising_edge(clk) then
      if (rst = '1') then
        received_count  <= 0;
        gap_count       <= 0;
        duplicate_count <= 0;
        malformed_count <= 0;
        heartbeat_count <= 0;
      else
        if (valid = '1') then
          received(received_count) <= message;
          received_count           <= received_count + 1;
        end if;
        if (gap = '1') then
          gap_count <= gap_count + 1;
        end if;
        if (duplicate = '1') then
          duplicate_count <= duplicate_count + 1;
        end if;
        if (malformed = '1') then
          malformed_count <= malformed_count + 1;
        end if;
        if (heartbeat = '1') then
          heartbeat_count <= heartbeat_count + 1;
        end if;
      end if;
    end if;

  end process monitor;

  main : process is

    variable mixed     : file_buffer_t;
    variable mixed_len : natural;
    variable add       : file_buffer_t;
    variable add_len   : natural;
    variable beat_file : file_buffer_t;
    variable beat_len  : natural;
    variable cut       : file_buffer_t;
    variable cut_len   : natural;

    procedure reset is
    begin

      rst <= '1';
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      rst <= '0';
      wait until rising_edge(clk);

    end procedure reset;

    procedure settle is
    begin

      for cycle in 1 to 4 loop

        wait until rising_edge(clk);

      end loop;

      wait for 1 ns;

    end procedure settle;

    -- Every message in the mixed vector, compared with its bytes in place.

    procedure check_mixed is

      variable offset : natural;
      variable size   : natural;

    begin

      offset := 20;
      check_equal(received_count, 7, "messages");

      for index in 0 to 6 loop

        size   := to_integer(be16(mixed(offset), mixed(offset + 1)));
        offset := offset + 2;
        check_equal(to_integer(received(index).length), size, "length of message " & integer'image(index));
        check_equal(received(index).feed_sequence, to_unsigned(10 + index, 64), "sequence");
        check_equal(received(index).ingress_cycles, to_unsigned(77, 64), "ingress timestamp");

        for byte_index in 0 to size - 1 loop

          check_equal(received(index).bytes(byte_index), mixed(offset + byte_index),
                      "message " & integer'image(index) & " byte " & integer'image(byte_index));

        end loop;

        offset := offset + size;

      end loop;

    end procedure check_mixed;

  begin

    test_runner_setup(runner, runner_cfg);
    read_bytes(vector_dir & "/mold_mixed.bin", mixed, mixed_len);
    read_bytes(vector_dir & "/mold_add_order.bin", add, add_len);
    read_bytes(vector_dir & "/mold_heartbeat.bin", beat_file, beat_len);
    read_bytes(vector_dir & "/mold_truncated.bin", cut, cut_len);

    while test_suite loop

      reset;

      if run("splits messages at every lane alignment") then

        for lane in 0 to 7 loop

          reset;
          send_payload(clk, beat, first, mixed(0 to mixed_len - 1), lane => lane);
          settle;
          info("start lane " & integer'image(lane));
          check_mixed;
          check_equal(malformed_count, 0);
          check_equal(expected, to_unsigned(17, 64));

        end loop;

      elsif run("duplicate packets produce nothing") then
        send_payload(clk, beat, first, add(0 to add_len - 1));
        send_payload(clk, beat, first, add(0 to add_len - 1));
        settle;
        check_equal(received_count, 1);
        check_equal(duplicate_count, 1);
        check_equal(gap_count, 0);
        check_equal(expected, to_unsigned(2, 64));
      elsif run("a sequence jump is a gap") then
        send_payload(clk, beat, first, add(0 to add_len - 1));
        send_payload(clk, beat, first, mixed(0 to mixed_len - 1));
        settle;
        check_equal(gap_count, 1);
        check_equal(received_count, 8);
        check_equal(expected, to_unsigned(17, 64));
      elsif run("heartbeats carry no messages") then
        send_payload(clk, beat, first, beat_file(0 to beat_len - 1));
        settle;
        check_equal(heartbeat_count, 1);
        check_equal(received_count, 0);
        check_equal(malformed_count, 0);
      elsif run("truncated packets are malformed") then
        send_payload(clk, beat, first, cut(0 to cut_len - 1));
        settle;
        check_equal(malformed_count, 1);
        check_equal(received_count, 0);
      elsif run("a malformed packet does not advance the expected sequence") then
        read_bytes(vector_dir & "/mold_cancel.bin", cut, cut_len);
        send_payload(clk, beat, first, add(0 to add_len - 1));
        -- Sequence 2, truncated inside its only message.
        send_payload(clk, beat, first, cut(0 to cut_len - 4));
        settle;
        check_equal(malformed_count, 1);
        check_equal(expected, to_unsigned(2, 64), "unchanged by the malformed packet");
        -- The retransmitted sequence 2 is in order, not a gap.
        send_payload(clk, beat, first, cut(0 to cut_len - 1));
        settle;
        check_equal(gap_count, 0);
        check_equal(received_count, 2);
        check_equal(expected, to_unsigned(3, 64));
      elsif run("back to back packets with no idle cycle") then
        send_payload(clk, beat, first, add(0 to add_len - 1), idle => 0);
        send_payload(clk, beat, first, mixed(0 to mixed_len - 1), lane => 5, idle => 0);
        settle;
        check_equal(received_count, 8);
        check_equal(malformed_count, 0);
      end if;

    end loop;

    test_runner_cleanup(runner);
    wait;

  end process main;

end architecture tb;
