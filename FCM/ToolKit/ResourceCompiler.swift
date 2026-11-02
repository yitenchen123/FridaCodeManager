/*
 ResourceCompiler.swift

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

 资源编译：把 Resources 目录整理成 Xcode 产出的那种 .app 结构。
 具体处理：
   - storyboard / xib → 调用 ibtool 编译成 .storyboardc / .nib（可用时）
   - xcassets → 调用 actool 编译出 Assets.car（可用时）
   - 其余资源原样拷贝
   - 生成 PkgInfo
   - Info.plist 可选转换为二进制
 工具不可用时降级为原样拷贝，不阻断构建。
 */

import Foundation

struct ResourceCompileReport {
    var copied: Int = 0
    var storyboards: Int = 0
    var assetCatalogs: Int = 0
    var warnings: [String] = []
}

/// 在 .app 目录里查找可用的 ibtool / actool
private func findXcrunTool(_ name: String) -> String? {
    let candidates = [
        "/usr/bin/\(name)",
        "/var/jb/usr/bin/\(name)",
        "/Applications/Xcode.app/Contents/Developer/usr/bin/\(name)"
    ]
    for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
        return path
    }
    return nil
}

/// 把 Resources 目录的内容整理进 .app
func compileResources(from source: String,
                      into appBundle: String,
                      projectName: String,
                      executable: String,
                      sdkPath: String,
                      minimumOS: String,
                      infoPlistSource: String = "",
                      appIconName: String = "") -> ResourceCompileReport {
    let fm = FileManager.default
    var report = ResourceCompileReport()

    // Xcode 的 INFOPLIST_FILE 可能不在 Resources/ 下（导入的工程很常见）。
    // 优先采用工程配置指定的文件，否则使用 FCM 约定的 Resources/Info.plist。
    let plistSource = infoPlistSource.isEmpty ? "\(source)/Info.plist" : infoPlistSource
    if fm.fileExists(atPath: plistSource) {
        _ = cp(plistSource, "\(appBundle)/Info.plist")
    } else {
        report.warnings.append("找不到 Info.plist：\(plistSource)")
    }

    let entries = (try? fm.contentsOfDirectory(atPath: source)) ?? []
    if entries.isEmpty {
        report.warnings.append("资源目录不存在或为空：\(source)")
    }

    let ibtool = findXcrunTool("ibtool")
    let actool = findXcrunTool("actool")

    for item in entries where item != ".DS_Store" && item != "DontTouchMe.plist" && item != "Info.plist" {
        let src = "\(source)/\(item)"
        var isDir: ObjCBool = false
        _ = fm.fileExists(atPath: src, isDirectory: &isDir)
        let lower = item.lowercased()

        // ---- storyboard ----
        if lower.hasSuffix(".storyboard") && !isDir.boolValue {
            let outName = (item as NSString).deletingPathExtension
            let outDir = "\(appBundle)/\(outName).storyboardc"
            if let tool = ibtool,
               runCaptured("'\(tool)' '\(src)' --compile '\(outDir)' --minimum-deployment-target \(minimumOS) --target-device iphone --target-device ipad --module \(safeModuleName(executable))", uid: 501).succeeded {
                report.storyboards += 1
                continue
            }
            _ = cp(src, "\(appBundle)/\(item)")
            report.copied += 1
            if ibtool == nil {
                report.warnings.append("未安装 ibtool，storyboard 未编译：\(item)")
            } else {
                report.warnings.append("storyboard 编译失败，已原样拷贝：\(item)")
            }
            continue
        }

        // ---- xib ----
        if lower.hasSuffix(".xib") && !isDir.boolValue {
            let outName = (item as NSString).deletingPathExtension
            let outDir = "\(appBundle)/\(outName).nib"
            if let tool = ibtool,
               runCaptured("'\(tool)' '\(src)' --compile '\(outDir)' --minimum-deployment-target \(minimumOS)", uid: 501).succeeded {
                report.storyboards += 1
                continue
            }
            _ = cp(src, "\(appBundle)/\(item)")
            report.copied += 1
            continue
        }

        // ---- Asset Catalog ----
        if lower.hasSuffix(".xcassets") && isDir.boolValue {
            if let tool = actool {
                let out = "\(appBundle)"
                // 同一个 UUID 只生成一次；之前的写法生成与删除用了两个不同的 UUID，
                // partial plist 会永久堆积在 tmp 里。
                let partialPlist = "\(global_container)/tmp/asset-\(UUID()).plist"
                var command = "'\(tool)' '\(src)' --compile '\(out)'"
                    + " --platform iphoneos --minimum-deployment-target \(minimumOS)"
                    + " --output-partial-info-plist '\(partialPlist)'"
                // 只有目录里真的存在 AppIcon.appiconset 时才传 --app-icon，
                // 否则 actool 会直接报错，资源反而编译不出来。
                let icon = appIconName.isEmpty ? "AppIcon" : appIconName
                if containsAppIconSet(in: src, name: icon) {
                    command += " --app-icon \(icon)"
                }
                let result = runCaptured(command, uid: 501)
                _ = rm(partialPlist)
                if result.succeeded {
                    report.assetCatalogs += 1
                    continue
                }
                report.warnings.append("actool 编译失败，已原样拷贝：\(item)")
            } else {
                report.warnings.append("未安装 actool，Assets 未编译：\(item)")
            }
            _ = cp(src, "\(appBundle)/\(item)")
            report.copied += 1
            continue
        }

        // ---- 普通资源 ----
        if cp(src, "\(appBundle)/\(item)") == 0 {
            report.copied += 1
        } else {
            report.warnings.append("复制失败：\(item)")
        }
    }

    // ---- PkgInfo ----
    let packageType = fillInfoPlist(bundlePath: appBundle,
                                    projectName: projectName,
                                    executable: executable,
                                    minimumOS: minimumOS)
    _ = packageType

    return report
}

/// Asset Catalog 里是否存在指定名字的 appiconset
private func containsAppIconSet(in catalogPath: String, name: String) -> Bool {
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(atPath: catalogPath) else { return false }
    for case let entry as String in enumerator {
        guard let last = entry.split(separator: "/").last,
              last == Substring(name + ".appiconset") else { continue }
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: "\(catalogPath)/\(entry)", isDirectory: &isDir), isDir.boolValue {
            return true
        }
    }
    return false
}

/// 补齐 Info.plist 中 Xcode 会写入、但用户工程可能缺失的键；返回 CFBundlePackageType
@discardableResult
func fillInfoPlist(bundlePath: String,
                   projectName: String,
                   executable: String,
                   minimumOS: String) -> String {
    let plistPath = "\(bundlePath)/Info.plist"
    var info = readPlistDictionary(at: plistPath) ?? [:]

    let packageType = (info["CFBundlePackageType"] as? String) ?? "APPL"

    // CFBundleExecutable 必须与实际二进制文件名完全一致，
    // 否则系统会认为 App 包损坏（老工程里常见 $(EXECUTABLE_NAME) 或旧名字）。
    let resolvedExecutable = executable
        .replacingOccurrences(of: "$(EXECUTABLE_NAME)", with: executable)
        .replacingOccurrences(of: "${EXECUTABLE_NAME}", with: executable)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if !resolvedExecutable.isEmpty {
        info["CFBundleExecutable"] = resolvedExecutable
    }
    if info["CFBundleName"] == nil { info["CFBundleName"] = projectName }
    if info["CFBundleDisplayName"] == nil { info["CFBundleDisplayName"] = projectName }
    if info["CFBundlePackageType"] == nil { info["CFBundlePackageType"] = packageType }
    if info["CFBundleInfoDictionaryVersion"] == nil { info["CFBundleInfoDictionaryVersion"] = "6.0" }
    if info["CFBundleVersion"] == nil { info["CFBundleVersion"] = "1.0" }
    if info["CFBundleShortVersionString"] == nil { info["CFBundleShortVersionString"] = "1.0" }
    if info["MinimumOSVersion"] == nil { info["MinimumOSVersion"] = minimumOS }
    if info["LSRequiresIPhoneOS"] == nil { info["LSRequiresIPhoneOS"] = true }
    if info["UILaunchStoryboardName"] == nil, FileManager.default.fileExists(atPath: "\(bundlePath)/LaunchScreen.storyboardc") {
        info["UILaunchStoryboardName"] = "LaunchScreen"
    }
    if info["UISupportedInterfaceOrientations"] == nil {
        info["UISupportedInterfaceOrientations"] = ["UIInterfaceOrientationPortrait"]
    }

    _ = writePlistDictionary(info, to: plistPath)

    // PkgInfo：Xcode 会生成，内容为 "APPL????"
    let pkgInfo = "\(bundlePath)/PkgInfo"
    if !FileManager.default.fileExists(atPath: pkgInfo) {
        _ = FileManager.default.createFile(atPath: pkgInfo,
                                          contents: Data((packageType + "????").utf8),
                                          attributes: nil)
    }
    return packageType
}

/// swift 模块名要求是合法标识符
func safeModuleName(_ name: String) -> String {
    let allowed = CharacterSet.alphanumerics
    var result = String(name.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }.joined())
    if let first = result.first, first.isNumber { result = "_" + result }
    return result.isEmpty ? "App" : result
}
