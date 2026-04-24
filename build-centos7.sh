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

# CentOS 7 EOL → vault
sed -i \
    -e 's|^mirrorlist=|#mirrorlist=|g' \
    -e 's|^#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' \
    /etc/yum.repos.d/CentOS-*.repo

# 基础工具 + 32位系统运行库（wine32 依赖）
yum install -y curl file which gzip
# 安装 i686 系统库；忽略失败（可能已内置）
yum install -y \
    glibc.i686 libstdc++.i686 libgcc.i686 \
    zlib.i686 freetype.i686 libpng.i686 2>/dev/null || true

# ── 从 EPEL repodata 解析并下载 wine RPM ────────────────────────────────
# EPEL 7 x86_64 仓库只有 x86_64/noarch 包；i686 包在独立的 i386 仓库。
# 两个仓库都需要。archives.fedoraproject.org 是 EPEL 7 归档地址。
EPEL_X64="https://archives.fedoraproject.org/pub/archive/epel/7/x86_64"
EPEL_I386="https://archives.fedoraproject.org/pub/archive/epel/7/i386"

mkdir -p /tmp/wine-rpms

# 函数：从指定 EPEL repo 下载 wine 包
# 用法: fetch_wine_pkgs <base_url> <tag> <pkg_filter_regex>
fetch_wine_pkgs() {
    local base="$1" tag="$2" filter="$3"
    echo "[信息] [$tag] 获取 repomd.xml ..."
    curl -fsSL "$base/repodata/repomd.xml" -o "/tmp/repomd-${tag}.xml" || {
        echo "[警告] [$tag] 无法访问 $base，跳过" >&2; return 0
    }
    local _primary
    _primary=$(grep -oP '(?<=href=")[^"]+' "/tmp/repomd-${tag}.xml" \
        | grep 'primary' | grep -v 'filelists\|other\|group' | head -1)
    echo "[信息] [$tag] primary: $_primary"
    curl -fsSL "$base/$_primary" -o "/tmp/primary-${tag}.xml.gz"

    echo "[诊断] [$tag] 所有 wine*.rpm:"
    gzip -dc "/tmp/primary-${tag}.xml.gz" \
        | grep -oP '(?<=href=")[^"]*wine[^"]*\.rpm' \
        | sort -u | tee "/tmp/wine-all-${tag}.txt"
    echo "[诊断] [$tag] 共 $(wc -l < "/tmp/wine-all-${tag}.txt") 个包"

    grep -P "$filter" "/tmp/wine-all-${tag}.txt" > "/tmp/wine-dl-${tag}.txt" || true
    echo "[信息] [$tag] 筛选后 $(wc -l < "/tmp/wine-dl-${tag}.txt") 个包待下载"

    while IFS= read -r _href; do
        local _fname
        _fname=$(basename "$_href")
        echo "[信息] [$tag] 下载 $_fname ..."
        curl -fsSL -o "/tmp/wine-rpms/$_fname" "$base/$_href"
    done < "/tmp/wine-dl-${tag}.txt"
}

# x86_64：wine-core, wine-filesystem, wine-common (noarch)
fetch_wine_pkgs "$EPEL_X64" "x64" \
    'wine-(core|filesystem|common)\b.*\.(x86_64|noarch)\.rpm'

# i386：wine-core.i686, wine-filesystem.i686（wine32 本体）
# common 是 noarch，x64 那边已经下了，不用重复
fetch_wine_pkgs "$EPEL_I386" "i386" \
    'wine-(core|filesystem)\b.*\.i686\.rpm'

ls -lh /tmp/wine-rpms/

# 安装所有 RPM（--nodeps 跳过依赖，--force 允许多架构并存）
echo "[信息] 安装 wine RPM（--nodeps --force）..."
rpm -ivh --nodeps --force /tmp/wine-rpms/*.rpm

# 诊断：查看安装结果
echo "[诊断] 安装后所有 wine 可执行文件:"
find /usr -name '*wine*' \( -type f -o -type l \) 2>/dev/null | sort | tee /tmp/wine-bins.txt

echo "[信息] 已安装包:"
rpm -qa | grep -i wine | sort
echo "[信息] 64位 DLL: $(find /usr/lib64/wine -name '*.dll.so' 2>/dev/null | wc -l) 个"
echo "[信息] 32位 DLL: $(find /usr/lib/wine  -name '*.dll.so' 2>/dev/null | wc -l) 个"

# 建立 wine 二进制软链（rpm --nodeps 不执行 %post，alternatives 不会跑）
for _bin in wine wine64 wine32 wine32-preloader wine-preloader wineserver wineboot winecfg; do
    _real=$(find /usr -name "$_bin" -type f 2>/dev/null | head -1)
    [ -n "$_real" ] || continue
    [ -e "/usr/bin/$_bin" ] && continue
    ln -sf "$_real" "/usr/bin/$_bin"
    echo "[信息] 软链: /usr/bin/$_bin -> $_real"
done

echo "[信息] wine 二进制汇总:"
for _b in /usr/bin/wine /usr/bin/wine64 /usr/bin/wine32; do
    [ -e "$_b" ] && file "$_b" || echo "  $_b: 不存在"
done

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

# 解析 alternatives 软链 → 复制真实二进制（不留悬空软链）
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

# ── 打包 32 位系统运行库（目标机可能没装 glibc.i686）────────────────────
# wine32 是 i386 ELF，依赖 32 位 libc/libstdc++ 等；把容器里的一并打进去。
echo "[信息] 打包 32 位系统运行库..."
_lib32_dirs="/lib /usr/lib"
for _pattern in \
        libc.so.6 libm.so.6 libpthread.so.0 libdl.so.2 librt.so.1 \
        libz.so.1 ld-linux.so.2 \
        libstdc++.so.6 libgcc_s.so.1 \
        libfreetype.so.6 libpng15.so.15 libpng16.so.16; do
    for _dir in $_lib32_dirs; do
        # 匹配所有版本（如 libc.so.6.x.y）
        for _f in "$_dir"/${_pattern}*; do
            [ -e "$_f" ] || [ -L "$_f" ] || continue
            cp -a "$_f" "$AD/usr/lib/" 2>/dev/null \
                && echo "[信息]  lib32: $_f" || true
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
# 64 位 ELF 加载路径
export LD_LIBRARY_PATH="\
$APPDIR/usr/lib64:\
$APPDIR/usr/lib64/wine:\
$APPDIR/usr/lib64/wine/x86_64-unix:\
${LD_LIBRARY_PATH:-}"
# 32 位 wine DLL 搜索路径
export WINEDLLPATH="$APPDIR/usr/lib/wine:$APPDIR/usr/lib64/wine"
# wine32 二进制使用 AppDir 内的 32 位系统库（覆盖系统路径）
export WINELOADER="$APPDIR/usr/bin/wine"
# 让 wine32 preloader 能找到 AppDir 内的 i686 系统库
# 32 位 ELF 使用的是 /lib/ld-linux.so.2，LD_LIBRARY_PATH 对它同样生效
export LD_LIBRARY_PATH="\
$APPDIR/usr/lib:\
$APPDIR/usr/lib/wine:\
$APPDIR/usr/lib/wine/i386-unix:\
$LD_LIBRARY_PATH"
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
