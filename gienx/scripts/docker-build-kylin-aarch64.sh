#!/usr/bin/env bash
#
# Build the Kylin aarch64 image and compile the package on Apple Silicon.
# Defaults to a Docker Hub *mirror* because registry-1.docker.io often times out
# from mainland networks (the error you just hit).
#
# Usage (from repo root):
#   ./gienx/scripts/docker-build-kylin-aarch64.sh
#
# Override the base image if one mirror is down:
#   BASE_IMAGE=docker.1ms.run/library/debian:11 ./gienx/scripts/docker-build-kylin-aarch64.sh
#
# If you already have a working HTTP proxy (Clash etc. on 7890):
#   Docker Desktop → Settings → Resources → Proxies → enable, or:
#   export HTTPS_PROXY=http://127.0.0.1:7890 HTTP_PROXY=http://127.0.0.1:7890
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT}"

BASE_IMAGE="${BASE_IMAGE:-docker.m.daocloud.io/library/debian:11}"
DEBIAN_MIRROR="${DEBIAN_MIRROR:-http://mirrors.ustc.edu.cn/debian}"
IMAGE_TAG="${IMAGE_TAG:-gienx-kylin-aarch64}"
SKIP_RUN="${SKIP_RUN:-0}"
CARGO_REGISTRY_VOLUME="${CARGO_REGISTRY_VOLUME:-gienx-kylin-cargo-registry}"
CARGO_GIT_VOLUME="${CARGO_GIT_VOLUME:-gienx-kylin-cargo-git}"

echo "base image : ${BASE_IMAGE}"
echo "apt mirror : ${DEBIAN_MIRROR}"
echo

docker buildx build \
  --platform linux/arm64 \
  --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
  --build-arg "DEBIAN_MIRROR=${DEBIAN_MIRROR}" \
  -f gienx/packaging/kylin-aarch64.Dockerfile \
  -t "${IMAGE_TAG}" \
  --load \
  .

if [[ "${SKIP_RUN}" == "1" ]]; then
  echo "image built; skip compile (SKIP_RUN=1)"
  exit 0
fi

mkdir -p "${ROOT}/dist"

# Cargo still fetches unused workspace git deps (livekit → libyuv on
# chromium.googlesource.com). Inside the container 127.0.0.1 is not the Mac
# proxy; Docker Desktop exposes it as host.docker.internal.
PROXY="${HTTPS_PROXY:-${https_proxy:-${HTTP_PROXY:-${http_proxy:-}}}}"
if [[ -z "${PROXY}" ]] && (echo >/dev/tcp/127.0.0.1/7890) >/dev/null 2>&1; then
  PROXY="http://host.docker.internal:7890"
fi
if [[ -n "${PROXY}" ]]; then
  # 本机 127.0.0.1:7890 在容器里要改成 host.docker.internal
  PROXY="${PROXY//127.0.0.1/host.docker.internal}"
  PROXY="${PROXY//localhost/host.docker.internal}"
  echo "proxy    : ${PROXY}"
fi

docker_proxy_args=()
if [[ -n "${PROXY}" ]]; then
  docker_proxy_args+=(
    -e "http_proxy=${PROXY}"
    -e "https_proxy=${PROXY}"
    -e "HTTP_PROXY=${PROXY}"
    -e "HTTPS_PROXY=${PROXY}"
    -e "ALL_PROXY=${PROXY}"
    -e "all_proxy=${PROXY}"
  )
fi

# Keep Cargo downloads across --rm containers. The source tree mount already
# preserves codex-rs/target, while these volumes preserve registry/git sources.
docker volume create "${CARGO_REGISTRY_VOLUME}" >/dev/null
docker volume create "${CARGO_GIT_VOLUME}" >/dev/null

docker run --rm --platform linux/arm64 \
  -v "${ROOT}:/src" \
  -v "${CARGO_REGISTRY_VOLUME}:/usr/local/cargo/registry" \
  -v "${CARGO_GIT_VOLUME}:/usr/local/cargo/git" \
  -w /src \
  -e OUT_DIR=/src/dist \
  "${docker_proxy_args[@]}" \
  "${IMAGE_TAG}"
