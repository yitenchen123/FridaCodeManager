/*
 JavaToolchain.swift

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

 JDK 探测与配置。

 很多工程（如 Air2）的 Makefile 里写着：
   BOOTJDK ?= $(shell /usr/libexec/java_home -v 1.8 2>/dev/null || echo "")
   JAVAC   := $(if $(BOOTJDK),$(BOOTJDK)/bin/javac,javac)

 也就是说 JDK 8 只是「用来指定编译器」，真正控制字节码版本的是
 编译参数 -source 8 -target 8。任何 JDK 8+ 的 javac 都能产出 major 52。

 所以设备上只需要 javac 和 jar 两个命令可用即可，不必强求 JDK 8。
 这个模块负责：
   1. 按优先级探测设备上的 JDK
   2. 检查是否支持 -source 8 -target 8
   3. 输出可直接透传给 Makefile 的 BOOTJDK 值
   4. 找不到时给出可执行的安装/放置建议
 */

import Foundation

// MARK: - 数据结构

struct JavaToolchainInfo {
    var home: String?         // JDK 根目录（含 bin/javac）
    var javacPath: String?
    var jarPath: String?
    var version: String = ""  // 如 "1.8.0_392" / "17.0.9"
    var supportsJava8Target: Bool = false
    var source: String = ""   // 说明来自哪里

    var ready: Bool { return javacPath != nil && jarPath != nil }
}

// MARK: - 探测

/// 探测设备上可用的 JDK
/// 优先级：
///   1. 工程自带 JRE（java_runtimes/、jre*、JavaApp/jre*）
///   2. 系统路径里的 javac（apt 安装的 openjdk）
///   3. FCM 固定目录（用户手动放置）
func detectJavaToolchain(projectPath: String) -> JavaToolchainInfo {
    let fm = FileManager.default
    var info = JavaToolchainInfo()

    // ---- 0) 优先检查标准 JDK 布局（bin/javac + lib/tools.jar）----
    // 这是完整的 JDK，能真正运行 javac（javac 自身是依赖 tools.jar 的 Java 程序）。
    // 常见放置位置：
    //   <工程>/.fcm-jdk/            FCM 推荐位置
    //   <工程>/jdk8/                工程自带
    //   Documents/.fcm-jdk/         全局共享
    // 用户通过「设置 > Java 环境」导入的 JDK 优先；
    // 其次是工程自带的位置。
    let standardJDKCandidates = [
        "\(global_documents)/.fcm-jdk",   // FCM 导入的目标位置
        "\(projectPath)/.fcm-jdk",
        "\(projectPath)/jdk8",
        "\(projectPath)/jdk",
        "\(Bundle.main.bundlePath)/jdk8"  // 若将来内置则可用
    ]
    for candidate in standardJDKCandidates {
        let javac = "\(candidate)/bin/javac"
        let tools = "\(candidate)/lib/tools.jar"

        // 用「文件存在」而不是「可执行」判断：
        // 从 zip 解压出来的文件是 644，没有执行位，
        // 用 isExecutableFile 会把刚导入的 JDK 直接跳过。
        guard fm.fileExists(atPath: javac) else { continue }

        // 发现 JDK 后补执行权限（幂等）
        shell("chmod -R +x '\(candidate)/bin' 2>/dev/null", uid: 501, env: [])
        #if !stock
        if !fm.isExecutableFile(atPath: javac) {
            shell("chmod -R +x '\(candidate)/bin' 2>/dev/null", uid: 0, env: [])
        }
        #endif

        // 完整 JDK 应同时具备 tools.jar（javac 的实现）
        let isFullJDK = fm.fileExists(atPath: tools)

        info.home = candidate
        info.javacPath = javac
        info.jarPath = fm.fileExists(atPath: "\(candidate)/bin/jar") ? "\(candidate)/bin/jar" : nil
        info.source = isFullJDK ? "标准 JDK（含 tools.jar）" : "JDK 布局"
        if candidate.hasPrefix(Bundle.main.bundlePath) {
            info.source += "，随 FCM 内置"
        }

        let versionResult = runCaptured("'\(javac)' -version", uid: 501)
        if let range = versionResult.output.range(of: "javac ") {
            info.version = String(versionResult.output[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let probe = runCaptured("'\(javac)' -source 8 -target 8 -version", uid: 501)
        info.supportsJava8Target = probe.succeeded
        return info
    }

    // ---- 1) 工程自带的 JRE ----
    var candidates: [(String, String)] = []   // (home, 来源说明)
    let searchRoots = [
        "\(projectPath)/java_runtimes",
        "\(projectPath)/JavaApp",
        "\(projectPath)/Libraries",
        "\(projectPath)"
    ]
    for root in searchRoots {
        guard let entries = try? fm.contentsOfDirectory(atPath: root) else { continue }
        for entry in entries {
            let lower = entry.lowercased()
            guard lower.hasPrefix("jre") || lower.hasPrefix("jdk") || lower.hasPrefix("java") else { continue }
            let full = "\(root)/\(entry)"
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue else { continue }
            // 可能是多版本目录（java_runtimes/8、/17）
            if fm.fileExists(atPath: "\(full)/bin/javac") {
                candidates.append((full, "工程自带：" + entry))
            } else if let subs = try? fm.contentsOfDirectory(atPath: full) {
                for sub in subs where fm.fileExists(atPath: "\(full)/\(sub)/bin/javac") {
                    candidates.append(("\(full)/\(sub)", "工程自带：" + entry + "/" + sub))
                }
            }
        }
    }

    // ---- 2) 系统路径 ----
    let systemRoots = [
        "/var/jb/usr/lib/jvm", "/usr/lib/jvm", "/var/jb/opt", "/opt"
    ]
    for root in systemRoots {
        guard let entries = try? fm.contentsOfDirectory(atPath: root) else { continue }
        for entry in entries {
            let full = "\(root)/\(entry)"
            if fm.fileExists(atPath: "\(full)/bin/javac") {
                candidates.append((full, "系统安装：" + entry))
            }
        }
    }

    // ---- 3) 直接的 javac 命令 ----
    let directJavac = ["/var/jb/usr/bin/javac", "/usr/bin/javac"]
        .first { fm.isExecutableFile(atPath: $0) }
    if let javac = directJavac {
        // 从 /usr/bin/javac 反推 JDK home
        let home = ((javac as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        candidates.append((home, "系统 PATH"))
    }

    // ---- 4) FCM 固定目录（用户手动放置）----
    let userJDK = "\(global_documents)/.fcm-jdk"
    if fm.fileExists(atPath: "\(userJDK)/bin/javac") {
        candidates.append((userJDK, "FCM 目录（用户放置）"))
    }

    guard let chosen = candidates.first else {
        return info
    }

    info.home = chosen.0
    info.source = chosen.1
    info.javacPath = "\(chosen.0)/bin/javac"
    if fm.exists(javac: info.javacPath!) == false {
        info.javacPath = nil
    }
    let jarCandidate = "\(chosen.0)/bin/jar"
    info.jarPath = fm.isExecutableFile(atPath: jarCandidate) ? jarCandidate : nil

    // 读取版本
    if let javac = info.javacPath {
        let result = runCaptured("'\(javac)' -version", uid: 501)
        // javac -version 输出到 stderr，runCaptured 已合并
        let text = result.output
        if let range = text.range(of: "javac ") {
            info.version = String(text[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // 检查能否产出 Java 8 字节码：
        // JDK 9+ 支持 -source 8；JDK 8 本身就支持
        let probe = runCaptured("'\(javac)' -source 8 -target 8 -version", uid: 501)
        info.supportsJava8Target = probe.succeeded
    }

    return info
}

// MARK: - 工具函数

private extension FileManager {
    /// 判断路径是否可执行的小工具
    func exists(javac path: String) -> Bool {
        return isExecutableFile(atPath: path)
    }
}

// MARK: - 报告

/// 生成可读的工具链状态说明
func describeJavaToolchain(_ info: JavaToolchainInfo) -> String {
    if !info.ready {
        var text = "未找到可用的 JDK（需要 javac 与 jar）\n"
        text += "安装方式（任选其一）：\n"
        text += "  · 在设备终端执行：apt install openjdk-17（或 openjdk-11 / openjdk-8）\n"
        text += "  · 把 JDK 解压到 \(global_documents)/.fcm-jdk/ 或 <工程>/.fcm-jdk/\n"
        text += "    （要求含 bin/javac 与 lib/tools.jar；iOS aarch64 版 OpenJDK 8 可用）\n"
        text += "  · 工程内放置 java_runtimes/<版本>/ 目录\n"
        return text
    }

    var text = "JDK：\(info.version.isEmpty ? "未知版本" : info.version)\n"
    text += "来源：\(info.source)\n"
    text += "路径：\(info.home ?? "-")\n"
    text += "Java 8 目标：\(info.supportsJava8Target ? "支持（-source 8 -target 8）" : "不支持")"
    return text
}

/// 生成要传给 Makefile 的 BOOTJDK 值
/// 返回空字符串表示使用 PATH 里的 javac（Makefile 的默认行为）
func bootJDKArgument(for info: JavaToolchainInfo) -> String {
    guard let home = info.home, info.ready else { return "" }
    return home
}
