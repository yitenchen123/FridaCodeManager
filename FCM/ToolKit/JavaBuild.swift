/*
 JavaBuild.swift

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

 在设备上编译 GitHub 工程里的 Java 启动核心。

 这类工程（Air2 / Pojav 系 / Zalith 系）通常：
   · JavaApp/src/launcher  → air2-launch.jar（启动核心）
   · JavaApp/src/lwjgl     → air2-lwjgl-patch.jar（LWJGL 补丁，需要官方 jar 做 classpath）
   · JavaApp/src/ownglfw   → air2-ownglfw.jar（自研 GLFW 覆盖层）
 由工程自己的 Makefile / 脚本阶段编译。设备上没有 make/python 时，
 这些脚本会失败，产物缺 jar，App 一启动就崩。

 这里不依赖 make/python，直接按 package 声明反推源码根目录，
 用 javac 产出 Java 8（major 52）的 class，再用 jar 打包，
 最后把 jar 放进 .app/Java/，让构建流程不再依赖宿主机的脚本环境。
 */

import Foundation

// MARK: - 数据结构

struct JavaSourceSet {
    var root: String          // package 根目录（javac 的 sourcepath）
    var sources: [String]     // 绝对 .java 路径
    var jarName: String
    var classpath: [String]
}

struct JavaBuildOutcome {
    var ok: Bool = false
    var jars: [String] = []
    var notes: [String] = []
    var failure: String = ""
}

// MARK: - 工程判定

private let javaIgnoredDirectories: [String] = [
    ".git", ".github", "build", "Build", "Payload", "clang", ".fcm-cache",
    ".fcm-errors", ".fcm-java", "node_modules", "Pods", "DerivedData",
    "java_runtimes", "Resources"
]

/// 工程里是否存在需要编译的 Java 源码。
/// 只认真正的 .java，不把内嵌 JRE 自带的东西算进来。
func projectNeedsJavaBuild(_ projectPath: String) -> Bool {
    let fm = FileManager.default
    guard let subpaths = try? fm.subpathsOfDirectory(atPath: projectPath) else { return false }

    for relative in subpaths where relative.hasSuffix(".java") {
        if isPathIgnored(relative, prefixes: javaIgnoredDirectories) { continue }
        if isJavaRuntimePath(relative) { continue }
        return true
    }
    return false
}

/// 判断路径是否落在 JDK / JRE 目录里（那些不是业务源码）
private func isJavaRuntimePath(_ relative: String) -> Bool {
    for component in relative.split(separator: "/") {
        let lower = component.lowercased()
        if lower == "jdk" || lower == "jre" || lower.hasPrefix("jdk") || lower.hasPrefix("jre") {
            return true
        }
        if lower.contains("openjdk") || lower == "java_runtimes" {
            return true
        }
    }
    return false
}

// MARK: - 源码根目录

/// 读取 .java 顶部的 package 声明
private func javaPackageName(of file: String) -> String {
    guard let handle = FileHandle(forReadingAtPath: file) else { return "" }
    let data = handle.readData(ofLength: 16384)
    handle.closeFile()
    guard let text = String(data: data, encoding: .utf8) else { return "" }

    // 去掉块注释与行注释，避免注释里的 package 干扰。
    // 注意正则里的 */ 必须转义成 \*/，否则会被当成「零个或多个 /」。
    var stripped = text
    stripped = stripped.replacingOccurrences(
        of: "/\\*[\\s\\S]*?\\*/", with: "", options: .regularExpression)
    stripped = stripped.replacingOccurrences(
        of: "//[^\\n]*", with: "", options: .regularExpression)

    let pattern = "(?:^|\\n)\\s*package\\s+([A-Za-z_][A-Za-z0-9_.]*)\\s*;"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return "" }
    let ns = stripped as NSString
    guard let match = regex.firstMatch(in: stripped, range: NSRange(location: 0, length: ns.length)),
          match.numberOfRanges > 1 else { return "" }
    return ns.substring(with: match.range(at: 1))
}

/// 根据 package 与文件路径反推源码根：
///   .../src/launcher/dev/airdevs/air2/launch/A.java
///   package dev.airdevs.air2.launch  →  .../src/launcher
private func javaPackageRoot(for file: String, packageName: String) -> String {
    let directory = (file as NSString).deletingLastPathComponent
    guard !packageName.isEmpty else { return directory }

    let components = packageName.split(separator: ".").map(String.init)
    var current = directory
    for component in components.reversed() {
        if (current as NSString).lastPathComponent == component {
            current = (current as NSString).deletingLastPathComponent
        } else {
            // 目录结构与 package 不一致（生成代码 / 默认包），退回到文件目录
            return directory
        }
    }
    return current
}

// MARK: - Makefile 中的 jar 命名

/// Makefile 里 `SOURCEDIR := ...` 与 `JARNAME := ...` 的配对关系。
/// 例如：
///   SOURCEDIR := src/launcher      + JARNAME := air2-launch
///   LWJGL_SRCDIR := src/lwjgl      + LWJGL_JARNAME := air2-lwjgl-patch
private func parseMakefileJarMap(makefile: String) -> [(srcDir: String, jarName: String)] {
    guard let text = try? String(contentsOfFile: makefile, encoding: .utf8) else { return [] }
    let makefileDir = (makefile as NSString).deletingLastPathComponent

    var values: [String: String] = [:]
    for rawLine in text.components(separatedBy: .newlines) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.hasPrefix("#"), let range = line.range(of: ":=") else { continue }
        let key = String(line[line.startIndex..<range.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !key.contains(" ") else { continue }
        var value = String(line[range.upperBound...])
            .trimmingCharacters(in: .whitespaces)
        if let hash = value.firstIndex(of: "#") {
            value = String(value[value.startIndex..<hash]).trimmingCharacters(in: .whitespaces)
        }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\","))
        guard !value.contains("$("), !value.isEmpty else { continue }
        values[key] = value
    }

    var mappings: [(String, String)] = []
    let suffixes = ["SOURCEDIR", "SRCDIR", "SRC_DIR"]
    for (key, value) in values {
        guard let suffix = suffixes.first(where: { key.hasSuffix($0) }) else { continue }
        let prefix = String(key.dropLast(suffix.count))
        let jarKey = prefix + "JARNAME"
        guard let jarRaw = values[jarKey], !jarRaw.isEmpty else { continue }
        guard !value.hasPrefix("/"), !jarRaw.hasPrefix("/") else { continue }

        let srcDir = (makefileDir as NSString).appendingPathComponent(value)
        var jarName = (jarRaw as NSString).lastPathComponent
        if !jarName.hasSuffix(".jar") { jarName += ".jar" }
        mappings.append((srcDir, jarName))
    }
    return mappings
}

/// 在工程的 Makefile / 构建脚本里找 `xxx.jar` 名字。
/// 用于没有显式 JARNAME 变量的产物（Air2 的 ownglfw 就写在 python 脚本里）。
private func discoverJarNames(projectPath: String) -> [String] {
    let fm = FileManager.default
    var names: Set<String> = []
    let interesting = ["Makefile", "makefile", "GNUmakefile"]
    let scriptExtensions = [".mk", ".sh", ".py"]

    guard let enumerator = fm.enumerator(atPath: projectPath) else { return [] }
    var visited = 0
    for case let relative as String in enumerator {
        visited += 1
        if visited > 600 { break }
        if isPathIgnored(relative, prefixes: javaIgnoredDirectories) {
            enumerator.skipDescendants()
            continue
        }
        let name = (relative as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()
        guard interesting.contains(name) || scriptExtensions.contains("." + ext) else { continue }

        let full = "\(projectPath)/\(relative)"
        let size = ((try? fm.attributesOfItem(atPath: full))?[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0, size < 512 * 1024 else { continue }
        guard let text = try? String(contentsOfFile: full, encoding: .utf8) else { continue }

        let pattern = "([A-Za-z0-9_.-]+?\\.jar)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let jar = ns.substring(with: match.range(at: 1))
            if jar.contains("/") { continue }   // 只收纯文件名
            names.insert(jar)
        }
    }
    return names.sorted()
}

// MARK: - classpath

/// 收集工程里可供 javac 使用的 jar（排除构建产物和内嵌 JRE）
private func collectJavaClasspath(projectPath: String) -> [String] {
    let fm = FileManager.default
    guard let subpaths = try? fm.subpathsOfDirectory(atPath: projectPath) else { return [] }
    var jars: [String] = []
    for relative in subpaths where relative.hasSuffix(".jar") {
        if isPathIgnored(relative, prefixes: javaIgnoredDirectories) { continue }
        if isJavaRuntimePath(relative) { continue }
        // 自己上一次编译出的 jar 不参与 classpath
        if relative.contains(".fcm-java/") { continue }
        jars.append("\(projectPath)/\(relative)")
    }
    return jars.sorted()
}

// MARK: - 编译

/// 编译工程里的 Java 源码，产出 Java 8 jar 并放进 app。
func buildJavaProject(projectPath: String,
                      appPath: String,
                      log: (String) -> Void) -> JavaBuildOutcome {
    let fm = FileManager.default
    var outcome = JavaBuildOutcome()
    let toolchain = detectJavaToolchain(projectPath: projectPath)

    for line in describeJavaToolchain(toolchain).split(separator: "\n") {
        log("  " + line)
    }
    guard toolchain.ready, toolchain.supportsJava8Target,
          let javac = toolchain.javacPath, let jarTool = toolchain.jarPath else {
        outcome.failure = "Java 工程需要 JDK（javac + jar）才能编译启动核心。\n"
            + describeJavaToolchain(toolchain) + "\n"
            + "请先在「设置 > Java 环境」导入 JDK 8，或在设备终端安装 openjdk-8 后重试。"
        return outcome
    }

    guard let subpaths = try? fm.subpathsOfDirectory(atPath: projectPath) else {
        outcome.failure = "无法读取工程目录：\(projectPath)"
        return outcome
    }

    // ---- 1) 按 package 根分组 ----
    var groups: [String: [String]] = [:]
    for relative in subpaths where relative.hasSuffix(".java") {
        if isPathIgnored(relative, prefixes: javaIgnoredDirectories) { continue }
        if isJavaRuntimePath(relative) { continue }
        let full = "\(projectPath)/\(relative)"
        let packageName = javaPackageName(of: full)
        let root = javaPackageRoot(for: full, packageName: packageName)
        groups[root, default: []].append(full)
    }
    guard !groups.isEmpty else {
        outcome.ok = true
        outcome.notes.append("没有找到可编译的 Java 源码")
        return outcome
    }

    // ---- 2) 源码目录 → jar 名 ----
    var jarMap: [String: String] = [:]
    let makefiles = [
        "\(projectPath)/Makefile",
        "\(projectPath)/JavaApp/Makefile"
    ]
    for makefile in makefiles where fm.fileExists(atPath: makefile) {
        for pair in parseMakefileJarMap(makefile: makefile) {
            let standardized = (pair.srcDir as NSString).standardizingPath
            jarMap[standardized] = pair.jarName
        }
    }

    let knownJarNames = discoverJarNames(projectPath: projectPath)
    let projectName = (projectPath as NSString).lastPathComponent
    var usedNames = Set<String>()
    var sets: [JavaSourceSet] = []

    for root in groups.keys.sorted() {
        let sources = (groups[root] ?? []).sorted()
        guard !sources.isEmpty else { continue }
        let rootName = (root as NSString).lastPathComponent.lowercased()
        var jarName = jarMap[(root as NSString).standardizingPath] ?? ""

        if jarName.isEmpty {
            // 脚本里写过 air2-ownglfw.jar 这类名字的，按目录名匹配
            for candidate in knownJarNames {
                let lower = candidate.lowercased()
                if rootName.count > 2 && lower.contains(rootName) {
                    jarName = candidate
                    break
                }
            }
        }
        if jarName.isEmpty {
            let base = (root as NSString).lastPathComponent
            jarName = (base == "src" || base == "java" || base == "main")
                ? "\(projectName).jar" : "\(base).jar"
        }
        jarName = jarName.replacingOccurrences(of: " ", with: "_")
        if usedNames.contains(jarName) {
            jarName = "\(projectName)-\(jarName)"
        }
        usedNames.insert(jarName)

        sets.append(JavaSourceSet(root: root,
                                  sources: sources,
                                  jarName: jarName,
                                  classpath: collectJavaClasspath(projectPath: projectPath)))
    }

    // ---- 3) 输出目录 ----
    let workRoot = fm.fileExists(atPath: "\(projectPath)/JavaApp")
        ? "\(projectPath)/JavaApp/build"
        : "\(projectPath)/.fcm-java/build"
    cfolder(atPath: workRoot)

    var producedJars: [String] = []

    for (index, set) in sets.enumerated() {
        log("编译 Java 源码集 \(index + 1)/\(sets.count)：\(set.root)")
        log("  源码 \(set.sources.count) 个 → \(set.jarName)")

        let classes = "\(workRoot)/classes-\(index)"
        _ = rm(classes)
        cfolder(atPath: classes)

        let sourceList = "\(workRoot)/sources-\(index).txt"
        var argFile = ""
        for source in set.sources {
            let escaped = source
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            argFile += "\"" + escaped + "\"\n"
        }
        cfile(atPath: sourceList, withContent: argFile)

        var compiled = false
        var lastOutput = ""
        var triedFlags: [[String]] = [toolchain.java8Flags]
        // 新 JDK 的 --release 8 偶尔因为 ct.sym 裁剪而不可用，双向兜底一次
        if toolchain.java8Flags.contains("--release") {
            triedFlags.append(["-source", "8", "-target", "8"])
        } else {
            triedFlags.append(["--release", "8"])
        }

        for flags in triedFlags {
            var args: [String] = [javac]
            args.append(contentsOf: flags)
            args.append(contentsOf: ["-encoding", "UTF-8", "-d", classes])
            if !set.classpath.isEmpty {
                args.append(contentsOf: ["-cp", set.classpath.joined(separator: ":")])
            }
            args.append("@" + sourceList)

            let command = args.map(shellQuote).joined(separator: " ")
            let result = runCaptured(command, uid: 501)
            lastOutput = result.output
            if result.succeeded {
                compiled = true
                break
            }
        }

        guard compiled else {
            outcome.failure = "javac 编译失败（\(set.root)）：\n" + String(lastOutput.suffix(2500))
            return outcome
        }

        // ---- 4) 校验字节码版本：必须是 Java 8（major 52）----
        let major = firstClassMajorVersion(in: classes)
        if major != 52 {
            outcome.failure = "编译产物不是 Java 8 字节码（major \(major)，期望 52）。\n"
                + "请使用 JDK 8，或在「设置 > Java 环境」里换成 JDK 8 后重试。"
            return outcome
        }

        let jarPath = "\(workRoot)/\(set.jarName)"
        _ = rm(jarPath)
        var jarArgs: [String] = [jarTool, "cf", jarPath, "-C", classes, "."]
        // 保留源码根里的 META-INF（部分补丁 jar 用它声明覆盖清单）
        let metaInf = "\(set.root)/META-INF"
        if fm.fileExists(atPath: metaInf) {
            jarArgs.append(contentsOf: ["-C", set.root, "META-INF"])
        }
        let jarCommand = jarArgs.map(shellQuote).joined(separator: " ")
        let jarResult = runCaptured(jarCommand, uid: 501)
        guard jarResult.succeeded, fm.fileExists(atPath: jarPath) else {
            outcome.failure = "jar 打包失败：\(set.jarName)\n" + String(jarResult.output.suffix(1200))
            return outcome
        }

        producedJars.append(jarPath)
        outcome.notes.append("\(set.jarName)（\(readableSize(jarPath))，Java 8）")
        log("  ✓ \(set.jarName)（\(readableSize(jarPath))）")
    }

    // ---- 5) 放进 App.app/Java/ ----
    if !appPath.isEmpty {
        let javaDir = "\(appPath)/Java"
        cfolder(atPath: javaDir)
        for jar in producedJars {
            let destination = "\(javaDir)/\((jar as NSString).lastPathComponent)"
            _ = rm(destination)
            _ = cp(jar, destination)
            if !fm.fileExists(atPath: destination) {
                outcome.failure = "无法把 \(jar) 拷进 App 包"
                return outcome
            }
        }
        log("已放入 App.app/Java/：\(producedJars.count) 个 jar")
    }

    outcome.ok = true
    outcome.jars = producedJars
    return outcome
}

/// 读取目录里第一个 .class 的 major version
private func firstClassMajorVersion(in directory: String) -> Int {
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(atPath: directory) else { return 0 }
    for case let relative as String in enumerator where relative.hasSuffix(".class") {
        let path = "\(directory)/\(relative)"
        guard let handle = FileHandle(forReadingAtPath: path) else { continue }
        let data = handle.readData(ofLength: 8)
        handle.closeFile()
        guard data.count == 8 else { continue }
        let bytes = [UInt8](data)
        guard bytes[0] == 0xCA && bytes[1] == 0xFE && bytes[2] == 0xBA && bytes[3] == 0xBE else {
            continue
        }
        return Int(bytes[6]) << 8 | Int(bytes[7])
    }
    return 0
}
