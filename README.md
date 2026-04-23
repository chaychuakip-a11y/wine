# wine-staging-fixed.AppImage

基于 [mmtrt/WINE_AppImage](https://github.com/mmtrt/WINE_AppImage) staging 11.6 修复版，解决多用户权限冲突和 AppRun 递归执行问题。

## 问题背景

### 1. `/tmp` 多用户冲突

AppImage type-2 runtime 启动时在 `$TMPDIR`（默认 `/tmp`）下创建 `.mount_<名称><随机>` 挂载目录（权限 700）。多用户共享机器时：

- 用户 A 的进程崩溃留下 `/tmp/.mount_wineXXXXXX`（属主 A，700 权限）
- 用户 B 无法删除，下次启动若随机后缀碰撞则失败
- `/tmp` 中残留大量孤儿目录

### 2. `wrapper` 中 `$progHome` 未定义

原版第 11 行：
```bash
export DXVK_CONFIG_FILE=${DXVK_CONFIG_FILE:-"$progHome/dxvk.conf"}
```
`$progHome` 从未定义，展开为空，实际路径变成 `/dxvk.conf`（根目录），普通用户无写权限。

### 3. AppRun 递归执行

以下场景会导致 AppRun 被反复触发，表现为一个 exe 跑完后又重跑：

- AppImage 被放入 `$PATH` 且命名为 `wine`
- 系统通过 `binfmt_misc` 把 `.exe` 注册给本 AppImage
- wine/wineserver 派生子进程时通过 `$WINE` 或 xdg-open 再次解析到 AppImage
- `"$MAIN" "$@"` 是 fork（非 exec），父 shell 退出后 AppImage unmount 再 mount

## 修复内容

### `wrapper`（内层，重打包进 AppImage）

```diff
+# Per-user state dir
+progHome="${XDG_CACHE_HOME:-$HOME/.cache}/wine-appimage-staging"
+mkdir -p "$progHome" 2>/dev/null
+
+# 递归 guard：已在 AppImage 树内则直接 exec wine，不重走挂载+setup
+if [ "${__WINE_APPIMAGE_ACTIVE:-0}" = "1" ] && [ -x "$APPDIR/usr/bin/wine" ] ; then
+    exec "$APPDIR/usr/bin/wine" "$@"
+fi
+export __WINE_APPIMAGE_ACTIVE=1
+
 export WINE="$APPDIR/usr/bin/wine"
 ...
-export DXVK_CONFIG_FILE=${DXVK_CONFIG_FILE:-"$progHome/dxvk.conf"}
+export DXVK_CONFIG_FILE=${DXVK_CONFIG_FILE:-"$progHome/dxvk.conf"}   # $progHome 现已定义
 ...
-"$MAIN" "$@"          # fork，父 shell 继续存活
+"exec "$MAIN" "$@"    # exec，父 shell 被替换，无残留
```

### `wine-appimage-launcher.sh`（外层启动脚本）

控制 AppImage runtime 挂载位置（无法在 AppImage 内部改）：

```bash
BASE="${XDG_RUNTIME_DIR:-$HOME/.cache}/wine-appimage"
mkdir -p "$BASE" && chmod 700 "$BASE"
export TMPDIR="$BASE"        # runtime 在此创建 .mount_*，每用户隔离
export __WINE_APPIMAGE_LAUNCHER_ACTIVE=1
exec "$APPIMAGE" "$@"
```

## 文件说明

```
├── wrapper                    已修补的内层启动脚本（build.sh 打包进 AppImage）
├── AppRun.env                 环境变量配置（参考）
├── wine-appimage-launcher.sh  外层启动脚本（控制挂载路径 + 递归 guard）
├── build.sh                   一键下载 → 打补丁 → 重打包
├── install.sh                 系统级共享安装脚本（需要 root）
└── README.md
```

`wine-staging-fixed.AppImage` 通过 [Release](https://github.com/chaychuakip-a11y/wine/releases/latest) 下载。

## 安装方式

### 方式一：系统共享安装（推荐多用户场景）

一份 AppImage + 一份 launcher，所有用户共用，各自的挂载点和数据完全隔离：

```bash
# 下载 AppImage
wget -O wine-staging-fixed.AppImage \
  https://github.com/chaychuakip-a11y/wine/releases/download/v11.6-fixed/wine-staging-fixed.AppImage

# 一键安装（需要 root）
sudo bash install.sh

# 任意用户直接使用
wine foo.exe
wine winecfg
WINEPREFIX=~/.mywine wine setup.exe
```

安装后文件布局：
```
/opt/wine-staging-fixed.AppImage   AppImage 本体（root 只读，所有用户共享）
/usr/local/bin/wine                launcher（所有用户共用同一个脚本）
```

每个用户运行时各自拥有：
| 目录 | 用途 |
|------|------|
| `/run/user/$UID/wine-appimage/` | FUSE 挂载点（登出自动清理） |
| `~/.wine-appimage-staging/` | WINEPREFIX |
| `~/.cache/wine-appimage-staging/` | DXVK 缓存等 |

### 方式二：单用户安装

```bash
mkdir -p ~/.local/bin
cp wine-staging-fixed.AppImage  ~/.local/bin/
cp wine-appimage-launcher.sh    ~/.local/bin/wine
chmod +x ~/.local/bin/wine ~/.local/bin/wine-staging-fixed.AppImage
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
```

## 回退原版

```bash
# 直接运行原版（挂载回 /tmp，不含递归 guard）
./wine-staging.AppImage notepad.exe

# 或用 APPIMAGE_EXTRACT_AND_RUN 跳过 FUSE（解压到临时目录运行，无 mount）
APPIMAGE_EXTRACT_AND_RUN=1 ./wine-staging-fixed.AppImage notepad.exe
```

## 验证

```bash
wine --version
# wine-11.6 (Staging)

# 确认挂载在 XDG_RUNTIME_DIR 而非 /tmp
mount | grep wine
# .../wine-staging-fixed.AppImage on /run/user/1000/wine-appimage/.mount_wine-XXXXXX ...

ls /tmp/.mount_wine* 2>&1
# ls: 无法访问 '/tmp/.mount_wine*': 没有那个文件或目录
```
