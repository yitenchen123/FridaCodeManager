/*
 IncrementalBuild.swift

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

 增量编译：只重新编译「源文件内容或编译参数发生变化」的单元，
 其余直接复用上次生成的 .o，从而把二次构建从分钟级压到秒级。

 判定依据（与 Xcode 的思路一致）：
   - 源文件：路径 + 修改时间 + 大小
   - 编译参数：宏、SDK、目标版本、include 路径的哈希
 任一变化即视为需要重编。
 */

import Foundation

// MARK: - 数据结构

struct CompileUnit {
    var source: String        // 工程内相对路径
    var object: String        // 生成的 .o 绝对路径
    var needsRebuild: Bool
}

/// 增量状态记录，存在工程目录的 .fcm-cache/build-state.txt
struct BuildState {
    var entries: [String: String] = [:]   // key: 源文件相对路径, value: 指纹

    static func stateFile(_ projectPath: String) -> String {
        return "\(projectPath)/.fcm-cache/build-state.txt"
    }

    static func load(_ projectPath: String) -> BuildState {
        var state = BuildState()
        let path = stateFile(projectPath)
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return state
        }
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            if parts.count == 2 {
                state.entries[String(parts[0])] = String(parts[1])
            }
        }
        return state
    }

    func save(_ projectPath: String) {
        let dir = "\(projectPath)/.fcm-cache"
        cfolder(atPath: dir)
        var lines: [String] = []
        for (key, value) in entries.sorted(by: { $0.key < $1.key }) {
            lines.append("\(key)\t\(value)")
        }
        cfile(atPath: BuildState.stateFile(projectPath), withContent: lines.joined(separator: "\n"))
    }
}

// MARK: - 指纹

/// 计算单个源文件的指纹（内容变化 + 编译参数变化）
func sourceFingerprint(projectPath: String, relativePath: String, flagsToken: String) -> String {
    let full = "\(projectPath)/\(relativePath)"
    let attrs = try? FileManager.default.attributesOfItem(atPath: full)
    let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
    let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0

    // 用 内容首尾片段的哈希 + 大小 + 修改时间 组成指纹：
    // 比整文件哈希快，又比只看 mtime 可靠（编辑器保存时 mtime 精度可能不够）。
    var contentHash: UInt32 = 2166136261
    if let handle = FileHandle(forReadingAtPath: full) {
        func feed(_ data: Data) {
            for byte in data {
                contentHash ^= UInt32(byte)
                contentHash = contentHash &* 16777619
            }
        }
        let head = handle.readData(ofLength: 2048)
        feed(head)
        handle.seekToEndOfFile()
        let fileSize = Int(handle.offsetInFile)
        if fileSize > 2048 {
            handle.seek(toFileOffset: UInt64(max(0, fileSize - 1024)))
            feed(handle.readDataToEndOfFile())
        }
        handle.closeFile()
    }

    let raw = "\(relativePath)|\(size)|\(mtime)|\(flagsToken)|\(String(format: "%08x", contentHash))"
    // FNV-1a：跨进程稳定（String.hashValue 每次启动都会变，不能用于持久化）
    var hash: UInt32 = 2166136261
    for byte in raw.utf8 {
        hash ^= UInt32(byte)
        hash = hash &* 16777619
    }
    return String(format: "%08x-%d", hash, size)
}

// MARK: - 计划

/// 决定哪些文件需要重新编译
func planCompilation(projectPath: String,
                     sources: [String],
                     objectDir: String,
                     flagsToken: String,
                     forceFull: Bool) -> (units: [CompileUnit], reused: Int, rebuilt: Int) {
    let fm = FileManager.default
    cfolder(atPath: objectDir)

    let previous = forceFull ? BuildState() : BuildState.load(projectPath)
    var units: [CompileUnit] = []
    var reused = 0
    var rebuilt = 0

    for source in sources {
        let fingerprint = sourceFingerprint(projectPath: projectPath,
                                            relativePath: source,
                                            flagsToken: flagsToken)

        // 目标 .o 用源路径的稳定哈希命名，保证多次构建指向同一个文件
        let objectName = stableObjectName(source)
        let objectPath = "\(objectDir)/\(objectName).o"

        let unchanged = previous.entries[source] == fingerprint
        let objectExists = fm.fileExists(atPath: objectPath)

        let needsRebuild = !(unchanged && objectExists)
        if needsRebuild { rebuilt += 1 } else { reused += 1 }

        units.append(CompileUnit(source: source, object: objectPath, needsRebuild: needsRebuild))
    }

    // 清理已删除源文件对应的 .o
    let validObjects = Set(sources.map { stableObjectName($0) + ".o" })
    if let existing = try? fm.contentsOfDirectory(atPath: objectDir) {
        for file in existing where file.hasSuffix(".o") && !validObjects.contains(file) {
            _ = rm("\(objectDir)/\(file)")
        }
    }

    return (units, reused, rebuilt)
}

/// 编译/链接全部成功后再写增量状态。
///
/// 关键点：不能在计划阶段就写。否则某个文件编译失败时，
/// 它的新指纹已经落盘、旧的 .o 还在，下一次构建会误判为“未改动”而直接复用旧产物。
func saveBuildState(projectPath: String, sources: [String], flagsToken: String) {
    var state = BuildState()
    for source in sources {
        state.entries[source] = sourceFingerprint(projectPath: projectPath,
                                                  relativePath: source,
                                                  flagsToken: flagsToken)
    }
    state.save(projectPath)
}

/// 工程内所有头文件的组合指纹。
///
/// 增量编译只看 .m 自身的话，改头文件不会触发重编，
/// 会复用按旧头文件生成的 .o（Xcode 靠 dep 文件解决，这里用保守做法：
/// 任一头文件变化就让本轮所有 ObjC 单元重编）。
func projectHeadersFingerprint(projectPath: String, ignorePrefixes: [String]) -> String {
    let fm = FileManager.default
    guard let all = try? fm.subpathsOfDirectory(atPath: projectPath) else { return "" }
    let headers = all
        .filter {
            let ext = ($0 as NSString).pathExtension.lowercased()
            return ext == "h" || ext == "hh" || ext == "hpp" || ext == "hxx"
        }
        .filter { !isPathIgnored($0, prefixes: ignorePrefixes) }
        .sorted()

    var combined = ""
    for header in headers {
        combined += sourceFingerprint(projectPath: projectPath,
                                      relativePath: header,
                                      flagsToken: "")
        combined += "|"
    }

    var hash: UInt32 = 2166136261
    for byte in combined.utf8 {
        hash ^= UInt32(byte)
        hash = hash &* 16777619
    }
    return String(format: "%08x", hash)
}

/// 把源文件路径映射成稳定的 .o 文件名
func stableObjectName(_ relativePath: String) -> String {
    // FNV-1a 32 位，跨进程稳定（Swift 的 hashValue 每次启动都不同，不能用）
    var hash: UInt32 = 2166136261
    for byte in relativePath.utf8 {
        hash ^= UInt32(byte)
        hash = hash &* 16777619
    }
    let base = (relativePath as NSString).lastPathComponent
        .replacingOccurrences(of: ".", with: "_")
    return String(format: "%@_%08x", base, hash)
}

// MARK: - 参数指纹

/// 把影响编译产出的参数组合成一个 token，参数变化时所有文件都会重编
func flagsToken(macro: String,
                sdk: String,
                target: String,
                headerFlags: String,
                extraFlags: String) -> String {
    var hash: UInt32 = 2166136261
    let combined = "\(macro)|\(sdk)|\(target)|\(headerFlags)|\(extraFlags)"
    for byte in combined.utf8 {
        hash ^= UInt32(byte)
        hash = hash &* 16777619
    }
    return String(format: "%08x", hash)
}
