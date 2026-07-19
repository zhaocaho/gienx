#!/usr/bin/env bash
#
# 下载 gienx 的 codex 二进制(mac arm / mac intel / windows / linux)，
# 解压后只保留 codex 二进制本身(按平台命名)，丢弃 CHANGELOG/LICENSE/README。
#
# 下载前会设置本地代理。
#
# 用法:
#   ./download-codex-binaries.sh                  # 默认版本 v0.142.4-beta.2
#   ./download-codex-binaries.sh v0.142.4-beta.3  # 指定版本
#   VERSION=v0.142.4-beta.3 OUT_DIR=./out ./download-codex-binaries.sh
#
set -euo pipefail

# ---- 配置(可用环境变量覆盖) ----
REPO="zhaocaho/gienx"
VERSION="${1:-${VERSION:-v0.142.4-beta.2}}"
OUT_DIR="${OUT_DIR:-codex-binaries}"

# ---- 本地代理(按你的要求应用) ----
export https_proxy=http://127.0.0.1:7890
export http_proxy=http://127.0.0.1:7890
export all_proxy=socks5://127.0.0.1:7890

# ---- 平台清单: archive 文件名 | 包内二进制名 | 输出名 ----
PLATFORMS=(
  "codex-cli-aarch64-apple-darwin.tar.xz|codex|codex-darwin-arm64"
  "codex-cli-x86_64-apple-darwin.tar.xz|codex|codex-darwin-x86_64"
  "codex-cli-x86_64-pc-windows-msvc.zip|codex.exe|codex-windows-x86_64.exe"
  "codex-cli-x86_64-unknown-linux-gnu.tar.xz|codex|codex-linux-x86_64"
)

mkdir -p "$OUT_DIR"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "仓库 : $REPO"
echo "版本 : $VERSION"
echo "输出 : $OUT_DIR/  (代理已设置: http/https→127.0.0.1:7890, socks5→127.0.0.1:7890)"
echo

extract_dir() {
  # $1=archive $2=目标目录
  local archive="$1" dest="$2"
  case "$archive" in
    *.tar.xz) tar -xf "$archive" -C "$dest" ;;
    *.zip)
      if command -v unzip >/dev/null 2>&1; then
        unzip -q -o "$archive" -d "$dest"
      else
        python3 -c "import sys,zipfile;zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$archive" "$dest"
      fi
      ;;
    *) echo "不认识的压缩格式: $archive" >&2; return 1 ;;
  esac
}

i=0
for entry in "${PLATFORMS[@]}"; do
  archive="${entry%%|*}"; rest="${entry#*|}"
  bin_name="${rest%%|*}"; out_name="${rest##*|}"
  i=$((i+1))
  url="https://github.com/${REPO}/releases/download/${VERSION}/${archive}"

  echo "[$i/4] $out_name  ←  $archive"
  # 下载
  curl -fL --retry 3 --connect-timeout 30 -o "$WORK/$archive" "$url"

  # 解压到子目录
  ex="$WORK/ex.$i"; mkdir -p "$ex"
  extract_dir "$WORK/$archive" "$ex"

  # 找到二进制(可能在子层)
  found="$(find "$ex" -type f -name "$bin_name" -perm +111 | head -1 || true)"
  if [ -z "$found" ]; then
    # windows 的 .exe 可能没有 +x，用 name 兜底
    found="$(find "$ex" -type f -name "$bin_name" | head -1 || true)"
  fi
  if [ -z "$found" ]; then
    echo "  ✗ 解压后未找到 $bin_name" >&2; exit 1
  fi

  cp "$found" "$OUT_DIR/$out_name"
  chmod +x "$OUT_DIR/$out_name" 2>/dev/null || true
  echo "  ✓ $OUT_DIR/$out_name  ($(du -h "$OUT_DIR/$out_name" | cut -f1))"
  echo
done

echo "完成。4 个二进制已放在: $OUT_DIR/"
ls -lh "$OUT_DIR"
