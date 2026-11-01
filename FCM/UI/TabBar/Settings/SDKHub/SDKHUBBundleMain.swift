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

    /// 多镜像回退：raw.githubusercontent 在国内经常超时，优先 jsDelivr
    private func mirrorURLs(_ sdk: String) -> [String] {
        let path = "FCM/UI/TabBar/Settings/SDKHub/sdk/iOS\(sdk).zip"
        return [
            "https://cdn.jsdelivr.net/gh/fridakitten/FridaCodeManager@main/\(path)",
            "https://fastly.jsdelivr.net/gh/fridakitten/FridaCodeManager@main/\(path)",
            "https://raw.githubusercontent.com/fridakitten/FridaCodeManager/main/\(path)"
        ]
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
            status = "正在导入 SDK…"
            DispatchQueue.global(qos: .userInitiated).async {
                let scope = fileURL.startAccessingSecurityScopedResource()
                let staged = "\(global_container)/tmp/sdk-import-\(UUID())"
                cfolder(atPath: staged)
                var ok = libzip_unzip(fileURL.path, staged) == 0
                // libzip 不认 tar.gz，扩展名是 tgz/tar.gz 时交给系统 tar
                let lower = fileURL.lastPathComponent.lowercased()
                if !ok && (lower.hasSuffix(".tgz") || lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tar")) {
                    #if !stock
                    let code = shell("mkdir -p '\(staged)' && tar xzf '\(fileURL.path)' -C '\(staged)' 2>/dev/null", uid: 501, env: [])
                    ok = (code == 0)
                    #endif
                }
                if scope { fileURL.stopAccessingSecurityScopedResource() }

                var found: [String] = []
                if ok {
                    found = collectSDKs(in: staged)
                }
                _ = rm(staged)

                DispatchQueue.main.async {
                    downloading = nil
                    refreshInstalled()
                    listid = UUID()
                    if found.isEmpty {
                        status = ""
                        haptfeedback(2)
                        showAlert(with: "导入失败：压缩包里没有找到 iPhoneOS*.sdk 目录\n\n支持的格式：zip、tar.gz / tgz")
                    } else {
                        status = "已导入：\(found.joined(separator: "、"))"
                        haptfeedback(1)
                        showAlert(with: "已导入 SDK：\n" + found.joined(separator: "\n"))
                    }
                }
            }
        case .failure(let error):
            downloading = nil
            status = ""
            showAlert(with: "导入失败：\(error.localizedDescription)")
        }
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
