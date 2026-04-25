#!/usr/bin/env bash
# 用已编译好的 build-centos7/AppDir 完成 deps 收集 + AppImage 打包
# （wine 编译耗时太长，此脚本是从中间状态恢复用的）
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR}"
OUTPUT_NAME="wine-staging-fixed.AppImage"
BUILD_DIR="$SCRIPT_DIR/build-centos7"
APPDIR="$BUILD_DIR/AppDir"

DOCKER=""
for _t in docker podman; do
    command -v "$_t" >/dev/null 2>&1 && DOCKER="$_t" && break
done
[ -n "$DOCKER" ] || { echo "错误：未找到 docker 或 podman" >&2; exit 1; }
[ -d "$APPDIR/usr/bin" ] || { echo "错误：$APPDIR/usr/bin 不存在，先跑 build-centos7.sh" >&2; exit 1; }

INNER=$(mktemp /tmp/wine-finalize.XXXXXX.sh)
trap 'rm -f "$INNER"' EXIT

cat > "$INNER" << 'INNER_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
OUT=/output/AppDir

# CentOS 7 仓库已 EOL
sed -i 's/^mirrorlist=/#mirrorlist=/g; s|^#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' \
    /etc/yum.repos.d/CentOS-*.repo

# 装 ldd/file 等工具 + wine 运行时常用 lib（覆盖 wine 链接的依赖）
yum -y install -q file findutils which binutils \
    freetype fontconfig \
    libX11 libXext libXcursor libXi libXrandr libXrender libXinerama \
    libXcomposite libXxf86vm libXtst libXfixes \
    mesa-libGL mesa-libGLU \
    libxml2 libxslt \
    openldap zlib alsa-lib pulseaudio-libs \
    libpng libjpeg-turbo libtiff libgphoto2 sane-backends \
    cups-libs openssl gnutls krb5-libs systemd-libs \
    gstreamer1 gstreamer1-plugins-base ncurses libusbx \
    glibc.i686 libgcc.i686 libstdc++.i686 \
    freetype.i686 fontconfig.i686 libX11.i686 libXext.i686 \
    libXcursor.i686 libXi.i686 libXrandr.i686 libXrender.i686 \
    libXinerama.i686 libXcomposite.i686 libXxf86vm.i686 \
    mesa-libGL.i686 mesa-libGLU.i686 libxml2.i686 \
    openldap.i686 zlib.i686 alsa-lib.i686 pulseaudio-libs.i686 \
    libpng.i686 libjpeg-turbo.i686 cups-libs.i686 \
    krb5-libs.i686 systemd-libs.i686 ncurses-libs.i686 || true

mkdir -p "$OUT/usr/lib64" "$OUT/usr/lib"

collect_libs() {
    local bin="$1" libdir="$2"
    [ -e "$bin" ] || return 0
    local real
    real="$(readlink -f "$bin" 2>/dev/null || echo "$bin")"
    # ldd 对 wine-preloader 等特殊 ELF 可能返回非零；忽略
    ldd "$real" 2>/dev/null | awk '/=>/ {print $3}' | while read -r lib; do
        [ -z "$lib" ] && continue
        [ -f "$lib" ] || continue
        case "$(basename "$lib")" in
            ld-linux*|libc.so*|libm.so*|libpthread.so*|libdl.so*|librt.so*|libresolv.so*|libnsl.so*|libnss_*|libutil.so*)
                continue ;;
        esac
        cp -aL "$lib" "$libdir/" 2>/dev/null || true
        local d
        d="$(dirname "$lib")"
        for soname in "$d/$(basename "$lib")"*; do
            [ -e "$soname" ] && cp -an "$soname" "$libdir/" 2>/dev/null || true
        done
    done || true
    return 0
}

echo "=== 收集运行时依赖 ==="
for b in "$OUT/usr/bin/"*; do
    [ -f "$b" ] || continue
    case "$(file -b "$b" 2>/dev/null)" in
        *"64-bit"*) collect_libs "$b" "$OUT/usr/lib64" ;;
        *"32-bit"*) collect_libs "$b" "$OUT/usr/lib"   ;;
    esac
done
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

chown -R "${HOST_UID}:${HOST_GID}" /output
INNER_SCRIPT

echo "=== 启动容器收集 deps ==="
$DOCKER run --rm \
    -e HOST_UID="$(id -u)" \
    -e HOST_GID="$(id -g)" \
    -v "$BUILD_DIR:/output" \
    -v "$INNER:/build.sh:ro" \
    centos:7 \
    bash /build.sh

echo ""
echo "=== 组装 AppDir ==="
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

echo "  wine:    $(file "$APPDIR/usr/bin/wine"   2>/dev/null | cut -d: -f2-)"
echo "  wine64:  $(file "$APPDIR/usr/bin/wine64" 2>/dev/null | cut -d: -f2-)"
du -sh "$APPDIR"

echo ""
echo "=== 打包 AppImage ==="
RUNTIME="$SCRIPT_DIR/runtime-x86_64"
APPIMAGETOOL="$SCRIPT_DIR/extracted-tool/squashfs-root/AppRun"
if [ ! -x "$APPIMAGETOOL" ]; then
    rm -rf "$SCRIPT_DIR/extracted-tool"
    mkdir -p "$SCRIPT_DIR/extracted-tool"
    cd "$SCRIPT_DIR/extracted-tool"
    "$SCRIPT_DIR/appimagetool.AppImage" --appimage-extract >/dev/null 2>&1
    cd "$SCRIPT_DIR"
fi
ARCH=x86_64 "$APPIMAGETOOL" --runtime-file "$RUNTIME" "$APPDIR" "$OUTPUT_DIR/$OUTPUT_NAME" 2>&1 | tail -5
echo ""
echo "=== 完成 ==="
echo "  $OUTPUT_DIR/$OUTPUT_NAME ($(du -sh "$OUTPUT_DIR/$OUTPUT_NAME" | cut -f1))"
