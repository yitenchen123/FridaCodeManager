import SwiftUI
import Foundation
import UniformTypeIdentifiers

struct SDKDownload: View {
    // 上游仓库里真实存在的版本（9.3 / 10.3 不存在，下载会 404，已移除）
    @State private var sdks: [String] = ["11.4","12.4","13.7","14.5","15.6","16.5"]
    @State private var installed: [String] = []
    @State private var listid: UUID = UUID()
    @State private var downloading: String? = nil
    @State private var status: String = ""
    @State private var showImporter = false

    var body: some View {
        List {
            Section(header: Text("在线下载")) {
                ForEach(sdks, id:\.self) { item in
                    if isInstalled(item) {
                        Button( action: {
                            remove(item)
                        }) {
                            HStack {
                                Label("iOS \(item)", systemImage: "trash.fill")
                                Spacer()
                                Text("已安装").font(.caption).foregroundColor(.secondary)
                            }
                        }
                        .disabled(downloading != nil)
                    } else {
                        Button( action: {
                            download(item)
                        }) {
                            HStack {
                                Label("iOS \(item)", systemImage: "arrow.down")
                                Spacer()
                                if downloading == item {
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(downloading != nil)
                    }
                }
            }

            Section(header: Text("手动安装")) {
                Button(action: { showImporter = true }) {
                    Label("导入本地 SDK（zip）", systemImage: "square.and.arrow.down")
                }
                .disabled(downloading != nil)
                Text("适用于在线列表里没有的版本（如 15.0 / 17.0 / 18.0）。\nzip 内需包含 iPhoneOS<版本>.sdk 目录。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // 已安装但不在在线列表里的 SDK（例如手动导入的）
            let extras = installed.filter { !sdks.contains($0) }
            if !extras.isEmpty {
                Section(header: Text("其他已安装")) {
                    ForEach(extras, id:\.self) { item in
                        Button(action: { remove(item) }) {
                            HStack {
                                Label("iOS \(item)", systemImage: "trash.fill")
                                Spacer()
                                Text("已安装").font(.caption).foregroundColor(.secondary)
                            }
                        }
                        .disabled(downloading != nil)
                    }
                }
            }

            if !status.isEmpty {
                Section {
                    Text(status).font(.footnote).foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("SDK 中心")
        .navigationBarTitleDisplayMode(.inline)
        .id(listid)
        .onAppear { refreshInstalled() }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.zip, .archive],
                      allowsMultipleSelection: false,
                      onCompletion: handleImport)
    }

    // MARK: - 已装列表

    private func refreshInstalled() {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: global_sdkpath)) ?? []
        installed = names.compactMap { name in
            guard name.hasPrefix("iPhoneOS"), name.hasSuffix(".sdk") else { return nil }
            return String(name.dropFirst("iPhoneOS".count).dropLast(".sdk".count))
        }.sorted()
    }

    private func isInstalled(_ version: String) -> Bool {
        return FileManager.default.fileExists(atPath: "\(global_sdkpath)/iPhoneOS\(version).sdk")
    }

    // MARK: - 下载

    /// 多镜像回退。raw.githubusercontent 在国内基本不通，优先用可用的镜像；
    /// 并从用户自己的仓库（含本次改动）取包，避免上游分支变动导致 404。
    private func mirrorURLs(_ sdk: String) -> [String] {
        let path = "FCM/UI/TabBar/Settings/SDKHub/sdk/iOS\(sdk).zip"
        let repo = "yitenchen123/FridaCodeManager"
        let branch = "zh-cn"
        var urls: [String] = []
        // 顺序按实测可用性排列（国内网络）
        urls.append("https://cdn.jsdelivr.net/gh/\(repo)@\(branch)/\(path)")
        urls.append("https://fastly.jsdelivr.net/gh/\(repo)@\(branch)/\(path)")
        urls.append("https://gh-proxy.com/https://raw.githubusercontent.com/\(repo)/\(branch)/\(path)")
        urls.append("https://raw.githubusercontent.com/\(repo)/\(branch)/\(path)")
        return urls
    }

    private func download(_ sdk: String) -> Void {
        downloading = sdk
        status = "正在下载 iOS \(sdk) SDK…"
        let target = "\(global_container)/tmp/sdk-\(sdk).zip"

        DispatchQueue.global(qos: .utility).async {
            cfolder(atPath: "\(global_sdkpath)")
            cfolder(atPath: "\(global_container)/tmp")

            var success = false
            var lastError = "未知错误"

            for url in mirrorURLs(sdk) {
                let host = URL(string: url)?.host ?? url
                DispatchQueue.main.async { status = "正在下载 iOS \(sdk) SDK…（\(host)）" }

                _ = rm(target)
                fdownload(url, target)

                // fdownload 失败时不创建文件，靠文件大小判断是否真的下到了
                let size = ((try? FileManager.default.attributesOfItem(atPath: target))?[.size] as? NSNumber)?.intValue ?? 0
                if size < 1024 {
                    lastError = "\(host) 无响应或返回为空"
                    _ = rm(target)
                    continue
                }

                if installSDKZip(target) {
                    success = true
                    break
                }
                lastError = "解压失败（文件可能不完整）"
                _ = rm(target)
            }

            _ = rm(target)
            DispatchQueue.main.async {
                downloading = nil
                refreshInstalled()
                listid = UUID()
                if success {
                    status = "iOS \(sdk) SDK 安装完成"
                    haptfeedback(1)
                } else {
                    status = "iOS \(sdk) 下载失败：\(lastError)"
                    haptfeedback(2)
                    showAlert(with: "SDK 下载失败\n\(lastError)\n\n可以切换网络重试，或点「导入本地 SDK」手动安装。")
                }
            }
        }
    }

    /// 解压 zip 到 SDK 目录，处理权限问题
    private func installSDKZip(_ path: String) -> Bool {
        if libzip_unzip(path, global_sdkpath) == 0 { return true }
        // 之前可能以 root 身份写入过，修正归属后重试
        #if jailbreak
        shell("chown -R mobile \(global_sdkpath)", uid: 0)
        #elseif trollstore
        shell("chown -R mobile:mobile \(global_sdkpath)", uid: 0)
        #endif
        return libzip_unzip(path, global_sdkpath) == 0
    }

    // MARK: - 本地导入

    private func handleImport(result: Result<[URL], Error>) -> Void {
        switch result {
        case .success(let urls):
            guard let fileURL = urls.first else { return }
            downloading = "local"
            status = "正在读取文件…"

            DispatchQueue.global(qos: .userInitiated).async {
                let outcome = importSDKFile(fileURL)
                DispatchQueue.main.async {
                    downloading = nil
                    refreshInstalled()
                    listid = UUID()
                    haptfeedback(outcome.ok ? 1 : 2)
                    status = outcome.ok ? outcome.message : ""
                    showAlert(with: outcome.message)
                }
            }
        case .failure(let error):
            downloading = nil
            status = ""
            showAlert(with: "导入失败：\(error.localizedDescription)")
        }
    }

    /// 同步执行整个导入流程，返回可展示的结果（包含失败的具体原因）
    private func importSDKFile(_ fileURL: URL) -> (ok: Bool, message: String) {
        let fm = FileManager.default
        cfolder(atPath: "\(global_container)/tmp")

        // 1) 复制到自己的沙盒（fileImporter 给的 URL 可能随授权结束失效）
        //    用 copyItem 而不是读进内存，避免大包 OOM
        let scope = fileURL.startAccessingSecurityScopedResource()
        let local = "\(global_container)/tmp/sdk-src-\(UUID()).bin"
        var copied = false
        do {
            try fm.copyItem(at: fileURL, to: URL(fileURLWithPath: local))
            copied = true
        } catch {
            // 同一个文件系统内可能不支持 copy，退回硬链接/直接读路径
            copied = (cp(fileURL.path, local) == 0)
        }
        if scope { fileURL.stopAccessingSecurityScopedResource() }
        let source = copied ? local : fileURL.path
        defer { if copied { _ = rm(local) } }

        guard fm.fileExists(atPath: source) else {
            return (false, "无法读取该文件，请重新选择")
        }

        // 2) 解压：先 zip，再 tar
        let staged = "\(global_container)/tmp/sdk-import-\(UUID())"
        cfolder(atPath: staged)
        defer { _ = rm(staged) }

        var extractError = ""
        let zipResult = libzip_unzip(source, staged)
        if zipResult != 0 {
            let (ok, log) = unarchiveTar(source, to: staged)
            if !ok {
                extractError = log.isEmpty ? "无法识别压缩格式" : log
            }
        }

        // 3) 找 SDK
        let found = collectSDKs(in: staged)
        if found.isEmpty {
            // 把目录结构带出来，方便判断到底是解压失败还是结构不符
            let listing = describeTree(staged, limit: 12)
            var msg = "导入失败：压缩包里没有找到 iPhoneOS*.sdk 目录\n\n"
            if !extractError.isEmpty {
                msg += "解压错误：\(extractError)\n\n"
            }
            msg += "解压后的内容：\n\(listing)"
            return (false, msg)
        }
        return (true, "已导入 SDK：\n" + found.joined(separator: "\n"))
    }

    /// 列出目录结构（用于错误提示）
    private func describeTree(_ path: String, limit: Int) -> String {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: path), !entries.isEmpty else {
            return "（空目录）"
        }
        var lines: [String] = []
        for name in entries.prefix(limit) {
            var isDir: ObjCBool = false
            fm.fileExists(atPath: "\(path)/\(name)", isDirectory: &isDir)
            lines.append(isDir.boolValue ? "\(name)/" : name)
        }
        if entries.count > limit { lines.append("…（共 \(entries.count) 项）") }
        return lines.joined(separator: "\n")
    }

    /// 在解压目录里找出 SDK（可能多套一层，也可能是没有版本号的 iPhoneOS.sdk）
    private func collectSDKs(in staged: String) -> [String] {
        let fm = FileManager.default
        var roots = [staged]
        // 往下剥最多 3 层“只有一个子目录”的情况
        var cursor = staged
        for _ in 0..<3 {
            guard let one = singleSubdirectory(of: cursor) else { break }
            roots.append(one)
            cursor = one
        }

        var results: [String] = []
        for root in roots {
            let entries = (try? fm.contentsOfDirectory(atPath: root)) ?? []
            for name in entries where name.hasSuffix(".sdk") && name.hasPrefix("iPhoneOS") {
                let src = "\(root)/\(name)"
                // 版本号从 SDKSettings.plist 里读，读到就用规范名 iPhoneOS<ver>.sdk
                let version = sdkVersion(of: src)
                let finalName = version.isEmpty ? name : "iPhoneOS\(version).sdk"
                let dest = "\(global_sdkpath)/\(finalName)"
                _ = rm(dest)
                if mv(src, dest) == 0 {
                    results.append(version.isEmpty ? name : "iOS \(version)")
                }
                break
            }
            if !results.isEmpty { break }
        }
        return results
    }

    /// 用系统 tar 解压（libzip 不支持 tar.gz / tgz），返回是否成功与错误输出
    private func unarchiveTar(_ path: String, to destination: String) -> (Bool, String) {
        var candidates: [String] = []
        #if jailbreak
        candidates = ["/var/jb/usr/bin/tar", "/usr/bin/tar", "/var/jb/bin/tar", "/bin/tar"]
        #else
        candidates = ["/usr/bin/tar", "/var/jb/usr/bin/tar", "/bin/tar"]
        #endif

        let fm = FileManager.default
        var tarPath: String? = nil
        for candidate in candidates where fm.isExecutableFile(atPath: candidate) {
            tarPath = candidate
            break
        }
        guard let tar = tarPath else {
            return (false, "系统里没有找到 tar 命令")
        }

        // gzip -dc | tar -x 比 tar -xzf 兼容性更好（部分 bsdtar 对 z 参数支持不一致）
        // 注意：不要加 2>/dev/null，否则真实错误会被吞掉
        let commands = [
            "'\(tar)' -xzf '\(path)' -C '\(destination)'",
            "'\(tar)' -xf '\(path)' -C '\(destination)'",
            "gzip -dc '\(path)' | '\(tar)' -xf - -C '\(destination)'"
        ]

        var lastLog = ""
        let uids: [uid_t] = [501, 0]
        for command in commands {
            for uid in uids {
                #if stock
                if uid == 0 { continue }
                #endif
                let output = runShellCapture(command, uid: uid)
                if output.code == 0 { return (true, "") }
                if !output.log.isEmpty { lastLog = output.log }
            }
        }
        return (false, lastLog)
    }

    /// 执行命令并捕获输出，返回 (退出码, stderr+stdout)
    private func runShellCapture(_ command: String, uid: uid_t) -> (code: Int, log: String) {
        let outPath = "\(global_container)/tmp/sdk-tar-\(UUID()).log"
        let full = command + " > '\(outPath)' 2>&1"
        let code = shell(full, uid: uid, env: [])
        var text = (try? String(contentsOfFile: outPath, encoding: .utf8)) ?? ""
        _ = rm(outPath)
        if text.count > 400 { text = String(text.suffix(400)) }
        return (code, text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 通过文件头判断是不是 tar / gzip
    private func looksLikeTarball(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { handle.closeFile() }
        let head = handle.readData(ofLength: 4)
        guard head.count >= 2 else { return false }
        let b = [UInt8](head)
        if b[0] == 0x1F && b[1] == 0x8B { return true }   // gzip
        if b[0] == 0x42 && b[1] == 0x5A { return true }   // bzip2
        if b[0] == 0xFD && b[1] == 0x37 { return true }   // xz
        return false
    }

    /// 读取 SDKSettings.plist 里的 Version
    private func sdkVersion(of sdkPath: String) -> String {
        let plist = "\(sdkPath)/SDKSettings.plist"
        if let dict = NSDictionary(contentsOfFile: plist) as? [String: Any],
           let version = dict["Version"] as? String {
            return version
        }
        let json = "\(sdkPath)/SDKSettings.json"
        if let data = FileManager.default.contents(atPath: json),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let version = obj["Version"] as? String {
            return version
        }
        return ""
    }

    // MARK: - 移除

    private func remove(_ sdk: String) -> Void {
        DispatchQueue.global(qos: .utility).async {
            ShowAlert(UIAlertController(title: "正在移除 SDK…", message: "", preferredStyle: .alert))
            // 早期版本可能以 root 写入过，先尝试普通删除，失败再提权
            if rm("\(global_sdkpath)/iPhoneOS\(sdk).sdk") != 0 {
                #if !stock
                shell("rm -rf \(global_sdkpath)/iPhoneOS\(sdk).sdk", uid: 0)
                #endif
            }
            DispatchQueue.main.async {
                refreshInstalled()
                listid = UUID()
                DismissAlert()
            }
        }
    }
}
