library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.hft_types_pkg.all;

entity order_book is
  generic (
    ORDER_CAPACITY : positive := 64
  );
  port (
    clk : in std_logic;
    rst : in std_logic;

    event_in    : in  market_event_t;
    event_valid : in  std_logic;
    event_ready : out std_logic;

    best_bid_price : out unsigned(63 downto 0);
    best_bid_qty   : out unsigned(31 downto 0);
    best_ask_price : out unsigned(63 downto 0);
    best_ask_qty   : out unsigned(31 downto 0);
    book_valid     : out std_logic;
    overflow_pulse : out std_logic
  );
end entity;

architecture rtl of order_book is
  type ref_array_t is array (natural range <>) of unsigned(63 downto 0);
  type price_array_t is array (natural range <>) of unsigned(63 downto 0);
  type qty_array_t is array (natural range <>) of unsigned(31 downto 0);
  type side_array_t is array (natural range <>) of byte_t;
  type valid_array_t is array (natural range <>) of std_logic;

  signal refs   : ref_array_t(0 to ORDER_CAPACITY - 1);
  signal prices : price_array_t(0 to ORDER_CAPACITY - 1);
  signal qtys   : qty_array_t(0 to ORDER_CAPACITY - 1);
  signal sides  : side_array_t(0 to ORDER_CAPACITY - 1);
  signal valids : valid_array_t(0 to ORDER_CAPACITY - 1) := (others => '0');
begin
  event_ready <= '1';

  process (all)
    variable bid_price_v : unsigned(63 downto 0);
    variable bid_qty_v   : unsigned(31 downto 0);
    variable ask_price_v : unsigned(63 downto 0);
    variable ask_qty_v   : unsigned(31 downto 0);
    variable bid_valid_v : boolean;
    variable ask_valid_v : boolean;
  begin
    bid_price_v := (others => '0');
    bid_qty_v := (others => '0');
    ask_price_v := (others => '1');
    ask_qty_v := (others => '0');
    bid_valid_v := false;
    ask_valid_v := false;

    for index in 0 to ORDER_CAPACITY - 1 loop
      if valids(index) = '1' and qtys(index) /= 0 then
        if sides(index) = SIDE_BUY then
          if not bid_valid_v or prices(index) > bid_price_v then
            bid_price_v := prices(index);
            bid_qty_v := qtys(index);
            bid_valid_v := true;
          elsif prices(index) = bid_price_v then
            bid_qty_v := bid_qty_v + qtys(index);
          end if;
        elsif sides(index) = SIDE_SELL then
          if not ask_valid_v or prices(index) < ask_price_v then
            ask_price_v := prices(index);
            ask_qty_v := qtys(index);
            ask_valid_v := true;
          elsif prices(index) = ask_price_v then
            ask_qty_v := ask_qty_v + qtys(index);
          end if;
        end if;
      end if;
    end loop;

    best_bid_price <= bid_price_v;
    best_bid_qty <= bid_qty_v;
    best_ask_price <= ask_price_v when ask_valid_v else (others => '0');
    best_ask_qty <= ask_qty_v;
    book_valid <= '1' when bid_valid_v and ask_valid_v else '0';
  end process;

  process (clk)
    variable free_index  : integer range -1 to ORDER_CAPACITY - 1;
    variable match_index : integer range -1 to ORDER_CAPACITY - 1;
  begin
    if rising_edge(clk) then
      overflow_pulse <= '0';

      if rst = '1' then
        valids <= (others => '0');
        for index in 0 to ORDER_CAPACITY - 1 loop
          refs(index) <= (others => '0');
          prices(index) <= (others => '0');
          qtys(index) <= (others => '0');
          sides(index) <= (others => '0');
        end loop;
      elsif event_valid = '1' then
        free_index := -1;
        match_index := -1;
        for index in 0 to ORDER_CAPACITY - 1 loop
          if valids(index) = '0' and free_index = -1 then
            free_index := index;
          end if;
          if valids(index) = '1' and
             refs(index) = event_in.order_reference and
             match_index = -1 then
            match_index := index;
          end if;
        end loop;

        if event_in.kind = EVENT_ADD then
          if match_index /= -1 then
            prices(match_index) <= event_in.price;
            qtys(match_index) <= event_in.quantity;
            sides(match_index) <= event_in.side;
          elsif free_index /= -1 then
            refs(free_index) <= event_in.order_reference;
            prices(free_index) <= event_in.price;
            qtys(free_index) <= event_in.quantity;
            sides(free_index) <= event_in.side;
            valids(free_index) <= '1';
          else
            overflow_pulse <= '1';
          end if;
        elsif match_index /= -1 and
              (event_in.kind = EVENT_CANCEL or
               event_in.kind = EVENT_EXECUTE) then
          if event_in.quantity >= qtys(match_index) then
            valids(match_index) <= '0';
            qtys(match_index) <= (others => '0');
          else
            qtys(match_index) <= qtys(match_index) - event_in.quantity;
          end if;
        elsif match_index /= -1 and event_in.kind = EVENT_DELETE then
          valids(match_index) <= '0';
          qtys(match_index) <= (others => '0');
        end if;
      end if;
    end if;
  end process;
end architecture;
