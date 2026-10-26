-- MoldUDP64 framing at 64 bits per beat (II = 1, no backpressure).
--
-- Messages may start at any byte lane, and one beat can hold the tail of one
-- message, the 2-byte length of the next, and that message's first bytes.
-- The parser works on whole beats rather than bytes: because every message
-- is at least 12 bytes long, a beat contains at most one boundary (the end
-- of the header or of a message), followed by at most one length prefix and
-- the start of the next message, which cannot also end in that beat. The
-- role of every lane therefore follows from a few small lane offsets
-- computed in parallel, instead of a chain of eight byte-wide FSM steps.
-- Message bytes go to one of two ping-pong buffers, so the message finishing
-- in a beat and the message starting in it never collide.
--
-- Messages shorter than 12 bytes (the smallest ITCH message) or longer than
-- 64 bytes are malformed; the bound is what keeps one completion per beat.
-- Duplicate and gap evaluation runs one cycle after the header and still
-- precedes the earliest possible completion.
--
-- Sequence rules match the A53 software model (hft-plsim): a packet wholly
-- at or before the expected sequence is a duplicate and produces nothing; a
-- packet starting past it is a gap; the expected sequence then advances to
-- sequence + count, but only once the packet has ended well formed. A
-- malformed packet never moves the expected sequence, exactly as the model
-- rejects the whole datagram. Payload keep masks must be contiguous (the
-- UDP receiver guarantees it).

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library work;
  use work.hft_types_pkg.all;

entity moldudp64_rx is
  port (
    clk : in    std_logic;
    rst : in    std_logic;

    s_payload        : in    axis64_t;
    s_first          : in    std_logic;
    s_ingress_cycles : in    unsigned(63 downto 0);

    m_message : out   itch_message_t;
    m_valid   : out   std_logic;

    gap_pulse         : out   std_logic;
    duplicate_pulse   : out   std_logic;
    malformed_pulse   : out   std_logic;
    heartbeat_pulse   : out   std_logic;
    expected_sequence : out   unsigned(63 downto 0)
  );
end entity moldudp64_rx;

architecture rtl of moldudp64_rx is

  -- header:  payload bytes 0..19 (session, sequence, count)
  -- len_hi:  the next byte is the high byte of a message length
  -- len_lo:  the high byte is held; the next byte is the low byte
  -- message: message body bytes
  -- trailer: all declared messages consumed; any further byte is malformed
  -- skip:    rest of a malformed packet

  type parse_t is (header, len_hi, len_lo, message, trailer, skip);

  signal state : parse_t := header;

  attribute fsm_encoding : string;
  attribute fsm_encoding of state   : signal is "one_hot";
  attribute fsm_safe_state : string;
  attribute fsm_safe_state of state : signal is "reset_state";

  type buffers_t is array (0 to 1) of byte_array_t(0 to itch_buffer_bytes - 1);

  -- Header bytes 10..19: sequence (10..17) and message count (18..19).

  subtype header_tail_t is byte_array_t(10 to 19);

  signal buffers       : buffers_t             := (others => (others => (others => '0')));
  signal active        : natural range 0 to 1  := 0;
  signal header_pos    : unsigned(4 downto 0)  := (others => '0');
  signal header_tail   : header_tail_t         := (others => (others => '0'));
  signal length_high   : byte_t                := (others => '0');
  signal length_r      : unsigned(6 downto 0)  := (others => '0');
  signal remaining     : unsigned(6 downto 0)  := (others => '0');
  signal index         : unsigned(6 downto 0)  := (others => '0');
  signal messages_left : unsigned(15 downto 0) := (others => '0');
  signal message_seq   : unsigned(63 downto 0) := (others => '0');
  signal ingress_r     : unsigned(63 downto 0) := (others => '0');

  -- Registered packet-level evaluation (one cycle after the header).
  signal header_done : std_logic             := '0';
  signal packet_seq  : unsigned(63 downto 0) := (others => '0');
  signal packet_cnt  : unsigned(15 downto 0) := (others => '0');
  signal expected_r  : unsigned(63 downto 0) := (others => '0');
  signal expected_ok : std_logic             := '0';
  signal duplicate   : std_logic             := '0';

  -- Expected-sequence commit, held until the packet's last beat is clean.
  -- pending_valid: header evaluated, waiting for the end of the packet.
  -- ended_clean:   packet ended (header in its last beat), waiting for the
  --                header evaluation one cycle later.
  signal pending_expected : unsigned(63 downto 0) := (others => '0');
  signal pending_valid    : std_logic             := '0';
  signal ended_clean      : std_logic             := '0';
  signal packet_bad       : std_logic             := '0';

  signal message_r   : itch_message_t := itch_message_reset;
  signal valid_r     : std_logic      := '0';
  signal gap_r       : std_logic      := '0';
  signal dup_r       : std_logic      := '0';
  signal malformed_r : std_logic      := '0';
  signal heartbeat_r : std_logic      := '0';

  -- Lane offsets are small signed integers: a length prefix can begin one
  -- lane "before" the beat (its high byte arrived in the previous beat) or
  -- just past it.

  subtype lane_t is integer range -1 to 10;

  function lane_of (
    data : std_logic_vector(63 downto 0);
    lane : lane_t
  ) return byte_t is
  begin

    if ((lane >= 0) and (lane <= 7)) then
      return lane_byte(data, lane);
    end if;

    return (others => '0');

  end function lane_of;

begin

  m_message         <= message_r;
  m_valid           <= valid_r;
  gap_pulse         <= gap_r;
  duplicate_pulse   <= dup_r;
  malformed_pulse   <= malformed_r;
  heartbeat_pulse   <= heartbeat_r;
  expected_sequence <= expected_r;

  parse : process (clk) is

    variable data        : std_logic_vector(63 downto 0);
    variable st          : parse_t;
    variable first_lane  : lane_t;
    variable last_lane   : lane_t;
    variable count       : natural range 0 to 8;
    variable pos         : natural range 0 to 20;
    variable tail        : header_tail_t;
    variable header_end  : lane_t;
    variable boundary    : lane_t;
    variable has_prefix  : boolean;
    variable tail_start  : lane_t;
    variable source      : integer;
    variable high        : byte_t;
    variable len_v       : unsigned(15 downto 0);
    variable new_lane    : lane_t;
    variable new_count   : natural range 0 to 8;
    variable left_v      : unsigned(15 downto 0);
    variable active_v    : natural range 0 to 1;
    variable bufs        : buffers_t;
    variable completed   : boolean;
    variable done_buffer : natural range 0 to 1;
    variable done_length : unsigned(6 downto 0);
    variable bad         : boolean;
    variable header_now  : boolean;
    variable header_seq  : unsigned(63 downto 0);
    variable header_cnt  : unsigned(15 downto 0);
    variable count_v     : unsigned(15 downto 0);
    variable pend_v      : unsigned(63 downto 0);
    variable pend_ok     : boolean;
    variable clean_v     : boolean;
    variable bad_seen    : boolean;

  begin

    if rising_edge(clk) then
      valid_r     <= '0';
      gap_r       <= '0';
      dup_r       <= '0';
      malformed_r <= '0';
      heartbeat_r <= '0';
      header_done <= '0';

      if (rst = '1') then
        state         <= header;
        expected_ok   <= '0';
        expected_r    <= (others => '0');
        duplicate     <= '0';
        pending_valid <= '0';
        ended_clean   <= '0';
        packet_bad    <= '0';
      else
        pend_v   := pending_expected;
        pend_ok  := pending_valid = '1';
        clean_v  := ended_clean = '1';
        bad_seen := packet_bad = '1';

        -- Packet-level checks for the header parsed in the previous cycle.
        if (header_done = '1') then
          if (packet_cnt = x"FFFF") then
            count_v := (others => '0');
          else
            count_v := packet_cnt;
          end if;
          if ((expected_ok = '1') and (count_v /= 0) and
              (packet_seq + count_v <= expected_r)) then
            duplicate <= '1';
            dup_r     <= '1';
            clean_v   := false;
          else
            if ((expected_ok = '1') and (packet_seq > expected_r)) then
              gap_r <= '1';
            end if;
            if (count_v = 0) then
              heartbeat_r <= '1';
            end if;
            if (clean_v) then
              -- The packet already ended well formed: commit now.
              expected_r  <= packet_seq + count_v;
              expected_ok <= '1';
              clean_v     := false;
            else
              pend_v  := packet_seq + count_v;
              pend_ok := true;
            end if;
          end if;
        end if;

        if (s_payload.valid = '1') then
          data        := s_payload.data;
          st          := state;
          pos         := to_integer(header_pos);
          tail        := header_tail;
          left_v      := messages_left;
          active_v    := active;
          bufs        := buffers;
          completed   := false;
          done_buffer := active;
          done_length := length_r;
          bad         := false;
          header_now  := false;
          header_seq  := (others => '0');
          header_cnt  := (others => '0');
          has_prefix  := false;
          boundary    := 0;
          tail_start  := 8;

          -- Contiguous keep: the first and last enabled lanes and the count.
          first_lane := 8;
          last_lane  := -1;

          for lane in 7 downto 0 loop

            if (s_payload.keep(lane) = '1') then
              first_lane := lane;
            end if;

          end loop;

          for lane in 0 to 7 loop

            if (s_payload.keep(lane) = '1') then
              last_lane := lane;
            end if;

          end loop;

          if (last_lane >= first_lane) then
            count := last_lane - first_lane + 1;
          else
            count := 0;
          end if;

          if (s_first = '1') then
            st        := header;
            pos       := 0;
            duplicate <= '0';
            ingress_r <= s_ingress_cycles;
            bad_seen  := false;
            pend_ok   := false;
          end if;

          -- An empty beat carries nothing to parse.
          if (count > 0) then
            -- Phase 1: bytes up to the boundary in the beat, if there is one.
            case st is

              when header =>

                -- Header byte j sits in lane first_lane + (j - pos).
                for j in 10 to 19 loop

                  source := first_lane + (j - pos);
                  if ((j >= pos) and (source <= last_lane)) then
                    tail(j) := lane_byte(data, source);
                  end if;

                end loop;

                if (pos + count >= 20) then
                  header_end := first_lane + (19 - pos);
                  header_now := true;

                  for j in 0 to 7 loop

                    header_seq(63 - (8 * j) downto 56 - (8 * j)) := unsigned(tail(10 + j));

                  end loop;

                  header_cnt := be16(tail(18), tail(19));
                  left_v     := header_cnt;
                  pos        := 20;
                  if ((header_cnt = 0) or (header_cnt = x"FFFF")) then
                    st         := trailer;
                    tail_start := header_end + 1;
                  else
                    st         := len_hi;
                    has_prefix := true;
                    boundary   := header_end + 1;
                  end if;
                else
                  pos := pos + count;
                end if;

              when len_hi =>

                has_prefix := true;
                boundary   := first_lane;

              when len_lo =>

                -- The high byte arrived in the previous beat.
                has_prefix := true;
                boundary   := first_lane - 1;

              when message =>

                -- Old-buffer bytes: lanes first_lane.. at offset index.
                for j in 0 to itch_buffer_bytes - 1 loop

                  source := first_lane + j - to_integer(index);
                  if ((j >= to_integer(index)) and (source <= last_lane) and
                      (j < to_integer(index) + to_integer(remaining))) then
                    bufs(active_v)(j) := lane_of(data, source);
                  end if;

                end loop;

                if (to_integer(remaining) <= count) then
                  completed   := true;
                  done_buffer := active_v;
                  done_length := length_r;
                  active_v    := 1 - active_v;
                  left_v      := left_v - 1;
                  if (left_v = 0) then
                    st         := trailer;
                    tail_start := first_lane + to_integer(remaining);
                  else
                    st         := len_hi;
                    has_prefix := true;
                    boundary   := first_lane + to_integer(remaining);
                  end if;
                else
                  index     <= index + count;
                  remaining <= remaining - count;
                end if;

              when trailer =>

                tail_start := first_lane;

              when skip =>

                null;

            end case;

            -- Phase 2: the length prefix at `boundary` and the next message's
            -- first bytes. A prefix split across beats parks in len_hi/len_lo.
            if (has_prefix) then
              if (boundary = first_lane - 1) then
                high := length_high;
              else
                high := lane_of(data, boundary);
              end if;

              if (boundary > last_lane) then
                st := len_hi;
              elsif (boundary + 1 > last_lane) then
                st          := len_lo;
                length_high <= high;
              else
                len_v := be16(high, lane_of(data, boundary + 1));
                if ((len_v < 12) or (len_v > 64)) then
                  bad := true;
                  st  := skip;
                else
                  new_lane := boundary + 2;
                  if (new_lane <= last_lane) then
                    new_count := last_lane - new_lane + 1;
                  else
                    new_count := 0;
                  end if;

                  -- Fewer than 12 bytes remain in the beat, so the message
                  -- only starts here; its first bytes are at offset 0.
                  for j in 0 to 7 loop

                    if (j < new_count) then
                      bufs(active_v)(j) := lane_of(data, new_lane + j);
                    end if;

                  end loop;

                  length_r  <= len_v(6 downto 0);
                  remaining <= len_v(6 downto 0) - new_count;
                  index     <= to_unsigned(new_count, 7);
                  st        := message;
                end if;
              end if;
            end if;
          end if;

          -- Any byte after the last declared message is malformed.
          if ((st = trailer) and (tail_start <= last_lane)) then
            bad := true;
            st  := skip;
          end if;

          -- A datagram that ends mid-header, mid-prefix or mid-message is
          -- truncated.
          if ((s_payload.last = '1') and (st /= trailer) and (st /= skip)) then
            bad := true;
          end if;
          if (bad) then
            bad_seen := true;
          end if;
          if (s_payload.last = '1') then
            st  := header;
            pos := 0;
            if (bad_seen) then
              pend_ok := false;
            elsif (pend_ok) then
              expected_r  <= pend_v;
              expected_ok <= '1';
              pend_ok     := false;
            elsif (header_now) then
              clean_v := true;
            end if;
          end if;

          state         <= st;
          header_pos    <= to_unsigned(pos, 5);
          header_tail   <= tail;
          messages_left <= left_v;
          active        <= active_v;
          buffers       <= bufs;

          if (header_now) then
            header_done <= '1';
            packet_seq  <= header_seq;
            packet_cnt  <= header_cnt;
            message_seq <= header_seq;
          end if;

          if (bad) then
            malformed_r <= '1';
          end if;

          -- Duplicates are parsed (to keep framing checks) but never emitted.
          if (completed) then
            message_seq <= message_seq + 1;
            if (duplicate = '0') then
              message_r.bytes          <= bufs(done_buffer);
              message_r.length         <= done_length;
              message_r.feed_sequence  <= message_seq;
              message_r.ingress_cycles <= ingress_r;
              valid_r                  <= '1';
            end if;
          end if;
        end if;

        pending_expected <= pend_v;
        if (pend_ok) then
          pending_valid <= '1';
        else
          pending_valid <= '0';
        end if;
        if (clean_v) then
          ended_clean <= '1';
        else
          ended_clean <= '0';
        end if;
        if (bad_seen) then
          packet_bad <= '1';
        else
          packet_bad <= '0';
        end if;
      end if;
    end if;

  end process parse;

end architecture rtl;
