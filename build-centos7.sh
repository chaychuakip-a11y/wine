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

# -- 检测容器工具 -----------------------------------------------------------
DOCKER=""
for _t in docker podman; do
    if command -v "$_t" >/dev/null 2>&1; then
        DOCKER="$_t"
        break
    fi
done
if [ -z "$DOCKER" ]; then
    echo "错误：未找到 docker 或 podman，请先安装其中之一。" >&2
    exit 1
fi

WRAPPER="$SCRIPT_DIR/wrapper"
if [ ! -f "$WRAPPER" ]; then
    echo "错误：缺少 wrapper 文件：$WRAPPER" >&2
    exit 1
fi

echo "=== 构建 CentOS 7 兼容 Wine Staging AppImage ==="
echo "容器工具 : $DOCKER"
echo "输出文件 : $OUTPUT_DIR/$OUTPUT_NAME"
echo ""

# -- 把容器内部的构建脚本写到临时文件，避免 heredoc 嵌套问题 ----------------
INNER=$(mktemp /tmp/wine-build-inner.XXXXXX.sh)
trap 'rm -f "$INNER"' EXIT

cat > "$INNER" << 'INNER_SCRIPT'
#!/usr/bin/env bash
set -ex

# 0. CentOS 7 已 EOL，官方镜像关闭，切换到 vault.centos.org
sed -i \
    -e 's|^mirrorlist=|#mirrorlist=|g' \
    -e 's|^#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' \
    /etc/yum.repos.d/CentOS-*.repo

# 1. 基础依赖
yum install -y epel-release
# EPEL 在 vault 时代也需要指定镜像
sed -i \
    -e 's|^mirrorlist=|#mirrorlist=|g' \
    -e 's|^#baseurl=https\?://download.fedoraproject.org/pub/epel|baseurl=https://archives.fedoraproject.org/pub/archive/epel|g' \
    /etc/yum.repos.d/epel*.repo 2>/dev/null || true
yum install -y curl wget file which

# 2. WineHQ repo（RHEL 7 / CentOS 7）
curl -fsSL -o /etc/yum.repos.d/winehq-rhel7.repo \
    https://dl.winehq.org/wine-builds/rhel/7/winehq-rhel.repo
rpm --import https://dl.winehq.org/wine-builds/winehq.key

# 优先 wine-staging，不可用时回退 wine-stable
yum install -y winehq-staging 2>/dev/null || {
    echo "[警告] wine-staging 不可用，改用 wine-stable ..."
    yum install -y winehq-stable
}
wine --version

# 3. 确定 wine 安装路径（WineHQ on RHEL 安装到 /opt/wine-*）
if   [ -d /opt/wine-staging ]; then WPFX=/opt/wine-staging
elif [ -d /opt/wine-stable  ]; then WPFX=/opt/wine-stable
else                                 WPFX=/usr
fi

# 4. 构建 AppDir
AD=/tmp/AppDir
mkdir -p "$AD/usr/bin" "$AD/usr/lib" "$AD/usr/lib64" \
         "$AD/usr/share/wine" "$AD/usr/libexec"

cp -a "$WPFX/bin/."    "$AD/usr/bin/"
[ -d "$WPFX/lib"     ] && cp -a "$WPFX/lib/."     "$AD/usr/lib/"
[ -d "$WPFX/lib64"   ] && cp -a "$WPFX/lib64/."   "$AD/usr/lib64/"
[ -d "$WPFX/libexec" ] && cp -a "$WPFX/libexec/." "$AD/usr/libexec/"
[ -d "$WPFX/share/wine" ] && cp -a "$WPFX/share/wine/." "$AD/usr/share/wine/"

# 5. 应用 wrapper 补丁（含 progHome 修复和递归 guard）
cp /src/wrapper "$AD/wrapper"
chmod 755 "$AD/wrapper"

# 6. AppRun（设置库路径后交给 wrapper）
cat > "$AD/AppRun" << 'EOF'
#!/usr/bin/env bash
SELF="$(readlink -f "$0")"
export APPDIR="$(dirname "$SELF")"
export PATH="$APPDIR/usr/bin:$PATH"
export LD_LIBRARY_PATH="$APPDIR/usr/lib:$APPDIR/usr/lib64:$APPDIR/usr/lib/wine:$APPDIR/usr/lib64/wine:${LD_LIBRARY_PATH:-}"
exec "$APPDIR/wrapper" "$@"
EOF
chmod +x "$AD/AppRun"

# 7. Desktop entry + 图标（appimagetool 打包时必须存在）
mkdir -p "$AD/usr/share/applications" \
         "$AD/usr/share/icons/hicolor/256x256/apps"

cat > "$AD/usr/share/applications/wine.desktop" << 'EOF'
[Desktop Entry]
Name=Wine
Exec=wine
Icon=wine
Type=Application
Categories=Utility;
EOF

# 找系统里的 wine 图标，找不到就生成一个最小合法 PNG
_ico=$(find /usr /opt -name "wine.png" 2>/dev/null | head -1)
if [ -n "$_ico" ]; then
    cp "$_ico" "$AD/usr/share/icons/hicolor/256x256/apps/wine.png"
else
    # 最小合法 1x1 透明 PNG（appimagetool 只要求文件存在）
    printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\nIDATx\x9cc\x00\x01\x00\x00\x05\x00\x01\r\n-\xb4\x00\x00\x00\x00IEND\xaeB`\x82' \
        > "$AD/usr/share/icons/hicolor/256x256/apps/wine.png"
fi

ln -sf usr/share/icons/hicolor/256x256/apps/wine.png "$AD/wine.png"
ln -sf usr/share/applications/wine.desktop           "$AD/wine.desktop"

# 8. 下载 appimagetool 并打包
AT=/tmp/appimagetool.AppImage
curl -fsSL -o "$AT" \
    https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage
chmod +x "$AT"

ARCH=x86_64 APPIMAGE_EXTRACT_AND_RUN=1 "$AT" \
    "$AD" "/output/wine-staging-fixed.AppImage"

echo ""
echo "✓ 完成：/output/wine-staging-fixed.AppImage"
INNER_SCRIPT

# -- 在 CentOS 7 容器内执行构建 ---------------------------------------------
"$DOCKER" run --rm \
    -v "$OUTPUT_DIR:/output" \
    -v "$WRAPPER:/src/wrapper:ro" \
    -v "$INNER:/build.sh:ro" \
    centos:7 \
    bash /build.sh

echo ""
echo "=== 构建完成 ==="
echo ""
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
