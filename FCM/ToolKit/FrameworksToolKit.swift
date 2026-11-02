 /* 
 FrameworksToolKit.swift 

 Copyright (C) 2023, 2024 SparkleChan and SeanIsTethered 
 Copyright (C) 2024 fridakitten 

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

  ______    _     _         _____        __ _                           ______                    _       _   _
 |  ___|  (_)   | |       /  ___|      / _| |                          |  ___|                  | |     | | (_)
 | |_ _ __ _  __| | __ _  \ `--.  ___ | |_| |___      ____ _ _ __ ___  | |_ ___  _   _ _ __   __| | __ _| |_ _  ___  _ __
 |  _| '__| |/ _` |/ _` |  `--. \/ _ \|  _| __\ \ /\ / / _` | '__/ _ \ |  _/ _ \| | | | '_ \ / _` |/ _` | __| |/ _ \| '_ \
 | | | |  | | (_| | (_| | /\__/ / (_) | | | |_ \ V  V / (_| | | |  __/ | || (_) | |_| | | | | (_| | (_| | |_| | (_) | | | |
 \_| |_|  |_|\__,_|\__,_| \____/ \___/|_|  \__| \_/\_/ \__,_|_|  \___| \_| \___/ \__,_|_| |_|\__,_|\__,_|\__|_|\___/|_| |_|
 Founded by. Sean Boleslawski, Benjamin Hornbeck and Lucienne Salim in 2023
 */ 

import Foundation

func findFrameworks(in directory: URL, SDKPath: String, ignorePaths: [String] = []) -> [String] {
    var frameworksSet = Set<String>()
    
    let fileManager = FileManager.default
    let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]
    let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles]
    
    guard let directoryEnumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: resourceKeys, options: options) else {
        print("Failed to create directory enumerator for \(directory)")
        return []
    }
    
    let ignoreSet = Set(ignorePaths)

    for case let fileURL as URL in directoryEnumerator {
        if shouldIgnore(fileURL: fileURL, ignoreSet: ignoreSet, fileManager: fileManager) {
            continue
        }

        do {
            let resourceValues = try fileURL.resourceValues(forKeys: Set(resourceKeys))
            
            if resourceValues.isRegularFile == true {
                let fileExtension = fileURL.pathExtension.lowercased()
                // Swift 的 import 也会产生 autolink，但显式 -framework 更可靠：
                // 有些设备工具链关闭了 autolink，届时 UIKit 符号会全部缺失。
                if ["h", "c", "cpp", "m", "mm", "swift"].contains(fileExtension) {
                    do {
                        let fileContents = try String(contentsOf: fileURL, encoding: .utf8)
                        let frameworkMatches = extractFrameworks(from: fileContents)
                        frameworksSet.formUnion(frameworkMatches)
                    } catch {
                        print("Error reading file \(fileURL): \(error)")
                    }
                }
            } else if resourceValues.isDirectory == true {
            } else {
                directoryEnumerator.skipDescendants()
            }
        } catch {
            print("Error reading resource values for file \(fileURL): \(error)")
        }
    }

    // 两个目录分别读取：之前把它们拼在一个 try 表达式里，
    // 只要 PrivateFrameworks 不存在（部分精简 SDK 就是如此），
    // 整个列表都会变成空，最终一个 -framework 都不传。
    var frameworks: [URL] = []
    if let publicFW = try? fileManager.contentsOfDirectory(
        at: URL(fileURLWithPath: "\(SDKPath)/System/Library/Frameworks"),
        includingPropertiesForKeys: nil) {
        frameworks.append(contentsOf: publicFW)
    }
    if let privateFW = try? fileManager.contentsOfDirectory(
        at: URL(fileURLWithPath: "\(SDKPath)/System/Library/PrivateFrameworks"),
        includingPropertiesForKeys: nil) {
        frameworks.append(contentsOf: privateFW)
    }
    if frameworks.isEmpty {
        print("Error while getting framework directories: \(SDKPath)")
    }
    
    let rawFW: [String] = frameworks.map { url in
        let lastPathComponent = url.lastPathComponent
        return lastPathComponent.deletingPathExtension()
    }
    
    frameworksSet = frameworksSet.filter { rawFW.contains($0) }
    return Array(frameworksSet)
}

private func shouldIgnore(fileURL: URL, ignoreSet: Set<String>, fileManager: FileManager) -> Bool {
    if ignoreSet.contains(fileURL.lastPathComponent) {
        return true
    }

    // 按完整路径匹配任意层级的忽略目录（例如 Sub/Resources/...）；
    // 只看直接父目录会漏掉嵌套在构建产物里的文件。
    let path = fileURL.path
    for prefix in ignoreSet where !prefix.isEmpty {
        if path.contains("/\(prefix)/") { return true }
    }
    return false
}

private func extractFrameworks(from contents: String) -> Set<String> {
    var frameworksSet = Set<String>()
    let nsString = contents as NSString
    let fullRange = NSRange(location: 0, length: nsString.length)

    // Objective-C： #import <UIKit/UIKit.h> 或 @import UIKit;
    if let regex = try? NSRegularExpression(pattern: "#(?:import|include)\\s+<([^/]+)/[^>]+>", options: []) {
        for match in regex.matches(in: contents, options: [], range: fullRange)
            where match.numberOfRanges == 2 {
            frameworksSet.insert(nsString.substring(with: match.range(at: 1)))
        }
    }
    if let regex = try? NSRegularExpression(pattern: "@import\\s+([A-Za-z_][A-Za-z0-9_]*)\\s*;", options: []) {
        for match in regex.matches(in: contents, options: [], range: fullRange)
            where match.numberOfRanges == 2 {
            frameworksSet.insert(nsString.substring(with: match.range(at: 1)))
        }
    }

    // Swift： import UIKit / import class UIKit.UIView
    // 只取模块名，后续会和 SDK 里真实存在的 .framework 求交集，
    // 所以 Foundation / SwiftUI 等错误来源不会污染链接参数。
    let swiftPatterns = [
        "^[ \\t]*(?:@_exported[ \\t]+)?import[ \\t]+(?:struct|class|enum|protocol|typealias|func|var|let)[ \\t]+([A-Za-z_][A-Za-z0-9_]*)",
        "^[ \\t]*(?:@_exported[ \\t]+)?import[ \\t]+([A-Za-z_][A-Za-z0-9_]*)"
    ]
    for pattern in swiftPatterns {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { continue }
        for match in regex.matches(in: contents, options: [], range: fullRange)
            where match.numberOfRanges == 2 {
            frameworksSet.insert(nsString.substring(with: match.range(at: 1)))
        }
    }

    return frameworksSet
}

extension String {
    func deletingPathExtension() -> String {
        return (self as NSString).deletingPathExtension
    }
}
