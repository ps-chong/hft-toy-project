-- Reset synchronizer: asynchronous assertion, synchronous deassertion.
--
-- Downstream flops see reset leave on a clock edge of their own domain, so
-- no flop can sample a deasserting reset inside its recovery window.

library ieee;
  use ieee.std_logic_1164.all;

entity reset_sync is
  generic (
    stages : positive := 3
  );
  port (
    clk       : in    std_logic;
    async_rst : in    std_logic;
    sync_rst  : out   std_logic
  );
end entity reset_sync;

architecture rtl of reset_sync is

  signal chain : std_logic_vector(stages - 1 downto 0) := (others => '1');

  attribute async_reg : string;
  attribute async_reg of chain : signal is "TRUE";

begin

  sync_rst <= chain(stages - 1);

  synchronize : process (clk, async_rst) is
  begin

    if (async_rst = '1') then
      chain <= (others => '1');
    elsif rising_edge(clk) then
      chain <= chain(stages - 2 downto 0) & '0';
    end if;

  end process synchronize;

end architecture rtl;
