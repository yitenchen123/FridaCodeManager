# Xcode 构建系统笔记

> 这份文档是 FCM 实现「像 Xcode 一样构建」的依据，也是排查构建问题的索引。
> 记录在 `FCM/ToolKit/` 下，随源码一起维护。

---

## 一、工程文件结构

```
MyApp.xcodeproj/
├── project.pbxproj          ← 核心，所有配置都在这里
├── project.xcworkspace/     ← 工作区（多工程时用）
├── xcuserdata/              ← 用户个人设置（不进 git）
└── xcshareddata/
    └── xcschemes/           ← 共享 scheme（进 git，CI 用）
```

`project.pbxproj` 是 NeXTSTEP 风格 plist：

```
// !$*UTF8*$!          ← 魔术注释，声明编码
{
  archiveVersion = 1;
  objectVersion = 56;  ← Xcode 14.3+ 用 56
  objects = { ... };
  rootObject = <24位UUID>;
}
```

### objectVersion 对照

| 值 | Xcode 版本 |
|---|---|
| 46 | 3.2 – 8.x |
| 48 | 9 |
| 50 | 10 |
| 51 | 11 |
| 52 | 12 |
| 53 | 13 |
| 55 | 14 |
| **56** | **14.3+（推荐，兼容最广）** |
| 60 | 15 |
| 70 | 16 |
| 77 | 16.3+ |

---

## 二、对象类型

### 工程骨架
- `PBXProject` — 1 个，工程根
- `PBXNativeTarget` — 1..N 个 App / 库 / 测试
- `XCConfigurationList` — 每个 target 一个 + 工程一个
- `XCBuildConfiguration` — Debug / Release × 每个 list

### 文件系统
- `PBXGroup` — 虚拟分组（**path 相对父组**）
- `PBXFileReference` — 单个文件引用
- `PBXFileSystemSynchronizedRootGroup` — Xcode 16+ 目录自动同步

### 构建
| 类型 | 作用 |
|---|---|
| `PBXBuildFile` | 文件参与构建的记录 |
| `PBXSourcesBuildPhase` | 编译哪些源 |
| `PBXResourcesBuildPhase` | 打包哪些资源 |
| `PBXFrameworksBuildPhase` | 链接哪些库 |
| `PBXHeadersBuildPhase` | 公开头文件 |
| `PBXCopyFilesBuildPhase` | 拷贝文件进 .app |
| `PBXShellScriptBuildPhase` | 自定义脚本 |
| `PBXTargetDependency` | 目标间依赖 |

---

## 三、构建阶段执行顺序

1. **解析依赖** — SPM / CocoaPods / 子模块
2. **生成 .app 骨架** — 创建目录，写 Info.plist
3. **资源编译**
   | 输入 | 工具 | 产物 |
   |---|---|---|
   | `.xcassets` | actool | `Assets.car` |
   | `.storyboard` | ibtool | `.storyboardc` |
   | `.xib` | ibtool | `.nib` |
   | `.strings` | copystrings | 二进制 strings |
   | `.png` | copypng | 优化后的 png |
   | 其他 | cp | 原样 |
4. **代码编译**（并行，默认 = CPU 核数）
   - ObjC: `clang -c xxx.m -o xxx.o`
   - Swift: `swiftc -c xxx.swift -o xxx.o`
   - C/C++: `clang -c xxx.c -o xxx.o`
5. **链接** — `clang -o MyApp *.o -framework UIKit -lz ...`
6. **拷贝二进制进 .app**
7. **运行脚本阶段**
8. **签名** — codesign / ldid
9. **生成 dSYM**（视配置）
10. **打包** — Archive → 导出 .ipa

---

## 四、构建设置继承

```
Xcode 内置默认值
  → 工程级 XCBuildConfiguration
    → target 级 XCBuildConfiguration
      → xcconfig 文件
        → 命令行 XXX=YYY
```

`$(inherited)` 表示取上一层的值并拼接。

### 关键设置

**路径**
- `SRCROOT` / `PROJECT_DIR` — 工程根
- `BUILT_PRODUCTS_DIR` — 产物目录
- `SDKROOT` — `iphoneos` / `iphonesimulator`

**头文件（最关键）**
- `HEADER_SEARCH_PATHS` → `-I`
- `USER_HEADER_SEARCH_PATHS` → `-iquote`

**链接**
- `OTHER_LDFLAGS` → `-L` / `-l` / `-Wl,-U,<symbol>`
- `LIBRARY_SEARCH_PATHS` → `-L`
- `FRAMEWORK_SEARCH_PATHS` → `-F`

`-Wl,-U,<symbol>` 表示**允许该符号未定义**，运行时从动态库解析。

**编译**
- `GCC_PREPROCESSOR_DEFINITIONS` → `-D`
- `CLANG_ENABLE_OBJC_ARC` — ARC 开关
- `CLANG_ENABLE_MODULES` — `@import` 支持
- `GCC_OPTIMIZATION_LEVEL` — `0` … `s`

**打包**
- `INFOPLIST_FILE`
- `PRODUCT_BUNDLE_IDENTIFIER`
- `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`
- `IPHONEOS_DEPLOYMENT_TARGET`

---

## 五、签名

### 无签名（CI）
```
CODE_SIGNING_ALLOWED=NO
CODE_SIGNING_REQUIRED=NO
CODE_SIGN_IDENTITY=""
```
产出未签名 .app，用 AltStore / TrollStore 自行签名。

### 越狱（FCM 场景）
```
ldid -S<entitlements.plist> MyApp
```
entitlements 通常需要：
- `platform-application`
- `com.apple.private.security.no-sandbox`
- `get-task-allow`

---

## 六、IPA 结构

```
Payload/
  MyApp.app/
    MyApp                  ← Mach-O
    Info.plist
    PkgInfo                ← "APPL????"
    Assets.car
    LaunchScreen.storyboardc
    Frameworks/            ← 动态库
    _CodeSignature/
```

打包：`cd Payload && zip -r ../MyApp.ipa .`

---

## 七、常见错误对照表

| 现象 | 根因 | 正确做法 |
|---|---|---|
| `Build input file cannot be found` | PBXGroup 的 path 写错（未逐层嵌套） | 每层 path 只写自己那一级 |
| `-framework X: linker input unused` | 把 `-framework` 传给了 `clang -c` | 只在链接阶段传 |
| `building for iOS, but linking in object file built for macOS` | 链接了 macOS 平台的 .a | 按架构筛选，排除 `lib-macos/` |
| `Undefined symbols: _xxx` | 对应 .m 编译失败没产出 .o；或该符号本就该未定义 | 查编译错误；或加 `-Wl,-U,_xxx` |
| `Failed to spawn process` | 长脚本作为 `bash -c` 单参数超限 | 写入文件再执行 |
| 编译"秒完成"、0 个文件 | `hasPrefix("")` 恒为 true | 过滤空字符串 |
| 构建在第 N 个文件突然停 | `bash -e` 遇错即退 | 每条命令 `||` 捕获 |
| 装了但启动闪退 | 签名/entitlements 不匹配 | 检查 ldid 返回值与 entitlement |
| dyld 找不到动态库 | 缺 `LD_RUNPATH_SEARCH_PATHS` | 设为 `@executable_path/Frameworks` |
| 脚本阶段写文件被拒 | Xcode 15+ 脚本沙箱 | `ENABLE_USER_SCRIPT_SANDBOXING = NO` |

---

## 八、FCM 的对应实现

| Xcode 能力 | FCM 模块 |
|---|---|
| 读工程配置 | `XcodeProjectConfig.swift` |
| 生成 pbxproj | `XcodeProjectGenerator.swift` |
| 资源编译 | `ResourceCompiler.swift` |
| 增量编译 | `IncrementalBuild.swift` |
| 静态库平台筛选 | `StaticLibraryResolver.swift` |
| CI 工作流对接 | `CIBridge.swift` |
| 构建阶段与诊断 | `BuildPipeline.swift` |
| 具体编译流程 | `Compiling/SeansBuild.swift` |
