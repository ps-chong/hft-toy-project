library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

entity axis64_to_byte is
  port (
    clk : in    std_logic;
    rst : in    std_logic;

    s_axis_tdata  : in    std_logic_vector(63 downto 0);
    s_axis_tkeep  : in    std_logic_vector(7 downto 0);
    s_axis_tvalid : in    std_logic;
    s_axis_tlast  : in    std_logic;
    s_axis_tready : out   std_logic;

    byte_data  : out   std_logic_vector(7 downto 0);
    byte_valid : out   std_logic;
    byte_sop   : out   std_logic;
    byte_eop   : out   std_logic;
    byte_ready : in    std_logic
  );
end entity axis64_to_byte;

architecture rtl of axis64_to_byte is

  function first_lane (
    keep : std_logic_vector(7 downto 0)
  )
    return natural is
  begin

    for index in 0 to 7 loop

      if (keep(index) = '1') then
        return index;
      end if;

    end loop;

    return 0;

  end function first_lane;

  function last_lane (
    keep : std_logic_vector(7 downto 0)
  )
    return natural is
  begin

    for index in 7 downto 0 loop

      if (keep(index) = '1') then
        return index;
      end if;

    end loop;

    return 0;

  end function last_lane;

  function following_lane (
    keep    : std_logic_vector(7 downto 0);
    current : natural
  )
    return natural is
  begin

    for index in current + 1 to 7 loop

      if (keep(index) = '1') then
        return index;
      end if;

    end loop;

    return current;

  end function following_lane;

  signal data_i         : std_logic_vector(63 downto 0) := (others => '0');
  signal keep_i         : std_logic_vector(7 downto 0)  := (others => '0');
  signal last_i         : std_logic                     := '0';
  signal lane_i         : natural range 0 to 7          := 0;
  signal buffered_i     : std_logic                     := '0';
  signal start_of_frame : std_logic                     := '1';

begin

  s_axis_tready <= not buffered_i;
  byte_valid    <= buffered_i;
  byte_data     <= data_i((lane_i * 8) + 7 downto lane_i * 8);
  byte_sop      <= buffered_i and start_of_frame;
  byte_eop      <= buffered_i and last_i
                   when lane_i = last_lane(keep_i)
                   else '0';

  unpack : process (clk) is
  begin

    if rising_edge(clk) then
      if (rst = '1') then
        data_i         <= (others => '0');
        keep_i         <= (others => '0');
        last_i         <= '0';
        lane_i         <= 0;
        buffered_i     <= '0';
        start_of_frame <= '1';
      else
        if ((buffered_i = '0') and (s_axis_tvalid = '1')) then
          if (s_axis_tkeep /= x"00") then
            data_i     <= s_axis_tdata;
            keep_i     <= s_axis_tkeep;
            last_i     <= s_axis_tlast;
            lane_i     <= first_lane(s_axis_tkeep);
            buffered_i <= '1';
          end if;
        elsif ((buffered_i = '1') and (byte_ready = '1')) then
          if (start_of_frame = '1') then
            start_of_frame <= '0';
          end if;

          if (lane_i = last_lane(keep_i)) then
            buffered_i <= '0';
            if (last_i = '1') then
              start_of_frame <= '1';
            end if;
          else
            lane_i <= following_lane(keep_i, lane_i);
          end if;
        end if;
      end if;
    end if;

  end process unpack;

end architecture rtl;
