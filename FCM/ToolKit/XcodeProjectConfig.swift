/*
 XcodeProjectConfig.swift

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

 读取工程里的 .xcodeproj/project.pbxproj，提取真实的构建设置。

 这是 FCM 与 Xcode 构建结果一致的关键：
 Xcode 用 HEADER_SEARCH_PATHS / OTHER_LDFLAGS / GCC_PREPROCESSOR_DEFINITIONS
 等设置精确控制编译，FCM 之前靠扫描目录猜测，必然对不上。
 现在直接读工程配置，把 $(SRCROOT)、$(inherited) 等变量展开，
 转成 clang 参数。
 */

import Foundation

// MARK: - 数据结构

struct XcodeBuildConfig {
    var headerSearchPaths: [String] = []
    var otherLDFlags: [String] = []
    var otherCFlags: [String] = []
    var preprocessorDefinitions: [String] = []
    var enableObjCARC: Bool = true
    var enableModules: Bool = true
    var librarySearchPaths: [String] = []
    var frameworkSearchPaths: [String] = []
    var infoplistFile: String = ""
    var productBundleIdentifier: String = ""
    var deploymentTarget: String = ""
    var sourceFound: Bool = false
}

// MARK: - 解析

/// 从工程目录找到 .xcodeproj 并解析构建设置
func loadXcodeBuildConfig(projectPath: String) -> XcodeBuildConfig {
    var config = XcodeBuildConfig()

    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(atPath: projectPath) else { return config }
    guard let projDir = entries.first(where: { $0.hasSuffix(".xcodeproj") }) else { return config }

    let pbxproj = "\(projectPath)/\(projDir)/project.pbxproj"
    guard let text = try? String(contentsOfFile: pbxproj, encoding: .utf8) else { return config }
    config.sourceFound = true

    // ---- HEADER_SEARCH_PATHS ----
    config.headerSearchPaths = parseListSetting("HEADER_SEARCH_PATHS", in: text, projectPath: projectPath)

    // ---- OTHER_LDFLAGS ----
    config.otherLDFlags = parseListSetting("OTHER_LDFLAGS", in: text, projectPath: projectPath)

    // ---- OTHER_CFLAGS ----
    config.otherCFlags = parseListSetting("OTHER_CFLAGS", in: text, projectPath: projectPath)

    // ---- GCC_PREPROCESSOR_DEFINITIONS ----
    config.preprocessorDefinitions = parseListSetting("GCC_PREPROCESSOR_DEFINITIONS", in: text, projectPath: projectPath)

    // ---- LIBRARY_SEARCH_PATHS / FRAMEWORK_SEARCH_PATHS ----
    config.librarySearchPaths = parseListSetting("LIBRARY_SEARCH_PATHS", in: text, projectPath: projectPath)
    config.frameworkSearchPaths = parseListSetting("FRAMEWORK_SEARCH_PATHS", in: text, projectPath: projectPath)

    // ---- 布尔设置 ----
    config.enableObjCARC = parseBoolSetting("CLANG_ENABLE_OBJC_ARC", in: text, defaultValue: true)
    config.enableModules = parseBoolSetting("CLANG_ENABLE_MODULES", in: text, defaultValue: true)

    // ---- 字符串设置 ----
    config.infoplistFile = parseStringSetting("INFOPLIST_FILE", in: text, projectPath: projectPath)
    config.productBundleIdentifier = parseStringSetting("PRODUCT_BUNDLE_IDENTIFIER", in: text, projectPath: projectPath)
    config.deploymentTarget = parseStringSetting("IPHONEOS_DEPLOYMENT_TARGET", in: text, projectPath: projectPath)

    return config
}

// MARK: - 设置解析

/// 展开 Xcode 的构建变量
private func expandVariables(_ value: String, projectPath: String) -> String {
    var result = value
    result = result.replacingOccurrences(of: "$(SRCROOT)", with: projectPath)
    result = result.replacingOccurrences(of: "${SRCROOT}", with: projectPath)
    result = result.replacingOccurrences(of: "$(PROJECT_DIR)", with: projectPath)
    result = result.replacingOccurrences(of: "${PROJECT_DIR}", with: projectPath)
    // $(inherited) 在单文件层面没有上级，直接去掉
    result = result.replacingOccurrences(of: "$(inherited)", with: "")
    result = result.replacingOccurrences(of: "${inherited}", with: "")
    // $(TARGET_NAME) / $(PRODUCT_NAME) 在库搜索路径里偶尔出现，用工程名兜底
    let projectName = (projectPath as NSString).lastPathComponent
    result = result.replacingOccurrences(of: "$(TARGET_NAME)", with: projectName)
    result = result.replacingOccurrences(of: "$(PRODUCT_NAME)", with: projectName)
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// 解析形如
///   HEADER_SEARCH_PATHS = (
///       "$(inherited)",
///       "$(SRCROOT)/Natives",
///   );
/// 或单值形式 HEADER_SEARCH_PATHS = "$(SRCROOT)/inc";
private func parseListSetting(_ key: String, in text: String, projectPath: String) -> [String] {
    var values: [String] = []

    // 数组形式
    let arrayPattern = key + "\\s*=\\s*\\(([^)]*)\\)"
    if let regex = try? NSRegularExpression(pattern: arrayPattern, options: [.dotMatchesLineSeparators]) {
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard match.numberOfRanges > 1 else { continue }
            let body = ns.substring(with: match.range(at: 1))
            for rawLine in body.components(separatedBy: ",") {
                let cleaned = rawLine
                    .replacingOccurrences(of: "\"", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if cleaned.isEmpty { continue }
                let expanded = expandVariables(cleaned, projectPath: projectPath)
                if !expanded.isEmpty && !values.contains(expanded) {
                    values.append(expanded)
                }
            }
        }
    }

    // 单值形式
    if values.isEmpty {
        let singlePattern = key + "\\s*=\\s*\"?([^;\"\\n]+)\"?\\s*;"
        if let regex = try? NSRegularExpression(pattern: singlePattern) {
            let ns = text as NSString
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                guard match.numberOfRanges > 1 else { continue }
                let raw = ns.substring(with: match.range(at: 1))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if raw.isEmpty || raw.hasPrefix("(") { continue }
                let expanded = expandVariables(raw, projectPath: projectPath)
                if !expanded.isEmpty && !values.contains(expanded) {
                    values.append(expanded)
                }
            }
        }
    }

    return values
}

private func parseStringSetting(_ key: String, in text: String, projectPath: String) -> String {
    let pattern = key + "\\s*=\\s*\"?([^;\"\\n]+)\"?\\s*;"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return "" }
    let ns = text as NSString
    for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
        guard match.numberOfRanges > 1 else { continue }
        let raw = ns.substring(with: match.range(at: 1))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { continue }
        return expandVariables(raw, projectPath: projectPath)
    }
    return ""
}

private func parseBoolSetting(_ key: String, in text: String, defaultValue: Bool) -> Bool {
    let pattern = key + "\\s*=\\s*(YES|NO|yes|no)"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return defaultValue }
    let ns = text as NSString
    guard let match = regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).last,
          match.numberOfRanges > 1 else { return defaultValue }
    let value = ns.substring(with: match.range(at: 1)).uppercased()
    return value == "YES"
}

// MARK: - 转成 clang 参数

/// 把工程配置转成 clang 的 include 参数
func clangIncludeFlags(from config: XcodeBuildConfig) -> String {
    var flags = ""
    var seen = Set<String>()
    for path in config.headerSearchPaths where !seen.contains(path) {
        seen.insert(path)
        flags += " -I" + shellQuote(path)
    }
    return flags
}

/// 把工程配置转成 clang 的链接参数
func clangLinkFlags(from config: XcodeBuildConfig) -> String {
    var flags = ""
    for path in config.librarySearchPaths {
        flags += " -L" + shellQuote(path)
    }
    for path in config.frameworkSearchPaths {
        flags += " -F" + shellQuote(path)
    }
    for raw in config.otherLDFlags {
        // Xcode 里写的是 "-Wl,-U,_sym" 这种形式，去掉外层引号即可直接用
        var flag = raw.trimmingCharacters(in: .whitespaces)
        if flag.hasPrefix("\"") && flag.hasSuffix("\"") && flag.count > 2 {
            flag = String(flag.dropFirst().dropLast())
        }
        if flag.isEmpty { continue }
        flags += " " + shellQuote(flag)
    }
    return flags
}

/// 把工程配置转成预处理宏定义
func clangDefineFlags(from config: XcodeBuildConfig) -> String {
    var flags = ""
    for raw in config.preprocessorDefinitions {
        var value = raw.trimmingCharacters(in: .whitespaces)
        if value.isEmpty { continue }
        // DEBUG=1 这种直接透传
        flags += " -D" + shellQuote(value)
    }
    return flags
}

/// 单引号包裹，并转义内部单引号
func shellQuote(_ value: String) -> String {
    return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
