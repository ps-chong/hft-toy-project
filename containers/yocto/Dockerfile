FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      bc bison build-essential chrpath cpio curl debianutils diffstat \
      file flex gawk gcc git iputils-ping libacl1 liblz4-tool locales \
      python3 python3-git python3-jinja2 python3-pexpect python3-pip \
      python3-subunit socat texinfo unzip wget xz-utils zstd && \
    locale-gen en_US.UTF-8 && \
    rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --uid 1000 builder && \
    python3 -m pip install --break-system-packages --no-cache-dir "kas>=4.7"

ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8
USER builder
WORKDIR /workspace
