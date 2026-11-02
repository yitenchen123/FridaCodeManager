/*
 BuildDiagnostics.swift

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

 构建前诊断：在真正编译之前，把已知会导致失败的条件全部检查一遍，
 一次性列出问题，而不是让用户逐个试错。

 检查项：
   · 工具链（clang / ldid / zip / tar）
   · Xcode 工程配置能否读取
   · 头文件搜索路径是否覆盖所有 #import "xxx.h"
   · 静态库平台是否正确
   · 框架依赖是否齐全
   · Java 工具链（若工程有 JavaApp）
   · CI 脚本依赖（python3 等）
   · 磁盘空间
 */

import Foundation

// MARK: - 诊断结果

enum DiagnosticLevel: String {
    case error = "错误"
    case warning = "警告"
    case info = "信息"
}

struct DiagnosticItem {
    var level: DiagnosticLevel
    var message: String
    var hint: String = ""
}

struct BuildDiagnosticsReport {
    var items: [DiagnosticItem] = []

    var errorCount: Int { return items.filter { $0.level == .error }.count }
    var warningCount: Int { return items.filter { $0.level == .warning }.count }
    var hasBlockingIssue: Bool { return errorCount > 0 }

    mutating func error(_ message: String, hint: String = "") {
        items.append(DiagnosticItem(level: .error, message: message, hint: hint))
    }
    mutating func warn(_ message: String, hint: String = "") {
        items.append(DiagnosticItem(level: .warning, message: message, hint: hint))
    }
    mutating func info(_ message: String) {
        items.append(DiagnosticItem(level: .info, message: message))
    }

    func formatted() -> String {
        guard !items.isEmpty else { return "构建前检查：未发现问题" }
        var lines: [String] = ["构建前检查：\(errorCount) 个错误，\(warningCount) 个警告"]
        for item in items {
            var line = "[\(item.level.rawValue)] \(item.message)"
            if !item.hint.isEmpty {
                line += "\n          → \(item.hint)"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - 主入口

/// 执行构建前诊断，返回报告
func runBuildDiagnostics(projectPath: String) -> BuildDiagnosticsReport {
    var report = BuildDiagnosticsReport()
    let fm = FileManager.default

    // ---- 1) 工具链 ----
    let toolchain = detectToolchain()
    if toolchain.clangPath == nil {
        report.error("找不到 clang", hint: "apt install clang-14")
    }
    if toolchain.ldidPath == nil {
        report.error("找不到 ldid，无法签名", hint: "apt install ldid")
    }
    if toolchain.zipPath == nil {
        report.warn("找不到 zip，将改用 libzip 打包", hint: "apt install zip")
    }
    if let clang = toolchain.clangPath {
        report.info("clang: \(clang)")
    }

    // ---- 2) Xcode 工程配置 ----
    let config = loadXcodeBuildConfig(projectPath: projectPath)
    if config.sourceFound {
        report.info("Xcode 工程：\(config.headerSearchPaths.count) 个头文件路径，"
                    + "\(config.otherLDFlags.count) 条链接参数")
        if config.headerSearchPaths.isEmpty {
            report.warn("工程没有 HEADER_SEARCH_PATHS，头文件可能找不到",
                        hint: "在 Xcode 的 Build Settings 里配置，或让 FCM 退回目录扫描")
        }
    } else {
        report.warn("没有找到 .xcodeproj，将使用目录扫描推断头文件路径")
    }

    // ---- 3) 头文件覆盖检查 ----
    let missingHeaders = checkMissingHeaders(projectPath: projectPath, config: config)
    if !missingHeaders.isEmpty {
        let sample = missingHeaders.prefix(5).joined(separator: "、")
        report.warn("有 \(missingHeaders.count) 个头文件可能找不到：\(sample)",
                    hint: "检查 HEADER_SEARCH_PATHS 是否包含这些头文件所在目录")
    }

    // ---- 4) 静态库平台 ----
    let ignoreList = makeBuildIgnoreList("")
    let libs = collectIOSStaticLibraries(projectPath: projectPath, ignorePrefixes: ignoreList)
    let xcfLibs = collectIOSStaticFromXCFrameworks(projectPath: projectPath, ignorePrefixes: ignoreList)
    let allLibs = libs + xcfLibs
    report.info("可用静态库 \(allLibs.count) 个")

    // 探测是否存在被排除的非 iOS 库
    if let all = try? fm.subpathsOfDirectory(atPath: projectPath) {
        let ignored = makeBuildIgnoreList("")
        let foreign = all.filter {
            $0.hasSuffix(".a") && !allLibs.contains($0) && !isPathIgnored($0, prefixes: ignored)
        }
        if !foreign.isEmpty {
            let sample = foreign.prefix(3).joined(separator: "、")
            report.info("已排除非 iOS 静态库 \(foreign.count) 个（如 \(sample)）")
        }
    }

    // ---- 5) Java 工程 ----
    let javaAppDir = "\(projectPath)/JavaApp"
    if fm.fileExists(atPath: javaAppDir) {
        let java = detectJavaToolchain(projectPath: projectPath)
        if java.ready {
            report.info("JDK：\(java.version)（\(java.source)）")
        } else {
            let jars = findPrebuiltJars(projectPath: projectPath)
            if !jars.isEmpty {
                report.info("没有 JDK，但已有 \(jars.count) 个预编译 jar，将跳过 Java 编译")
            } else {
                report.warn("工程有 JavaApp 但设备上没有 JDK",
                            hint: "设置 > Java 环境 导入 JDK，或把编好的 jar 放到 JavaApp/build/")
            }
        }
    }

    // ---- 6) CI 脚本依赖 ----
    let ciSteps = ciPrepSteps(for: projectPath)
    if !ciSteps.isEmpty {
        report.info("检测到 \(ciSteps.count) 个 CI 准备步骤")
        let pythonNeeded = ciSteps.contains { $0.command.contains("python3") || $0.command.contains("python ") }
        if pythonNeeded {
            let hasPython = shell("command -v python3 >/dev/null 2>&1", uid: 501, env: []) == 0
            if !hasPython {
                report.warn("CI 步骤需要 python3，但设备上没有",
                            hint: "apt install python3")
            }
        }
    }

    // ---- 7) 构建脚本阶段 ----
    let phases = loadShellBuildPhases(projectPath: projectPath)
    if !phases.isEmpty {
        report.info("检测到 \(phases.count) 个构建脚本阶段")
        for phase in phases {
            let unsupported = detectUnsupportedSteps(phase.script)
            for warning in unsupported {
                report.info("  \(phase.name)：\(warning)")
            }
        }
    }

    // ---- 8) 磁盘空间 ----
    let space = availableDiskSpaceMB()
    if space >= 0 {
        if space < 500 {
            report.error("磁盘剩余空间不足（\(space)MB）",
                         hint: "清理空间后重试，编译中间产物需要数百 MB")
        } else if space < 1500 {
            report.warn("磁盘剩余空间偏少（\(space)MB）", hint: "大工程可能中途写满")
        } else {
            report.info("磁盘剩余 \(space)MB")
        }
    }

    return report
}

// MARK: - 辅助检查

/// 扫描源码里的 #import "xxx.h"，检查是否有找不到的
func checkMissingHeaders(projectPath: String, config: XcodeBuildConfig) -> [String] {
    let fm = FileManager.default
    guard let all = try? fm.subpathsOfDirectory(atPath: projectPath) else { return [] }

    // 收集工程内所有头文件（相对路径 → 目录）
    let ignored = makeBuildIgnoreList("")
    var headerDirs: Set<String> = [""]
    for file in all where file.hasSuffix(".h") || file.hasSuffix(".hh") || file.hasSuffix(".hpp") {
        if isPathIgnored(file, prefixes: ignored) { continue }
        let dir = (file as NSString).deletingLastPathComponent
        headerDirs.insert(dir)
    }

    // 可用的搜索路径：工程配置 + 所有含头文件的目录
    var searchDirs = Set<String>()
    for path in config.headerSearchPaths {
        let relative = path.replacingOccurrences(of: projectPath + "/", with: "")
        searchDirs.insert(relative)
    }
    searchDirs.formUnion(headerDirs)
    searchDirs.insert("")

    var missing = Set<String>()
    let importPattern = "#(?:import|include)\\s+\"([^\"]+\\.h)\""
    guard let regex = try? NSRegularExpression(pattern: importPattern) else { return [] }

    for file in all where file.hasSuffix(".m") || file.hasSuffix(".mm") || file.hasSuffix(".h") {
        let full = "\(projectPath)/\(file)"
        guard let text = try? String(contentsOfFile: full, encoding: .utf8) else { continue }
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard match.numberOfRanges > 1 else { continue }
            let header = ns.substring(with: match.range(at: 1))
            // 检查这个头文件是否在某个已知目录里
            let found = searchDirs.contains { dir in
                let candidate = dir.isEmpty ? header : "\(dir)/\(header)"
                return fm.fileExists(atPath: "\(projectPath)/\(candidate)")
            }
            if !found {
                missing.insert(header)
            }
        }
    }
    return Array(missing).sorted()
}

/// 读取剩余磁盘空间（MB），失败返回 -1
func availableDiskSpaceMB() -> Int {
    let fm = FileManager.default
    guard let attrs = try? fm.attributesOfFileSystem(forPath: global_documents),
          let free = attrs[.systemFreeSize] as? NSNumber else {
        return -1
    }
    return free.intValue / 1024 / 1024
}
