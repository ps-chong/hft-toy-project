-- Market-data pipeline in axis_clk: MoldUDP64 framing, ITCH decode, order
-- book, signal engine and the pre-trade risk gate, plus the kill latch.
--
--   payload -> moldudp64_rx -> itch_decoder -+-> order_store -> tob_ladder -> signal_engine -+
--                                            |                                               |
--                                            +----------------> risk_guard <-----------------+
--                                                                   |
--                                             event skid (R5 ring) -+-> approved signals
--
-- Kill latch: any fault (sequence gap, malformed packet or message, book
-- overflow, event-output overflow, or a network fault from the top level)
-- sets it, and faults dominate: a fault arriving in the same cycle as a
-- clear leaves it set. Clearing needs a rising edge on clear_faults with
-- external_kill low, so a clear request held high cannot keep re-arming
-- trading after later faults. The latch resets set (fail closed), and every
-- clear flushes the order book, so trading restarts from a book built only
-- from post-clear messages.
--
-- No backpressure upstream of the event skid: the R5 ring writer must keep
-- up, and an event that finds the skid full is an overflow fault.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library work;
  use work.hft_types_pkg.all;

entity hft_pipeline is
  generic (
    set_bits        : positive := 12;
    level_bits      : positive := 10;
    tick_shift      : natural  := 0;
    imbalance_shift : natural  := 1
  );
  port (
    clk : in    std_logic;
    rst : in    std_logic;

    s_payload        : in    axis64_t;
    s_first          : in    std_logic;
    s_ingress_cycles : in    unsigned(63 downto 0);

    -- Committed configuration (axis_clk, from the control snapshot).
    trading_enable  : in    std_logic;
    external_kill   : in    std_logic;
    clear_faults    : in    std_logic;
    external_fault  : in    std_logic;
    limits          : in    risk_limits_t;
    book_locate     : in    unsigned(15 downto 0);
    strategy_select : in    std_logic_vector(7 downto 0);
    anchor_price    : in    unsigned(31 downto 0);

    -- Every normalized event, before risk (verification and replay tap).
    decoded_event : out   market_event_t;
    decoded_valid : out   std_logic;

    -- Approved events, as they leave risk_guard (telemetry tap).
    approved_event : out   market_event_t;
    approved_valid : out   std_logic;

    -- Approved events towards the R5 ring writer.
    event_out   : out   market_event_t;
    event_valid : out   std_logic;
    event_ready : in    std_logic;

    signal_valid : out   std_logic;
    signal_out   : out   signal_t;

    best_bid_price : out   unsigned(63 downto 0);
    best_bid_qty   : out   unsigned(31 downto 0);
    best_ask_price : out   unsigned(63 downto 0);
    best_ask_qty   : out   unsigned(31 downto 0);
    book_valid     : out   std_logic;
    book_flushing  : out   std_logic;

    killed            : out   std_logic;
    gap_pulse         : out   std_logic;
    duplicate_pulse   : out   std_logic;
    malformed_pulse   : out   std_logic;
    unknown_pulse     : out   std_logic;
    overflow_pulse    : out   std_logic;
    risk_reject_pulse : out   std_logic;
    expected_sequence : out   unsigned(63 downto 0)
  );
end entity hft_pipeline;

architecture rtl of hft_pipeline is

  signal message       : itch_message_t;
  signal message_valid : std_logic;

  signal mold_gap       : std_logic;
  signal mold_malformed : std_logic;
  signal itch_malformed : std_logic;

  signal decoded   : market_event_t;
  signal decoded_v : std_logic;

  signal delta_valid : std_logic;
  signal delta_buy   : std_logic;
  signal delta_add   : std_logic;
  signal delta_price : unsigned(31 downto 0);
  signal delta_qty   : unsigned(31 downto 0);
  signal store_full  : std_logic;

  signal bid_price : unsigned(63 downto 0);
  signal bid_qty   : unsigned(31 downto 0);
  signal ask_price : unsigned(63 downto 0);
  signal ask_qty   : unsigned(31 downto 0);
  signal tob_valid : std_logic;

  signal proposal       : signal_t;
  signal proposal_valid : std_logic;

  signal approved   : market_event_t;
  signal approved_v : std_logic;
  signal ev_reject  : std_logic;
  signal sig_reject : std_logic;

  signal skid_ready    : std_logic;
  signal skid_push     : std_logic;
  signal skid_in       : std_logic_vector(market_event_bits - 1 downto 0);
  signal skid_data     : std_logic_vector(market_event_bits - 1 downto 0);
  signal skid_overflow : std_logic := '0';

  signal kill_latched : std_logic := '1';
  signal clear_d      : std_logic := '0';
  signal clear_rise   : std_logic;
  signal kill_i       : std_logic;
  signal flush_book   : std_logic;

  attribute max_fanout : integer;
  attribute max_fanout of kill_latched : signal is 32;

begin

  kill_i     <= kill_latched or external_kill;
  clear_rise <= clear_faults and not clear_d;
  flush_book <= clear_rise;

  killed            <= kill_i;
  gap_pulse         <= mold_gap;
  malformed_pulse   <= mold_malformed or itch_malformed;
  overflow_pulse    <= store_full or skid_overflow;
  risk_reject_pulse <= ev_reject or sig_reject;
  decoded_event     <= decoded;
  decoded_valid     <= decoded_v;
  approved_event    <= approved;
  approved_valid    <= approved_v;
  best_bid_price    <= bid_price;
  best_bid_qty      <= bid_qty;
  best_ask_price    <= ask_price;
  best_ask_qty      <= ask_qty;
  book_valid        <= tob_valid;
  event_out         <= unpack_event(skid_data);
  skid_in           <= pack_event(approved);
  skid_push         <= approved_v and skid_ready;

  mold : entity work.moldudp64_rx
    port map (
      clk               => clk,
      rst               => rst,
      s_payload         => s_payload,
      s_first           => s_first,
      s_ingress_cycles  => s_ingress_cycles,
      m_message         => message,
      m_valid           => message_valid,
      gap_pulse         => mold_gap,
      duplicate_pulse   => duplicate_pulse,
      malformed_pulse   => mold_malformed,
      heartbeat_pulse   => open,
      expected_sequence => expected_sequence
    );

  itch : entity work.itch_decoder
    port map (
      clk             => clk,
      rst             => rst,
      s_message       => message,
      s_valid         => message_valid,
      s_gap           => mold_gap,
      event_out       => decoded,
      event_valid     => decoded_v,
      malformed_pulse => itch_malformed,
      unknown_pulse   => unknown_pulse
    );

  store : entity work.order_store
    generic map (
      set_bits => set_bits
    )
    port map (
      clk            => clk,
      rst            => rst,
      flush          => flush_book,
      event_in       => decoded,
      event_valid    => decoded_v,
      book_locate    => book_locate,
      delta_valid    => delta_valid,
      delta_buy      => delta_buy,
      delta_add      => delta_add,
      delta_price    => delta_price,
      delta_qty      => delta_qty,
      flushing       => book_flushing,
      overflow_pulse => store_full,
      miss_pulse     => open
    );

  ladder : entity work.tob_ladder
    generic map (
      level_bits => level_bits,
      tick_shift => tick_shift
    )
    port map (
      clk               => clk,
      rst               => rst,
      flush             => flush_book,
      anchor_price      => anchor_price,
      delta_valid       => delta_valid,
      delta_buy         => delta_buy,
      delta_add         => delta_add,
      delta_price       => delta_price,
      delta_qty         => delta_qty,
      best_bid_price    => bid_price,
      best_bid_qty      => bid_qty,
      best_ask_price    => ask_price,
      best_ask_qty      => ask_qty,
      book_valid        => tob_valid,
      out_of_band_pulse => open
    );

  signals : entity work.signal_engine
    generic map (
      imbalance_shift => imbalance_shift
    )
    port map (
      clk             => clk,
      rst             => rst,
      strategy_select => strategy_select,
      best_bid_price  => bid_price,
      best_bid_qty    => bid_qty,
      best_ask_price  => ask_price,
      best_ask_qty    => ask_qty,
      book_valid      => tob_valid,
      signal_valid    => proposal_valid,
      signal_out      => proposal
    );

  pre_risk : entity work.risk_guard
    port map (
      clk                 => clk,
      rst                 => rst,
      event_in            => decoded,
      event_valid         => decoded_v,
      signal_in           => proposal,
      signal_vld          => proposal_valid,
      trading_enable      => trading_enable,
      killed              => kill_i,
      limits              => limits,
      approved_event      => approved,
      approved_valid      => approved_v,
      approved_signal     => signal_out,
      approved_sig_vld    => signal_valid,
      event_reject_pulse  => ev_reject,
      signal_reject_pulse => sig_reject
    );

  event_skid : entity work.axis_skid
    generic map (
      width => market_event_bits
    )
    port map (
      clk     => clk,
      rst     => rst,
      s_data  => skid_in,
      s_valid => skid_push,
      s_ready => skid_ready,
      m_data  => skid_data,
      m_valid => event_valid,
      m_ready => event_ready
    );

  kill_latch : process (clk) is

    variable fault : boolean;

  begin

    if rising_edge(clk) then
      fault := (mold_gap = '1') or (mold_malformed = '1') or (itch_malformed = '1') or
               (store_full = '1') or (skid_overflow = '1') or (external_fault = '1');

      skid_overflow <= approved_v and not skid_ready;
      clear_d       <= clear_faults;

      if (rst = '1') then
        kill_latched  <= '1';
        skid_overflow <= '0';
        clear_d       <= '0';
      elsif (fault) then
        kill_latched <= '1';
      elsif ((clear_rise = '1') and (external_kill = '0')) then
        kill_latched <= '0';
      end if;
    end if;

  end process kill_latch;

end architecture rtl;
