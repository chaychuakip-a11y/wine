#!/usr/bin/env bash
# build-centos7.sh — 在 CentOS 7 容器里从源码编译 wine 9.0，链接系统 glibc 2.17
#
# EPEL 7 只有 wine 4.0.4 且无 i686 包；用户的 32 位 EXE 在 4.0.4 下报 "Bad EXE format"。
# 必须从源码自己编译现代 wine，链接 CentOS 7 系统 glibc。
#
# 用法：
#   bash build-centos7.sh
#   WINE_VERSION=9.0 bash build-centos7.sh
#   OUTPUT_DIR=/path/to/share bash build-centos7.sh
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR}"
OUTPUT_NAME="wine-staging-fixed.AppImage"
WINE_VERSION="${WINE_VERSION:-9.0}"

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

APPIMAGETOOL_APPIMAGE="$SCRIPT_DIR/appimagetool.AppImage"
if [ ! -f "$APPIMAGETOOL_APPIMAGE" ]; then
    echo "下载 appimagetool ..."
    wget -q -O "$APPIMAGETOOL_APPIMAGE" \
        https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage
    chmod +x "$APPIMAGETOOL_APPIMAGE"
fi

# ── 准备 build 目录 ────────────────────────────────────────────────────────
BUILD_DIR="$SCRIPT_DIR/build-centos7"
APPDIR_OUT="$BUILD_DIR/AppDir"

if [ -d "$BUILD_DIR" ]; then
    echo "清理上次构建产物 ..."
    $DOCKER run --rm -v "$BUILD_DIR:/toclean" centos:7 rm -rf /toclean 2>/dev/null || true
    rm -rf "$BUILD_DIR" 2>/dev/null || true
fi
mkdir -p "$BUILD_DIR" "$APPDIR_OUT"

# ── 容器内构建脚本 ─────────────────────────────────────────────────────────
INNER=$(mktemp /tmp/wine-c7-build.XXXXXX.sh)
trap 'rm -f "$INNER"' EXIT

cat > "$INNER" << 'INNER_SCRIPT'
#!/usr/bin/env bash
set -euxo pipefail

WINE_VERSION="${WINE_VERSION:-9.0}"
JOBS="$(nproc)"
BUILD=/build
OUT=/output/AppDir
mkdir -p "$OUT" "$BUILD"

# CentOS 7 仓库已 EOL，切到 vault.centos.org
sed -i 's/^mirrorlist=/#mirrorlist=/g; s|^#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' \
    /etc/yum.repos.d/CentOS-*.repo

# ── 基础工具 + EPEL + SCL（devtoolset-11 提供 gcc 11） ─────────────────────
yum -y install epel-release centos-release-scl
# CentOS-SCLo 仓库已 EOL；重写成 vault 上的归档地址
cat > /etc/yum.repos.d/CentOS-SCLo-scl.repo << 'EOF'
[centos-sclo-sclo]
name=CentOS-7 - SCLo sclo
baseurl=https://vault.centos.org/centos/7/sclo/x86_64/sclo/
gpgcheck=0
enabled=1
EOF
cat > /etc/yum.repos.d/CentOS-SCLo-scl-rh.repo << 'EOF'
[centos-sclo-rh]
name=CentOS-7 - SCLo rh
baseurl=https://vault.centos.org/centos/7/sclo/x86_64/rh/
gpgcheck=0
enabled=1
EOF
sed -i \
    -e 's/^metalink=/#metalink=/g' \
    -e 's/^mirrorlist=/#mirrorlist=/g' \
    -e 's|^#baseurl=https\?://download.fedoraproject.org/pub/epel|baseurl=https://archives.fedoraproject.org/pub/archive/epel|g' \
    -e 's|^#baseurl=https\?://download.example/pub/epel|baseurl=https://archives.fedoraproject.org/pub/archive/epel|g' \
    /etc/yum.repos.d/epel*.repo

yum -y install \
    devtoolset-11-gcc devtoolset-11-gcc-c++ devtoolset-11-binutils \
    glibc-devel glibc-devel.i686 \
    libstdc++-devel libstdc++-devel.i686 \
    make autoconf automake bison flex pkgconfig \
    git wget tar bzip2 xz patch which file findutils perl gettext

# ── wine 编译依赖（64 + 32 位）─────────────────────────────────────────────
PKGS_BOTH="\
    freetype-devel fontconfig-devel \
    libX11-devel libXext-devel libXcursor-devel libXi-devel \
    libXrandr-devel libXrender-devel libXinerama-devel \
    libXcomposite-devel libXxf86vm-devel \
    mesa-libGL-devel mesa-libGLU-devel \
    libxml2-devel libxslt-devel \
    openldap-devel zlib-devel \
    alsa-lib-devel pulseaudio-libs-devel \
    libpng-devel libjpeg-turbo-devel libtiff-devel \
    libgphoto2-devel sane-backends-devel \
    cups-devel openssl-devel gnutls-devel \
    krb5-devel libudev-devel \
    gstreamer1-devel gstreamer1-plugins-base-devel \
    ncurses-devel readline-devel \
    libusbx-devel \
"
yum -y install $PKGS_BOTH || true
for p in $PKGS_BOTH; do
    yum -y install "${p}.i686" 2>/dev/null || true
done
yum -y install glibc.i686 libgcc.i686 libstdc++.i686

# ── 启用 devtoolset-11 ─────────────────────────────────────────────────────
source /opt/rh/devtoolset-11/enable
export CC=gcc
export CXX=g++
gcc --version

# ── 下载 wine 源码 ─────────────────────────────────────────────────────────
cd "$BUILD"
echo "=== 下载 wine $WINE_VERSION 源码 ==="
wget --tries=3 --timeout=60 -O wine.tar.xz \
    "https://dl.winehq.org/wine/source/${WINE_VERSION}/wine-${WINE_VERSION}.tar.xz"
tar xf wine.tar.xz
mv "wine-${WINE_VERSION}" wine-src

# ── 编译 wine64（先建，wine32 需要它） ────────────────────────────────────
echo "=== 编译 wine64（用 $JOBS 并发） ==="
mkdir -p "$BUILD/wine64-build"
cd "$BUILD/wine64-build"
PKG_CONFIG_PATH=/usr/lib64/pkgconfig:/usr/share/pkgconfig \
"$BUILD/wine-src/configure" \
    --prefix=/opt/wine \
    --enable-win64 \
    --disable-tests \
    --without-vulkan \
    --without-vkd3d \
    --without-mingw \
    --without-oss
make -j"$JOBS"
make install DESTDIR="$OUT"

# ── 编译 wine32（i386，与 wine64 配合 wow64） ─────────────────────────────
echo "=== 编译 wine32 ==="
mkdir -p "$BUILD/wine32-build"
cd "$BUILD/wine32-build"
PKG_CONFIG_PATH=/usr/lib/pkgconfig:/usr/share/pkgconfig \
"$BUILD/wine-src/configure" \
    --prefix=/opt/wine \
    --libdir=/opt/wine/lib \
    --with-wine64="$BUILD/wine64-build" \
    --disable-tests \
    --without-vulkan \
    --without-vkd3d \
    --without-mingw \
    --without-oss
make -j"$JOBS"
make install DESTDIR="$OUT"

echo "=== wine 安装结果 ==="
ls -la "$OUT/opt/wine/bin/" | head
file "$OUT/opt/wine/bin/wine"   2>/dev/null || true
file "$OUT/opt/wine/bin/wine64" 2>/dev/null || true

# ── 整理目录：把 /opt/wine 内容上移到 AppDir/usr 标准布局 ─────────────────
mkdir -p "$OUT/usr/bin" "$OUT/usr/lib" "$OUT/usr/lib64" "$OUT/usr/share"
cp -a "$OUT/opt/wine/bin/."   "$OUT/usr/bin/"
[ -d "$OUT/opt/wine/lib"   ] && cp -a "$OUT/opt/wine/lib/."   "$OUT/usr/lib/"   || true
[ -d "$OUT/opt/wine/lib64" ] && cp -a "$OUT/opt/wine/lib64/." "$OUT/usr/lib64/" || true
[ -d "$OUT/opt/wine/share" ] && cp -a "$OUT/opt/wine/share/." "$OUT/usr/share/" || true
rm -rf "$OUT/opt"

# ── 收集运行时共享库依赖（不含 glibc）────────────────────────────────────
collect_libs() {
    local bin="$1" libdir="$2"
    [ -e "$bin" ] || return 0
    local real
    real="$(readlink -f "$bin" 2>/dev/null || echo "$bin")"
    ldd "$real" 2>/dev/null | awk '/=>/ {print $3}' | while read -r lib; do
        [ -z "$lib" ] && continue
        [ -f "$lib" ] || continue
        case "$(basename "$lib")" in
            ld-linux*|libc.so*|libm.so*|libpthread.so*|libdl.so*|librt.so*|libresolv.so*|libnsl.so*|libnss_*|libutil.so*)
                continue ;;
        esac
        cp -aL "$lib" "$libdir/" 2>/dev/null || true
        local d="$(dirname "$lib")" soname
        for soname in "$d/$(basename "$lib")"*; do
            [ -e "$soname" ] && cp -an "$soname" "$libdir/" 2>/dev/null || true
        done
    done
}

# 主二进制
for b in "$OUT/usr/bin/"*; do
    [ -f "$b" ] || continue
    case "$(file -b "$b" 2>/dev/null)" in
        *"64-bit"*) collect_libs "$b" "$OUT/usr/lib64" ;;
        *"32-bit"*) collect_libs "$b" "$OUT/usr/lib"   ;;
    esac
done
# wine PE 加载器 (.so)
for f in "$OUT/usr/lib64/wine/x86_64-unix/"*.so; do
    [ -f "$f" ] && collect_libs "$f" "$OUT/usr/lib64"
done
for f in "$OUT/usr/lib/wine/i386-unix/"*.so; do
    [ -f "$f" ] && collect_libs "$f" "$OUT/usr/lib"
done

echo "=== AppDir 内容统计 ==="
echo "  wine 主二进制: $(ls $OUT/usr/bin/ | wc -l) 个"
echo "  64位 wine DLL: $(find $OUT/usr/lib64/wine -name '*.so' 2>/dev/null | wc -l) 个"
echo "  32位 wine DLL: $(find $OUT/usr/lib/wine   -name '*.so' 2>/dev/null | wc -l) 个"
echo "  bundled lib64: $(ls $OUT/usr/lib64/*.so* 2>/dev/null | wc -l) 个"
echo "  bundled lib32: $(ls $OUT/usr/lib/*.so*   2>/dev/null | wc -l) 个"

# 修正归属
chown -R "${HOST_UID}:${HOST_GID}" /output
INNER_SCRIPT

# ── 启动构建容器 ───────────────────────────────────────────────────────────
echo ""
echo "=== 启动 CentOS 7 编译容器（耗时 1-2 小时）==="
$DOCKER run --rm \
    -e HOST_UID="$(id -u)" \
    -e HOST_GID="$(id -g)" \
    -e WINE_VERSION="$WINE_VERSION" \
    -v "$BUILD_DIR:/output" \
    -v "$INNER:/build.sh:ro" \
    centos:7 \
    bash /build.sh

# ── 组装 AppDir ────────────────────────────────────────────────────────────
echo ""
echo "=== 组装 AppDir ==="
APPDIR="$APPDIR_OUT"

cp "$SCRIPT_DIR/wrapper" "$APPDIR/AppRun"
chmod 755 "$APPDIR/AppRun"

cat > "$APPDIR/wine.desktop" << 'EOF'
[Desktop Entry]
Name=Wine
Exec=wine
Icon=wine
Type=Application
Categories=System;
EOF
printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\rIDATx\x9cc\x00\x01\x00\x00\x05\x00\x01\r\n-\xb4\x00\x00\x00\x00IEND\xaeB`\x82' > "$APPDIR/wine.png"

echo "=== AppDir 最终摘要 ==="
echo "  wine:    $(file "$APPDIR/usr/bin/wine"   2>/dev/null | cut -d: -f2-)"
echo "  wine64:  $(file "$APPDIR/usr/bin/wine64" 2>/dev/null | cut -d: -f2-)"
du -sh "$APPDIR"

# ── 打包 AppImage ──────────────────────────────────────────────────────────
echo ""
echo "=== 打包 AppImage ==="
APPIMAGETOOL="$SCRIPT_DIR/extracted-tool/squashfs-root/AppRun"
if [ ! -x "$APPIMAGETOOL" ]; then
    rm -rf "$SCRIPT_DIR/extracted-tool"
    mkdir -p "$SCRIPT_DIR/extracted-tool"
    cd "$SCRIPT_DIR/extracted-tool"
    "$APPIMAGETOOL_APPIMAGE" --appimage-extract >/dev/null 2>&1
    cd "$SCRIPT_DIR"
fi

ARCH=x86_64 "$APPIMAGETOOL" \
    --runtime-file "$RUNTIME" \
    "$APPDIR" \
    "$OUTPUT_DIR/$OUTPUT_NAME" 2>&1 | tail -5

echo ""
echo "=== 构建完成 ==="
echo "  产出文件: $OUTPUT_DIR/$OUTPUT_NAME ($(du -sh "$OUTPUT_DIR/$OUTPUT_NAME" | cut -f1))"
