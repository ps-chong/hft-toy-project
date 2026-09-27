ARG HOST_IMAGE=hft-host:latest
FROM ${HOST_IMAGE}

ARG ARM_GNU_VERSION=13.3.rel1
ARG ARM_GNU_SHA256=95c011cee430e64dd6087c75c800f04b9c49832cc1000127a92a97f9c8d83af4
ARG ARM_GNU_ARCHIVE=arm-gnu-toolchain-${ARM_GNU_VERSION}-x86_64-arm-none-eabi.tar.xz

RUN curl --fail --location --retry 3 \
      "https://armkeil.blob.core.windows.net/developer/Files/downloads/gnu/${ARM_GNU_VERSION}/binrel/${ARM_GNU_ARCHIVE}" \
      --output "/tmp/${ARM_GNU_ARCHIVE}" && \
    echo "${ARM_GNU_SHA256}  /tmp/${ARM_GNU_ARCHIVE}" | sha256sum --check - && \
    tar -C /opt -xf "/tmp/${ARM_GNU_ARCHIVE}" && \
    mv "/opt/arm-gnu-toolchain-${ARM_GNU_VERSION}-x86_64-arm-none-eabi" \
      /opt/arm-gnu-toolchain && \
    rm "/tmp/${ARM_GNU_ARCHIVE}"

ENV ARM_GNU_TOOLCHAIN_ROOT=/opt/arm-gnu-toolchain
ENV PATH="/opt/arm-gnu-toolchain/bin:${PATH}"
