FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
ARG CMAKE_VERSION=4.4.3
ARG RUST_VERSION=1.97.1

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates clang-18 clang-tidy-18 clang-tools-18 curl g++-14 \
      gcovr ghdl git lcov libclang-rt-18-dev ninja-build \
      python3 python3-pip python3-venv && \
    rm -rf /var/lib/apt/lists/*

RUN python3 -m venv /opt/hft-python && \
    /opt/hft-python/bin/pip install --no-cache-dir \
      "cmake==${CMAKE_VERSION}" \
      "coverage>=7.10" "hypothesis>=6.138" "mypy>=1.18" \
      "pytest>=8.4" "pytest-cov>=6.2" "ruff>=0.13" \
      "vsg>=3.35" "vunit_hdl>=4.7"

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
      sh -s -- -y --profile minimal --default-toolchain "${RUST_VERSION}" && \
    /root/.cargo/bin/rustup component add clippy llvm-tools-preview rustfmt && \
    /root/.cargo/bin/rustup target add aarch64-unknown-linux-gnu

ENV PATH="/opt/hft-python/bin:/root/.cargo/bin:${PATH}"
WORKDIR /workspace
