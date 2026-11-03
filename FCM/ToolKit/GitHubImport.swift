/*
 GitHubImport.swift

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

 从 GitHub 仓库拉取源码并导入为工程
 支持：https://github.com/owner/repo 、 owner/repo 、带 .git 后缀、
       以及 /tree/<branch> 指定分支
 */

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - 仓库地址解析

struct GitHubRepoRef {
    var owner: String
    var repo: String
    var branch: String?

    var slug: String { "\(owner)/\(repo)" }

    /// 解析用户输入的仓库地址，失败返回 nil
    static func parse(_ input: String) -> GitHubRepoRef? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // 去掉协议前缀
        for prefix in ["https://", "http://", "git@", "ssh://git@"] {
            if text.lowercased().hasPrefix(prefix) {
                text = String(text.dropFirst(prefix.count))
            }
        }
        // git@github.com:owner/repo.git
        if text.lowercased().hasPrefix("github.com:") {
            text = String(text.dropFirst("github.com:".count))
        } else if text.lowercased().hasPrefix("github.com/") {
            text = String(text.dropFirst("github.com/".count))
        }

        var parts = text.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }

        var branch: String? = nil
        // owner/repo/tree/branch
        if parts.count >= 4, parts[2] == "tree" {
            branch = parts[3...].joined(separator: "/")
            parts = Array(parts.prefix(2))
        }

        var owner = parts[0]
        var repo = parts[1]
        if repo.hasSuffix(".git") {
            repo = String(repo.dropLast(4))
        }
        owner = owner.replacingOccurrences(of: " ", with: "")
        repo = repo.replacingOccurrences(of: " ", with: "")
        guard !owner.isEmpty, !repo.isEmpty else { return nil }
        return GitHubRepoRef(owner: owner, repo: repo, branch: branch)
    }
}

// MARK: - 下载

private func ghRequest(_ url: URL, token: String?) -> URLRequest {
    var request = URLRequest(url: url)
    request.timeoutInterval = 120
    request.setValue("FridaCodeManager", forHTTPHeaderField: "User-Agent")
    if let token = token, !token.isEmpty {
        request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
    }
    return request
}

/// 同步方式下载（在后台队列里调用），返回 (临时文件路径, HTTP 状态码, 错误信息)
/// 下载到临时文件（在后台队列里同步等待），返回 (临时路径, HTTP 状态码, 错误)
private func ghDownload(_ url: URL, token: String?, timeout: TimeInterval = 300) -> (String?, Int, String?) {
    let destination = "\(global_container)/tmp/gh-\(UUID()).zip"
    var resultPath: String? = nil
    var statusCode = 0
    var errorMessage: String? = nil
    let semaphore = DispatchSemaphore(value: 0)

    var request = ghRequest(url, token: token)
    // 这里也会下载 release 资产（.tgz），不能写死 Accept: application/zip
    request.setValue("*/*", forHTTPHeaderField: "Accept")

    // 用 downloadTask，避免把整个仓库读进内存（大仓库会 OOM）
    let task = URLSession.shared.downloadTask(with: request) { location, response, error in
        defer { semaphore.signal() }
        if let http = response as? HTTPURLResponse {
            statusCode = http.statusCode
        }
        if let error = error {
            errorMessage = error.localizedDescription
            return
        }
        guard let location = location else {
            errorMessage = "服务器没有返回数据"
            return
        }
        do {
            if FileManager.default.fileExists(atPath: destination) {
                try? FileManager.default.removeItem(atPath: destination)
            }
            try FileManager.default.moveItem(at: location, to: URL(fileURLWithPath: destination))
            resultPath = destination
        } catch {
            errorMessage = "写入临时文件失败"
        }
    }
    task.resume()
    if semaphore.wait(timeout: .now() + timeout) == .timedOut {
        task.cancel()
        return (nil, -1, "下载超时（\(Int(timeout)) 秒）")
    }
    return (resultPath, statusCode, errorMessage)
}

/// 查询默认分支（避免 main / master 猜错）
private func ghDefaultBranch(_ ref: GitHubRepoRef, token: String?) -> String? {
    let urlString = "https://api.github.com/repos/\(ref.owner)/\(ref.repo)"
    guard let url = URL(string: urlString) else { return nil }
    var branch: String? = nil
    let semaphore = DispatchSemaphore(value: 0)
    let task = URLSession.shared.dataTask(with: ghRequest(url, token: token)) { body, _, _ in
        defer { semaphore.signal() }
        guard let body = body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return }
        branch = json["default_branch"] as? String
    }
    task.resume()
    _ = semaphore.wait(timeout: .now() + 60)
    return branch
}

// MARK: - 主入口

/// 从 GitHub 仓库拉取源码并导入为新工程
func importGitHubRepo(_ input: String, token: String?, progress: ((String) -> Void)? = nil) -> ImportOutcome {
    guard let ref = GitHubRepoRef.parse(input) else {
        return .fail("无法识别的仓库地址，示例：https://github.com/用户/仓库")
    }

    cfolder(atPath: "\(global_container)/tmp")
    progress?("正在获取仓库信息…")

    let branch: String
    if let specified = ref.branch, !specified.isEmpty {
        branch = specified
    } else if let def = ghDefaultBranch(ref, token: token), !def.isEmpty {
        branch = def
    } else {
        branch = "main"
    }

    // 优先 git clone --recursive：zip 不含子模块，依赖第三方库的工程会缺头文件
    progress?("正在克隆 \(ref.slug)（\(branch)）…")
    switch cloneRepo(ref, branch: branch, token: token, progress: progress) {
    case .success(let dir):
        progress?("正在创建工程…")
        let outcome = adoptStagedDirectory(dir, fallbackName: ref.repo)
        _ = rm(dir)
        if outcome.ok { recordGitHubSlug(ref, outcome.projectPath) }
        return outcome
    case .needsAuth:
        return .fail("私有仓库需要 Token，请切换到「使用 Token」并填写后再试")
    case .notFound:
        return .fail("仓库不存在：\(ref.slug)")
    case .noGit:
        progress?("未找到 git，改用 zip 下载（不含子模块）…")
    case .failed(let reason):
        progress?("git 克隆失败，改用 zip 下载…\n\(reason)")
    }

    // git 不可用时的回退：zip
    let candidates = [
        "https://codeload.github.com/\(ref.owner)/\(ref.repo)/zip/refs/heads/\(branch)",
        "https://api.github.com/repos/\(ref.owner)/\(ref.repo)/zipball/\(branch)"
    ]

    var lastError = "下载失败"
    for (index, urlString) in candidates.enumerated() {
        guard let url = URL(string: urlString) else { continue }
        progress?(index == 0 ? "正在下载 \(ref.slug)…" : "重试中（API 通道）…")
        let (path, status, err) = ghDownload(url, token: token)
        if let path = path, (200...299).contains(status) {
            progress?("正在解压…")
            let staging = "\(global_container)/tmp/gh-\(UUID())"
            cfolder(atPath: staging)
            let ok = libzip_unzip(path, staging) == 0
            _ = rm(path)
            guard ok else {
                _ = rm(staging)
                lastError = "解压失败"
                continue
            }
            progress?("正在创建工程…")
            let outcome = adoptStagedDirectory(staging, fallbackName: ref.repo)
            _ = rm(staging)
            if outcome.ok { recordGitHubSlug(ref, outcome.projectPath) }
            if outcome.ok { return outcome }
            lastError = outcome.message
            continue
        }
        switch status {
        case 401: lastError = "认证失败：Token 无效或已过期"
        case 403: lastError = "访问被拒绝：Token 权限不足或触发限流"
        case 404: lastError = "仓库不存在或为私有仓库：\(ref.slug)"
        case -1:  lastError = err ?? "网络请求失败"
        default:  lastError = err ?? "下载失败（HTTP \(status)）"
        }
    }
    return .fail(lastError)
}

// MARK: - git 克隆

enum CloneResult {
    case success(String)
    case needsAuth
    case notFound
    case noGit
    case failed(String)
}

/// 用 git clone --recursive 拉仓库（含子模块）
private func cloneRepo(_ ref: GitHubRepoRef, branch: String, token: String?, progress: ((String) -> Void)?) -> CloneResult {
    let fm = FileManager.default
    let git = ["/var/jb/usr/bin/git", "/usr/bin/git", "/var/jb/bin/git", "/bin/git"]
        .first { fm.isExecutableFile(atPath: $0) }
    guard let gitPath = git else { return .noGit }

    let destination = "\(global_container)/tmp/ghclone-\(UUID())"
    _ = rm(destination)

    // 带 token 的地址只用于 clone 命令，不落盘到 .git/config
    var remote = "https://github.com/\(ref.owner)/\(ref.repo).git"
    if let token = token, !token.isEmpty {
        remote = "https://x-access-token:\(token)@github.com/\(ref.owner)/\(ref.repo).git"
    }

    let depth = "--depth 1"
    let command = "'\(gitPath)' clone \(depth) --recursive --branch '\(branch)' '\(remote)' '\(destination)'"

    progress?("正在克隆（含子模块，可能较慢）…")
    let output = runPS(command: command, uid: 501)

    if output.code != 0 {
        // 再试一次不带 --branch（分支可能不是默认名）
        let retry = "'\(gitPath)' clone \(depth) --recursive '\(remote)' '\(destination)'"
        let r2 = runPS(command: retry, uid: 501)
        if r2.code != 0 {
            let log = (r2.log.isEmpty ? output.log : r2.log)
            if log.contains("Authentication failed") || log.contains("could not read Username") {
                return .needsAuth
            }
            if log.contains("not found") || log.contains("Repository not found") {
                return .notFound
            }
            return .failed(log.isEmpty ? "退出码 \(r2.code)" : log)
        }
    }

    // 清掉 .git 里的凭据痕迹
    let config = "\(destination)/.git/config"
    if let text = try? String(contentsOfFile: config, encoding: .utf8) {
        let cleaned = text.replacingOccurrences(of: remote, with: "https://github.com/\(ref.owner)/\(ref.repo).git")
        try? cleaned.write(toFile: config, atomically: true, encoding: .utf8)
    }
    return .success(destination)
}

/// 执行命令并捕获输出
private func runPS(command: String, uid: uid_t) -> (code: Int, log: String) {
    let logPath = "\(global_container)/tmp/gh-\(UUID()).log"
    let wrapped = command + " > '\(logPath)' 2>&1"
    let code = shell(wrapped, uid: uid, env: [])
    var text = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
    _ = rm(logPath)
    if text.count > 500 { text = String(text.suffix(500)) }
    return (code, text.trimmingCharacters(in: .whitespacesAndNewlines))
}

/// 把克隆下来的仓库收编成工程（保留 .git，方便之后推送）
private func adoptClonedRepo(_ dir: String, name: String) -> ImportOutcome {
    let outcome = adoptStagedDirectory(dir)
    // adoptStagedDirectory 会移动目录，所以克隆目录已经不存在了；只做清理
    _ = rm(dir)
    if !outcome.ok {
        return outcome
    }
    return outcome
}

// MARK: - Release 资产（JRE / 预编译依赖）

/// 一条「从 GitHub release 下载并解压到工程内」的资源描述
struct ReleaseAssetSpec {
    var tag: String
    var asset: String
    var baseDirectory: String   // 解压目标，相对工程根目录（tar -C 的目录）
    var destination: String     // 解压后应出现的子目录，相对工程根目录
}

/// 读取 .github/workflows 里的全部 YAML 文本
private func workflowTexts(projectPath: String) -> [String] {
    let dir = "\(projectPath)/.github/workflows"
    guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
    return files.filter { $0.hasSuffix(".yml") || $0.hasSuffix(".yaml") }
        .sorted()
        .compactMap { try? String(contentsOfFile: "\(dir)/\($0)", encoding: .utf8) }
}

/// 从 workflow 中提取 release 下载步骤。
///
/// 支持 GitHub Actions 里常见写法：
///   for spec in "java8.tgz:java-8-openjdk" "java17.tgz:java-17-openjdk"; do
///     ...
///     gh release download jre-assets --pattern "$tgz" --dir /tmp/jre_get
///     tar xzf "/tmp/jre_get/$tgz" -C Libraries/java_runtimes
/// 这正是 Air2 在 CI 里补齐四档 JRE 的方式。
func missingReleaseAssets(projectPath: String) -> [ReleaseAssetSpec] {
    let fm = FileManager.default
    let texts = workflowTexts(projectPath: projectPath)
    guard !texts.isEmpty else { return [] }

    var specs: [ReleaseAssetSpec] = []
    for text in texts {
        // 只处理 tag 是字面量的调用；${{ ... }} / $TAG 这类动态值在设备上无法还原
        guard let tagRange = text.range(of: "gh release download\\s+([A-Za-z0-9._/-]+)",
                                        options: .regularExpression) else { continue }
        let tagLine = String(text[tagRange])
        let tag = tagLine.components(separatedBy: CharacterSet.whitespacesAndNewlines).last ?? ""

        // 解压目标：tar 命令里 -C 后面的字面量目录
        guard let tarRange = text.range(of: "tar\\s+[^\\n]*-C\\s+([A-Za-z0-9._/-]+)",
                                        options: .regularExpression) else { continue }
        let tarLine = String(text[tarRange])
        var baseDirectory = ""
        if let cRange = tarLine.range(of: "-C\\s+", options: .regularExpression) {
            baseDirectory = String(tarLine[cRange.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        // 绝对路径或含变量的目标不处理，避免在设备上写到工程外
        guard !baseDirectory.isEmpty, !baseDirectory.hasPrefix("/"),
              !baseDirectory.contains("$"), !baseDirectory.contains("..") else { continue }

        // 「资产名:解压后目录名」的配对
        let pattern = "\"([A-Za-z0-9._+-]+\\.(?:tgz|tar\\.gz|zip)):([A-Za-z0-9._/-]+)\""
        guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard match.numberOfRanges >= 3 else { continue }
            let asset = ns.substring(with: match.range(at: 1))
            let subdir = ns.substring(with: match.range(at: 2))
            let destination = baseDirectory + "/" + subdir

            // 已存在的目录按 CI 的做法直接跳过
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: "\(projectPath)/\(destination)", isDirectory: &isDir), isDir.boolValue {
                continue
            }
            if specs.contains(where: { $0.asset == asset && $0.destination == destination }) { continue }
            specs.append(ReleaseAssetSpec(tag: tag,
                                          asset: asset,
                                          baseDirectory: baseDirectory,
                                          destination: destination))
        }
    }
    return specs
}

/// 识别仓库 slug：优先导入时记录的 .fcm-repo，其次 .git/config 的 origin，最后 workflow 里的 --repo
private func repositorySlug(projectPath: String, workflowText: String) -> String? {
    // zip 方式导入的仓库没有 .git，导入时把 owner/repo 记下来，供 release 资产使用
    if let recorded = try? String(contentsOfFile: "\(projectPath)/.fcm-repo", encoding: .utf8) {
        let slug = recorded.trimmingCharacters(in: .whitespacesAndNewlines)
        if !slug.isEmpty { return slug }
    }
    if let config = try? String(contentsOfFile: "\(projectPath)/.git/config", encoding: .utf8) {
        for line in config.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("url = ") else { continue }
            var url = String(trimmed.dropFirst("url = ".count))
            for marker in ["github.com/", "github.com:"] {
                guard let range = url.range(of: marker) else { continue }
                url = String(url[range.upperBound...])
                if url.hasSuffix(".git") { url.removeLast(4) }
                let parts = url.split(separator: "/").map(String.init)
                guard parts.count >= 2 else { continue }
                return parts[0] + "/" + parts[1]
            }
        }
    }
    // workflow 里显式写了 --repo owner/repo
    if let range = workflowText.range(of: "--repo\\s+([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)",
                                      options: .regularExpression) {
        let token = String(workflowText[range])
        return String(token.split(separator: " ").last ?? "")
    }
    return nil
}

/// 记录本次导入的 GitHub 仓库，供构建时定位 release 资产
private func recordGitHubSlug(_ ref: GitHubRepoRef, _ projectPath: String?) {
    guard let path = projectPath else { return }
    try? ref.slug.write(toFile: "\(path)/.fcm-repo", atomically: true, encoding: .utf8)
}

/// 下载并解压 workflow 声明的 release 资产，返回是否全部就位。
/// 这些资源是 GitHub CI 构建的一部分（如 Air2 的四档 JRE），
/// 不拉取就会得到「能编译但启动缺运行时」的残缺包。
func stageReleaseAssets(projectPath: String, log: (String) -> Void) -> Bool {
    let specs = missingReleaseAssets(projectPath: projectPath)
    guard !specs.isEmpty else { return true }
    cfolder(atPath: "\(global_container)/tmp")

    let texts = workflowTexts(projectPath: projectPath)
    guard let slug = texts.compactMap({ repositorySlug(projectPath: projectPath, workflowText: $0) }).first
    else {
        log("无法识别仓库地址（.git/config 或 workflow 里没有 owner/repo），跳过 release 资产")
        return true
    }

    let fm = FileManager.default
    let tarPath = ["/var/jb/usr/bin/tar", "/usr/bin/tar", "/var/jb/bin/tar", "/bin/tar"]
        .first { fm.isExecutableFile(atPath: $0) }

    for spec in specs {
        log("下载 release 资产 \(spec.asset)（\(spec.tag)）…")
        guard let url = URL(string: "https://github.com/\(slug)/releases/download/\(spec.tag)/\(spec.asset)") else {
            log("资产地址无效：\(spec.asset)")
            return false
        }
        let (archive, status, error) = ghDownload(url, token: nil, timeout: 900)
        guard let archive = archive, (200...299).contains(status) else {
            log("下载失败（HTTP \(status)）：\(error ?? "未知错误")")
            log("请确认网络可用，或在 Mac 上手动把 \(spec.destination) 放进工程目录")
            return false
        }

        let extracted: Bool
        if spec.asset.hasSuffix(".zip") {
            extracted = libzip_unzip(archive, "\(projectPath)/\(spec.baseDirectory)") == 0
        } else if let tar = tarPath {
            cfolder(atPath: "\(projectPath)/\(spec.baseDirectory)")
            let command = "\(shellQuote(tar)) xzf \(shellQuote(archive)) -C \(shellQuote("\(projectPath)/\(spec.baseDirectory)"))"
            extracted = runCaptured(command, uid: 501).succeeded
        } else {
            log("找不到 tar，无法解压 \(spec.asset)")
            _ = rm(archive)
            return false
        }
        _ = rm(archive)

        var isDir: ObjCBool = false
        guard extracted,
              fm.fileExists(atPath: "\(projectPath)/\(spec.destination)", isDirectory: &isDir),
              isDir.boolValue else {
            log("解压失败或目录缺失：\(spec.destination)")
            return false
        }
        log("已就位：\(spec.destination)")
    }
    return true
}
