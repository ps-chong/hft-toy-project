-- eth_ipv4_udp_rx: payload extraction, filtering, and fault reporting.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library vunit_lib;
  context vunit_lib.vunit_context;

library hft;
  use hft.hft_types_pkg.all;
  use hft.hft_tb_pkg.all;

entity tb_eth_ipv4_udp_rx is
  generic (
    runner_cfg : string;
    vector_dir : string
  );
end entity tb_eth_ipv4_udp_rx;

architecture tb of tb_eth_ipv4_udp_rx is

  constant clk_period : time := 6.4 ns;

  signal clk : std_logic := '0';
  signal rst : std_logic := '1';

  signal rx_beat     : axis64_t := axis64_idle;
  signal payload     : axis64_t;
  signal first       : std_logic;
  signal dropped     : unsigned(31 downto 0);
  signal drop        : std_logic;
  signal malformed   : std_logic;
  signal frame_error : std_logic;
  signal packet      : std_logic;

  signal rx_bytes     : byte_array_t(0 to 511) := (others => x"00");
  signal rx_count     : natural                := 0;
  signal first_count  : natural                := 0;
  signal last_count   : natural                := 0;
  signal drop_count   : natural                := 0;
  signal bad_count    : natural                := 0;
  signal error_count  : natural                := 0;
  signal packet_count : natural                := 0;

begin

  clk <= not clk after clk_period / 2;

  dut : entity hft.eth_ipv4_udp_rx
    port map (
      clk               => clk,
      rst               => rst,
      s_axis            => rx_beat,
      m_payload         => payload,
      m_first           => first,
      dropped_count     => dropped,
      drop_pulse        => drop,
      malformed_pulse   => malformed,
      frame_error_pulse => frame_error,
      packet_pulse      => packet
    );

  monitor : process (clk) is

    variable count : natural;

  begin

    if rising_edge(clk) then
      if (rst = '1') then
        count        := 0;
        first_count  <= 0;
        last_count   <= 0;
        drop_count   <= 0;
        bad_count    <= 0;
        error_count  <= 0;
        packet_count <= 0;
      else
        if (payload.valid = '1') then

          for lane in 0 to 7 loop

            if (payload.keep(lane) = '1') then
              rx_bytes(count) <= lane_byte(payload.data, lane);
              count           := count + 1;
            end if;

          end loop;

          if (payload.last = '1') then
            last_count <= last_count + 1;
          end if;
        end if;
        if (first = '1') then
          first_count <= first_count + 1;
        end if;
        if (drop = '1') then
          drop_count <= drop_count + 1;
        end if;
        if (malformed = '1') then
          bad_count <= bad_count + 1;
        end if;
        if (frame_error = '1') then
          error_count <= error_count + 1;
        end if;
        if (packet = '1') then
          packet_count <= packet_count + 1;
        end if;
      end if;
      rx_count <= count;
    end if;

  end process monitor;

  main : process is

    variable vector : file_buffer_t;
    variable length : natural;
    -- Header (42) plus a 20-byte payload.
    variable frame : byte_array_t(0 to 61);

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

  begin

    test_runner_setup(runner, runner_cfg);
    read_bytes(vector_dir & "/mold_mixed.bin", vector, length);

    while test_suite loop

      reset;

      if run("forwards exactly the udp payload") then
        send_frame(clk, rx_beat, udp_frame(vector(0 to length - 1)));
        settle;
        check_equal(rx_count, length, "payload bytes");
        check_equal(first_count, 1, "first pulses");
        check_equal(last_count, 1, "last beats");
        check_equal(packet_count, 1, "packets");
        check_equal(drop_count + bad_count + error_count, 0, "faults");

        for index in 0 to length - 1 loop

          check_equal(rx_bytes(index), vector(index), "payload byte " & integer'image(index));

        end loop;

      elsif run("short payload in a padded frame") then
        send_frame(clk, rx_beat, udp_frame(vector(0 to 5)));
        settle;
        check_equal(rx_count, 6, "padding must not be forwarded");
        check_equal(last_count, 1);
        check_equal(bad_count, 0);
      elsif run("drops traffic for another port") then
        send_frame(clk, rx_beat, udp_frame(vector(0 to length - 1), dst_port => 47002));
        settle;
        check_equal(rx_count, 0);
        check_equal(drop_count, 1);
        check_equal(dropped, to_unsigned(1, 32));
        check_equal(bad_count, 0, "a filter miss is not malformed");
      elsif run("bad ipv4 checksum is malformed") then
        frame     := udp_frame(vector(0 to 19));
        frame(24) := frame(24) xor x"01";
        send_frame(clk, rx_beat, frame);
        settle;
        check_equal(bad_count, 1);
        check_equal(rx_count, 0);
        check_equal(dropped, to_unsigned(1, 32));
      elsif run("mac frame error is reported") then
        send_frame(clk, rx_beat, udp_frame(vector(0 to length - 1)), mac_error => '1');
        settle;
        check_equal(error_count, 1);
      end if;

    end loop;

    test_runner_cleanup(runner);
    wait;

  end process main;

end architecture tb;
