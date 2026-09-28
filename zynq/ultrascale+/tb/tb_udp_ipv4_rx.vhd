library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library vunit_lib;
  context vunit_lib.vunit_context;

entity tb_udp_ipv4_rx is
  generic (
    runner_cfg : string
  );
end entity tb_udp_ipv4_rx;

architecture tb of tb_udp_ipv4_rx is

  constant clk_period : time := 10 ns;

  type byte_array_t is array (natural range <>) of std_logic_vector(7 downto 0);

  constant udp_mold_add : byte_array_t :=
  (
    x"02", x"00", x"00", x"00", x"00", x"01",
    x"02", x"00", x"00", x"00", x"00", x"02",
    x"08", x"00",
    x"45", x"00", x"00", x"56", x"00", x"00", x"40", x"00",
    x"40", x"11", x"B6", x"E1", x"C0", x"A8", x"01", x"01",
    x"C0", x"A8", x"01", x"64",
    x"30", x"39", x"B7", x"98", x"00", x"42", x"00", x"00",
    x"54", x"45", x"53", x"54", x"53", x"45", x"53", x"53",
    x"30", x"31", x"00", x"00", x"00", x"00", x"00", x"00",
    x"00", x"01", x"00", x"01", x"00", x"24", x"41", x"00",
    x"01", x"00", x"02", x"00", x"00", x"00", x"01", x"E2",
    x"40", x"01", x"02", x"03", x"04", x"05", x"06", x"07",
    x"08", x"42", x"00", x"00", x"00", x"64", x"41", x"43",
    x"4D", x"45", x"20", x"20", x"20", x"20", x"00", x"12",
    x"D6", x"44"
  );

  signal clk : std_logic := '0';
  signal rst : std_logic := '1';

  signal frame_data  : std_logic_vector(7 downto 0) := (others => '0');
  signal frame_valid : std_logic                    := '0';
  signal frame_sop   : std_logic                    := '0';
  signal frame_eop   : std_logic                    := '0';
  signal frame_ready : std_logic;

  signal payload_data  : std_logic_vector(7 downto 0);
  signal payload_valid : std_logic;
  signal payload_sop   : std_logic;
  signal payload_eop   : std_logic;

  signal dropped_count : unsigned(31 downto 0);
  signal drop_pulse    : std_logic;
  signal malformed     : std_logic;

  signal payload_count : natural := 0;
  signal sop_count     : natural := 0;
  signal eop_count     : natural := 0;
  signal first_payload : std_logic_vector(7 downto 0) := (others => '0');
  signal last_payload  : std_logic_vector(7 downto 0) := (others => '0');
  signal drop_seen     : std_logic := '0';
  signal malformed_seen : std_logic := '0';

begin

  clk <= not clk after clk_period / 2;

  dut : entity hft.udp_ipv4_rx
    port map (
      clk             => clk,
      rst             => rst,
      frame_data      => frame_data,
      frame_valid     => frame_valid,
      frame_sop       => frame_sop,
      frame_eop       => frame_eop,
      frame_ready     => frame_ready,
      payload_data    => payload_data,
      payload_valid   => payload_valid,
      payload_sop     => payload_sop,
      payload_eop     => payload_eop,
      payload_ready   => '1',
      dropped_count   => dropped_count,
      drop_pulse      => drop_pulse,
      malformed_pulse => malformed
    );

  monitor : process (clk) is
  begin

    if rising_edge(clk) then
      if (rst = '1') then
        payload_count  <= 0;
        sop_count      <= 0;
        eop_count      <= 0;
        first_payload  <= (others => '0');
        last_payload   <= (others => '0');
        drop_seen      <= '0';
        malformed_seen <= '0';
      else
        if (payload_valid = '1') then
          if (payload_count = 0) then
            first_payload <= payload_data;
          end if;
          payload_count <= payload_count + 1;
          last_payload  <= payload_data;
          if (payload_sop = '1') then
            sop_count <= sop_count + 1;
          end if;
          if (payload_eop = '1') then
            eop_count <= eop_count + 1;
          end if;
        end if;
        if (drop_pulse = '1') then
          drop_seen <= '1';
        end if;
        if (malformed = '1') then
          malformed_seen <= '1';
        end if;
      end if;
    end if;

  end process monitor;

  main : process is

    procedure reset_dut is
    begin

      rst         <= '1';
      frame_valid <= '0';
      wait for 3 * clk_period;
      wait until rising_edge(clk);
      rst <= '0';

    end procedure reset_dut;

    procedure send_frame (
      corrupt_checksum : boolean := false;
      wrong_port       : boolean := false
    ) is

      variable octet : std_logic_vector(7 downto 0);

    begin

      for index in udp_mold_add'range loop
        octet := udp_mold_add(index);
        if (corrupt_checksum and (index = 24)) then
          octet := x"B7";
        elsif (wrong_port and (index = 37)) then
          octet := x"99";
        end if;

        frame_data  <= octet;
        frame_valid <= '1';
        if (index = udp_mold_add'low) then
          frame_sop <= '1';
        else
          frame_sop <= '0';
        end if;
        if (index = udp_mold_add'high) then
          frame_eop <= '1';
        else
          frame_eop <= '0';
        end if;
        loop
          wait until rising_edge(clk);
          exit when frame_ready = '1';
        end loop;
      end loop;
      frame_valid <= '0';
      frame_sop   <= '0';
      frame_eop   <= '0';
      wait until rising_edge(clk);

    end procedure send_frame;

  begin

    test_runner_setup(runner, runner_cfg);

    while test_suite loop
      if run("extracts validated MoldUDP64 payload") then
        reset_dut;
        send_frame;
        check_equal(payload_count, 58);
        check_equal(sop_count, 1);
        check_equal(eop_count, 1);
        check_equal(first_payload, std_logic_vector'(x"54"));
        check_equal(last_payload, std_logic_vector'(x"44"));
        check_equal(dropped_count, to_unsigned(0, 32));
        check_equal(malformed_seen, '0');
      elsif run("drops unmatched destination port") then
        reset_dut;
        send_frame(wrong_port => true);
        check_equal(payload_count, 0);
        check_equal(drop_seen, '1');
        check_equal(dropped_count, to_unsigned(1, 32));
      elsif run("rejects invalid IPv4 checksum") then
        reset_dut;
        send_frame(corrupt_checksum => true);
        check_equal(payload_count, 0);
        check_equal(malformed_seen, '1');
        check_equal(dropped_count, to_unsigned(1, 32));
      end if;
    end loop;

    test_runner_cleanup(runner);
    wait;

  end process main;

end architecture tb;
