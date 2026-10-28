#!/usr/bin/env bash
# Runs the VUnit test benches on the Windows Vivado 2026.1 simulator (xsim)
# from WSL; see zynq/ultrascale+/sim/xsim.py. VUnit itself runs inside the
# host image (containers/host/Dockerfile) only to export the compile order
# and test names; results land in build/xsim (xsim-junit.xml and logs/).
#
#   scripts/linux/xsim.sh [--filter <regex on hft.<bench>[.<config>].<test>>]
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

image="${HFT_CI_IMAGE:-hft-host:dev}"
output="${hft_repo}/build/xsim"

"$(dirname "${BASH_SOURCE[0]}")/verify-tools.sh"
if ! docker image inspect "${image}" >/dev/null 2>&1; then
  docker build -t "${image}" -f "${hft_repo}/containers/host/Dockerfile" \
    "${hft_repo}/containers/host"
fi

rm -rf "${output}"
mkdir -p "${output}"
docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp \
  -v "${hft_repo}:/workspace" -w /workspace "${image}" \
  python zynq/ultrascale+/sim/xsim.py export build/xsim/export.json

stage="$(hft_stage_dir)"
hft_stage_sources "${stage}" protocol/generated/vhdl protocol/vectors zynq/ultrascale+
trap 'hft_stop_stage_processes "${stage}"; exit 130' INT TERM
python3 "${hft_repo}/zynq/ultrascale+/sim/xsim.py" run --export "${output}/export.json" \
  --stage "${stage}" --vivado-root "${HFT_VIVADO_ROOT}" --output "${output}" "$@"
