#!/bin/bash
# 更新 workspace 中所有 Cargo.toml 的版本号
# 用法: ./update-version.sh <version>
# 示例: ./update-version.sh 0.0.1

set -e

if [ -z "$1" ]; then
    echo "错误: 请提供版本号"
    echo "用法: $0 <version>"
    echo "示例: $0 0.0.1"
    exit 1
fi

NEW_VERSION="$1"

echo "正在更新所有 Cargo.toml 的版本号为: $NEW_VERSION"

# 查找所有 Cargo.toml 文件
find codex-rs -name "Cargo.toml" -type f | while read -r file; do
    # 检查文件是否包含 version 字段
    if grep -q "^version = " "$file"; then
        # 使用 sed 更新版本号
        sed -i.bak "s/^version = \".*\"/version = \"$NEW_VERSION\"/" "$file"
        rm -f "$file.bak"
        echo "✓ 已更新: $file"
    fi
done

echo ""
echo "版本更新完成！"
echo "当前版本: $NEW_VERSION"
echo ""
echo "下一步操作:"
echo "1. git add -A"
echo "2. git commit -m \"chore: bump version to $NEW_VERSION\""
echo "3. git tag -a v$NEW_VERSION -m \"Release v$NEW_VERSION\""
echo "4. git push origin HEAD --tags"
