#!/usr/bin/env bash
# Polls every GitHub Actions run for one commit until all have finished,
# prints a summary, and saves the failed-step logs of failed runs.
#
#   scripts/linux/poll-ci.sh [--sha <commit>] [--interval 30] [--timeout 90]
#                            [--log-dir build/ci-logs] [--gh gh]
#
# Exits 0 when every run concluded success or skipped, 1 otherwise. Any gh
# account with read access to the repository is enough (Windows gh.exe works
# too).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
repository="ps-chong/hft-toy-project"
sha=""
interval=30
timeout_minutes=90
log_dir="${repo_root}/build/ci-logs"
gh=gh
while [ $# -gt 0 ]; do
  case "$1" in
    --sha) sha="$2"; shift 2 ;;
    --repository) repository="$2"; shift 2 ;;
    --interval) interval="$2"; shift 2 ;;
    --timeout) timeout_minutes="$2"; shift 2 ;;
    --log-dir) log_dir="$2"; shift 2 ;;
    --gh) gh="$2"; shift 2 ;;
    *) echo "error: unknown argument '$1'" >&2; exit 1 ;;
  esac
done
[ -n "${sha}" ] || sha="$(git -C "${repo_root}" rev-parse HEAD)"
deadline=$(( $(date +%s) + timeout_minutes * 60 ))

# One tab-separated line per run: id, workflow, status, conclusion, event, url.
list_runs() {
  "${gh}" run list --repo "${repository}" --commit "${sha}" --limit 50 \
    --json databaseId,workflowName,status,conclusion,event,url \
    --jq 'sort_by(.workflowName)[]
      | [.databaseId, .workflowName, .status, .conclusion, .event, .url] | @tsv' | tr -d '\r'
}

echo "Waiting for workflow runs of ${sha} in ${repository}."
while true; do
  runs="$(list_runs)"
  total="$(grep -c . <<<"${runs}" || true)"
  pending="$(awk -F'\t' '$3 != "completed"' <<<"${runs}" | grep -c . || true)"
  echo "$(date +%H:%M:%S) ${total} run(s), $((total - pending)) finished, ${pending} pending"
  if [ "${total}" -gt 0 ] && [ "${pending}" -eq 0 ]; then
    break
  fi
  if [ "$(date +%s)" -gt "${deadline}" ]; then
    echo "error: timed out after ${timeout_minutes} minutes with ${pending} run(s) pending" >&2
    exit 1
  fi
  sleep "${interval}"
done

awk -F'\t' -v OFS='\t' '{ print $2, $5, $4, $6 }' <<<"${runs}" | column -t -s $'\t'

failed="$(awk -F'\t' -v OFS='\t' '$4 != "success" && $4 != "skipped" { print $1, $2 }' \
  <<<"${runs}")"
if [ -z "${failed}" ]; then
  echo "All runs passed."
  exit 0
fi

mkdir -p "${log_dir}"
while IFS=$'\t' read -r id name; do
  file="${log_dir}/${id}-$(tr -cs 'A-Za-z0-9' '-' <<<"${name}" | sed 's/-$//').log"
  "${gh}" run view "${id}" --repo "${repository}" --log-failed >"${file}" 2>&1 || true
  echo "Failed: ${name} -> ${file}"
done <<<"${failed}"
exit 1
