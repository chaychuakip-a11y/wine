#!/usr/bin/env bash
# ------------------------------------------------------------------
# Shared launcher for wine-staging-fixed.AppImage
#
# 可被多个用户共用：AppImage 放只读共享位置，挂载点/缓存/WINEPREFIX
# 均展开到各自的 $XDG_RUNTIME_DIR / $HOME，互不干扰。
#
# AppImage 查找顺序：
#   1. 环境变量 WINE_APPIMAGE
#   2. 与本脚本同目录的 wine-staging-fixed.AppImage
#   3. /opt/wine-staging-fixed.AppImage   （系统级共享安装位置）
#
# Usage: wine [args...]   (args forwarded to wine)
# ------------------------------------------------------------------
set -eu

_self_dir="$(dirname "$(readlink -f "$0")")"
APPIMAGE="${WINE_APPIMAGE:-}"
if [ -z "$APPIMAGE" ]; then
    for _candidate in \
        "$_self_dir/wine-staging-fixed.AppImage" \
        "$HOME/.local/share/wine-appimage/wine-staging-fixed.AppImage" \
        "/opt/wine-staging-fixed.AppImage" \
        "/home/asrdictt/tyliu23/wine-share-file/wine-staging-fixed.AppImage"; do
        if [ -x "$_candidate" ]; then
            APPIMAGE="$_candidate"
            break
        fi
    done
fi

if [ ! -x "$APPIMAGE" ]; then
    echo "wine-appimage-launcher: AppImage not found or not executable: $APPIMAGE" >&2
    exit 1
fi

# Per-user mount/tmp location. XDG_RUNTIME_DIR is tmpfs under /run/user/$UID
# (already per-user, cleaned at logout); fall back to ~/.cache.
BASE="${XDG_RUNTIME_DIR:-$HOME/.cache}/wine-appimage"
mkdir -p "$BASE"
chmod 700 "$BASE"

# AppImage type-2 runtime honours $TMPDIR for where to create
# .mount_XXXXXX. Redirecting it to $BASE keeps every user's mount inside
# their own $HOME/$XDG_RUNTIME_DIR and avoids /tmp cross-user issues.
export TMPDIR="$BASE"

# If FUSE is unavailable, fall back to extract-and-run mode.
# This extracts the AppImage to a temp dir on first run (slower, but no FUSE needed).
if ! fusermount --version >/dev/null 2>&1 && ! fusermount3 --version >/dev/null 2>&1; then
    export APPIMAGE_EXTRACT_AND_RUN=1
    # 集群环境 home 目录常挂 noexec（NFS/GPFS/Lustre）。shell 脚本在 noexec 上仍可被
    # bash 解释执行，无法用脚本测 ELF 是否可执行。直接切换到本地 /tmp（按 UID 隔离）。
    BASE="/tmp/wine-appimage-$(id -u)"
    mkdir -p "$BASE"
    chmod 700 "$BASE"
    export TMPDIR="$BASE"
fi

# Top-level recursion guard. The inner wrapper also has one, but we
# short-circuit the whole outer runtime if we detect we are already
# inside an active invocation (e.g. a wine child process resolved
# this script through $PATH again).
if [ "${__WINE_APPIMAGE_LAUNCHER_ACTIVE:-0}" = "1" ]; then
    # Forward directly to the already-mounted wine if available.
    if [ -n "${APPDIR:-}" ] && [ -x "$APPDIR/usr/bin/wine" ]; then
        exec "$APPDIR/usr/bin/wine" "$@"
    fi
    # Otherwise fall through once; the inner wrapper will also guard.
fi
export __WINE_APPIMAGE_LAUNCHER_ACTIVE=1

exec "$APPIMAGE" "$@"
