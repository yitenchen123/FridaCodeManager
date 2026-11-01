/*
 XcodeProjectGenerator.swift

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

 生成 .xcodeproj/project.pbxproj。

 结构参照 Xcode 的真实产物：
   PBXProject → PBXNativeTarget → PBX*BuildPhase → PBXBuildFile → PBXFileReference
 一个可用的工程至少需要：

   - 每个源文件：PBXFileReference + PBXBuildFile + Sources 阶段引用
   - 每个资源：  PBXFileReference + Resources 阶段引用
   - 每个框架：  PBXFileReference + Frameworks 阶段引用
   - 目标：      PBXNativeTarget，含上面几个阶段
   - 配置：      XCBuildConfiguration（Debug/Release）+ XCConfigurationList
   - 工程：      PBXProject，含 targets 与 configurationList

 UUID 使用确定性哈希（与 Xcode 一致用 24 位大写十六进制），
 这样重新生成时不会因为 UUID 抖动导致 diff 爆炸。
 */

import Foundation

// MARK: - 模型

struct XcodeSourceFile {
    var relativePath: String      // 相对于工程根
    var fileType: String          // sourcecode.c.objc / sourcecode.swift ...
}

struct XcodeResourceFile {
    var relativePath: String
    var fileType: String
    var isFolder: Bool = false
}

struct XcodeFrameworkRef {
    var name: String              // UIKit / libz / terracotta
    var path: String              // System / 工程内相对路径
    var isSystem: Bool
}

struct XcodeProjectSpec {
    var projectName: String
    var bundleIdentifier: String
    var deploymentTarget: String
    var sources: [XcodeSourceFile]
    var resources: [XcodeResourceFile]
    var frameworks: [XcodeFrameworkRef]
    var headerSearchPaths: [String] = []
    var otherLDFlags: [String] = []
    var preprocessorDefinitions: [String] = []
    var infoPlistPath: String = ""
    var enableARC: Bool = true
}

// MARK: - UUID

/// 与 Xcode 一致的 24 位大写十六进制，由内容确定，保证可重现
private func xcUUID(_ parts: String...) -> String {
    // Xcode 的 UUID 是 24 位十六进制（96 位）。
    // 用两轮 FNV-1a 64 位拼出足够长度，并保证同一输入永远得到同一结果，
    // 这样重新生成工程时 UUID 不抖动，git diff 才看得清真实改动。
    let seed = parts.joined(separator: "\u{1}")
    var h1: UInt64 = 14695981039346656037
    for byte in seed.utf8 {
        h1 ^= UInt64(byte)
        h1 = h1 &* 1099511628211
    }
    var h2: UInt64 = 14695981039346656037
    for byte in (seed + "#2").utf8 {
        h2 ^= UInt64(byte)
        h2 = h2 &* 1099511628211
    }
    // 取 h1 的 12 位 + h2 的 12 位
    // 24 位十六进制 = 前 12 位取 h1 低 48 位，后 12 位取 h2 低 48 位
    return String(format: "%012llX%012llX", h1 & 0xFFFFFFFFFFFF, h2 & 0xFFFFFFFFFFFF)
}

private func swiftString(_ value: String) -> String {
    let escaped = value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"" + escaped + "\""
}

// MARK: - 文件类型推断

func xcodeFileType(for path: String) -> String {
    let ext = (path as NSString).pathExtension.lowercased()
    switch ext {
    case "m": return "sourcecode.c.objc"
    case "mm": return "sourcecode.cpp.objcpp"
    case "c": return "sourcecode.c.c"
    case "cpp", "cc", "cxx": return "sourcecode.cpp.cpp"
    case "swift": return "sourcecode.swift"
    case "h", "hpp": return "sourcecode.c.h"
    case "plist": return "text.plist.xml"
    case "xcassets": return "folder.assetcatalog"
    case "storyboard": return "file.storyboard"
    case "xib": return "file.xib"
    case "strings": return "text.plist.strings"
    case "json": return "text.json"
    case "png": return "image.png"
    case "jpg", "jpeg": return "image.jpeg"
    case "pdf": return "image.pdf"
    case "ttf", "otf": return "file"
    case "a": return "archive.ar"
    case "framework": return "wrapper.framework"
    case "xcframework": return "wrapper.xcframework"
    case "xcconfig": return "text.xcconfig"
    default: return "file"
    }
}

// MARK: - 生成

/// 生成 project.pbxproj 文本
func generatePBXProj(_ spec: XcodeProjectSpec) -> String {
    var out: [String] = []

    let projectUUID = xcUUID("project", spec.projectName)
    let targetUUID = xcUUID("target", spec.projectName)
    let sourcesPhaseUUID = xcUUID("phase", "sources")
    let resourcesPhaseUUID = xcUUID("phase", "resources")
    let frameworksPhaseUUID = xcUUID("phase", "frameworks")
    let mainGroupUUID = xcUUID("group", "main")
    let productsGroupUUID = xcUUID("group", "products")
    let projectConfigListUUID = xcUUID("configlist", "project")
    let targetConfigListUUID = xcUUID("configlist", "target")
    let debugProjectConfigUUID = xcUUID("config", "project", "Debug")
    let releaseProjectConfigUUID = xcUUID("config", "project", "Release")
    let debugTargetConfigUUID = xcUUID("config", "target", "Debug")
    let releaseTargetConfigUUID = xcUUID("config", "target", "Release")
    let productFileUUID = xcUUID("product", spec.projectName)

    // ---- 文件引用与构建文件 ----
    var fileRefs: [String] = []
    var buildFiles: [String] = []
    var sourceBuildFileUUIDs: [String] = []
    var resourceBuildFileUUIDs: [String] = []
    var frameworkBuildFileUUIDs: [String] = []

    // 源文件按目录分组
    var groupMembers: [String: [String]] = [:]
    var groupOrder: [String] = []

    for source in spec.sources {
        let fileRef = xcUUID("fileref", source.relativePath)
        let buildFile = xcUUID("buildfile", source.relativePath)
        let name = (source.relativePath as NSString).lastPathComponent
        fileRefs.append("""
                \(fileRef) /* \(name) */ = {isa = PBXFileReference; lastKnownFileType = \(source.fileType); path = \(swiftString(name)); sourceTree = "<group>"; };
        """)
        buildFiles.append("""
                \(buildFile) /* \(name) in Sources */ = {isa = PBXBuildFile; fileRef = \(fileRef) /* \(name) */; };
        """)
        sourceBuildFileUUIDs.append(buildFile)

        let dir = (source.relativePath as NSString).deletingLastPathComponent
        let groupKey = dir.isEmpty ? "." : dir
        if groupMembers[groupKey] == nil {
            groupMembers[groupKey] = []
            groupOrder.append(groupKey)
        }
        groupMembers[groupKey]?.append(fileRef)
    }

    for resource in spec.resources {
        let fileRef = xcUUID("fileref", resource.relativePath)
        let buildFile = xcUUID("buildfile", resource.relativePath)
        let name = (resource.relativePath as NSString).lastPathComponent
        let refType = resource.isFolder ? "folder" : "lastKnownFileType = \(resource.fileType)"
        fileRefs.append("""
                \(fileRef) /* \(name) */ = {isa = PBXFileReference; \(refType); path = \(swiftString(name)); sourceTree = "<group>"; };
        """)
        buildFiles.append("""
                \(buildFile) /* \(name) in Resources */ = {isa = PBXBuildFile; fileRef = \(fileRef) /* \(name) */; };
        """)
        resourceBuildFileUUIDs.append(buildFile)
    }

    for framework in spec.frameworks {
        let fileRef = xcUUID("fileref", framework.name)
        let buildFile = xcUUID("buildfile", framework.name)
        if framework.isSystem {
            fileRefs.append("""
                    \(fileRef) /* \(framework.name).framework */ = {isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = \(swiftString(framework.name + ".framework")); path = \(swiftString(framework.path)); sourceTree = SDKROOT; };
            """)
        } else {
            fileRefs.append("""
                    \(fileRef) /* \(framework.name) */ = {isa = PBXFileReference; lastKnownFileType = wrapper.framework; path = \(swiftString(framework.path)); sourceTree = "<group>"; };
            """)
        }
        buildFiles.append("""
                \(buildFile) /* \(framework.name) in Frameworks */ = {isa = PBXBuildFile; fileRef = \(fileRef) /* \(framework.name) */; };
        """)
        frameworkBuildFileUUIDs.append(buildFile)
    }

    // ---- 分组 ----
    // 关键：PBXGroup 的 path 是相对父组的，必须按真实目录层级逐层嵌套。
    // 如果把所有目录平铺挂在根组下、path 只写目录名，
    // Xcode 会拼出错误路径并报 "Build input file cannot be found"。
    var groups: [String] = []

    // 收集所有涉及的目录（含源文件所在目录及其所有父目录）
    var allDirs = Set<String>()
    for key in groupMembers.keys where key != "." {
        var parts = key.split(separator: "/").map(String.init)
        while !parts.isEmpty {
            allDirs.insert(parts.joined(separator: "/"))
            parts.removeLast()
        }
    }
    let sortedDirs = allDirs.sorted { ($0.split(separator: "/").count, $0) < ($1.split(separator: "/").count, $1) }

    // 每个目录的直接子目录
    func childDirs(of dir: String) -> [String] {
        let prefix = dir + "/"
        return sortedDirs.filter { $0.hasPrefix(prefix) && !$0[prefix.endIndex...].contains("/") }
    }

    // 顶层目录（没有父目录的）
    let topDirs = sortedDirs.filter { !$0.contains("/") }

    groups.append("""
            \(productsGroupUUID) /* Products */ = {
                isa = PBXGroup;
                children = (
                    \(productFileUUID) /* \(spec.projectName).app */,
                );
                name = Products;
                sourceTree = "<group>";
            };
    """)

    for dir in sortedDirs {
        let groupUUID = xcUUID("group", dir)
        let name = (dir as NSString).lastPathComponent
        var children: [String] = []

        // 该目录下直接包含的文件
        if let refs = groupMembers[dir] {
            children.append(contentsOf: refs)
        }
        // 直接子目录
        for sub in childDirs(of: dir) {
            children.append(xcUUID("group", sub))
        }

        groups.append("""
                \(groupUUID) /* \(name) */ = {
                    isa = PBXGroup;
                    children = (
        """ + children.map { "                    \($0)," }.joined(separator: "\n") + """

                    );
                    name = \(swiftString(name));
                    path = \(swiftString(name));
                    sourceTree = "<group>";
                };
        """)
    }

    // 根组：挂顶层目录 + 根级散文件 + Products
    var mainGroupChildren: [String] = []
    if let rootRefs = groupMembers["."] {
        mainGroupChildren.append(contentsOf: rootRefs)
    }
    for dir in topDirs {
        mainGroupChildren.append(xcUUID("group", dir))
    }
    mainGroupChildren.append(productsGroupUUID)

    groups.append("""
            \(mainGroupUUID) = {
                isa = PBXGroup;
                children = (
        """ + mainGroupChildren.map { "                \($0)," }.joined(separator: "\n") + """

                );
                sourceTree = "<group>";
            };
    """)

    // ---- 构建设置 ----
    var headerPaths = spec.headerSearchPaths.map { swiftString($0) }.joined(separator: ",\n\t\t\t\t\t")
    if !headerPaths.isEmpty { headerPaths = "\n\t\t\t\t\t" + headerPaths + ",\n\t\t\t\t" }

    var ldFlags = spec.otherLDFlags.map { swiftString($0) }.joined(separator: ",\n\t\t\t\t\t")
    if !ldFlags.isEmpty { ldFlags = "\n\t\t\t\t\t" + ldFlags + ",\n\t\t\t\t" }

    var defines = spec.preprocessorDefinitions.map { swiftString($0) }.joined(separator: ",\n\t\t\t\t\t")
    if !defines.isEmpty { defines = "\n\t\t\t\t\t" + defines + ",\n\t\t\t\t" }

    let commonTargetSettings = """
                    CLANG_ENABLE_MODULES = YES;
                    CLANG_ENABLE_OBJC_ARC = \(spec.enableARC ? "YES" : "NO");
                    CODE_SIGNING_ALLOWED = NO;
                    DEAD_CODE_STRIPPING = NO;
                    GCC_PREPROCESSOR_DEFINITIONS = (\(defines)"$(inherited)",
                    );
                    HEADER_SEARCH_PATHS = (\(headerPaths)"$(inherited)",
                    );
                    IPHONEOS_DEPLOYMENT_TARGET = \(spec.deploymentTarget);
                    OTHER_LDFLAGS = (\(ldFlags)"$(inherited)",
                    );
                    PRODUCT_BUNDLE_IDENTIFIER = \(swiftString(spec.bundleIdentifier));
                    PRODUCT_NAME = "$(TARGET_NAME)";
                    SDKROOT = iphoneos;
                    TARGETED_DEVICE_FAMILY = "1,2";
    """

    out.append("// !$*UTF8*$!")
    out.append("{")
    out.append("\tarchiveVersion = 1;")
    out.append("\tclasses = {")
    out.append("\t};")
    out.append("\tobjectVersion = 56;")
    out.append("\tobjects = {")

    // 各段
    out.append("\n/* Begin PBXBuildFile section */")
    out.append(buildFiles.joined(separator: "\n"))
    out.append("/* End PBXBuildFile section */\n")

    out.append("/* Begin PBXFileReference section */")
    fileRefs.append("""
            \(productFileUUID) /* \(spec.projectName).app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = \(swiftString(spec.projectName + ".app")); sourceTree = BUILT_PRODUCTS_DIR; };
    """)
    out.append(fileRefs.joined(separator: "\n"))
    out.append("/* End PBXFileReference section */\n")

    out.append("/* Begin PBXFrameworksBuildPhase section */")
    out.append("""
            \(frameworksPhaseUUID) /* Frameworks */ = {
                isa = PBXFrameworksBuildPhase;
                buildActionMask = 2147483647;
                files = (
    """ + frameworkBuildFileUUIDs.map { "                \($0)," }.joined(separator: "\n") + """

                );
                runOnlyForDeploymentPostprocessing = 0;
            };
    """)
    out.append("/* End PBXFrameworksBuildPhase section */\n")

    out.append("/* Begin PBXGroup section */")
    out.append(groups.joined(separator: "\n"))
    out.append("/* End PBXGroup section */\n")

    out.append("/* Begin PBXNativeTarget section */")
    out.append("""
            \(targetUUID) /* \(spec.projectName) */ = {
                isa = PBXNativeTarget;
                buildConfigurationList = \(targetConfigListUUID) /* Build configuration list for PBXNativeTarget "\(spec.projectName)" */;
                buildPhases = (
                    \(sourcesPhaseUUID) /* Sources */,
                    \(frameworksPhaseUUID) /* Frameworks */,
                    \(resourcesPhaseUUID) /* Resources */,
                );
                buildRules = (
                );
                dependencies = (
                );
                name = \(spec.projectName);
                productName = \(spec.projectName);
                productReference = \(productFileUUID) /* \(spec.projectName).app */;
                productType = "com.apple.product-type.application";
            };
    """)
    out.append("/* End PBXNativeTarget section */\n")

    out.append("/* Begin PBXProject section */")
    out.append("""
            \(projectUUID) /* Project object */ = {
                isa = PBXProject;
                attributes = {
                    BuildIndependentTargetsInParallel = 1;
                    LastUpgradeCheck = 1500;
                    TargetAttributes = {
                        \(targetUUID) = {
                            CreatedOnToolsVersion = 15.0;
                        };
                    };
                };
                buildConfigurationList = \(projectConfigListUUID) /* Build configuration list for PBXProject "\(spec.projectName)" */;
                compatibilityVersion = "Xcode 14.0";
                developmentRegion = en;
                hasScannedForEncodings = 0;
                knownRegions = (
                    en,
                    Base,
                );
                mainGroup = \(mainGroupUUID);
                productRefGroup = \(productsGroupUUID) /* Products */;
                projectDirPath = "";
                projectRoot = "";
                targets = (
                    \(targetUUID) /* \(spec.projectName) */,
                );
            };
    """)
    out.append("/* End PBXProject section */\n")

    out.append("/* Begin PBXResourcesBuildPhase section */")
    out.append("""
            \(resourcesPhaseUUID) /* Resources */ = {
                isa = PBXResourcesBuildPhase;
                buildActionMask = 2147483647;
                files = (
    """ + resourceBuildFileUUIDs.map { "                \($0)," }.joined(separator: "\n") + """

                );
                runOnlyForDeploymentPostprocessing = 0;
            };
    """)
    out.append("/* End PBXResourcesBuildPhase section */\n")

    out.append("/* Begin PBXSourcesBuildPhase section */")
    out.append("""
            \(sourcesPhaseUUID) /* Sources */ = {
                isa = PBXSourcesBuildPhase;
                buildActionMask = 2147483647;
                files = (
    """ + sourceBuildFileUUIDs.map { "                \($0)," }.joined(separator: "\n") + """

                );
                runOnlyForDeploymentPostprocessing = 0;
            };
    """)
    out.append("/* End PBXSourcesBuildPhase section */\n")

    out.append("/* Begin XCBuildConfiguration section */")
    out.append("""
            \(debugProjectConfigUUID) /* Debug */ = {
                isa = XCBuildConfiguration;
                buildSettings = {
                    ALWAYS_SEARCH_USER_PATHS = NO;
                    ENABLE_USER_SCRIPT_SANDBOXING = NO;
                    ONLY_ACTIVE_ARCH = YES;
                    SDKROOT = iphoneos;
                };
                name = Debug;
            };
            \(releaseProjectConfigUUID) /* Release */ = {
                isa = XCBuildConfiguration;
                buildSettings = {
                    ALWAYS_SEARCH_USER_PATHS = NO;
                    ENABLE_USER_SCRIPT_SANDBOXING = NO;
                    SDKROOT = iphoneos;
                    VALIDATE_PRODUCT = YES;
                };
                name = Release;
            };
            \(debugTargetConfigUUID) /* Debug */ = {
                isa = XCBuildConfiguration;
                buildSettings = {
    \(commonTargetSettings)
                    DEBUG_INFORMATION_FORMAT = dwarf;
                    GCC_OPTIMIZATION_LEVEL = 0;
                };
                name = Debug;
            };
            \(releaseTargetConfigUUID) /* Release */ = {
                isa = XCBuildConfiguration;
                buildSettings = {
    \(commonTargetSettings)
                    DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
                    GCC_OPTIMIZATION_LEVEL = s;
                };
                name = Release;
            };
    """)
    out.append("/* End XCBuildConfiguration section */\n")

    out.append("/* Begin XCConfigurationList section */")
    out.append("""
            \(projectConfigListUUID) /* Build configuration list for PBXProject "\(spec.projectName)" */ = {
                isa = XCConfigurationList;
                buildConfigurations = (
                    \(debugProjectConfigUUID) /* Debug */,
                    \(releaseProjectConfigUUID) /* Release */,
                );
                defaultConfigurationIsVisible = 0;
                defaultConfigurationName = Release;
            };
            \(targetConfigListUUID) /* Build configuration list for PBXNativeTarget "\(spec.projectName)" */ = {
                isa = XCConfigurationList;
                buildConfigurations = (
                    \(debugTargetConfigUUID) /* Debug */,
                    \(releaseTargetConfigUUID) /* Release */,
                );
                defaultConfigurationIsVisible = 0;
                defaultConfigurationName = Release;
            };
    """)
    out.append("/* End XCConfigurationList section */")

    out.append("\t};")
    out.append("\trootObject = \(projectUUID) /* Project object */;")
    out.append("}")

    return out.joined(separator: "\n")
}

/// 把生成的 pbxproj 写入 <project>/<name>.xcodeproj/project.pbxproj
@discardableResult
func writeXcodeProject(_ spec: XcodeProjectSpec, projectPath: String) -> (Bool, String) {
    let xcodeprojDir = "\(projectPath)/\(spec.projectName).xcodeproj"
    cfolder(atPath: xcodeprojDir)

    let content = generatePBXProj(spec)
    cfile(atPath: "\(xcodeprojDir)/project.pbxproj", withContent: content)

    // 同时写入共享 scheme，方便在 Xcode 里直接打开就能 Run
    let schemeDir = "\(xcodeprojDir)/xcshareddata/xcschemes"
    cfolder(atPath: schemeDir)
    let scheme = """
    <?xml version="1.0" encoding="UTF-8"?>
    <Scheme LastUpgradeVersion = "1500" version = "1.7">
       <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
          <BuildActionEntries>
             <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
                <BuildableReference
                   BuildableIdentifier = "primary"
                   BlueprintIdentifier = "\(xcUUID("target", spec.projectName))"
                   BuildableName = "\(spec.projectName).app"
                   BlueprintName = "\(spec.projectName)"
                   ReferencedContainer = "container:\(spec.projectName).xcodeproj">
                </BuildableReference>
             </BuildActionEntry>
          </BuildActionEntries>
       </BuildAction>
       <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
          <BuildableProductRunnable runnableDebuggingMode = "0">
             <BuildableReference
                BuildableIdentifier = "primary"
                BlueprintIdentifier = "\(xcUUID("target", spec.projectName))"
                BuildableName = "\(spec.projectName).app"
                BlueprintName = "\(spec.projectName)"
                ReferencedContainer = "container:\(spec.projectName).xcodeproj">
             </BuildableReference>
          </BuildableProductRunnable>
       </LaunchAction>
       <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
       </ProfileAction>
       <AnalyzeAction buildConfiguration = "Debug">
       </AnalyzeAction>
       <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES">
       </ArchiveAction>
    </Scheme>
    """
    cfile(atPath: "\(schemeDir)/\(spec.projectName).xcscheme", withContent: scheme)

    return (true, xcodeprojDir)
}

/// 工程依赖分析结果
struct ProjectDependencies {
    var systemFrameworks: [String] = []      // UIKit / Foundation ...
    var localFrameworks: [String] = []       // 工程内 .framework 名字
    var headerSearchPaths: [String] = []     // 含头文件的目录（绝对路径）
    var otherLDFlags: [String] = []          // -L / -l / -Wl,-U
}

/// 扫描源码里的 import，推断需要的系统框架与头文件路径
func loadProjectDependencies(projectPath: String) -> ProjectDependencies {
    let fm = FileManager.default
    var deps = ProjectDependencies()

    let ignore = ["Resources", ".git", "build", "Payload", "clang", ".fcm-cache", ".fcm-errors", "node_modules"]
    guard let all = try? fm.subpathsOfDirectory(atPath: projectPath) else { return deps }

    // ---- 1) 系统框架：从 #import <XXX/YYY.h> 推断 ----
    var frameworks = Set<String>()
    let frameworkHints: [String: String] = [
        "UIKit": "UIKit", "Foundation": "Foundation", "SwiftUI": "SwiftUI",
        "Security": "Security", "Network": "Network", "QuartzCore": "QuartzCore",
        "AVFoundation": "AVFoundation", "AVFAudio": "AVFAudio", "ImageIO": "ImageIO",
        "SafariServices": "SafariServices", "UserNotifications": "UserNotifications",
        "BackgroundTasks": "BackgroundTasks", "UniformTypeIdentifiers": "UniformTypeIdentifiers",
        "CoreGraphics": "CoreGraphics", "Metal": "Metal", "MetalKit": "MetalKit",
        "OpenGLES": "OpenGLES", "AudioToolbox": "AudioToolbox", "CoreAudio": "CoreAudio",
        "VideoToolbox": "VideoToolbox", "CoreMedia": "CoreMedia", "WebKit": "WebKit",
        "AuthenticationServices": "AuthenticationServices", "LocalAuthentication": "LocalAuthentication"
    ]

    for file in all where file.hasSuffix(".m") || file.hasSuffix(".h") || file.hasSuffix(".mm") || file.hasSuffix(".swift") {
        if ignore.contains(where: { file.hasPrefix($0 + "/") }) { continue }
        let full = "\(projectPath)/\(file)"
        guard let text = try? String(contentsOfFile: full, encoding: .utf8) else { continue }
        for (key, framework) in frameworkHints where text.contains("<" + key + "/") || text.contains("import " + key) {
            frameworks.insert(framework)
        }
    }
    deps.systemFrameworks = frameworks.sorted()

    // ---- 2) 工程内 .framework ----
    var localFW = Set<String>()
    for file in all where file.hasSuffix(".framework") {
        if ignore.contains(where: { file.hasPrefix($0 + "/") }) { continue }
        let name = ((file as NSString).lastPathComponent as NSString).deletingPathExtension
        localFW.insert(name)
    }
    deps.localFrameworks = localFW.sorted()

    // ---- 3) 头文件搜索路径：含 .h 的目录 ----
    var headers = Set<String>()
    for file in all where file.hasSuffix(".h") {
        if ignore.contains(where: { file.hasPrefix($0 + "/") }) { continue }
        let dir = (file as NSString).deletingLastPathComponent
        if !dir.isEmpty { headers.insert("\(projectPath)/\(dir)") }
    }
    deps.headerSearchPaths = headers.sorted()

    // ---- 4) 静态库：复用平台筛选，避免把 lib-macos 之类链进 iOS 工程 ----
    let iosLibs = collectIOSStaticLibraries(projectPath: projectPath, ignorePrefixes: ignore)
    var libDirs = Set<String>()
    for file in iosLibs {
        let dir = (file as NSString).deletingLastPathComponent
        if !dir.isEmpty { libDirs.insert("\(projectPath)/\(dir)") }
    }
    for dir in libDirs.sorted() {
        deps.otherLDFlags.append("-L" + dir)
    }
    for file in iosLibs {
        let base = ((file as NSString).lastPathComponent as NSString).deletingPathExtension
        if base.hasPrefix("lib") {
            let flag = "-l" + String(base.dropFirst(3))
            if !deps.otherLDFlags.contains(flag) { deps.otherLDFlags.append(flag) }
        }
    }

    return deps
}

/// 从工程目录收集生成 pbxproj 所需的文件清单
func buildProjectSpec(projectName: String,
                      projectPath: String,
                      bundleIdentifier: String,
                      deploymentTarget: String) -> XcodeProjectSpec {
    let ignore = ["Resources", ".git", "build", "Payload", "clang", ".fcm-cache", ".fcm-errors", "node_modules"]
    var spec = XcodeProjectSpec(projectName: projectName,
                                bundleIdentifier: bundleIdentifier,
                                deploymentTarget: deploymentTarget,
                                sources: [], resources: [], frameworks: [])

    let fm = FileManager.default
    guard let all = try? fm.subpathsOfDirectory(atPath: projectPath) else { return spec }

    for file in all {
        if ignore.contains(where: { file.hasPrefix($0 + "/") }) { continue }
        if file.contains(".xcodeproj/") || file.hasPrefix(".") { continue }
        let low = file.lowercased()

        if low.hasSuffix(".m") || low.hasSuffix(".mm") || low.hasSuffix(".c")
            || low.hasSuffix(".cpp") || low.hasSuffix(".swift") {
            spec.sources.append(XcodeSourceFile(relativePath: file, fileType: xcodeFileType(for: file)))
        } else if low.hasSuffix(".xcassets") && !file.contains("/") {
            spec.resources.append(XcodeResourceFile(relativePath: file, fileType: "folder.assetcatalog", isFolder: true))
        } else if low.hasSuffix(".storyboard") || low.hasSuffix(".xib")
                    || low.hasSuffix(".strings") || low.hasSuffix(".plist") && !file.contains("Resources/") {
            if !file.contains("Info.plist") {
                spec.resources.append(XcodeResourceFile(relativePath: file, fileType: xcodeFileType(for: file)))
            }
        }
    }

    spec.sources.sort { $0.relativePath < $1.relativePath }
    spec.resources.sort { $0.relativePath < $1.relativePath }
    return spec
}
