import UIKit

// Basically the "bootup" of FridaCodeManager

// fatal error handling
func exitWithError(_ message: String) -> Never {
    fatalError(message)
}

// jbroot environment
#if jailbreak
let jbroot: String = {
    let preroot = String(cString: libroot_dyn_get_jbroot_prefix())
    if FileManager.default.fileExists(atPath: preroot) {
        return preroot
    } else if let altroot = altroot(inPath: "/var/containers/Bundle/Application")?.path {
        return altroot
    } else {
        exitWithError("failed to determine jbroot")
    }
}()
#elseif trollstore
let jbroot: String = "\(Bundle.main.bundlePath)/toolchain"
#endif

// global environment
let global_container: String = {
    guard let path = contgen() else {
        exitWithError("failed to generate global container")
    }
    return path
}()

let global_documents = "\(global_container)/Documents"

#if !stock
let global_sdkpath = "\(global_container)/.sdk"
#else
let global_sdkpath = "\(global_documents)/.sdk"
#endif

let changelog: String = "v2.0.alpha_5 \"iPad + 代码编辑器更新\"（中文汉化版 + ZIP 源码导入）\n\n应用\n-> 整体界面汉化为简体中文\n-> 新增「从 ZIP 导入」：可直接导入 zip 源码包生成工程\n-> 文件管理器的「导入」现在会自动解压 zip\n-> 控制台新增复制按钮\n-> 暂时移除百科页面\n-> 新建工程弹窗关闭了自动纠错\n\n代码编辑器\n-> 移除高亮缓存\n-> 修复空格缩进模式下的退格\n-> 新增自动补全大括号与引号"
let global_version: String = "v2.0.alpha_5"

// compatibiloty checks
let isiOS16: Bool = ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 16, minorVersion: 0, patchVersion: 0))

let isPad: Bool = {
    if UIDevice.current.userInterfaceIdiom == .pad {
        return true
    } else {
        return false
    }
}()
