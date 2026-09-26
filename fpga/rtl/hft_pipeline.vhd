library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.hft_types_pkg.all;

entity hft_pipeline is
  generic (
    ORDER_CAPACITY : positive := 64
  );
  port (
    clk : in std_logic;
    rst : in std_logic;

    packet_data  : in  byte_t;
    packet_valid : in  std_logic;
    packet_sop   : in  std_logic;
    packet_eop   : in  std_logic;
    packet_ready : out std_logic;

    event_out   : out market_event_t;
    event_valid : out std_logic;
    event_ready : in  std_logic;

    trading_enable : in std_logic;
    external_kill  : in std_logic;
    clear_faults   : in std_logic;
    max_quantity   : in unsigned(31 downto 0);
    price_floor    : in unsigned(63 downto 0);
    price_ceiling  : in unsigned(63 downto 0);

    signal_valid : out std_logic;
    signal_side  : out byte_t;
    signal_price : out unsigned(63 downto 0);
    signal_qty   : out unsigned(31 downto 0);

    killed             : out std_logic;
    gap_pulse          : out std_logic;
    malformed_pulse    : out std_logic;
    unknown_pulse      : out std_logic;
    overflow_pulse     : out std_logic;
    risk_reject_pulse  : out std_logic;
    expected_sequence  : out unsigned(63 downto 0)
  );
end entity;

architecture rtl of hft_pipeline is
  signal msg_data      : byte_t;
  signal msg_valid     : std_logic;
  signal msg_sop       : std_logic;
  signal msg_eop       : std_logic;
  signal msg_sequence  : unsigned(63 downto 0);
  signal msg_ready     : std_logic;

  signal mold_gap       : std_logic;
  signal mold_malformed : std_logic;
  signal heartbeat      : std_logic;
  signal itch_malformed : std_logic;

  signal decoded_event : market_event_t;
  signal decoded_valid : std_logic;
  signal decoded_ready : std_logic;

  signal bid_price : unsigned(63 downto 0);
  signal bid_qty   : unsigned(31 downto 0);
  signal ask_price : unsigned(63 downto 0);
  signal ask_qty   : unsigned(31 downto 0);
  signal book_valid : std_logic;
  signal book_overflow : std_logic;

  signal kill_latched : std_logic := '1';
begin
  killed <= kill_latched or external_kill;
  gap_pulse <= mold_gap;
  malformed_pulse <= mold_malformed or itch_malformed;
  overflow_pulse <= book_overflow;

  mold : entity work.moldudp64_decoder
    port map (
      clk => clk,
      rst => rst,
      s_data => packet_data,
      s_valid => packet_valid,
      s_sop => packet_sop,
      s_eop => packet_eop,
      s_ready => packet_ready,
      m_data => msg_data,
      m_valid => msg_valid,
      m_sop => msg_sop,
      m_eop => msg_eop,
      m_sequence => msg_sequence,
      m_ready => msg_ready,
      gap_pulse => mold_gap,
      malformed_pulse => mold_malformed,
      heartbeat_pulse => heartbeat,
      expected_sequence => expected_sequence
    );

  itch : entity work.itch_decoder
    port map (
      clk => clk,
      rst => rst,
      s_data => msg_data,
      s_valid => msg_valid,
      s_sop => msg_sop,
      s_eop => msg_eop,
      s_sequence => msg_sequence,
      s_ready => msg_ready,
      event_out => decoded_event,
      event_valid => decoded_valid,
      event_ready => decoded_ready,
      malformed_pulse => itch_malformed,
      unknown_pulse => unknown_pulse
    );

  book : entity work.order_book
    generic map (
      ORDER_CAPACITY => ORDER_CAPACITY
    )
    port map (
      clk => clk,
      rst => rst,
      event_in => decoded_event,
      event_valid => decoded_valid and decoded_ready,
      event_ready => open,
      best_bid_price => bid_price,
      best_bid_qty => bid_qty,
      best_ask_price => ask_price,
      best_ask_qty => ask_qty,
      book_valid => book_valid,
      overflow_pulse => book_overflow
    );

  pre_risk : entity work.risk_guard
    port map (
      clk => clk,
      rst => rst,
      event_in => decoded_event,
      event_valid => decoded_valid,
      event_ready => decoded_ready,
      approved_event => event_out,
      approved_valid => event_valid,
      approved_ready => event_ready,
      trading_enable => trading_enable,
      kill_latched => kill_latched or external_kill,
      max_quantity => max_quantity,
      price_floor => price_floor,
      price_ceiling => price_ceiling,
      reject_pulse => risk_reject_pulse
    );

  signals : entity work.signal_engine
    port map (
      clk => clk,
      rst => rst,
      best_bid_price => bid_price,
      best_bid_qty => bid_qty,
      best_ask_price => ask_price,
      best_ask_qty => ask_qty,
      book_valid => book_valid,
      signal_valid => signal_valid,
      signal_side => signal_side,
      signal_price => signal_price,
      signal_qty => signal_qty
    );

  process (clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        kill_latched <= '1';
      elsif clear_faults = '1' and external_kill = '0' then
        kill_latched <= '0';
      elsif mold_gap = '1' or mold_malformed = '1' or
            itch_malformed = '1' or book_overflow = '1' then
        kill_latched <= '1';
      end if;
    end if;
  end process;
end architecture;
