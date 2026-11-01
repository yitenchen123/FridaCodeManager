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
private func ghDownload(_ url: URL, token: String?) -> (String?, Int, String?) {
    let destination = "\(global_container)/tmp/gh-\(UUID()).zip"
    var resultPath: String? = nil
    var statusCode = 0
    var errorMessage: String? = nil
    let semaphore = DispatchSemaphore(value: 0)

    var request = ghRequest(url, token: token)
    request.setValue("application/zip", forHTTPHeaderField: "Accept")

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
    if semaphore.wait(timeout: .now() + 300) == .timedOut {
        task.cancel()
        return (nil, -1, "下载超时（300 秒）")
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

    // 优先用 codeload（不占 API 配额），失败再退回 API 的 zipball
    let candidates: [String] = [
        "https://codeload.github.com/\(ref.owner)/\(ref.repo)/zip/refs/heads/\(branch)",
        "https://api.github.com/repos/\(ref.owner)/\(ref.repo)/zipball/\(branch)"
    ]

    var lastError = "下载失败"
    for (index, urlString) in candidates.enumerated() {
        guard let url = URL(string: urlString) else { continue }
        progress?(index == 0 ? "正在下载 \(ref.slug)（\(branch)）…" : "正在重试（API 通道）…")
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
            let outcome = adoptStagedDirectory(staging)
            _ = rm(staging)
            if outcome.ok { return outcome }
            lastError = outcome.message
            continue
        }
        switch status {
        case 401:
            lastError = "认证失败：Token 无效或已过期"
        case 403:
            lastError = "访问被拒绝：可能是 Token 权限不足或触发限流"
        case 404:
            lastError = "仓库不存在或为私有仓库（需要有效 Token）：\(ref.slug)"
        case -1:
            lastError = err ?? "网络请求失败"
        default:
            lastError = err ?? "下载失败（HTTP \(status)）"
        }
    }
    return .fail(lastError)
}
