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
    var clanguageStandard: String = ""
    var optimizationLevel: String = ""
    var deadCodeStripping: String = ""
    var generateInfoPlist: Bool = true
    var strictObjCMsgSend: Bool = false
    var runpathSearchPaths: [String] = []
    var supportedPlatforms: String = ""
    // 以下依据 Apple Build Settings Reference 补齐
    var userHeaderSearchPaths: [String] = []      // USER_HEADER_SEARCH_PATHS → -iquote
    var systemHeaderSearchPaths: [String] = []    // SYSTEM_HEADER_SEARCH_PATHS → -isystem
    var systemFrameworkSearchPaths: [String] = [] // SYSTEM_FRAMEWORK_SEARCH_PATHS
    var cxxLanguageStandard: String = ""          // CLANG_CXX_LANGUAGE_STANDARD
    var swiftOptimizationLevel: String = ""       // SWIFT_OPTIMIZATION_LEVEL（-Onone / -O）
    var swiftObjcBridgingHeader: String = ""      // SWIFT_OBJC_BRIDGING_HEADER
    var swiftVersion: String = ""                 // SWIFT_VERSION
    var productName: String = ""                  // PRODUCT_NAME
    var executablePrefix: String = ""             // EXECUTABLE_PREFIX
    var executableSuffix: String = ""             // EXECUTABLE_SUFFIX
    var architectures: String = ""                // ARCHS
    var validArchs: String = ""                   // VALID_ARCHS
    var onlyActiveArch: Bool = false              // ONLY_ACTIVE_ARCH
    var stripInstalledProduct: Bool = false       // STRIP_INSTALLED_PRODUCT
    var stripStyle: String = ""                   // STRIP_STYLE
    var debugInformationFormat: String = ""       // DEBUG_INFORMATION_FORMAT
    var codeSignEntitlements: String = ""         // CODE_SIGN_ENTITLEMENTS
    var excludedArchitectures: String = ""        // EXCLUDED_ARCHITECTURES
    var assetCatalogAppIcon: String = ""          // ASSETCATALOG_COMPILER_APPICON_NAME
    var assetCatalogAccentColor: String = ""      // ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME
    var marketingVersion: String = ""             // MARKETING_VERSION
    var currentProjectVersion: String = ""        // CURRENT_PROJECT_VERSION
    var resourcesFolderPath: String = ""          // UNLOCALIZED_RESOURCES_FOLDER_PATH
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
    config.clanguageStandard = parseStringSetting("GCC_C_LANGUAGE_STANDARD", in: text, projectPath: projectPath)
    config.optimizationLevel = parseStringSetting("GCC_OPTIMIZATION_LEVEL", in: text, projectPath: projectPath)
    config.deadCodeStripping = parseStringSetting("DEAD_CODE_STRIPPING", in: text, projectPath: projectPath)
    config.supportedPlatforms = parseStringSetting("SUPPORTED_PLATFORMS", in: text, projectPath: projectPath)
    config.runpathSearchPaths = parseListSetting("LD_RUNPATH_SEARCH_PATHS", in: text, projectPath: projectPath)
    config.strictObjCMsgSend = parseBoolSetting("ENABLE_STRICT_OBJC_MSGSEND", in: text, defaultValue: false)
    config.generateInfoPlist = parseBoolSetting("GENERATE_INFOPLIST_FILE", in: text, defaultValue: true)

    config.userHeaderSearchPaths = parseListSetting("USER_HEADER_SEARCH_PATHS", in: text, projectPath: projectPath)
    config.systemHeaderSearchPaths = parseListSetting("SYSTEM_HEADER_SEARCH_PATHS", in: text, projectPath: projectPath)
    config.systemFrameworkSearchPaths = parseListSetting("SYSTEM_FRAMEWORK_SEARCH_PATHS", in: text, projectPath: projectPath)
    config.cxxLanguageStandard = parseStringSetting("CLANG_CXX_LANGUAGE_STANDARD", in: text, projectPath: projectPath)
    config.swiftOptimizationLevel = parseStringSetting("SWIFT_OPTIMIZATION_LEVEL", in: text, projectPath: projectPath)
    config.swiftObjcBridgingHeader = parseStringSetting("SWIFT_OBJC_BRIDGING_HEADER", in: text, projectPath: projectPath)
    config.swiftVersion = parseStringSetting("SWIFT_VERSION", in: text, projectPath: projectPath)
    config.productName = parseStringSetting("PRODUCT_NAME", in: text, projectPath: projectPath)
    config.executablePrefix = parseStringSetting("EXECUTABLE_PREFIX", in: text, projectPath: projectPath)
    config.executableSuffix = parseStringSetting("EXECUTABLE_SUFFIX", in: text, projectPath: projectPath)
    // ARCHS 既可能是单值，也可能写成数组 (arm64, arm64e)；
    // 数组形式用 parseStringSetting 会被括号/换行截断，必须按列表解析。
    let archValues = parseListSetting("ARCHS", in: text, projectPath: projectPath)
    config.architectures = archValues.isEmpty
        ? parseStringSetting("ARCHS", in: text, projectPath: projectPath)
        : archValues.joined(separator: " ")
    let validArchValues = parseListSetting("VALID_ARCHS", in: text, projectPath: projectPath)
    config.validArchs = validArchValues.isEmpty
        ? parseStringSetting("VALID_ARCHS", in: text, projectPath: projectPath)
        : validArchValues.joined(separator: " ")
    config.onlyActiveArch = parseBoolSetting("ONLY_ACTIVE_ARCH", in: text, defaultValue: false)
    config.stripInstalledProduct = parseBoolSetting("STRIP_INSTALLED_PRODUCT", in: text, defaultValue: false)
    config.stripStyle = parseStringSetting("STRIP_STYLE", in: text, projectPath: projectPath)
    config.debugInformationFormat = parseStringSetting("DEBUG_INFORMATION_FORMAT", in: text, projectPath: projectPath)
    config.codeSignEntitlements = parseStringSetting("CODE_SIGN_ENTITLEMENTS", in: text, projectPath: projectPath)
    let excludedValues = parseListSetting("EXCLUDED_ARCHITECTURES", in: text, projectPath: projectPath)
    config.excludedArchitectures = excludedValues.isEmpty
        ? parseStringSetting("EXCLUDED_ARCHITECTURES", in: text, projectPath: projectPath)
        : excludedValues.joined(separator: " ")
    config.assetCatalogAppIcon = parseStringSetting("ASSETCATALOG_COMPILER_APPICON_NAME", in: text, projectPath: projectPath)
    config.assetCatalogAccentColor = parseStringSetting("ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME", in: text, projectPath: projectPath)
    config.marketingVersion = parseStringSetting("MARKETING_VERSION", in: text, projectPath: projectPath)
    config.currentProjectVersion = parseStringSetting("CURRENT_PROJECT_VERSION", in: text, projectPath: projectPath)
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
    // 注意：$(TARGET_NAME) / $(PRODUCT_NAME) 不能在这里用工程目录名展开。
    // 工程目录是 UUID，展开后 PRODUCT_NAME 会变成 UUID，
    // 导致最终二进制名与 Info.plist 的 CFBundleExecutable 对不上。
    // 这些变量留给 build() 在拿到 ProjectInfo 之后再解析。
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// 解析形如
///   HEADER_SEARCH_PATHS = (
///       "$(inherited)",
///       "$(SRCROOT)/Natives",
///   );
/// 或单值形式 HEADER_SEARCH_PATHS = "$(SRCROOT)/inc";
///
/// ★ 不能用正则 [^)]* 匹配数组体 ★
///   $(inherited)、$(SRCROOT) 内部本身含括号，
///   正则会在这里提前截断，得到 "$(inherited" 这种残缺值，
///   拼进 clang 参数后整条命令语法错误。
///   必须按括号配对扫描。
private func parseListSetting(_ key: String, in text: String, projectPath: String) -> [String] {
    var values: [String] = []

    let chars = Array(text)
    var searchIndex = 0

    while searchIndex < chars.count {
        // 定位 "KEY" 后跟 "="
        guard let keyRange = findKey(key, in: chars, from: searchIndex) else { break }
        var i = keyRange.upperBound
        searchIndex = keyRange.upperBound

        // 跳过空白与 '='
        while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 }
        guard i < chars.count, chars[i] == "=" else { continue }
        i += 1
        while i < chars.count, chars[i] == " " || chars[i] == "\t" || chars[i] == "\n" { i += 1 }
        guard i < chars.count else { break }

        if chars[i] == "(" {
            // ---- 数组形式：括号配对扫描 ----
            var depth = 0
            var body: [Character] = []
            var j = i
            while j < chars.count {
                let c = chars[j]
                if c == "(" {
                    depth += 1
                    if depth == 1 { j += 1; continue }
                } else if c == ")" {
                    depth -= 1
                    if depth == 0 { j += 1; break }
                }
                body.append(c)
                j += 1
            }
            searchIndex = j

            // 按顶层逗号切分（$(...) 内部的逗号不算）
            for rawItem in splitTopLevelCommas(String(body)) {
                let cleaned = rawItem
                    .replacingOccurrences(of: "\"", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if cleaned.isEmpty { continue }
                // 跳过 $(inherited) 这类占位符
                let expanded = expandVariables(cleaned, projectPath: projectPath)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if expanded.isEmpty || expanded == "$" { continue }
                if !values.contains(expanded) {
                    values.append(expanded)
                }
            }
        } else {
            // ---- 单值形式：读到分号 ----
            var raw: [Character] = []
            var j = i
            while j < chars.count, chars[j] != ";" {
                raw.append(chars[j])
                j += 1
            }
            searchIndex = j + 1
            let cleaned = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if !cleaned.isEmpty {
                let expanded = expandVariables(cleaned, projectPath: projectPath)
                if !expanded.isEmpty && !values.contains(expanded) {
                    values.append(expanded)
                }
            }
        }
    }

    return values
}

/// 在字符数组里定位 "KEY" 的位置（要求前面不是字母数字，避免误匹配 XXX_KEY）
private func findKey(_ key: String, in chars: [Character], from start: Int) -> Range<Int>? {
    let keyChars = Array(key)
    guard keyChars.count > 0, chars.count >= keyChars.count else { return nil }

    var i = start
    while i + keyChars.count <= chars.count {
        var matched = true
        for k in 0..<keyChars.count where chars[i + k] != keyChars[k] {
            matched = false
            break
        }
        if matched {
            // 前面不能紧跟字母数字下划线
            if i == 0 {
                return i..<(i + keyChars.count)
            }
            let prev = chars[i - 1]
            if !(prev.isLetter || prev.isNumber || prev == "_") {
                return i..<(i + keyChars.count)
            }
        }
        i += 1
    }
    return nil
}

/// 按顶层逗号切分：忽略括号与引号内部的逗号
private func splitTopLevelCommas(_ input: String) -> [String] {
    var parts: [String] = []
    var current: [Character] = []
    var depth = 0
    var inQuote = false

    for c in input {
        if c == "\"" {
            inQuote.toggle()
            current.append(c)
            continue
        }
        if !inQuote {
            if c == "(" {
                depth += 1
            } else if c == ")" {
                depth -= 1
            } else if c == "," && depth == 0 {
                parts.append(String(current))
                current = []
                continue
            }
        }
        current.append(c)
    }
    if !current.isEmpty {
        parts.append(String(current))
    }
    return parts
}

private func parseStringSetting(_ key: String, in text: String, projectPath: String) -> String {
    let pattern = key + "\\s*=\\s*\"?([^;\"\\n]+)\"?\\s*;"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return "" }
    let ns = text as NSString
    var found = ""

    // pbxproj 里同一个 key 会出现在工程级与 target 级配置中。
    // 后者（target 级）在文件里通常靠后，而且优先级更高，所以取最后一个非空值。
    for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
        guard match.numberOfRanges > 1 else { continue }
        let raw = ns.substring(with: match.range(at: 1))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { continue }
        found = expandVariables(raw, projectPath: projectPath)
    }
    return found
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

/// 判断一个值是否是合法的 shell 参数
/// 防止解析残留（如 "$(inherited" 这种括号不配对的残片）污染整条编译命令
func isValidShellArgument(_ value: String) -> Bool {
    if value.isEmpty { return false }
    // 括号必须配对
    var depth = 0
    for c in value {
        if c == "(" { depth += 1 }
        else if c == ")" {
            depth -= 1
            if depth < 0 { return false }
        }
    }
    if depth != 0 { return false }
    // 不能含有未展开的变量残留
    if value.hasPrefix("$(") && !value.contains(")") { return false }
    return true
}

/// 把工程配置转成 clang 的 include 参数
func clangIncludeFlags(from config: XcodeBuildConfig) -> String {
    var flags = ""
    var seen = Set<String>()

    // -iquote：用户头文件优先（#import "xxx.h"）
    for path in config.userHeaderSearchPaths where !seen.contains(path) {
        guard isValidShellArgument(path) else { continue }
        seen.insert(path)
        flags += " -iquote" + shellQuote(path)
    }
    // -I：常规头文件搜索
    for path in config.headerSearchPaths where !seen.contains(path) {
        guard isValidShellArgument(path) else { continue }
        seen.insert(path)
        flags += " -I" + shellQuote(path)
    }
    // -isystem：系统头（不产生警告）
    for path in config.systemHeaderSearchPaths where !seen.contains(path) {
        guard isValidShellArgument(path) else { continue }
        seen.insert(path)
        flags += " -isystem" + shellQuote(path)
    }
    return flags
}

/// 拆分 Xcode 列表里的单个条目。
/// OTHER_LDFLAGS / OTHER_CFLAGS 中的条目偶尔会把多个参数写在一个字符串里
/// （如 "-framework UIKit"），直接整体加引号会变成“一个带空格的参数”，clang 无法识别。
private func splitFlagTokens(_ raw: String) -> [String] {
    var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count > 2 {
        value = String(value.dropFirst().dropLast())
    }
    return value.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
        .map { String($0).trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
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
    for path in config.systemFrameworkSearchPaths {
        guard isValidShellArgument(path) else { continue }
        flags += " -iframework" + shellQuote(path)
    }
    for raw in config.otherLDFlags {
        for flag in splitFlagTokens(raw) {
            guard isValidShellArgument(flag) else { continue }
            flags += " " + shellQuote(flag)
        }
    }
    return flags
}

/// Swift 驱动的链接参数。
///
/// swiftc 不像 clang 那样接受任意 `-Wl,...` / `-ObjC`，
/// 必须把它们转成 `-Xlinker` 逐项传递；否则会直接报 unknown argument。
func swiftLinkFlags(from config: XcodeBuildConfig) -> String {
    var flags = ""
    for path in config.librarySearchPaths {
        flags += " -L" + shellQuote(path)
    }
    for path in config.frameworkSearchPaths {
        flags += " -F" + shellQuote(path)
    }
    for path in config.systemFrameworkSearchPaths {
        guard isValidShellArgument(path) else { continue }
        flags += " -F" + shellQuote(path)
    }

    // 把 OTHER_LDFLAGS 展开成 token，再逐个转换
    var tokens: [String] = []
    for raw in config.otherLDFlags {
        tokens.append(contentsOf: splitFlagTokens(raw))
    }

    var index = 0
    while index < tokens.count {
        let token = tokens[index]
        if token.hasPrefix("-Wl,") {
            // -Wl,-rpath,/path → -Xlinker -rpath -Xlinker /path
            let parts = token.dropFirst(4).split(separator: ",", omittingEmptySubsequences: false)
            for part in parts {
                flags += " -Xlinker " + shellQuote(String(part))
            }
            index += 1
            continue
        }
        // -framework / -weak_framework 等需要和后面的名字成对传给 Swift 驱动
        let pairFlags: Set<String> = ["-framework", "-weak_framework", "-lazy_framework",
                                      "-reexport_framework", "-needed_framework"]
        if pairFlags.contains(token), index + 1 < tokens.count {
            flags += " " + token + " " + shellQuote(tokens[index + 1])
            index += 2
            continue
        }
        if token.hasPrefix("-l") || token.hasPrefix("-L") ||
           token.hasPrefix("-F") || token == "-ObjC" {
            // -ObjC 虽然是 linker 参数，但 Swift 驱动不接受直接形式
            if token == "-ObjC" {
                flags += " -Xlinker " + shellQuote(token)
            } else {
                flags += " " + shellQuote(token)
            }
            index += 1
            continue
        }
        if isValidShellArgument(token) {
            flags += " -Xlinker " + shellQuote(token)
        }
        index += 1
    }

    for path in config.runpathSearchPaths where !path.isEmpty {
        guard isValidShellArgument(path) else { continue }
        flags += " -Xlinker -rpath -Xlinker " + shellQuote(path)
    }
    return flags
}

/// OTHER_CFLAGS：直接透传给 clang（同样逐 token 处理）
func clangOtherCFlags(from config: XcodeBuildConfig) -> String {
    var flags = ""
    for raw in config.otherCFlags {
        for flag in splitFlagTokens(raw) {
            guard isValidShellArgument(flag) else { continue }
            flags += " " + shellQuote(flag)
        }
    }
    return flags
}

/// 优化级别：GCC_OPTIMIZATION_LEVEL 0/1/2/3/s/fast → -O0/-Os...
func clangOptimizationFlags(from config: XcodeBuildConfig) -> String {
    let level = config.optimizationLevel.trimmingCharacters(in: .whitespaces)
    return level.isEmpty ? "" : " -O" + level
}

/// 语言标准必须按源文件语言区分：
/// 只编译 C 文件时传 -std=gnu++17 会直接报错，反之亦然。
func clangLanguageStandardFlags(from config: XcodeBuildConfig, forCpp: Bool) -> String {
    if forCpp {
        let cxx = config.cxxLanguageStandard.trimmingCharacters(in: .whitespaces)
        guard !cxx.isEmpty else { return "" }
        // Xcode 里可能存成 "gnu++17" / "c++17" / "c++20"
        return " -std=" + cxx
    }
    let c = config.clanguageStandard.trimmingCharacters(in: .whitespaces)
    guard !c.isEmpty else { return "" }
    // Xcode 里可能存成 gnu17 / gnu11 / c99
    return " -std=" + c
}

/// 严格 objc msgSend 检查会插入额外检查，设备上关闭可减少运行时开销
func clangObjCMessagingFlags(from config: XcodeBuildConfig) -> String {
    return config.strictObjCMsgSend ? " -fno-strict-objc-msgsend" : ""
}

/// 解析目标架构
/// 依据 ARCHS / VALID_ARCHS / EXCLUDED_ARCHITECTURES / ONLY_ACTIVE_ARCH
/// 返回 clang 可用的 -arch 参数（空字符串表示用默认 arm64）
func resolveTargetArchitectures(from config: XcodeBuildConfig) -> [String] {
    // EXCLUDED_ARCHITECTURES 用于排除（模拟器常见 x86_64）
    var excluded: [String] = []
    if !config.excludedArchitectures.isEmpty {
        excluded = config.excludedArchitectures
            .replacingOccurrences(of: "$(inherited)", with: "")
            .split(whereSeparator: { $0 == " " || $0 == "," })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var archs: [String] = []
    let source = config.architectures.isEmpty ? config.validArchs : config.architectures
    if !source.isEmpty {
        // ARCHS 形如 "arm64" 或 "$(ARCHS_STANDARD)"
        // $(ARCHS_STANDARD) 对 iOS 设备即 arm64
        let cleaned = source
            .replacingOccurrences(of: "$(ARCHS_STANDARD)", with: "arm64")
            .replacingOccurrences(of: "${ARCHS_STANDARD}", with: "arm64")
            .replacingOccurrences(of: "$(ARCHS_STANDARD_64_BIT)", with: "arm64")
            .replacingOccurrences(of: "$(ARCHS_STANDARD_32_BIT)", with: "armv7")
            .replacingOccurrences(of: "$(ARCHS_STANDARD_32_64_BIT)", with: "arm64 armv7")
            .replacingOccurrences(of: "$(inherited)", with: "")
        archs = cleaned
            .split(whereSeparator: { $0 == " " || $0 == "," })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // 设备构建只接受 ARM 架构。
    // 很多工程把 ARCHS 写成 "arm64 x86_64"（同时支持真机与模拟器），
    // 把 x86_64 传给 iOS 设备编译器会得到 “building for iOS, but linking ... simulator”。
    let deviceArchs = archs.filter { ["arm64", "arm64e", "armv7", "armv7s"].contains($0) }
    archs = deviceArchs.isEmpty ? ["arm64"] : deviceArchs
    // 去掉被排除的
    archs = archs.filter { !excluded.contains($0) }
    return archs.isEmpty ? ["arm64"] : archs
}

/// 把工程配置转成链接阶段的 runpath 参数
func clangRunpathFlags(from config: XcodeBuildConfig) -> String {
    var flags = ""
    for path in config.runpathSearchPaths where !path.isEmpty {
        guard isValidShellArgument(path) else { continue }
        // $(inherited) 等已被展开过滤
        flags += " -Wl,-rpath," + shellQuote(path)
    }
    return flags
}

/// 把工程配置转成预处理宏定义
func clangDefineFlags(from config: XcodeBuildConfig) -> String {
    var flags = ""
    for raw in config.preprocessorDefinitions {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if value.isEmpty { continue }
        guard isValidShellArgument(value) else { continue }
        // DEBUG=1 这种直接透传
        flags += " -D" + shellQuote(value)
    }
    return flags
}

/// 单引号包裹，并转义内部单引号
func shellQuote(_ value: String) -> String {
    return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
