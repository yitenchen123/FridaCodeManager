 /* 
 SparksBuild.swift 

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
import UIKit

#if !stock
// private api function group to open arbitary apps
private func obfuscatedClass(_ className: String) -> AnyClass? {
    return NSClassFromString(className)
}

private func obfuscatedSelector(_ selectorName: String) -> Selector? {
    return NSSelectorFromString(selectorName)
}

func OpenApp(_ bundleID: String) -> Void {
    guard let workspaceClass = obfuscatedClass("LSApplicationWorkspace") as? NSObject.Type else {
        print("Failed to find LSApplicationWorkspace")
        return
    }
    
    guard let defaultWorkspaceSelector = obfuscatedSelector("defaultWorkspace") else {
        print("Failed to find defaultWorkspace selector")
        return
    }
    
    let workspace = workspaceClass.perform(defaultWorkspaceSelector)?.takeUnretainedValue() as? NSObject
    
    guard let openAppSelector = obfuscatedSelector("openApplicationWithBundleID:") else {
        print("Failed to find openApplicationWithBundleID selector")
        return
    }
    
    if let workspace = workspace {
        let result = workspace.perform(openAppSelector, with: bundleID)
        if result == nil {
            print("Failed to open app with bundle ID \(bundleID)")
        }
    } else {
        print("Failed to initialize LSApplicationWorkspace")
    }
}
#endif

/// 扫描工程里的源文件（返回相对路径）。
/// 用 enumerator 逐层遍历并在忽略目录处剪枝：
/// subpathsOfDirectory 会把整棵树（含解压后的 JRE、Pods）一次性装进数组，
/// 在 iPhone 7/8 这类 2GB 设备上很容易触发内存压力。
func FindFilesStack(_ projectPath: String, _ fileExtensions: [String], _ ignore: [String]) -> [String] {
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(atPath: projectPath) else { return [] }

    let extensions = Set(fileExtensions)
    var files: [String] = []

    for case let relative as String in enumerator {
        // 注意：ignore 里可能出现空字符串（splitAndTrim("") 会返回 [""]），
        // 而 hasPrefix("") 恒为 true —— 那会把所有文件都过滤掉，
        // 表现为"编译瞬间完成，一个文件都没编"。
        // 统一走 isPathIgnored，按目录边界匹配，避免 "build" 误伤 "builder.m"。
        if isPathIgnored(relative, prefixes: ignore) {
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: "\(projectPath)/\(relative)", isDirectory: &isDirectory),
               isDirectory.boolValue {
                enumerator.skipDescendants()
            }
            continue
        }
        if extensions.contains(where: { relative.hasSuffix($0) }) {
            // 这里只返回相对路径，引号统一在拼接命令时加，
            // 否则会出现 /工程路径/'相对路径' 这种把引号包在中间的写法，
            // clang 会把 '文件名' 当成目录名，导致编译中断。
            files.append(relative)
        }
    }
    return files
}
