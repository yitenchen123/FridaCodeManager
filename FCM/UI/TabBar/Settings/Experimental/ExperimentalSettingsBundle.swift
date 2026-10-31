import SwiftUI
import Foundation

struct ExperimentalSettingsBundle: View {
    //@AppStorage("CETypechecking") var typecheck: Bool = false
    @AppStorage("GIT_ENABLED") var enabled: Bool = false
    @AppStorage("GIT_TOKEN") var token: String = ""
    var body: some View {
        List {
            /*Section(header: Text("Code Editor")) {
                Toggle("Typecheck Code", isOn: $typecheck)
            }*/
            Section(header: Text("GitHub")) {
                Toggle("启用", isOn: $enabled)
                if enabled {
                    SecureField("访问令牌", text: $token)
                }
            }
            NavigationLink(destination: DumpLogBundleMain()) {
                Label("日志系统（调试）", systemImage: "doc.fill")
            }
        }
        .navigationTitle("实验性功能")
        .navigationBarTitleDisplayMode(.inline)
    }
}
