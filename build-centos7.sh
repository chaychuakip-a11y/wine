#!/usr/bin/env bash
# build-centos7.sh — 构建兼容 CentOS 7（glibc ≥ 2.17）的 wine-staging AppImage
#
# 在有网络的构建机上运行，需要 docker 或 podman。
# 产出的 AppImage 可复制到内网，在 glibc ≥ 2.17 的机器上直接使用。
#
# 用法：
#   bash build-centos7.sh
#   OUTPUT_DIR=/path/to/share bash build-centos7.sh
set -eu

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR}"
OUTPUT_NAME="wine-staging-fixed.AppImage"

DOCKER=""
for _t in docker podman; do
    if command -v "$_t" >/dev/null 2>&1; then DOCKER="$_t"; break; fi
done
[ -n "$DOCKER" ] || { echo "错误：未找到 docker 或 podman" >&2; exit 1; }

[ -f "$SCRIPT_DIR/wrapper" ] || { echo "错误：缺少 wrapper" >&2; exit 1; }
WRAPPER="$SCRIPT_DIR/wrapper"

echo "=== 构建 CentOS 7 兼容 Wine Staging AppImage ==="
echo "容器工具 : $DOCKER"
echo "输出文件 : $OUTPUT_DIR/$OUTPUT_NAME"
echo ""

INNER=$(mktemp /tmp/wine-build-inner.XXXXXX.sh)
trap 'rm -f "$INNER"' EXIT

cat > "$INNER" << 'INNER_SCRIPT'
#!/usr/bin/env bash
set -ex

export DEBIAN_FRONTEND=noninteractive

# 基础工具
apt-get update -qq
apt-get install -y --no-install-recommends \
    curl ca-certificates file gnupg2

# ── WineHQ Ubuntu 20.04 仓库（提供 wine64 x86_64 + wine32 i386）────────────
# Ubuntu 20.04 (focal) 有完整的 multilib 支持，WineHQ 仍在维护。
# 产出的 AppImage 通过捆绑系统库兼容 glibc ≥ 2.17（CentOS 7）。
dpkg --add-architecture i386
curl -fsSL https://dl.winehq.org/wine-builds/winehq.key \
    | gpg --dearmor -o /etc/apt/trusted.gpg.d/winehq.gpg
echo "deb [arch=amd64,i386] https://dl.winehq.org/wine-builds/ubuntu/ focal main" \
    > /etc/apt/sources.list.d/winehq.list
apt-get update -qq

# 安装 32 位系统运行库
apt-get install -y --no-install-recommends \
    libc6:i386 libstdc++6:i386 libgcc-s1:i386 \
    zlib1g:i386 libfreetype6:i386 2>/dev/null || true

# 安装 winehq-staging（wine64 + wine32 + 所有 DLL）
apt-get install -y --no-install-recommends --install-recommends \
    winehq-staging

echo "[诊断] WineHQ 安装位置:"
find /opt/wine-staging/bin -name 'wine*' -type f | sort
echo "[信息] 32位 DLL: $(find /opt/wine-staging -path '*/i386-unix/*.so' 2>/dev/null | wc -l) 个"
echo "[信息] 64位 DLL: $(find /opt/wine-staging -path '*/x86_64-unix/*.so' 2>/dev/null | wc -l) 个"

# ── 构建 AppDir ──────────────────────────────────────────────────────────
AD=/tmp/AppDir
mkdir -p "$AD/usr/bin" "$AD/usr/lib/wine" "$AD/usr/lib64/wine"

# wine 二进制
cp -a /opt/wine-staging/bin/. "$AD/usr/bin/"

# DLL（wine 7+ 布局：lib/wine/i386-unix/*.so  lib/wine/i386-windows/*.dll）
if [ -d /opt/wine-staging/lib/wine ]; then
    cp -a /opt/wine-staging/lib/wine/. "$AD/usr/lib/wine/"
fi
if [ -d /opt/wine-staging/lib64/wine ]; then
    cp -a /opt/wine-staging/lib64/wine/. "$AD/usr/lib64/wine/"
fi
# 兼容旧布局（lib/i386-linux-gnu/wine/ 等）
for _d in /opt/wine-staging/lib/i386-linux-gnu \
          /opt/wine-staging/lib/x86_64-linux-gnu; do
    [ -d "$_d" ] && cp -a "$_d/." "$AD/usr/lib/" 2>/dev/null || true
done

# ── 捆绑 32 位系统库（CentOS 7 可能没有 i386 glibc）───────────────────────
echo "[信息] 捆绑 32 位系统运行库..."
for _pattern in \
        libc.so.6 libm.so.6 libpthread.so.0 libdl.so.2 librt.so.1 \
        ld-linux.so.2 libz.so.1 \
        libstdc++.so.6 libgcc_s.so.1 \
        libfreetype.so.6; do
    for _dir in /lib/i386-linux-gnu /usr/lib/i386-linux-gnu /lib32 /usr/lib32; do
        for _f in "$_dir"/${_pattern}*; do
            [ -e "$_f" ] || [ -L "$_f" ] || continue
            cp -a "$_f" "$AD/usr/lib/" 2>/dev/null \
                && echo "  lib32: $_f" || true
        done
    done
done

# wrapper
cp /src/wrapper "$AD/wrapper"
chmod 755 "$AD/wrapper"

# AppRun
cat > "$AD/AppRun" << 'EOF'
#!/usr/bin/env bash
SELF="$(readlink -f "$0")"
export APPDIR="$(dirname "$SELF")"
export PATH="$APPDIR/usr/bin:$PATH"
# 64 位库路径
export LD_LIBRARY_PATH="\
$APPDIR/usr/lib64:\
$APPDIR/usr/lib64/wine:\
$APPDIR/usr/lib64/wine/x86_64-unix:\
${LD_LIBRARY_PATH:-}"
# 32 位库路径（wine32 i386 ELF 使用，prepend 优先用捆绑库）
export LD_LIBRARY_PATH="\
$APPDIR/usr/lib:\
$APPDIR/usr/lib/wine:\
$APPDIR/usr/lib/wine/i386-unix:\
$LD_LIBRARY_PATH"
export WINEDLLPATH="$APPDIR/usr/lib/wine:$APPDIR/usr/lib64/wine"
export WINELOADER="$APPDIR/usr/bin/wine"
exec "$APPDIR/wrapper" "$@"
EOF
chmod +x "$AD/AppRun"

# Desktop entry + 图标
mkdir -p "$AD/usr/share/applications" "$AD/usr/share/icons/hicolor/256x256/apps"
cat > "$AD/usr/share/applications/wine.desktop" << 'EOF'
[Desktop Entry]
Name=Wine
Exec=wine
Icon=wine
Type=Application
Categories=Utility;
EOF
_ico=$(find /opt/wine-staging /usr -name "wine.png" 2>/dev/null | head -1)
[ -n "$_ico" ] && cp "$_ico" "$AD/usr/share/icons/hicolor/256x256/apps/wine.png" \
|| printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\nIDATx\x9cc\x00\x01\x00\x00\x05\x00\x01\r\n-\xb4\x00\x00\x00\x00IEND\xaeB`\x82' \
    > "$AD/usr/share/icons/hicolor/256x256/apps/wine.png"
ln -sf usr/share/icons/hicolor/256x256/apps/wine.png "$AD/wine.png"
ln -sf usr/share/applications/wine.desktop           "$AD/wine.desktop"

# 汇总
echo ""
echo "=== AppDir 摘要 ==="
echo "  二进制 : $(ls "$AD/usr/bin/wine"* 2>/dev/null | tr '\n' ' ')"
echo "  64位 DLL: $(find "$AD/usr/lib64" "$AD/usr/lib" -path '*/x86_64-unix/*.so' 2>/dev/null | wc -l) 个"
echo "  32位 DLL: $(find "$AD/usr/lib"  -path '*/i386-unix/*.so' 2>/dev/null | wc -l) 个"
echo "  AppDir 大小: $(du -sh "$AD" | cut -f1)"

# 打包（runtime 由宿主机预下载后挂载进来，避免容器内网络限制）
AT=/tmp/appimagetool.AppImage
curl -fsSL -o "$AT" \
    https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage
chmod +x "$AT"

ARCH=x86_64 APPIMAGE_EXTRACT_AND_RUN=1 \
    "$AT" --runtime-file /src/runtime-x86_64 \
    "$AD" "/output/wine-staging-fixed.AppImage"
echo "✓ 完成：/output/wine-staging-fixed.AppImage"
INNER_SCRIPT

# 预下载 runtime（若不存在）
RUNTIME="$SCRIPT_DIR/runtime-x86_64"
if [ ! -f "$RUNTIME" ]; then
    echo "下载 AppImage runtime ..."
    wget -q -O "$RUNTIME" \
        https://github.com/AppImage/type2-runtime/releases/download/continuous/runtime-x86_64
fi

"$DOCKER" run --rm \
    -v "$OUTPUT_DIR:/output" \
    -v "$WRAPPER:/src/wrapper:ro" \
    -v "$INNER:/build.sh:ro" \
    -v "$RUNTIME:/src/runtime-x86_64:ro" \
    ubuntu:20.04 \
    bash /build.sh

echo ""
echo "=== 构建完成 ==="
echo "  产出文件：$OUTPUT_DIR/$OUTPUT_NAME"
echo ""
echo "  内网部署步骤："
echo "    1. 将以下三个文件放到共享目录："
echo "         $OUTPUT_NAME"
echo "         wine-appimage-launcher.sh"
echo "         install-user.sh"
echo "    2. 每位用户执行一次："
echo "         bash /path/to/install-user.sh"
echo "         source ~/.bashrc"
