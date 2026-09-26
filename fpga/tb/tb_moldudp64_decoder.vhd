library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library vunit_lib;
  context vunit_lib.vunit_context;

library hft;
  use hft.hft_types_pkg.all;

entity tb_moldudp64_decoder is
  generic (
    runner_cfg : string
  );
end entity tb_moldudp64_decoder;

architecture tb of tb_moldudp64_decoder is

  constant clk_period   : time                         := 10 ns;
  signal   clk          : std_logic                    := '0';
  signal   rst          : std_logic                    := '1';
  signal   data         : std_logic_vector(7 downto 0) := (others => '0');
  signal   valid        : std_logic                    := '0';
  signal   sop          : std_logic                    := '0';
  signal   eop          : std_logic                    := '0';
  signal   ready        : std_logic;
  signal   out_data     : std_logic_vector(7 downto 0);
  signal   out_valid    : std_logic;
  signal   out_sop      : std_logic;
  signal   out_eop      : std_logic;
  signal   out_sequence : unsigned(63 downto 0);
  signal   gap          : std_logic;
  signal   malformed    : std_logic;
  signal   heartbeat    : std_logic;
  signal   expected     : unsigned(63 downto 0);
  signal   output_count : natural                      := 0;
  signal   first_output : std_logic_vector(7 downto 0) := (others => '0');

  type byte_array_t is array (natural range <>) of std_logic_vector(7 downto 0);

  constant mold_add       : byte_array_t :=
  (
    x"54",
    x"45",
    x"53",
    x"54",
    x"53",
    x"45",
    x"53",
    x"53",
    x"30",
    x"31",
    x"00",
    x"00",
    x"00",
    x"00",
    x"00",
    x"00",
    x"00",
    x"01",
    x"00",
    x"01",
    x"00",
    x"24",
    x"41",
    x"00",
    x"01",
    x"00",
    x"02",
    x"00",
    x"00",
    x"00",
    x"01",
    x"E2",
    x"40",
    x"01",
    x"02",
    x"03",
    x"04",
    x"05",
    x"06",
    x"07",
    x"08",
    x"42",
    x"00",
    x"00",
    x"00",
    x"64",
    x"41",
    x"43",
    x"4D",
    x"45",
    x"20",
    x"20",
    x"20",
    x"20",
    x"00",
    x"12",
    x"D6",
    x"44"
  );
  constant heartbeat_seq3 : byte_array_t :=
  (
    x"54",
    x"45",
    x"53",
    x"54",
    x"53",
    x"45",
    x"53",
    x"53",
    x"30",
    x"31",
    x"00",
    x"00",
    x"00",
    x"00",
    x"00",
    x"00",
    x"00",
    x"03",
    x"00",
    x"00"
  );
  constant truncated      : byte_array_t :=
  (
    x"54",
    x"45",
    x"53",
    x"54",
    x"53",
    x"45",
    x"53",
    x"53",
    x"30",
    x"31",
    x"00",
    x"00",
    x"00",
    x"00",
    x"00",
    x"00",
    x"00",
    x"01",
    x"00",
    x"01",
    x"00",
    x"24",
    x"41"
  );

begin

  clk <= not clk after clk_period / 2;

  dut : entity hft.moldudp64_decoder
    port map (
      clk               => clk,
      rst               => rst,
      s_data            => data,
      s_valid           => valid,
      s_sop             => sop,
      s_eop             => eop,
      s_ready           => ready,
      m_data            => out_data,
      m_valid           => out_valid,
      m_sop             => out_sop,
      m_eop             => out_eop,
      m_sequence        => out_sequence,
      m_ready           => '1',
      gap_pulse         => gap,
      malformed_pulse   => malformed,
      heartbeat_pulse   => heartbeat,
      expected_sequence => expected
    );

  monitor : process (clk) is
  begin

    if rising_edge(clk) then
      if (rst = '1') then
        output_count <= 0;
        first_output <= (others => '0');
      elsif (out_valid = '1') then
        if (out_sop = '1') then
          first_output <= out_data;
        end if;
        output_count <= output_count + 1;
      end if;
    end if;

  end process monitor;

  main : process is

    procedure reset_dut is
    begin

      rst   <= '1';
      valid <= '0';
      wait for 3 * CLK_PERIOD;
      wait until rising_edge(clk);
      rst   <= '0';

    end procedure reset_dut;

    procedure send_packet (
      payload : byte_array_t
    ) is
    begin

      for index in payload'range loop

        data  <= payload(index);
        valid <= '1';

        if (index = payload'low) then
          sop <= '1';
        else
          sop <= '0';
        end if;

        if (index = payload'high) then
          eop <= '1';
        else
          eop <= '0';
        end if;

        loop

          wait until rising_edge(clk);
          exit when ready = '1';

        end loop;

      end loop;

      valid <= '0';
      sop   <= '0';
      eop   <= '0';

    end procedure send_packet;

  begin

    test_runner_setup(runner, runner_cfg);

    while test_suite loop

      if run("extracts framed message") then
        reset_dut;
        send_packet(MOLD_ADD);
        wait for 1 ns;
        check_equal(output_count, 36);
        check_equal(first_output, std_logic_vector'(x"41"));
        check_equal(out_sequence, to_unsigned(1, 64));
        check_equal(expected, to_unsigned(2, 64));
        check_equal(malformed, '0');
      elsif run("detects sequence gap") then
        reset_dut;
        send_packet(MOLD_ADD);
        send_packet(HEARTBEAT_SEQ3);
        wait for 1 ns;
        check_equal(gap, '1');
        check_equal(heartbeat, '1');
        check_equal(expected, to_unsigned(3, 64));
      elsif run("rejects truncated payload") then
        reset_dut;
        send_packet(TRUNCATED);
        wait for 1 ns;
        check_equal(malformed, '1');
        check_equal(output_count, 1);
      end if;

    end loop;

    test_runner_cleanup(runner);
    wait;

  end process main;

end architecture tb;
