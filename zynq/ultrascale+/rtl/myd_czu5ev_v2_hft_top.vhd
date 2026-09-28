library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library work;
  use work.hft_types_pkg.all;

entity myd_czu5ev_v2_hft_top is
  port (
    axis_clk : in    std_logic;
    axis_rst : in    std_logic;

    s_axis_tdata  : in    std_logic_vector(7 downto 0);
    s_axis_tvalid : in    std_logic;
    s_axis_tuser  : in    std_logic;
    s_axis_tlast  : in    std_logic;
    s_axis_tready : out   std_logic;

    m_event_kind      : out   std_logic_vector(7 downto 0);
    m_event_side      : out   std_logic_vector(7 downto 0);
    m_event_sequence  : out   std_logic_vector(63 downto 0);
    m_event_timestamp : out   std_logic_vector(47 downto 0);
    m_event_reference : out   std_logic_vector(63 downto 0);
    m_event_symbol    : out   std_logic_vector(63 downto 0);
    m_event_price     : out   std_logic_vector(63 downto 0);
    m_event_quantity  : out   std_logic_vector(31 downto 0);
    m_event_valid     : out   std_logic;
    m_event_ready     : in    std_logic;

    control_enable     : in    std_logic;
    control_kill       : in    std_logic;
    control_clear      : in    std_logic;
    risk_max_quantity  : in    std_logic_vector(31 downto 0);
    risk_price_floor   : in    std_logic_vector(63 downto 0);
    risk_price_ceiling : in    std_logic_vector(63 downto 0);

    signal_valid : out   std_logic;
    signal_side  : out   std_logic_vector(7 downto 0);
    signal_price : out   std_logic_vector(63 downto 0);
    signal_qty   : out   std_logic_vector(31 downto 0);

    status_killed     : out   std_logic;
    status_gap        : out   std_logic;
    status_malformed  : out   std_logic;
    status_unknown    : out   std_logic;
    status_overflow   : out   std_logic;
    status_rejected   : out   std_logic;
    expected_sequence : out   std_logic_vector(63 downto 0)
  );
end entity myd_czu5ev_v2_hft_top;

architecture rtl of myd_czu5ev_v2_hft_top is

  signal event_i             : market_event_t;
  signal signal_side_i       : byte_t;
  signal signal_price_i      : unsigned(63 downto 0);
  signal signal_qty_i        : unsigned(31 downto 0);
  signal expected_sequence_i : unsigned(63 downto 0);

begin

  m_event_kind      <= event_i.kind;
  m_event_side      <= event_i.side;
  m_event_sequence  <= std_logic_vector(event_i.feed_sequence);
  m_event_timestamp <= std_logic_vector(event_i.timestamp_ns);
  m_event_reference <= std_logic_vector(event_i.order_reference);
  m_event_symbol    <= event_i.symbol;
  m_event_price     <= std_logic_vector(event_i.price);
  m_event_quantity  <= std_logic_vector(event_i.quantity);
  signal_side       <= signal_side_i;
  signal_price      <= std_logic_vector(signal_price_i);
  signal_qty        <= std_logic_vector(signal_qty_i);
  expected_sequence <= std_logic_vector(expected_sequence_i);

  pipeline : entity work.hft_pipeline
    port map (
      clk               => axis_clk,
      rst               => axis_rst,
      packet_data       => s_axis_tdata,
      packet_valid      => s_axis_tvalid,
      packet_sop        => s_axis_tuser,
      packet_eop        => s_axis_tlast,
      packet_ready      => s_axis_tready,
      event_out         => event_i,
      event_valid       => m_event_valid,
      event_ready       => m_event_ready,
      trading_enable    => control_enable,
      external_kill     => control_kill,
      clear_faults      => control_clear,
      max_quantity      => unsigned(risk_max_quantity),
      price_floor       => unsigned(risk_price_floor),
      price_ceiling     => unsigned(risk_price_ceiling),
      signal_valid      => signal_valid,
      signal_side       => signal_side_i,
      signal_price      => signal_price_i,
      signal_qty        => signal_qty_i,
      killed            => status_killed,
      gap_pulse         => status_gap,
      malformed_pulse   => status_malformed,
      unknown_pulse     => status_unknown,
      overflow_pulse    => status_overflow,
      risk_reject_pulse => status_rejected,
      expected_sequence => expected_sequence_i
    );

end architecture rtl;
