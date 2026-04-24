#!/usr/bin/env bash
# build-centos7.sh — 构建兼容 CentOS 7（glibc 2.17）的 wine-staging AppImage
#
# 策略：
#   - 以原版 mmtrt AppImage 为基底（已内置 64 位 glibc 2.31 compat runtime，
#     wine64 可在 glibc ≥ 2.17 的系统上正常运行）
#   - 从 Ubuntu 20.04 + WineHQ 提取 wine32 i386 二进制和 i386-unix DLL
#   - 将 32 位 glibc（libc, libstdc++, ld-linux.so.2 等）打包进
#     AppDir/runtime/compat32/，并用 shell wrapper 包裹 wine32，
#     让 wine32 通过打包的 ld-linux.so.2 启动，绕过系统 glibc 版本限制
#
# 依赖：docker 或 podman，wget/curl
# 用法：
#   bash build-centos7.sh
#   OUTPUT_DIR=/path/to/share bash build-centos7.sh
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR}"
OUTPUT_NAME="wine-staging-fixed.AppImage"
MMTRT_URL="https://github.com/mmtrt/WINE_AppImage/releases/download/continuous-staging/wine-staging_11.6-x86_64.AppImage"

DOCKER=""
for _t in docker podman; do
    command -v "$_t" >/dev/null 2>&1 && DOCKER="$_t" && break
done
[ -n "$DOCKER" ] || { echo "错误：未找到 docker 或 podman" >&2; exit 1; }
[ -f "$SCRIPT_DIR/wrapper" ] || { echo "错误：缺少 wrapper" >&2; exit 1; }

RUNTIME="$SCRIPT_DIR/runtime-x86_64"
if [ ! -f "$RUNTIME" ]; then
    echo "下载 AppImage runtime ..."
    wget -q -O "$RUNTIME" \
        https://github.com/AppImage/type2-runtime/releases/download/continuous/runtime-x86_64
fi

# ── 第一阶段：提取原版 mmtrt AppImage ──────────────────────────────────────
MMTRT_APPIMAGE="$SCRIPT_DIR/wine-staging_11.6-x86_64.AppImage"
if [ ! -f "$MMTRT_APPIMAGE" ]; then
    echo "下载原版 mmtrt wine-staging 11.6 AppImage ..."
    wget -q --show-progress -O "$MMTRT_APPIMAGE" "$MMTRT_URL"
    chmod +x "$MMTRT_APPIMAGE"
fi

APPDIR="$SCRIPT_DIR/build-appdir"
rm -rf "$APPDIR"
mkdir -p "$APPDIR"
echo "提取原版 AppImage ..."
cd "$APPDIR" && "$MMTRT_APPIMAGE" --appimage-extract >/dev/null 2>&1
cd "$SCRIPT_DIR"
APPDIR="$SCRIPT_DIR/build-appdir/squashfs-root"
echo "  原版 AppDir: $APPDIR"
echo "  64位 compat runtime: $(ls $APPDIR/runtime/compat/lib/x86_64-linux-gnu/libc.so.6 2>/dev/null && echo '✓ 存在' || echo '✗ 缺失')"

# ── 第二阶段：从 Ubuntu 容器提取 wine32 ──────────────────────────────────
echo ""
echo "=== 从 Ubuntu 20.04 + WineHQ 提取 wine32 ==="

WINE32_DIR="$SCRIPT_DIR/build-wine32"
# Docker 上次产生的文件可能归 root 所有；使用容器内 root 清理
if [ -d "$WINE32_DIR" ]; then
    $DOCKER run --rm -v "$WINE32_DIR:/toclean" ubuntu:20.04 rm -rf /toclean 2>/dev/null || true
fi
rm -rf "$WINE32_DIR" 2>/dev/null || true
mkdir -p "$WINE32_DIR"

INNER=$(mktemp /tmp/wine-build-inner.XXXXXX.sh)
trap 'rm -f "$INNER"
    # Docker 产生的文件归 root 所有，需 sudo 才能删除
    if [ -d "$SCRIPT_DIR/build-wine32" ]; then
        sudo rm -rf "$SCRIPT_DIR/build-wine32" 2>/dev/null || \
            { chmod -R u+rwX "$SCRIPT_DIR/build-wine32" 2>/dev/null; rm -rf "$SCRIPT_DIR/build-wine32" 2>/dev/null; } || true
    fi
    if [ -d "$SCRIPT_DIR/build-appdir" ]; then
        rm -rf "$SCRIPT_DIR/build-appdir" 2>/dev/null || true
    fi' EXIT

cat > "$INNER" << 'INNER_SCRIPT'
#!/usr/bin/env bash
set -ex
export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get install -y --no-install-recommends curl ca-certificates gnupg2

dpkg --add-architecture i386
curl -fsSL https://dl.winehq.org/wine-builds/winehq.key \
    | gpg --dearmor -o /etc/apt/trusted.gpg.d/winehq.gpg
echo "deb [arch=amd64,i386] https://dl.winehq.org/wine-builds/ubuntu/ focal main" \
    > /etc/apt/sources.list.d/winehq.list
apt-get update -qq

# 安装 wine32 相关包（含 32 位系统库）
apt-get install -y --no-install-recommends --install-recommends \
    winehq-staging \
    libc6:i386 libstdc++6:i386 libgcc-s1:i386 \
    zlib1g:i386 libfreetype6:i386 libfontconfig1:i386 \
    libx11-6:i386 libxext6:i386

OUT=/output

# ── wine32 二进制（wine32 在 wine-staging 里是 /opt/wine-staging/bin/wine，
#    它实际是 64 位入口；真正的 i386 ELF 是 wine-preloader ）
# 在 WineHQ staging，wine32 的 i386 可执行在 lib/wine/i386-unix/
echo "=== wine 二进制 ==="
find /opt/wine-staging/bin -type f | sort | xargs file 2>/dev/null | grep -E "i386|32-bit" || true
find /opt/wine-staging -name '*preloader*' -type f | sort

# 复制 i386-unix DLL（wine32 native 实现）
mkdir -p "$OUT/lib/wine"
cp -a /opt/wine-staging/lib/wine/. "$OUT/lib/wine/" 2>/dev/null || true
echo "32位 DLL (.so): $(find $OUT/lib/wine/i386-unix -name '*.so' 2>/dev/null | wc -l)"

# 复制 wine32 i386 相关二进制
mkdir -p "$OUT/bin"
find /opt/wine-staging/bin -type f | while read f; do
    _arch=$(file "$f" 2>/dev/null)
    echo "[bin] $f: $_arch"
    cp "$f" "$OUT/bin/"
done

# ── 32 位 glibc compat 层 ──────────────────────────────────────────────────
# 这些库会放入 AppDir/runtime/compat32/，wrapper 用它们启动 wine32，
# 确保不依赖系统的 i386 glibc 版本。
mkdir -p "$OUT/compat32/lib"
for _f in \
    /lib/i386-linux-gnu/ld-linux.so.2 \
    /lib/i386-linux-gnu/ld-2.*.so \
    /lib/i386-linux-gnu/libc.so.6 \
    /lib/i386-linux-gnu/libc-*.so \
    /lib/i386-linux-gnu/libm.so.6 \
    /lib/i386-linux-gnu/libm-*.so \
    /lib/i386-linux-gnu/libpthread.so.0 \
    /lib/i386-linux-gnu/libpthread-*.so \
    /lib/i386-linux-gnu/libdl.so.2 \
    /lib/i386-linux-gnu/libdl-*.so \
    /lib/i386-linux-gnu/librt.so.1 \
    /lib/i386-linux-gnu/librt-*.so \
    /lib/i386-linux-gnu/libnsl.so.1 \
    /lib/i386-linux-gnu/libresolv.so.2 \
    /lib/i386-linux-gnu/libresolv-*.so \
    /usr/lib/i386-linux-gnu/libstdc++.so.6 \
    /usr/lib/i386-linux-gnu/libstdc++.so.6.* \
    /usr/lib/i386-linux-gnu/libgcc_s.so.1 \
    /usr/lib/i386-linux-gnu/libz.so.1 \
    /usr/lib/i386-linux-gnu/libz.so.1.* \
    /usr/lib/i386-linux-gnu/libfreetype.so.6 \
    /usr/lib/i386-linux-gnu/libfreetype.so.6.* \
    /usr/lib/i386-linux-gnu/libfontconfig.so.1 \
    /usr/lib/i386-linux-gnu/libfontconfig.so.1.* \
    /usr/lib/i386-linux-gnu/libX11.so.6 \
    /usr/lib/i386-linux-gnu/libX11.so.6.* \
    /usr/lib/i386-linux-gnu/libXext.so.6 \
    /usr/lib/i386-linux-gnu/libXext.so.6.*; do
    [ -e "$_f" ] || [ -L "$_f" ] || continue
    cp -a "$_f" "$OUT/compat32/lib/" && echo "  compat32: $_f" || true
done

echo ""
echo "=== wine32 提取完成 ==="
echo "  bin:        $(ls $OUT/bin/ | wc -l) 个"
echo "  i386 DLL:   $(find $OUT/lib/wine/i386-unix -name '*.so' 2>/dev/null | wc -l) 个"
echo "  compat32:   $(ls $OUT/compat32/lib/ | wc -l) 个库文件"
echo "  ld-linux:   $(ls $OUT/compat32/lib/ld-linux.so.2 2>/dev/null && echo '✓' || echo '✗ 缺失！')"
# 修正文件归属，避免宿主机 cp 时因 root 权限失败
chown -R "${HOST_UID}:${HOST_GID}" "$OUT"
INNER_SCRIPT

$DOCKER run --rm \
    -e HOST_UID="$(id -u)" \
    -e HOST_GID="$(id -g)" \
    -v "$WINE32_DIR:/output" \
    -v "$INNER:/build.sh:ro" \
    ubuntu:20.04 \
    bash /build.sh

echo ""
echo "=== 合并 wine32 到 AppDir ==="

# 合并 wine i386 DLL 到 mmtrt AppImage 的 wine 安装路径
# wine (64位) 的 WINELIBDIR 在编译时固定为 ../lib/wine/ 相对于 bin/wine，
# 即 $APPDIR/opt/wine-staging/lib/wine/。i386-unix DLL 必须在此目录下，
# wine64 才能在 WoW64/fork 模式中找到并加载它们。
mkdir -p "$APPDIR/opt/wine-staging/lib/wine"
if [ -d "$WINE32_DIR/lib/wine/i386-unix" ]; then
    cp -a "$WINE32_DIR/lib/wine/i386-unix"   "$APPDIR/opt/wine-staging/lib/wine/" 2>/dev/null || true
    cp -a "$WINE32_DIR/lib/wine/i386-windows" "$APPDIR/opt/wine-staging/lib/wine/" 2>/dev/null || true
fi

# 合并 32 位 compat runtime
mkdir -p "$APPDIR/runtime/compat32/lib"
cp -a "$WINE32_DIR/compat32/lib/." "$APPDIR/runtime/compat32/lib/" 2>/dev/null || true

# 创建 wine32 launcher（通过捆绑的 ld-linux.so.2 启动，绕过系统 glibc）
LD32="$APPDIR/runtime/compat32/lib/ld-linux.so.2"
if [ ! -e "$LD32" ]; then
    echo "✗ 错误：compat32/lib/ld-linux.so.2 未提取到，wine32 compat 不完整" >&2
    exit 1
fi
# 确保 ld-2.31.so（ld-linux.so.2 的真实文件）可执行
chmod +x "$APPDIR/runtime/compat32/lib/ld-2.31.so" 2>/dev/null || true
chmod +x "$APPDIR/runtime/compat32/lib/ld-linux.so.2" 2>/dev/null || true

# wine32 wrapper：放在 wine64 会搜索的路径：
#   $APPDIR/opt/wine-staging/bin/wine32  （与 bin/wine 同级，wine 内部 exec_wine_loader 找到它）
#   $APPDIR/usr/bin/wine32               （wrapper 设置的 WINE32 env var 指向此处，作为备选）
# 两者内容相同，指向同一个 i386-unix/wine ELF，经由打包的 ld-linux.so.2 加载。

WINE32_LAUNCHER_CONTENT='#!/usr/bin/env bash
# wine32 launcher — 通过打包的 ld-linux.so.2 启动 i386 wine，
# 确保在 glibc 2.17（CentOS 7）上也能运行。
SELF_DIR="$(dirname "$(readlink -f "$0")")"
# 从 opt/wine-staging/bin/ 向上三级得到 AppDir
APPDIR="$(cd "$SELF_DIR/../../.." && pwd)"
LD32="$APPDIR/runtime/compat32/lib/ld-2.31.so"
WINE32_BIN="$APPDIR/opt/wine-staging/lib/wine/i386-unix/wine"
[ -x "$LD32" ]     || { echo "wine32: ld-linux.so.2 not found: $LD32" >&2; exit 1; }
[ -x "$WINE32_BIN" ] || { echo "wine32: i386 wine not found: $WINE32_BIN" >&2; exit 1; }
export LD_LIBRARY_PATH="$APPDIR/runtime/compat32/lib:$APPDIR/opt/wine-staging/lib/wine/i386-unix${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$LD32" "$WINE32_BIN" "$@"
'

echo "$WINE32_LAUNCHER_CONTENT" > "$APPDIR/opt/wine-staging/bin/wine32"
chmod +x "$APPDIR/opt/wine-staging/bin/wine32"

# usr/bin/wine32 → opt/wine-staging/bin/wine32（供 wrapper WINE32= 使用）
ln -sf "../../opt/wine-staging/bin/wine32" "$APPDIR/usr/bin/wine32"

# ── 更新 wrapper ──────────────────────────────────────────────────────────
cp "$SCRIPT_DIR/wrapper" "$APPDIR/wrapper"
chmod 755 "$APPDIR/wrapper"

# ── 汇总 ─────────────────────────────────────────────────────────────────
echo ""
echo "=== AppDir 最终摘要 ==="
for _b in wine wine32 wineserver wineboot; do
    _p="$APPDIR/opt/wine-staging/bin/$_b"
    [ -e "$_p" ] && echo "  $_b: $(file "$_p" | cut -d: -f2)" || echo "  $_b: 不存在"
done
echo "  64位 DLL: $(find "$APPDIR/opt/wine-staging/lib/wine/x86_64-unix" -name '*.so' 2>/dev/null | wc -l) 个"
echo "  32位 DLL: $(find "$APPDIR/opt/wine-staging/lib/wine/i386-unix"   -name '*.so' 2>/dev/null | wc -l) 个"
echo "  64位 compat runtime: $(ls "$APPDIR/runtime/compat/lib/x86_64-linux-gnu/libc.so.6" 2>/dev/null && echo '✓' || echo '✗')"
echo "  32位 compat runtime: $(ls "$APPDIR/runtime/compat32/lib/ld-2.31.so" 2>/dev/null && echo '✓' || echo '✗')"

# ── 重新打包 ──────────────────────────────────────────────────────────────
echo ""
echo "=== 打包 AppImage ==="
APPIMAGETOOL="$SCRIPT_DIR/extracted-tool/squashfs-root/AppRun"
if [ ! -x "$APPIMAGETOOL" ]; then
    AT_APPIMAGE="$SCRIPT_DIR/appimagetool.AppImage"
    if [ ! -f "$AT_APPIMAGE" ]; then
        wget -q -O "$AT_APPIMAGE" \
            https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage
        chmod +x "$AT_APPIMAGE"
    fi
    mkdir -p "$SCRIPT_DIR/extracted-tool"
    cd "$SCRIPT_DIR/extracted-tool"
    "$AT_APPIMAGE" --appimage-extract >/dev/null 2>&1
    cd "$SCRIPT_DIR"
    APPIMAGETOOL="$SCRIPT_DIR/extracted-tool/squashfs-root/AppRun"
fi

ARCH=x86_64 "$APPIMAGETOOL" \
    --runtime-file "$RUNTIME" \
    "$APPDIR" \
    "$OUTPUT_DIR/$OUTPUT_NAME" 2>&1 | tail -5

echo ""
echo "=== 构建完成 ==="
echo "  产出文件 : $OUTPUT_DIR/$OUTPUT_NAME ($(du -sh "$OUTPUT_DIR/$OUTPUT_NAME" | cut -f1))"
echo ""
echo "  内网部署："
echo "    将 $OUTPUT_NAME wine-appimage-launcher.sh install-user.sh 放到共享目录"
echo "    每位用户执行：bash /共享路径/install-user.sh"
