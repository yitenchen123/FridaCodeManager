/*
 BuildPipeline.swift

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

 构建管线：把「源码 → 可安装包」拆成明确、可诊断的阶段，
 每一步都校验返回值，失败即中止并给出可操作的原因。
 */

import Foundation

// MARK: - 构建产物目录

/// 构建时必须排除的目录。
///
/// 对应 Xcode 不会参与编译的目录：DerivedData / build / Pods 产物，
/// 以及 FCM 自己的中间产物（Payload、clang、.fcm-cache）。
/// 不排除它们会把上次构建的副本再次编译，表现为链接时 duplicate symbol，
/// 或者“明明没改代码却重新编译了一堆文件”。
let buildIgnoredDirectories: [String] = [
    ".git", "build", "Build", "Payload", "clang", ".fcm-cache", ".fcm-errors",
    "node_modules", "DerivedData", "Pods", ".build", "Resources"
]

/// 把 api.api 里的用户在忽略项与内置忽略项合并
func makeBuildIgnoreList(_ userIgnore: String) -> [String] {
    var result: [String] = []
    for item in splitAndTrim(userIgnore) + buildIgnoredDirectories {
        let trimmed = item.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.isEmpty || trimmed == "." { continue }
        if !result.contains(trimmed) { result.append(trimmed) }
    }
    return result
}

/// 判断相对路径是否落在忽略项内。
/// 支持两种写法：
///   - "Resources"     匹配任意层级下名为 Resources 的目录
///   - "Sources/Generated" 匹配该前缀目录
func isPathIgnored(_ relativePath: String, prefixes: [String]) -> Bool {
    let path = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    for raw in prefixes {
        let prefix = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if prefix.isEmpty { continue }
        if prefix.contains("/") {
            if path == prefix || path.hasPrefix(prefix + "/") { return true }
        } else if path == prefix || path.hasPrefix(prefix + "/") ||
                    path.split(separator: "/").contains(where: { $0 == Substring(prefix) }) {
            return true
        }
    }
    return false
}

// MARK: - 构建阶段

enum BuildStage: String {
    case setup      = "准备"
    case ci         = "CI 准备"
    case headers    = "扫描头文件"
    case compile    = "编译"
    case link       = "链接"
    case bundle     = "打包 .app"
    case sign       = "签名"
    case package    = "生成安装包"
    case verify     = "校验产物"

    var display: String { return rawValue }
}

/// 构建失败时携带的详细信息
struct BuildFailure {
    var stage: BuildStage
    var reason: String
    var detail: String
    var hint: String

    var message: String {
        var text = "[\(stage.display)] 失败：\(reason)"
        if !detail.isEmpty {
            text += "\n\n" + detail
        }
        if !hint.isEmpty {
            text += "\n\n建议：" + hint
        }
        return text
    }
}

// MARK: - 工具：带返回值的命令执行

struct CommandResult {
    var code: Int
    var output: String
    var succeeded: Bool { return code == 0 }
}

/// 执行 shell 命令并捕获输出。绝不静默失败。
func runCaptured(_ command: String, uid: uid_t = 501, env: [String] = [], timeout: Int = 900) -> CommandResult {
    // 所有临时文件都落在 container/tmp 下；这里必须确保目录存在，
    // 否则重定向本身就会失败，命令还没跑就返回非零。
    cfolder(atPath: "\(global_container)/tmp")
    let logPath = "\(global_container)/tmp/fcm-cmd-\(UUID()).log"
    let wrapped = command + " > '" + logPath + "' 2>&1"
    let code = shell(wrapped, uid: uid, env: env)
    var text = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
    _ = rm(logPath)
    if text.count > 4000 {
        text = "…（前面省略）\n" + String(text.suffix(4000))
    }
    return CommandResult(code: code, output: text.trimmingCharacters(in: .whitespacesAndNewlines))
}

/// 把字节数格式化成人类可读的大小
func readableSize(_ path: String) -> String {
    let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.intValue ?? 0
    if size <= 0 { return "0 B" }
    return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
}

// MARK: - 环境校验

struct ToolchainStatus {
    var clangPath: String?
    var swiftcPath: String?
    var ldidPath: String?
    var tarPath: String?
    var zipPath: String?

    var missing: [String] {
        var list: [String] = []
        if clangPath == nil { list.append("clang-14") }
        if ldidPath == nil { list.append("ldid") }
        if zipPath == nil { list.append("zip") }
        return list
    }

    var ready: Bool { return missing.isEmpty }
}

func detectToolchain() -> ToolchainStatus {
    let fm = FileManager.default
    func find(_ candidates: [String]) -> String? {
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    // rootless 下 jbroot = /var/jb；roothide 下 jbroot 是另一个前缀。
    // 只写死 /var/jb 会在 roothide 设备上误报“找不到 clang/ldid”。
    func candidates(_ names: [String]) -> [String] {
        var paths: [String] = []
        for name in names {
            paths.append("\(jbroot)/usr/bin/\(name)")
            paths.append("/var/jb/usr/bin/\(name)")
            paths.append("/usr/bin/\(name)")
        }
        return paths
    }

    var status = ToolchainStatus()
    status.clangPath = find(candidates(["clang-14", "clang"]))
    status.swiftcPath = find(candidates(["swiftc"]))
    status.ldidPath = find(candidates(["ldid"]))
    status.tarPath = find(candidates(["tar"]))
    status.zipPath = find(candidates(["zip"]))
    return status
}

// MARK: - Info.plist 构建变量

/// 展开 Info.plist 里的 `$(PRODUCT_NAME)` / `$(EXECUTABLE_NAME)` 等构建变量。
///
/// Xcode 在拷贝 Info.plist 时会用构建设置替换这些占位符。
/// GitHub 导入的工程普遍使用 `$(EXECUTABLE_NAME)`、`$(PRODUCT_BUNDLE_IDENTIFIER)`，
/// 不展开的话 App 名会直接显示成字面量，甚至影响安装校验。
/// 返回替换的键数量。
func expandInfoPlistBuildVariables(at plistPath: String,
                                   executableName: String,
                                   finalExecutable: String,
                                   bundleID: String,
                                   config: XcodeBuildConfig) -> Int {
    guard var plist = readPlistDictionary(at: plistPath) else { return 0 }

    let currentVersion = config.currentProjectVersion.isEmpty
        ? "1" : config.currentProjectVersion
    let marketingVersion: String
    if !config.marketingVersion.isEmpty {
        marketingVersion = config.marketingVersion
    } else {
        marketingVersion = (plist["CFBundleShortVersionString"] as? String) ?? "1.0"
    }
    let developmentLanguage = (plist["CFBundleDevelopmentRegion"] as? String) ?? "en"

    let replacements: [String: String] = [
        "EXECUTABLE_NAME": finalExecutable,
        "TARGET_NAME": executableName,
        "PRODUCT_NAME": executableName,
        "PRODUCT_MODULE_NAME": safeModuleName(executableName),
        "PRODUCT_BUNDLE_IDENTIFIER": bundleID,
        "CURRENT_PROJECT_VERSION": currentVersion,
        "MARKETING_VERSION": marketingVersion,
        "DEVELOPMENT_LANGUAGE": developmentLanguage,
        "SRCROOT": config.sourceRoot
    ]

    var replaced = 0

    func expandString(_ value: String) -> String {
        var result = value
        for (key, replacement) in replacements {
            for token in ["$(" + key + ")", "${" + key + "}"] {
                if result.contains(token) {
                    replaced += result.components(separatedBy: token).count - 1
                    result = result.replacingOccurrences(of: token, with: replacement)
                }
            }
        }
        return result
    }

    func walk(_ value: Any) -> Any {
        if let string = value as? String {
            return expandString(string)
        }
        if let dictionary = value as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, child) in dictionary {
                result[key] = walk(child)
            }
            return result
        }
        if let array = value as? [Any] {
            return array.map { walk($0) }
        }
        return value
    }

    plist = walk(plist) as? [String: Any] ?? plist
    guard writePlistDictionary(plist, to: plistPath) else { return 0 }
    return replaced
}

// MARK: - 产物校验

/// CPU 类型 → 架构名（Mach-O 头里的 cputype）
private func machoArchName(_ cpuType: UInt32) -> String? {
    switch cpuType {
    case 0x0100000C: return "arm64"
    case 0x0200000C: return "arm64_32"
    case 0x0000000C: return "armv7"
    case 0x01000007: return "x86_64"
    case 0x00000007: return "i386"
    default: return nil
    }
}

/// 读取 thin Mach-O 的 filetype（1=object, 2=execute, 6=dylib, 8=bundle）。
/// 用于区分“需要嵌入 .app/Frameworks 的动态 framework”与静态 framework。
func machoFileType(_ path: String) -> UInt32? {
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { handle.closeFile() }
    let header = handle.readData(ofLength: 16)
    guard header.count == 16 else { return nil }
    let bytes = [UInt8](header)
    guard bytes[0] == 0xCF && bytes[1] == 0xFA && bytes[2] == 0xED && bytes[3] == 0xFE else {
        return nil   // 静态库是 ar 归档，动态 fat 二进制这里也不处理
    }
    return UInt32(bytes[12]) | (UInt32(bytes[13]) << 8)
        | (UInt32(bytes[14]) << 16) | (UInt32(bytes[15]) << 24)
}

/// 读取 Fat 二进制里的所有架构
private func fatArchitectures(_ handle: FileHandle, is64: Bool) -> [String] {
    let header = handle.readData(ofLength: 8)
    guard header.count == 8 else { return [] }
    let hb = [UInt8](header)
    let count = Int((UInt32(hb[4]) << 24) | (UInt32(hb[5]) << 16) | (UInt32(hb[6]) << 8) | UInt32(hb[7]))
    let entrySize = is64 ? 32 : 20
    var archs: [String] = []

    for index in 0..<min(count, 64) {
        handle.seek(toFileOffset: UInt64(8 + index * entrySize))
        let entry = handle.readData(ofLength: 4)
        guard entry.count == 4 else { break }
        let e = [UInt8](entry)
        let cpu = (UInt32(e[0]) << 24) | (UInt32(e[1]) << 16) | (UInt32(e[2]) << 8) | UInt32(e[3])
        if let name = machoArchName(cpu), !archs.contains(name) {
            archs.append(name)
        }
    }
    return archs
}

/// 检查产物是否是目标架构的真实 Mach-O。
///
/// 与之前只看 magic 的实现相比，这里会继续解析 cputype：
/// 把 x86_64 / i386 的库误链进来说成 arm64，最终只会在设备启动时崩溃。
func verifyMachO(_ path: String, expectedArch: String = "arm64") -> (Bool, String) {
    guard FileManager.default.fileExists(atPath: path) else {
        return (false, "文件不存在：\(path)")
    }
    let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.intValue ?? 0
    if size < 4096 {
        return (false, "文件过小（\(size) 字节），链接可能未完成")
    }

    guard let handle = FileHandle(forReadingAtPath: path) else {
        return (false, "无法读取文件")
    }
    defer { handle.closeFile() }
    let head = handle.readData(ofLength: 8)
    guard head.count == 8 else { return (false, "文件头不完整") }

    let bytes = [UInt8](head)
    let isMachO64LE = bytes[0] == 0xCF && bytes[1] == 0xFA && bytes[2] == 0xED && bytes[3] == 0xFE
    let isMachO32LE = bytes[0] == 0xCE && bytes[1] == 0xFA && bytes[2] == 0xED && bytes[3] == 0xFE
    let isFat32    = bytes[0] == 0xCA && bytes[1] == 0xFE && bytes[2] == 0xBA && bytes[3] == 0xBE
    let isFat64    = bytes[0] == 0xCA && bytes[1] == 0xFE && bytes[2] == 0xBA && bytes[3] == 0xBF

    guard isMachO64LE || isMachO32LE || isFat32 || isFat64 else {
        return (false, "不是有效的 Mach-O（文件头 \(head.map { String(format: "%02X", $0) }.joined(separator: " "))）")
    }

    if isFat32 || isFat64 {
        handle.seek(toFileOffset: 0)
        let archs = fatArchitectures(handle, is64: isFat64)
        if archs.isEmpty {
            return (false, "Universal 二进制里没有可识别的 iOS 架构")
        }
        if !expectedArch.isEmpty && !archs.contains(expectedArch) {
            return (false, "架构为 \(archs.joined(separator: "、"))，期望 \(expectedArch)")
        }
        return (true, "Universal（\(archs.joined(separator: "、"))）")
    }

    // thin Mach-O：cputype 在文件偏移 4，filetype 在偏移 12
    handle.seek(toFileOffset: 0)
    let header = handle.readData(ofLength: 16)
    guard header.count == 16 else { return (false, "Mach-O 头不完整") }
    let hb = [UInt8](header)
    let cpu = UInt32(hb[4]) | (UInt32(hb[5]) << 8) | (UInt32(hb[6]) << 16) | (UInt32(hb[7]) << 24)
    guard let arch = machoArchName(cpu) else {
        return (false, String(format: "未知 CPU 类型 0x%08X", cpu))
    }

    // filetype：1 = object，2 = execute，6 = dylib
    let fileType = UInt32(hb[12]) | (UInt32(hb[13]) << 8) | (UInt32(hb[14]) << 16) | (UInt32(hb[15]) << 24)
    if fileType != 2 && fileType != 6 {
        return (false, "Mach-O 类型为 \(fileType)，不是可执行文件")
    }

    if !expectedArch.isEmpty && arch != expectedArch {
        return (false, "架构为 \(arch)，期望 \(expectedArch)")
    }
    return (true, arch)
}

/// 校验 .app 目录结构是否完整
func verifyAppBundle(_ appPath: String) -> (Bool, [String]) {
    let fm = FileManager.default
    var problems: [String] = []

    let infoPlist = "\(appPath)/Info.plist"
    if !fm.fileExists(atPath: infoPlist) {
        problems.append("缺少 Info.plist")
    } else if let info = readPlistDictionary(at: infoPlist) {
        let exec = info["CFBundleExecutable"] as? String ?? ""
        if exec.isEmpty {
            problems.append("Info.plist 缺少 CFBundleExecutable")
        } else if !fm.fileExists(atPath: "\(appPath)/\(exec)") {
            problems.append("可执行文件缺失：\(exec)")
        }
        if (info["CFBundleIdentifier"] as? String ?? "").isEmpty {
            problems.append("Info.plist 缺少 CFBundleIdentifier")
        }
    } else {
        problems.append("Info.plist 无法解析")
    }
    return (problems.isEmpty, problems)
}

/// 检查脚本阶段产出的 Java 相关目录是否有内容
/// 很多工程（Air2 就是）依赖 App.app/Java/*.jar 才能启动，
/// jar 缺失时 App 会崩溃，但 Xcode 不会报错，需要在打包前拦下来。
func verifyJavaArtifacts(_ appPath: String) -> (ok: Bool, notes: [String]) {
    let fm = FileManager.default
    var notes: [String] = []
    var hasJar = false

    for sub in ["Java", "libs", "java_runtimes"] {
        let dir = "\(appPath)/\(sub)"
        guard fm.fileExists(atPath: dir) else { continue }
        let entries = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
        let jars = entries.filter { $0.hasSuffix(".jar") }
        if !jars.isEmpty {
            hasJar = true
            notes.append("\(sub)/：\(jars.count) 个 jar（" + jars.prefix(4).joined(separator: "、") + "）")
        } else if !entries.isEmpty {
            notes.append("\(sub)/：\(entries.count) 项（无 jar）")
        }
    }

    // 有 Java 源码但产物里没有 jar → 脚本阶段可能失败了
    return (hasJar || notes.isEmpty, notes)
}

// MARK: - 签名

enum SignMode {
    case ldidEntitlements(String)   // 越狱：用 entitlements 签名
    case adhoc                      // 仅 ad-hoc
    case none
}

/// 用 ldid 签名，返回是否成功与错误
func signBinary(_ binary: String, entitlements: String?, ldid: String) -> (Bool, String) {
    // ldid 的 -S 后面可以直接跟 entitlements 文件；没有文件时只用 -S（ad-hoc）。
    // 之前写成 -S- 会把它当成“从 stdin 读 entitlements”，在没有输入时会卡住/失败。
    var command = shellQuote(ldid) + " -S"
    if let ent = entitlements, FileManager.default.fileExists(atPath: ent) {
        command += shellQuote(ent)
    }
    command += " " + shellQuote(binary)

    // 先以普通用户尝试，失败再提权（entitlements 文件常属于 root）
    var result = runCaptured(command, uid: 501)
    if !result.succeeded {
        let elevated = runCaptured(command, uid: 0)
        if elevated.succeeded {
            result = elevated
        }
    }
    if result.succeeded {
        return (true, "")
    }
    var hint = result.output
    if hint.contains("No such file") {
        hint = "可执行文件不存在，通常是链接阶段没有产出"
    } else if hint.isEmpty {
        hint = "ldid 无输出（退出码 \(result.code)）"
    }
    return (false, hint)
}

// MARK: - 打包

/// 把 .app 打成 ipa（Payload/<name>.app 结构）
func packageIPA(appBundle: String, output: String, zipPath: String?) -> (Bool, String) {
    let fm = FileManager.default
    let workDir = "\(global_container)/tmp/fcm-pkg-\(UUID())"
    let payload = "\(workDir)/Payload"
    let appName = (appBundle as NSString).lastPathComponent

    _ = rm(workDir)
    cfolder(atPath: payload)

    do {
        try fm.copyItem(atPath: appBundle, toPath: "\(payload)/\(appName)")
    } catch {
        _ = rm(workDir)
        return (false, "复制 .app 失败：\(error.localizedDescription)")
    }

    // 清理无用残留
    for junk in [".DS_Store", "fcm-failed-files.txt"] {
        _ = rm("\(payload)/\(appName)/\(junk)")
    }

    _ = rm(output)

    // 优先进程内 libzip：越狱设备不一定装了 zip，
    // 而 libzip.a 已经链接进 FCM，功能完全等价且不受 PATH 影响。
    var failureText = ""
    if let zip = zipPath, FileManager.default.isExecutableFile(atPath: zip) {
        let result = runCaptured("cd '\(workDir)' && '\(zip)' -r -q -y '\(output)' Payload", uid: 501)
        failureText = result.output
        if result.succeeded && fm.fileExists(atPath: output) {
            _ = rm(workDir)
            return (true, "")
        }
    }

    let libzipCode = libzip_zip(payload, output, true)
    _ = rm(workDir)
    guard libzipCode == 0, fm.fileExists(atPath: output) else {
        if !failureText.isEmpty {
            return (false, failureText)
        }
        return (false, "zip 与 libzip 都无法生成 ipa（libzip 返回 \(libzipCode)）")
    }
    return (true, "")
}
