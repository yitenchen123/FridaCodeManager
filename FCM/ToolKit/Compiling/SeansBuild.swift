/* 
 SeansBuild.swift 

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
import SwiftUI
import Darwin

/// 把工程路径与相对路径拼成一个安全的 shell 参数（整体加单引号）
func quoted(_ base: String, _ relative: String) -> String {
    let full = (base as NSString).appendingPathComponent(relative)
    let escaped = full.replacingOccurrences(of: "'", with: "'\\''")
    return "'" + escaped + "'"
}

/// 把相对路径数组转成空格分隔的带引号参数
func quotedList(_ base: String, _ items: [String]) -> String {
    return items.map { quoted(base, $0) }.joined(separator: " ")
}

/// 扫描工程内的头文件搜索路径
/// Xcode 用 HEADER_SEARCH_PATHS 指定这些目录，FCM 之前完全没有传，
/// 导致 #import "a2_log.h"（在别的目录）和 #include <jni.h> 必然找不到。
///
/// 判定规则（任一满足即加入 -I）：
///   1. 目录名是 include / includes / Headers / Public / include_debug
///   2. 目录里直接存在 .h 文件（业务目录，例如 Natives/Support 同时放 .m 和 .h）
func discoverHeaderDirectories(_ projectPath: String) -> [String] {
    let fm = FileManager.default
    var paths: [String] = [projectPath]
    let ignored = buildIgnoredDirectories + ["java_runtimes", "depends"]

    guard let en = fm.enumerator(atPath: projectPath) else { return paths }
    var count = 0
    for case let item as String in en {
        count += 1
        if count > 30000 { break }

        var isDir: ObjCBool = false
        let full = "\(projectPath)/\(item)"
        guard fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue else { continue }

        // 跳过构建产物、版本控制、以及明显与源码无关的目录
        if isPathIgnored(item, prefixes: ignored) {
            en.skipDescendants()
            continue
        }

        let name = (item as NSString).lastPathComponent
        let lower = name.lowercased()
        if lower == "include" || lower == "includes" || lower == "headers" ||
           lower == "include_debug" || lower == "public" {
            paths.append(full)
            continue
        }

        // 目录里直接含 .h 文件的，也当作头文件目录
        let children = (try? fm.contentsOfDirectory(atPath: full)) ?? []
        if children.contains(where: { $0.hasSuffix(".h") || $0.hasSuffix(".hh") || $0.hasSuffix(".hpp") }) {
            paths.append(full)
        }
    }

    // 去重
    var seen = Set<String>()
    return paths.filter { seen.insert($0).inserted }
}

func discoverHeaderPaths(_ projectPath: String) -> String {
    return discoverHeaderDirectories(projectPath)
        .map { " -I" + shellQuote($0) }
        .joined()
}

/// Swift 通过 Clang importer 读取 Objective-C 头文件，
/// 头文件搜索路径必须经 -Xcc 转发；直接传 -I 给 swiftc 会被当成 Swift 模块路径。
func swiftClangImporterFlags(headerDirectories: [String]) -> String {
    return headerDirectories
        .map { " -Xcc -I" + shellQuote($0) }
        .joined()
}

/// 把 iPhoneOS16.4.sdk 转成可直接比较的字符串（各段补零到 3 位，字典序 == 版本序）
func versionKey(_ sdkName: String) -> String {
    let raw = sdkName
        .replacingOccurrences(of: "iPhoneOS", with: "")
        .replacingOccurrences(of: ".sdk", with: "")
    let parts = raw.split(separator: ".").map { Int($0) ?? 0 }
    return parts.map { String(format: "%03d", $0) }.joined(separator: ".")
}

/// 找出本机真正可用的 SDK 名
/// 优先：工程指定的（若已安装）→ 同主版本最高的 → 设置里的默认 → 任意一个已安装的
func resolveAvailableSDK(_ requested: String) -> String {
    let fm = FileManager.default
    let installed = ((try? fm.contentsOfDirectory(atPath: global_sdkpath)) ?? [])
        .filter { $0.hasPrefix("iPhoneOS") && $0.hasSuffix(".sdk") }

    if installed.isEmpty { return requested }
    if installed.contains(requested) { return requested }

    // 同主版本（例如 16.5 找不到时，用 16.x 里最新的）
    let wantedMajor = requested
        .replacingOccurrences(of: "iPhoneOS", with: "")
        .replacingOccurrences(of: ".sdk", with: "")
        .split(separator: ".").first.map(String.init)

    if let major = wantedMajor {
        let sameMajor = installed.filter {
            $0.replacingOccurrences(of: "iPhoneOS", with: "")
                .replacingOccurrences(of: ".sdk", with: "")
                .hasPrefix(major + ".")
        }
        if let best = sameMajor.sorted(by: { versionKey($0) < versionKey($1) }).last {
            print("SDK \"\(requested)\" 未安装，自动使用 \"\(best)\"")
            return best
        }
    }

    let fallback = UserDefaults.standard.string(forKey: "sdk") ?? ""
    if installed.contains(fallback) {
        print("SDK \"\(requested)\" 未安装，自动使用默认 \"\(fallback)\"")
        return fallback
    }

    if let any = installed.sorted(by: { versionKey($0) < versionKey($1) }).last {
        print("SDK \"\(requested)\" 未安装，自动使用 \"\(any)\"")
        return any
    }
    return requested
}

/// 并行编译一批 ObjC / C 编译单元，并自动串行重试被系统终止的单元。
///
/// 为什么单独写脚本而不是直接拼 xargs 命令：
///   · 主阶段按内存算出的并行度跑，尽量吃满设备；
///   · 万一某个 clang 被 jetsam 杀掉，串行重试只补被杀的那几个文件，
///     而不是让整次构建失败重来；
///   · 有真实编译错误（日志里有 error:）的不重试，避免无谓地再编一遍。
///
/// - Parameters:
///   - failLog: 已经加好 shell 引号的失败清单路径。
/// - Returns: 可直接追加到 EXEC 的 shell 片段。
func parallelCompileShell(projectPath: String,
                          units: [(source: String, object: String)],
                          errorDir: String,
                          failLog: String,
                          clangCommand: String,
                          extraFlags: String,
                          targetTriple: String,
                          compileFlags: (String) -> String,
                          parallelism: Int) -> String {
    let unitDir = "\(projectPath)/.fcm-units"
    _ = rm(unitDir)
    cfolder(atPath: unitDir)

    func write(_ content: String, _ name: String) {
        // 临时脚本不需要原子写：atomic 会为每个文件生成临时文件再 rename，
        // 几百个编译单元时这笔开销反而明显。
        _ = try? content.write(toFile: "\(unitDir)/\(name)", atomically: false, encoding: .utf8)
    }

    var commands: [String] = []
    for (index, unit) in units.enumerated() {
        let marker = "\(unitDir)/u\(index).fail"
        let errName = (unit.object as NSString).lastPathComponent + ".txt"
        let body = "rm -f " + shellQuote(unit.object)
            + " ; " + clangCommand + " " + compileFlags(unit.source) + " " + extraFlags
            + " -target " + targetTriple
            + " -c " + quoted(projectPath, unit.source)
            + " -o " + shellQuote(unit.object)
            + " > " + shellQuote("\(errorDir)/\(errName)") + " 2>&1"
        commands.append(body + " || touch " + shellQuote(marker))

        // 重试脚本先打标记、编译成功才清除：即使重试进程本身被杀，
        // 标记仍在，最终会被如实报告成失败。
        write("#!/bin/sh\n"
              + "touch " + shellQuote(marker) + " ; " + body
              + " ; if [ $? -eq 0 ]; then rm -f " + shellQuote(marker) + " ; fi\n",
              "u\(index).sh")
        write(unit.source + "\n", "u\(index).src")
        write("\(errorDir)/\(errName)\n", "u\(index).err")
    }

    let unitsFile = "\(projectPath)/.fcm-units.txt"
    // NUL 分隔：xargs 默认会解释输入里的引号/反斜杠，
    // 命令里的单引号路径（含空格的文件名）会被它吃掉。
    _ = try? commands.joined(separator: "\u{0}")
        .write(toFile: unitsFile, atomically: false, encoding: .utf8)

    let runnerFile = "\(projectPath)/.fcm-run.sh"
    let script = "#!/bin/sh\n"
        + "UD=" + shellQuote(unitDir) + "\n"
        + "rm -rf " + shellQuote(errorDir) + " ; mkdir -p " + shellQuote(errorDir) + "\n"
        + "xargs -0 -P " + String(parallelism)
        + " -I {} sh -c '{}' < " + shellQuote(unitsFile) + "\n"
        + "for f in \"$UD\"/*.fail; do\n"
        + "  [ -f \"$f\" ] || continue\n"
        + "  n=${f##*/}\n"
        + "  n=${n#u}\n"
        + "  n=${n%.fail}\n"
        + "  e=$(cat \"$UD/u$n.err\" 2>/dev/null)\n"
        + "  if [ -f \"$e\" ] && grep -q 'error:' \"$e\" 2>/dev/null; then continue; fi\n"
        + "  sh \"$UD/u$n.sh\"\n"
        + "done\n"
        + "for f in \"$UD\"/*.fail; do\n"
        + "  [ -f \"$f\" ] || continue\n"
        + "  n=${f##*/}\n"
        + "  n=${n#u}\n"
        + "  n=${n%.fail}\n"
        + "  cat \"$UD/u$n.src\"\n"
        + "done > " + failLog + "\n"
    _ = try? script.write(toFile: runnerFile, atomically: false, encoding: .utf8)

    // runner 自身输出单独落盘：failLog 只保留失败源文件清单，
    // 否则重试过程中的任何一行输出都会被误判成编译失败。
    let runLog = shellQuote("\(projectPath)/.fcm-run.log")
    return "cd " + shellQuote(projectPath) + " ; rm -f " + failLog + " ; "
        + "sh " + shellQuote(runnerFile) + " > " + runLog + " 2>&1 ; "
        + "rm -rf " + shellQuote(runnerFile) + " " + shellQuote(unitsFile)
        + " " + shellQuote(unitDir) + " ; "
}

func build(_ ProjectInfo: Project,_ erase: Bool,_ status: Binding<String>?,_ progress: Binding<Double>?) -> Int {
    // 工程里写的 SDK 可能在本机没有安装（常见于别人分享的工程），
    // 这里自动回退到「已安装的同系列 SDK」或「设置里的默认 SDK」，避免每次都要手动改。
    var ProjectInfo = ProjectInfo
    ProjectInfo.SDK = resolveAvailableSDK(ProjectInfo.SDK)

    let info: [String] = ["\(ProjectInfo.ProjectPath)/Payload","\(ProjectInfo.ProjectPath)/Payload/\(ProjectInfo.Executable).app","\(ProjectInfo.ProjectPath)/Resources","\(global_sdkpath)/\(ProjectInfo.SDK)","\(ProjectInfo.ProjectPath)/clang","\(ProjectInfo.ProjectPath)/bridge.h","\(ProjectInfo.ProjectPath)/entitlements.plist","\(load("\(ProjectInfo.ProjectPath)/api.api"))"]
    //PayloadPath  info[0]
    //AppPath      info[1]
    //Resources    info[2]
    //SDKPath      info[3]
    //ClangPath    info[4]
    //ClangBridge  info[5]
    //Entitlements info[6]
    //API Text     info[7]

    if !isBashSafe(filename: ProjectInfo.Executable) {
        print("错误：检测到可疑工程")
        return 1;
    }

    let fileManager = FileManager.default

    if !fileManager.fileExists(atPath: info[3]) {
       print("找不到 SDK \"\(ProjectInfo.SDK)\"。\n请前往「设置 > SDK 中心」下载，或在「工程设置 > SDK」里换一个已安装的 SDK。\n")
       return 1;
    }

    #if !stock
    //define build bash environment
    let bashenv: [String] = ["SDKROOT=\(info[3])","CPATH=\(Bundle.main.bundlePath)/include","LIBRARY_PATH=\(info[3])/usr/lib","FRAMEWORK_PATH=/System/Library/Frameworks:/System/Library/PrivateFrameworks","HOME=\(global_container)/.cache/.\(ProjectInfo.SDK)"]
    #endif

    // 工具链路径只探测一次：设备上可能只有 clang（没有 clang-14 这个别名），
    // 硬编码 "clang-14" 会让诊断通过但编译失败。
    let toolchain = detectToolchain()
    let clangCommand = shellQuote(toolchain.clangPath ?? "clang-14")

    //Processing API
    var apiextension: ext = ext(build:"",build_sub: "",bef: "", aft:"", ign: "")
    if !info[7].isEmpty {
        apiextension = api(info[7], ProjectInfo)
    }

    print("FridaCodeManager \(global_version)\n ")
    _ = climessenger("info","App Name: \(ProjectInfo.Executable)\nBundleID: \(ProjectInfo.BundleID)\nSDK:      \(ProjectInfo.SDK)")

    // Xcode 的第一步是解析依赖（SPM / CocoaPods / CI 脚本），然后才扫描源文件。
    // FCM 也必须先做，否则 CI 现下的头文件、预编译库会被后面的扫描漏掉。
    if hasSwiftPackageDependencies(projectPath: ProjectInfo.ProjectPath) {
        _ = resolveSwiftPackages(projectPath: ProjectInfo.ProjectPath) { line in
            _ = climessenger("spm", line)
        }
    }

    let prepSteps = ciPrepSteps(for: ProjectInfo.ProjectPath)
    if !prepSteps.isEmpty {
        _ = climessenger("ci-prep", "检测到 \(prepSteps.count) 个 CI 准备步骤，开始执行…")
        _ = runCIPrepSteps(prepSteps, projectPath: ProjectInfo.ProjectPath) { line in
            _ = climessenger("ci-prep", line)
        }
    }

    // ---------------- Release 资产 ----------------
    // GitHub CI 把大体积运行时（如 Air2 的四档 JRE）放在 release 资产里，
    // 构建前下载解压。缺了它们，产物能安装但启动缺运行时。
    let releaseAssets = missingReleaseAssets(projectPath: ProjectInfo.ProjectPath)
    if !releaseAssets.isEmpty {
        messenger(status, progress, "准备运行时资源", 0.08)
        _ = climessenger("release-assets",
                         "检测到 \(releaseAssets.count) 个 release 资产："
                         + releaseAssets.map { $0.asset }.joined(separator: "、"))
        let staged = stageReleaseAssets(projectPath: ProjectInfo.ProjectPath) { line in
            _ = climessenger("release-assets", line)
        }
        if !staged {
            _ = climessenger("release-assets-hint",
                             "release 资产未就位，产物会缺运行时；请确认网络后重试")
            return 1
        }
    }

    //finding code files
    messenger(status,progress,"finding code files",0.1)
    // 内置忽略项 + api.api 的忽略项；避免把 Payload/clang/build 里的旧副本也编进去
    let ignoreList = makeBuildIgnoreList(apiextension.ign)
    let (MFiles, SwiftFiles) = (
        FindFilesStack(ProjectInfo.ProjectPath, [".m", ".c", ".mm", ".cpp", ".cc", ".cxx", ".s"], ignoreList),
        FindFilesStack(ProjectInfo.ProjectPath, [".swift"], ignoreList)
    )
    // 静态库来源有两处：普通 .a，以及 .xcframework 里的设备切片
    let AFiles = (collectIOSStaticLibraries(projectPath: ProjectInfo.ProjectPath, ignorePrefixes: ignoreList)
                + collectIOSStaticFromXCFrameworks(projectPath: ProjectInfo.ProjectPath, ignorePrefixes: ignoreList)).sorted()

    //finding frameworks
    // Swift 代码也会 import 系统框架，不能只在有 .m 文件时才扫描。
    messenger(status,progress,"finding frameworks", 0.15)
    let frameworks = FileManager.default.fileExists(atPath: info[3])
        ? findFrameworks(in: URL(fileURLWithPath: ProjectInfo.ProjectPath),
                         SDKPath: info[3],
                         ignorePaths: ignoreList)
        : []
    // 工程自带的 .framework（如 terracotta）：需要额外传 -F 搜索路径，
    // 否则符号会缺失（_terracotta_ios_* 之类）。
    let localFrameworks = collectIOSFrameworks(projectPath: ProjectInfo.ProjectPath,
                                               ignorePrefixes: ignoreList)
    var localFrameworkFlags = ""
    for item in localFrameworks {
        let fwDir = ((item.path as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        localFrameworkFlags += " -F" + shellQuote(fwDir) + " -framework " + shellQuote(item.name)
    }

    // Xcode 工程里的 OTHER_LDFLAGS 直接透传：
    // 例如 "-Wl,-U,_terracotta_ios_start" 表示允许该符号未定义（运行时解析），
    // 以及 -L<path> -lmbedtls 这类库搜索与链接参数。
    // 优先读取 .xcodeproj 里的真实构建设置。
    // Xcode 用 HEADER_SEARCH_PATHS / OTHER_LDFLAGS 精确控制编译，
    // 靠扫描目录猜测必然对不上，这是之前链路反复失败的根因。
    let xcodeConfig = loadXcodeBuildConfig(projectPath: ProjectInfo.ProjectPath)
    // .xcodeproj 可能在子目录里（GitHub 仓库很常见），SRCROOT 必须指向它所在的目录
    let xcodeRoot = xcodeConfig.sourceRoot.isEmpty ? ProjectInfo.ProjectPath : xcodeConfig.sourceRoot
    var headerFlags = ""
    // swiftc 的 Clang importer 需要同一组路径，但必须经 -Xcc 转发
    var swiftHeaderFlags = ""
    if xcodeConfig.sourceFound &&
        (!xcodeConfig.headerSearchPaths.isEmpty ||
         !xcodeConfig.userHeaderSearchPaths.isEmpty ||
         !xcodeConfig.systemHeaderSearchPaths.isEmpty) {
        headerFlags = clangIncludeFlags(from: xcodeConfig)
        for path in xcodeConfig.userHeaderSearchPaths where isValidShellArgument(path) {
            swiftHeaderFlags += " -Xcc -iquote" + shellQuote(path)
        }
        for path in xcodeConfig.headerSearchPaths where isValidShellArgument(path) {
            swiftHeaderFlags += " -Xcc -I" + shellQuote(path)
        }
        for path in xcodeConfig.systemHeaderSearchPaths where isValidShellArgument(path) {
            swiftHeaderFlags += " -Xcc -isystem" + shellQuote(path)
        }
        var report = "读取 Xcode 工程配置：头文件路径 \(xcodeConfig.headerSearchPaths.count) 个"
        report += "，链接参数 \(xcodeConfig.otherLDFlags.count) 条"
        _ = climessenger("xcode-config", report)
        for path in xcodeConfig.headerSearchPaths.prefix(10) {
            _ = climessenger("xcode-config", "  -I " + path.replacingOccurrences(of: ProjectInfo.ProjectPath + "/", with: ""))
        }
    } else {
        // 没有工程配置时退回目录扫描
        let headerDirectories = discoverHeaderDirectories(ProjectInfo.ProjectPath)
        headerFlags = headerDirectories.map { " -I" + shellQuote($0) }.joined()
        swiftHeaderFlags = swiftClangImporterFlags(headerDirectories: headerDirectories)
        _ = climessenger("xcode-config", "未找到 .xcodeproj 配置，改用目录扫描")
    }
    // bridging header 经常 import 工程根目录里的头文件，根目录始终加入 importer 搜索路径
    swiftHeaderFlags += " -Xcc -I" + shellQuote(xcodeRoot)

    // Header Map（对应 Xcode 的 USE_HEADERMAP = YES，默认开启）
    //
    // Xcode 让工程内所有头文件都能用 #import "文件名.h" 直接引用，
    // 不管它实际在哪个子目录 —— 靠的就是 header map。
    // FCM 之前只有 HEADER_SEARCH_PATHS 里的目录，
    // 所以 Air2/ 下那些头文件全部找不到（A2ThemeManager.h 等）。
    //
    // 这里生成等价的扁平索引目录并加入 -I。
    let headerMap = buildHeaderMap(projectPath: ProjectInfo.ProjectPath,
                                   ignorePrefixes: ignoreList)
    if headerMap.count > 0 {
        headerFlags += " -I" + shellQuote(headerMap.directory)
        swiftHeaderFlags += " -Xcc -I" + shellQuote(headerMap.directory)
        var report = "Header Map：收录 \(headerMap.count) 个头文件"
        if !headerMap.conflicts.isEmpty {
            report += "（\(headerMap.conflicts.count) 个重名已跳过）"
        }
        _ = climessenger("xcode-config", report)
    }

    let xcodeLinkFlags = clangLinkFlags(from: xcodeConfig)
    let defineFlags = clangDefineFlags(from: xcodeConfig)
    let otherCFlags = clangOtherCFlags(from: xcodeConfig)
    let optimizationFlags = clangOptimizationFlags(from: xcodeConfig)
    let objcMessagingFlags = clangObjCMessagingFlags(from: xcodeConfig)
    // 动态库搜索路径：LD_RUNPATH_SEARCH_PATHS
    var runpathFlags = clangRunpathFlags(from: xcodeConfig)

    if !otherCFlags.isEmpty {
        _ = climessenger("xcode-config", "OTHER_CFLAGS：" + otherCFlags)
    }

    // Xcode 默认 LD_RUNPATH_SEARCH_PATHS 含 @executable_path/Frameworks；
    // 工程自带动态 framework 时缺了这条会在启动时 dyld 找不到库。
    if runpathFlags.isEmpty {
        runpathFlags = " -Wl,-rpath,@executable_path/Frameworks"
    }

    let frameflags = (frameworks.map { "-framework " + shellQuote($0) }.joined(separator: " ")
                    + localFrameworkFlags
                    + xcodeLinkFlags
                    + runpathFlags)

    // swiftc 不接受 -Wl, / -ObjC 这类 clang 形式，必须换成 -Xlinker；
    // 系统框架与工程自带 framework 的 -framework/-F 形式两边通用。
    var swiftFrameworkLinkFlags = frameworks.map { "-framework " + shellQuote($0) }.joined(separator: " ")
        + localFrameworkFlags
        + swiftLinkFlags(from: xcodeConfig)
    if xcodeConfig.runpathSearchPaths.isEmpty {
        swiftFrameworkLinkFlags += " -Xlinker -rpath -Xlinker " + shellQuote("@executable_path/Frameworks")
    }

    //setting up command
    messenger(status,progress,"setting up compiler",0.2)

    // 目标架构：iOS 设备构建只接受 ARM。
    // 旧实现同时传 -arch x86_64 和 -target arm64-apple-ios，两者会直接冲突。
    let targetArchs = resolveTargetArchitectures(from: xcodeConfig)
    let targetArch = targetArchs.first(where: { $0 == "arm64" }) ?? targetArchs[0]
    // 部署版本优先用工程里的 IPHONEOS_DEPLOYMENT_TARGET（Air2 是 14.0）。
    // 用设备当前系统版本当部署目标，会把只在更高系统存在的 API 编进来。
    let deploymentTarget = xcodeConfig.deploymentTarget.isEmpty
        ? ProjectInfo.TG : xcodeConfig.deploymentTarget
    let targetTriple = "\(targetArch)-apple-ios\(deploymentTarget)"
    if targetArchs != ["arm64"] {
        _ = climessenger("xcode-config", "目标架构：" + targetArchs.joined(separator: ", ") + "，使用 " + targetArch)
    }

    // 可执行文件名遵循 Xcode 规则：
    //   PRODUCT_NAME → EXECUTABLE_NAME，再拼 EXECUTABLE_PREFIX / EXECUTABLE_SUFFIX
    let executableName = resolveExecutableName(ProjectInfo.Executable, config: xcodeConfig)
    let finalExecutable = xcodeConfig.executablePrefix + executableName + xcodeConfig.executableSuffix
    if finalExecutable != ProjectInfo.Executable {
        _ = climessenger("build-plan", "可执行文件名：\(finalExecutable)（依据 PRODUCT_NAME / EXECUTABLE_*）")
    }
    let builtBinary = "\(info[1])/\(finalExecutable)"

    // 现代 Objective-C 基本都用 ARC；不开 ARC 时任何 __weak 都会直接报错。
    // 如需关闭，在工程的 api.api 里写 <noarc>true</noarc>。
    let usesARC = xcodeConfig.enableObjCARC && !apiextension.noarc
    let arcFlag = usesARC ? " -fobjc-arc" : " -fno-objc-arc"
    let modulesFlag = xcodeConfig.enableModules ? " -fmodules" : ""
    let sdkPathFlag = " -isysroot " + shellQuote(info[3])
    let macroFlag = ProjectInfo.Macro.isEmpty ? "" : " -D" + shellQuote(ProjectInfo.Macro)

    func isObjCSource(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext == "m" || ext == "mm"
    }
    func isCppSource(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext == "mm" || ext == "cpp" || ext == "cc" || ext == "cxx"
    }
    func isAsmSource(_ path: String) -> Bool {
        return (path as NSString).pathExtension.lowercased() == "s"
    }

    // 语言标准必须按文件类型分开，否则 -std=gnu++17 会把 .c 直接编失败。
    func compileFlags(for source: String) -> String {
        var flags = macroFlag + headerFlags + defineFlags + otherCFlags
        flags += optimizationFlags + objcMessagingFlags + sdkPathFlag
        if isObjCSource(source) { flags += arcFlag }
        if !isAsmSource(source) {
            flags += clangLanguageStandardFlags(from: xcodeConfig, forCpp: isCppSource(source))
        }
        flags += modulesFlag
        return flags
    }

    let hasCppSources = MFiles.contains(where: { isCppSource($0) })
    let cxxRuntimeFlag = hasCppSources ? " -lc++" : ""

    // Swift 通过 Clang importer 读头文件；宏也必须经 -Xcc 让它可见。
    var swiftImporterDefineFlags = ""
    if !ProjectInfo.Macro.isEmpty {
        swiftImporterDefineFlags += " -Xcc -D" + shellQuote(ProjectInfo.Macro)
    }
    for raw in xcodeConfig.preprocessorDefinitions where isValidShellArgument(raw) {
        swiftImporterDefineFlags += " -Xcc -D" + shellQuote(raw)
    }
    let swiftMacroFlag = ProjectInfo.Macro.isEmpty ? "" : " -D" + shellQuote(ProjectInfo.Macro)
    let swiftOptimization: String = {
        let raw = xcodeConfig.swiftOptimizationLevel
        if !raw.isEmpty {
            return raw.hasPrefix("-") ? " " + raw : " -O" + raw
        }
        return erase ? " -O" : " -Onone"
    }()
    // 有 main.swift 时不能传 -parse-as-library（顶层语句会报错）
    let hasMainSwift = SwiftFiles.contains { ($0 as NSString).lastPathComponent == "main.swift" }
    let parseAsLibrary = hasMainSwift ? "" : " -parse-as-library"

    // 桥接头：工程设置优先，其次工程根目录的 bridge.h
    var bridgingHeader = ""
    let configuredBridge = resolveProjectFilePath(xcodeConfig.swiftObjcBridgingHeader,
                                                  projectPath: xcodeRoot)
    if !configuredBridge.isEmpty, FileManager.default.fileExists(atPath: configuredBridge) {
        bridgingHeader = configuredBridge
    } else if FileManager.default.fileExists(atPath: info[5]) {
        bridgingHeader = info[5]
    }
    let bridgingHeaderFlag = bridgingHeader.isEmpty ? "" : " -import-objc-header " + shellQuote(bridgingHeader)

    // Swift 模块名必须合法；Xcode 的 PRODUCT_MODULE_NAME 默认就是清洗过的 PRODUCT_NAME。
    // 不传时 swiftc 会用输出文件名推断，带空格/连字符的名字可能直接报错。
    let swiftModuleName = safeModuleName(finalExecutable)
    let swiftBaseFlags = swiftMacroFlag + swiftHeaderFlags + swiftImporterDefineFlags
        + " -sdk " + shellQuote(info[3])
        + " -target " + targetTriple
        + " -module-name " + shellQuote(swiftModuleName)
        + swiftOptimization + " -g"

    // 失败文件名写入该文件，避免在 Swift 字符串里拼接 shell 变量（$ 会被当成插值）
    let FAIL_LOG = quoted(ProjectInfo.ProjectPath, "fcm-failed-files.txt")
    let LINK_FLAG = quoted(ProjectInfo.ProjectPath, "fcm-link-failed.txt")
    let errorDir = "\(ProjectInfo.ProjectPath)/.fcm-errors"
    // 从每个 .o 对应的日志里提炼 error 行（忽略 warning，避免淹没）
    let errorSummary = "echo ''; echo '—— 错误摘要 ——'; "
        + "for f in .fcm-errors/*.txt; do "
        + "[ -f \"$f\" ] || continue ; "
        + "E=$(grep -m3 'error:' \"$f\" 2>/dev/null) ; "
        + "if [ -n \"$E\" ]; then echo \"$(basename \"$f\" .txt):\"; echo \"$E\"; fi ; "
        + "done ; "

    #if trollstore
    // TrollStore 分支不使用 Swift 编译参数；显式引用避免 -warnings-as-errors 报未使用变量。
    _ = (swiftBaseFlags, bridgingHeaderFlag, parseAsLibrary, swiftHeaderFlags, swiftFrameworkLinkFlags)
    _ = (FAIL_LOG, LINK_FLAG, errorDir, errorSummary)
    #endif

    var EXEC = ""
    var incrementalToken: String? = nil

    if !SwiftFiles.isEmpty {
        #if jailbreak
        // Swift 工程：ObjC 部分先各自编译成 .o，再连同 Swift 一起交给 swiftc 链接。
        // 每次构建都清空 clang 目录，避免上一轮遗留的 .o 参与链接。
        let objcUnits = MFiles.map { mFile in
            (source: mFile, object: "\(info[4])/\(stableObjectName(mFile)).o")
        }
        let objcObjectPaths = objcUnits.map { $0.object }
        EXEC += "rm -rf " + shellQuote(info[4]) + " ; mkdir -p " + shellQuote(info[4]) + " ; "
        if !objcUnits.isEmpty {
            // ObjC 部分同样并行 + 失败重试，避免混合工程里几十个 .m 串行编译
            let objcScheduler = CompileScheduler.make(projectPath: ProjectInfo.ProjectPath,
                                                      fileCount: objcUnits.count)
            _ = climessenger("build-plan", "ObjC 调度：" + objcScheduler.reason)
            EXEC += parallelCompileShell(projectPath: ProjectInfo.ProjectPath,
                                         units: objcUnits,
                                         errorDir: errorDir,
                                         failLog: FAIL_LOG,
                                         clangCommand: clangCommand,
                                         extraFlags: apiextension.build_sub,
                                         targetTriple: targetTriple,
                                         compileFlags: { compileFlags(for: $0) },
                                         parallelism: objcScheduler.parallelism)
        } else {
            EXEC += "rm -f " + FAIL_LOG + " ; "
        }
        EXEC += "if [ -s " + FAIL_LOG + " ]; then echo '以下文件编译失败：'; cat " + FAIL_LOG
            + "; " + errorSummary + "exit 1; fi ; "

        let objectArgs = objcObjectPaths.map { shellQuote($0) }.joined(separator: " ")
        // swiftc 默认按 CPU 核数并行前端任务，不看内存：
        // 2GB 设备上 6 个前端同时跑很容易被 jetsam。这里用同一个调度器限流。
        let swiftJobs = CompileScheduler.make(projectPath: ProjectInfo.ProjectPath,
                                              fileCount: max(1, SwiftFiles.count))
        _ = climessenger("build-plan", "Swift 调度：" + swiftJobs.reason)
        func swiftCompileCommand(jobs: Int) -> String {
            return "swiftc " + swiftBaseFlags
                + " -j " + String(jobs)
                + " " + quotedList(ProjectInfo.ProjectPath, SwiftFiles)
                + " " + quotedList(ProjectInfo.ProjectPath, AFiles)
                + " " + objectArgs
                + " " + apiextension.build
                + swiftFrameworkLinkFlags
                + cxxRuntimeFlag
                + " " + bridgingHeaderFlag
                + parseAsLibrary
                + " -o " + shellQuote(builtBinary)
        }

        // 134/137/139 = 进程被 SIGABRT/SIGKILL/SIGSEGV 终止，多半是内存不够被系统杀掉。
        // 这时降到串行再试一次；真正的编译错误不重试，避免白白多编一遍。
        EXEC += swiftCompileCommand(jobs: swiftJobs.parallelism)
            + " ; RC=$? ; "
            + "if [ $RC -eq 137 ] || [ $RC -eq 139 ]; then "
            + "echo 'Swift 编译进程被系统终止，降为串行重试…' ; "
            + swiftCompileCommand(jobs: 1)
            + " || { echo 'Swift 编译或链接失败'; exit 1; } ; "
            + "elif [ $RC -ne 0 ]; then echo 'Swift 编译或链接失败'; exit 1; fi ; "
        #elseif trollstore
        print("TrollStore 版本目前不支持 Swift 工程！\n")
        return 1
        #endif
    } else {
        #if jailbreak
        // 纯 ObjC 工程：增量 + 并行编译。
        // 只为「源码或编译参数变化」的文件生成编译单元，
        // 其余直接复用已有 .o，二次构建可以快一个数量级。
        let objectDir = info[4]
        let token = flagsToken(macro: ProjectInfo.Macro,
                               sdk: ProjectInfo.SDK,
                               target: targetTriple,
                               headerFlags: headerFlags,
                               extraFlags: compileFlags(for: "")
                                    + "|cpp:" + clangLanguageStandardFlags(from: xcodeConfig, forCpp: true)
                                    + "|" + (usesARC ? "arc" : "noarc")
                                    + "|headers:" + projectHeadersFingerprint(projectPath: ProjectInfo.ProjectPath,
                                                                              ignorePrefixes: ignoreList))
        incrementalToken = token
        let plan = planCompilation(projectPath: ProjectInfo.ProjectPath,
                                   sources: MFiles,
                                   objectDir: objectDir,
                                   flagsToken: token,
                                   forceFull: false)

        // 变更统计写进日志，方便判断增量是否生效
        var planReport = "编译计划：\(MFiles.count) 个源文件，"
        planReport += "需重编 \(plan.rebuilt) 个，复用 \(plan.reused) 个"
        _ = climessenger("build-plan", planReport)

        let pending = plan.units.filter { $0.needsRebuild }
        if !pending.isEmpty {
            // 调度策略：按可用内存而非只看 CPU 核数，避免 200+ 编译单元并行时被 jetsam
            let scheduler = CompileScheduler.make(projectPath: ProjectInfo.ProjectPath,
                                                  fileCount: pending.count)
            _ = climessenger("build-plan", "调度：" + scheduler.reason)
            EXEC += parallelCompileShell(projectPath: ProjectInfo.ProjectPath,
                                         units: pending.map { (source: $0.source, object: $0.object) },
                                         errorDir: errorDir,
                                         failLog: FAIL_LOG,
                                         clangCommand: clangCommand,
                                         extraFlags: apiextension.build_sub,
                                         targetTriple: targetTriple,
                                         compileFlags: { compileFlags(for: $0) },
                                         parallelism: scheduler.parallelism)
        } else {
            EXEC += "cd " + shellQuote(ProjectInfo.ProjectPath) + " ; rm -f " + FAIL_LOG + " ; "
        }

        // 编译失败与链接失败分开报告，避免把链接错误说成“这些文件编译失败”
        EXEC += "if [ -s " + FAIL_LOG + " ]; then echo '以下文件编译失败：'; cat " + FAIL_LOG
            + "; " + errorSummary + "exit 1; fi ; "

        // 链接：只链接本次计划里的 .o（含复用的），不再用 clang/*.o 全局通配，
        // 否则旧的 UUID .o 会一起被链进来，直接 duplicate symbol。
        let objectArgs = plan.units.map { shellQuote($0.object) }.joined(separator: " ")
        let linkFlags = macroFlag + sdkPathFlag + " -fobjc-link-runtime "
            + apiextension.build + frameflags + cxxRuntimeFlag
        EXEC += clangCommand + " " + linkFlags + " -target " + targetTriple
            + " " + objectArgs
            + " " + quotedList(ProjectInfo.ProjectPath, AFiles)
            + " -o " + shellQuote(builtBinary)
            + " || echo LINK_FAILED > " + LINK_FLAG + " ; "
        EXEC += "if [ -f " + LINK_FLAG + " ]; then echo '链接失败，请查看上面的 ld 输出'; rm -f "
            + LINK_FLAG + " ; exit 1 ; fi ; "
        #elseif trollstore
        // TrollStore 版本没有并行编译调度，直接把所有源文件交给 clang。
        // 复用同一套公共参数，避免 C 与 C++ 语言标准互相冲突。
        EXEC += clangCommand + " " + compileFlags(for: "") + arcFlag + cxxRuntimeFlag
            + " " + apiextension.build + frameflags
            + " -target " + targetTriple + " "
            + quotedList(ProjectInfo.ProjectPath, MFiles)
            + " " + quotedList(ProjectInfo.ProjectPath, AFiles)
            + " -o " + shellQuote(builtBinary)
        #endif
    }

    let CDEXEC = "cd " + shellQuote(ProjectInfo.ProjectPath)

    //compiling app
    if !frameworks.isEmpty {
        _ = climessenger("framework-finder","\(frameworks.map { "\($0)" }.joined(separator: "\n"))")
    }

    // 每次构建都重新生成 Payload：否则旧的 .app / 旧二进制会和新产物混在一起。
    // 注意只清理 Payload 与旧 ipa，clang 目录保留给增量编译复用。
    let staleIPA = "\(ProjectInfo.ProjectPath)/"
        + ProjectInfo.Executable.replacingOccurrences(of: " ", with: "_") + ".ipa"
    _ = rm(staleIPA)
    _ = rm(info[0])
    cfolder(atPath: info[0])
    cfolder(atPath: info[1])
    cfolder(atPath: info[4])

    //has to move somewhere else
    #if !stock
    if !fileManager.fileExists(atPath: "\(global_container)/.cache") {
        cfolder(atPath: "\(global_container)/.cache")
    }
    if !fileManager.fileExists(atPath: "\(global_container)/.cache/.\(ProjectInfo.SDK)") {
        cfolder(atPath: "\(global_container)/.cache/.\(ProjectInfo.SDK)")
    }
    #endif

    // 静态库清单：工程里常有多平台预编译库，
    // 链错平台会报 "building for iOS, but linking in object file built for macOS"
    if !AFiles.isEmpty {
        var libReport = "待链接静态库 \(AFiles.count) 个："
        for lib in AFiles.prefix(12) {
            libReport += "\n  " + lib
        }
        if AFiles.count > 12 { libReport += "\n  …" }
        _ = climessenger("static-libs", libReport)
    } else {
        _ = climessenger("static-libs", "工程内没有可用的 iOS 静态库")
    }

    if !localFrameworks.isEmpty {
        var fwReport = "工程自带 framework \(localFrameworks.count) 个："
        for item in localFrameworks {
            fwReport += "\n  " + item.name + "  (" + item.path.replacingOccurrences(of: ProjectInfo.ProjectPath + "/", with: "") + ")"
        }
        _ = climessenger("local-frameworks", fwReport)
    }

    // ---------------- 构建前诊断 ----------------
    // 一次性检查所有已知会失败的条件，避免用户逐个试错。
    let diagnostics = runBuildDiagnostics(projectPath: ProjectInfo.ProjectPath)
    for line in diagnostics.formatted().split(separator: "\n") {
        _ = climessenger("preflight", String(line))
    }
    if diagnostics.hasBlockingIssue {
        _ = climessenger("preflight", "存在 \(diagnostics.errorCount) 个阻断性问题，已中止构建")
        _ = rm(info[0])
        return 1
    }

    // ---------------- 编译 ----------------
    messenger(status, progress, BuildStage.compile.display, 0.3)

    // 把编译脚本写入文件再执行：Air2 有 200+ 源文件，
    // 拼成 bash -c 的单个参数会超出 posix_spawn 上限（Failed to spawn process）。
    let buildScript = "\(global_container)/tmp/fcm-build-\(UUID()).sh"
    cfolder(atPath: "\(global_container)/tmp")
    _ = rm(buildScript)
    cfile(atPath: buildScript, withContent: "#!/bin/bash\nset +e\n" + CDEXEC + "\n" + EXEC)
    shell("chmod +x " + shellQuote(buildScript), uid: 501, env: [])

    // bashenv 提供 SDKROOT / CPATH / LIBRARY_PATH，缺了会找不到系统头文件和库
    var compileEnv: [String] = []
    #if !stock
    compileEnv = bashenv
    #endif
    let compileResult = runCaptured(shellQuote(buildScript), uid: 501, env: compileEnv)
    _ = rm(buildScript)

    if !compileResult.succeeded {
        _ = climessenger("compiler-stage", "编译或链接失败")
        if !compileResult.output.isEmpty {
            _ = climessenger("compiler-output", compileResult.output)
        }
        _ = rm(info[0])
        return 1
    }
    _ = climessenger("compiler-stage", "编译完成")

    // 编译成功后才写增量状态；失败时保留旧状态，下次会重新编译受影响文件。
    if let token = incrementalToken {
        saveBuildState(projectPath: ProjectInfo.ProjectPath, sources: MFiles, flagsToken: token)
    }


    // ---------------- 打包 .app ----------------
    messenger(status, progress, BuildStage.bundle.display, 0.45)

    let stagingApp = info[1]

    // 资源编译：storyboard/xib 交给 ibtool，xcassets 交给 actool，
    // 同时补齐 Info.plist 必需键并生成 PkgInfo，尽量贴近 Xcode 的产出结构。
    // 链接产物已经写在 stagingApp 内，这里不能再次删除它。
    let configuredInfoPlist = resolveProjectFilePath(xcodeConfig.infoplistFile,
                                                     projectPath: xcodeRoot)
    let resourceReport = compileResources(from: info[2],
                                          into: stagingApp,
                                          projectName: ProjectInfo.Executable,
                                          executable: finalExecutable,
                                          sdkPath: info[3],
                                          minimumOS: deploymentTarget,
                                          infoPlistSource: configuredInfoPlist,
                                          appIconName: xcodeConfig.assetCatalogAppIcon)

    // Info.plist 里的 $(PRODUCT_NAME) / $(EXECUTABLE_NAME) / $(CURRENT_PROJECT_VERSION)
    // 必须像 Xcode 一样展开，否则 Air2 这类工程的 CFBundleName 会保留字面量。
    let expandedKeys = expandInfoPlistBuildVariables(
        at: "\(stagingApp)/Info.plist",
        executableName: executableName,
        finalExecutable: finalExecutable,
        bundleID: ProjectInfo.BundleID,
        config: xcodeConfig)
    if expandedKeys > 0 {
        _ = climessenger("bundle-stage", "已展开 Info.plist 构建变量 \(expandedKeys) 处")
    }

    // 保证 bundle id 与工程记录一致（Info.plist 缺失时 fillInfoPlist 不一定有该键）
    _ = wplist(value: ProjectInfo.BundleID,
               forKey: "CFBundleIdentifier",
               plistPath: "\(stagingApp)/Info.plist")

    var bundleSummary = "资源：拷贝 \(resourceReport.copied) 项"
    if resourceReport.storyboards > 0 { bundleSummary += "，界面 \(resourceReport.storyboards) 个" }
    if resourceReport.assetCatalogs > 0 { bundleSummary += "，资源目录 \(resourceReport.assetCatalogs) 个" }
    _ = climessenger("bundle-stage", bundleSummary)
    for warning in resourceReport.warnings {
        _ = climessenger("bundle-stage", "  提示：" + warning)
    }

    // 动态 framework 必须复制进 .app/Frameworks（Xcode 的 Embed Frameworks 阶段），
    // 只链接不嵌入的话，启动时 dyld 会报 image not found。
    var embeddedFrameworkBinaries: [String] = []
    let dynamicFrameworks = localFrameworks.filter {
        if let type = machoFileType($0.path) { return type == 6 || type == 8 }
        return false
    }
    if !dynamicFrameworks.isEmpty {
        let frameworksDir = "\(stagingApp)/Frameworks"
        cfolder(atPath: frameworksDir)
        for item in dynamicFrameworks {
            let frameworkDir = (item.path as NSString).deletingLastPathComponent
            let frameworkName = (frameworkDir as NSString).lastPathComponent
            let destination = "\(frameworksDir)/\(frameworkName)"
            _ = rm(destination)
            if cp(frameworkDir, destination) == 0 {
                embeddedFrameworkBinaries.append("\(destination)/\(item.name)")
            } else {
                _ = climessenger("bundle-stage", "  提示：嵌入 framework 失败：\(frameworkName)")
            }
        }
        _ = climessenger("bundle-stage", "已嵌入动态 framework \(embeddedFrameworkBinaries.count) 个")
    }

    // 可执行文件必须在 .app 内，签名/打包都以它为入口
    if !FileManager.default.fileExists(atPath: builtBinary) {
        _ = climessenger("bundle-stage", "可执行文件缺失：\(builtBinary)")
        _ = climessenger("bundle-hint", "链接阶段没有产出，请查看上面的编译日志")
        _ = rm(info[0])
        return 1
    }

    // ---------------- Java 启动核心 ----------------
    // Air2 / Pojav 系工程的 Java 侧是 App 真正启动 Minecraft 的入口。
    // 它们原本靠工程 Makefile 在宿主 Mac 上编译；设备没有 make/python，
    // 脚本阶段必然掉进坑里。这里直接用 javac/jar 产出 Java 8 字节码，
    // 再放进 .app/Java/，不再依赖工程脚本环境。
    var javaAlreadyBuilt = false
    if projectNeedsJavaBuild(ProjectInfo.ProjectPath) {
        messenger(status, progress, "编译 Java 核心", 0.49)
        _ = climessenger("java-stage", "检测到 Java 源码，开始按 Java 8（major 52）编译")
        let javaOutcome = buildJavaProject(projectPath: ProjectInfo.ProjectPath,
                                           appPath: stagingApp) { line in
            _ = climessenger("java-stage", line)
        }
        if javaOutcome.ok {
            javaAlreadyBuilt = true
            for note in javaOutcome.notes {
                _ = climessenger("java-stage", "  · " + note)
            }
        } else {
            for line in javaOutcome.failure.split(separator: "\n") {
                _ = climessenger("java-stage", String(line))
            }
            _ = climessenger("java-hint", "Java 核心是启动必需产物；缺 JDK 时请先在「设置 > Java 环境」导入 JDK 8")
            _ = rm(info[0])
            return 1
        }
    }

    // ---------------- 脚本阶段 ----------------
    // Xcode 的顺序：编译 → 链接 → 拷资源 → 脚本阶段 → 签名。
    // 很多 GitHub 项目把依赖下载、资源拷贝放在这里，
    // 不执行就会缺文件（Air2 的 Java 核心与运行时资源即如此）。
    let shellPhases = loadShellBuildPhases(projectPath: ProjectInfo.ProjectPath)
    if !shellPhases.isEmpty {
        messenger(status, progress, "执行构建脚本", 0.5)
        _ = climessenger("shell-phase", "检测到 \(shellPhases.count) 个脚本阶段")
        let phasesSucceeded = runShellBuildPhases(shellPhases,
                                                  projectPath: ProjectInfo.ProjectPath,
                                                  appPath: stagingApp,
                                                  configuration: erase ? "Release" : "Debug",
                                                  sdkPath: info[3],
                                                  sourceRoot: xcodeRoot,
                                                  javaAlreadyBuilt: javaAlreadyBuilt) { line in
            _ = climessenger("shell-phase", line)
        }
        if !phasesSucceeded {
            // Java 相关阶段的失败在 runner 内部已经降级；走到这里说明是真正的构建错误。
            _ = climessenger("shell-phase", "脚本阶段失败，已中止构建")
            _ = rm(info[0])
            return 1
        }
    }

    if toolchain.ldidPath == nil {
        _ = climessenger("sign-stage", "找不到 ldid，无法签名。安装：apt install ldid")
        _ = rm(info[0])
        return 1
    }

    let executablePath = "\(stagingApp)/\(finalExecutable)"

    // ---------------- 剥离符号 ----------------
    // Xcode 的顺序是 strip → 签名。先签名再 strip 会把签名破坏掉，
    // 表现就是“装上了但启动闪退”。
    // STRIP_STYLE：all / non-global → -x，debugging → -S
    if xcodeConfig.stripInstalledProduct {
        let stripStyle = xcodeConfig.stripStyle.isEmpty ? "all" : xcodeConfig.stripStyle
        let stripFlag = stripStyle == "debugging" ? "-S" : "-x"
        // iOS 上不一定有 strip 命令，没有就跳过（不影响产物可用性）
        let stripPath = ["\(jbroot)/usr/bin/strip", "/usr/bin/strip"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        if let stripPath = stripPath {
            let stripResult = runCaptured(shellQuote(stripPath) + " " + stripFlag + " "
                                          + shellQuote(executablePath) + " 2>&1", uid: 501)
            if stripResult.succeeded {
                _ = climessenger("strip-stage", "已剥离符号（\(stripStyle)），大小：\(readableSize(executablePath))")
            } else {
                _ = climessenger("strip-stage", "剥离失败（不影响运行）：\(stripResult.output)")
            }
        } else {
            _ = climessenger("strip-stage", "设备上没有 strip 命令，已跳过")
        }
    }

    // ---------------- 签名 ----------------
    messenger(status, progress, BuildStage.sign.display, 0.55)

    // CODE_SIGN_ENTITLEMENTS 优先于工程根目录的 entitlements.plist
    var entitlementsPath = info[6]
    let configuredEntitlements = resolveProjectFilePath(xcodeConfig.codeSignEntitlements,
                                                        projectPath: xcodeRoot)
    if !configuredEntitlements.isEmpty,
       FileManager.default.fileExists(atPath: configuredEntitlements) {
        entitlementsPath = configuredEntitlements
    }

    let signResult = signBinary(executablePath, entitlements: entitlementsPath, ldid: toolchain.ldidPath!)
    if !signResult.0 {
        _ = climessenger("sign-stage", "签名失败：\(signResult.1)")
        _ = climessenger("sign-hint", "请检查 entitlements.plist 是否与本机越狱环境匹配")
        _ = rm(info[0])
        return 1
    }
    _ = climessenger("sign-stage", "签名完成：\(finalExecutable)")

    // 嵌入的 framework 也要 ad-hoc 签名，否则同样会在加载时被系统拒绝
    for binary in embeddedFrameworkBinaries {
        let nested = signBinary(binary, entitlements: nil, ldid: toolchain.ldidPath!)
        if nested.0 {
            _ = climessenger("sign-stage", "已签名嵌入库：\((binary as NSString).lastPathComponent)")
        } else {
            _ = climessenger("sign-stage", "嵌入库签名失败：\(nested.1)")
        }
    }

    // ---------------- 校验产物 ----------------
    messenger(status, progress, BuildStage.verify.display, 0.65)

    let bundleCheck = verifyAppBundle(stagingApp)
    if !bundleCheck.0 {
        _ = climessenger("verify-stage", "产物校验失败：")
        for problem in bundleCheck.1 {
            _ = climessenger("verify-stage", "  · \(problem)")
        }
        _ = rm(info[0])
        return 1
    }

    // Java 产物校验：Air2 这类工程的启动依赖 App.app/Java/*.jar，
    // 脚本阶段若失败，jar 缺失会导致 App 启动即崩溃。
    let javaCheck = verifyJavaArtifacts(stagingApp)
    if !javaCheck.notes.isEmpty {
        for note in javaCheck.notes {
            _ = climessenger("verify-stage", "Java 产物：" + note)
        }
    } else if !shellPhases.isEmpty {
        _ = climessenger("verify-stage", "提示：工程有脚本阶段，但产物里没有发现 jar")
    }

    let macho = verifyMachO(executablePath, expectedArch: targetArch)
    if !macho.0 {
        _ = climessenger("verify-stage", "可执行文件校验失败：\(macho.1)")
        _ = rm(info[0])
        return 1
    }
    _ = climessenger("verify-stage", "架构：\(macho.1)，大小：\(readableSize(executablePath))")

    // ---------------- 生成安装包 ----------------
    messenger(status, progress, BuildStage.package.display, 0.75)

    // 用工程名区分，避免多个工程同时构建互相覆盖
    let ipaName = ProjectInfo.Executable.replacingOccurrences(of: " ", with: "_")
    let ipaPath = "\(ProjectInfo.ProjectPath)/\(ipaName).ipa"

    let packaged = packageIPA(appBundle: stagingApp, output: ipaPath, zipPath: toolchain.zipPath)
    if !packaged.0 {
        _ = climessenger("package-stage", "打包 ipa 失败：\(packaged.1)")
        _ = rm(info[0])
        return 1
    }
    _ = climessenger("package-stage", "已生成：\(ipaPath)（\(readableSize(ipaPath))）")

    // ---------------- 安装 ----------------
    if ProjectInfo.TYPE == "Applications" {
        messenger(status, progress, "安装 \(ProjectInfo.Executable)", 0.85)

        #if !stock
        if erase {
            killTaskWithProcessName(finalExecutable)
            let installPath = "\(ProjectInfo.ProjectPath)/ts.ipa"
            _ = rm(installPath)
            if cp(ipaPath, installPath) != 0 {
                _ = climessenger("install-stage", "复制 ipa 到安装位置失败")
                _ = rm(info[0])
                return 1
            }
            let result = shell(shellQuote("\(Bundle.main.bundlePath)/tshelper")
                               + " install " + shellQuote(installPath) + " > /dev/null 2>&1", uid: 0)
            _ = climessenger("install-stage", "TrollStore Helper 返回 \(result)")
            _ = rm(installPath)

            // 只清理 Payload，clang 目录留给下一次增量编译
            _ = rm(info[0])
            if result != 0 {
                _ = climessenger("install-hint", "安装未成功。可把生成的 ipa 传到设备，用 TrollStore / 自签工具安装。")
                return result
            }
            return 0
        }
        #endif

        // 导出场景：只生成产物，不安装
        _ = rm(info[0])
        return 0
    } else {
        // 命令行工具：直接运行看返回值
        let result = shell(shellQuote(executablePath))
        _ = climessenger("run-stage", "退出码 \(result)")
        _ = rm(info[0])
        return 0
    }
}

/// 解析 PRODUCT_NAME / EXECUTABLE_NAME。
/// 只有明确、完全展开的名字才采用；否则回退到 FCM 记录的可执行名。
private func resolveExecutableName(_ fallback: String, config: XcodeBuildConfig) -> String {
    var name = config.productName
        .replacingOccurrences(of: "$(TARGET_NAME)", with: fallback)
        .replacingOccurrences(of: "${TARGET_NAME}", with: fallback)
        .replacingOccurrences(of: "$(PRODUCT_NAME)", with: fallback)
        .replacingOccurrences(of: "${PRODUCT_NAME}", with: fallback)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if name.isEmpty || name.contains("$(") || name.contains("${") || name.contains("/") {
        name = fallback
    }
    return name
}

/// 把 pbxproj 里的路径（可能是相对路径）解析成工程内绝对路径
private func resolveProjectFilePath(_ raw: String, projectPath: String) -> String {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return "" }
    if value.hasPrefix("/") { return value }
    return (projectPath as NSString).appendingPathComponent(value)
}

private func messenger(_ status: Binding<String>?,_ progress: Binding<Double>?,_ tstat: String,_  tproc: Double) -> Void {
    DispatchQueue.main.async {
        if let status = status, let progress = progress {
            status.wrappedValue = tstat
            withAnimation {
                progress.wrappedValue = tproc
            }
        }
    }
}

func splitAndTrim(_ inputString: String) -> [String] {
    let parts = inputString.split(separator: ";")
    
    let trimmedParts = parts.map { $0.trimmingCharacters(in: .whitespaces) }
    
    return trimmedParts
}

#if stock
func sethome(to newHome: String) {
    let result = setenv("HOME", newHome, 1)
    
    if result == 0 {
        print("[sethome] \(newHome)\n")
    } else {
        print("[sethome] fault")
    }
}
#endif
