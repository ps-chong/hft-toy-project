#!/usr/bin/env bash
# Run the GitHub-hosted workflows locally, inside the same host image the
# Docker Compose demo uses (containers/host/Dockerfile).
#
#   scripts/ci/local.sh [r5|a53|fpga|quality|swupdate|demo|all] ...
#
# The repository is expected on a Linux filesystem (see sync-wsl.sh);
# HFT_CI_REPO overrides the location. Jobs run as root inside the container
# and hand file ownership back afterwards.
set -euo pipefail

repo="${HFT_CI_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
image="${HFT_CI_IMAGE:-hft-host:dev}"
network="hft-ci"
owner="$(id -u):$(id -g)"

log() { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }

ensure_image() {
  if ! docker image inspect "${image}" >/dev/null 2>&1; then
    log "building ${image}"
    docker build -t "${image}" -f "${repo}/containers/host/Dockerfile" "${repo}/containers/host"
  fi
}

in_container() {
  # seccomp=unconfined: ThreadSanitizer re-executes itself with
  # personality(ADDR_NO_RANDOMIZE), which Docker's default profile blocks.
  docker run --rm --network "${network}" --security-opt seccomp=unconfined \
    -e DATABASE_URL="${DATABASE_URL:-}" \
    -e CARGO_TERM_COLOR=always \
    -v "${repo}:/workspace" \
    -v hft-ci-cargo-registry:/root/.cargo/registry \
    -v hft-ci-cargo-git:/root/.cargo/git \
    -w /workspace "${image}" \
    bash -euo pipefail -c "
      git config --global --add safe.directory /workspace
      trap 'chown -R ${owner} /workspace/build /workspace/target /workspace/vunit_out \
        /workspace/coverage-reports /workspace/demo/out /workspace/work \
        /workspace/.mypy_cache /workspace/.ruff_cache /workspace/.pytest_cache \
        /workspace/python/.ruff_cache /workspace/python/.pytest_cache 2>/dev/null || true' EXIT
      $1"
}

job_r5() {
  log "Cortex-R5: sanitized host tests, clang-tidy, TSAN, coverage, cross build"
  in_container '
    cmake --preset host-clang-debug
    cmake --build --preset host-clang-debug
    ctest --preset host-clang-debug
    run-clang-tidy-19 -quiet -p build/host-clang-debug \
      cortex/r5/src/host_demo.cpp cortex/r5/src/host_platform.cpp
    cmake --preset host-clang-tsan
    cmake --build --preset host-clang-tsan
    ctest --preset host-clang-tsan
    cmake --preset host-coverage
    cmake --build --preset host-coverage
    ctest --preset host-coverage
    # Multi-threaded tests trip gcov bug 68080 (negative branch counts).
    mkdir -p coverage-reports
    gcovr --root . build/host-coverage --filter cortex/r5/ --filter tests/cpp/ \
      --exclude build/ --gcov-ignore-parse-errors=negative_hits.warn_once_per_file \
      --print-summary --xml-pretty --output coverage-reports/cpp-coverage.xml
    cmake --preset r5-release
    cmake --build --preset r5-release
    /opt/arm-gnu-toolchain/bin/arm-none-eabi-size build/r5-release/r5/hft_r5_firmware.elf'
}

job_a53() {
  log "Cortex-A53: fmt, clippy, tests with PostgreSQL, loom, aarch64 build"
  docker rm -f hft-ci-postgres >/dev/null 2>&1 || true
  docker run -d --name hft-ci-postgres --network "${network}" \
    -e POSTGRES_DB=hft_test -e POSTGRES_USER=hft -e POSTGRES_PASSWORD=hft-test \
    postgres:17-alpine >/dev/null
  trap 'docker rm -f hft-ci-postgres >/dev/null 2>&1 || true' RETURN
  for _ in $(seq 1 30); do
    docker exec hft-ci-postgres pg_isready -U hft >/dev/null 2>&1 && break
    sleep 1
  done
  DATABASE_URL=postgresql://hft:hft-test@hft-ci-postgres:5432/hft_test in_container '
    cargo fmt --all -- --check
    cargo clippy --workspace --all-targets -- -D warnings
    cargo test --workspace --all-targets
    PGPASSWORD=hft-test psql -h hft-ci-postgres -U hft -d hft_test -v ON_ERROR_STOP=1 \
      -f cortex/a53/storage/migrations/0001_initial.sql >/dev/null
    RUSTFLAGS="--cfg loom" CARGO_TARGET_DIR=target/loom \
      cargo test -p hft-disruptor --release --test loom
    cargo build --workspace --release --target aarch64-unknown-linux-gnu
    if [ "${HFT_CI_DEPENDENCY_POLICY:-0}" = 1 ]; then
      cargo install cargo-audit cargo-deny --locked
      cargo audit
      cargo deny check
    fi'
}

job_fpga() {
  log "FPGA: generated contracts, VSG, VUnit on GHDL and NVC (coverage)"
  in_container '
    python3 protocol/generator/generate.py --check
    vsg -c zynq/ultrascale+/vsg.yaml -f zynq/ultrascale+/rtl/*.vhd zynq/ultrascale+/tb/*.vhd
    VUNIT_SIMULATOR=ghdl python zynq/ultrascale+/sim/run.py -p "$(nproc)" -x fpga-junit.xml
    VUNIT_SIMULATOR=nvc HFT_VHDL_COVERAGE=1 python zynq/ultrascale+/sim/run.py \
      -p "$(nproc)" -x fpga-nvc-junit.xml'
}

job_quality() {
  log "Python and documentation: ruff, mypy, pytest, diagrams"
  in_container '
    export PYTHONPATH=/workspace/python/src
    ruff check python scripts protocol/generator coverage deploy/swupdate "zynq/ultrascale+/sim"
    mypy --config-file python/pyproject.toml python/src/hft_tools
    pytest -q python/tests --cov=hft_tools --cov-branch --cov-report=term-missing \
      -p no:cacheprovider
    python scripts/render_diagrams.py
    git diff --exit-code -- "docs/**/*.mmd" "docs/*/diagrams/*.mmd"
    python scripts/render_diagrams.py --render
    python scripts/render_figures.py
    git diff --exit-code -- docs/figures/latency-histogram.svg docs/figures/ingress-waveform.svg'
}

job_swupdate() {
  log "SWUpdate: deterministic signed contract bundle"
  in_container '
    pytest -q python/tests/test_swupdate_bundle.py -p no:cacheprovider
    workdir=$(mktemp -d)
    printf "rootfs-contract\n" | gzip -n > "${workdir}/rootfs.ext4.gz"
    printf "boot-contract\n" | gzip -n > "${workdir}/boot.vfat.gz"
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=hft-ci-contract/" \
      -keyout "${workdir}/key.pem" -out "${workdir}/cert.pem" 2>/dev/null
    python deploy/swupdate/build_bundle.py --description deploy/swupdate/sw-description \
      --rootfs "${workdir}/rootfs.ext4.gz" --boot "${workdir}/boot.vfat.gz" \
      --key "${workdir}/key.pem" --certificate "${workdir}/cert.pem" \
      --output "${workdir}/hft-contract.swu"
    sha256sum "${workdir}/hft-contract.swu"'
}

job_demo() {
  log "Demo smoke test (Docker Compose)"
  HFT_DEMO_IMAGE="${image}" bash "${repo}/demo/run_demo.sh" --smoke
}

main() {
  docker network inspect "${network}" >/dev/null 2>&1 || docker network create "${network}" >/dev/null
  ensure_image
  local jobs=("$@")
  [ "${#jobs[@]}" -eq 0 ] && jobs=(all)
  [ "${jobs[0]}" = all ] && jobs=(r5 a53 fpga quality swupdate demo)
  for job in "${jobs[@]}"; do
    "job_${job}"
  done
  log "all requested jobs passed: ${jobs[*]}"
}

main "$@"
