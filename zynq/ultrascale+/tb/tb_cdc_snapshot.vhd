-- cdc_snapshot across unrelated clocks: every snapshot the destination sees
-- is one the source loaded (never a mix of two), in order, none lost.
--
-- The payload is a counter and its complement, so any torn transfer breaks
-- the pairing. run.py instantiates several clock-period ratios.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library vunit_lib;
  context vunit_lib.vunit_context;

entity tb_cdc_snapshot is
  generic (
    runner_cfg    : string;
    src_period_ps : positive := 10000;
    dst_period_ps : positive := 6400
  );
end entity tb_cdc_snapshot;

architecture tb of tb_cdc_snapshot is

  constant src_period : time    := src_period_ps * 1 ps;
  constant dst_period : time    := dst_period_ps * 1 ps;
  constant transfers  : natural := 200;

  signal src_clk   : std_logic                     := '0';
  signal dst_clk   : std_logic                     := '0';
  signal src_rst   : std_logic                     := '1';
  signal dst_rst   : std_logic                     := '1';
  signal src_data  : std_logic_vector(63 downto 0) := (others => '0');
  signal src_load  : std_logic                     := '0';
  signal src_busy  : std_logic;
  signal dst_data  : std_logic_vector(63 downto 0);
  signal dst_valid : std_logic;

  signal loaded   : natural := 0;
  signal received : natural := 0;
  signal done     : boolean := false;

begin

  src_clk <= not src_clk after src_period / 2;
  -- Odd start offset so the edges drift relative to each other.
  dst_clk <= not dst_clk after (dst_period / 2) + 137 ps when now = 0 ps else
             not dst_clk after dst_period / 2;

  dut : entity work.cdc_snapshot
    generic map (
      width => 64
    )
    port map (
      src_clk   => src_clk,
      src_rst   => src_rst,
      src_data  => src_data,
      src_load  => src_load,
      src_busy  => src_busy,
      dst_clk   => dst_clk,
      dst_rst   => dst_rst,
      dst_data  => dst_data,
      dst_valid => dst_valid
    );

  -- Loads a new value every cycle the snapshot is idle; the data input
  -- changes every cycle regardless, as a live status bus would.
  source : process (src_clk) is

    variable counter : unsigned(31 downto 0);

  begin

    if rising_edge(src_clk) then
      if (src_rst = '1') then
        counter := (others => '0');
      end if;
      counter  := counter + 1;
      src_data <= std_logic_vector(counter) & std_logic_vector(not counter);
      src_load <= '0';
      if ((src_rst = '0') and (src_busy = '0') and (src_load = '0') and (loaded < transfers)) then
        src_load <= '1';
        loaded   <= loaded + 1;
      end if;
    end if;

  end process source;

  sink : process (dst_clk) is

    variable previous : unsigned(31 downto 0);
    variable value    : unsigned(31 downto 0);

  begin

    if rising_edge(dst_clk) then
      if (dst_rst = '1') then
        previous := (others => '0');
      elsif (dst_valid = '1') then
        value    := unsigned(dst_data(63 downto 32));
        check_equal(dst_data(31 downto 0), not dst_data(63 downto 32), "torn snapshot");
        check(value > previous, "snapshots out of order");
        previous := value;
        received <= received + 1;
      end if;
    end if;

  end process sink;

  main : process is
  begin

    test_runner_setup(runner, runner_cfg);

    while test_suite loop

      if run("snapshots cross whole and in order") then
        wait for 5 * src_period;
        src_rst <= '0';
        dst_rst <= '0';
        wait until loaded = transfers for transfers * 20 * (src_period + dst_period);
        wait for 20 * (src_period + dst_period);
        check_equal(loaded, transfers);
        check_equal(received, transfers, "every accepted load arrives exactly once");
      end if;

    end loop;

    test_runner_cleanup(runner);
    wait;

  end process main;

end architecture tb;
