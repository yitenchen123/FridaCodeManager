/*
 CIBridge.swift

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

 从 .github/workflows 下的 yml 工作流读取 CI 配置，在构建前执行等价的准备步骤。
 典型用途：很多项目把依赖（mbedtls、JRE、预编译库）放在 CI 里现下，
 源码包里并不包含，直接编译必然缺头文件。
 */

import Foundation

// MARK: - 数据结构

struct CIWorkflowStep {
    var name: String
    var run: String
    var uses: String
}

/// 从 yml 里提取出来的、值得在设备上执行的一步
struct CIPrepStep {
    var title: String      // 展示用
    var command: String    // 实际执行的脚本
    var reason: String     // 为什么执行
}

// MARK: - 极简 YAML 解析
// 不引入第三方依赖：只解析我们关心的 `jobs: -> <job>: -> steps: -> - name:/run:/uses:` 结构

private func parseWorkflowSteps(_ text: String) -> [CIWorkflowStep] {
    var steps: [CIWorkflowStep] = []
    var current: CIWorkflowStep? = nil
    var mode: String? = nil        // "run" / "name" / "uses"
    var buffer: [String] = []

    func flushField() {
        guard let m = mode else { return }
        let joined = buffer.joined(separator: "\n")
        switch m {
        case "run":  current?.run = joined
        case "name": current?.name = joined.trimmingCharacters(in: .whitespaces)
        case "uses": current?.uses = joined.trimmingCharacters(in: .whitespaces)
        default: break
        }
        mode = nil
        buffer = []
    }

    func flushStep() {
        flushField()
        if let s = current, !s.run.isEmpty || !s.uses.isEmpty {
            steps.append(s)
        }
        current = nil
    }

    for rawLine in text.components(separatedBy: .newlines) {
        // 去掉注释行
        let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#") { continue }

        let indent = rawLine.prefix { $0 == " " }.count

        // 新的一步
        if trimmed.hasPrefix("- ") {
            flushStep()
            current = CIWorkflowStep(name: "", run: "", uses: "")
            let rest = String(trimmed.dropFirst(2))
            if let colon = rest.firstIndex(of: ":") {
                let key = String(rest[..<colon]).trimmingCharacters(in: .whitespaces)
                let value = String(rest[rest.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if key == "name" { current?.name = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
                if key == "uses" { current?.uses = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
                if key == "run" {
                    if value == "|" || value == ">" || value.isEmpty {
                        mode = "run"
                    } else {
                        current?.run = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    }
                }
            }
            continue
        }

        // 多行块内容
        if mode != nil {
            // 块的缩进比 `- name:` 更深，都算内容
            if indent >= 6 || (trimmed.isEmpty && !buffer.isEmpty) {
                buffer.append(rawLine)
                continue
            } else {
                flushField()
            }
        }

        // 单行 key: value
        if current != nil, let colon = trimmed.firstIndex(of: ":") {
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if key == "run" {
                if value == "|" || value == ">" || value.isEmpty {
                    mode = "run"
                } else {
                    current?.run = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                }
            } else if key == "name" && (current?.name.isEmpty ?? true) {
                current?.name = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            } else if key == "uses" {
                current?.uses = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
    }
    flushStep()
    return steps
}

// MARK: - 筛选出适合在设备执行的前置步骤

/// 这些命令在设备上没有意义或必然失败，跳过
private let kSkipPatterns: [String] = [
    "xcodebuild",            // 设备上没 xcodebuild
    "upload-artifact",       // 上传产物是 CI 专属
    "download-artifact",
    "actions/checkout",      // 源码已经在工程里了
    "actions/setup",
    "actions/cache",
    "docker ",
    "apt-get",               // 设备上没有 apt
    "brew ",
    "sudo ",
    "runs-on",
    "github.event",
    "${{ secrets.",
    "macos-",          // runner 镜像名，设备上无意义
    "ubuntu-",
    "windows-",
    "runs-on",
    "echo \"",             // 纯回显，无实际作用
    "zip -r", "mkpayload",  // 打包步骤由 FCM 自己做
    "install_name_tool",    // 依赖已打包好的产物
    "ldid ",                // FCM 自己签名
    "codesign",
    "-version\"",           // 只查版本
    "--show-sdk-version"
]

/// 明确需要执行的准备动作（下载依赖 / 生成文件 / 校验）
private let kWantedHints: [String] = [
    "fetch", "download", "deps", "dependency", "jre", "jdk", "gen_", "generate",
    "setup", "prepare", "bootstrap", "patch", "submodule", "copy", "install"
]

func ciPrepSteps(for projectPath: String) -> [CIPrepStep] {
    let fm = FileManager.default
    let workflowDir = "\(projectPath)/.github/workflows"
    guard let files = try? fm.contentsOfDirectory(atPath: workflowDir) else {
        return []
    }

    var candidates: [CIPrepStep] = []

    for file in files.sorted() where file.hasSuffix(".yml") || file.hasSuffix(".yaml") {
        let path = "\(workflowDir)/\(file)"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
        let steps = parseWorkflowSteps(text)

        for step in steps {
            let script = step.run.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !script.isEmpty else { continue }

            let haystack = (step.name + " " + script).lowercased()

            // 跳过设备上不可能成功的
            if kSkipPatterns.contains(where: { haystack.contains($0.lowercased()) }) {
                continue
            }
            // 打包/注入类由 FCM 自己完成，不重复执行
            if haystack.contains("注入") && haystack.contains("打包") { continue }
            if haystack.contains("upload") || haystack.contains("artifact") { continue }

            // 只保留看起来是"准备依赖"的步骤
            guard kWantedHints.contains(where: { haystack.contains($0) }) else {
                continue
            }
            // 排除纯环境信息
            if (step.name.contains("环境") || haystack.contains("version")) &&
               haystack.contains("echo") {
                continue
            }

            // 必须真的有执行动作，排除只做 echo 的步骤
            let actionHints = ["python3 ", "python ", "git ", "curl ", "wget ", "cp ",
                               "rsync ", "unzip ", "tar ", "chmod ", "./"]
            guard actionHints.contains(where: { script.contains($0) }) else { continue }

            let title = step.name.isEmpty ? "准备依赖" : step.name
            candidates.append(CIPrepStep(
                title: title,
                command: script,
                reason: "来自 \(file)"
            ))
        }
    }

    return candidates
}

// MARK: - 执行

/// 依次执行 CI 预备步骤，返回日志文本
func runCIPrepSteps(_ steps: [CIPrepStep], projectPath: String, log: (String) -> Void) -> Bool {
    guard !steps.isEmpty else { return true }

    // 前置检查：这些步骤大多依赖 python3，设备上没装时直接给出明确提示，
    // 否则只会看到一个含糊的"退出码 32512"。
    var missingTools: [String] = []
    for tool in ["python3", "git", "curl"] {
        let found = shell("command -v \(tool) >/dev/null 2>&1", uid: 501, env: []) == 0
        if !found { missingTools.append(tool) }
    }

    if !missingTools.isEmpty {
        log("缺少依赖：\(missingTools.joined(separator: "、"))")
        log("CI 准备步骤需要这些工具。安装命令：")
        log("  apt install \(missingTools.map { $0 == "python3" ? "python3" : $0 }.joined(separator: " "))")
        log("跳过 CI 准备步骤，直接开始编译（可能因缺依赖而失败）")
        return false
    }

    for (index, step) in steps.enumerated() {
        log("[\(index + 1)/\(steps.count)] \(step.title)（\(step.reason)）")

        // CI 里的脚本默认在工作区根目录跑，这里切换到工程目录
        let command = "cd '\(projectPath)' && " + step.command

        var output = ""
        #if !stock
        let result = runCIPrepCommand(command)
        output = result.log
        if result.code != 0 {
            log("  ✗ 失败（退出码 \(result.code)）")
            if !output.isEmpty {
                log(output)
            }
            // 单个步骤失败不中断：有些项目对缺依赖是容忍的
            log("  已跳过，继续下一步")
            continue
        }
        #endif
        log("  ✓ 完成")
        if !output.isEmpty {
            let trimmed = output.count > 700 ? String(output.suffix(700)) : output
            log(trimmed)
        }
    }
    return true
}

private func runCIPrepCommand(_ command: String) -> (code: Int, log: String) {
    let logPath = "\(global_container)/tmp/ci-prep-\(UUID()).log"
    let wrapped = command + " > '\(logPath)' 2>&1"
    let code = shell(wrapped, uid: 501, env: [])
    var text = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
    _ = rm(logPath)
    if text.count > 2000 { text = String(text.suffix(2000)) }
    return (code, text.trimmingCharacters(in: .whitespacesAndNewlines))
}
