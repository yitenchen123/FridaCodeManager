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
func runCaptured(_ command: String, uid: uid_t = 501, timeout: Int = 900) -> CommandResult {
    let logPath = "\(global_container)/tmp/fcm-cmd-\(UUID()).log"
    let wrapped = command + " > '" + logPath + "' 2>&1"
    let code = shell(wrapped, uid: uid, env: [])
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

    var status = ToolchainStatus()
    status.clangPath = find(["/var/jb/usr/bin/clang-14", "/usr/bin/clang-14",
                             "/var/jb/usr/bin/clang", "/usr/bin/clang"])
    status.swiftcPath = find(["/var/jb/usr/bin/swiftc", "/usr/bin/swiftc"])
    status.ldidPath = find(["/var/jb/usr/bin/ldid", "/usr/bin/ldid"])
    status.tarPath = find(["/var/jb/usr/bin/tar", "/usr/bin/tar"])
    status.zipPath = find(["/var/jb/usr/bin/zip", "/usr/bin/zip"])
    return status
}

// MARK: - 产物校验

/// 检查生成的 Mach-O 是否是目标架构
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
    // Mach-O 64 位 magic：0xCFFAEDFE（小端，即文件中的 FE ED FA CF）
    let isMachO64LE = bytes[0] == 0xCF && bytes[1] == 0xFA && bytes[2] == 0xED && bytes[3] == 0xFE
    let isFatLE    = bytes[0] == 0xCA && bytes[1] == 0xFE && bytes[2] == 0xBA && bytes[3] == 0xBE
    let isFatBE    = bytes[0] == 0xBE && bytes[1] == 0xBA && bytes[2] == 0xFE && bytes[3] == 0xCA

    guard isMachO64LE || isFatLE || isFatBE else {
        return (false, "不是有效的 Mach-O（文件头 \(head.map { String(format: "%02X", $0) }.joined(separator: " "))）")
    }
    return (true, isFatLE || isFatBE ? "Universal" : expectedArch)
}

/// 校验 .app 目录结构是否完整
func verifyAppBundle(_ appPath: String) -> (Bool, [String]) {
    let fm = FileManager.default
    var problems: [String] = []

    let infoPlist = "\(appPath)/Info.plist"
    if !fm.fileExists(atPath: infoPlist) {
        problems.append("缺少 Info.plist")
    } else if let info = NSDictionary(contentsOfFile: infoPlist) as? [String: Any] {
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

// MARK: - 签名

enum SignMode {
    case ldidEntitlements(String)   // 越狱：用 entitlements 签名
    case adhoc                      // 仅 ad-hoc
    case none
}

/// 用 ldid 签名，返回是否成功与错误
func signBinary(_ binary: String, entitlements: String?, ldid: String) -> (Bool, String) {
    var command = "'\(ldid)' -S"
    if let ent = entitlements, FileManager.default.fileExists(atPath: ent) {
        command += "'\(ent)'"
    } else {
        command += "-"
    }
    command += " '\(binary)'"

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

    let zip = zipPath ?? "/usr/bin/zip"
    let result = runCaptured("cd '\(workDir)' && '\(zip)' -r -q -y '\(output)' Payload", uid: 501)
    let ok = result.succeeded && fm.fileExists(atPath: output)
    _ = rm(workDir)

    if !ok {
        return (false, result.output.isEmpty ? "zip 打包失败（退出码 \(result.code)）" : result.output)
    }
    return (true, "")
}
