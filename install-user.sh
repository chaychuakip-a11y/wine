#!/usr/bin/env bash
# install-user.sh — 单用户安装，无需 root
#
# 用法：
#   bash install-user.sh              # 从脚本所在目录复制（内网）或在线下载
#   bash install-user.sh --uninstall  # 卸载
#
# 安装位置（均在 $HOME 下，不影响其他用户）：
#   ~/.local/share/wine-appimage/wine-staging-fixed.AppImage
#   ~/.local/bin/wine
set -euo pipefail

APPIMAGE_NAME="wine-staging-fixed.AppImage"
LAUNCHER_NAME="wine-appimage-launcher.sh"
RELEASE_BASE="https://github.com/chaychuakip-a11y/wine/releases/download/v11.6-fixed"
RAW_BASE="https://raw.githubusercontent.com/chaychuakip-a11y/wine/master"

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
APPIMAGE_DEST="$HOME/.local/share/wine-appimage/$APPIMAGE_NAME"
LAUNCHER_DEST="$HOME/.local/bin/wine"

# ── 卸载 ──────────────────────────────────────────────────────────
if [ "${1:-}" = "--uninstall" ]; then
    echo "卸载 wine-appimage ..."
    rm -f "$LAUNCHER_DEST" "$APPIMAGE_DEST"
    rmdir "$(dirname "$APPIMAGE_DEST")" 2>/dev/null || true
    echo "✓ 已卸载（~/.wine-appimage-staging 已保留，如需删除请手动执行）"
    exit 0
fi

mkdir -p "$(dirname "$APPIMAGE_DEST")" "$HOME/.local/bin"

# ── 安装 AppImage ─────────────────────────────────────────────────
if [ -x "$APPIMAGE_DEST" ]; then
    echo "AppImage 已存在，跳过：$APPIMAGE_DEST"
elif [ -f "$SCRIPT_DIR/$APPIMAGE_NAME" ]; then
    echo "从本地复制 $APPIMAGE_NAME ..."
    cp "$SCRIPT_DIR/$APPIMAGE_NAME" "$APPIMAGE_DEST"
    chmod +x "$APPIMAGE_DEST"
else
    echo "本地未找到，尝试下载 $APPIMAGE_NAME ..."
    wget -q --show-progress -O "$APPIMAGE_DEST" "$RELEASE_BASE/$APPIMAGE_NAME"
    chmod +x "$APPIMAGE_DEST"
fi

# ── 安装 launcher ─────────────────────────────────────────────────
if [ -f "$SCRIPT_DIR/$LAUNCHER_NAME" ]; then
    echo "从本地复制 $LAUNCHER_NAME → $LAUNCHER_DEST"
    cp "$SCRIPT_DIR/$LAUNCHER_NAME" "$LAUNCHER_DEST"
else
    echo "本地未找到，尝试下载 $LAUNCHER_NAME ..."
    wget -q -O "$LAUNCHER_DEST" "$RAW_BASE/$LAUNCHER_NAME"
fi
chmod +x "$LAUNCHER_DEST"

# ── 确保 ~/.local/bin 在 PATH ─────────────────────────────────────
for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    if [ -f "$rc" ] && ! grep -qF '.local/bin' "$rc"; then
        printf '\n# wine-appimage\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$rc"
        echo "  已将 ~/.local/bin 加入 $rc"
    fi
done

echo ""
echo "✓ 安装完成"
echo "  重新加载 shell：source ~/.bashrc"
echo ""
echo "  使用：wine winecfg / wine foo.exe / WINEPREFIX=~/.mywine wine setup.exe"
echo "  卸载：bash $(readlink -f "$0") --uninstall"
