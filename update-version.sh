#!/bin/bash
# 完整的版本发布脚本
# 功能：获取最新版本、询问新版本、更新版本、提交、打标签、推送
# 用法: ./update-version.sh [新版本号]
# 示例:
#   ./update-version.sh           # 交互式选择版本
#   ./update-version.sh 0.1.0-gienx.2  # 直接指定版本

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 打印带颜色的消息
info() { echo -e "${BLUE}ℹ${NC} $1"; }
success() { echo -e "${GREEN}✓${NC} $1"; }
warn() { echo -e "${YELLOW}⚠${NC} $1"; }
error() { echo -e "${RED}✗${NC} $1"; }

# 获取当前分支
get_current_branch() {
    git branch --show-current
}

# 获取最新的 gienx 版本
get_latest_gienx_version() {
    # 获取所有包含 gienx 的标签，按版本号排序，取最新的
    local tag=$(git tag -l "*gienx*" | sort -V | tail -n 1)
    # 移除 'v' 前缀
    echo "${tag#v}"
}

# 解析 semver 版本号
parse_version() {
    local version=$1
    # 移除 'v' 前缀
    version=${version#v}

    # 解析主要部分（MAJOR.MINOR.PATCH）
    if [[ $version =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)(-(.+))?$ ]]; then
        echo "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[5]}"
    else
        error "无法解析版本号: $version"
        exit 1
    fi
}

# 建议下一个版本
suggest_next_versions() {
    local current=$1
    read -r major minor patch prerelease <<< "$(parse_version "$current")"

    echo ""
    info "当前版本: $current"
    echo ""
    echo "建议的版本："
    echo "  1) $major.$minor.$((patch + 1))-gienx.1  (patch 升级)"
    echo "  2) $major.$((minor + 1)).0-gienx.1        (minor 升级)"
    echo "  3) $((major + 1)).0.0-gienx.1             (major 升级)"

    # 如果有预发布标签，提供移除标签的选项
    if [[ -n "$prerelease" ]]; then
        echo "  4) $major.$minor.$patch                 (发布正式版)"
    fi

    echo "  5) 自定义版本"
    echo "  6) 保持当前版本（仅重新打包发布）"
    echo "  0) 取消"
    echo ""
}

# 更新 Cargo.toml 版本
update_version_in_cargo() {
    local new_version=$1
    local cargo_file="codex-rs/Cargo.toml"

    if [[ ! -f "$cargo_file" ]]; then
        error "找不到 $cargo_file"
        exit 1
    fi

    # 使用 awk 精确替换 [workspace.package] 下的 version 字段
    awk -v new_version="$new_version" '
    /^\[workspace\.package\]/ { in_workspace=1 }
    /^\[/ && !/^\[workspace\.package\]/ { in_workspace=0 }
    in_workspace && /^version = "/ {
        print "version = \"" new_version "\""
        next
    }
    { print }
    ' "$cargo_file" > "$cargo_file.tmp" && mv "$cargo_file.tmp" "$cargo_file"

    success "已更新 $cargo_file 的版本为 $new_version"
}

# 检查是否有未提交的更改
check_uncommitted_changes() {
    if [[ -n $(git status --porcelain) ]]; then
        warn "有未提交的更改"
        git status --short
        echo ""
        read -p "是否继续？(y/n) " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            info "已取消"
            exit 0
        fi
    fi
}

# 主函数
main() {
    local new_version=""

    # 如果提供了参数，直接使用
    if [[ $# -gt 0 ]]; then
        new_version=$1
    else
        # 获取最新版本
        local latest_version=$(get_latest_gienx_version)

        if [[ -z "$latest_version" ]]; then
            warn "没有找到包含 'gienx' 的标签"
            latest_version="0.0.0"
            info "将使用 $latest_version 作为基础版本"
        else
            success "找到最新版本: $latest_version"
        fi

        # 显示建议的版本
        suggest_next_versions "$latest_version"

        # 询问用户选择
        read -p "请选择版本 (0-6): " choice

        case $choice in
            1)
                read -r major minor patch prerelease <<< "$(parse_version "$latest_version")"
                new_version="$major.$minor.$((patch + 1))-gienx.1"
                ;;
            2)
                read -r major minor patch prerelease <<< "$(parse_version "$latest_version")"
                new_version="$major.$((minor + 1)).0-gienx.1"
                ;;
            3)
                read -r major minor patch prerelease <<< "$(parse_version "$latest_version")"
                new_version="$((major + 1)).0.0-gienx.1"
                ;;
            4)
                read -r major minor patch prerelease <<< "$(parse_version "$latest_version")"
                if [[ -z "$prerelease" ]]; then
                    error "当前版本已经是正式版"
                    exit 1
                fi
                new_version="$major.$minor.$patch"
                ;;
            5)
                read -p "请输入自定义版本号: " new_version
                ;;
            6)
                new_version="$latest_version"
                info "保持当前版本: $new_version"
                ;;
            0|*)
                info "已取消"
                exit 0
                ;;
        esac
    fi

    # 验证版本号格式
    if [[ ! $new_version =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$ ]]; then
        error "无效的版本号格式: $new_version"
        error "版本号格式应为: MAJOR.MINOR.PATCH[-PRERELEASE]"
        exit 1
    fi

    echo ""
    info "准备发布版本: $new_version"
    echo ""

    # 检查未提交的更改
    check_uncommitted_changes

    # 更新版本
    update_version_in_cargo "$new_version"

    # 提交更改
    echo ""
    info "提交版本更新..."
    git add -A
    git commit -m "chore: bump version to $new_version" || {
        warn "没有需要提交的更改"
    }

    # 删除旧标签（如果存在）
    local tag_name="v$new_version"
    if git tag -l | grep -q "^$tag_name$"; then
        warn "标签 $tag_name 已存在，将删除并重新创建"
        git tag -d "$tag_name"
        git push origin ":refs/tags/$tag_name" 2>/dev/null || true
    fi

    # 创建新标签
    echo ""
    info "创建标签 $tag_name..."
    git tag -a "$tag_name" -m "Release $tag_name"

    # 推送
    echo ""
    read -p "是否立即推送到远程？(y/n) " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        local branch=$(get_current_branch)
        info "推送到远程..."
        git push origin "$branch" --tags
        success "推送完成！"
        echo ""
        success "版本 $new_version 已成功发布！"
        echo ""
        info "查看发布状态:"
        echo "  gh run list --workflow=release.yml --limit 3"
        echo "  或访问: https://github.com/$(git remote get-url origin | sed 's/.*github.com[:/]\(.*\)\.git/\1/')/actions"
    else
        echo ""
        warn "未推送到远程。稍后可以手动推送："
        echo "  git push origin $(get_current_branch) --tags"
    fi
}

# 执行主函数
main "$@"
