#!/usr/bin/env bash
#
# 下载 gienx 的 codex 二进制(mac arm / mac intel / windows / linux)，
# 解压后只保留 codex 二进制本身(保持原名 codex / codex.exe)，
# 按平台分到各自子目录里，丢弃 CHANGELOG/LICENSE/README。
#
# 默认下载最新的 release；若仓库只有预发布版本(无正式 release)，
# 则回退到 releases 列表的第一个(最新预发布)。
#
# 下载前会设置本地代理。
#
# 用法:
#   ./download-codex-binaries.sh                  # 最新 release
#   ./download-codex-binaries.sh v0.142.4-beta.3  # 指定版本
#   VERSION=v0.142.4-beta.3 OUT_DIR=./out ./download-codex-binaries.sh
#
set -euo pipefail

# ---- 配置(可用环境变量覆盖) ----
REPO="zhaocaho/gienx"
VERSION="${1:-${VERSION:-}}"
OUT_DIR="${OUT_DIR:-gienx-binaries}"

# ---- 本地代理(按你的要求应用) ----
export https_proxy=http://127.0.0.1:7890
export http_proxy=http://127.0.0.1:7890
export all_proxy=socks5://127.0.0.1:7890

# ---- 解析最新版本 ----
# 顺序: gh CLI(已认证) → /releases/latest 重定向(不走 API) → API(兜底,带 UA)
resolve_latest_version() {
  local tag
  # 1) gh CLI(若已 gh auth login，不受未认证限流影响)
  if command -v gh >/dev/null 2>&1; then
    if tag="$(gh release list -R "${REPO}" -L 1 --json tagName -q '.[0].tagName' 2>/dev/null)" \
       && [ -n "$tag" ]; then
      echo "$tag"; return 0
    fi
  fi
  # 2) /releases/latest 重定向: 最终 URL 形如 .../releases/tag/<tag>，不走 API
  if tag="$(curl -fsSL --retry 3 --connect-timeout 30 -o /dev/null \
        -w '%{url_effective}' "https://github.com/${REPO}/releases/latest" 2>/dev/null)" \
     && [[ "$tag" == *releases/tag/* ]]; then
    tag="${tag##*releases/tag/}"; tag="${tag%%\?*}"
    echo "$tag"; return 0
  fi
  # 3) API 兜底(带 User-Agent；失败时打印响应体帮助诊断)
  local body
  body="$(curl -sSL --retry 3 --connect-timeout 30 \
        -H 'User-Agent: gienx-download-script' \
        https://api.github.com/repos/${REPO}/releases 2>/dev/null || true)"
  tag="$(printf '%s' "$body" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d[0]["tag_name"] if isinstance(d,list) and d else "")' 2>/dev/null || true)"
  if [ -n "$tag" ]; then echo "$tag"; return 0; fi
  echo "  (API 响应体: $(printf '%s' "$body" | head -c 200))" >&2
  return 1
}

if [ -z "$VERSION" ]; then
  echo "未指定版本，正在获取最新 release ..."
  if ! VERSION="$(resolve_latest_version)"; then
    echo "✗ 无法获取最新版本，请显式传入版本号，例如: $0 v0.142.4-beta.2" >&2
    exit 1
  fi
  echo "→ 最新版本: $VERSION"
fi

# ---- 平台清单: archive 文件名 | 包内二进制名 | 平台目录名 ----
PLATFORMS=(
  "codex-cli-aarch64-apple-darwin.tar.xz|codex|darwin-arm64"
  "codex-cli-x86_64-apple-darwin.tar.xz|codex|darwin-x86_64"
  "codex-cli-x86_64-pc-windows-msvc.zip|codex.exe|windows-x86_64"
  "codex-cli-x86_64-unknown-linux-gnu.tar.xz|codex|linux-x86_64"
)

mkdir -p "$OUT_DIR"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "仓库 : $REPO"
echo "版本 : $VERSION"
echo "输出 : $OUT_DIR/<平台>/  (代理已设置: http/https→127.0.0.1:7890, socks5→127.0.0.1:7890)"
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
  bin_name="${rest%%|*}"; plat_dir="${rest##*|}"
  i=$((i+1))
  url="https://github.com/${REPO}/releases/download/${VERSION}/${archive}"

  echo "[$i/4] $plat_dir/$bin_name  ←  $archive"
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

  # 按平台分目录，保持原二进制名
  mkdir -p "$OUT_DIR/$plat_dir"
  cp "$found" "$OUT_DIR/$plat_dir/$bin_name"
  chmod +x "$OUT_DIR/$plat_dir/$bin_name" 2>/dev/null || true
  echo "  ✓ $OUT_DIR/$plat_dir/$bin_name  ($(du -h "$OUT_DIR/$plat_dir/$bin_name" | cut -f1))"
  echo
done

echo "完成。4 个二进制已放在: $OUT_DIR/"
ls -lhR "$OUT_DIR"
