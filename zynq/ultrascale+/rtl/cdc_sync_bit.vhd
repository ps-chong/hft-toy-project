-- Two- (or more-) flop synchronizer for one slowly changing level, for
-- example SFP link-up from the transceiver domain.
--
-- Latency: `stages` destination cycles. Only levels that stay stable for
-- several destination cycles may cross here; pulses and multi-bit values
-- must use cdc_snapshot instead.

library ieee;
  use ieee.std_logic_1164.all;

entity cdc_sync_bit is
  generic (
    stages      : positive  := 2;
    reset_value : std_logic := '0'
  );
  port (
    dst_clk : in    std_logic;
    dst_rst : in    std_logic;
    src     : in    std_logic;
    dst     : out   std_logic
  );
end entity cdc_sync_bit;

architecture rtl of cdc_sync_bit is

  signal chain : std_logic_vector(stages - 1 downto 0) := (others => reset_value);

  -- Keep the flops together and tell timing analysis they are synchronizers.
  attribute async_reg : string;
  attribute async_reg of chain : signal is "TRUE";

begin

  dst <= chain(stages - 1);

  synchronize : process (dst_clk) is
  begin

    if rising_edge(dst_clk) then
      if (dst_rst = '1') then
        chain <= (others => reset_value);
      else
        chain <= chain(stages - 2 downto 0) & src;
      end if;
    end if;

  end process synchronize;

end architecture rtl;
