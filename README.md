# wine-staging-fixed.AppImage

基于 [mmtrt/WINE_AppImage](https://github.com/mmtrt/WINE_AppImage) staging 11.6 的修复版，
解决多用户共享场景下的权限冲突、变量缺失和递归执行三个问题。

---

## 快速开始（内网）

管理员将以下三个文件放到共享目录（例如 `/home/asrdictt/tyliu23/wine/`）：

```
wine-staging-fixed.AppImage
wine-appimage-launcher.sh
install-user.sh
```

每个用户各自执行一次安装：

```bash
bash /home/asrdictt/tyliu23/wine/install-user.sh
source ~/.bashrc
```

之后直接使用：

```bash
wine foo.exe
wine winecfg
```

---

## 安装详解

### 安装过程做了什么

`install-user.sh` 只操作当前用户的家目录，不需要 root，不影响其他用户：

1. 将 `wine-staging-fixed.AppImage` 复制到 `~/.local/share/wine-appimage/`
2. 将 `wine-appimage-launcher.sh` 安装为 `~/.local/bin/wine`
3. 若 `~/.local/bin` 不在 `$PATH` 中，自动追加到 `~/.bashrc` / `~/.zshrc`

安装完成后的文件布局：

```
~/.local/
├── bin/
│   └── wine                          ← 启动脚本，用户直接调用的入口
└── share/
    └── wine-appimage/
        └── wine-staging-fixed.AppImage
```

每次运行时，各用户私有的目录（自动创建，无需手动操作）：

| 目录 | 说明 |
|------|------|
| `$XDG_RUNTIME_DIR/wine-appimage/`<br>（通常 `/run/user/$UID/wine-appimage/`） | AppImage FUSE 挂载点，登出后由系统自动清理。若系统无 `XDG_RUNTIME_DIR`，自动回退到 `~/.cache/wine-appimage/` |
| `~/.wine-appimage-staging/` | WINEPREFIX，存放 Windows 注册表、C 盘文件等 |
| `~/.cache/wine-appimage-staging/` | DXVK 缓存、shader 缓存等 |

> 以上目录均在各用户自己的 `$HOME` 下，用户之间完全隔离，互不可见。

### 卸载

```bash
bash ~/.local/share/wine-appimage/../../../  # 或直接：
bash /home/asrdictt/tyliu23/wine/install-user.sh --uninstall
```

卸载只删除 AppImage 和 launcher，**不会删除** `~/.wine-appimage-staging/`（Wine 数据）。

---

## 日常使用

### 基本用法

```bash
# 打开 Wine 配置界面
wine winecfg

# 运行一个 exe
wine /path/to/程序.exe

# 运行带参数的程序
wine /path/to/程序.exe --参数1 --参数2

# 查看 Wine 版本
wine --version
# 输出：wine-11.6 (Staging)
```

### 使用独立的 WINEPREFIX

默认 WINEPREFIX 是 `~/.wine-appimage-staging/`，不同程序可以用独立的环境互不干扰：

```bash
# 为某个程序单独建一个 Wine 环境
WINEPREFIX=~/.wine-myapp wine winecfg
WINEPREFIX=~/.wine-myapp wine /path/to/程序.exe

# 32 位程序专用环境
WINEPREFIX=~/.wine-32bit WINEARCH=win32 wine winecfg
WINEPREFIX=~/.wine-32bit wine /path/to/32bit程序.exe
```

### 调用 Wine 内置工具

```bash
# 控制面板 / 配置
wine winecfg          # Wine 配置
wine control          # Windows 控制面板
wine regedit          # 注册表编辑器
wine taskmgr          # 任务管理器
wine uninstaller      # 添加/删除程序

# 文件操作
wine explorer         # 资源管理器
wine notepad          # 记事本
wine wordpad          # 写字板
wine cmd              # Windows 命令行

# wineserver 管理
wineserver -k         # 终止当前 WINEPREFIX 的所有 Wine 进程
wineserver -w         # 等待所有 Wine 进程结束
```

> 注意：`wineserver` 也由 launcher 管理，直接执行 `wineserver` 即可，无需指定路径。

### 安装 Windows 软件

```bash
# 直接运行安装程序
wine /path/to/setup.exe

# 静默安装（部分程序支持）
wine /path/to/setup.exe /S

# 安装完成后，程序通常可以在 ~/.wine-appimage-staging/drive_c/ 下找到
ls ~/.wine-appimage-staging/drive_c/Program\ Files/
```

### 常用环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `WINEPREFIX` | `~/.wine-appimage-staging` | Wine 数据目录 |
| `WINEARCH` | `win64` | Windows 架构，可设为 `win32` |
| `WINEDEBUG` | `fixme-all` | 调试信息级别，`-all` 可完全静默 |
| `DXVK_HUD` | `0` | DXVK 性能叠加层，`1` 开启 |
| `DXVK_LOG_LEVEL` | `none` | DXVK 日志级别 |

```bash
# 示例：静默运行，使用独立前缀
WINEPREFIX=~/.wine-game WINEDEBUG=-all wine game.exe

# 示例：开启 DXVK 性能显示
DXVK_HUD=1 wine game.exe
```

---

## 问题排查

### 确认挂载点不在 /tmp

```bash
wine winecfg &
sleep 2
mount | grep wine
# 正常输出（挂载在用户私有目录）：
# .../wine-staging-fixed.AppImage on /run/user/1001/wine-appimage/.mount_wine-XXXXXX ...
#
# 不应出现：
# .../wine-staging-fixed.AppImage on /tmp/.mount_wine-XXXXXX ...
```

### 清理残留的 Wine 进程

```bash
wineserver -k         # 优雅终止
# 若无响应：
pkill -u $USER wineserver
pkill -u $USER wine
```

### 清理 WINEPREFIX 重新开始

```bash
rm -rf ~/.wine-appimage-staging
wine winecfg   # 重新初始化
```

### 查看 Wine 运行日志

```bash
WINEDEBUG=+all wine 程序.exe 2>~/wine.log
# 然后查看
cat ~/wine.log | grep -i error
```

---

## 文件说明

| 文件 | 说明 |
|------|------|
| `wine-staging-fixed.AppImage` | 修复版 AppImage，通过 [Release](https://github.com/chaychuakip-a11y/wine/releases/latest) 下载 |
| `wine-appimage-launcher.sh` | 外层启动脚本，控制挂载路径和递归 guard |
| `install-user.sh` | 单用户安装脚本（无需 root） |
| `install.sh` | 系统级安装脚本（需要 root） |
| `build.sh` | 从原版重新构建修复版的脚本 |
| `wrapper` | 已修补的 AppImage 内层脚本（供 build.sh 使用） |
| `AppRun.env` | AppImage 环境变量配置（参考） |

---

## 问题背景与修复原理

### 问题 1：`/tmp` 多用户挂载冲突

AppImage type-2 runtime 启动时在 `$TMPDIR`（默认 `/tmp`）下创建 `.mount_<名称><随机>` 挂载目录，权限为 700。多用户共享机器时：

- 用户 A 的进程崩溃，留下 `/tmp/.mount_wineXXXXXX`（属主 A，700 权限）
- 用户 B 无法删除该目录（无权限），导致 `/tmp` 中积累孤儿目录
- 极端情况下随机后缀碰撞，新挂载失败

**修复**：`wine-appimage-launcher.sh` 在启动 AppImage 前设置：

```bash
BASE="${XDG_RUNTIME_DIR:-$HOME/.cache}/wine-appimage"
export TMPDIR="$BASE"
```

AppImage runtime 读取 `$TMPDIR` 决定挂载位置，从而将每个用户的挂载点隔离到各自的目录下。`XDG_RUNTIME_DIR`（`/run/user/$UID/`）由 systemd 按用户 ID 管理；若系统无此目录则回退到 `~/.cache/wine-appimage/`，两种情况均为用户私有，不会产生冲突。

### 问题 2：`wrapper` 中 `$progHome` 未定义

原版第 11 行引用了从未赋值的 `$progHome`：

```bash
export DXVK_CONFIG_FILE=${DXVK_CONFIG_FILE:-"$progHome/dxvk.conf"}
# $progHome 为空，实际展开为 /dxvk.conf（根目录），普通用户无写权限
```

**修复**：`wrapper` 头部增加定义：

```bash
progHome="${XDG_CACHE_HOME:-$HOME/.cache}/wine-appimage-staging"
mkdir -p "$progHome" 2>/dev/null
```

### 问题 3：AppRun 递归执行

以下情况会导致一个 exe 执行完后又被反复重启：

- AppImage 被放入 `$PATH` 且命名为 `wine`
- 系统通过 `binfmt_misc` 将 `.exe` 注册给本 AppImage
- wine/wineserver 派生子进程时，通过环境变量 `$WINE` 或 xdg-open 再次解析到 AppImage，触发新的完整挂载流程
- 原版 `"$MAIN" "$@"` 是 fork，父 shell 在 wine 退出后仍存活，可能触发后续逻辑

**修复**：内外两层递归 guard：

```bash
# 外层 launcher：
export __WINE_APPIMAGE_LAUNCHER_ACTIVE=1

# 内层 wrapper：检测到已在 AppImage 内则直接 exec wine，跳过挂载和 setup
if [ "${__WINE_APPIMAGE_ACTIVE:-0}" = "1" ] && [ -x "$APPDIR/usr/bin/wine" ]; then
    exec "$APPDIR/usr/bin/wine" "$@"
fi
export __WINE_APPIMAGE_ACTIVE=1

# 末尾改为 exec，父 shell 被替换，无残留
exec "$MAIN" "$@"
```
