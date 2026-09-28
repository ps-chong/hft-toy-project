library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library vunit_lib;
  context vunit_lib.vunit_context;

entity tb_axis64_to_byte is
  generic (
    runner_cfg : string
  );
end entity tb_axis64_to_byte;

architecture tb of tb_axis64_to_byte is

  constant clk_period : time := 10 ns;

  signal clk : std_logic := '0';
  signal rst : std_logic := '1';

  signal s_data  : std_logic_vector(63 downto 0) := (others => '0');
  signal s_keep  : std_logic_vector(7 downto 0)  := (others => '0');
  signal s_valid : std_logic                     := '0';
  signal s_last  : std_logic                     := '0';
  signal s_ready : std_logic;

  signal byte_data  : std_logic_vector(7 downto 0);
  signal byte_valid : std_logic;
  signal byte_sop   : std_logic;
  signal byte_eop   : std_logic;

  signal received_count : natural := 0;
  signal sop_count      : natural := 0;
  signal eop_count      : natural := 0;
  signal first_byte     : std_logic_vector(7 downto 0) := (others => '0');
  signal last_byte      : std_logic_vector(7 downto 0) := (others => '0');

begin

  clk <= not clk after clk_period / 2;

  dut : entity hft.axis64_to_byte
    port map (
      clk           => clk,
      rst           => rst,
      s_axis_tdata  => s_data,
      s_axis_tkeep  => s_keep,
      s_axis_tvalid => s_valid,
      s_axis_tlast  => s_last,
      s_axis_tready => s_ready,
      byte_data     => byte_data,
      byte_valid    => byte_valid,
      byte_sop      => byte_sop,
      byte_eop      => byte_eop,
      byte_ready    => '1'
    );

  monitor : process (clk) is
  begin

    if rising_edge(clk) then
      if (rst = '1') then
        received_count <= 0;
        sop_count      <= 0;
        eop_count      <= 0;
        first_byte     <= (others => '0');
        last_byte      <= (others => '0');
      elsif (byte_valid = '1') then
        if (received_count = 0) then
          first_byte <= byte_data;
        end if;
        last_byte      <= byte_data;
        received_count <= received_count + 1;
        if (byte_sop = '1') then
          sop_count <= sop_count + 1;
        end if;
        if (byte_eop = '1') then
          eop_count <= eop_count + 1;
        end if;
      end if;
    end if;

  end process monitor;

  main : process is

    procedure reset_dut is
    begin

      rst     <= '1';
      s_valid <= '0';
      wait for 3 * clk_period;
      wait until rising_edge(clk);
      rst <= '0';

    end procedure reset_dut;

    procedure send_word (
      data : std_logic_vector(63 downto 0);
      keep : std_logic_vector(7 downto 0);
      last : std_logic
    ) is
    begin

      s_data  <= data;
      s_keep  <= keep;
      s_last  <= last;
      s_valid <= '1';
      loop
        wait until rising_edge(clk);
        exit when s_ready = '1';
      end loop;
      s_valid <= '0';

    end procedure send_word;

  begin

    test_runner_setup(runner, runner_cfg);

    while test_suite loop
      if run("unpacks full and partial AXI words") then
        reset_dut;
        send_word(x"0807060504030201", x"FF", '0');
        send_word(x"0000000000000A09", x"03", '1');
        wait for 12 * clk_period;
        check_equal(received_count, 10);
        check_equal(sop_count, 1);
        check_equal(eop_count, 1);
        check_equal(first_byte, std_logic_vector'(x"01"));
        check_equal(last_byte, std_logic_vector'(x"0A"));
      end if;
    end loop;

    test_runner_cleanup(runner);
    wait;

  end process main;

end architecture tb;
