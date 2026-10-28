#!/usr/bin/env python3
"""Run the VUnit test benches on the Vivado simulator (xsim).

VUnit 4.7 has no xsim backend, and xsim cannot elaborate VUnit's own VHDL
library, so this drives xvhdl, xelab and xsim directly with the project
run.py defines and links the benches against xsim/vunit_lib.vhd, a stand-in
for the VUnit calls they use:

  export  (where VUnit is installed, e.g. hft-host:dev) writes the compile
          order of the hft library files the test benches need, and their
          test names, as VUnit sees them.
  run     (in WSL with the Windows Vivado; see scripts/linux/xsim.sh)
          compiles with xvhdl --2008, then elaborates and runs every test in a
          simulation of its own, as VUnit does, and judges it from the
          vunit_results file the way VUnit's own runner does.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path

from run import ROOT, bench_configs, bench_generics, configure_suite

CMD = "/mnt/c/Windows/System32/cmd.exe"
LIBRARY = "hft"
VUNIT_STAND_IN = "zynq/ultrascale+/sim/xsim/vunit_lib.vhd"


def export(destination: Path) -> None:
    destination = destination.resolve()
    sys.argv = [sys.argv[0], "--output-path", str(destination.parent / "vunit_out")]
    vu = configure_suite()
    lib = vu.library(LIBRARY)
    benches = lib.get_test_benches()
    bench_files = lib.get_source_files(str(ROOT / "zynq/ultrascale+/tb/tb_*.vhd"))

    # The implementation subset adds the package bodies and architectures
    # that a plain compile order of the benches' dependencies leaves out.
    files = [
        {"path": Path(source.name).resolve().relative_to(ROOT).as_posix(), "library": LIBRARY}
        for source in vu.get_compile_order(vu.get_implementation_subset(bench_files))
        if source.library.name == LIBRARY
    ]
    tests = {bench.name: [test.name for test in bench.get_tests()] for bench in benches}
    destination.write_text(json.dumps({"files": files, "benches": tests}, indent=2) + "\n")
    print(f"Exported {len(files)} files and {sum(map(len, tests.values()))} tests.")


@dataclass
class Run:
    """One test in a simulation of its own, as VUnit runs them by default;
    test is "" for a bench without named tests."""

    bench: str
    config: str
    generics: dict[str, str | int]
    test: str
    index: int

    @property
    def snapshot(self) -> str:
        return f"{self.bench}__{self.config}" if self.config else self.bench

    @property
    def name(self) -> str:
        return f"{self.snapshot}__{self.index}"

    @property
    def suite(self) -> str:
        parts = [LIBRARY, self.bench, self.config]
        return ".".join(part for part in parts if part)

    @property
    def full_name(self) -> str:
        return f"{self.suite}.{self.test}" if self.test else self.suite


def encode_dict(values: dict[str, str | bool]) -> str:
    """VUnit's runner_cfg encoding (vunit/test/suites.py)."""

    def escape(value: str) -> str:
        return value.replace(":", "::").replace(",", ",,")

    encoded = []
    for key in sorted(values):
        value = values[key]
        text = str(value).lower() if isinstance(value, bool) else str(value)
        encoded.append(f"{escape(key)} : {escape(text)}")
    return ",".join(encoded)


def result(file: Path, test: str) -> str:
    """VUnit's reading of vunit_results for a single-test simulation: the test
    passed if the suite finished, failed if it started, else never ran."""
    started = False
    done = False
    if file.exists():
        for line in file.read_text(errors="replace").splitlines():
            started = started or line == f"test_start:{test}"
            done = done or line.startswith("test_suite_done")
    if done:
        return "passed"
    return "failed" if started or not test else "skipped"


class Xsim:
    def __init__(self, vivado_root: Path, stage: Path) -> None:
        self.bin = vivado_root / "bin"
        self.work = stage / "xsim"
        self.stage_win = subprocess.run(
            ["wslpath", "-w", str(stage)], check=True, capture_output=True, text=True
        ).stdout.strip()

    def win(self, relative: str) -> str:
        """Windows path of a staged repository-relative path, with '/'."""
        return f"{self.stage_win}/src/{relative}".replace("\\", "/")

    def work_win(self, relative: str) -> str:
        return f"{self.stage_win}/xsim/{relative}".replace("\\", "/")

    def call(self, tool: str, args: list[str], log: str) -> bool:
        """Runs a tool from the work directory with its options in a file, so
        nothing passes through cmd.exe quoting."""
        options = self.work / f"{log}.args"
        options.write_text("\n".join([*args, "-log", f"{log}.log"]) + "\n")
        bat = subprocess.run(
            ["wslpath", "-w", str(self.bin / f"{tool}.bat")],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        process = subprocess.run(
            [CMD, "/d", "/c", bat, "-f", options.name],
            check=False,
            cwd=self.work,
            capture_output=True,
            text=True,
            errors="replace",
        )
        if process.returncode != 0:
            print(process.stdout[-4000:], process.stderr[-2000:], sep="\n")
        return process.returncode == 0


def runs_from(benches: dict[str, list[str]], pattern: str) -> list[Run]:
    generics = bench_generics()
    configs = bench_configs()
    runs = []
    for bench, tests in sorted(benches.items()):
        common: dict[str, str | int] = dict(generics.get(bench, {}))
        for config, extra in (configs.get(bench) or {"": {}}).items():
            for index, test in enumerate(tests or [""]):
                item = Run(bench, config, {**common, **extra}, test, index)
                if re.search(pattern, item.full_name):
                    runs.append(item)
    return runs


def staged_generic(value: str | int, xsim: Xsim) -> str:
    """Repository paths in generics become staged Windows paths."""
    text = str(value)
    root = ROOT.as_posix()
    if text == root or text.startswith(root + "/"):
        return xsim.win(text[len(root) + 1 :])
    return text


def run(args: argparse.Namespace) -> int:
    exported = json.loads(args.export.read_text())
    xsim = Xsim(args.vivado_root, args.stage)
    shutil.rmtree(xsim.work, ignore_errors=True)
    xsim.work.mkdir(parents=True)
    logs = args.output / "logs"
    shutil.rmtree(logs, ignore_errors=True)
    logs.mkdir(parents=True)

    files = [{"path": VUNIT_STAND_IN, "library": "vunit_lib"}, *exported["files"]]
    libraries = sorted({file["library"] for file in files})
    project = [f'vhdl2008 {file["library"]} "{xsim.win(file["path"])}"' for file in files]
    (xsim.work / "compile.prj").write_text("\n".join(project) + "\n")
    print(f"Compiling {len(project)} files into {', '.join(libraries)}.")
    compiled = xsim.call("xvhdl", ["-prj", "compile.prj"], "compile")
    shutil.copy(xsim.work / "compile.log", logs)
    if not compiled:
        print("xvhdl failed; see build/xsim/logs/compile.log", file=sys.stderr)
        return 1

    suite = ET.Element("testsuite", name="xsim")
    failures = 0
    skipped = 0
    total = 0
    for item in runs_from(exported["benches"], args.filter):
        started = time.monotonic()
        output = xsim.work / "out" / item.name
        output.mkdir(parents=True)
        runner_cfg = {
            "enabled_test_cases": item.test.replace(",", ",,"),
            "use_color": False,
            "output path": xsim.work_win(f"out/{item.name}") + "/",
            "active python runner": True,
            "tb path": xsim.win("zynq/ultrascale+/tb") + "/",
        }
        generics = {"runner_cfg": encode_dict(runner_cfg)}
        for name, value in item.generics.items():
            generics[name] = staged_generic(value, xsim)
        # runner_cfg is a top-level generic, so every test needs its own
        # elaboration; reusing the snapshot name keeps xsim.dir small.
        elaborate = [f"{LIBRARY}.{item.bench}", "-s", item.snapshot, "--debug", "off"]
        for library in libraries:
            elaborate += ["-L", library]
        for name, value in generics.items():
            elaborate += ["-generic_top", f'"{name}={value}"']

        ok = xsim.call("xelab", elaborate, f"elab_{item.name}") and xsim.call(
            "xsim", [item.snapshot, "-R"], f"run_{item.name}"
        )
        for log in xsim.work.glob(f"*_{item.name}.log"):
            shutil.copy(log, logs)
        status = result(output / "vunit_results", item.test) if ok else "failed"
        total += 1
        case = ET.SubElement(
            suite,
            "testcase",
            classname=item.suite,
            name=item.test or item.bench,
            time=f"{time.monotonic() - started:.1f}",
        )
        if status == "failed":
            failures += 1
            ET.SubElement(case, "failure", message=f"see logs/run_{item.name}.log")
        elif status == "skipped":
            skipped += 1
            ET.SubElement(case, "skipped", message="the test never started")
        print(f"{status:7} {item.full_name}", flush=True)

    suite.set("tests", str(total))
    suite.set("failures", str(failures))
    suite.set("skipped", str(skipped))
    junit = args.output / "xsim-junit.xml"
    ET.ElementTree(suite).write(junit, encoding="utf-8", xml_declaration=True)
    passed = total - failures - skipped
    print(f"{passed} of {total} tests passed on xsim ({failures} failed, {skipped} skipped).")
    # A test that never started did not pass either.
    return 0 if total and passed == total else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    export_parser = commands.add_parser("export")
    export_parser.add_argument("destination", type=Path)
    run_parser = commands.add_parser("run")
    run_parser.add_argument("--export", type=Path, required=True)
    run_parser.add_argument("--stage", type=Path, required=True)
    run_parser.add_argument("--vivado-root", type=Path, required=True)
    run_parser.add_argument("--output", type=Path, required=True)
    run_parser.add_argument(
        "--filter", default="", help="regular expression on hft.<bench>[.<config>].<test>"
    )
    args = parser.parse_args()
    if args.command == "export":
        export(args.destination)
        return 0
    return run(args)


if __name__ == "__main__":
    sys.exit(main())
