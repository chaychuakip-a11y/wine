#!/usr/bin/env bash
# build.sh — 下载原版 wine-staging AppImage，打补丁，重新打包
#
# 用法：
#   bash build.sh              # 在当前目录产出 wine-staging-fixed.AppImage
#   OUTPUT_DIR=/opt bash build.sh
#
# 依赖：wget curl jq (系统包管理器安装即可)
set -euo pipefail

REPO="mmtrt/WINE_AppImage"
TAG="continuous-staging"
OUTPUT_DIR="${OUTPUT_DIR:-.}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── 1. 查最新 staging release ──────────────────────────────────────
echo "[1/5] 查询 release ..."
URL=$(curl -sL "https://api.github.com/repos/$REPO/releases/tags/$TAG" \
  | jq -r '.assets[] | select(.name | test("x86_64\\.AppImage$")) | .browser_download_url' \
  | head -1)
FILENAME=$(basename "$URL")
echo "      → $FILENAME"

# ── 2. 下载 ────────────────────────────────────────────────────────
echo "[2/5] 下载 AppImage ..."
wget -q --show-progress -O "$WORK/wine-staging.AppImage" "$URL"
chmod +x "$WORK/wine-staging.AppImage"

# ── 3. 下载 appimagetool ────────────────────────────────────────────
echo "[3/5] 下载 appimagetool ..."
TOOL_URL="https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage"
wget -q --show-progress -O "$WORK/appimagetool.AppImage" "$TOOL_URL"
chmod +x "$WORK/appimagetool.AppImage"

# ── 4. 提取 ────────────────────────────────────────────────────────
echo "[4/5] 提取并打补丁 ..."
cd "$WORK"
./wine-staging.AppImage --appimage-extract >/dev/null 2>&1
APPDIR="$WORK/squashfs-root"

# 用仓库中的 wrapper 替换原版
cp "$(dirname "$0")/wrapper" "$APPDIR/wrapper"
chmod 755 "$APPDIR/wrapper"

# ── 5. 重打包 ───────────────────────────────────────────────────────
echo "[5/5] 重打包 ..."
FIXED="$WORK/appimagetool-extracted"
mkdir "$FIXED"
cd "$FIXED"
"$WORK/appimagetool.AppImage" --appimage-extract >/dev/null 2>&1
cd "$WORK"

OUTPUT_NAME="${FILENAME%.AppImage}-fixed.AppImage"
ARCH=x86_64 "$FIXED/squashfs-root/AppRun" "$APPDIR" "$OUTPUT_DIR/$OUTPUT_NAME" 2>&1 | tail -3

echo ""
echo "✓ 输出: $OUTPUT_DIR/$OUTPUT_NAME"
echo "  使用: ./wine-appimage-launcher.sh <exe 或 wine 参数>"
