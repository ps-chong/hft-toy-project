#!/usr/bin/env bash
# Removes generated Vivado and xsim output: build/vivado, build/xsim, and this
# checkout's staging directory on C:.
#
#   scripts/linux/clean-fpga.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

rm -rf "${hft_repo}/build/vivado" "${hft_repo}/build/xsim" "$(hft_stage_dir)"
