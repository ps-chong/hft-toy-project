-- telemetry_udp_tx: frame layout against the generated payload vector, a
-- valid IPv4 header, and drop-not-stall behaviour when the MAC backs up.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library vunit_lib;
  context vunit_lib.vunit_context;

library hft;
  use hft.hft_types_pkg.all;
  use hft.hft_tb_pkg.all;

entity tb_telemetry_udp_tx is
  generic (
    runner_cfg : string;
    vector_dir : string
  );
end entity tb_telemetry_udp_tx;

architecture tb of tb_telemetry_udp_tx is

  constant clk_period : time := 6.4 ns;

  signal clk : std_logic := '0';
  signal rst : std_logic := '1';

  signal event   : market_event_t := market_event_reset;
  signal event_v : std_logic      := '0';
  signal drops   : unsigned(31 downto 0);

  signal tdata  : std_logic_vector(63 downto 0);
  signal tkeep  : std_logic_vector(7 downto 0);
  signal tvalid : std_logic;
  signal tlast  : std_logic;
  signal tready : std_logic := '1';

  signal frame       : byte_array_t(0 to 127) := (others => x"00");
  signal frame_bytes : natural                := 0;
  signal frames      : natural                := 0;

begin

  clk <= not clk after clk_period / 2;

  dut : entity hft.telemetry_udp_tx
    port map (
      clk           => clk,
      rst           => rst,
      event_data    => event,
      event_valid   => event_v,
      status_flags  => x"00",
      rx_dropped    => (others => '0'),
      drop_count    => drops,
      m_axis_tdata  => tdata,
      m_axis_tkeep  => tkeep,
      m_axis_tvalid => tvalid,
      m_axis_tlast  => tlast,
      m_axis_tready => tready
    );

  -- Captures the most recent frame.
  capture : process (clk) is

    variable count : natural;

  begin

    if rising_edge(clk) then
      if (rst = '1') then
        count  := 0;
        frames <= 0;
      elsif ((tvalid = '1') and (tready = '1')) then

        for lane in 0 to 7 loop

          if (tkeep(lane) = '1') then
            frame(count) <= lane_byte(tdata, lane);
            count        := count + 1;
          end if;

        end loop;

        if (tlast = '1') then
          frame_bytes <= count;
          frames      <= frames + 1;
          count       := 0;
        end if;
      end if;
    end if;

  end process capture;

  main : process is

    variable vector : file_buffer_t;
    variable length : natural;
    variable sum    : unsigned(15 downto 0);
    variable sample : market_event_t;

    procedure reset is
    begin

      rst <= '1';
      wait until rising_edge(clk);
      rst <= '0';
      wait until rising_edge(clk);

    end procedure reset;

    procedure push_event is
    begin

      event   <= sample;
      event_v <= '1';
      wait until rising_edge(clk);
      event_v <= '0';
      wait until rising_edge(clk);

    end procedure push_event;

  begin

    test_runner_setup(runner, runner_cfg);
    read_bytes(vector_dir & "/telemetry_event.bin", vector, length);

    -- The event behind protocol/vectors/telemetry_event.bin.
    sample                 := market_event_reset;
    sample.kind            := event_add;
    sample.side            := side_buy;
    sample.feed_sequence   := to_unsigned(1, 64);
    sample.timestamp_ns    := to_unsigned(123456, 48);
    sample.order_reference := x"0102030405060708";
    sample.symbol          := x"41434D4520202020";
    sample.price           := to_unsigned(1234500, 64);
    sample.quantity        := to_unsigned(100, 32);
    sample.ingress_cycles  := to_unsigned(16, 64);

    while test_suite loop

      tready <= '1';
      reset;

      if run("frame matches the generated payload vector") then
        push_event;
        wait until rising_edge(clk) and frames = 1;
        wait for 1 ns;
        check_equal(frame_bytes, 106, "frame length");
        check_equal(std_logic_vector'(frame(12) & frame(13)), std_logic_vector'(x"0800"), "ethertype");
        check_equal(frame(23), std_logic_vector'(x"11"), "udp");
        check_equal(std_logic_vector'(frame(38) & frame(39)), std_logic_vector(to_unsigned(72, 16)),
                    "udp length");

        sum := (others => '0');

        for word in 0 to 9 loop

          sum := ones_add(sum, be16(frame(14 + (2 * word)), frame(15 + (2 * word))));

        end loop;

        check_equal(sum, to_unsigned(16#FFFF#, 16), "ipv4 header checksum");
        check_equal(to_hex(frame(42 to 105)), to_hex(vector(0 to length - 1)), "payload");
      elsif run("drops instead of stalling when the mac backs up") then
        tready <= '0';

        for index in 1 to 20 loop

          push_event;

        end loop;

        -- One frame in flight plus a full FIFO of 16; the rest dropped.
        check_equal(drops, to_unsigned(3, 32));
        tready <= '1';

        for cycle in 1 to 17 * 20 loop

          wait until rising_edge(clk);

        end loop;

        wait for 1 ns;
        check_equal(frames, 17);
      end if;

    end loop;

    test_runner_cleanup(runner);
    wait;

  end process main;

end architecture tb;
