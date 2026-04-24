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

WINE32_DIR=$(mktemp -d /tmp/wine32-XXXXXX)
INNER=$(mktemp /tmp/wine-build-inner.XXXXXX.sh)
trap 'rm -f "$INNER"; rm -rf "$WINE32_DIR"' EXIT

# ── 阶段1：linux/386 容器提取 32 位 wine ───────────────────────────────────
# EPEL 7 i386 包在 dl.fedoraproject.org 已下线，但在 archives.fedoraproject.org 保留
echo "=== 阶段1：提取 32 位 wine 文件 (linux/386 容器) ==="
"$DOCKER" run --rm --platform linux/386 \
    -v "$WINE32_DIR:/wine32" \
    centos:7 bash -c '
set -ex

# CentOS 7 EOL → vault
sed -i \
    -e "s|^mirrorlist=|#mirrorlist=|g" \
    -e "s|^#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g" \
    /etc/yum.repos.d/CentOS-*.repo

# EPEL 7 i386 已从 dl.fedoraproject.org 下线，用 archives 归档站
cat > /etc/yum.repos.d/epel.repo << "EPELEOF"
[epel]
name=Extra Packages for Enterprise Linux 7 - i386 (archive)
baseurl=https://archives.fedoraproject.org/pub/archive/epel/7/i386/
failovermethod=priority
enabled=1
gpgcheck=0
EPELEOF

yum install -y wine

echo "[阶段1] wine --version:"
wine --version || true
echo "[阶段1] wine 包列表:"
rpm -qa | grep -i wine | sort

echo "[阶段1] 提取文件到 /wine32 ..."
rpm -qa | grep -i wine | xargs -r rpm -ql 2>/dev/null \
    | grep -v "(contains no files)" | sort -u \
    | while IFS= read -r f; do
        [ -e "$f" ] || [ -L "$f" ] || continue
        dst="/wine32$f"
        mkdir -p "$(dirname "$dst")"
        cp -a "$f" "$dst" 2>/dev/null || true
    done

# 解析 alternatives 软链：/usr/bin/wine -> /etc/alternatives/wine -> 实际二进制
for _bin in wine wine64 wine32 wine32-preloader wine-preloader wineserver wineboot winecfg; do
    _src="/usr/bin/$_bin"
    [ -e "$_src" ] || continue
    _real=$(readlink -f "$_src" 2>/dev/null)
    if [ -n "$_real" ] && [ -f "$_real" ]; then
        rm -f "/wine32/usr/bin/$_bin"
        cp "$_real" "/wine32/usr/bin/$_bin" && chmod +x "/wine32/usr/bin/$_bin"
        echo "[阶段1] 解析 $_src -> $_real"
    fi
done

echo "[阶段1] 文件总数: $(find /wine32 -type f | wc -l)"
echo "[阶段1] DLL 数量: $(find /wine32 -name "*.dll.so" | wc -l)"
echo "[阶段1] 二进制:"
ls -la /wine32/usr/bin/wine* 2>/dev/null || echo "  (未找到)"
'

echo ""
echo "=== 阶段2：x86_64 容器构建 AppImage ==="

# ── 阶段2 内部脚本 ─────────────────────────────────────────────────────────
cat > "$INNER" << 'INNER_SCRIPT'
#!/usr/bin/env bash
set -ex

# CentOS 7 EOL → vault
sed -i \
    -e 's|^mirrorlist=|#mirrorlist=|g' \
    -e 's|^#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' \
    /etc/yum.repos.d/CentOS-*.repo

# EPEL x86_64（现行地址仍可用）
cat > /etc/yum.repos.d/epel.repo << 'EPELEOF'
[epel]
name=Extra Packages for Enterprise Linux 7 - x86_64
baseurl=https://dl.fedoraproject.org/pub/epel/7/x86_64/
failovermethod=priority
enabled=1
gpgcheck=0
EPELEOF

yum install -y curl wget file which

# 安装 64 位 wine（multilib_policy=best 禁止 yum 拉取 i686 依赖，避免找不到 EPEL i386）
echo "[阶段2] 安装 wine.x86_64 ..."
yum install -y wine \
    --setopt=multilib_policy=best \
    --exclude='*.i686' \
    --exclude='*.i386'
wine --version || true
echo "[阶段2] 64位 DLL: $(find /usr/lib64/wine -name '*.dll.so' 2>/dev/null | wc -l) 个"

# 确定 wine 前缀
if   [ -d /opt/wine-staging ]; then WPFX=/opt/wine-staging
elif [ -d /opt/wine-stable  ]; then WPFX=/opt/wine-stable
else                                 WPFX=/usr
fi

# 构建 AppDir
AD=/tmp/AppDir
mkdir -p "$AD/usr/bin" "$AD/usr/lib" "$AD/usr/lib64" \
         "$AD/usr/share/wine" "$AD/usr/libexec"

if [ "$WPFX" != "/usr" ]; then
    mkdir -p "$AD$WPFX"
    cp -a "$WPFX/." "$AD$WPFX/"
    for _bin in wine wine64 wine32 wine32-preloader wineserver wineboot winecfg; do
        _src="$WPFX/bin/$_bin"
        [ -e "$_src" ] || [ -L "$_src" ] || continue
        _rel="../../${WPFX#/}/bin/$_bin"
        ln -sf "$_rel" "$AD/usr/bin/$_bin" 2>/dev/null || \
            cp -a "$_src" "$AD/usr/bin/$_bin" 2>/dev/null || true
    done
else
    echo "[阶段2] 收集 64位 wine 文件..."
    rpm -qa | grep -i wine | xargs -r rpm -ql 2>/dev/null \
        | grep -v '(contains no files)' | sort -u > /tmp/wine-files.txt
    echo "[阶段2] 文件数: $(wc -l < /tmp/wine-files.txt)"

    while IFS= read -r f; do
        [ -e "$f" ] || [ -L "$f" ] || continue
        dst="$AD$f"
        mkdir -p "$(dirname "$dst")" || { echo "WARN: mkdir $dst"; continue; }
        cp -a "$f" "$dst" || echo "WARN: cp $f"
    done < /tmp/wine-files.txt

    # 解析 alternatives 软链
    for _bin in wine wine64 wine32 wine32-preloader wineserver wineboot winecfg; do
        _src="/usr/bin/$_bin"
        [ -e "$_src" ] || continue
        _real=$(readlink -f "$_src" 2>/dev/null)
        if [ -n "$_real" ] && [ -f "$_real" ]; then
            rm -f "$AD/usr/bin/$_bin"
            cp "$_real" "$AD/usr/bin/$_bin" && chmod +x "$AD/usr/bin/$_bin"
            echo "[阶段2] 解析 $_src -> $_real"
        fi
    done
fi

# 合并阶段1的 32 位 wine 文件
echo "[阶段2] 合并 32 位 wine 文件..."
_wine32_count=$(find /wine32 -type f 2>/dev/null | wc -l)
echo "[阶段2] /wine32 文件数: $_wine32_count"

if [ "$_wine32_count" -gt 0 ]; then
    # 32位 DLL → $AD/usr/lib/wine/
    for _src_dir in /wine32/usr/lib/wine /wine32/usr/lib/wine/i386-unix /wine32/usr/lib; do
        [ -d "$_src_dir" ] || continue
        _rel="${_src_dir#/wine32}"
        mkdir -p "$AD$_rel"
        cp -a "$_src_dir/." "$AD$_rel/" 2>/dev/null || true
    done

    # wine32 主入口
    for _candidate in /wine32/usr/bin/wine32 /wine32/usr/bin/wine; do
        [ -f "$_candidate" ] || continue
        cp "$_candidate" "$AD/usr/bin/wine32" && chmod +x "$AD/usr/bin/wine32"
        echo "[阶段2] wine32 安装自: $_candidate"
        break
    done

    # wine-preloader 32位
    for _candidate in /wine32/usr/bin/wine32-preloader /wine32/usr/bin/wine-preloader; do
        [ -f "$_candidate" ] || continue
        cp "$_candidate" "$AD/usr/bin/wine32-preloader" && chmod +x "$AD/usr/bin/wine32-preloader"
        echo "[阶段2] wine32-preloader 安装自: $_candidate"
        break
    done

    echo "[阶段2] 32位 DLL: $(find "$AD/usr/lib/wine" -name '*.dll.so' 2>/dev/null | wc -l) 个"
    echo "[阶段2] wine32: $(ls -la "$AD/usr/bin/wine32" 2>/dev/null || echo '未找到')"
else
    echo "[警告] 阶段1未产出文件，AppImage 将缺少 32 位支持！"
fi

# wrapper
cp /src/wrapper "$AD/wrapper"
chmod 755 "$AD/wrapper"

# AppRun
cat > "$AD/AppRun" << 'EOF'
#!/usr/bin/env bash
SELF="$(readlink -f "$0")"
export APPDIR="$(dirname "$SELF")"
export PATH="$APPDIR/usr/bin:$PATH"
export LD_LIBRARY_PATH="$APPDIR/usr/lib:$APPDIR/usr/lib64:$APPDIR/usr/lib/wine:$APPDIR/usr/lib64/wine:$APPDIR/usr/lib/wine/i386-unix:${LD_LIBRARY_PATH:-}"
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
_ico=$(find /usr /opt -name "wine.png" 2>/dev/null | head -1)
if [ -n "$_ico" ]; then
    cp "$_ico" "$AD/usr/share/icons/hicolor/256x256/apps/wine.png"
else
    printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\nIDATx\x9cc\x00\x01\x00\x00\x05\x00\x01\r\n-\xb4\x00\x00\x00\x00IEND\xaeB`\x82' \
        > "$AD/usr/share/icons/hicolor/256x256/apps/wine.png"
fi
ln -sf usr/share/icons/hicolor/256x256/apps/wine.png "$AD/wine.png"
ln -sf usr/share/applications/wine.desktop           "$AD/wine.desktop"

# 汇总
echo ""
echo "[阶段2] === AppDir 最终摘要 ==="
echo "  wine 二进制: $(ls "$AD/usr/bin/wine"* 2>/dev/null | tr '\n' ' ')"
echo "  64位 DLL:   $(find "$AD/usr/lib64/wine" -name '*.dll.so' 2>/dev/null | wc -l) 个"
echo "  32位 DLL:   $(find "$AD/usr/lib/wine"  -name '*.dll.so' 2>/dev/null | wc -l) 个"
echo "  AppDir 大小: $(du -sh "$AD" | cut -f1)"

# appimagetool 打包
AT=/tmp/appimagetool.AppImage
curl -fsSL -o "$AT" \
    https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage
chmod +x "$AT"

ARCH=x86_64 APPIMAGE_EXTRACT_AND_RUN=1 "$AT" \
    "$AD" "/output/wine-staging-fixed.AppImage"

echo ""
echo "✓ 完成：/output/wine-staging-fixed.AppImage"
INNER_SCRIPT

# ── 执行阶段2 ────────────────────────────────────────────────────────────
"$DOCKER" run --rm \
    -v "$OUTPUT_DIR:/output" \
    -v "$WRAPPER:/src/wrapper:ro" \
    -v "$INNER:/build.sh:ro" \
    -v "$WINE32_DIR:/wine32:ro" \
    centos:7 \
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
