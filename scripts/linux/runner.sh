#!/usr/bin/env bash
# On-demand self-hosted GitHub Actions runner for the Vivado workflow, in WSL.
#
#   scripts/linux/runner.sh install [--token <registration token>] [--gh <gh>]
#   scripts/linux/runner.sh start | stop | status
#   scripts/linux/runner.sh remove [--token <removal token>] [--gh <gh>]
#
# The runner lives under ~/ghr (work directory ~/ghr/w), runs as the current
# user, and only while started: start launches it in the background for a CI
# cycle, stop ends it. It carries the labels self-hosted, Linux, X64, vivado
# and xczu5ev, which only .github/workflows/vivado.yml requests; that workflow
# never runs for pull requests. Jobs drive the Windows Vivado through WSL
# interop (common.sh), and the runner ends when WSL shuts down, so keep a WSL
# session open while it should be online.
#
# A token comes from --token, or from the GitHub CLI when its token may
# administer the repository (fine-grained PAT: Administration read/write).
# When WSL's gh is another account, point --gh at the Windows gh.exe. The
# runner's .env carries HFT_VIVADO_ROOT and HFT_VIVADO_LICENSE (a BASIC-tier
# license directory; split-vivado-license.py).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

repository="${HFT_RUNNER_REPOSITORY:-ps-chong/hft-toy-project}"
root="${HFT_RUNNER_ROOT:-${HOME}/ghr}"
name="$(hostname)-vivado"
labels="vivado,xczu5ev"
pid_file="${root}/runner.pid"
log_file="${root}/runner.log"

[ $# -gt 0 ] || hft_die "usage: runner.sh install|start|stop|status|remove [--token T] [--gh GH]"
action="$1"
shift
token=""
gh=gh
while [ $# -gt 0 ]; do
  case "$1" in
    --token) token="$2"; shift 2 ;;
    --gh) gh="$2"; shift 2 ;;
    --name) name="$2"; shift 2 ;;
    *) hft_die "unknown argument '$1'" ;;
  esac
done

runner_token() {
  if [ -n "${token}" ]; then
    echo "${token}"
    return
  fi
  local value
  value="$("${gh}" api -X POST "repos/${repository}/actions/runners/$1-token" --jq .token \
    2>/dev/null | tr -d '\r')" || true
  [ -n "${value}" ] || hft_die "cannot create a runner $1 token with '${gh}' (it needs" \
    "Administration read/write on ${repository}); pass --token from" \
    "Settings > Actions > Runners > New self-hosted runner"
  echo "${value}"
}

runner_pid() {
  [ -f "${pid_file}" ] || return 1
  local pid
  pid="$(cat "${pid_file}")"
  kill -0 "${pid}" 2>/dev/null && echo "${pid}"
}

install_runner() {
  mkdir -p "${root}/w"
  if [ ! -x "${root}/config.sh" ]; then
    local release
    release="$("${gh}" api repos/actions/runner/releases/latest | tr -d '\r')"
    # The release notes list each package's SHA-256 between markers.
    read -r tag url expected < <(python3 -c '
import json, re, sys
release = json.load(sys.stdin)
assets = [a for a in release["assets"]
          if re.fullmatch(r"actions-runner-linux-x64-[0-9.]+\.tar\.gz", a["name"])]
sha = re.search(r"<!-- BEGIN SHA linux-x64 -->([0-9a-f]{64})<!-- END SHA linux-x64 -->",
                release["body"])
if not assets or not sha:
    sys.exit("actions/runner " + release["tag_name"] + " has no linux-x64 package or checksum")
print(release["tag_name"], assets[0]["browser_download_url"], sha.group(1))
' <<<"${release}")
    local archive
    archive="$(mktemp --suffix=.tar.gz)"
    curl -fsSL -o "${archive}" "${url}"
    local actual
    actual="$(sha256sum "${archive}" | cut -d' ' -f1)"
    if [ "${actual}" != "${expected}" ]; then
      rm -f "${archive}"
      hft_die "checksum mismatch for ${url}: ${actual}, expected ${expected}"
    fi
    tar -xzf "${archive}" -C "${root}"
    rm -f "${archive}"
    echo "Unpacked actions/runner ${tag} into ${root}."
  fi

  local license="${HFT_VIVADO_LICENSE:-$(hft_appdata)/XilinxLicense-BASIC}"
  printf '%s\n' "HFT_VIVADO_ROOT=${HFT_VIVADO_ROOT}" "HFT_VIVADO_LICENSE=${license}" \
    >"${root}/.env"

  local registration
  registration="$(runner_token registration)"
  (cd "${root}" && ./config.sh --unattended --replace \
    --url "https://github.com/${repository}" --token "${registration}" \
    --name "${name}" --labels "${labels}" --work w)
  echo "Registered runner '${name}' with labels self-hosted, Linux, X64, ${labels}."
}

start_runner() {
  if runner_pid >/dev/null; then
    echo "Runner already running."
    return
  fi
  [ -f "${root}/.runner" ] || hft_die "the runner is not registered; run 'runner.sh install' first"
  # A session of its own, so closing the terminal does not end the runner;
  # the process records its own pid, which is then also its process group.
  rm -f "${pid_file}"
  (cd "${root}" && setsid nohup bash -c 'echo $$ >"$1"; exec ./run.sh' _ "${pid_file}" \
    >"${log_file}" 2>&1 </dev/null &)
  for _ in $(seq 1 20); do
    [ -s "${pid_file}" ] && break
    sleep 0.25
  done
  echo "Runner started (pid $(cat "${pid_file}")); log ${log_file}."
}

stop_runner() {
  local pid
  if pid="$(runner_pid)"; then
    # run.sh starts Runner.Listener, which starts Runner.Worker per job; all
    # share run.sh's process group.
    kill -TERM -- "-${pid}" 2>/dev/null || true
    for _ in $(seq 1 20); do
      kill -0 "${pid}" 2>/dev/null || break
      sleep 0.5
    done
    kill -KILL -- "-${pid}" 2>/dev/null || true
  fi
  rm -f "${pid_file}"
  echo "Runner stopped."
}

case "${action}" in
  install) install_runner ;;
  start) start_runner ;;
  stop) stop_runner ;;
  status)
    if pid="$(runner_pid)"; then
      echo "Runner running (pid ${pid})."
    else
      echo "Runner stopped."
    fi
    if [ -f "${root}/.runner" ]; then
      python3 -c 'import json, sys
runner = json.load(open(sys.argv[1], encoding="utf-8-sig"))
print("agentName:", runner["agentName"])
print("gitHubUrl:", runner["gitHubUrl"])' "${root}/.runner"
    else
      echo "Not registered."
    fi
    ;;
  remove)
    stop_runner
    removal="$(runner_token remove)"
    (cd "${root}" && ./config.sh remove --token "${removal}")
    ;;
  *) hft_die "unknown action '${action}'" ;;
esac
