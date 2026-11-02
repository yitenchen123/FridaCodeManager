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
 */

import Foundation
import SwiftUI
import Darwin

func typecheck(_ ProjectInfo: Project) -> Void {
    let info: [String] = ["\(ProjectInfo.ProjectPath)/Payload","\(ProjectInfo.ProjectPath)/Payload/\(ProjectInfo.Executable).app","\(ProjectInfo.ProjectPath)/Resources","\(global_sdkpath)/\(ProjectInfo.SDK)","\(ProjectInfo.ProjectPath)/clang","\(ProjectInfo.ProjectPath)/bridge.h","\(ProjectInfo.ProjectPath)/entitlements.plist","\(load("\(ProjectInfo.ProjectPath)/api.api"))"]
    //PayloadPath  info[0]
    //AppPath      info[1]
    //Resources    info[2]
    //SDKPath      info[3]
    //ClangPath    info[4]
    //ClangBridge  info[5]
    //Entitlements info[6]
    //API          info[7]

    let fileManager = FileManager.default

    if !fileManager.fileExists(atPath: info[3]) {
       return
    }

    //define build bash environment
    let bashenv: [String] = ["SDKROOT=\(info[3])","CPATH=\(Bundle.main.bundlePath)/include","LIBRARY_PATH=\(info[3])/usr/lib","FRAMEWORK_PATH=/System/Library/Frameworks:/System/Library/PrivateFrameworks","HOME=\(global_container)/.cache/.\(ProjectInfo.SDK)"]

    var apiextension: ext = ext(build:"",build_sub: "",bef: "", aft:"", ign: "")
    if !info[7].isEmpty {
        apiextension = api(info[7], ProjectInfo)
    }

    //finding code files
    let ignoreList = makeBuildIgnoreList(apiextension.ign)
    let MFiles = FindFilesStack(ProjectInfo.ProjectPath, [".m", ".c", ".mm", ".cpp", ".cc", ".cxx", ".s"], ignoreList)
    let SwiftFiles = FindFilesStack(ProjectInfo.ProjectPath, [".swift"], ignoreList)

    // 头文件搜索路径与构建保持一致：工程配置优先，否则目录扫描 + header map
    let xcodeConfig = loadXcodeBuildConfig(projectPath: ProjectInfo.ProjectPath)
    var headerFlags = ""
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
    } else {
        let dirs = discoverHeaderDirectories(ProjectInfo.ProjectPath)
        headerFlags = dirs.map { " -I" + shellQuote($0) }.joined()
        swiftHeaderFlags = swiftClangImporterFlags(headerDirectories: dirs)
    }
    swiftHeaderFlags += " -Xcc -I" + shellQuote(ProjectInfo.ProjectPath)

    let headerMap = buildHeaderMap(projectPath: ProjectInfo.ProjectPath, ignorePrefixes: ignoreList)
    if headerMap.count > 0 {
        headerFlags += " -I" + shellQuote(headerMap.directory)
        swiftHeaderFlags += " -Xcc -I" + shellQuote(headerMap.directory)
    }

    let targetArchs = resolveTargetArchitectures(from: xcodeConfig)
    let targetArch = targetArchs.first(where: { $0 == "arm64" }) ?? targetArchs[0]
    let targetTriple = "\(targetArch)-apple-ios\(ProjectInfo.TG)"
    let sdkFlag = " -isysroot " + shellQuote(info[3])
    let macroFlag = ProjectInfo.Macro.isEmpty ? "" : " -D" + shellQuote(ProjectInfo.Macro)
    let modulesFlag = xcodeConfig.enableModules ? " -fmodules" : ""
    let arcFlag = (xcodeConfig.enableObjCARC && !apiextension.noarc)
        ? " -fobjc-arc" : " -fno-objc-arc"
    // 语法检查不链接，但仍需要正确的语言标准
    let cStd = clangLanguageStandardFlags(from: xcodeConfig, forCpp: false)
    let cxxStd = clangLanguageStandardFlags(from: xcodeConfig, forCpp: true)

    func clangCheckFlags(for source: String) -> String {
        let ext = (source as NSString).pathExtension.lowercased()
        var flags = macroFlag + headerFlags + sdkFlag + modulesFlag
        if ext == "s" { return flags }
        if ext == "m" || ext == "mm" { flags += arcFlag }
        let isCpp = ext == "mm" || ext == "cpp" || ext == "cc" || ext == "cxx"
        return flags + (isCpp ? cxxStd : cStd)
    }

    var EXEC = ""
    if !SwiftFiles.isEmpty {
        if !MFiles.isEmpty {
            EXEC += MFiles.map { mFile in
                "clang-14 " + clangCheckFlags(for: mFile) + " " + apiextension.build_sub
                    + " -target " + targetTriple + " -fsyntax-only " + quoted(ProjectInfo.ProjectPath, mFile)
                    + " ; "
            }.joined()
        }
        let hasMainSwift = SwiftFiles.contains { ($0 as NSString).lastPathComponent == "main.swift" }
        let parseAsLibrary = hasMainSwift ? "" : " -parse-as-library"
        let bridge = FileManager.default.fileExists(atPath: info[5])
            ? " -import-objc-header " + shellQuote(info[5]) : ""
        EXEC += "swiftc -typecheck " + macroFlag + swiftHeaderFlags + " -sdk " + shellQuote(info[3])
            + " -target " + targetTriple
            + " " + quotedList(ProjectInfo.ProjectPath, SwiftFiles)
            + bridge + parseAsLibrary
    } else {
        EXEC += "clang-14 " + clangCheckFlags(for: "")
            + " " + apiextension.build_sub
            + " -target " + targetTriple + " -fsyntax-only "
            + quotedList(ProjectInfo.ProjectPath, MFiles)
    }

    let (CDEXEC) = ("cd " + shellQuote(ProjectInfo.ProjectPath))

    //typechecking
    _ = climessenger("","","\(CDEXEC) ; \(EXEC)", nil, bashenv)
}
