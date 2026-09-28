library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library work;
  use work.hft_types_pkg.all;

entity risk_guard is
  port (
    clk : in    std_logic;
    rst : in    std_logic;

    event_in    : in    market_event_t;
    event_valid : in    std_logic;
    event_ready : out   std_logic;

    approved_event : out   market_event_t;
    approved_valid : out   std_logic;
    approved_ready : in    std_logic;

    trading_enable : in    std_logic;
    kill_latched   : in    std_logic;
    max_quantity   : in    unsigned(31 downto 0);
    price_floor    : in    unsigned(63 downto 0);
    price_ceiling  : in    unsigned(63 downto 0);

    reject_pulse : out   std_logic
  );
end entity risk_guard;

architecture rtl of risk_guard is

  signal permitted : std_logic;
  signal is_order  : std_logic;

begin

  is_order <= '1' when event_in.kind = EVENT_ADD else
              '0';

  permitted <= '1'
               when is_order = '0' or (
                                        trading_enable = '1' and
                                        kill_latched = '0' and
                                        event_in.quantity > 0 and
                                        event_in.quantity <= max_quantity and
                                        event_in.price >= price_floor and
                                        event_in.price <= price_ceiling and
                                        (event_in.side = SIDE_BUY or event_in.side = SIDE_SELL)
                                      ) else
               '0';

  approved_event <= event_in;
  approved_valid <= event_valid and permitted;
  event_ready    <= approved_ready when permitted = '1' else
                    '1';

  process (clk) is
  begin

    if rising_edge(clk) then
      reject_pulse <= '0';
      if (rst = '0' and event_valid = '1' and event_ready = '1' and
          is_order = '1' and permitted = '0') then
        reject_pulse <= '1';
      end if;
    end if;

  end process;

end architecture rtl;
