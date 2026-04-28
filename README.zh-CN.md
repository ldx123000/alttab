<p align="right">
  <a href="./README.md">English</a> | <strong>简体中文</strong>
</p>

<h1 align="center">AltTab</h1>

<p align="center">
  一个小型 macOS 窗口切换工具，让 <kbd>Command</kbd> + <kbd>Tab</kbd> 在“窗口”之间切换，而不是在“应用”之间切换。
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-13%2B-black?style=flat-square&logo=apple&logoColor=white" alt="macOS 13+">
  <img src="https://img.shields.io/badge/Swift-swiftc-F05138?style=flat-square&logo=swift&logoColor=white" alt="Swift swiftc">
  <img src="https://img.shields.io/badge/build-Command_Line_Tools-blue?style=flat-square" alt="Command Line Tools">
  <img src="https://img.shields.io/badge/license-MIT-green?style=flat-square" alt="MIT License">
  <img src="https://img.shields.io/github/stars/ldx123000/alttab?style=flat-square" alt="Stars">
</p>

<p align="center">
  <img src="Screenshots/AltTab1.jpg" alt="AltTab switcher" width="360">
</p>

## 项目简介

AltTab 是一个菜单栏工具，目标是在 macOS 上提供更接近 Windows Alt-Tab 的“按窗口切换”体验。macOS 原生 Command-Tab 是按应用切换；这个工具运行时会接管 Command-Tab，并改为在具体窗口之间切换。

交互尽量贴近 macOS 原生切换器：

- 快速轻按 <kbd>Command</kbd> + <kbd>Tab</kbd>：直接切到下一个窗口，不弹出列表。
- 按下 <kbd>Tab</kbd> 后继续按住 <kbd>Command</kbd>：显示窗口列表并继续选择。
- 松开 <kbd>Command</kbd>：激活当前选中的窗口。

本项目灵感来源于 [sergio-farfan/alttab-macos](https://github.com/sergio-farfan/alttab-macos)，并围绕更简单的本地构建方式和 Command-Tab 行为做了调整。

## 特性

- 运行时覆盖 macOS 原生 Command-Tab
- 短按 Command-Tab 立即切换，不显示列表
- 按住 Command-Tab 显示非激活式浮层切换器
- 支持普通窗口和最小化窗口
- 使用 MRU 顺序，并跟踪同应用内窗口焦点变化
- 通过 Accessibility 读取标题、聚焦、置顶、取消最小化
- 不使用屏幕录制权限，也不截取实时窗口缩略图
- 只依赖 Command Line Tools 和 `swiftc` 构建，不需要完整 Xcode 项目
- 无第三方依赖

## 环境要求

| 要求 | 版本 |
| --- | --- |
| macOS | 13.0 或更高 |
| 构建工具 | Command Line Tools |
| 权限 | Accessibility |

## 构建与安装

只构建：

```bash
./build.sh build
```

构建 DMG 安装包：

```bash
./build.sh dmg
open AltTab/build/dist/AltTab-1.0.dmg
```

安装到 `~/Applications`：

```bash
./build.sh install
open ~/Applications/AltTab.app
```

安装到 `/Applications`：

```bash
sudo ./build.sh install --system
open /Applications/AltTab.app
```

从构建目录直接运行：

```bash
./build.sh run
```

## 权限

如果还没有授予 Accessibility 权限，AltTab 首次启动时会显示一个权限引导窗口。这个权限用于监听键盘事件和管理窗口。

<p align="center">
  <img src="Screenshots/AltTab2.jpg" alt="AltTab guide" width="360">
</p>

可以使用引导窗口里的按钮，也可以手动前往：

```text
系统设置 -> 隐私与安全性 -> 辅助功能 -> AltTab
```

不需要屏幕录制权限。切换器显示应用图标和窗口标题，不显示实时窗口缩略图。

## 快捷键

| 快捷键 | 操作 |
| --- | --- |
| 轻按 <kbd>Command</kbd> + <kbd>Tab</kbd> | 立即切到下一个窗口 |
| 按住 <kbd>Command</kbd> + <kbd>Tab</kbd> | 打开窗口切换器 |
| 按住 Command 时按 <kbd>Tab</kbd> | 向前选择 |
| <kbd>Shift</kbd> + <kbd>Tab</kbd> | 向后选择 |
| <kbd>Left</kbd> / <kbd>Right</kbd> | 移动选中项 |
| 松开 <kbd>Command</kbd> | 激活选中窗口 |
| <kbd>Escape</kbd> | 取消 |
| <kbd>Enter</kbd> | 确认 |
| 点击条目 | 选中该条目 |

## 构建脚本

| 命令 | 说明 |
| --- | --- |
| `./build.sh build` | 使用 `swiftc` 构建 Release app bundle |
| `./build.sh dmg` | 构建包含 `AltTab.app` 和 Applications 快捷方式的 DMG |
| `./build.sh install` | 安装到 `~/Applications` |
| `./build.sh install --system` | 安装到 `/Applications` |
| `./build.sh run` | 构建并从构建目录启动 |
| `./build.sh clean` | 删除构建产物 |
| `./build.sh diagnose-hotkeys` | 查看原生 Command-Tab 热键是否被禁用 |
| `./build.sh restore-hotkeys` | 恢复 macOS 原生 Command-Tab |
| `./build.sh uninstall` | 卸载用户级安装 |
| `./build.sh uninstall --system` | 卸载系统级安装 |

## 实现方式

AltTab 使用 session 级别的 `CGEvent` tap 监听 Command、Tab、方向键、Escape 和 Enter。应用运行期间，它还会通过 SkyLight 私有 API 禁用 macOS 原生 Command-Tab symbolic hotkeys，避免系统应用切换器抢先处理快捷键。

窗口枚举使用 `CGWindowListCopyWindowInfo` 获取可见窗口，并通过 Accessibility 查询最小化窗口。MRU 顺序通过 `NSWorkspace` 应用激活通知和各应用的 `AXObserver` 焦点窗口通知维护。

窗口激活依赖 Accessibility API，用于取消最小化、置顶和聚焦选中窗口。

## 恢复原生 Command-Tab

如果应用异常退出后 macOS 原生 Command-Tab 没有恢复，可以手动执行：

```bash
./build.sh restore-hotkeys
```

查看当前状态：

```bash
./build.sh diagnose-hotkeys
```

## 项目结构

```text
AltTab/AltTab/
├── main.swift              # 应用入口和热键恢复钩子
├── AppDelegate.swift       # 生命周期、状态栏和切换器编排
├── HotkeyManager.swift     # 全局事件 tap 和快捷键状态机
├── NativeCommandTab.swift  # 禁用/恢复原生 Command-Tab
├── WindowModel.swift       # 窗口枚举和 MRU 跟踪
├── WindowActivator.swift   # 置顶、聚焦、取消最小化
├── SwitcherPanel.swift     # 浮层切换器
├── ThumbnailView.swift     # 窗口条目视图
├── PermissionManager.swift # Accessibility 权限流程
└── PreferencesMenu.swift   # 菜单栏操作
```

## 许可证

MIT。见 [LICENSE](./LICENSE)。
