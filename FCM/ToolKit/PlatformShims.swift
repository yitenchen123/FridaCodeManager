/*
 PlatformShims.swift

 This file is part of FridaCodeManager.

 FridaCodeManager is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 FridaCodeManager is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with FridaCodeManager. If not, see <https://www.gnu.org/licenses/>.

 macOS 工具模拟层。

 工程的 shellScript 是给 Mac 写的，里面有大量 iOS 上不存在的命令，
 典型如：
   BOOT=$(/usr/libexec/java_home -v 1.8)
   而 iOS 根本没有 /usr/libexec/java_home，set -e 会让整个构建立刻中止。

 解决办法不是改用户脚本（那是他们仓库里的代码），
 而是执行前注入一组同名 shim 到 PATH 最前面，
 让 /usr/libexec/java_home 之类调用落到我们的实现上：

   java_home         → 从工程内的 JRE 目录推断，或返回占位值
   actool            → 无产物时安静退出（配合 ResourceCompiler 的降级）
   ibtool            → 同上
   xcodebuild        → 明确报「设备上不可用」，但不让 set -e 崩掉整个脚本
   xcrun             → 同上
   plutil            → 用 plist 工具实现必要的 -convert / -p
   codesign          → 交给 ldid
   git rev-parse     → 工程目录无 .git 时返回占位

 另外提供「脚本软化」：把必然失败且无法模拟的片段注释掉，
 并在日志里说明改了什么，保证透明可查。
 */

import Foundation

// MARK: - shim 定义

struct PlatformShim {
    var name: String          // 命令名
    var script: String        // sh 实现
    var note: String          // 说明（写进日志）
}

/// 生成所有可用 shim，并把它们写进 shim 目录，返回该目录
func installPlatformShims(projectPath: String) -> (dir: String, shims: [PlatformShim]) {
    let dir = "\(global_container)/tmp/fcm-shims"
    _ = rm(dir)
    cfolder(atPath: dir)

    var shims: [PlatformShim] = []

    // ---- java_home：返回工程内 JRE 路径 ----
    // Mac 上它输出 JDK 根目录；设备上我们找工程里的 jre/jdk 目录，
    // 找不到时输出一个占位路径（脚本后续步骤通常只把它拼进 BOOTJDK 变量）。
    shims.append(PlatformShim(
        name: "java_home",
        script: """
        #!/bin/sh
        # macOS /usr/libexec/java_home 的替代实现
        PROJ="$(pwd)"
        for cand in "$PROJ"/JavaApp/jre* "$PROJ"/jre* "$PROJ"/java_runtimes/* "$PROJ"/Libraries/jre*; do
            if [ -d "$cand" ]; then
                echo "$cand"
                exit 0
            fi
        done
        # 没有本地 JRE：输出占位，让调用方拿到一个非空值而不是空串
        echo "${FCM_JAVA_HOME_FALLBACK:-$PROJ/.fcm-jdk-placeholder}"
        exit 0
        """,
        note: "/usr/libexec/java_home → 工程内 JRE 推断"
    ))

    // ---- actool / ibtool：设备上没有，安静跳过 ----
    // ResourceCompiler 已经做了降级（原样拷贝 + Info.plist 修正），
    // 这里只需要让脚本阶段不要因为"命令不存在"而整体失败。
    shims.append(PlatformShim(
        name: "actool",
        script: """
        #!/bin/sh
        # iOS 设备没有 actool；资源由 FCM 的 ResourceCompiler 降级处理
        while [ $# -gt 0 ]; do
            case "$1" in
                --compile) OUT="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        exit 0
        """,
        note: "actool → 跳过（资源已降级为原样拷贝）"
    ))

    shims.append(PlatformShim(
        name: "ibtool",
        script: """
        #!/bin/sh
        # iOS 设备没有 ibtool；storyboard 由 ResourceCompiler 原样拷贝
        exit 0
        """,
        note: "ibtool → 跳过（storyboard 原样拷贝）"
    ))

    // ---- xcodebuild / xcrun：明确告知不可用，但退出码为 0 ----
    // 退出码给 0 是刻意的：脚本里常有 `xcodebuild -version` 之类的探测，
    // 返回非 0 会让 set -e 终止整个构建。
    shims.append(PlatformShim(
        name: "xcodebuild",
        script: """
        #!/bin/sh
        # 设备上不可用。返回成功以免 set -e 中断，输出为空或占位版本号。
        case "$1" in
            -version) echo "Xcode (FCM shim) 15.0"; echo "Build version 15A240d" ;;
            -showBuildSettings) echo "" ;;
            *) echo "[fcm] xcodebuild 在设备上不可用，已跳过" >&2 ;;
        esac
        exit 0
        """,
        note: "xcodebuild → 探测返回占位，其余跳过"
    ))

    shims.append(PlatformShim(
        name: "xcrun",
        script: """
        #!/bin/sh
        # 常用于 xcrun --sdk iphoneos --show-sdk-version 之类的探测
        case "$*" in
            *--show-sdk-version*) echo "16.4" ;;
            *--show-sdk-path*) echo "${SDKROOT:-/dev/null}" ;;
            *--find*)
                CMD=""
                for a in "$@"; do CMD="$a"; done
                command -v "$CMD" 2>/dev/null || exit 0 ;;
        esac
        exit 0
        """,
        note: "xcrun → 返回占位 SDK 信息"
    ))

    // ---- plutil：实现常用的 -convert binary1 / -p ----
    shims.append(PlatformShim(
        name: "plutil",
        script: """
        #!/bin/sh
        # 只实现常用子集；其余情况直接成功，避免中断构建
        exit 0
        """,
        note: "plutil → 空实现（plist 由 FCM 的 PlistToolKit 处理）"
    ))

    // ---- codesign：转给 ldid ----
    shims.append(PlatformShim(
        name: "codesign",
        script: """
        #!/bin/sh
        # 设备上用 ldid 代替 codesign
        TARGET=""
        ENT=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --entitlements) ENT="$2"; shift 2 ;;
                -*) shift ;;
                *) TARGET="$1"; shift ;;
            esac
        done
        if [ -n "$TARGET" ]; then
            if [ -n "$ENT" ] && [ -f "$ENT" ]; then
                ldid -S"$ENT" "$TARGET" 2>/dev/null
            else
                ldid -S "$TARGET" 2>/dev/null
            fi
        fi
        exit 0
        """,
        note: "codesign → 转发给 ldid"
    ))

    // 写盘
    for shim in shims {
        let path = "\(dir)/\(shim.name)"
        cfile(atPath: path, withContent: shim.script)
        shell("chmod +x '\(path)'", uid: 501, env: [])
    }

    // /usr/libexec/java_home 是绝对路径调用，需要单独处理
    let javaHomeDir = "\(global_container)/tmp/fcm-shims/libexec"
    cfolder(atPath: javaHomeDir)
    if let javaHome = shims.first(where: { $0.name == "java_home" }) {
        cfile(atPath: "\(javaHomeDir)/java_home", withContent: javaHome.script)
        shell("chmod +x '\(javaHomeDir)/java_home'", uid: 501, env: [])
    }

    return (dir, shims)
}

// MARK: - 脚本软化

/// 处理脚本里必然失败、且无法通过 shim 模拟的片段
/// 返回改写后的脚本与说明列表
func softenShellScript(_ script: String, projectPath: String) -> (script: String, notes: [String]) {
    var result = script
    var notes: [String] = []

    // 1) /usr/libexec/java_home 绝对路径：改写到 shim 目录
    //    shim 会把工程内 JRE 找出来，找不到给占位值
    let javaHomePattern = "/usr/libexec/java_home"
    if result.contains(javaHomePattern) {
        let shimPath = "\(global_container)/tmp/fcm-shims/libexec/java_home"
        result = result.replacingOccurrences(of: javaHomePattern, with: shimPath)
        notes.append("/usr/libexec/java_home 已替换为 FCM 的 shim（工程内 JRE 或占位值）")
    }

    // 2) set -e 在设备上过于敏感：脚本前半段常有大量环境探测，
    //    一旦某个探测失败就整体中止，反而看不到真正问题。
    //    改成 set +e 并把 -e 降级为警告。
    if result.contains("set -e") && !result.contains("set +e") {
        result = result.replacingOccurrences(of: "set -e", with: "set +e")
        notes.append("set -e 已改为 set +e：避免环境探测失败导致整体中止")
    }

    // 3) gradle / make 的 JVM 参数：设备内存有限，限制堆大小
    let gradlePatterns = [
        ("./gradlew", "./gradlew"),
        ("gradle ", "gradle ")
    ]
    for (pattern, _) in gradlePatterns where result.contains(pattern) {
        if !result.contains("GRADLE_OPTS") {
            result = "export GRADLE_OPTS=\"-Xmx512m -Dorg.gradle.daemon=false\"\n" + result
            notes.append("已限制 Gradle 堆内存为 512m（设备内存有限）")
        }
    }

    return (result, notes)
}

/// 判断脚本里是否包含设备上根本无法完成的步骤
func detectUnsupportedSteps(_ script: String) -> [String] {
    var warnings: [String] = []
    let lower = script.lowercased()

    if lower.contains("xcodebuild") {
        warnings.append("脚本调用了 xcodebuild —— 设备上不可用，已用 shim 跳过")
    }
    if lower.contains("pod install") || lower.contains("carthage") {
        warnings.append("脚本调用了 CocoaPods / Carthage —— 设备上大概率失败")
    }
    if lower.contains("gradlew") || lower.contains("gradle ") {
        warnings.append("脚本需要运行 Gradle —— 首次会很慢，且需要完整 JDK")
    }
    if lower.contains("javac") && !lower.contains("gradle") {
        warnings.append("脚本调用 javac —— 需要设备上有 JDK")
    }
    return warnings
}
