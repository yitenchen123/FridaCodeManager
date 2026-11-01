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
func discoverHeaderPaths(_ projectPath: String) -> String {
    let fm = FileManager.default
    var paths: [String] = [projectPath]

    guard let en = fm.enumerator(atPath: projectPath) else { return "" }
    var count = 0
    for case let item as String in en {
        count += 1
        if count > 30000 { break }

        var isDir: ObjCBool = false
        let full = "\(projectPath)/\(item)"
        guard fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue else { continue }

        let name = (item as NSString).lastPathComponent
        // 跳过构建产物、版本控制、以及明显与源码无关的目录
        if name == ".git" || name == "build" || name == "Payload" || name == "clang" ||
           name == "node_modules" || name.hasPrefix(".") ||
           name == "DerivedData" || name == "java_runtimes" || name == "depends" {
            en.skipDescendants()
            continue
        }

        let lower = name.lowercased()
        if lower == "include" || lower == "includes" || lower == "headers" ||
           lower == "include_debug" || lower == "public" {
            paths.append(full)
            continue
        }

        // 目录里直接含 .h 文件的，也当作头文件目录
        let children = (try? fm.contentsOfDirectory(atPath: full)) ?? []
        if children.contains(where: { $0.hasSuffix(".h") }) {
            paths.append(full)
        }
    }

    // 去重并生成 -I 参数（路径可能含空格，用单引号包住）
    var seen = Set<String>()
    var flags = ""
    for path in paths where !seen.contains(path) {
        seen.insert(path)
        flags += " -I'\(path)'"
    }
    return flags
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

    //Processing API
    var apiextension: ext = ext(build:"",build_sub: "",bef: "", aft:"", ign: "")
    if !info[7].isEmpty {
        apiextension = api(info[7], ProjectInfo)
    }

    print("FridaCodeManager \(global_version)\n ")
    _ = climessenger("info","App Name: \(ProjectInfo.Executable)\nBundleID: \(ProjectInfo.BundleID)\nSDK:      \(ProjectInfo.SDK)")

    //finding code files
    messenger(status,progress,"finding code files",0.1)
    let ignoreList = splitAndTrim(apiextension.ign) + ["Resources"]
    let (MFiles, SwiftFiles) = (
        FindFilesStack(ProjectInfo.ProjectPath, [".m", ".c", ".mm", ".cpp"], ignoreList),
        FindFilesStack(ProjectInfo.ProjectPath, [".swift"], ignoreList)
    )
    // 静态库来源有两处：普通 .a，以及 .xcframework 里的设备切片
    let AFiles = (collectIOSStaticLibraries(projectPath: ProjectInfo.ProjectPath, ignorePrefixes: ignoreList)
                + collectIOSStaticFromXCFrameworks(projectPath: ProjectInfo.ProjectPath, ignorePrefixes: ignoreList)).sorted()

    //finding frameworks
    messenger(status,progress,"finding frameworks", 0.15)
    let frameworks = !MFiles.isEmpty && FileManager.default.fileExists(atPath: info[3]) ? findFrameworks(in: URL(fileURLWithPath: ProjectInfo.ProjectPath), SDKPath: info[3], ignorePaths: splitAndTrim(apiextension.ign) + ["Resources"]) : []
    // 工程自带的 .framework（如 terracotta）：需要额外传 -F 搜索路径，
    // 否则符号会缺失（_terracotta_ios_* 之类）。
    let localFrameworks = collectIOSFrameworks(projectPath: ProjectInfo.ProjectPath,
                                               ignorePrefixes: splitAndTrim(apiextension.ign) + ["Resources"])
    var localFrameworkFlags = ""
    for item in localFrameworks {
        let fwDir = ((item.path as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        localFrameworkFlags += " -F'" + fwDir + "' -framework " + item.name
    }

    // Xcode 工程里的 OTHER_LDFLAGS 直接透传：
    // 例如 "-Wl,-U,_terracotta_ios_start" 表示允许该符号未定义（运行时解析），
    // 以及 -L<path> -lmbedtls 这类库搜索与链接参数。
    // 优先读取 .xcodeproj 里的真实构建设置。
    // Xcode 用 HEADER_SEARCH_PATHS / OTHER_LDFLAGS 精确控制编译，
    // 靠扫描目录猜测必然对不上，这是之前链路反复失败的根因。
    let xcodeConfig = loadXcodeBuildConfig(projectPath: ProjectInfo.ProjectPath)
    var headerFlags = ""
    if xcodeConfig.sourceFound && !xcodeConfig.headerSearchPaths.isEmpty {
        headerFlags = clangIncludeFlags(from: xcodeConfig)
        var report = "读取 Xcode 工程配置：头文件路径 \(xcodeConfig.headerSearchPaths.count) 个"
        report += "，链接参数 \(xcodeConfig.otherLDFlags.count) 条"
        _ = climessenger("xcode-config", report)
        for path in xcodeConfig.headerSearchPaths.prefix(10) {
            _ = climessenger("xcode-config", "  -I " + path.replacingOccurrences(of: ProjectInfo.ProjectPath + "/", with: ""))
        }
    } else {
        // 没有工程配置时退回目录扫描
        headerFlags = discoverHeaderPaths(ProjectInfo.ProjectPath)
        _ = climessenger("xcode-config", "未找到 .xcodeproj 配置，改用目录扫描")
    }

    let xcodeLinkFlags = clangLinkFlags(from: xcodeConfig)
    let defineFlags = clangDefineFlags(from: xcodeConfig)

    let frameflags = (frameworks.map { "-framework \($0)" }.joined(separator: " ")
                    + localFrameworkFlags
                    + xcodeLinkFlags)

    // 如果工程带 .github/workflows，优先执行其中的依赖准备步骤。
    // 很多项目的第三方库（mbedtls / JRE / 预编译 dylib）不进 git，
    // 而是在 CI 里现下，直接编译必然缺头文件。
    // Swift Package 依赖：先尝试解析，失败不阻断（设备可能没装 swift）
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
        // 依赖下载完可能新增了头文件目录，重新扫描
    }

    //setting up command
    messenger(status,progress,"setting up compiler",0.2)

    // 现代 Objective-C 基本都用 ARC；不开 ARC 时任何 __weak 都会直接报错
    // （cannot create __weak reference in file using manual reference counting）。
    // 如需关闭，在工程的 api.api 里写 <noarc>true</noarc>。
    var objcFlags = " -fobjc-arc -fobjc-link-runtime" + headerFlags + defineFlags
    // Xcode 工程里显式关闭 ARC 时以工程配置为准
    if !xcodeConfig.enableObjCARC || apiextension.noarc {
        objcFlags = " -fno-objc-arc"
    }

    // 双引号常量：直接写转义引号在多层的 Swift 字符串里极易出错，统一用 Q
    let Q = String(Character(Unicode.Scalar(34)))
    // 失败文件名写入该文件，避免在 Swift 字符串里拼接 shell 变量（$ 会被当成插值）
    let FAIL_LOG = quoted(ProjectInfo.ProjectPath, "fcm-failed-files.txt")
    let LINK_FLAG = quoted(ProjectInfo.ProjectPath, "fcm-link-failed.txt")
    var EXEC = ""
    if !SwiftFiles.isEmpty {
        #if jailbreak
        if !MFiles.isEmpty {
            // shell() 用 bash -e 执行，任何一条 clang 返回非 0 都会让脚本立刻退出。
            // 所以每条命令都用 || 记录失败文件名，全部跑完再统一判定。
            EXEC += "rm -f " + FAIL_LOG + " ; "
            EXEC += MFiles.map { mFile in
                [
                "clang-14 -D\(ProjectInfo.Macro) \(objcFlags) -fmodules \(apiextension.build_sub) -target arm64-apple-ios\(ProjectInfo.TG) -c ",
                quoted(ProjectInfo.ProjectPath, mFile),
                " ", AFiles.joined(separator: " "),
                " -o '", info[4], "/", UUID().uuidString, ".o' || ",
                "echo ", Q, mFile, Q, " >> " + FAIL_LOG
                ].joined()
            }.joined()
        }
        EXEC += """
        swiftc -D\(ProjectInfo.Macro) \(quotedList(ProjectInfo.ProjectPath, SwiftFiles)) \(quotedList(ProjectInfo.ProjectPath, AFiles)) \(MFiles.isEmpty ? "" : "clang/*.o") \(apiextension.build) \
        \(FileManager.default.fileExists(atPath: info[5]) ? "-import-objc-header '\(info[5])'" : "") -parse-as-library -target arm64-apple-ios\(ProjectInfo.TG) -o '\(info[1])/\(ProjectInfo.Executable)'
        """
        EXEC += " || true ; "
        EXEC += "if [ -s " + FAIL_LOG + " ]; then echo '以下文件编译失败：'; cat " + FAIL_LOG + "; exit 1; fi"
        #elseif trollstore
        print("TrollStore 版本目前不支持 Swift 工程！\n")
        return 1
        #endif
    } else {
        #if jailbreak
        // 纯 ObjC 工程：增量 + 并行编译。
        // 只为「源码或编译参数变化」的文件生成编译单元，
        // 其余直接复用已有 .o，二次构建可以快一个数量级。
        let objectDir = "\(ProjectInfo.ProjectPath)/clang"
        let token = flagsToken(macro: ProjectInfo.Macro,
                               sdk: ProjectInfo.SDK,
                               target: ProjectInfo.TG,
                               headerFlags: headerFlags,
                               extraFlags: objcFlags)
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
            let errorDir = "\(ProjectInfo.ProjectPath)/.fcm-errors"
            let compileUnits = pending.map { unit in
                // 错误日志按 .o 名区分；失败时把源文件写进汇总清单，
                // 具体 error 行由脚本末尾从各自的日志里提取。
                let errName = (unit.object as NSString).lastPathComponent + ".txt"
                return [
                    "clang-14 -D\(ProjectInfo.Macro) \(objcFlags) -fmodules \(apiextension.build) -target arm64-apple-ios\(ProjectInfo.TG) -c ",
                    quoted(ProjectInfo.ProjectPath, unit.source),
                    " -o ", quoted(ProjectInfo.ProjectPath, "./clang/" + (unit.object as NSString).lastPathComponent),
                    " > ", quoted(ProjectInfo.ProjectPath, "./.fcm-errors/" + errName),
                    " 2>&1 || echo ", Q, unit.source, Q
                    ].joined()
            }
            let unitsFile = "\(ProjectInfo.ProjectPath)/.fcm-units.txt"
            cfile(atPath: unitsFile, withContent: compileUnits.joined(separator: "\n"))

            var jobs = ProcessInfo.processInfo.activeProcessorCount
            if jobs > 8 { jobs = 8 }
            if jobs < 2 { jobs = 2 }
            let runnerFile = "\(ProjectInfo.ProjectPath)/.fcm-run.sh"
            cfile(atPath: runnerFile, withContent:
                "#!/bin/sh\nrm -rf '" + errorDir + "' ; mkdir -p '" + errorDir + "'\n"
                + "cat '" + unitsFile + "' | xargs -P " + String(jobs) + " -I {} sh -c '{}'\n")

            EXEC += "cd '\(ProjectInfo.ProjectPath)' ; rm -f " + FAIL_LOG + " ; "
            EXEC += "sh '" + runnerFile + "' > " + FAIL_LOG + " 2>&1 ; "
            EXEC += "rm -f '" + runnerFile + "' '" + unitsFile + "' ; "
        } else {
            EXEC += "cd '\(ProjectInfo.ProjectPath)' ; rm -f " + FAIL_LOG + " ; "
        }

        // 链接：收集所有 .o（含复用的）
        EXEC += "mkdir -p '" + info[1] + "' ; "
        EXEC += """
        clang-14 -D\(ProjectInfo.Macro) \(objcFlags) \(frameflags) -fmodules \(apiextension.build) -target arm64-apple-ios\(ProjectInfo.TG) \(quotedList(ProjectInfo.ProjectPath, AFiles)) clang/*.o -o '\(info[1])/\(ProjectInfo.Executable)' || echo "LINK_FAILED" > '" + LINK_FLAG + "'
        """
        EXEC += " ; "
        // 编译失败与链接失败分开报告，避免把链接错误说成"这些文件编译失败"
        // 先列出失败文件，再从各自的日志里提炼 error 行（忽略 warning，避免淹没）
        EXEC += "if [ -s " + FAIL_LOG + " ]; then echo '以下文件编译失败：'; cat " + FAIL_LOG + "; "
        EXEC += "echo ''; echo '—— 错误摘要 ——'; "
        EXEC += "cat " + FAIL_LOG + " | sed 's|^|./|' > /dev/null ; "
        EXEC += "for f in .fcm-errors/*.txt; do "
        EXEC += "[ -f \"$f\" ] || continue ; "
        EXEC += "E=$(grep -m3 'error:' \"$f\" 2>/dev/null) ; "
        EXEC += "if [ -n \"$E\" ]; then echo \"$(basename $f .txt):\"; echo \"$E\"; fi ; "
        EXEC += "done ; fi ; "
        EXEC += "if [ -f '" + LINK_FLAG + "' ]; then echo '链接失败，请查看上面的 ld 输出'; rm -f '" + LINK_FLAG + "' ; exit 1 ; fi ; "
        EXEC += "if [ -s " + FAIL_LOG + " ]; then exit 1 ; fi"
        #elseif trollstore
        EXEC += """
        clang-14 -D\(ProjectInfo.Macro) \(objcFlags) \(frameflags) -fmodules \(apiextension.build) -target arm64-apple-ios\(ProjectInfo.TG) \(quotedList(ProjectInfo.ProjectPath, MFiles)) \(quotedList(ProjectInfo.ProjectPath, AFiles)) \
        -o '\(info[1])/\(ProjectInfo.Executable)'
        """
        #endif
    }

    let (CDEXEC) = ("cd '\(ProjectInfo.ProjectPath)'")

    //compiling app
    if !frameworks.isEmpty {
        _ = climessenger("framework-finder","\(frameworks.map { "\($0)" }.joined(separator: "\n"))")
    }

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

    // ---------------- 编译 ----------------
    messenger(status, progress, BuildStage.compile.display, 0.3)

    // 把编译脚本写入文件再执行：Air2 有 200+ 源文件，
    // 拼成 bash -c 的单个参数会超出 posix_spawn 上限（Failed to spawn process）。
    let buildScript = "\(global_container)/tmp/fcm-build.sh"
    _ = rm(buildScript)
    cfile(atPath: buildScript, withContent: "#!/bin/bash\nset +e\n" + CDEXEC + "\n" + EXEC)
    shell("chmod +x '" + buildScript + "'", uid: 501, env: [])

    // bashenv 提供 SDKROOT / CPATH / LIBRARY_PATH，缺了会找不到系统头文件和库
    var compileEnv: [String] = []
    #if !stock
    compileEnv = bashenv
    #endif
    let compileResult = runCaptured("'" + buildScript + "'", uid: 501, env: compileEnv)
    _ = rm(buildScript)

    if !compileResult.succeeded {
        _ = climessenger("compiler-stage", "编译或链接失败")
        if !compileResult.output.isEmpty {
            _ = climessenger("compiler-output", compileResult.output)
        }
        _ = rm(info[0])
        _ = rm(info[4])
        return 1
    }
    _ = climessenger("compiler-stage", "编译完成")

    // ---------------- 打包 .app ----------------
    messenger(status, progress, BuildStage.bundle.display, 0.45)

    let stagingApp = info[1]
    _ = rm(stagingApp)
    cfolder(atPath: stagingApp)

    // 资源编译：storyboard/xib 交给 ibtool，xcassets 交给 actool，
    // 同时补齐 Info.plist 必需键并生成 PkgInfo，尽量贴近 Xcode 的产出结构。
    let resourceReport = compileResources(from: info[2],
                                          into: stagingApp,
                                          projectName: ProjectInfo.Executable,
                                          executable: ProjectInfo.Executable,
                                          sdkPath: info[3],
                                          minimumOS: ProjectInfo.TG)

    var bundleSummary = "资源：拷贝 \(resourceReport.copied) 项"
    if resourceReport.storyboards > 0 { bundleSummary += "，界面 \(resourceReport.storyboards) 个" }
    if resourceReport.assetCatalogs > 0 { bundleSummary += "，资源目录 \(resourceReport.assetCatalogs) 个" }
    _ = climessenger("bundle-stage", bundleSummary)
    for warning in resourceReport.warnings {
        _ = climessenger("bundle-stage", "  提示：" + warning)
    }

    // 复制可执行文件（签名前需要它已在 .app 内）
    let builtBinary = "\(info[1])/\(ProjectInfo.Executable)"
    if !FileManager.default.fileExists(atPath: builtBinary) {
        _ = climessenger("bundle-stage", "可执行文件缺失：\(builtBinary)")
        _ = climessenger("bundle-hint", "链接阶段没有产出，请查看上面的编译日志")
        _ = rm(info[0])
        return 1
    }

    // ---------------- 脚本阶段 ----------------
    // Xcode 的顺序：编译 → 链接 → 拷资源 → 脚本阶段 → 签名。
    // 很多 GitHub 项目把依赖下载、资源拷贝放在这里，
    // 不执行就会缺文件（Air2 的 Java 核心与运行时资源即如此）。
    let shellPhases = loadShellBuildPhases(projectPath: ProjectInfo.ProjectPath)
    if !shellPhases.isEmpty {
        messenger(status, progress, "执行构建脚本", 0.5)
        _ = climessenger("shell-phase", "检测到 \(shellPhases.count) 个脚本阶段")
        _ = runShellBuildPhases(shellPhases,
                                projectPath: ProjectInfo.ProjectPath,
                                appPath: stagingApp,
                                configuration: erase ? "Release" : "Debug") { line in
            _ = climessenger("shell-phase", line)
        }
    }

    // ---------------- 签名 ----------------
    messenger(status, progress, BuildStage.sign.display, 0.55)

    let toolchain = detectToolchain()
    if toolchain.ldidPath == nil {
        _ = climessenger("sign-stage", "找不到 ldid，无法签名。安装：apt install ldid")
        _ = rm(info[0])
        return 1
    }

    let executablePath = "\(stagingApp)/\(ProjectInfo.Executable)"
    let signResult = signBinary(executablePath, entitlements: info[6], ldid: toolchain.ldidPath!)
    if !signResult.0 {
        _ = climessenger("sign-stage", "签名失败：\(signResult.1)")
        _ = climessenger("sign-hint", "请检查 entitlements.plist 是否与本机越狱环境匹配")
        _ = rm(info[0])
        return 1
    }
    _ = climessenger("sign-stage", "签名完成：\(ProjectInfo.Executable)")

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

    let macho = verifyMachO(executablePath)
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
            killTaskWithProcessName(ProjectInfo.Executable)
            let installPath = "\(ProjectInfo.ProjectPath)/ts.ipa"
            _ = rm(installPath)
            if cp(ipaPath, installPath) != 0 {
                _ = climessenger("install-stage", "复制 ipa 到安装位置失败")
                _ = rm(info[0])
                return 1
            }
            let result = shell("\(Bundle.main.bundlePath)/tshelper install '\(installPath)' > /dev/null 2>&1", uid: 0)
            _ = climessenger("install-stage", "TrollStore Helper 返回 \(result)")
            _ = rm(installPath)

            _ = rm(info[0])
            _ = rm(info[4])
            if result != 0 {
                _ = climessenger("install-hint", "安装未成功。可把生成的 ipa 传到设备，用 TrollStore / 自签工具安装。")
                return result
            }
            return 0
        }
        #endif

        _ = rm(info[0])
        _ = rm(info[4])
        return 0
    } else {
        // 命令行工具：直接运行看返回值
        let result = shell("\"\(executablePath)\"")
        _ = climessenger("run-stage", "退出码 \(result)")
        _ = rm(info[0])
        _ = rm(info[4])
        return 0
    }
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
