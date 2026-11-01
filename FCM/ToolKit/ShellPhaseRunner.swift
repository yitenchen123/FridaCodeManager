/*
 ShellPhaseRunner.swift

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

 执行工程里的 PBXShellScriptBuildPhase。

 这是 Xcode 处理「GitHub 上下载下来的源码」的关键环节：
 很多项目把预编译依赖的下载、Java 核心的编译、运行时资源的拷贝
 都放在脚本阶段里，而不是提交进 git。
 不执行这些阶段，就会缺文件（Air2 的 fetch_deps.py / JRE 就是如此）。

 Xcode 在执行脚本时会注入一批环境变量，这里也尽量对齐：
   SRCROOT / PROJECT_DIR / BUILD_DIR / BUILT_PRODUCTS_DIR
   TARGET_BUILD_DIR / CONFIGURATION / SDKROOT / ARCHS
 */

import Foundation

// MARK: - 数据结构

struct ShellBuildPhase {
    var name: String
    var script: String
    var shellPath: String
}

// MARK: - 解析

/// 从 project.pbxproj 里提取所有 PBXShellScriptBuildPhase
func loadShellBuildPhases(projectPath: String) -> [ShellBuildPhase] {
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(atPath: projectPath) else { return [] }
    guard let projDir = entries.first(where: { $0.hasSuffix(".xcodeproj") }) else { return [] }

    let pbxproj = "\(projectPath)/\(projDir)/project.pbxproj"
    guard let text = try? String(contentsOfFile: pbxproj, encoding: .utf8) else { return [] }

    var phases: [ShellBuildPhase] = []

    // 匹配一个完整的 PBXShellScriptBuildPhase 对象块
    //   <UUID> /* name */ = {
    //       isa = PBXShellScriptBuildPhase;
    //       ...
    //       name = "...";
    //       shellPath = /bin/sh;
    //       shellScript = "...";
    //   };
    let blockPattern = "\\{\\s*isa = PBXShellScriptBuildPhase;([\\s\\S]*?)\\n\\t\\t\\};"
    guard let blockRegex = try? NSRegularExpression(pattern: blockPattern) else { return [] }
    let ns = text as NSString

    for match in blockRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
        guard match.numberOfRanges > 1 else { continue }
        let body = ns.substring(with: match.range(at: 1))

        let name = extractPBXString("name", from: body) ?? "未命名脚本"
        let shellPath = extractPBXString("shellPath", from: body) ?? "/bin/sh"
        guard let script = extractPBXString("shellScript", from: body), !script.isEmpty else { continue }

        // 跳过「只做代码签名」这类由 FCM 自己处理的阶段
        let lower = (name + script).lowercased()
        if lower.contains("codesign") && lower.contains("ldid") {
            continue
        }

        phases.append(ShellBuildPhase(name: name,
                                      script: script,
                                      shellPath: shellPath.trimmingCharacters(in: .whitespaces)))
    }
    return phases
}

/// 从对象块里取出某个字符串字段，并还原 pbxproj 的转义
private func extractPBXString(_ key: String, from body: String) -> String? {
    // 形式一：key = "....";   （可能跨行，含 \" \\ \n 转义）
    let quotedPattern = "\\b" + key + "\\s*=\\s*\"((?:[^\"\\\\]|\\\\.)*)\";"
    if let regex = try? NSRegularExpression(pattern: quotedPattern, options: [.dotMatchesLineSeparators]) {
        let ns = body as NSString
        if let match = regex.firstMatch(in: body, range: NSRange(location: 0, length: ns.length)),
           match.numberOfRanges > 1 {
            let raw = ns.substring(with: match.range(at: 1))
            return unescapePBX(raw)
        }
    }
    // 形式二：key = /bin/sh;   （不带引号）
    let barePattern = "\\b" + key + "\\s*=\\s*([^;\"\\n]+);"
    if let regex = try? NSRegularExpression(pattern: barePattern) {
        let ns = body as NSString
        if let match = regex.firstMatch(in: body, range: NSRange(location: 0, length: ns.length)),
           match.numberOfRanges > 1 {
            return ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
        }
    }
    return nil
}

/// 还原 pbxproj 字符串里的转义序列
private func unescapePBX(_ raw: String) -> String {
    var result = ""
    var iterator = raw.makeIterator()
    while let ch = iterator.next() {
        guard ch == "\\" else {
            result.append(ch)
            continue
        }
        guard let next = iterator.next() else { break }
        switch next {
        case "n": result.append("\n")
        case "t": result.append("\t")
        case "r": result.append("\r")
        case "\"": result.append("\"")
        case "\\": result.append("\\")
        case "0": result.append("\0")
        default:
            result.append("\\")
            result.append(next)
        }
    }
    return result
}

// MARK: - 执行

/// 按顺序执行脚本阶段，返回是否全部成功
/// 环境变量尽量对齐 Xcode 的注入，脚本里用 ${SRCROOT} 之类才不会失效
func runShellBuildPhases(_ phases: [ShellBuildPhase],
                         projectPath: String,
                         appPath: String,
                         configuration: String,
                         log: (String) -> Void) -> Bool {
    guard !phases.isEmpty else { return true }

    let buildDir = "\(global_container)/tmp/fcm-build-dir"
    cfolder(atPath: buildDir)

    // Xcode 在这些位置放产物；脚本常引用 ${BUILT_PRODUCTS_DIR}
    let productsDir = appPath.isEmpty ? buildDir : (appPath as NSString).deletingLastPathComponent
    let targetBuildDir = productsDir

    // 安装 macOS 工具模拟层：java_home / actool / xcodebuild / codesign 等
    // 没有这层，工程脚本里的 macOS 专属命令会让 set -e 直接中止构建。
    let shimInstall = installPlatformShims(projectPath: projectPath)
    for shim in shimInstall.shims {
        log("  兼容处理：\(shim.note)")
    }

    var allSucceeded = true

    for (index, phase) in phases.enumerated() {
        log("[\(index + 1)/\(phases.count)] \(phase.name)")

        // 先探测脚本里有哪些步骤设备上做不了，提前告知
        for warning in detectUnsupportedSteps(phase.script) {
            log("  注意：\(warning)")
        }

        // 脚本写到文件再执行：内容可能有几十 KB，
        // 作为 bash -c 的单参数会超出 posix_spawn 限制。
        let scriptFile = "\(global_container)/tmp/fcm-phase.sh"
        _ = rm(scriptFile)

        // 注入 Xcode 风格的表头，让 ${SRCROOT} 之类的变量可用
        var body = "#!/bin/sh\nset +e\n"
        body += "export SRCROOT=\"\(projectPath)\"\n"
        body += "export PROJECT_DIR=\"\(projectPath)\"\n"
        body += "export PROJECT_FILE_PATH=\"\(projectPath)\"\n"
        body += "export SRCROOT=\"\(projectPath)\"\n"
        body += "export BUILD_DIR=\"\(buildDir)\"\n"
        body += "export BUILT_PRODUCTS_DIR=\"\(productsDir)\"\n"
        body += "export TARGET_BUILD_DIR=\"\(targetBuildDir)\"\n"
        body += "export CONFIGURATION=\"\(configuration)\"\n"
        body += "export ARCHS=\"arm64\"\n"
        body += "export PLATFORM_NAME=\"iphoneos\"\n"
        body += "export EFFECTIVE_PLATFORM_NAME=\"-iphoneos\"\n"
        body += "export TARGET_NAME=\"\((appPath as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: ""))\"\n"
        // shim 目录放最前，让 java_home / actool / codesign 等落到我们的实现
        body += "export PATH=\"" + shimInstall.dir + ":/var/jb/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH\"\n"
        body += "cd \"\(projectPath)\"\n"

        // 软化脚本：替换 macOS 专属路径、降级 set -e、限制 Gradle 内存
        let softened = softenShellScript(phase.script, projectPath: projectPath)
        if !softened.notes.isEmpty {
            for note in softened.notes {
                log("  已处理：\(note)")
            }
        }

        body += "\n"
        body += softened.script
        body += "\n"

        cfile(atPath: scriptFile, withContent: body)
        shell("chmod +x '\(scriptFile)'", uid: 501, env: [])

        let result = runCaptured("'\(scriptFile)'", uid: 501)
        _ = rm(scriptFile)

        if result.succeeded {
            log("  ✓ 完成")
            if !result.output.isEmpty {
                let trimmed = result.output.count > 600 ? String(result.output.suffix(600)) : result.output
                log(trimmed)
            }
        } else {
            log("  ✗ 失败（退出码 \(result.code)）")
            if !result.output.isEmpty {
                let trimmed = result.output.count > 1200 ? String(result.output.suffix(1200)) : result.output
                log(trimmed)
            }
            allSucceeded = false
            // 单个脚本失败不中断整个构建：有些阶段是可选的
            log("  已跳过，继续后续阶段")
        }
    }
    return allSucceeded
}

// MARK: - SPM 支持

/// 判断工程是否有 Swift Package 依赖
func hasSwiftPackageDependencies(projectPath: String) -> Bool {
    let fm = FileManager.default
    if fm.fileExists(atPath: "\(projectPath)/Package.swift") { return true }
    if fm.fileExists(atPath: "\(projectPath)/Package.resolved") { return true }
    return false
}

/// 尝试解析 SPM 依赖（调用 swift package resolve）
/// 设备上有 swift 工具链时可用；没有则返回说明，不阻断构建
func resolveSwiftPackages(projectPath: String, log: (String) -> Void) -> Bool {
    guard hasSwiftPackageDependencies(projectPath: projectPath) else { return true }

    let fm = FileManager.default
    guard let swift = ["/var/jb/usr/bin/swift", "/usr/bin/swift"]
        .first(where: { fm.isExecutableFile(atPath: $0) }) else {
        log("检测到 Swift Package 依赖，但设备上没有 swift 命令，跳过依赖解析")
        log("安装方式：apt install swift")
        return false
    }

    log("正在解析 Swift Package 依赖…")
    let result = runCaptured("cd '\(projectPath)' && '\(swift)' package resolve", uid: 501)
    if result.succeeded {
        log("依赖解析完成")
        return true
    }
    log("依赖解析失败：")
    log(result.output)
    return false
}
