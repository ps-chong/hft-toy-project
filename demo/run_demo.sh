#!/usr/bin/env bash
# End-to-end demo of the HFT toy system on one Linux host (or WSL).
#
#   exchange --MoldUDP64--> PL model --events--> R5 firmware --RPMsg--> hftd --OUCH--> exchange
#
# Every box runs the project's own code: the Python exchange simulator, the
# Rust software model of the PL ingress (hft-plsim), the real R5 firmware
# core on a host platform adapter (hft_r5_sim), and the A53 daemon (hftd)
# with PostgreSQL. The narrative walks through fail-closed start-up, arming,
# a feed gap that the R5 latches as a kill, re-arming, and an operator kill.
# Afterwards the captured feed is replayed through the VHDL ingress and the
# RTL output is compared byte for byte with the software model's.
#
# Usage: demo/run_demo.sh [--smoke]
#   --smoke   shorter dwell times; every narrative claim is asserted and the
#             script exits non-zero if one does not hold (used by CI).
# Outputs land in demo/out/ (capture, events, replay summary, latency report).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="${root}/demo/out"
smoke=0
[[ "${1:-}" == "--smoke" ]] && smoke=1
dwell=$((smoke ? 3 : 6))

compose=(docker compose -f "${root}/containers/compose.yml" -p hft-demo --profile demo)
owner="$(id -u):$(id -g)"
failures=0

bold=$'\e[1m'
dim=$'\e[2m'
green=$'\e[32m'
red=$'\e[31m'
reset=$'\e[0m'

step() { printf '\n%s== %s%s\n' "${bold}" "$*" "${reset}"; }
note() { printf '%s   %s%s\n' "${dim}" "$*" "${reset}"; }

# expect DESCRIPTION CONDITION...: report, and count failures for --smoke.
expect() {
  local description="$1"
  shift
  if "$@"; then
    printf '   %sok%s   %s\n' "${green}" "${reset}" "${description}"
  else
    printf '   %sFAIL%s %s\n' "${red}" "${reset}" "${description}"
    failures=$((failures + 1))
  fi
}

cleanup() {
  "${compose[@]}" down --volumes --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Runs a shell command in the host image with the repository mounted
# read-write, then hands created files back to the invoking user.
in_host() {
  docker run --rm -v "${root}:/workspace" \
    -v hft-ci-cargo-registry:/root/.cargo/registry -v hft-ci-cargo-git:/root/.cargo/git \
    -e HFT_REPLAY_CAPTURE -e HFT_REPLAY_EXPECTED -e HFT_REPLAY_OUTPUT \
    -w /workspace hft-host:dev bash -c "$1"'; status=$?
      chown -R '"${owner}"' build target demo/out vunit_out 2>/dev/null; exit $status'
}

ctl() { "${compose[@]}" exec -T hftd target/release/hftctl --socket /run/hft/control.sock "$@"; }

# field JSON_PATH: reads one value from a JSON document on stdin.
field() { python3 -c "import json,sys; v=json.load(sys.stdin); print(eval('v'+sys.argv[1]))" "$1"; }

counter() { ctl counters | field "['counters']['$1']"; }

# Latest r5_stats line printed by the R5 model.
r5_stat() {
  "${compose[@]}" logs --no-log-prefix r5sim 2>/dev/null | grep '"r5_stats"' | tail -n 1 |
    field "['$1']"
}

gt() { [[ "$1" -gt "$2" ]]; }
eq() { [[ "$1" -eq "$2" ]]; }

step "1/8 Build the host image and the demo binaries"
docker image inspect hft-host:dev >/dev/null 2>&1 ||
  docker build -t hft-host:dev -f "${root}/containers/host/Dockerfile" "${root}/containers/host"
in_host '
  set -e
  cmake --preset host-release >/dev/null
  cmake --build --preset host-release --target hft_r5_sim
  cargo build --release --locked -p hftd -p hftctl -p hft-plsim
  rm -rf demo/out && mkdir -p demo/out'

step "2/8 Start PostgreSQL, the exchange, the PL model, the R5 firmware and hftd"
"${compose[@]}" up -d
for _ in $(seq 1 60); do
  ctl status >/dev/null 2>&1 && break
  sleep 1
done
ctl status >/dev/null || { "${compose[@]}" logs --tail 40; exit 1; }
note "control socket answering; feed running at one packet every ${HFT_DEMO_INTERVAL:-0.02} s"

step "3/8 Fail-closed start: market data flows, nothing trades"
sleep "${dwell}"
status="$(ctl status)"
note "hftd: armed=$(field "['state']['armed']" <<<"${status}") killed=$(field "['state']['killed']" <<<"${status}")"
note "R5:   events=$(r5_stat events) intents=$(r5_stat intents) kill_reasons=$(r5_stat kill_reasons)"
expect "the R5 receives normalized events" gt "$(r5_stat events)" 0
expect "no order reaches the exchange before arming" eq "$(counter intents_sent)" 0

step "4/8 Arm: risk_config goes to the R5, intents flow, the exchange acknowledges"
ctl arm >/dev/null
sleep "${dwell}"
sent="$(counter intents_sent)"
accepted="$(counter accepted)"
note "intents_sent=${sent} accepted=${accepted} p50=$(counter intent_to_ack_p50_ns) ns p99=$(counter intent_to_ack_p99_ns) ns"
expect "orders are sent after arming" gt "${sent}" 0
expect "the exchange accepts them" gt "${accepted}" 0

step "5/8 Fault: the exchange skips a sequence number (SIGUSR1)"
"${compose[@]}" kill -s SIGUSR1 exchange >/dev/null
sleep 2
before="$(counter intents_received)"
sleep "${dwell}"
after="$(counter intents_received)"
note "the PL model flags the next event feed_gap; the R5 kill switch latches"
note "R5 kill_reasons=$(r5_stat kill_reasons); intents_received ${before} -> ${after}"
expect "the R5 latched a kill" gt "$(r5_stat kill_reasons)" 0
expect "the R5 stops producing intents" eq "${after}" "${before}"

step "6/8 Re-arm: the operator clears the latched fault"
ctl arm >/dev/null
sleep "${dwell}"
resumed="$(counter intents_received)"
note "intents_received ${after} -> ${resumed}"
expect "trading resumes" gt "${resumed}" "${after}"

step "7/8 Operator kill"
ctl kill >/dev/null
sleep 2
stopped="$(counter intents_sent)"
sleep "${dwell}"
note "intents_sent ${stopped} -> $(counter intents_sent); blocked=$(counter intents_blocked)"
expect "nothing is sent after the kill" eq "$(counter intents_sent)" "${stopped}"
journal="$("${compose[@]}" exec -T postgres psql -U hft -d hft -tAc 'select count(*) from order_events' 2>/dev/null || echo 0)"
note "order_events journaled in PostgreSQL: ${journal}"
"${compose[@]}" stop >/dev/null

step "8/8 Replay the captured feed through the VHDL ingress and compare"
expect "the PL model captured the feed" test -s "${out}/capture.bin"
export HFT_REPLAY_CAPTURE=/workspace/demo/out/capture.bin
export HFT_REPLAY_EXPECTED=/workspace/demo/out/model_events.bin
export HFT_REPLAY_OUTPUT=/workspace/demo/out/rtl_events.bin
replay_ok=0
in_host 'set -o pipefail; VUNIT_SIMULATOR=ghdl python3 zynq/ultrascale+/sim/run.py \
  --output-path vunit_out/demo --no-color "hft.tb_replay.*" | tail -n 3' && replay_ok=1
expect "tb_replay: RTL events equal the software model's" eq "${replay_ok}" 1
PYTHONPATH="${root}/python/src" python3 -m hft_tools.replay_compare \
  "${out}/model_events.bin" "${out}/rtl_events.bin" >"${out}/replay_summary.json" || true
note "$(python3 -c "import json; s=json.load(open('${out}/replay_summary.json')); \
print(f\"{s['model_events']} events, kinds {s['kinds']}, feed_gap flags {s['feed_gap_flags']}, match={s['match']}\")")"
in_host 'PYTHONPATH=python/src python3 -m hft_tools.latency_report demo/out/r5_latency.jsonl \
  --output demo/out/latency' >/dev/null 2>&1 &&
  note "latency report: demo/out/latency.html"

if ((failures > 0)); then
  printf '\n%s%d check(s) failed%s\n' "${red}" "${failures}" "${reset}"
  exit 1
fi
printf '\n%sDemo complete.%s Outputs in demo/out/\n' "${green}" "${reset}"
