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
    let (MFiles, AFiles, SwiftFiles) = (FindFilesStack(ProjectInfo.ProjectPath, [".m", ".c", ".mm", ".cpp"], splitAndTrim(apiextension.ign) + ["Resources"]), FindFilesStack(ProjectInfo.ProjectPath, [".a"], splitAndTrim(apiextension.ign) + ["Resources"]), FindFilesStack(ProjectInfo.ProjectPath, [".swift"], splitAndTrim(apiextension.ign) + ["Resources"]))

    //finding frameworks
    messenger(status,progress,"finding frameworks", 0.15)
    let frameworks = !MFiles.isEmpty && FileManager.default.fileExists(atPath: info[3]) ? findFrameworks(in: URL(fileURLWithPath: ProjectInfo.ProjectPath), SDKPath: info[3], ignorePaths: splitAndTrim(apiextension.ign) + ["Resources"]) : []
    let frameflags = frameworks.map { "-framework \($0)" }.joined(separator: " ")

    //setting up command
    messenger(status,progress,"setting up compiler",0.2)

    // 如果工程带 .github/workflows，优先执行其中的依赖准备步骤。
    // 很多项目的第三方库（mbedtls / JRE / 预编译 dylib）不进 git，
    // 而是在 CI 里现下，直接编译必然缺头文件。
    let prepSteps = ciPrepSteps(for: ProjectInfo.ProjectPath)
    if !prepSteps.isEmpty {
        _ = climessenger("ci-prep", "检测到 \(prepSteps.count) 个 CI 准备步骤，开始执行…")
        _ = runCIPrepSteps(prepSteps, projectPath: ProjectInfo.ProjectPath) { line in
            _ = climessenger("ci-prep", line)
        }
        // 依赖下载完可能新增了头文件目录，重新扫描
    }

    // 扫描工程内的头文件目录。Xcode 工程用 HEADER_SEARCH_PATHS 指定这些路径，
    // FCM 之前完全不知道，导致 #import <mbedtls/xxx.h> 这类写法必然找不到。
    let headerFlags = discoverHeaderPaths(ProjectInfo.ProjectPath)

    // 现代 Objective-C 基本都用 ARC；不开 ARC 时任何 __weak 都会直接报错
    // （cannot create __weak reference in file using manual reference counting）。
    // 如需关闭，在工程的 api.api 里写 <noarc>true</noarc>。
    var objcFlags = " -fobjc-arc -fobjc-link-runtime" + headerFlags
    if apiextension.noarc {
        objcFlags = ""
    }

    // 双引号常量：直接写转义引号在多层的 Swift 字符串里极易出错，统一用 Q
    let Q = String(Character(Unicode.Scalar(34)))
    // 失败文件名写入该文件，避免在 Swift 字符串里拼接 shell 变量（$ 会被当成插值）
    let FAIL_LOG = quoted(ProjectInfo.ProjectPath, "fcm-failed-files.txt")
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
        // 纯 ObjC 工程：并行编译，单文件失败不中断。
        // 并行编译：每个编译单元写成一行，交给 xargs -P 多进程执行，
        // 与 Xcode 默认的并行编译一致。失败的文件名统一收集到 FAIL_LOG。
        let compileUnits = MFiles.map { mFile in
            [
                "clang-14 -D\(ProjectInfo.Macro) \(objcFlags) -fmodules \(apiextension.build) -target arm64-apple-ios\(ProjectInfo.TG) -c ",
                quoted(ProjectInfo.ProjectPath, mFile),
                " -o 'clang/", UUID().uuidString, ".o' 2>/dev/null || echo ",
                Q, mFile, Q
                ].joined()
        }
        let unitsFile = "\(ProjectInfo.ProjectPath)/.fcm-units.txt"
        cfile(atPath: unitsFile, withContent: compileUnits.joined(separator: "\n"))
        EXEC += "cd '\(ProjectInfo.ProjectPath)' ; rm -rf clang && mkdir -p clang ; rm -f " + FAIL_LOG + " ; "
        // 并行执行脚本单独写成文件，避免在 Swift 字符串里拼 shell 变量
        let runnerFile = "\(ProjectInfo.ProjectPath)/.fcm-run.sh"
        // 并行度在 Swift 侧算好，脚本里不出现 shell 变量，避免 Swift 插值冲突
        var jobs = ProcessInfo.processInfo.activeProcessorCount
        if jobs > 8 { jobs = 8 }
        if jobs < 2 { jobs = 2 }
        let runnerScript = "#!/bin/sh\n"
            + "cat '" + unitsFile + "' | xargs -P " + String(jobs) + " -I {} sh -c '{}'\n"
        cfile(atPath: runnerFile, withContent: runnerScript)
        EXEC += "sh '" + runnerFile + "' >> " + FAIL_LOG + " 2>&1 ; "
        EXEC += "rm -f '" + runnerFile + "' ; "
        EXEC += "rm -f '" + unitsFile + "' ; "
        EXEC += "mkdir -p '" + info[1] + "' ; "
        EXEC += """
        clang-14 -D\(ProjectInfo.Macro) \(objcFlags) \(frameflags) -fmodules \(apiextension.build) -target arm64-apple-ios\(ProjectInfo.TG) \(quotedList(ProjectInfo.ProjectPath, AFiles)) clang/*.o -o '\(info[1])/\(ProjectInfo.Executable)'
        """
        EXEC += " ; "
        EXEC += "if [ -s " + FAIL_LOG + " ]; then echo '以下文件编译失败：'; cat " + FAIL_LOG + "; exit 1; fi"
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

    do {
        let contents = try FileManager.default.contentsOfDirectory(atPath: info[2])
        for item in contents where item != "DontTouchMe.plist" && item != ".DS_Store" {
            try FileManager.default.copyItem(atPath: "\(info[2])/\(item)",
                                             toPath: "\(stagingApp)/\(item)")
        }
    } catch {
        _ = climessenger("bundle-stage", "复制资源失败：\(error.localizedDescription)")
        _ = rm(info[0])
        return 1
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
