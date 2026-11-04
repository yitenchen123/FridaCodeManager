/*
 HeaderMap.swift

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

 Header Map：复刻 Xcode 的 USE_HEADERMAP 机制。

 Xcode 默认 USE_HEADERMAP = YES，会为每个 target 生成一个
 header map 目录，里面的 <TargetName>.hmap 内容是：

   A2ThemeManager.h -> /abs/path/Air2/UI/Theme/A2ThemeManager.h
   A2BaseViewController.h -> /abs/path/Air2/UI/Screens/A2BaseViewController.h

 然后通过 -I<derived>/TargetHeaderMap 传给 clang。

 效果：工程内所有头文件都能用 #import "文件名.h" 直接引用，
 不管它实际位于哪个子目录。
 这正是 Air2 不给每个子目录配 HEADER_SEARCH_PATHS 也能编过的原因。

 FCM 之前只有 HEADER_SEARCH_PATHS 里列出的目录，
 所以 Air2/ 下的头文件全部找不到。

 实现方式：不生成二进制 .hmap（格式复杂且无文档），
 而是生成等价的「扁平索引目录」：
   构建目录/headers/<文件名>.h → 符号链接到真实位置
 然后把这个目录加进 -I。
 效果与 header map 完全一致，且实现简单可靠。
 */

import Foundation

// MARK: - 结果

struct HeaderMapResult {
    var directory: String       // 生成的头文件索引目录
    var count: Int              // 收录的头文件数量
    var conflicts: [String]     // 同名头文件冲突（后者被跳过）
}

// MARK: - 生成

/// 扫描工程内所有头文件，建立一个扁平的索引目录
/// 返回可用于 -I 的目录路径
func buildHeaderMap(projectPath: String, ignorePrefixes: [String] = []) -> HeaderMapResult {
    let fm = FileManager.default
    let mapDir = "\(global_container)/tmp/fcm-headermap-\(stableHash(projectPath))"

    // 不再每次 rm -rf 重建：索引目录里只是符号链接，
    // 按需补缺/纠正比先删后建快得多（大工程每次能省几百次 unlink+symlink）。
    cfolder(atPath: mapDir)

    var result = HeaderMapResult(directory: mapDir, count: 0, conflicts: [])
    var expected: [String: String] = [:]

    // 排除构建产物与版本控制目录
    let ignoredPrefixes = makeBuildIgnoreList("") + ignorePrefixes + [".xcodeproj"]

    guard let enumerator = fm.enumerator(atPath: projectPath) else {
        return result
    }

    // 流式遍历：工程带 JRE / Pods 时，subpathsOfDirectory 会一次性
    // 把几万个路径装进数组，2GB 设备上白白吃内存。
    for case let file as String in enumerator {
        if isPathIgnored(file, prefixes: ignoredPrefixes) {
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: "\(projectPath)/\(file)", isDirectory: &isDirectory),
               isDirectory.boolValue {
                enumerator.skipDescendants()
            }
            continue
        }
        guard file.hasSuffix(".h") || file.hasSuffix(".hh") || file.hasSuffix(".hpp") else {
            continue
        }

        let name = (file as NSString).lastPathComponent

        // 同名头文件：保留第一个（与 Xcode header map 行为一致，后写覆盖但会警告）
        if expected[name] != nil {
            if !result.conflicts.contains(name) {
                result.conflicts.append(name)
            }
            continue
        }
        expected[name] = "\(projectPath)/\(file)"
    }

    for (name, source) in expected {
        let target = "\(mapDir)/\(name)"

        // 已有且指向同一文件：直接跳过
        if let existing = try? fm.destinationOfSymbolicLink(atPath: target), existing == source {
            result.count += 1
            continue
        }

        _ = rm(target)

        // 优先用符号链接（零拷贝）；不支持则复制
        do {
            try fm.createSymbolicLink(atPath: target, withDestinationPath: source)
            result.count += 1
        } catch {
            if cp(source, target) == 0 {
                result.count += 1
            }
        }
    }

    // 清掉上一轮遗留、当前工程里已不存在的头文件索引
    if let leftovers = try? fm.contentsOfDirectory(atPath: mapDir) {
        for name in leftovers where expected[name] == nil {
            _ = rm("\(mapDir)/\(name)")
        }
    }

    return result
}

// MARK: - 辅助

/// 稳定的短哈希（用于目录命名，避免多个工程互相覆盖）
func stableHash(_ value: String) -> String {
    var hash: UInt32 = 2166136261
    for byte in value.utf8 {
        hash ^= UInt32(byte)
        hash = hash &* 16777619
    }
    return String(format: "%08x", hash)
}
