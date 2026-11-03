/*
 ProjectImport.swift

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

 从 zip 源码包导入工程 / 向工程内导入 zip 内容
 */

import Foundation

// MARK: - 导入结果

struct ImportOutcome {
    var ok: Bool
    var message: String
    var projectPath: String?

    static func fail(_ message: String) -> ImportOutcome {
        return ImportOutcome(ok: false, message: message, projectPath: nil)
    }

    static func success(_ message: String, _ projectPath: String?) -> ImportOutcome {
        return ImportOutcome(ok: true, message: message, projectPath: projectPath)
    }
}

// MARK: - 常量

private let kImportStaging = "\(global_container)/tmp"

private let kIgnoredNames: Set<String> = [
    ".DS_Store", "__MACOSX", "Inbox", "savedLayouts.json",
    ".sdk", ".cache", "virtualFS.dat"
]

private let kSourceExtensions: Set<String> = [
    "swift", "m", "mm", "c", "cc", "cpp", "cxx", "h", "hh", "hpp", "hxx",
    "s", "metal", "storyboard", "xib", "plist", "api", "xcconfig", "entitlements",
    // 有些 GitHub 仓库的原生侧很少，核心逻辑全在 Java（如 Air2 / Pojav 系）
    "java", "kt", "kts", "gradle", "cmake", "mk"
]

/// 识别 GitHub 仓库使用的构建系统，用于导入后的提示与构建路径选择。
private func detectProjectBuildSystems(_ directory: String) -> [String] {
    let fm = FileManager.default
    var systems: [String] = []

    if let location = discoverXcodeProject(projectPath: directory) {
        let name = (location.projectBundle as NSString).lastPathComponent
        systems.append("Xcode 工程 \(name)")
    }
    if fm.fileExists(atPath: "\(directory)/Package.swift") {
        systems.append("Swift Package")
    }
    if fm.fileExists(atPath: "\(directory)/Podfile") {
        systems.append("CocoaPods")
    }
    if projectNeedsJavaBuild(directory) {
        systems.append("Java 启动核心")
    }
    if fm.fileExists(atPath: "\(directory)/CMakeLists.txt") {
        systems.append("CMake")
    } else if let enumerator = fm.enumerator(atPath: directory) {
        // 嵌套的 CMake 工程也很常见（Natives/CMakeLists.txt）
        var visited = 0
        for case let relative as String in enumerator {
            visited += 1
            if visited > 400 { break }
            if relative.hasSuffix("CMakeLists.txt") {
                systems.append("CMake（\(relative)）")
                break
            }
        }
    }
    if fm.fileExists(atPath: "\(directory)/Makefile") {
        systems.append("Makefile")
    }
    return systems
}

/// 系统自带的 zip 工具（越狱设备一定有，TrollStore 设备由系统 dyld 提供 libarchive）
private enum ZipBackend {
    static func unzipBinaries() -> [String] {
        #if jailbreak
        return ["/var/jb/usr/bin/unzip", "/usr/bin/unzip", "/var/jb/bin/unzip"]
        #else
        return ["/usr/bin/unzip", "/var/jb/usr/bin/unzip"]
        #endif
    }

    static func zipBinaries() -> [String] {
        #if jailbreak
        return ["/var/jb/usr/bin/zip", "/usr/bin/zip", "/var/jb/bin/zip"]
        #else
        return ["/usr/bin/zip", "/var/jb/usr/bin/zip"]
        #endif
    }

    static func first(_ candidates: [String]) -> String? {
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    static func unzip(_ archive: String, to destination: String) -> Bool {
        if let bin = first(unzipBinaries()) {
            let code = shell("\(bin) -o -q '\(archive)' -d '\(destination)'", uid: currentUid(), env: currentEnv)
            if code == 0 { return true }
            // 部分压缩包用到 unzip 不认的扩展字段，退回 libzip 再试一次
        }
        if libzip_unzip(archive, destination) == 0 { return true }
        // 最后一招：以 root 身份再解一次（目标目录可能属于 root）
        #if !stock
        _ = shell("chown -R mobile '\(destination)' 2>/dev/null; chmod -R u+rwX '\(destination)' 2>/dev/null", uid: 0, env: currentEnv)
        if let bin = first(unzipBinaries()) {
            let code = shell("\(bin) -o -q '\(archive)' -d '\(destination)'", uid: 0, env: currentEnv)
            if code == 0 { return true }
        }
        #endif
        return false
    }

    static func zip(_ source: String, to archive: String, keepParent: Bool) -> Int32 {
        if let bin = first(zipBinaries()) {
            let parentOfArchive = (archive as NSString).deletingLastPathComponent
            let parentOfSource = (source as NSString).deletingLastPathComponent
            if keepParent {
                let base = parentOfSource.isEmpty ? "." : parentOfSource
                let code = shell("cd '\(base)' && \(bin) -r -q -y '\(archive)' '\((source as NSString).lastPathComponent)'", uid: currentUid(), env: currentEnv)
                if code == 0 { return 0 }
            } else {
                let base = parentOfArchive.isEmpty ? "." : parentOfArchive
                let code = shell("cd '\(base)' && \(bin) -r -q -y '\(archive)' .", uid: currentUid(), env: currentEnv)
                if code == 0 { return 0 }
            }
        }
        return libzip_zip(source, archive, keepParent)
    }

    private static func currentUid() -> uid_t {
        #if jailbreak || trollstore
        return 501
        #else
        return 0
        #endif
    }

    private static let currentEnv: [String] = []
}

// MARK: - 压缩包探测

private func looksLikeZip(_ path: String) -> Bool {
    guard let handle = FileHandle(forReadingAtPath: path) else { return false }
    defer { handle.closeFile() }
    let magic = handle.readData(ofLength: 4)
    guard magic.count == 4 else { return false }
    let bytes = [UInt8](magic)
    // PK\x03\x04 (普通) / PK\x05\x06 (空包)
    return bytes[0] == 0x50 && bytes[1] == 0x4B &&
        ((bytes[2] == 0x03 && bytes[3] == 0x04) || (bytes[2] == 0x05 && bytes[3] == 0x06))
}

private func isZipName(_ path: String) -> Bool {
    let ext = (path as NSString).pathExtension.lowercased()
    return ext == "zip" || ext == "sproj"
}

// MARK: - 工程结构探测

/// 判断一个目录是否已经是一个完整的 FridaCodeManager 工程
private func findProjectRoot(in directory: String, depth: Int = 0) -> String? {
    guard depth <= 3 else { return nil }

    let fm = FileManager.default
    let marker = "\(directory)/Resources/DontTouchMe.plist"
    if fm.fileExists(atPath: marker) {
        return directory
    }

    // 只有 Info.plist 没有 DontTouchMe.plist：补齐后也算工程
    if fm.fileExists(atPath: "\(directory)/Resources/Info.plist") {
        repairProjectDirectory(directory)
        return directory
    }

    guard let children = try? fm.contentsOfDirectory(atPath: directory) else {
        return nil
    }
    let visible = children.filter { !kIgnoredNames.contains($0) && !$0.hasPrefix(".") }

    if visible.count == 1 {
        let only = "\(directory)/\(visible[0])"
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: only, isDirectory: &isDir), isDir.boolValue {
            return findProjectRoot(in: only, depth: depth + 1)
        }
    }
    return nil
}

/// 统计目录内源码文件的个数（与深度），用于给普通源码包生成工程外壳
private func scanSources(in directory: String, depth: Int = 0, limit: Int = 20000) -> (files: Int, maxDepth: Int) {
    var files = 0
    var maxDepth = depth
    let fm = FileManager.default
    guard depth <= 12, let enumerator = fm.enumerator(atPath: directory) else {
        return (0, depth)
    }
    var counter = 0
    for case let item as String in enumerator {
        counter += 1
        if counter > limit { break }
        let full = "\(directory)/\(item)"
        var isDir: ObjCBool = false
        fm.fileExists(atPath: full, isDirectory: &isDir)
        let itemDepth = depth + item.components(separatedBy: "/").count
        if isDir.boolValue {
            maxDepth = max(maxDepth, itemDepth)
        } else {
            let ext = (item as NSString).pathExtension.lowercased()
            if kSourceExtensions.contains(ext) {
                files += 1
            }
        }
    }
    return (files, maxDepth)
}

/// 为缺少 FCM 工程配置的目录补齐 Info.plist / DontTouchMe.plist / entitlements.plist
private func repairProjectDirectory(_ directory: String) {
    let fm = FileManager.default
    let resources = "\(directory)/Resources"
    cfolder(atPath: resources)

    let dirName = ((directory as NSString).lastPathComponent)
        .replacingOccurrences(of: " ", with: "_")
    let safeName = dirName.isEmpty ? "Imported" : dirName

    let infoPath = "\(resources)/Info.plist"
    if !fm.fileExists(atPath: infoPath) {
        let info: [String: Any] = [
            "CFBundleExecutable": safeName,
            "CFBundleIdentifier": "com.imported.\(safeName)",
            "CFBundleName": safeName,
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1.0",
            "MinimumOSVersion": gosver() ?? "15.0"
        ]
        if let data = try? PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0) {
            fm.createFile(atPath: infoPath, contents: data, attributes: nil)
        }
    }

    let dontTouchPath = "\(resources)/DontTouchMe.plist"
    if !fm.fileExists(atPath: dontTouchPath) {
        let sdk = UserDefaults.standard.string(forKey: "sdk") ?? "iPhoneOS15.6.sdk"
        let conf: [String: Any] = [
            "SDK": sdk,
            "TYPE": "Applications",
            "CMacro": "stable",
            "宏": ["stable": [:], "debug": [:]]
        ]
        if let data = try? PropertyListSerialization.data(fromPropertyList: conf, format: .xml, options: 0) {
            fm.createFile(atPath: dontTouchPath, contents: data, attributes: nil)
        }
    }

    let entPath = "\(directory)/entitlements.plist"
    if !fm.fileExists(atPath: entPath) {
        let ent: [String: Any] = ["platform-application": true]
        if let data = try? PropertyListSerialization.data(fromPropertyList: ent, format: .xml, options: 0) {
            fm.createFile(atPath: entPath, contents: data, attributes: nil)
        }
    }
}

/// 基于二进制名推导一个合法的 bundle id
private func makeBundleID(for directory: String) -> String {
    let info = NSDictionary(contentsOfFile: "\(directory)/Resources/Info.plist")
    if let existing = info?["CFBundleIdentifier"] as? String, !existing.isEmpty {
        return existing
    }
    var raw: String
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
    if let binary = entries.first(where: { !$0.contains(".") && !kIgnoredNames.contains($0) }) {
        raw = binary
    } else {
        raw = (directory as NSString).lastPathComponent
    }
    let allowed = CharacterSet.alphanumerics
    raw = String(raw.unicodeScalars.map { allowed.contains($0) ? String($0) : "" }.joined())
        .lowercased()
    if raw.isEmpty { raw = "imported" }
    if let head = raw.first, head.isNumber { raw = "app\(raw)" }
    return "com.imported.\(raw)"
}

/// 把源码目录收编成一个工程：源码**平铺在工程根目录**，只额外生成 Resources/ 等配置
/// 不再套 Source/ 这层目录，避免打开工程后只能看到一个 Source 文件夹
private func wrapSourcesAsProject(_ directory: String, name: String) -> String? {
    let fm = FileManager.default
    let entries = (try? fm.contentsOfDirectory(atPath: directory)) ?? []

    // 真工程（有 Resources 或 DontTouchMe.plist）不该走到这里
    if entries.contains("Resources") || entries.contains("DontTouchMe.plist") {
        return nil
    }

    let wrapUUID = "\(UUID())"
    let wrapPath = "\(global_documents)/\(wrapUUID)"
    cfolder(atPath: wrapPath)

    // 逐项搬进工程根目录（同名的 plist 会跟自动生成冲突，先移开）
    var hasEntitlements = false
    for item in entries {
        if item == ".DS_Store" || item == "__MACOSX" { continue }
        let src = "\(directory)/\(item)"
        if item == "entitlements.plist" {
            hasEntitlements = true
            _ = mv(src, "\(wrapPath)/entitlements.plist")
            continue
        }
        if item == "Info.plist" || item == "DontTouchMe.plist" {
            // 根目录下散落的旧 plist 放进 Resources，不要覆盖自动生成的
            cfolder(atPath: "\(wrapPath)/Resources")
            _ = mv(src, "\(wrapPath)/Resources/\(item)")
            continue
        }
        _ = mv(src, "\(wrapPath)/\(item)")
    }

    repairProjectDirectory(wrapPath)

    if !hasEntitlements {
        let ent: [String: Any] = ["platform-application": true]
        if let data = try? PropertyListSerialization.data(fromPropertyList: ent, format: .xml, options: 0) {
            fm.createFile(atPath: "\(wrapPath)/entitlements.plist", contents: data, attributes: nil)
        }
    }

    // 可执行文件名跟随导入的仓库/目录名
    let exec = name.replacingOccurrences(of: " ", with: "_")
        .replacingOccurrences(of: "-", with: "_")
        .replacingOccurrences(of: ".", with: "_")
    _ = wplist(value: exec, forKey: "CFBundleExecutable", plistPath: "\(wrapPath)/Resources/Info.plist")
    _ = wplist(value: name, forKey: "CFBundleName", plistPath: "\(wrapPath)/Resources/Info.plist")
    _ = wplist(value: makeBundleID(for: wrapPath), forKey: "CFBundleIdentifier", plistPath: "\(wrapPath)/Resources/Info.plist")
    return wrapPath
}

/// 普通源码包：根据结构决定是「造工程外壳」还是「直接放进当前目录」
private func adoptSourceDirectory(_ source: String, fallbackName: String?) -> ImportOutcome {
    let scan = scanSources(in: source)
    let systems = detectProjectBuildSystems(source)
    // 纯预编译仓库（只有 .a/.dylib + xcodeproj）也应该允许导入
    if scan.files == 0 && systems.isEmpty {
        return .fail("压缩包里没有可识别的源码文件，也没有 Xcode / CMake / Makefile 工程")
    }

    let name = fallbackName ?? ((source as NSString).lastPathComponent)

    // 有嵌套源码目录（说明是完整 App 工程树），或者是 C 二进制工程，就造一个工程外壳
    // 根目录下直接摊开的源码（如 main.c / main.m）按二进制工程处理
    let rootFiles = (try? FileManager.default.contentsOfDirectory(atPath: source)) ?? []
    let hasRootSource = rootFiles.contains { kSourceExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
    let needsWrap = hasRootSource || scan.maxDepth >= 2 || !FileManager.default.fileExists(atPath: "\(source)/Resources")
    if needsWrap {
        let wrapped = wrapSourcesAsProject(source, name: name)
        guard let projectPath = wrapped else {
            return .fail("创建工程外壳失败")
        }
        var message = "已导入工程「\(name)」"
        if !systems.isEmpty {
            message += "（\(systems.joined(separator: " · "))）"
        }
        // 这些依赖只能在 macOS 上准备，提前说清楚，避免构建到一半才报错
        if systems.contains("CocoaPods") {
            message += "\n注意：工程使用 CocoaPods。设备上无法执行 pod install，"
                + "请先在 Mac 上安装依赖并提交 Pods/ 目录。"
        }
        if systems.contains("Swift Package") {
            message += "\n注意：工程使用 Swift Package Manager。设备上无法解析远程依赖，"
                + "请先在 Mac 上执行 swift package resolve 并提交 .build/ 或改用 Xcode 工程。"
        }
        if FileManager.default.fileExists(atPath: "\(source)/.gitmodules") {
            message += "\n注意：仓库含 git 子模块；请确认导入时已完整拉取 submodule。"
        }
        return .success(message, projectPath)
    }
    return .success("已导入 \(scan.files) 个源码文件", nil)
}

/// 把 repo-main / repo-master / repo-1.2.3 这类目录名还原成仓库名
private func cleanRepoName(_ raw: String) -> String {
    var name = raw
    if name.hasSuffix(".zip") || name.hasSuffix(".sproj") {
        name = (name as NSString).deletingPathExtension
    }
    for suffix in ["-main", "-master", "-develop", "-dev"] {
        if name.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
    }
    // repo-<分支名>：只在后缀里有数字或点号时认为是版本/分支
    if let dash = name.lastIndex(of: "-") {
        let tail = String(name[name.index(after: dash)...])
        if !tail.isEmpty && tail.allSatisfy({ $0.isNumber || $0 == "." || $0 == "v" }) {
            return String(name[..<dash])
        }
    }
    return name
}

/// 如果一个目录里只有一个子目录，且没有别的文件，返回这个子目录（用于剥掉 repo-main/ 这层）
func singleSubdirectory(of directory: String) -> String? {
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(atPath: directory) else { return nil }
    let visible = entries.filter { !kIgnoredNames.contains($0) && !$0.hasPrefix(".") }
    guard visible.count == 1 else { return nil }
    let candidate = "\(directory)/\(visible[0])"
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: candidate, isDirectory: &isDir), isDir.boolValue else { return nil }
    return candidate
}

/// 从 .zip / .sproj 压缩包导入一个工程
func importProjectArchive(target: String) -> ImportOutcome {
    let fm = FileManager.default
    guard fm.fileExists(atPath: target) else {
        return .fail("找不到文件：\((target as NSString).lastPathComponent)")
    }

    let stagingID = "\(UUID())"
    let staging = "\(kImportStaging)/\(stagingID)"
    cfolder(atPath: kImportStaging)
    _ = rm(staging)

    var archive = target
    var temporaryCopy: String? = nil
    if !looksLikeZip(target) && !isZipName(target) {
        // 文件 App 有时会把压缩包拷成不带 .zip 后缀的名字
        let copyPath = "\(kImportStaging)/\(stagingID)-input.zip"
        if cp(target, copyPath) == 0 {
            temporaryCopy = copyPath
            archive = copyPath
        }
    }

    let unzipped = ZipBackend.unzip(archive, to: staging)
    if let copyPath = temporaryCopy { _ = rm(copyPath) }

    guard unzipped, fm.fileExists(atPath: staging) else {
        _ = rm(staging)
        return .fail("解压失败，请确认这是一个有效的 zip 压缩包")
    }

    let result = adoptStagedDirectory(staging)
    _ = rm(staging)
    return result
}

/// 把工程目录安装到 Documents 下（每次导入生成新的 UUID 目录，避免冲突）
private func installProject(from root: String) -> ImportOutcome {
    let destination = "\(global_documents)/\(UUID())"

    if cp(root, destination) != 0 {
        _ = rm(destination)
        return .fail("安装工程失败（复制文件出错）")
    }

    repairProjectDirectory(destination)

    // 补齐 SDK（导入的工程可能来自别的设备，里面写的 SDK 本地没有）
    let plist = "\(destination)/Resources/DontTouchMe.plist"
    let existing = rplist(forKey: "SDK", plistPath: plist) ?? ""
    let sdkInstalled = !existing.isEmpty &&
        FileManager.default.fileExists(atPath: "\(global_sdkpath)/\(existing)")
    if !sdkInstalled {
        let fallback = UserDefaults.standard.string(forKey: "sdk") ?? "iPhoneOS15.6.sdk"
        _ = wplist(value: fallback, forKey: "SDK", plistPath: plist)
    }

    let name = rplist(forKey: "CFBundleExecutable", plistPath: "\(destination)/Resources/Info.plist")
        ?? "导入的工程"
    return .success("已导入工程「\(name)」", destination)
}

/// 把一个已经解压好的暂存目录收编为工程
func adoptStagedDirectory(_ staging: String, fallbackName: String? = nil) -> ImportOutcome {
    let fm = FileManager.default

    // 1) 已经是 FCM 工程（含 Resources/DontTouchMe.plist），允许外面多套几层
    if let root = findProjectRoot(in: staging) {
        return installProject(from: root)
    }

    guard let entries = try? fm.contentsOfDirectory(atPath: staging) else {
        return .fail("无法读取解压目录")
    }
    let visible = entries.filter { !kIgnoredNames.contains($0) && !$0.hasPrefix(".") }

    guard !visible.isEmpty else {
        return .fail("压缩包是空的")
    }

    // 2) 只有一个目录：可能是 repo-main/ 或仓库名那一层，剥掉再判断
    var source = staging
    var displayName: String? = nil

    if let sub = singleSubdirectory(of: staging) {
        if let inner = findProjectRoot(in: sub) {
            return installProject(from: inner)
        }
        // 极少数情况还会再套一层（如 repo-main/src），仍含工程结构时也剥掉
        if let deeper = singleSubdirectory(of: sub), findProjectRoot(in: deeper) != nil {
            return installProject(from: deeper)
        }
        source = sub
        // 用被剥掉那一层的名字做显示名，去掉 -main / -master / -<分支> 后缀
        displayName = cleanRepoName((sub as NSString).lastPathComponent)
    }

    return adoptSourceDirectory(source, fallbackName: displayName ?? fallbackName)
}

/// 把 zip 内容导入到某个目录内（工程里「导入」按钮用）
func importArchiveInto(directory: String, archive: String) -> ImportOutcome {
    let fm = FileManager.default
    guard fm.fileExists(atPath: archive) else {
        return .fail("找不到文件：\((archive as NSString).lastPathComponent)")
    }

    let stagingID = "\(UUID())"
    let staging = "\(kImportStaging)/\(stagingID)"
    cfolder(atPath: kImportStaging)
    _ = rm(staging)

    guard ZipBackend.unzip(archive, to: staging) else {
        _ = rm(staging)
        return .fail("解压失败，请确认这是一个有效的 zip 压缩包")
    }

    guard let entries = try? fm.contentsOfDirectory(atPath: staging) else {
        return .fail("无法读取解压目录")
    }
    var visible = entries.filter { !kIgnoredNames.contains($0) }

    // 如果压缩包里只套了一层同名目录，自动剥掉它，避免导入后多一层
    if visible.count == 1 {
        let only = "\(staging)/\(visible[0])"
        var isDir: ObjCBool = false
        fm.fileExists(atPath: only, isDirectory: &isDir)
        let archiveBase = ((archive as NSString).lastPathComponent as NSString).deletingPathExtension
        if isDir.boolValue && (visible[0] == archiveBase || visible[0] == "\(archiveBase)-master" || visible[0] == "\(archiveBase)-main") {
            let nested = (try? fm.contentsOfDirectory(atPath: only)) ?? []
            visible = nested.filter { !kIgnoredNames.contains($0) }
            if !visible.isEmpty {
                var moved = 0
                for item in visible {
                    if mv("\(only)/\(item)", "\(directory)/\(item)") == 0 { moved += 1 }
                }
                _ = rm(staging)
                if moved == visible.count {
                    return .success("已导入 \(moved) 项内容", nil)
                }
                return .fail("部分文件导入失败（已导入 \(moved)/\(visible.count) 项）")
            }
        }
    }

    var moved = 0
    var conflicts: [String] = []
    for item in visible {
        if fm.fileExists(atPath: "\(directory)/\(item)") {
            conflicts.append(item)
            continue
        }
        if mv("\(staging)/\(item)", "\(directory)/\(item)") == 0 {
            moved += 1
        }
    }
    _ = rm(staging)

    if !conflicts.isEmpty && moved == 0 {
        return .fail("目标目录已存在同名文件：\(conflicts.prefix(3).joined(separator: "、"))")
    }
    if !conflicts.isEmpty {
        return .success("已导入 \(moved) 项，跳过 \(conflicts.count) 项同名文件", nil)
    }
    return .success("已导入 \(moved) 项内容", nil)
}
