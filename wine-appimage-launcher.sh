#!/usr/bin/env bash
# ------------------------------------------------------------------
# Per-user launcher for wine-staging-fixed.AppImage
#
# Redirects the outer AppImage FUSE mount point from the global /tmp
# (which causes multi-user permission conflicts when stale mount dirs
# are owned by another user) to a per-user location under $HOME.
#
# Usage: wine-appimage-launcher.sh [args...]   (args forwarded to wine)
# Env:
#   WINE_APPIMAGE=<path>   override path to the fixed AppImage
# ------------------------------------------------------------------
set -eu

APPIMAGE="${WINE_APPIMAGE:-$(dirname "$(readlink -f "$0")")/wine-staging-fixed.AppImage}"

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
