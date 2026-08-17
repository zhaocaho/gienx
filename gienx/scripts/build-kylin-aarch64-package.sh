#!/usr/bin/env bash
#
# Build the Kylin V10 SP1 linux-arm64 package:
#   bin/gienx
#   codex-resources/bwrap
#   codex-path/rg
#   codex-package.json
#
# Must be run on aarch64 Linux with glibc <= 2.31 (Debian 11 / Ubuntu 20.04
# or this script's Docker image). Building on Ubuntu 22.04+ produces a binary
# that will not start on the target machine.
#
# Usage:
#   ./gienx/scripts/build-kylin-aarch64-package.sh
#   OUT_DIR=./dist ./gienx/scripts/build-kylin-aarch64-package.sh
#
set -euo pipefail

TARGET="aarch64-unknown-linux-gnu"
MAX_GLIBC="2.31"
RG_VERSION="${RG_VERSION:-15.1.0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CODEX_RS="${REPO_ROOT}/codex-rs"
CHECK_GLIBC="${SCRIPT_DIR}/check-glibc-max.py"
if [[ -z "${OUT_DIR:-}" ]]; then
  OUT_DIR="${REPO_ROOT}/dist"
fi
mkdir -p "${OUT_DIR}"
OUT_DIR="$(cd "${OUT_DIR}" && pwd)"

version_from_workspace() {
  python3 - <<'PY'
from pathlib import Path
import re
text = Path("codex-rs/Cargo.toml").read_text(encoding="utf-8")
match = re.search(r'(?m)^version\s*=\s*"([^"]+)"', text)
if not match:
    raise SystemExit("workspace.package.version not found in codex-rs/Cargo.toml")
print(match.group(1))
PY
}

require_host() {
  local machine glibc
  machine="$(uname -m)"
  if [[ "${machine}" != "aarch64" ]]; then
    echo "error: host is ${machine}, need aarch64 (use the Debian 11 arm64 container or workflow)." >&2
    exit 1
  fi
  if [[ "$(uname -s)" != "Linux" ]]; then
    echo "error: host is not Linux." >&2
    exit 1
  fi
  glibc="$(ldd --version 2>&1 | head -n1 | grep -oE '[0-9]+\.[0-9]+' | tail -n1 || true)"
  if [[ -z "${glibc}" ]]; then
    echo "error: could not read host glibc version." >&2
    exit 1
  fi
  python3 - "${glibc}" "${MAX_GLIBC}" <<'PY'
import sys
def parse(v):
    return tuple(int(p) for p in v.split("."))
host, max_v = sys.argv[1], sys.argv[2]
if parse(host) > parse(max_v):
    print(
        f"error: host glibc {host} > {max_v}; binaries linked here will not run on Kylin V10 SP1.",
        file=sys.stderr,
    )
    raise SystemExit(1)
print(f"host glibc {host} <= {max_v}")
PY
}

# rusty_v8's Python downloader often saves a truncated/HTML body through a
# proxy, then panics with `Decompression error Err(Buf)`. Fetch with curl,
# require a real gzip, and point the build at that file.
download_rusty_v8() {
  local version="$1"
  local dest_dir="${CODEX_RS}/target/kylin-prebuilt"
  local dest="${dest_dir}/librusty_v8_release_${TARGET}.a.gz"
  local url_path="denoland/rusty_v8/releases/download/v${version}/librusty_v8_release_${TARGET}.a.gz"
  local -a urls=(
    "https://github.com/${url_path}"
    "https://ghfast.top/https://github.com/${url_path}"
    "https://mirror.ghproxy.com/https://github.com/${url_path}"
  )
  mkdir -p "${dest_dir}"
  if [[ -f "${dest}" ]] && gzip -t "${dest}" 2>/dev/null; then
    local sz
    sz="$(wc -c < "${dest}")"
    if [[ "${sz}" -gt 10000000 ]]; then
      echo "reusing rusty_v8 archive (${sz} bytes)"
      export RUSTY_V8_ARCHIVE="${dest}"
      return 0
    fi
  fi
  rm -f "${dest}"
  local url
  for url in "${urls[@]}"; do
    echo "==> download rusty_v8 from ${url}"
    # Debian 11 curl is 7.74: no --min-file-size (needs 8.4+). Check size after.
    if curl -fL --retry 5 --retry-delay 2 --connect-timeout 30 \
      -o "${dest}.tmp" "${url}"; then
      local sz
      sz="$(wc -c < "${dest}.tmp")"
      if [[ "${sz}" -lt 10000000 ]]; then
        echo "too small (${sz} bytes), likely an HTML error page" >&2
      elif gzip -t "${dest}.tmp" 2>/dev/null; then
        mv "${dest}.tmp" "${dest}"
        export RUSTY_V8_ARCHIVE="${dest}"
        echo "rusty_v8 archive ok (${sz} bytes)"
        return 0
      else
        echo "not a gzip (${sz} bytes): $(file "${dest}.tmp" 2>/dev/null || true)" >&2
      fi
    fi
    rm -f "${dest}.tmp"
  done
  echo "error: failed to download a valid rusty_v8 archive for ${TARGET}" >&2
  exit 1
}

cd "${REPO_ROOT}"
require_host

if ! command -v cargo >/dev/null 2>&1; then
  echo "error: cargo not on PATH. Install rustup + 1.95.0 first." >&2
  exit 1
fi
if ! command -v objdump >/dev/null 2>&1; then
  echo "error: objdump not on PATH. Install binutils." >&2
  exit 1
fi
if ! command -v strip >/dev/null 2>&1; then
  echo "error: strip not on PATH. Install binutils." >&2
  exit 1
fi
if ! command -v pkg-config >/dev/null 2>&1 || ! pkg-config --exists libcap; then
  echo "error: libcap not found via pkg-config (need libcap-dev)." >&2
  exit 1
fi

VERSION="$(version_from_workspace)"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/gienx-kylin-XXXXXX")"
trap 'rm -rf "${STAGE}"' EXIT
PKG="${STAGE}/package"
BIN_DIR="${PKG}/bin"
RESOURCES_DIR="${PKG}/codex-resources"
PATH_DIR="${PKG}/codex-path"
mkdir -p "${BIN_DIR}" "${RESOURCES_DIR}" "${PATH_DIR}"

echo "repo    : ${REPO_ROOT}"
echo "version : ${VERSION}"
echo "target  : ${TARGET}"
echo "out     : ${OUT_DIR}"
echo

echo "==> pre-download rusty_v8 (avoid corrupt proxy gzip)"
download_rusty_v8 "149.2.0"
# drop the partial file that panicked last time
rm -f "${CODEX_RS}/target/${TARGET}/release/gn_out/obj/librusty_v8.tmp" \
  "${CODEX_RS}/target/${TARGET}/release/gn_out/obj/librusty_v8.a"

echo "==> cargo build gienx + bwrap"
# Apple Silicon + --platform linux/arm64 goes through QEMU. rustc + thin LTO
# on codex-core gets SIGKILL (OOM). Drop LTO, serialize rustc, more CGUs.
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-1}"
export CARGO_PROFILE_RELEASE_LTO="${CARGO_PROFILE_RELEASE_LTO:-off}"
export CARGO_PROFILE_RELEASE_CODEGEN_UNITS="${CARGO_PROFILE_RELEASE_CODEGEN_UNITS:-16}"
export CARGO_INCREMENTAL="${CARGO_INCREMENTAL:-0}"
echo "cargo jobs=${CARGO_BUILD_JOBS} lto=${CARGO_PROFILE_RELEASE_LTO} cgus=${CARGO_PROFILE_RELEASE_CODEGEN_UNITS}"
(
  cd "${CODEX_RS}"
  cargo build --release --target "${TARGET}" --bin gienx --bin bwrap
)

GIENX_BIN="${CODEX_RS}/target/${TARGET}/release/gienx"
BWRAP_BIN="${CODEX_RS}/target/${TARGET}/release/bwrap"
if [[ ! -x "${GIENX_BIN}" ]]; then
  # native builds without --target land in target/release/
  if [[ -x "${CODEX_RS}/target/release/gienx" ]]; then
    GIENX_BIN="${CODEX_RS}/target/release/gienx"
    BWRAP_BIN="${CODEX_RS}/target/release/bwrap"
  fi
fi
cp "${GIENX_BIN}" "${BIN_DIR}/gienx"
cp "${BWRAP_BIN}" "${RESOURCES_DIR}/bwrap"
chmod 0755 "${BIN_DIR}/gienx" "${RESOURCES_DIR}/bwrap"

echo "==> cargo install ripgrep ${RG_VERSION} (same glibc sysroot)"
RG_ROOT="${STAGE}/rg-prefix"
mkdir -p "${RG_ROOT}"
cargo install --version "${RG_VERSION}" --target "${TARGET}" --root "${RG_ROOT}" ripgrep
cp "${RG_ROOT}/bin/rg" "${PATH_DIR}/rg"
chmod 0755 "${PATH_DIR}/rg"

echo "==> strip packaged binaries"
# Keep Cargo's unstripped build outputs for local diagnostics. Only remove
# symbols/debug sections from the copies that are about to enter the package.
for binary in "${BIN_DIR}/gienx" "${RESOURCES_DIR}/bwrap" "${PATH_DIR}/rg"; do
  before="$(wc -c < "${binary}")"
  strip --strip-all "${binary}"
  after="$(wc -c < "${binary}")"
  echo "stripped $(basename "${binary}"): ${before} -> ${after} bytes"
done

python3 - <<PY
import json
from pathlib import Path
meta = {
    "layoutVersion": 1,
    "version": "${VERSION}",
    "target": "${TARGET}",
    "variant": "gienx",
    "entrypoint": "bin/gienx",
    "resourcesDir": "codex-resources",
    "pathDir": "codex-path",
    "compat": {
        "os": "kylin-desktop-v10-sp1",
        "arch": "aarch64",
        "maxGlibc": "${MAX_GLIBC}",
    },
}
Path("${PKG}/codex-package.json").write_text(json.dumps(meta, indent=2) + "\n", encoding="utf-8")
PY

echo "==> glibc symbol check (max ${MAX_GLIBC})"
python3 "${CHECK_GLIBC}" --max "${MAX_GLIBC}" "${BIN_DIR}/gienx"
python3 "${CHECK_GLIBC}" --max "${MAX_GLIBC}" "${RESOURCES_DIR}/bwrap"
python3 "${CHECK_GLIBC}" --max "${MAX_GLIBC}" "${PATH_DIR}/rg"

if ! "${RESOURCES_DIR}/bwrap" --help 2>&1 | grep -q -- "--perms"; then
  echo "error: bundled bwrap is missing --perms; system 0.4.0 would also be rejected." >&2
  exit 1
fi
echo "bundled bwrap --help includes --perms"

ARCHIVE_STEM="gienx-kylin-v10-${TARGET}"
ARCHIVE="${OUT_DIR}/${ARCHIVE_STEM}.tar.xz"
mkdir -p "${OUT_DIR}"
tar -C "${PKG}" -cJf "${ARCHIVE}" .
(
  cd "${OUT_DIR}"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$(basename "${ARCHIVE}")" > "$(basename "${ARCHIVE}").sha256"
  else
    shasum -a 256 "$(basename "${ARCHIVE}")" > "$(basename "${ARCHIVE}").sha256"
  fi
)

echo
echo "package tree:"
find "${PKG}" -type f -print | sort
echo
echo "built ${ARCHIVE}"
ls -lh "${ARCHIVE}" "${ARCHIVE}.sha256"
echo
echo "Electron: preserve the archive layout and spawn <package-root>/bin/gienx"
echo "so InstallContext can see codex-package.json + codex-resources/ + codex-path/."
