#!/usr/bin/env bash
# Checks that the Windows Vivado 2026.1 installation can be driven from WSL.
#
#   scripts/linux/verify-tools.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

for tool in rsync wslpath; do
  command -v "${tool}" >/dev/null || hft_die "${tool} is not installed"
done
[ -x "${hft_cmd}" ] || hft_die "cmd.exe is unavailable; enable WSL interop"
vivado="$(hft_tool vivado)"
mkdir -p "${HFT_VIVADO_STAGE}"

# Vivado 2026.1 prints its banner for -version but exits with status 1, so
# the banner is the only reliable signal.
version="$(hft_win_run "${HFT_VIVADO_STAGE}" "${vivado}" -version 2>&1 | tr -d '\r' || true)"
if ! grep -qi '^vivado v2026\.1' <<<"${version}"; then
  hft_die "the executable at '${vivado}' is not Vivado 2026.1:"$'\n'"${version}"
fi

echo "Repository: ${hft_repo}"
echo "Vivado:     ${vivado}"
echo "Staging:    ${HFT_VIVADO_STAGE}"
head -n 1 <<<"${version}"
