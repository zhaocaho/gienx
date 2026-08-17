# Debian 11 (glibc 2.31) aarch64 build image for Kylin V10 SP1.
#
# Docker Hub is often unreachable from mainland networks. Override the base:
#   docker buildx build --platform linux/arm64 \
#     --build-arg BASE_IMAGE=docker.m.daocloud.io/library/debian:11 \
#     -f gienx/packaging/kylin-aarch64.Dockerfile -t gienx-kylin-aarch64 --load .
#
# Or run gienx/scripts/docker-build-kylin-aarch64.sh (uses the DaoCloud mirror).
ARG BASE_IMAGE=debian:11
FROM ${BASE_IMAGE}

ARG DEBIAN_MIRROR=
ARG RUSTUP_DIST_SERVER=https://mirrors.ustc.edu.cn/rust-static
ARG RUSTUP_UPDATE_ROOT=https://mirrors.ustc.edu.cn/rust-static/rustup

ENV DEBIAN_FRONTEND=noninteractive \
    RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    CARGO_TERM_COLOR=always \
    RUSTUP_DIST_SERVER=${RUSTUP_DIST_SERVER} \
    RUSTUP_UPDATE_ROOT=${RUSTUP_UPDATE_ROOT}

RUN if [ -n "${DEBIAN_MIRROR}" ]; then \
      printf '%s\n' \
        "deb ${DEBIAN_MIRROR} bullseye main" \
        "deb ${DEBIAN_MIRROR} bullseye-updates main" \
        "deb ${DEBIAN_MIRROR}-security bullseye-security main" \
        > /etc/apt/sources.list; \
    fi \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        binutils \
        build-essential \
        ca-certificates \
        curl \
        file \
        git \
        gzip \
        libcap-dev \
        libssl-dev \
        pkg-config \
        python3 \
        xz-utils \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /usr/local/cargo \
    && printf '%s\n' \
      '[source.crates-io]' \
      'replace-with = "ustc"' \
      '[source.ustc]' \
      'registry = "sparse+https://mirrors.ustc.edu.cn/crates.io-index/"' \
      > /usr/local/cargo/config.toml \
    && curl --proto '=https' --tlsv1.2 -sSf https://mirrors.ustc.edu.cn/rust-static/rustup/rustup-init.sh \
      -o /tmp/rustup-init.sh \
    && sh /tmp/rustup-init.sh -y --default-toolchain 1.95.0 --profile minimal \
    && rustup target add aarch64-unknown-linux-gnu \
    && rm -f /tmp/rustup-init.sh

WORKDIR /src
# The build script lives in the mounted repo.
CMD ["./gienx/scripts/build-kylin-aarch64-package.sh"]
