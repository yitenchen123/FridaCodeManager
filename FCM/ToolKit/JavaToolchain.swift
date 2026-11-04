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
    var java8Flags: [String] = []   // 实际可用的 Java 8 编译参数
    var source: String = ""   // 说明来自哪里

    var ready: Bool { return javacPath != nil && jarPath != nil }
}

// MARK: - 探测

/// 探测设备上可用的 JDK。
///
/// Air2 的启动核心必须产出 Java 8 字节码（major 52），这样内嵌的
/// OpenJDK 8/17/21 都能加载。JDK 8 本身用 -source 8 -target 8；
/// 新版本 JDK 优先用 --release 8（会正确限制 API，避免编到不存在的方法）。
/// 因此这里把「能编译 Java 8」当作硬条件，并优先选择 JDK 8。
func detectJavaToolchain(projectPath: String) -> JavaToolchainInfo {
    let fm = FileManager.default
    var info = JavaToolchainInfo()

    var candidates: [(home: String, source: String, priority: Int)] = []
    var seen = Set<String>()

    func addCandidate(_ home: String, _ source: String, priority: Int) {
        // 注意：不能用 trimmingCharacters 去斜杠，那会把 "/usr/lib/jvm/x" 变成
        // 相对路径 "usr/lib/jvm/x"，后面 fileExists 全部失败。
        var normalized = (home as NSString).standardizingPath
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        guard seen.insert(normalized).inserted else { return }
        guard fm.fileExists(atPath: "\(normalized)/bin/javac") else { return }
        candidates.append((normalized, source, priority))
    }

    // ---- 0) 标准 JDK 布局（用户导入 / 工程自带 / 内置）----
    let standardJDKCandidates = [
        ("\(global_documents)/.fcm-jdk", "FCM 目录（用户导入）", 40),
        ("\(projectPath)/.fcm-jdk", "工程目录 .fcm-jdk", 30),
        ("\(projectPath)/jdk8", "工程自带 jdk8", 25),
        ("\(projectPath)/jdk", "工程自带 jdk", 20),
        ("\(Bundle.main.bundlePath)/jdk8", "FCM 内置 JDK", 35)
    ]
    for candidate in standardJDKCandidates {
        addCandidate(candidate.0, candidate.1, priority: candidate.2)
    }

    // ---- 1) 工程自带的 JRE/JDK ----
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

            if fm.fileExists(atPath: "\(full)/bin/javac") {
                addCandidate(full, "工程自带：\(entry)", priority: 15)
            } else if let subs = try? fm.contentsOfDirectory(atPath: full) {
                for sub in subs where fm.fileExists(atPath: "\(full)/\(sub)/bin/javac") {
                    addCandidate("\(full)/\(sub)", "工程自带：\(entry)/\(sub)", priority: 15)
                }
            }
        }
    }

    // ---- 2) 系统路径 ----
    // JAVA_HOME 与 PATH 里的 javac 也要认：Linux 上 JDK 常装在
    // /usr/lib/jvm 之外（如 SDKMAN / mise），而 iOS 上也可能通过 PATH 暴露。
    if let javaHome = ProcessInfo.processInfo.environment["JAVA_HOME"], !javaHome.isEmpty {
        addCandidate(javaHome, "JAVA_HOME", priority: 10)
    }
    let pathDirectories = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
    for directory in pathDirectories {
        let javac = "\(directory)/javac"
        guard fm.fileExists(atPath: javac) else { continue }
        let realJavac = (javac as NSString).resolvingSymlinksInPath
        let home = ((realJavac as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        addCandidate(home, "PATH：\(directory)", priority: 10)
    }

    let systemRoots = [
        "\(jbroot)/usr/lib/jvm", "/var/jb/usr/lib/jvm", "/usr/lib/jvm",
        "\(jbroot)/opt", "/opt"
    ]
    for root in systemRoots {
        guard let entries = try? fm.contentsOfDirectory(atPath: root) else { continue }
        for entry in entries {
            addCandidate("\(root)/\(entry)", "系统安装：\(entry)", priority: 5)
        }
    }

    // ---- 3) 直接的 javac 命令 ----
    for javac in ["\(jbroot)/usr/bin/javac", "/var/jb/usr/bin/javac", "/usr/bin/javac"] {
        guard fm.fileExists(atPath: javac) else { continue }
        let home = ((javac as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        addCandidate(home, "系统 PATH", priority: 5)
    }

    guard !candidates.isEmpty else { return info }

    // ---- 4) 依次评估，优先 JDK 8 ----
    // 按来源优先级从高到低评估：JDK 8 命中后得分必然高于任何非 8 候选
    // （最高 40 + 300 对 40 + 200），可以立刻结束，省掉后续多次 javac 探测。
    let ordered = candidates.enumerated().sorted {
        if $0.element.priority != $1.element.priority {
            return $0.element.priority > $1.element.priority
        }
        return $0.offset < $1.offset
    }.map { $0.element }

    var best: (JavaToolchainInfo, Int)?
    for candidate in ordered {
        var current = JavaToolchainInfo()
        current.home = candidate.home
        current.source = candidate.source
        current.javacPath = "\(candidate.home)/bin/javac"
        current.jarPath = fm.fileExists(atPath: "\(candidate.home)/bin/jar")
            ? "\(candidate.home)/bin/jar" : nil

        // zip 解压出来的 bin 往往没有执行位。
        // 只在 javac 不可执行时才补，而且不做 -R 递归：
        // 递归 chmod 一个 JDK 目录要遍历上万个文件，每次构建都做纯属浪费。
        if !fm.isExecutableFile(atPath: "\(candidate.home)/bin/javac") {
            _ = shell("chmod +x \(shellQuote("\(candidate.home)/bin"))/* 2>/dev/null",
                      uid: 501, env: [])
        }

        let versionResult = runCaptured("\(shellQuote(current.javacPath!)) -version", uid: 501)
        if let range = versionResult.output.range(of: "javac ") {
            current.version = String(versionResult.output[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let major = javaMajorVersion(current.version)

        // 先选参数模式，再真正验证 javac 接受它
        if major == 8 {
            current.java8Flags = ["-source", "8", "-target", "8"]
        } else if major >= 9 {
            let releaseProbe = runCaptured(
                "\(shellQuote(current.javacPath!)) --release 8 -version", uid: 501)
            if releaseProbe.succeeded {
                current.java8Flags = ["--release", "8"]
            } else {
                let sourceTargetProbe = runCaptured(
                    "\(shellQuote(current.javacPath!)) -source 8 -target 8 -version", uid: 501)
                if sourceTargetProbe.succeeded {
                    current.java8Flags = ["-source", "8", "-target", "8"]
                }
            }
        } else if major > 0 {
            // 未知版本号时两种都试
            if runCaptured("\(shellQuote(current.javacPath!)) --release 8 -version", uid: 501).succeeded {
                current.java8Flags = ["--release", "8"]
            } else if runCaptured("\(shellQuote(current.javacPath!)) -source 8 -target 8 -version", uid: 501).succeeded {
                current.java8Flags = ["-source", "8", "-target", "8"]
            }
        }
        current.supportsJava8Target = !current.java8Flags.isEmpty

        guard current.ready, current.supportsJava8Target else { continue }

        // 评分：JDK 8 最高；其余能用 --release 8 的新 JDK 次之；来源优先级做微调
        var score = candidate.priority
        if major == 8 {
            score += 300
        } else if major >= 9 {
            score += 200
        } else {
            score += 100
        }
        if best == nil || score > best!.1 {
            best = (current, score)
        }

        // JDK 8 已经满足硬条件且得分最高，不必再探测其它候选
        if major == 8 { break }
    }

    if let best = best {
        info = best.0
    }
    return info
}

/// 从 javac 版本字符串取出主版本号（"1.8.0_392" → 8，"17.0.9" → 17）
private func javaMajorVersion(_ version: String) -> Int {
    let text = version.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return 0 }
    let parts = text.split(separator: ".")
    if parts.first == "1", parts.count > 1 {
        return Int(parts[1]) ?? 0
    }
    return Int(parts[0]) ?? 0
}

// MARK: - 报告

/// 生成可读的工具链状态说明
func describeJavaToolchain(_ info: JavaToolchainInfo) -> String {
    if !info.ready {
        var text = "未找到可用的 JDK（需要 javac 与 jar）\n"
        text += "安装方式（任选其一）：\n"
        text += "  · 在「设置 > Java 环境」导入 JDK 8（iOS aarch64 版 OpenJDK 8）\n"
        text += "  · 在设备终端执行：apt install openjdk-8（没有则用 openjdk-17）\n"
        text += "  · 把 JDK 解压到 \(global_documents)/.fcm-jdk/ 或 <工程>/.fcm-jdk/\n"
        text += "    （要求含 bin/javac 与 bin/jar）\n"
        text += "  · 工程内放置 java_runtimes/<版本>/ 目录\n"
        return text
    }

    var text = "JDK：\(info.version.isEmpty ? "未知版本" : info.version)\n"
    text += "来源：\(info.source)\n"
    text += "路径：\(info.home ?? "-")\n"
    let flags = info.java8Flags.joined(separator: " ")
    text += "Java 8 目标：\(info.supportsJava8Target ? "支持（\(flags)）" : "不支持")"
    return text
}

/// 生成要传给 Makefile 的 BOOTJDK 值
/// 返回空字符串表示使用 PATH 里的 javac（Makefile 的默认行为）
func bootJDKArgument(for info: JavaToolchainInfo) -> String {
    guard let home = info.home, info.ready else { return "" }
    return home
}
