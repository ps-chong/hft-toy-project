# Reproducible host image for every GitHub-hosted workflow mirror
# (scripts/ci/local.sh) and for the Docker Compose demo (containers/compose.yml).
FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
ARG CMAKE_VERSION=4.4.3
ARG RUST_VERSION=1.97.1
ARG NVC_VERSION=1.23.0
ARG ARM_GNU_VERSION=13.3.rel1
ARG ARM_GNU_SHA256=95c011cee430e64dd6087c75c800f04b9c49832cc1000127a92a97f9c8d83af4
ARG MERMAID_CLI_VERSION=11.12.0

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates clang-19 clang-tidy-19 clang-tools-19 curl g++-14 \
      gcc-aarch64-linux-gnu libc6-dev-arm64-cross gcovr ghdl git lcov libclang-rt-19-dev \
      ninja-build openssl postgresql-client python3 python3-pip python3-venv \
      rsync xz-utils zstd \
      nodejs npm \
      libasound2t64 libatk-bridge2.0-0 libatk1.0-0 libcairo2 libcups2t64 \
      libdbus-1-3 libdrm2 libexpat1 libgbm1 libglib2.0-0t64 libnspr4 libnss3 \
      libpango-1.0-0 libx11-6 libxcb1 libxcomposite1 libxdamage1 libxext6 \
      libxfixes3 libxkbcommon0 libxrandr2 && \
    update-alternatives --install /usr/bin/clang clang /usr/bin/clang-19 100 && \
    update-alternatives --install /usr/bin/clang++ clang++ /usr/bin/clang++-19 100 && \
    update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-14 100 && \
    update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-14 100 && \
    update-alternatives --install /usr/bin/gcov gcov /usr/bin/gcov-14 100 && \
    rm -rf /var/lib/apt/lists/*

# NVC is pinned to the same upstream package the FPGA workflow installs.
RUN curl --fail --location --retry 3 -o /tmp/nvc.deb \
      "https://github.com/nickg/nvc/releases/download/r${NVC_VERSION}/nvc_${NVC_VERSION}-1_amd64_ubuntu-24.04.deb" && \
    apt-get update && apt-get install -y --no-install-recommends /tmp/nvc.deb && \
    rm -rf /tmp/nvc.deb /var/lib/apt/lists/*

# The R5 cross lane uses the checksum-verified Arm GNU release from r5.yml.
RUN archive="arm-gnu-toolchain-${ARM_GNU_VERSION}-x86_64-arm-none-eabi.tar.xz" && \
    curl --fail --location --retry 3 \
      "https://armkeil.blob.core.windows.net/developer/Files/downloads/gnu/${ARM_GNU_VERSION}/binrel/${archive}" \
      --output "/tmp/${archive}" && \
    echo "${ARM_GNU_SHA256}  /tmp/${archive}" | sha256sum --check - && \
    tar -C /opt -xf "/tmp/${archive}" && \
    mv "/opt/arm-gnu-toolchain-${ARM_GNU_VERSION}-x86_64-arm-none-eabi" /opt/arm-gnu-toolchain && \
    rm "/tmp/${archive}"

RUN npm install --global "@mermaid-js/mermaid-cli@${MERMAID_CLI_VERSION}" && \
    npm cache clean --force

RUN python3 -m venv /opt/hft-python && \
    /opt/hft-python/bin/pip install --no-cache-dir \
      "cmake==${CMAKE_VERSION}" \
      "coverage>=7.10" "hypothesis>=6.138" "mypy>=1.18" \
      "pytest>=8.4" "pytest-cov>=6.2" "ruff>=0.13" \
      "rich>=14.0" "textual>=5.0" "wavedrom==2.0.3.post3" \
      "vsg>=3.35" "vunit_hdl>=4.7"

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
      sh -s -- -y --profile minimal --default-toolchain "${RUST_VERSION}" && \
    /root/.cargo/bin/rustup component add clippy llvm-tools-preview rustfmt && \
    /root/.cargo/bin/rustup target add aarch64-unknown-linux-gnu

ENV PATH="/opt/hft-python/bin:/root/.cargo/bin:${PATH}"
ENV ARM_GNU_TOOLCHAIN_ROOT=/opt/arm-gnu-toolchain
ENV CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=aarch64-linux-gnu-gcc
WORKDIR /workspace
