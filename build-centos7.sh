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
yum install -y curl wget file which

# 2. Wine（WineHQ 已于 CentOS 7 EOL 后停止发布，centos/7 路径已 404）
#    EPEL wine 在 CentOS 7 构建，天然兼容 glibc 2.17。
echo "[信息] 安装 EPEL wine（glibc 2.17 兼容）..."
yum install -y wine
wine --version || true

# === 诊断：安装结果 ===
echo "--- wine 安装诊断 ---"
rpm -qa | grep -i wine || true
echo "which wine: $(which wine 2>/dev/null || echo 未找到)"
file "$(which wine 2>/dev/null)" 2>/dev/null || true
echo "/opt 内容:"; ls /opt/ 2>/dev/null || echo "(空)"
echo "dll.so 文件数: $(find /usr /opt -name '*.dll.so' 2>/dev/null | wc -l)"
find /usr /opt -name '*.dll.so' 2>/dev/null | head -5 || true
echo "--- 诊断结束 ---"

# 3. 确定 wine 前缀
if   [ -d /opt/wine-staging ]; then WPFX=/opt/wine-staging
elif [ -d /opt/wine-stable  ]; then WPFX=/opt/wine-stable
else                                 WPFX=/usr
fi

# 4. 构建 AppDir
AD=/tmp/AppDir
mkdir -p "$AD/usr/bin" "$AD/usr/lib" "$AD/usr/lib64" \
         "$AD/usr/share/wine" "$AD/usr/libexec"

echo "[信息] wine 前缀: $WPFX"

if [ "$WPFX" != "/usr" ]; then
    # /opt/wine-* 路径：把整个 prefix 原样复制到 AppDir 的相同位置，
    # 保留原始目录结构，避免符号链接断链。
    mkdir -p "$AD$WPFX"
    cp -a "$WPFX/." "$AD$WPFX/"
    # 同时在 usr/bin 建一层真实的符号链接，让 wrapper 能通过 $APPDIR/usr/bin/wine 找到
    for _bin in wine wine64 wine32 wineserver wineboot winecfg; do
        _src="$WPFX/bin/$_bin"
        [ -e "$_src" ] || [ -L "$_src" ] || continue
        ln -sf "$AD$_src" "$AD/usr/bin/$_bin" 2>/dev/null || \
            cp -a "$_src" "$AD/usr/bin/$_bin" 2>/dev/null || true
    done
else
    # 纯 /usr 安装：用 rpm -ql 精确收集
    echo "[信息] 收集 wine rpm 文件列表..."
    rpm -qa | grep -i wine | xargs -r rpm -ql 2>/dev/null \
        | grep -v '(contains no files)' | sort -u > /tmp/wine-files.txt
    echo "[信息] 共 $(wc -l < /tmp/wine-files.txt) 个文件"

    while IFS= read -r f; do
        [ -e "$f" ] || [ -L "$f" ] || continue
        dst="$AD$f"
        mkdir -p "$(dirname "$dst")"
        cp -a "$f" "$dst" 2>/dev/null || true
    done < /tmp/wine-files.txt

    # /usr/bin/wine 经过 alternatives 链：
    #   /usr/bin/wine -> /etc/alternatives/wine -> 实际二进制
    # AppImage 内没有 /etc/alternatives/，把实际文件直接覆盖掉符号链接。
    for _bin in wine wine64 wine32 wineserver wineboot winecfg; do
        _src="/usr/bin/$_bin"
        [ -e "$_src" ] || continue
        _real=$(readlink -f "$_src" 2>/dev/null)
        if [ -n "$_real" ] && [ -f "$_real" ]; then
            echo "[信息] 解析链接 $_src -> $_real"
            rm -f "$AD/usr/bin/$_bin"          # 先删掉已复制进来的符号链接
            cp "$_real" "$AD/usr/bin/$_bin"    # 再写入实体文件
            chmod +x "$AD/usr/bin/$_bin"
        fi
    done
fi

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
