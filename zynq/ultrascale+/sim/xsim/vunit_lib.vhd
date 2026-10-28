-- Stand-in for the part of VUnit the test benches use, compiled as library
-- vunit_lib for the Vivado simulator only (see ../xsim.py). xsim 2026.1
-- compiles VUnit 4.7 but cannot elaborate it: its static elaboration
-- evaluates VUnit's protected-type storage and fails inside
-- integer_vector_ptr_pkg. GHDL and NVC keep running the real VUnit.
--
-- Behaviour follows VUnit's: tests run in the order of enabled_test_cases
-- from runner_cfg, run() records test_start:<name> in <output path>/
-- vunit_results, test_runner_cleanup records test_suite_done, and the first
-- failed check or error() stops the simulation. Add an overload here when a
-- bench needs a VUnit call this file lacks.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

library std;
  use std.textio.all;

package vunit_xsim_pkg is

  subtype runner_sync_t is std_logic;

  signal runner : runner_sync_t := '0';

  procedure test_runner_setup (
    signal runner     : in runner_sync_t;
    constant runner_cfg : in string
  );

  impure function test_suite return boolean;

  impure function run (
    constant name : in string
  ) return boolean;

  procedure test_runner_cleanup (
    signal runner : in runner_sync_t
  );

  procedure info (
    constant msg : in string
  );

  procedure error (
    constant msg : in string
  );

  procedure check (
    constant expr : in boolean;
    constant msg  : in string := ""
  );

  procedure check_equal (
    constant got      : in integer;
    constant expected : in integer;
    constant msg      : in string := ""
  );

  procedure check_equal (
    constant got      : in unsigned;
    constant expected : in unsigned;
    constant msg      : in string := ""
  );

  procedure check_equal (
    constant got      : in unsigned;
    constant expected : in natural;
    constant msg      : in string := ""
  );

  procedure check_equal (
    constant got      : in natural;
    constant expected : in unsigned;
    constant msg      : in string := ""
  );

  procedure check_equal (
    constant got      : in std_logic_vector;
    constant expected : in std_logic_vector;
    constant msg      : in string := ""
  );

  procedure check_equal (
    constant got      : in unsigned;
    constant expected : in std_logic_vector;
    constant msg      : in string := ""
  );

  procedure check_equal (
    constant got      : in std_logic_vector;
    constant expected : in unsigned;
    constant msg      : in string := ""
  );

  procedure check_equal (
    constant got      : in std_logic;
    constant expected : in std_logic;
    constant msg      : in string := ""
  );

  procedure check_equal (
    constant got      : in boolean;
    constant expected : in boolean;
    constant msg      : in string := ""
  );

  procedure check_equal (
    constant got      : in string;
    constant expected : in string;
    constant msg      : in string := ""
  );

end package vunit_xsim_pkg;

package body vunit_xsim_pkg is

  type state_t is protected
    procedure configure (
      constant runner_cfg : in string
    );
    impure function next_test return boolean;
    impure function current return string;
    impure function results_file return string;
  end protected state_t;

  type state_t is protected body

    variable enabled   : line;
    variable test      : line;
    variable position  : natural := 1;
    variable out_path  : line;

    impure function one_based (
      constant value : in string
    ) return string is
      constant result : string(1 to value'length) := value;
    begin
      return result;
    end function one_based;

    -- runner_cfg is "key : value,key : value" with ',' and ':' inside keys
    -- and values doubled (vunit/test/suites.py encode_dict).
    impure function lookup (
      constant cfg : in string;
      constant key : in string
    ) return string is
      variable entry : line;
      variable index : natural := cfg'low;
    begin
      while index <= cfg'high loop
        if (cfg(index) = ',' or cfg(index) = ':') and index < cfg'high and
           cfg(index + 1) = cfg(index) then
          write(entry, cfg(index));
          index := index + 2;
        elsif cfg(index) = ',' then
          if entry /= null and entry.all'length >= key'length + 3 and
             entry.all(1 to key'length + 3) = key & " : " then
            return entry.all(key'length + 4 to entry.all'length);
          end if;
          deallocate(entry);
          index := index + 1;
        else
          write(entry, cfg(index));
          index := index + 1;
        end if;
      end loop;
      if entry /= null and entry.all'length >= key'length + 3 and
         entry.all(1 to key'length + 3) = key & " : " then
        return entry.all(key'length + 4 to entry.all'length);
      end if;
      return "";
    end function lookup;

    procedure configure (
      constant runner_cfg : in string
    ) is
    begin
      enabled  := new string'(one_based(lookup(runner_cfg, "enabled_test_cases")));
      out_path := new string'(one_based(lookup(runner_cfg, "output path")));
      position := 1;
    end procedure configure;

    -- Test names are separated by ',' and their own commas doubled.
    impure function next_test return boolean is
      variable name : line;
    begin
      deallocate(test);
      if enabled = null or position > enabled.all'length then
        return false;
      end if;
      while position <= enabled.all'length loop
        if enabled.all(position) = ',' and position < enabled.all'length and
           enabled.all(position + 1) = ',' then
          write(name, ',');
          position := position + 2;
        elsif enabled.all(position) = ',' then
          position := position + 1;
          exit;
        else
          write(name, enabled.all(position));
          position := position + 1;
        end if;
      end loop;
      if name = null then
        test := new string'("");
      else
        test := name;
      end if;
      return true;
    end function next_test;

    impure function current return string is
    begin
      if test = null then
        return "";
      end if;
      return test.all;
    end function current;

    impure function results_file return string is
    begin
      return out_path.all & "vunit_results";
    end function results_file;

  end protected body state_t;

  shared variable state : state_t;

  procedure record_result (
    constant entry : in string;
    constant mode  : in file_open_kind
  ) is
    file     results : text;
    variable status  : file_open_status;
    variable l       : line;
  begin
    file_open(status, results, state.results_file, mode);
    assert status = open_ok
      report "cannot write " & state.results_file
      severity failure;
    write(l, entry);
    writeline(results, l);
    file_close(results);
  end procedure record_result;

  procedure fail (
    constant msg : in string
  ) is
  begin
    report msg severity error;
    std.env.finish(1);
  end procedure fail;

  procedure test_runner_setup (
    signal runner     : in runner_sync_t;
    constant runner_cfg : in string
  ) is
  begin
    state.configure(runner_cfg);
    record_result("", write_mode);
  end procedure test_runner_setup;

  impure function test_suite return boolean is
  begin
    return state.next_test;
  end function test_suite;

  impure function run (
    constant name : in string
  ) return boolean is
  begin
    if state.current /= name then
      return false;
    end if;
    report "Test " & name severity note;
    record_result("test_start:" & name, append_mode);
    return true;
  end function run;

  procedure test_runner_cleanup (
    signal runner : in runner_sync_t
  ) is
  begin
    record_result("test_suite_done", append_mode);
    std.env.finish(0);
  end procedure test_runner_cleanup;

  procedure info (
    constant msg : in string
  ) is
  begin
    report msg severity note;
  end procedure info;

  procedure error (
    constant msg : in string
  ) is
  begin
    fail(msg);
  end procedure error;

  procedure check (
    constant expr : in boolean;
    constant msg  : in string := ""
  ) is
  begin
    if not expr then
      fail("Check failed. " & msg);
    end if;
  end procedure check;

  procedure equality_failed (
    constant got      : in string;
    constant expected : in string;
    constant msg      : in string
  ) is
  begin
    fail("Equality check failed - Got " & got & ". Expected " & expected & ". " & msg);
  end procedure equality_failed;

  procedure check_equal (
    constant got      : in integer;
    constant expected : in integer;
    constant msg      : in string := ""
  ) is
  begin
    if got /= expected then
      equality_failed(integer'image(got), integer'image(expected), msg);
    end if;
  end procedure check_equal;

  procedure check_equal (
    constant got      : in unsigned;
    constant expected : in unsigned;
    constant msg      : in string := ""
  ) is
  begin
    if got /= expected then
      equality_failed(to_hstring(got), to_hstring(expected), msg);
    end if;
  end procedure check_equal;

  procedure check_equal (
    constant got      : in unsigned;
    constant expected : in natural;
    constant msg      : in string := ""
  ) is
  begin
    if got /= expected then
      equality_failed(to_hstring(got), integer'image(expected), msg);
    end if;
  end procedure check_equal;

  procedure check_equal (
    constant got      : in natural;
    constant expected : in unsigned;
    constant msg      : in string := ""
  ) is
  begin
    if got /= expected then
      equality_failed(integer'image(got), to_hstring(expected), msg);
    end if;
  end procedure check_equal;

  procedure check_equal (
    constant got      : in std_logic_vector;
    constant expected : in std_logic_vector;
    constant msg      : in string := ""
  ) is
  begin
    if got /= expected then
      equality_failed(to_hstring(got), to_hstring(expected), msg);
    end if;
  end procedure check_equal;

  procedure check_equal (
    constant got      : in unsigned;
    constant expected : in std_logic_vector;
    constant msg      : in string := ""
  ) is
  begin
    if got /= unsigned(expected) then
      equality_failed(to_hstring(got), to_hstring(expected), msg);
    end if;
  end procedure check_equal;

  procedure check_equal (
    constant got      : in std_logic_vector;
    constant expected : in unsigned;
    constant msg      : in string := ""
  ) is
  begin
    if unsigned(got) /= expected then
      equality_failed(to_hstring(got), to_hstring(expected), msg);
    end if;
  end procedure check_equal;

  procedure check_equal (
    constant got      : in std_logic;
    constant expected : in std_logic;
    constant msg      : in string := ""
  ) is
  begin
    if got /= expected then
      equality_failed(std_logic'image(got), std_logic'image(expected), msg);
    end if;
  end procedure check_equal;

  procedure check_equal (
    constant got      : in boolean;
    constant expected : in boolean;
    constant msg      : in string := ""
  ) is
  begin
    if got /= expected then
      equality_failed(boolean'image(got), boolean'image(expected), msg);
    end if;
  end procedure check_equal;

  procedure check_equal (
    constant got      : in string;
    constant expected : in string;
    constant msg      : in string := ""
  ) is
  begin
    if got /= expected then
      equality_failed(got, expected, msg);
    end if;
  end procedure check_equal;

end package body vunit_xsim_pkg;

context vunit_context is
  library vunit_lib;
  use vunit_lib.vunit_xsim_pkg.all;
end context vunit_context;
