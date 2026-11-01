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

/// 扫描工程内的头文件搜索路径
/// 规则：目录名是 include / Headers / include* 的，或其父目录是 mbedtls / openssl 这类标准布局
func discoverHeaderPaths(_ projectPath: String) -> String {
    let fm = FileManager.default
    var paths: [String] = [projectPath]

    guard let en = fm.enumerator(atPath: projectPath) else { return "" }
    var count = 0
    for case let item as String in en {
        count += 1
        if count > 20000 { break }
        var isDir: ObjCBool = false
        let full = "\(projectPath)/\(item)"
        guard fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue else { continue }

        let name = (item as NSString).lastPathComponent
        // 跳过构建产物与 VCS 目录
        if name == ".git" || name == "build" || name == "Payload" || name == "clang" ||
           name == "node_modules" || name.hasPrefix(".") {
            en.skipDescendants()
            continue
        }
        let lower = name.lowercased()
        // 常见头文件目录
        if lower == "include" || lower == "includes" || lower == "headers" ||
           lower == "include_debug" || lower == "public" {
            paths.append(full)
        }
    }

    // 去重并生成 -I 参数（加引号，路径可能含空格）
    var seen = Set<String>()
    var flags = ""
    for path in paths where !seen.contains(path) {
        seen.insert(path)
        flags += " -I'\(path)'"
    }
    return flags
}

/// 找出本机真正可用的 SDK 名
/// 优先：工程指定的（若已安装）→ 同主版本最高的 → 设置里的默认 → 任意一个已安装的
func resolveAvailableSDK(_ requested: String) -> String {
    let fm = FileManager.default
    let installed = ((try? fm.contentsOfDirectory(atPath: global_sdkpath)) ?? [])
        .filter { $0.hasPrefix("iPhoneOS") && $0.hasSuffix(".sdk") }

    if installed.isEmpty { return requested }
    if installed.contains(requested) { return requested }

    // 同主版本（例如 16.5 找不到时，用 16.x）
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

    // 设置里的默认 SDK
    let fallback = UserDefaults.standard.string(forKey: "sdk") ?? ""
    if installed.contains(fallback) {
        print("SDK \"\(requested)\" 未安装，自动使用默认 \"\(fallback)\"")
        return fallback
    }

    // 任意一个最简单的
    if let any = installed.sorted(by: { versionKey($0) < versionKey($1) }).last {
        print("SDK \"\(requested)\" 未安装，自动使用 \"\(any)\"")
        return any
    }
    return requested
}

/// 把 iPhoneOS16.4.sdk 转成可比较的数字元组
func versionKey(_ sdkName: String) -> [Int] {
    let raw = sdkName
        .replacingOccurrences(of: "iPhoneOS", with: "")
        .replacingOccurrences(of: ".sdk", with: "")
    return raw.split(separator: ".").map { Int($0) ?? 0 }
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

    var EXEC = ""
    if !SwiftFiles.isEmpty {
        #if jailbreak
        if !MFiles.isEmpty {
            EXEC += MFiles.map { mFile in
                "clang-14 -D\(ProjectInfo.Macro) \(objcFlags) -fmodules \(apiextension.build_sub) -target arm64-apple-ios\(ProjectInfo.TG) -c '\(ProjectInfo.ProjectPath)/\(mFile)' \(AFiles.joined(separator: " ")) -o '\(info[4])/\(UUID()).o' ; "
            }.joined()
        }
        EXEC += """
        swiftc -D\(ProjectInfo.Macro) \(SwiftFiles.map { "\(ProjectInfo.ProjectPath)/\($0)" }.joined(separator: " ")) \(AFiles.map { "\(ProjectInfo.ProjectPath)/\($0)" }.joined(separator: " ")) \(MFiles.isEmpty ? "" : "clang/*.o") \(apiextension.build) \
        \(FileManager.default.fileExists(atPath: info[5]) ? "-import-objc-header '\(info[5])'" : "") -parse-as-library -target arm64-apple-ios\(ProjectInfo.TG) -o '\(info[1])/\(ProjectInfo.Executable)'
        """
        #elseif trollstore
        print("TrollStore 版本目前不支持 Swift 工程！\n")
        return 1
        #endif
    } else {
        #if jailbreak
        EXEC += """
        clang-14 -D\(ProjectInfo.Macro) \(objcFlags) \(frameflags) -fmodules \(apiextension.build) -target arm64-apple-ios\(ProjectInfo.TG) \(MFiles.map { "\(ProjectInfo.ProjectPath)/\($0)" }.joined(separator: " ")) \(AFiles.map { "\(ProjectInfo.ProjectPath)/\($0)" }.joined(separator: " ")) \
        -o '\(info[1])/\(ProjectInfo.Executable)'
        """
        #elseif trollstore
        EXEC += """
        clang-14 -D\(ProjectInfo.Macro) \(objcFlags) \(frameflags) -fmodules \(apiextension.build) -target arm64-apple-ios\(ProjectInfo.TG) \(MFiles.map { "\(ProjectInfo.ProjectPath)/\($0)" }.joined(separator: " ")) \(AFiles.map { "\(ProjectInfo.ProjectPath)/\($0)" }.joined(separator: " ")) \
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

    try? copyc(from: info[2], to: info[1])
    _ = rm("\(info[1])/DontTouchMe.plist")

    #if !stock
    if !apiextension.bef.isEmpty {
        messenger(status,progress,"running api-exec-stage (before)",0.3)
        if climessenger("api-exec-stage","","\(CDEXEC) ; \(apiextension.bef)",nil,bashenv) != 0 {
            _ = climessenger("error-occurred", "running api-exec-stage failed")
            _ = rm(info[0])
            _ = rm(info[4])
            return 1
        }
    }
    messenger(status,progress,"compiling \(ProjectInfo.Executable)",0.4)
    if climessenger("compiler-stage","","\(CDEXEC) ; \(EXEC)", nil, bashenv) != 0 {
        _ = climessenger("compiling-failed","compiling \(ProjectInfo.Executable) failed")
        _ = rm(info[0])
        _ = rm(info[4])
        return 1
    }
    #else
    // -->>> magic compiler <<<--
    sethome(to: "\(global_documents)")
    dylock("\(Bundle.main.bundlePath)/toolchain/bin/clang.dylib");
    for file in MFiles {
        if dyexec("\(Bundle.main.bundlePath)/toolchain/bin/clang.dylib", "clang -I\(Bundle.main.bundlePath)/toolchain/lib/clang/16.0.0/include -isysroot \(info[3]) -target arm64-apple-ios\(ProjectInfo.TG) -c \(ProjectInfo.ProjectPath)/\(file) -o \(info[4])/\(UUID()).o") != 0 {
            print("[!] clang 可能已崩溃。如果 clang 没有给出具体错误，请重启应用后重试！\n")
            _ = rm(info[0])
            _ = rm(info[4])
            return -1
        }
    }
    dyunlock();
    //MachO!!
    let ofiles = FindFilesStack(ProjectInfo.ProjectPath, [".o"], splitAndTrim(apiextension.ign) + ["Resources"])
    if dyexec("\(Bundle.main.bundlePath)/toolchain/bin/ld.dylib", "ld -ObjC -lc -lc++ \(ofiles.map { "\(ProjectInfo.ProjectPath)/\($0)" }.joined(separator: " ")) -syslibroot \(info[3]) \(frameflags) -o \(info[1])/\(ProjectInfo.Executable)") != 0 {
        print("[!] 链接失败！\n")
        _ = rm(info[0])
        _ = rm(info[4])
        return -1
    }
    sethome(to: "\(global_container)")
    // -->>> magic ending <<<--
    #endif

    #if !stock
    messenger(status,progress,"running api-exec-stage (after)",0.5)
    if !apiextension.aft.isEmpty {
        if climessenger("api-exec-stage","","\(CDEXEC) ; \(apiextension.aft)",nil,bashenv) != 0 {
            _ = climessenger("error-occurred", "running api-exec-stage failed")
            _ = rm(info[0])
            _ = rm(info[4])
            return 1
        }
    }
    #endif

    if ProjectInfo.TYPE == "Applications" {
        messenger(status,progress,"compressing \(ProjectInfo.Executable) into .ipa archive",0.5)
        #if !stock
        shell("ldid -S'\(info[6])' '\(info[1])/\(ProjectInfo.Executable)'", uid: 0)
        #endif

        libzip_zip("\(ProjectInfo.ProjectPath)/Payload", "\(ProjectInfo.ProjectPath)/ts.ipa", true)

        //installing app
        messenger(status,progress,"installing \(ProjectInfo.Executable)",0.7)
        var result: Int = 0
        #if !stock
        if erase {
            killTaskWithProcessName(ProjectInfo.Executable)
            result = shell("\(Bundle.main.bundlePath)/tshelper install '\(ProjectInfo.ProjectPath)/ts.ipa' > /dev/null 2>&1", uid: 0)
            _ = climessenger("install--stage","TrollStore Helper returned \(String(result))")
        }
        #endif
        _ = rm(info[0])
        _ = rm(info[4])
        if erase {
            _ = rm("\(ProjectInfo.ProjectPath)/ts.ipa")
        }
        #if !stock
        return result
        #else
        return 0
        #endif
    } else {
        shell("ldid -S'\(info[6])' '\(info[1])/\(ProjectInfo.Executable)'")
        let result = shell("\"\(info[1])/\(ProjectInfo.Executable)\"")
        print("[*] Binary returned \(result)\n")
        _ = rm(info[0])
        _ = rm(info[4])
        return 0;
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
