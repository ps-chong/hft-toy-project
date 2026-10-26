-- AXI4-Lite control/status block (ps_clk domain) for the generated map in
-- protocol/schema/registers.yaml.
--
-- Data-race rule: nothing written here reaches axis_clk directly. Writes go
-- to ps_clk shadow registers; COMMIT.request sends the whole shadow set
-- through one cdc_snapshot, so axis_clk only ever sees complete
-- configurations, and CONFIG_REVISION counts the commits applied. Status
-- comes back the same way, as one coherent snapshot refreshed continuously.
--
-- One transaction at a time per channel; responses are always OKAY.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library work;
  use work.hft_protocol_pkg.all;

entity hft_regs_axil is
  port (
    clk : in    std_logic;
    rst : in    std_logic;

    s_awaddr  : in    std_logic_vector(15 downto 0);
    s_awvalid : in    std_logic;
    s_awready : out   std_logic;
    s_wdata   : in    std_logic_vector(31 downto 0);
    s_wvalid  : in    std_logic;
    s_wready  : out   std_logic;
    s_bresp   : out   std_logic_vector(1 downto 0);
    s_bvalid  : out   std_logic;
    s_bready  : in    std_logic;
    s_araddr  : in    std_logic_vector(15 downto 0);
    s_arvalid : in    std_logic;
    s_arready : out   std_logic;
    s_rdata   : out   std_logic_vector(31 downto 0);
    s_rresp   : out   std_logic_vector(1 downto 0);
    s_rvalid  : out   std_logic;
    s_rready  : in    std_logic;

    -- Committed configuration, still in ps_clk; crosses through cdc_snapshot.
    config_data : out   std_logic_vector(218 downto 0);
    config_load : out   std_logic;
    config_busy : in    std_logic;

    -- Latest status snapshot, already in ps_clk.
    status_data  : in    std_logic_vector(291 downto 0);
    status_fresh : in    std_logic
  );
end entity hft_regs_axil;

architecture rtl of hft_regs_axil is

  constant build_id : std_logic_vector(31 downto 0) := x"48544654";

  signal control       : std_logic_vector(2 downto 0)   := "010";
  signal max_quantity  : std_logic_vector(31 downto 0)  := std_logic_vector(to_unsigned(1000, 32));
  signal floor_lo      : std_logic_vector(31 downto 0)  := x"00000001";
  signal floor_hi      : std_logic_vector(31 downto 0)  := (others => '0');
  signal ceiling_lo    : std_logic_vector(31 downto 0)  := std_logic_vector(to_unsigned(1000000000, 32));
  signal ceiling_hi    : std_logic_vector(31 downto 0)  := (others => '0');
  signal stock_locate  : std_logic_vector(15 downto 0)  := (others => '0');
  signal strategy      : std_logic_vector(7 downto 0)   := (others => '0');
  signal anchor        : std_logic_vector(31 downto 0)  := (others => '0');
  signal commit_wanted : std_logic                      := '0';
  signal status        : std_logic_vector(291 downto 0) := (others => '0');

  signal awready_i : std_logic                     := '0';
  signal bvalid_i  : std_logic                     := '0';
  signal arready_i : std_logic                     := '0';
  signal rvalid_i  : std_logic                     := '0';
  signal rdata_i   : std_logic_vector(31 downto 0) := (others => '0');

  -- Status field views (layout must match the packing in the top level).
  alias st_flags          : std_logic_vector(3 downto 0) is status(3 downto 0);
  alias st_expected       : std_logic_vector(63 downto 0) is status(67 downto 4);
  alias st_packets        : std_logic_vector(63 downto 0) is status(131 downto 68);
  alias st_drops          : std_logic_vector(31 downto 0) is status(163 downto 132);
  alias st_malformed      : std_logic_vector(31 downto 0) is status(195 downto 164);
  alias st_gaps           : std_logic_vector(31 downto 0) is status(227 downto 196);
  alias st_telemetry_drop : std_logic_vector(31 downto 0) is status(259 downto 228);
  alias st_revision       : std_logic_vector(31 downto 0) is status(291 downto 260);

begin

  s_awready <= awready_i;
  s_wready  <= awready_i;
  s_bresp   <= "00";
  s_bvalid  <= bvalid_i;
  s_arready <= arready_i;
  s_rresp   <= "00";
  s_rvalid  <= rvalid_i;
  s_rdata   <= rdata_i;

  -- Layout (msb first): control(3) max_quantity(32) ceiling(64) floor(64)
  -- stock_locate(16) strategy(8) anchor(32) = 219 bits.
  config_data <= control & max_quantity & ceiling_hi & ceiling_lo & floor_hi & floor_lo &
                 stock_locate & strategy & anchor;
  config_load <= commit_wanted and not config_busy;

  write_channel : process (clk) is

    variable offset : natural range 0 to 65535;

  begin

    if rising_edge(clk) then
      awready_i <= '0';
      if (rst = '1') then
        bvalid_i      <= '0';
        control       <= "010";
        commit_wanted <= '0';
      else
        if ((commit_wanted = '1') and (config_busy = '0')) then
          commit_wanted <= '0';
        end if;
        if ((bvalid_i = '1') and (s_bready = '1')) then
          bvalid_i <= '0';
        end if;
        -- Accept address and data together, one transaction at a time.
        if ((s_awvalid = '1') and (s_wvalid = '1') and (awready_i = '0') and (bvalid_i = '0')) then
          awready_i <= '1';
          bvalid_i  <= '1';
          offset    := to_integer(unsigned(s_awaddr));

          case offset is

            when REG_CONTROL =>

              control <= s_wdata(2 downto 0);

            when REG_COMMIT =>

              commit_wanted <= commit_wanted or s_wdata(REG_COMMIT_REQUEST_BIT);

            when REG_RISK_MAX_QTY =>

              max_quantity <= s_wdata;

            when REG_RISK_PRICE_FLOOR =>

              floor_lo <= s_wdata;

            when REG_RISK_PRICE_FLOOR_HI =>

              floor_hi <= s_wdata;

            when REG_RISK_PRICE_CEILING =>

              ceiling_lo <= s_wdata;

            when REG_RISK_PRICE_CEILING_HI =>

              ceiling_hi <= s_wdata;

            when REG_STOCK_LOCATE =>

              stock_locate <= s_wdata(15 downto 0);

            when REG_STRATEGY_SELECT =>

              strategy <= s_wdata(7 downto 0);

            when REG_TOB_ANCHOR_PRICE =>

              anchor <= s_wdata;

            when others =>

              null;

          end case;

        end if;
      end if;
    end if;

  end process write_channel;

  read_channel : process (clk) is

    variable offset : natural range 0 to 65535;

  begin

    if rising_edge(clk) then
      arready_i <= '0';
      if (status_fresh = '1') then
        status <= status_data;
      end if;
      if (rst = '1') then
        rvalid_i <= '0';
      else
        if ((rvalid_i = '1') and (s_rready = '1')) then
          rvalid_i <= '0';
        end if;
        if ((s_arvalid = '1') and (arready_i = '0') and (rvalid_i = '0')) then
          arready_i <= '1';
          rvalid_i  <= '1';
          offset    := to_integer(unsigned(s_araddr));

          case offset is

            when REG_BUILD_ID =>

              rdata_i <= build_id;

            when REG_ABI_VERSION =>

              rdata_i <= std_logic_vector(to_unsigned(ABI_VERSION, 32));

            when REG_CONTROL =>

              rdata_i <= (31 downto 3 => '0') & control;

            when REG_STATUS =>

              rdata_i <= (31 downto 5 => '0') & config_busy & st_flags;

            when REG_EXPECTED_SEQUENCE_LO =>

              rdata_i <= st_expected(31 downto 0);

            when REG_EXPECTED_SEQUENCE_HI =>

              rdata_i <= st_expected(63 downto 32);

            when REG_PACKET_COUNT_LO =>

              rdata_i <= st_packets(31 downto 0);

            when REG_PACKET_COUNT_HI =>

              rdata_i <= st_packets(63 downto 32);

            when REG_DROP_COUNT =>

              rdata_i <= st_drops;

            when REG_MALFORMED_COUNT =>

              rdata_i <= st_malformed;

            when REG_GAP_COUNT =>

              rdata_i <= st_gaps;

            when REG_CONFIG_REVISION =>

              rdata_i <= st_revision;

            when REG_TELEMETRY_DROP_COUNT =>

              rdata_i <= st_telemetry_drop;

            when REG_RISK_MAX_QTY =>

              rdata_i <= max_quantity;

            when REG_RISK_PRICE_FLOOR =>

              rdata_i <= floor_lo;

            when REG_RISK_PRICE_FLOOR_HI =>

              rdata_i <= floor_hi;

            when REG_RISK_PRICE_CEILING =>

              rdata_i <= ceiling_lo;

            when REG_RISK_PRICE_CEILING_HI =>

              rdata_i <= ceiling_hi;

            when REG_STOCK_LOCATE =>

              rdata_i <= x"0000" & stock_locate;

            when REG_STRATEGY_SELECT =>

              rdata_i <= x"000000" & strategy;

            when REG_TOB_ANCHOR_PRICE =>

              rdata_i <= anchor;

            when others =>

              rdata_i <= (others => '0');

          end case;

        end if;
      end if;
    end if;

  end process read_channel;

end architecture rtl;
