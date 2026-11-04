/*
 StaticLibraryResolver.swift

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

 静态库筛选：工程里常同时存在多个平台的预编译库
 （例如 mbedtls 的 lib/ 与 lib-macos/），
 全部链进去会报 "building for iOS, but linking in object file built for macOS"。
 这里按路径特征与 Mach-O 头部实际架构筛选，只保留真正能用于 iOS 的 .a。
 */

import Foundation

// MARK: - 路径特征

/// 明显不属于 iOS 设备的目录名（不区分大小写）
private let kForeignPlatformDirs: [String] = [
    "lib-macos", "lib-mac", "macos", "osx", "darwin",
    "lib-simulator", "simulator", "simulatorarm64", "simulator-x86_64",
    "iphonesimulator", "x86_64", "arm64_x86_64",
    "lib-linux", "linux", "android"
]

private func pathHasForeignPlatform(_ relativePath: String) -> Bool {
    let parts = relativePath.lowercased().split(separator: "/").map(String.init)
    for part in parts {
        if kForeignPlatformDirs.contains(part) { return true }
    }
    return false
}

// MARK: - Mach-O 架构探测

/// 读取 .a 与 Fat 归档的 CPU 类型，判断是否为 iOS 设备（arm64 / armv7）
/// 支持两种布局：
///   1. 标准 ar 归档（!<arch>\n），成员为单个架构的 Mach-O
///   2. Fat/Universal 二进制（0xCAFEBABE），内含多架构切片
func staticLibraryPlatform(_ path: String) -> String? {
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { handle.closeFile() }

    let head = handle.readData(ofLength: 8)
    guard head.count == 8 else { return nil }
    let hb = [UInt8](head)

    // ---- Fat / Universal ----
    if hb[0] == 0xCA && hb[1] == 0xFE && hb[2] == 0xBA && hb[3] == 0xBE {
        return fatBinaryPlatforms(path)
    }

    // ---- 标准 ar 归档 ----
    guard head == Data("!<arch>\n".utf8) else { return nil }
    return archiveMemberPlatform(path)
}

/// 解析 Fat 二进制里包含哪些 CPU 架构，返回第一个匹配的 iOS 架构名
private func fatBinaryPlatforms(_ path: String) -> String? {
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { handle.closeFile() }

    let head = handle.readData(ofLength: 8)
    guard head.count == 8 else { return nil }
    let hb = [UInt8](head)
    // 大端序记数
    let count = (UInt32(hb[4]) << 24) | (UInt32(hb[5]) << 16) | (UInt32(hb[6]) << 8) | UInt32(hb[7])

    var found: [String] = []
    for index in 0..<min(count, 16) {
        let offset = UInt64(8 + Int(index) * 20)
        handle.seek(toFileOffset: offset)
        let entry = handle.readData(ofLength: 20)
        guard entry.count == 20 else { break }
        let e = [UInt8](entry)
        let cpu = (UInt32(e[0]) << 24) | (UInt32(e[1]) << 16) | (UInt32(e[2]) << 8) | UInt32(e[3])
        switch cpu {
        case 0x0100000C: found.append("arm64")
        case 0x0000000C: found.append("armv7")
        case 0x01000007: found.append("x86_64")
        case 0x00000007: found.append("i386")
        default: break
        }
    }
    // 只要含 arm64 或 armv7，就认为可用于 iOS
    if found.contains("arm64") { return "arm64" }
    if found.contains("armv7") { return "armv7" }
    return found.first ?? "fat-unknown"
}

/// 遍历 ar 归档成员，返回第一个 Mach-O 的架构
/// 需要处理两种归档格式：
///   - BSD ar：成员名以 "#1/<N>" 存储，真实名字占数据开头 N 字节
///   - GNU ar：成员名在头部字段里，数据紧接在头之后
private func archiveMemberPlatform(_ path: String) -> String? {
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { handle.closeFile() }

    var offset: UInt64 = 8
    let fileSize = handle.seekToEndOfFile()

    for _ in 0..<32 {
        guard offset + 60 <= fileSize else { break }
        handle.seek(toFileOffset: offset)
        let header = handle.readData(ofLength: 60)
        guard header.count == 60 else { break }

        // 成员大小在偏移 48，长度 10，ASCII 十进制
        guard let sizeText = String(data: header.subdata(in: 48..<58), encoding: .ascii),
              let memberSize = UInt64(sizeText.trimmingCharacters(in: .whitespaces)) else {
            break
        }

        // BSD ar：成员名前 16 字节形如 "#1/<N>"，真实名字占数据前 N 字节
        let nameField = String(data: header.subdata(in: 0..<16), encoding: .ascii) ?? ""
        var nameSkip: UInt64 = 0
        if nameField.hasPrefix("#1/"),
           let n = UInt64(nameField.dropFirst(3).trimmingCharacters(in: .whitespaces)) {
            nameSkip = n
        }

        let memberStart = offset + 60
        let dataStart = memberStart + nameSkip
        guard dataStart + 8 <= fileSize else { break }

        handle.seek(toFileOffset: dataStart)
        let m = handle.readData(ofLength: 8)

        if m.count == 8 {
            let b = [UInt8](m)
            // Mach-O 64 little-endian
            if b[0] == 0xCF && b[1] == 0xFA && b[2] == 0xED && b[3] == 0xFE {
                let cpu = UInt32(b[4]) | (UInt32(b[5]) << 8) | (UInt32(b[6]) << 16) | (UInt32(b[7]) << 24)
                switch cpu {
                case 0x0100000C: return "arm64"
                case 0x0000000C: return "armv7"
                case 0x01000007: return "x86_64"
                case 0x00000007: return "i386"
                default: return String(format: "cpu_0x%08x", cpu)
                }
            }
            // 归档里嵌 Fat 成员
            if b[0] == 0xCA && b[1] == 0xFE && b[2] == 0xBA && b[3] == 0xBE {
                return fatBinaryPlatforms(path)
            }
        }

        offset = memberStart + memberSize
        if offset % 2 == 1 { offset += 1 }
    }
    return nil
}

// MARK: - 主入口

/// 收集工程内可用于 iOS 的静态库
/// 规则：
///   1. 排除路径里带 macos/simulator 等字样的
///   2. 保留 Mach-O 架构为 arm64 / armv7 的
///   3. 架构无法判断时，按路径规则保留（避免误删）
func collectIOSStaticLibraries(projectPath: String, ignorePrefixes: [String]) -> [String] {
    let fm = FileManager.default
    // 流式遍历：工程里带 JRE / Pods 时，subpathsOfDirectory 会一次性
    // 把几万个路径装进数组，2GB 设备上很容易被系统杀掉。
    guard let enumerator = fm.enumerator(atPath: projectPath) else { return [] }

    let ignoreList = makeBuildIgnoreList("") + ignorePrefixes
    var result: [String] = []

    for case let file as String in enumerator {
        // 用户配置的忽略项 + 构建产物目录
        if isPathIgnored(file, prefixes: ignoreList) {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: "\(projectPath)/\(file)", isDirectory: &isDir), isDir.boolValue {
                enumerator.skipDescendants()
            }
            continue
        }
        guard file.hasSuffix(".a") else { continue }

        // 路径明显属于其他平台
        if pathHasForeignPlatform(file) { continue }

        let full = "\(projectPath)/\(file)"
        if let platform = staticLibraryPlatform(full) {
            if platform == "arm64" || platform == "armv7" {
                result.append(file)
            }
            // 其余架构（x86_64 / i386 / 未知 CPU）直接排除
        } else {
            // 读不出架构时保守保留，避免漏掉有效库
            result.append(file)
        }
    }
    return result.sorted()
}

/// 直接读取文件头的 CPU 类型（单个 Mach-O 或 Fat）
func machoPlatformOnly(_ path: String) -> String? {
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { handle.closeFile() }
    let head = handle.readData(ofLength: 8)
    guard head.count == 8 else { return nil }
    let b = [UInt8](head)

    if b[0] == 0xCA && b[1] == 0xFE && b[2] == 0xBA && b[3] == 0xBE {
        return fatBinaryPlatforms(path)
    }
    if b[0] == 0xCF && b[1] == 0xFA && b[2] == 0xED && b[3] == 0xFE {
        let cpu = UInt32(b[4]) | (UInt32(b[5]) << 8) | (UInt32(b[6]) << 16) | (UInt32(b[7]) << 24)
        switch cpu {
        case 0x0100000C: return "arm64"
        case 0x0000000C: return "armv7"
        case 0x01000007: return "x86_64"
        default: return nil
        }
    }
    return nil
}

/// 处理 .xcframework 里的静态库二进制
/// xcframework 内部结构：
///   libterracotta.xcframework/
///     ios-arm64/
///       libterracotta.a        ← 我们要的
///       Headers/
///     ios-arm64_x86_64-simulator/
///       libterracotta.a        ← 排除
func collectIOSStaticFromXCFrameworks(projectPath: String, ignorePrefixes: [String]) -> [String] {
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(atPath: projectPath) else { return [] }
    let ignoreList = makeBuildIgnoreList("") + ignorePrefixes

    var result: [String] = []
    for case let entry as String in enumerator {
        if isPathIgnored(entry, prefixes: ignoreList) {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: "\(projectPath)/\(entry)", isDirectory: &isDir), isDir.boolValue {
                enumerator.skipDescendants()
            }
            continue
        }
        guard entry.hasSuffix(".xcframework") else { continue }

        let xcfPath = "\(projectPath)/\(entry)"
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: xcfPath, isDirectory: &isDir), isDir.boolValue else { continue }

        // 内部结构由下面手动遍历，不必再让 enumerator 往里走
        enumerator.skipDescendants()

        // 枚举里层 slice 目录
        guard let slices = try? fm.contentsOfDirectory(atPath: xcfPath) else { continue }
        for slice in slices where slice.hasPrefix("ios-") {
            // 只要设备切片，排除 simulator
            if slice.contains("simulator") { continue }
            let slicePath = "\(xcfPath)/\(slice)"

            guard let files = try? fm.contentsOfDirectory(atPath: slicePath) else { continue }
            for file in files where file.hasSuffix(".a") {
                let full = "\(slicePath)/\(file)"
                if let platform = staticLibraryPlatform(full),
                   platform != "arm64" && platform != "armv7" {
                    continue
                }
                // 转换成工程内相对路径，与其它库保持一致的引用方式
                let relative = "\(entry)/\(slice)/\(file)"
                if !result.contains(relative) {
                    result.append(relative)
                }
            }
        }
    }
    return result.sorted()
}

/// 收集可用的 .framework 及其二进制路径（只收 arm64 的）
func collectIOSFrameworks(projectPath: String, ignorePrefixes: [String]) -> [(name: String, path: String)] {
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(atPath: projectPath) else { return [] }
    let ignoreList = makeBuildIgnoreList("") + ignorePrefixes

    var seen = Set<String>()
    var result: [(String, String)] = []

    for case let entry as String in enumerator {
        if isPathIgnored(entry, prefixes: ignoreList) {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: "\(projectPath)/\(entry)", isDirectory: &isDir), isDir.boolValue {
                enumerator.skipDescendants()
            }
            continue
        }
        guard entry.hasSuffix(".framework") else { continue }
        if pathHasForeignPlatform(entry) { continue }

        let frameworkPath = "\(projectPath)/\(entry)"
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: frameworkPath, isDirectory: &isDir), isDir.boolValue else { continue }

        let name = ((entry as NSString).lastPathComponent as NSString).deletingPathExtension
        if seen.contains(name) { continue }

        let binary = "\(frameworkPath)/\(name)"
        guard fm.fileExists(atPath: binary) else { continue }

        // 只收 arm64 / armv7 的
        if let platform = machoPlatformOnly(binary),
           platform != "arm64" && platform != "armv7" {
            continue
        }
        seen.insert(name)
        result.append((name, binary))
    }
    return result.sorted { $0.0 < $1.0 }
}
