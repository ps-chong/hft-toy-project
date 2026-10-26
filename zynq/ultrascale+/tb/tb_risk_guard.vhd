-- risk_guard: entry gating on limits, enable and kill; lifecycle passthrough;
-- signal gating.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library vunit_lib;
  context vunit_lib.vunit_context;

library hft;
  use hft.hft_types_pkg.all;

entity tb_risk_guard is
  generic (
    runner_cfg : string
  );
end entity tb_risk_guard;

architecture tb of tb_risk_guard is

  -- vunit_context also exports a byte_t.

  subtype byte_t is hft.hft_types_pkg.byte_t;

  constant clk_period : time := 6.4 ns;

  signal clk : std_logic := '0';
  signal rst : std_logic := '1';

  signal event      : market_event_t := market_event_reset;
  signal event_v    : std_logic      := '0';
  signal proposal   : signal_t       := signal_reset;
  signal proposal_v : std_logic      := '0';
  signal enable     : std_logic      := '1';
  signal killed     : std_logic      := '0';
  signal limits     : risk_limits_t  :=
        (
        max_quantity  => to_unsigned(1000, 32),
        price_floor   => to_unsigned(100, 64),
        price_ceiling => to_unsigned(2000000, 64)
       );

  signal approved     : market_event_t;
  signal approved_v   : std_logic;
  signal approved_sig : signal_t;
  signal approved_s_v : std_logic;
  signal ev_reject    : std_logic;
  signal sig_reject   : std_logic;

  signal passed           : natural := 0;
  signal rejected         : natural := 0;
  signal sig_passed       : natural := 0;
  signal sig_reject_count : natural := 0;

begin

  clk <= not clk after clk_period / 2;

  dut : entity hft.risk_guard
    port map (
      clk                 => clk,
      rst                 => rst,
      event_in            => event,
      event_valid         => event_v,
      signal_in           => proposal,
      signal_vld          => proposal_v,
      trading_enable      => enable,
      killed              => killed,
      limits              => limits,
      approved_event      => approved,
      approved_valid      => approved_v,
      approved_signal     => approved_sig,
      approved_sig_vld    => approved_s_v,
      event_reject_pulse  => ev_reject,
      signal_reject_pulse => sig_reject
    );

  count : process (clk) is
  begin

    if rising_edge(clk) then
      if (rst = '1') then
        passed           <= 0;
        rejected         <= 0;
        sig_passed       <= 0;
        sig_reject_count <= 0;
      else
        if (approved_v = '1') then
          passed <= passed + 1;
        end if;
        if (ev_reject = '1') then
          rejected <= rejected + 1;
        end if;
        if (approved_s_v = '1') then
          sig_passed <= sig_passed + 1;
        end if;
        if (sig_reject = '1') then
          sig_reject_count <= sig_reject_count + 1;
        end if;
      end if;
    end if;

  end process count;

  main : process is

    procedure reset is
    begin

      rst <= '1';
      wait until rising_edge(clk);
      rst <= '0';
      -- Limits and enable are registered once.
      wait until rising_edge(clk);
      wait until rising_edge(clk);

    end procedure reset;

    procedure send (
      kind  : byte_t;
      side  : byte_t;
      qty   : natural;
      price : natural
    ) is

      variable next_event : market_event_t;

    begin

      next_event          := market_event_reset;
      next_event.kind     := kind;
      next_event.side     := side;
      next_event.quantity := to_unsigned(qty, 32);
      next_event.price    := to_unsigned(price, 64);
      event               <= next_event;
      event_v             <= '1';
      wait until rising_edge(clk);
      event_v             <= '0';
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      wait for 1 ns;

    end procedure send;

    procedure propose (
      side  : byte_t;
      qty   : natural;
      price : natural
    ) is
    begin

      proposal   <= (side => side, price => to_unsigned(price, 64), qty => to_unsigned(qty, 32));
      proposal_v <= '1';
      wait until rising_edge(clk);
      proposal_v <= '0';
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      wait for 1 ns;

    end procedure propose;

  begin

    test_runner_setup(runner, runner_cfg);

    while test_suite loop

      enable <= '1';
      killed <= '0';
      reset;

      if run("entries inside the limits pass") then
        send(event_add, side_buy, 10, 1500);
        check_equal(passed, 1);
        check_equal(approved.quantity, to_unsigned(10, 32));
        check_equal(rejected, 0);
      elsif run("entries outside the limits are rejected") then
        send(event_add, side_buy, 1001, 1500);
        send(event_add, side_buy, 0, 1500);
        send(event_add, side_sell, 10, 99);
        send(event_add, side_sell, 10, 2000001);
        send(event_add, side_none, 10, 1500);
        check_equal(passed, 0);
        check_equal(rejected, 5);
      elsif run("64-bit limits reduce correctly") then
        limits.price_ceiling <= x"0000000100000000";
        wait until rising_edge(clk);
        wait until rising_edge(clk);
        send(event_add, side_buy, 10, 2000001);
        check_equal(passed, 1, "a ceiling above 2**32 is no bound");
        limits.price_floor   <= x"0000000100000000";
        wait until rising_edge(clk);
        wait until rising_edge(clk);
        send(event_add, side_buy, 10, 1500);
        check_equal(rejected, 1, "a floor above 2**32 rejects every 32-bit price");
      elsif run("kill and disable block entries but not lifecycle events") then
        killed <= '1';
        send(event_add, side_buy, 10, 1500);
        send(event_execute, side_none, 10, 0);
        send(event_delete, side_none, 0, 0);
        check_equal(passed, 2);
        check_equal(rejected, 1);
        killed <= '0';
        enable <= '0';
        wait until rising_edge(clk);
        wait until rising_edge(clk);
        send(event_add, side_buy, 10, 1500);
        check_equal(rejected, 2);
      elsif run("a kill blocks entries on the cycle it asserts") then
        -- The registered enable term still reads open here; only the
        -- unregistered kill input can stop this entry.
        killed <= '1';
        send(event_add, side_buy, 10, 1500);
        check_equal(passed, 0);
        check_equal(rejected, 1);
      elsif run("signals are gated like entries") then
        propose(side_buy, 1, 1500);
        check_equal(sig_passed, 1);
        check_equal(approved_sig.price, to_unsigned(1500, 64));
        propose(side_buy, 1, 50);
        check_equal(sig_reject_count, 1);
        killed <= '1';
        propose(side_sell, 1, 1500);
        check_equal(sig_passed, 1);
        check_equal(sig_reject_count, 2);
      end if;

    end loop;

    test_runner_cleanup(runner);
    wait;

  end process main;

end architecture tb;
