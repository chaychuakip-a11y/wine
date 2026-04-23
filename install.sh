#!/usr/bin/env bash
# install.sh — 系统级共享安装（需要 root）
#
# 安装后所有用户直接执行 wine foo.exe 即可，各自的挂载点、WINEPREFIX、
# DXVK 缓存均隔离在自己的 $XDG_RUNTIME_DIR / $HOME 下。
#
# 用法：
#   sudo bash install.sh                       # 使用本地已有 AppImage
#   sudo APPIMAGE=/path/to/xxx.AppImage bash install.sh
#   sudo bash install.sh --uninstall           # 卸载
#
# 文件布局（安装后）：
#   /opt/wine-staging-fixed.AppImage   AppImage 本体（只读共享）
#   /usr/local/bin/wine                启动脚本（所有用户共用）
set -euo pipefail

INSTALL_APPIMAGE="/opt/wine-staging-fixed.AppImage"
INSTALL_LAUNCHER="/usr/local/bin/wine"
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"

# ── 卸载 ──────────────────────────────────────────────────────────
if [ "${1:-}" = "--uninstall" ]; then
    echo "卸载 wine-appimage ..."
    rm -f "$INSTALL_LAUNCHER"
    rm -f "$INSTALL_APPIMAGE"
    echo "✓ 已卸载"
    exit 0
fi

# ── 检查 root ─────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    echo "请用 sudo 运行此脚本" >&2
    exit 1
fi

# ── 找到 AppImage ─────────────────────────────────────────────────
SRC_APPIMAGE="${APPIMAGE:-}"
if [ -z "$SRC_APPIMAGE" ]; then
    for _c in \
        "$SCRIPT_DIR/wine-staging-fixed.AppImage" \
        "./wine-staging-fixed.AppImage"; do
        if [ -f "$_c" ]; then
            SRC_APPIMAGE="$_c"
            break
        fi
    done
fi
if [ -z "$SRC_APPIMAGE" ] || [ ! -f "$SRC_APPIMAGE" ]; then
    echo "找不到 wine-staging-fixed.AppImage。" >&2
    echo "请先运行 bash build.sh，或指定路径：APPIMAGE=<path> sudo bash install.sh" >&2
    exit 1
fi

# ── 安装 AppImage ─────────────────────────────────────────────────
echo "安装 AppImage → $INSTALL_APPIMAGE"
cp "$SRC_APPIMAGE" "$INSTALL_APPIMAGE"
chown root:root "$INSTALL_APPIMAGE"
chmod 755 "$INSTALL_APPIMAGE"

# ── 安装 launcher ─────────────────────────────────────────────────
echo "安装 launcher → $INSTALL_LAUNCHER"
cp "$SCRIPT_DIR/wine-appimage-launcher.sh" "$INSTALL_LAUNCHER"
chown root:root "$INSTALL_LAUNCHER"
chmod 755 "$INSTALL_LAUNCHER"

echo ""
echo "✓ 安装完成"
echo "  所有用户现在可以直接执行："
echo "    wine foo.exe"
echo "    wine winecfg"
echo "    WINEPREFIX=~/.mywine wine setup.exe"
echo ""
echo "  卸载：sudo bash install.sh --uninstall"
