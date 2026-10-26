-- hft_pipeline: end to end from UDP payload beats to approved events, and
-- the kill latch (fault dominance, edge-triggered clear, fail closed).

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library vunit_lib;
  context vunit_lib.vunit_context;

library hft;
  use hft.hft_types_pkg.all;
  use hft.hft_tb_pkg.all;

entity tb_hft_pipeline is
  generic (
    runner_cfg : string;
    vector_dir : string
  );
end entity tb_hft_pipeline;

architecture tb of tb_hft_pipeline is

  constant clk_period : time := 6.4 ns;

  signal clk : std_logic := '0';
  signal rst : std_logic := '1';

  signal beat  : axis64_t  := axis64_idle;
  signal first : std_logic := '0';

  signal clear_faults   : std_logic := '0';
  signal external_kill  : std_logic := '0';
  signal external_fault : std_logic := '0';
  signal event_ready    : std_logic := '1';

  constant limits : risk_limits_t :=
  (
    max_quantity  => to_unsigned(1000, 32),
    price_floor   => to_unsigned(1, 64),
    price_ceiling => to_unsigned(1000000000, 64)
  );

  signal event_o     : market_event_t;
  signal event_valid : std_logic;
  signal flushing    : std_logic;
  signal killed      : std_logic;
  signal gap         : std_logic;
  signal malformed   : std_logic;
  signal overflow    : std_logic;
  signal rejected    : std_logic;
  signal expected    : unsigned(63 downto 0);

  signal event_count  : natural        := 0;
  signal reject_count : natural        := 0;
  signal last_event   : market_event_t := market_event_reset;

begin

  clk <= not clk after clk_period / 2;

  dut : entity hft.hft_pipeline
    generic map (
      set_bits => 4
    )
    port map (
      clk              => clk,
      rst              => rst,
      s_payload        => beat,
      s_first          => first,
      s_ingress_cycles => (others => '0'),
      trading_enable   => '1',
      external_kill    => external_kill,
      clear_faults     => clear_faults,
      external_fault   => external_fault,
      limits           => limits,
      book_locate      => (others => '0'),
      -- No strategy: risk_reject_pulse then counts event rejections only.
      strategy_select   => x"FF",
      anchor_price      => to_unsigned(1234000, 32),
      decoded_event     => open,
      decoded_valid     => open,
      approved_event    => open,
      approved_valid    => open,
      event_out         => event_o,
      event_valid       => event_valid,
      event_ready       => event_ready,
      signal_valid      => open,
      signal_out        => open,
      best_bid_price    => open,
      best_bid_qty      => open,
      best_ask_price    => open,
      best_ask_qty      => open,
      book_valid        => open,
      book_flushing     => flushing,
      killed            => killed,
      gap_pulse         => gap,
      duplicate_pulse   => open,
      malformed_pulse   => malformed,
      unknown_pulse     => open,
      overflow_pulse    => overflow,
      risk_reject_pulse => rejected,
      expected_sequence => expected
    );

  count : process (clk) is
  begin

    if rising_edge(clk) then
      if (rst = '1') then
        event_count  <= 0;
        reject_count <= 0;
      else
        if ((event_valid = '1') and (event_ready = '1')) then
          event_count <= event_count + 1;
          last_event  <= event_o;
        end if;
        if (rejected = '1') then
          reject_count <= reject_count + 1;
        end if;
      end if;
    end if;

  end process count;

  main : process is

    variable add     : file_buffer_t;
    variable add_n   : natural;
    variable mixed   : file_buffer_t;
    variable mixed_n : natural;
    variable cut     : file_buffer_t;
    variable cut_n   : natural;

    procedure pulse_clear is
    begin

      clear_faults <= '1';
      wait until rising_edge(clk);
      clear_faults <= '0';
      wait until rising_edge(clk);
      wait for 1 ns;

    end procedure pulse_clear;

    procedure reset_and_arm is
    begin

      rst <= '1';
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      rst <= '0';
      wait until rising_edge(clk);
      wait for 1 ns;
      check_equal(killed, '1', "fails closed out of reset");
      pulse_clear;
      check_equal(killed, '0', "armed");
      wait until rising_edge(clk) and flushing = '0';

    end procedure reset_and_arm;

    procedure settle is
    begin

      for cycle in 1 to 12 loop

        wait until rising_edge(clk);

      end loop;

      wait for 1 ns;

    end procedure settle;

  begin

    test_runner_setup(runner, runner_cfg);
    read_bytes(vector_dir & "/mold_add_order.bin", add, add_n);
    read_bytes(vector_dir & "/mold_mixed.bin", mixed, mixed_n);
    read_bytes(vector_dir & "/mold_truncated.bin", cut, cut_n);

    while test_suite loop

      event_ready    <= '1';
      external_kill  <= '0';
      external_fault <= '0';
      reset_and_arm;

      if run("packet to approved event") then
        send_payload(clk, beat, first, add(0 to add_n - 1));
        settle;
        check_equal(event_count, 1);
        check_equal(last_event.kind, event_add);
        check_equal(last_event.quantity, to_unsigned(100, 32));
        check_equal(last_event.price, to_unsigned(1234500, 64));
        check_equal(last_event.feed_sequence, to_unsigned(1, 64));
        check_equal(last_event.flags, std_logic_vector'(x"00"));
        check_equal(expected, to_unsigned(2, 64));
        check_equal(killed, '0');
      elsif run("faults dominate a simultaneous clear") then
        external_fault <= '1';
        clear_faults   <= '1';
        wait until rising_edge(clk);
        external_fault <= '0';
        wait until rising_edge(clk);
        wait for 1 ns;
        check_equal(killed, '1', "fault and clear in one cycle");
        -- clear_faults is still high: no new edge, so no re-arm.
        settle;
        check_equal(killed, '1', "a held clear is not a new clear");
        clear_faults <= '0';
        wait until rising_edge(clk);
        pulse_clear;
        check_equal(killed, '0');
      elsif run("external kill blocks the clear") then
        external_fault <= '1';
        wait until rising_edge(clk);
        external_fault <= '0';
        external_kill  <= '1';
        pulse_clear;
        external_kill  <= '0';
        wait until rising_edge(clk);
        wait for 1 ns;
        check_equal(killed, '1', "latch stays set after the external kill drops");
      elsif run("a gap kills and blocks entries but not lifecycle events") then
        send_payload(clk, beat, first, add(0 to add_n - 1));
        send_payload(clk, beat, first, mixed(0 to mixed_n - 1));
        settle;
        check_equal(killed, '1');
        -- A and F blocked; E, C, X, U, D forwarded.
        check_equal(reject_count, 2);
        check_equal(event_count, 1 + 5);
      elsif run("a malformed packet kills") then
        send_payload(clk, beat, first, cut(0 to cut_n - 1));
        settle;
        check_equal(killed, '1');
      elsif run("a stalled event consumer is an overflow fault") then
        event_ready <= '0';
        send_payload(clk, beat, first, mixed(0 to mixed_n - 1));
        settle;
        check_equal(killed, '1');
      end if;

    end loop;

    test_runner_cleanup(runner);
    wait;

  end process main;

end architecture tb;
