# FridaCodeManager 简体中文版（含 ZIP 源码导入）

基于 [yitenchen123/FridaCodeManager](https://github.com/yitenchen123/FridaCodeManager)（上游 `emexlab/FridaCodeManager`）的汉化分支，作者已宣布该项目**停止维护**（DEPRECATED）。
本分支在上游 `main` 基础上做了两件事：

1. **全量界面汉化**
2. **新增「从 ZIP 导入」源码包的功能**（另外让文件管理器里的「导入」自动解压 zip）

> ⚠️ 原项目只能在**越狱设备（rootless / roothide，iOS 15.0–18.3.1）或 TrollStore（15.0–17.6.1）**上编译运行，需要 `swift`、`clang-14`、`ldid`、`git`、`unzip`/`zip`。

---

## 一、怎么应用这些修改

### 方式 A：打补丁（推荐，保留上游历史）

```bash
git clone https://github.com/yitenchen123/FridaCodeManager.git
cd FridaCodeManager
patch -p1 < 汉化与ZIP导入.patch      # 或使用仓库根目录的 fcm-zh.patch
```

### 方式 B：直接用完整源码包

解压 `FridaCodeManager-zh-src.tar.gz`（`Blueprint/` 里的 `AppIcon.png`、`tshelper`、SDK 大文件未包含，需从上游补齐，见下文）。

### 编译（与上游一致，必须在越狱设备上用 Makefile）

```bash
make              # rootless 越狱
make roothide     # roothide
make trollstore   # TrollStore（tipa）
```

首次编译前需要补齐缺失的大文件（本补丁包里没有，避免体积过大）：

```bash
# 1. 从上游取回 Blueprint 目录里的原生资源
git checkout origin/main -- Blueprint/FridaCodeManager.app/AppIcon.png \
    Blueprint/FridaCodeManager.app/tshelper \
    "Blueprint/FridaCodeManager.app/Launch Screen.storyboardc"

# 2. SDK（Makefile 的 greet 目标会自动用 iOS15.6 解压到 SDK/）
git checkout origin/main -- FCM/UI/TabBar/Settings/SDKHub/sdk/
```

---

## 二、汉化内容一览

| 模块 | 说明 |
|---|---|
| 底部标签栏 | 主页 / 项目 / 设置 |
| 主页 | 更新日志、新建工程、导入工程、从 ZIP 导入、关于 |
| 新建工程弹窗 | 应用名称、包标识符、类型（应用/二进制）、Swift / ObjC / Swift+ObjC / Swift+C++ / C |
| 项目列表 | 分组标题（应用/工具）、导出 App、导出工程、工程设置、删除 |
| 工程页 / 文件管理器 | 构建、宏、GitHub 菜单、新建、重命名、复制、移动、粘贴、分享、删除；文件夹、SDK 列表 |
| 工程设置 | 应用信息（应用名/显示名/BundleID/版本/最低部署版本）、外观（图标、屏幕方向限制）、SDK |
| 构建页 / 控制台 | 日志、问题导航器、文件：/行号：、致命错误、构建成功 |
| 代码编辑器 | 主题（默认/暮色/午夜）、高级显示设置、跳转到行、查找字符串、工具栏、自动补全、高亮当前行 |
| 设置 | 默认 SDK、高级、附加工具（SDK 中心 / SF 符号 / 清理工具）、实验性功能（GitHub、日志系统）、缩进、作者 |
| 弹窗 | 取消 / 确认 / 提交 / 关闭 / 复制 / 已复制 |
| 构建日志 | 查找源码、查找框架、准备编译器、编译、打包 .ipa、安装 等阶段提示 |
| 默认作者名 | `Anonym` → `匿名` |

> 未翻译的部分：内部 `print` 调试日志、commit 关键字（`succeed/note/warning/error` 是 clang 输出解析用的，**不能翻译**）、算法用的正则、文件名/路径常量、SF Symbol 名。

---

## 三、新增功能：从 ZIP 导入源码

### 3.1 入口一：主页 →「从 ZIP 导入」（导入成一个**新工程**）

调用链：

```
Home.swift:  .fileImporter(.zip, .archive)  →  handleZipImport()  →  importProjectArchive(target:)
                                                        ↓
ProjectImport.swift:  解压到 tmp/<UUID> → 识别结构 → 安装为新工程 → Documents/<UUID>/
```

支持的三种压缩包结构：

| 压缩包内容 | 处理方式 |
|---|---|
| 已经是 FCM 工程（含 `Resources/DontTouchMe.plist`），外层可能多套了一层目录 | 直接安装为新工程，并自动补全缺失的 `Info.plist` / `DontTouchMe.plist` / `entitlements.plist`，SDK 用系统默认值 |
| 只有一个根目录，里面是普通源码（如 `Sources/…`） | 生成工程外壳：`Source/` 存放源码 + 自动生成 `Info.plist`、`DontTouchMe.plist`、`entitlements.plist`，可执行文件名取自压缩包名 |
| 根目录散着源码（如 `main.c`、`*.m`+`*.h`） | 同上，按「二进制类工程」处理 |

安全点：

* 不会把用户打开的文件移走（先拷到 tmp 解压，成功后拷进 Documents）
* 支持 iOS 安全作用域（`startAccessingSecurityScopedResource`）
* 解压优先用 `/var/jb/usr/bin/unzip`，失败退回内置 `libzip_unzip`，再失败用 root 重试
* 导入过程中首页显示「正在导入…」遮罩，结束后弹窗提示结果并自动刷新项目列表

### 3.2 入口二：工程内文件管理器 → 右上角「…」→「导入文件 / ZIP」

`UIFileList.swift` 里的 `DocumentPicker` 已改：选中 `.zip` 时**解压到当前目录**，而不是把 zip 文件本身丢进去；
若包内只套了一层与压缩包同名的目录（`xxx-master/`、`xxx-main/` 会一并识别），会自动剥掉这层，避免导入后多一级目录；同名文件自动跳过并在提示里说明。

对应实现：`ProjectImport.swift → importArchiveInto(directory:archive:)`

### 3.3 新增文件

| 文件 | 作用 |
|---|---|
| `FCM/ToolKit/ProjectImport.swift` | ZIP 导入的全部逻辑（约 500 行，`unzip`/`zip` 后端选择、工程识别与外壳生成、结果模型 `ImportOutcome`） |

---

## 四、注意事项

* `make` 用的是 `swiftc -warnings-as-errors`，本补丁已按 Swift 5.5 兼容写法（不用 `if let x {` 简写）。
* 新增源码文件会被 Makefile 的 `find ./FCM/ -name '*.swift'` 自动带上，**不需要**改 Makefile。
* `.zip`/`.archive` 这两个 `UTType` 需要 `import UniformTypeIdentifiers`，`Home.swift` 原本就有。
* 上游代码本身未经本仓库编译验证（iOS 越狱工具链不在本环境内）；如编译报错请把日志贴出来。

## 五、许可

沿用上游 GPL-3.0（见 `LICENSE`）。
