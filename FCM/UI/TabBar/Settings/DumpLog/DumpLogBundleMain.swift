import SwiftUI

struct DumpLogBundleMain: View {
    var body: some View {
        List {
            Button("导出日志") {
                mainlogSystem.dumpLog()
            }
            Button("清空日志") {
                mainlogSystem.clearLog()
            }
            Button("测试输出") {
                print("meow meow")
            }
        }
        .navigationTitle("DumpLog")
        .navigationBarTitleDisplayMode(.inline)
    }
}
