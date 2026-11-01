/*
 JavaEnvironmentView.swift

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

 设置 > Java 环境：导入与管理设备上的 JDK。

 iOS 没有官方 JDK，但存在社区构建的 aarch64 版本（如 OpenJDK8-iOS）。
 用户拿到后通过「文件」导入，FCM 解压到 Documents/.fcm-jdk/，
 之后构建 Java 工程时会自动使用它。
 */

import SwiftUI
import UniformTypeIdentifiers

struct JavaEnvironmentView: View {
    @State private var info: JavaToolchainInfo = JavaToolchainInfo()
    @State private var importing = false
    @State private var status: String = ""
    @State private var showImporter = false

    var body: some View {
        List {
            Section(header: Text("当前环境")) {
                if info.ready {
                    infoRow("版本", info.version.isEmpty ? "未知" : info.version)
                    infoRow("来源", info.source)
                    infoRow("Java 8 目标", info.supportsJava8Target ? "支持" : "不支持")
                    if let home = info.home {
                        Text(home)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else {
                    Text("尚未导入 JDK")
                        .foregroundColor(.secondary)
                    Text("设备上没有可用的 javac。\n导入一份 iOS aarch64 版 JDK 即可编译 Java 工程。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }

            Section(header: Text("导入")) {
                Button {
                    showImporter = true
                } label: {
                    Label("导入 JDK（zip / tgz）", systemImage: "square.and.arrow.down")
                }
                .disabled(importing)

                Text("要求：压缩包内需包含 bin/javac 与 lib/tools.jar。\n解压后约 200MB，请确保存储空间充足。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if info.ready {
                Section {
                    Button(role: .destructive) {
                        removeJDK()
                    } label: {
                        Label("移除已导入的 JDK", systemImage: "trash")
                    }
                }
            }

            if !status.isEmpty {
                Section {
                    Text(status)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("Java 环境")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { refresh() }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.zip, .archive],
                      allowsMultipleSelection: false,
                      onCompletion: handleImport)
    }

    /// iOS 15 兼容的行布局（LabeledContent 需要 iOS 16）
    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: - 状态

    private func refresh() {
        // 用工程根目录（Documents）探测，覆盖全局 .fcm-jdk
        info = detectJavaToolchain(projectPath: global_documents)
    }

    // MARK: - 导入

    private func handleImport(result: Result<[URL], Error>) -> Void {
        switch result {
        case .success(let urls):
            guard let fileURL = urls.first else { return }
            importing = true
            status = "正在导入 JDK…"

            DispatchQueue.global(qos: .userInitiated).async {
                let outcome = installJDKArchive(fileURL)
                DispatchQueue.main.async {
                    importing = false
                    status = outcome.message
                    refresh()
                    haptfeedback(outcome.ok ? 1 : 2)
                    showAlert(with: outcome.message)
                }
            }
        case .failure(let error):
            importing = false
            status = ""
            showAlert(with: "导入失败：\(error.localizedDescription)")
        }
    }

    /// 解压 JDK 归档到 Documents/.fcm-jdk
    private func installJDKArchive(_ fileURL: URL) -> (ok: Bool, message: String) {
        let fm = FileManager.default
        let target = "\(global_documents)/.fcm-jdk"
        let staging = "\(global_container)/tmp/jdk-import-\(UUID())"

        cfolder(atPath: "\(global_container)/tmp")
        _ = rm(staging)
        cfolder(atPath: staging)

        let scope = fileURL.startAccessingSecurityScopedResource()

        // 先复制到自己的 tmp（安全作用域 URL 会失效）
        let local = "\(global_container)/tmp/jdk-src.zip"
        _ = rm(local)
        var copied = (cp(fileURL.path, local) == 0)
        if !copied, let data = try? Data(contentsOf: fileURL) {
            copied = fm.createFile(atPath: local, contents: data)
        }
        if scope { fileURL.stopAccessingSecurityScopedResource() }

        guard copied else {
            _ = rm(staging)
            return (false, "无法读取该文件，请重新选择")
        }

        // 解压：三级回退
        //   1. 系统 unzip（最可靠，能处理 libzip 不支持的包）
        //   2. libzip（App 内置，无外部依赖）
        //   3. tar（仅对 tar.gz/tgz 有效）
        // 注意：不能用 tar 解 zip，那是两种完全不同的格式。
        var extracted = false

        if let unzipBin = ["/var/jb/usr/bin/unzip", "/usr/bin/unzip", "/var/jb/bin/unzip"]
            .first(where: { fm.isExecutableFile(atPath: $0) }) {
            extracted = shell("'\(unzipBin)' -q -o '\(local)' -d '\(staging)'", uid: 501, env: []) == 0
            if !extracted {
                // 权限问题（目标目录属于 root）时提权重试
                #if !stock
                extracted = shell("'\(unzipBin)' -q -o '\(local)' -d '\(staging)'", uid: 0, env: []) == 0
                #endif
            }
        }

        if !extracted {
            extracted = libzip_unzip(local, staging) == 0
        }

        if !extracted {
            // 只有 tar 系列才走这条路
            let lower = fileURL.lastPathComponent.lowercased()
            if lower.hasSuffix(".tgz") || lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tar"),
               let tar = ["/var/jb/usr/bin/tar", "/usr/bin/tar"].first(where: { fm.isExecutableFile(atPath: $0) }) {
                extracted = shell("'\(tar)' -xf '\(local)' -C '\(staging)' 2>/dev/null", uid: 501, env: []) == 0
            }
        }
        _ = rm(local)

        guard extracted else {
            _ = rm(staging)
            return (false, "解压失败：找不到可用的解压工具或压缩包已损坏\n\n可尝试：apt install unzip")
        }

        // 找到含 bin/javac 的目录（可能多套一层）
        guard let jdkRoot = findJDKRoot(in: staging) else {
            // 解压成功但结构不符：把实际看到的内容报出来，便于定位
            let listing = describeDirectory(staging, depth: 2)
            _ = rm(staging)
            return (false, "解压成功，但压缩包里没有 bin/javac\n\n解压后的结构：\n" + listing)
        }

        // 检查是否含 tools.jar（javac 实现）
        let hasTools = fm.fileExists(atPath: "\(jdkRoot)/lib/tools.jar")

        // 搬到目标位置
        _ = rm(target)
        if mv(jdkRoot, target) != 0 {
            if cp(jdkRoot, target) != 0 {
                _ = rm(staging)
                return (false, "安装失败：无法移动 JDK 到 \(target)")
            }
        }
        shell("chmod -R +x '\(target)/bin' 2>/dev/null", uid: 501, env: [])
        _ = rm(staging)

        // 校验
        let javac = "\(target)/bin/javac"
        guard fm.isExecutableFile(atPath: javac) else {
            return (false, "JDK 已解压，但 bin/javac 不可执行")
        }

        var message = "JDK 导入成功\n位置：\(target)\n"
        if !hasTools {
            message += "\n注意：缺少 lib/tools.jar，javac 可能无法工作。\n"
            message += "请确认导入的是完整 JDK（不是 JRE）。"
        }
        return (hasTools, message)
    }

    /// 列出目录结构（最多两层），用于错误提示
    private func describeDirectory(_ path: String, depth: Int) -> String {
        let fm = FileManager.default
        var lines: [String] = []
        func walk(_ dir: String, _ level: Int) {
            guard level <= depth else { return }
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for entry in entries.sorted().prefix(12) {
                var isDir: ObjCBool = false
                fm.fileExists(atPath: "\(dir)/\(entry)", isDirectory: &isDir)
                let indent = String(repeating: "  ", count: level)
                lines.append(indent + entry + (isDir.boolValue ? "/" : ""))
                if isDir.boolValue && level < depth {
                    walk("\(dir)/\(entry)", level + 1)
                }
            }
            if entries.count > 12 {
                lines.append(String(repeating: "  ", count: level) + "…（共 \(entries.count) 项）")
            }
        }
        walk(path, 0)
        if lines.isEmpty { return "（空目录）" }
        return lines.prefix(20).joined(separator: "\n")
    }

    /// 在解压目录里找 JDK 根（含 bin/javac）
    private func findJDKRoot(in dir: String) -> String? {
        let fm = FileManager.default
        if fm.isExecutableFile(atPath: "\(dir)/bin/javac") { return dir }

        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
        for entry in entries {
            let sub = "\(dir)/\(entry)"
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: sub, isDirectory: &isDir), isDir.boolValue else { continue }
            if fm.isExecutableFile(atPath: "\(sub)/bin/javac") { return sub }
            // 再深一层（某些发行版会多套 jdk8/jdk1.8.0_xxx）
            if let subs = try? fm.contentsOfDirectory(atPath: sub) {
                for s in subs where fm.isExecutableFile(atPath: "\(sub)/\(s)/bin/javac") {
                    return "\(sub)/\(s)"
                }
            }
        }
        return nil
    }

    // MARK: - 移除

    private func removeJDK() {
        let target = "\(global_documents)/.fcm-jdk"
        DispatchQueue.global(qos: .utility).async {
            let result = rm(target)
            DispatchQueue.main.async {
                refresh()
                haptfeedback(result == 0 ? 1 : 2)
                status = result == 0 ? "已移除" : "移除失败"
            }
        }
    }
}
