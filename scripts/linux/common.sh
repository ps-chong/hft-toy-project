# shellcheck shell=bash
# Shared helpers for driving the Windows Vivado 2026.1 installation from WSL.
# Source this file; do not execute it.
#
# Vivado is a Windows program here (lib/win64.o, .bat launchers), so it needs
# native C:\ paths: callers mirror their inputs into a staging directory on
# /mnt/c, run the launchers through cmd.exe from there, and copy the results
# back into the Linux checkout.
#
#   HFT_VIVADO_ROOT     Vivado installation, as a WSL path
#   HFT_VIVADO_LICENSE  license file or directory (BASIC tier or higher), as a
#                       WSL path; defaults to %APPDATA%\XilinxLicense-BASIC
#                       when that exists (split-vivado-license.py)
#   HFT_VIVADO_STAGE    staging root on a Windows drive

HFT_VIVADO_ROOT="${HFT_VIVADO_ROOT:-/mnt/c/AMDDesignTools/2026.1/Vivado}"
HFT_VIVADO_STAGE="${HFT_VIVADO_STAGE:-/mnt/c/hft-vivado}"
hft_repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
hft_cmd=/mnt/c/Windows/System32/cmd.exe
hft_powershell=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe

hft_die() {
  echo "error: $*" >&2
  exit 1
}

# A process that outlives the terminal it was started from (the runner, a
# nohup job) keeps that terminal's interop socket in WSL_INTEROP; once the
# terminal is gone, Windows executables no longer start. /run/WSL/1_interop
# belongs to the distribution's init and lives as long as WSL does.
hft_restore_interop() {
  if [ -n "${WSL_INTEROP:-}" ] && [ -S "${WSL_INTEROP}" ]; then
    return
  fi
  local socket
  for socket in /run/WSL/1_interop /run/WSL/*_interop; do
    if [ -S "${socket}" ]; then
      export WSL_INTEROP="${socket}"
      return
    fi
  done
  hft_die "no live WSL interop socket under /run/WSL; Windows tools cannot start"
}

hft_win_path() {
  wslpath -w "$1"
}

# Runs a Windows command line from a working directory on a Windows drive
# (cmd.exe refuses a WSL working directory). Arguments must not need cmd
# quoting; pass anything complex through an -f argument file.
#   hft_win_run <working dir on /mnt/*> <program> [args...]
hft_win_run() {
  local dir="$1" program="$2"
  shift 2
  (cd "${dir}" && "${hft_cmd}" /d /c "$(hft_win_path "${program}")" "$@")
}

hft_appdata() {
  local appdata
  appdata="$(cd /mnt/c && "${hft_cmd}" /d /c echo %APPDATA% | tr -d '\r')"
  wslpath -u "${appdata}"
}

# Exports XILINXD_LICENSE_FILE to Windows processes when a license is known.
hft_setup_license() {
  local license="${1:-${HFT_VIVADO_LICENSE:-}}"
  if [ -z "${license}" ]; then
    local fallback
    fallback="$(hft_appdata)/XilinxLicense-BASIC"
    [ -d "${fallback}" ] && license="${fallback}"
  fi
  [ -n "${license}" ] || return 0
  [ -e "${license}" ] || hft_die "license '${license}' was not found"
  export XILINXD_LICENSE_FILE
  XILINXD_LICENSE_FILE="$(hft_win_path "${license}")"
  case ":${WSLENV:-}:" in
    *:XILINXD_LICENSE_FILE:*) ;;
    *) export WSLENV="${WSLENV:+${WSLENV}:}XILINXD_LICENSE_FILE" ;;
  esac
  echo "Using license: ${license}"
}

# Staging directory for this checkout, so a local build and the runner's
# checkout never share files.
hft_stage_dir() {
  local hash
  hash="$(printf '%s' "${hft_repo}" | sha1sum | cut -c1-8)"
  echo "${HFT_VIVADO_STAGE}/$(basename "${hft_repo}")-${hash}"
}

# Mirrors repository-relative paths into <stage>/src.
#   hft_stage_sources <stage> <path>...
hft_stage_sources() {
  local stage="$1"
  shift
  mkdir -p "${stage}/src"
  (cd "${hft_repo}" && rsync -rlt --delete --relative "$@" "${stage}/src/")
}

# Cancelling a job kills only the WSL side of cmd.exe; the Windows processes
# it started keep running. Stop every Windows process whose command line
# mentions the staging directory.
hft_stop_stage_processes() {
  local stage
  stage="$(hft_win_path "$1")"
  (cd /mnt/c && "${hft_powershell}" -NoProfile -NonInteractive -Command "
    Get-CimInstance Win32_Process |
      Where-Object { \$_.ProcessId -ne \$PID -and \$_.CommandLine -and
        \$_.CommandLine.Contains('${stage}') } |
      ForEach-Object { Stop-Process -Id \$_.ProcessId -Force -ErrorAction SilentlyContinue }
  ") >/dev/null 2>&1 || true
}

hft_tool() {
  local tool="${HFT_VIVADO_ROOT}/bin/$1.bat"
  [ -f "${tool}" ] || hft_die "Vivado tool '$1' was not found at '${tool}'"
  echo "${tool}"
}

hft_restore_interop
