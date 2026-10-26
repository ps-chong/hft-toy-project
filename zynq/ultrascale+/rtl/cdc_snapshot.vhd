-- Atomic multi-bit clock-domain crossing (req/ack toggle handshake).
--
-- The source captures `src_data` into a holding register on `src_load` and
-- toggles `req`. The destination sees the synchronized toggle, then copies
-- the holding register, which has been stable for at least two destination
-- cycles, and toggles `ack` back. Every bit therefore crosses as one
-- coherent snapshot: a 64-bit price collar can never be observed half
-- written. Loads arriving while a transfer is in flight are refused
-- (`src_busy`) and must be retried by the source.
--
-- Timing: the holding-register to destination paths are constrained with
-- set_max_delay -datapath_only and set_bus_skew in the XDC.

library ieee;
  use ieee.std_logic_1164.all;

entity cdc_snapshot is
  generic (
    width : positive
  );
  port (
    src_clk  : in    std_logic;
    src_rst  : in    std_logic;
    src_data : in    std_logic_vector(width - 1 downto 0);
    src_load : in    std_logic;
    src_busy : out   std_logic;

    dst_clk   : in    std_logic;
    dst_rst   : in    std_logic;
    dst_data  : out   std_logic_vector(width - 1 downto 0);
    dst_valid : out   std_logic
  );
end entity cdc_snapshot;

architecture rtl of cdc_snapshot is

  signal hold     : std_logic_vector(width - 1 downto 0) := (others => '0');
  signal req      : std_logic                            := '0';
  signal ack_sync : std_logic_vector(1 downto 0)         := (others => '0');

  signal req_sync : std_logic_vector(2 downto 0)         := (others => '0');
  signal ack      : std_logic                            := '0';
  signal captured : std_logic_vector(width - 1 downto 0) := (others => '0');
  signal fresh    : std_logic                            := '0';

  attribute async_reg : string;
  attribute async_reg of ack_sync : signal is "TRUE";
  attribute async_reg of req_sync : signal is "TRUE";

begin

  -- A transfer is in flight until the acknowledgement toggle returns.
  src_busy  <= req xor ack_sync(1);
  dst_data  <= captured;
  dst_valid <= fresh;

  source : process (src_clk) is
  begin

    if rising_edge(src_clk) then
      if (src_rst = '1') then
        req      <= '0';
        ack_sync <= (others => '0');
      else
        ack_sync <= ack_sync(0) & ack;
        if ((src_load = '1') and ((req xor ack_sync(1)) = '0')) then
          hold <= src_data;
          req  <= not req;
        end if;
      end if;
    end if;

  end process source;

  destination : process (dst_clk) is
  begin

    if rising_edge(dst_clk) then
      fresh <= '0';
      if (dst_rst = '1') then
        req_sync <= (others => '0');
        ack      <= '0';
      else
        req_sync <= req_sync(1 downto 0) & req;
        -- A request edge: the holding register is stable now.
        if ((req_sync(2) xor req_sync(1)) = '1') then
          captured <= hold;
          ack      <= req_sync(1);
          fresh    <= '1';
        end if;
      end if;
    end if;

  end process destination;

end architecture rtl;
