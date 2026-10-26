-- Two-entry skid buffer (register slice) with registered ready.
--
-- Breaks the combinational ready path between a consumer and its producer
-- while still sustaining one transfer per cycle: when the consumer stalls,
-- the beat already in flight lands in the skid register instead of being
-- lost. s_ready depends only on local flops.

library ieee;
  use ieee.std_logic_1164.all;

entity axis_skid is
  generic (
    width : positive
  );
  port (
    clk : in    std_logic;
    rst : in    std_logic;

    s_data  : in    std_logic_vector(width - 1 downto 0);
    s_valid : in    std_logic;
    s_ready : out   std_logic;

    m_data  : out   std_logic_vector(width - 1 downto 0);
    m_valid : out   std_logic;
    m_ready : in    std_logic
  );
end entity axis_skid;

architecture rtl of axis_skid is

  signal main_data  : std_logic_vector(width - 1 downto 0) := (others => '0');
  signal main_valid : std_logic                            := '0';
  signal skid_data  : std_logic_vector(width - 1 downto 0) := (others => '0');
  signal skid_valid : std_logic                            := '0';

begin

  s_ready <= not skid_valid;
  m_data  <= main_data;
  m_valid <= main_valid;

  slice : process (clk) is
  begin

    if rising_edge(clk) then
      if (rst = '1') then
        main_valid <= '0';
        skid_valid <= '0';
      else
        if ((main_valid = '0') or (m_ready = '1')) then
          -- Output register free (or draining): refill from skid first.
          if (skid_valid = '1') then
            main_data  <= skid_data;
            main_valid <= '1';
            skid_valid <= '0';
          else
            main_data  <= s_data;
            main_valid <= s_valid;
          end if;
        elsif ((s_valid = '1') and (skid_valid = '0')) then
          -- Output stalled: park the incoming beat.
          skid_data  <= s_data;
          skid_valid <= '1';
        end if;
      end if;
    end if;

  end process slice;

end architecture rtl;
