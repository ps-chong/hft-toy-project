#!/usr/bin/env bash
# Runs zynq/ultrascale+/vivado/tcl/build.tcl with the Windows Vivado 2026.1
# from WSL: mirrors the sources into a staging directory on C:, runs Vivado
# there, and copies the reports back to build/vivado/<profile>.
#
#   scripts/linux/build-fpga.sh [--profile sim-dma|sfp10g]
#                               [--goal synth|impl|bitstream] [--license PATH]
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

profile=sim-dma
goal=synth
license=""
while [ $# -gt 0 ]; do
  case "$1" in
    --profile) profile="$2"; shift 2 ;;
    --goal) goal="$2"; shift 2 ;;
    --license) license="$2"; shift 2 ;;
    *) hft_die "unknown argument '$1'" ;;
  esac
done
case "${profile}" in sim-dma | sfp10g) ;; *) hft_die "unknown profile '${profile}'" ;; esac
case "${goal}" in synth | impl | bitstream) ;; *) hft_die "unknown goal '${goal}'" ;; esac

"$(dirname "${BASH_SOURCE[0]}")/verify-tools.sh"
hft_setup_license "${license}"

stage="$(hft_stage_dir)"
work="${stage}/vivado/${profile}"
output="${hft_repo}/build/vivado/${profile}"
hft_stage_sources "${stage}" protocol/generated/vhdl zynq/ultrascale+
rm -rf "${work}" "${output}"
mkdir -p "${work}/out" "${output}"

copy_back() {
  rsync -rlt --chmod=D755,F644 --exclude '/project/' --exclude '.Xil/' \
    "${work}/out/" "${output}/"
}
trap 'hft_stop_stage_processes "${stage}"; copy_back; exit 130' INT TERM

src="$(hft_win_path "${stage}/src")"
out="$(hft_win_path "${work}/out")"
echo "Running Vivado profile '${profile}' (${goal}) in '${work}'."
status=0
hft_win_run "${work}" "$(hft_tool vivado)" -mode batch -nojournal \
  -log "${out}\\vivado.log" \
  -source "${src}\\zynq\\ultrascale+\\vivado\\tcl\\build.tcl" \
  -tclargs "${src}" "${out}" "${profile}" "${goal}" || status=$?
copy_back
trap - INT TERM

[ "${status}" -eq 0 ] || hft_die "Vivado failed with exit code ${status}"
echo "Reports in ${output}"
