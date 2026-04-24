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

# EPEL 7 i686 包实际存放在 x86_64 仓库目录（multilib），没有单独的 i386 仓库。
# 用 curl 直接抓目录列表，找出 wine-core.*.x86_64.rpm 和 wine-core.*.i686.rpm，
# 然后 rpm --nodeps 安装，完全绕过 yum 的架构解析。
cat > "$INNER" << 'INNER_SCRIPT'
#!/usr/bin/env bash
set -ex

# CentOS 7 EOL → vault
sed -i \
    -e 's|^mirrorlist=|#mirrorlist=|g' \
    -e 's|^#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' \
    /etc/yum.repos.d/CentOS-*.repo

# 基础工具（只用 CentOS 基础源，不需要 EPEL）
yum install -y curl wget file which

# ── 从 EPEL x86_64 repodata 解析并下载 wine 包 ───────────────────────────
# EPEL 7 不支持目录浏览；从 repodata/primary.xml.gz 找包的真实路径
# EPEL 7 随 CentOS 7 一起归档，dl.fedoraproject.org 已 404
# 需使用 archives.fedoraproject.org
EPEL_BASE="https://archives.fedoraproject.org/pub/archive/epel/7/x86_64"

echo "[信息] 下载 EPEL repomd.xml ..."
curl -fsSL "$EPEL_BASE/repodata/repomd.xml" -o /tmp/repomd.xml
cat /tmp/repomd.xml | grep -i primary || true

# 从 repomd.xml 提取 primary.xml.gz 的相对路径
_primary=$(grep -oP '(?<=href=")[^"]+' /tmp/repomd.xml | grep 'primary' | grep -v 'filelists\|other\|group' | head -1)
echo "[信息] primary 路径: $_primary"

curl -fsSL "$EPEL_BASE/$_primary" -o /tmp/primary.xml.gz
yum install -y gzip 2>/dev/null || true

# 从 primary.xml 中找 wine-core / wine-filesystem / wine-common 的 href
echo "[信息] 搜索 wine 包路径..."
gzip -dc /tmp/primary.xml.gz \
    | grep -oP '(?<=href=")[^"]*wine-(core|filesystem|common)[^"]*\.rpm' \
    | sort -u \
    | tee /tmp/wine-hrefs.txt

echo "[信息] 共找到 $(wc -l < /tmp/wine-hrefs.txt) 个 wine 包"

# 下载
mkdir -p /tmp/wine-rpms
while IFS= read -r _href; do
    _fname=$(basename "$_href")
    echo "[信息] 下载 $_fname ..."
    curl -fsSL -o "/tmp/wine-rpms/$_fname" "$EPEL_BASE/$_href"
done < /tmp/wine-hrefs.txt

ls -lh /tmp/wine-rpms/

# 安装（--nodeps 跳过依赖检查，AppImage 在目标机运行时系统库由宿主提供）
echo "[信息] 安装 wine RPM（--nodeps）..."
rpm -ivh --nodeps --force /tmp/wine-rpms/*.rpm

echo "[信息] 已安装包:"
rpm -qa | grep -i wine | sort
echo "[信息] 64位 DLL: $(find /usr/lib64/wine -name '*.dll.so' 2>/dev/null | wc -l) 个"
echo "[信息] 32位 DLL: $(find /usr/lib/wine  -name '*.dll.so' 2>/dev/null | wc -l) 个"
echo "[信息] wine 二进制:"
ls -la /usr/bin/wine* /usr/lib/wine/wine* 2>/dev/null || echo "  (none)"

# ── 构建 AppDir ──────────────────────────────────────────────────────────
AD=/tmp/AppDir
mkdir -p "$AD/usr/bin" "$AD/usr/lib" "$AD/usr/lib64" "$AD/usr/share/wine"

echo "[信息] 收集所有 wine rpm 文件..."
rpm -qa | grep -i wine | xargs -r rpm -ql 2>/dev/null \
    | grep -v '(contains no files)' | sort -u > /tmp/wine-files.txt
echo "[信息] 文件数: $(wc -l < /tmp/wine-files.txt)"

while IFS= read -r f; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    dst="$AD$f"
    mkdir -p "$(dirname "$dst")" || { echo "WARN: mkdir $dst"; continue; }
    cp -a "$f" "$dst" || echo "WARN: cp $f"
done < /tmp/wine-files.txt

# 解析 alternatives 软链（/usr/bin/wine → /etc/alternatives/wine → 实际二进制）
for _bin in wine wine64 wine32 wine32-preloader wine-preloader wineserver wineboot winecfg; do
    _src="/usr/bin/$_bin"
    [ -e "$_src" ] || continue
    _real=$(readlink -f "$_src" 2>/dev/null)
    if [ -n "$_real" ] && [ -f "$_real" ]; then
        rm -f "$AD/usr/bin/$_bin"
        cp "$_real" "$AD/usr/bin/$_bin" && chmod +x "$AD/usr/bin/$_bin"
        echo "[信息] 解析 $_src -> $_real"
    fi
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
echo "=== AppDir 摘要 ==="
echo "  二进制 : $(ls "$AD/usr/bin/wine"* 2>/dev/null | tr '\n' ' ')"
echo "  64位 DLL: $(find "$AD/usr/lib64/wine" -name '*.dll.so' 2>/dev/null | wc -l) 个"
echo "  32位 DLL: $(find "$AD/usr/lib/wine"  -name '*.dll.so' 2>/dev/null | wc -l) 个"
echo "  AppDir 大小: $(du -sh "$AD" | cut -f1)"

# 打包
AT=/tmp/appimagetool.AppImage
curl -fsSL -o "$AT" \
    https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage
chmod +x "$AT"

ARCH=x86_64 APPIMAGE_EXTRACT_AND_RUN=1 "$AT" "$AD" "/output/wine-staging-fixed.AppImage"
echo "✓ 完成：/output/wine-staging-fixed.AppImage"
INNER_SCRIPT

"$DOCKER" run --rm \
    -v "$OUTPUT_DIR:/output" \
    -v "$WRAPPER:/src/wrapper:ro" \
    -v "$INNER:/build.sh:ro" \
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
