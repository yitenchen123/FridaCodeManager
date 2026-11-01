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

    // 用 内容首尾片段 + 大小 + 修改时间 组成指纹：
    // 比整文件哈希快，且足以发现改动（Xcode 也依赖 mtime）
    var contentSample = ""
    if let handle = FileHandle(forReadingAtPath: full) {
        let head = handle.readData(ofLength: 2048)
        handle.seekToEndOfFile()
        let fileSize = Int(handle.offsetInFile)
        if fileSize > 2048 {
            handle.seek(toFileOffset: UInt64(max(0, fileSize - 1024)))
            let tail = handle.readDataToEndOfFile()
            contentSample = String(data: head + tail, encoding: .utf8) ?? ""
        } else {
            contentSample = String(data: head, encoding: .utf8) ?? ""
        }
        handle.closeFile()
    }

    let raw = "\(relativePath)|\(size)|\(mtime)|\(flagsToken)|\(contentSample.count)"
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
    var nextState = BuildState()
    var units: [CompileUnit] = []
    var reused = 0
    var rebuilt = 0

    for source in sources {
        let fingerprint = sourceFingerprint(projectPath: projectPath,
                                            relativePath: source,
                                            flagsToken: flagsToken)
        nextState.entries[source] = fingerprint

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

    nextState.save(projectPath)
    return (units, reused, rebuilt)
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
