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

# -- 临时目录和内部脚本 -------------------------------------------------------
WINE32_DIR=$(mktemp -d /tmp/wine32-XXXXXX)
INNER=$(mktemp /tmp/wine-build-inner.XXXXXX.sh)
trap 'rm -f "$INNER"; rm -rf "$WINE32_DIR"' EXIT

# -- 阶段1：在 i386 容器内安装 32 位 wine 并提取文件 --------------------------
echo "=== 阶段1：提取 32 位 wine 文件 (linux/386 容器) ==="
"$DOCKER" run --rm --platform linux/386 \
    -v "$WINE32_DIR:/wine32" \
    centos:7 bash -c '
set -e
sed -i \
    -e "s|^mirrorlist=|#mirrorlist=|g" \
    -e "s|^#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g" \
    /etc/yum.repos.d/CentOS-*.repo

yum install -y epel-release
yum install -y wine

echo "[信息] 32位容器内 wine --version:"
wine --version || true

echo "[信息] 提取 32位 wine 文件到 /wine32 ..."
rpm -qa | grep -i wine | xargs -r rpm -ql 2>/dev/null \
    | grep -v "(contains no files)" | sort -u \
    | while IFS= read -r f; do
        [ -e "$f" ] || [ -L "$f" ] || continue
        dst="/wine32$f"
        mkdir -p "$(dirname "$dst")"
        cp -a "$f" "$dst" 2>/dev/null || true
    done

# 解析 alternatives 软链（/usr/bin/wine -> /etc/alternatives/wine -> 实际二进制）
for _bin in wine wine64 wine32 wine32-preloader wineserver wineboot winecfg; do
    _src="/usr/bin/$_bin"
    [ -e "$_src" ] || continue
    _real=$(readlink -f "$_src" 2>/dev/null)
    if [ -n "$_real" ] && [ -f "$_real" ]; then
        rm -f "/wine32/usr/bin/$_bin"
        cp "$_real" "/wine32/usr/bin/$_bin" && chmod +x "/wine32/usr/bin/$_bin"
        echo "[信息] 解析 $_src -> $_real"
    fi
done

echo "[信息] 32位 wine 文件数: $(find /wine32 -type f | wc -l)"
echo "[信息] 32位 DLL 数量: $(find /wine32 -name "*.dll.so" | wc -l)"
echo "[信息] wine 二进制:"
ls -la /wine32/usr/bin/wine* 2>/dev/null || echo "  (未找到)"
'

echo ""
echo "=== 阶段2：在 x86_64 容器内构建 AppImage ==="

# -- 把容器内部的构建脚本写到临时文件，避免 heredoc 嵌套问题 ----------------
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

# 2. 安装 64 位 wine
echo "[信息] 安装 64 位 wine..."
yum install -y wine
wine --version || true

echo "[信息] wine64 检测:"
ls /usr/bin/wine64 /usr/lib64/wine/ 2>/dev/null || echo "  (未找到)"
echo "[信息] 64位 dll 数量: $(find /usr/lib64/wine -name '*.dll.so' 2>/dev/null | wc -l)"

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
    mkdir -p "$AD$WPFX"
    cp -a "$WPFX/." "$AD$WPFX/" || { echo "ERROR: 复制 $WPFX 失败，磁盘可能已满" >&2; exit 1; }
    for _bin in wine wine64 wine32 wine32-preloader wineserver wineboot winecfg; do
        _src="$WPFX/bin/$_bin"
        [ -e "$_src" ] || [ -L "$_src" ] || continue
        _rel="../../${WPFX#/}/bin/$_bin"
        ln -sf "$_rel" "$AD/usr/bin/$_bin" 2>/dev/null || \
            cp -a "$_src" "$AD/usr/bin/$_bin" 2>/dev/null || true
    done
else
    # 纯 /usr 安装：用 rpm -ql 精确收集
    echo "[信息] 收集 64位 wine rpm 文件列表..."
    rpm -qa | grep -i wine | xargs -r rpm -ql 2>/dev/null \
        | grep -v '(contains no files)' | sort -u > /tmp/wine-files.txt
    echo "[信息] 共 $(wc -l < /tmp/wine-files.txt) 个文件"

    while IFS= read -r f; do
        [ -e "$f" ] || [ -L "$f" ] || continue
        dst="$AD$f"
        mkdir -p "$(dirname "$dst")" || { echo "WARN: mkdir 失败: $(dirname "$dst")"; continue; }
        cp -a "$f" "$dst" || echo "WARN: cp 失败: $f"
    done < /tmp/wine-files.txt

    # 解析 alternatives 软链
    for _bin in wine wine64 wine32 wine32-preloader wineserver wineboot winecfg; do
        _src="/usr/bin/$_bin"
        [ -e "$_src" ] || continue
        _real=$(readlink -f "$_src" 2>/dev/null)
        if [ -n "$_real" ] && [ -f "$_real" ]; then
            echo "[信息] 解析链接 $_src -> $_real"
            rm -f "$AD/usr/bin/$_bin"
            cp "$_real" "$AD/usr/bin/$_bin" || { echo "WARN: cp 失败: $_real"; continue; }
            chmod +x "$AD/usr/bin/$_bin"
        fi
    done
fi

# 5. 合并 32 位 wine 文件（来自阶段1）
echo "[信息] 合并 32 位 wine 文件..."
if [ -d /wine32 ] && [ "$(find /wine32 -type f | wc -l)" -gt 0 ]; then
    # 合并 lib（32位）
    for _dir in /wine32/usr/lib /wine32/usr/lib/wine /wine32/usr/lib/wine/i386-unix; do
        [ -d "$_dir" ] || continue
        _rel="${_dir#/wine32}"
        mkdir -p "$AD$_rel"
        cp -a "$_dir/." "$AD$_rel/" 2>/dev/null || true
    done

    # 合并 32 位 wine 二进制（wine, wine32, wine-preloader）
    for _bin in wine wine32 wine32-preloader wineserver; do
        _src="/wine32/usr/bin/$_bin"
        [ -f "$_src" ] || continue
        # 32位二进制放到专用路径，避免覆盖64位
        cp "$_src" "$AD/usr/bin/${_bin}32" 2>/dev/null || true
        chmod +x "$AD/usr/bin/${_bin}32" 2>/dev/null || true
        echo "[信息] 安装 32位二进制: $AD/usr/bin/${_bin}32"
    done

    # wine32 主入口（优先用 wine32，否则用 wine）
    if [ -f "/wine32/usr/bin/wine32" ]; then
        cp "/wine32/usr/bin/wine32" "$AD/usr/bin/wine32"
        chmod +x "$AD/usr/bin/wine32"
    elif [ -f "/wine32/usr/bin/wine" ]; then
        cp "/wine32/usr/bin/wine" "$AD/usr/bin/wine32"
        chmod +x "$AD/usr/bin/wine32"
    fi

    # wine-preloader 32位
    for _name in wine-preloader wine32-preloader; do
        _src="/wine32/usr/bin/$_name"
        [ -f "$_src" ] || continue
        cp "$_src" "$AD/usr/bin/wine32-preloader"
        chmod +x "$AD/usr/bin/wine32-preloader"
        break
    done

    echo "[信息] 32位 DLL 合并完成: $(find "$AD/usr/lib" -name '*.dll.so' 2>/dev/null | wc -l) 个"
    echo "[信息] wine32 二进制: $(ls -la "$AD/usr/bin/wine32" 2>/dev/null || echo '未找到')"
else
    echo "[警告] /wine32 目录为空，AppImage 将缺少 32 位支持！"
fi

# 6. 应用 wrapper 补丁
cp /src/wrapper "$AD/wrapper"
chmod 755 "$AD/wrapper"

# 7. AppRun（设置库路径后交给 wrapper）
cat > "$AD/AppRun" << 'EOF'
#!/usr/bin/env bash
SELF="$(readlink -f "$0")"
export APPDIR="$(dirname "$SELF")"
export PATH="$APPDIR/usr/bin:$PATH"
export LD_LIBRARY_PATH="$APPDIR/usr/lib:$APPDIR/usr/lib64:$APPDIR/usr/lib/wine:$APPDIR/usr/lib64/wine:$APPDIR/usr/lib/wine/i386-unix:${LD_LIBRARY_PATH:-}"
exec "$APPDIR/wrapper" "$@"
EOF
chmod +x "$AD/AppRun"

# 8. Desktop entry + 图标
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

_ico=$(find /usr /opt -name "wine.png" 2>/dev/null | head -1)
if [ -n "$_ico" ]; then
    cp "$_ico" "$AD/usr/share/icons/hicolor/256x256/apps/wine.png"
else
    printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\nIDATx\x9cc\x00\x01\x00\x00\x05\x00\x01\r\n-\xb4\x00\x00\x00\x00IEND\xaeB`\x82' \
        > "$AD/usr/share/icons/hicolor/256x256/apps/wine.png"
fi

ln -sf usr/share/icons/hicolor/256x256/apps/wine.png "$AD/wine.png"
ln -sf usr/share/applications/wine.desktop           "$AD/wine.desktop"

# 9. 下载 appimagetool 并打包
AT=/tmp/appimagetool.AppImage
curl -fsSL -o "$AT" \
    https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage
chmod +x "$AT"

echo "[信息] AppDir 内容摘要:"
echo "  wine 二进制: $(ls "$AD/usr/bin/wine"* 2>/dev/null | tr '\n' ' ')"
echo "  64位 DLL: $(find "$AD/usr/lib64/wine" -name '*.dll.so' 2>/dev/null | wc -l) 个"
echo "  32位 DLL: $(find "$AD/usr/lib/wine" -name '*.dll.so' 2>/dev/null | wc -l) 个"
echo "  AppDir 大小: $(du -sh "$AD" 2>/dev/null | cut -f1)"

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
    -v "$WINE32_DIR:/wine32:ro" \
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
