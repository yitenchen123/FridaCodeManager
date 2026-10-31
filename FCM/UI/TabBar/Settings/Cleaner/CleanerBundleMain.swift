import SwiftUI

struct Cleaner: View {
    var body: some View {
       List {
           Button(action: {
               clean(1)
           }) {
               Label("清理模块缓存", systemImage: "trash.fill")
           }
           Button(action: {
               clean(2)
           }) {
               Label("清理临时数据", systemImage: "trash.fill")
           }
       }
       .navigationTitle("清理工具")
       .navigationBarTitleDisplayMode(.inline)
    }

    private func clean(_ arg: Int) {
        DispatchQueue.global(qos: .utility).async {
            ShowAlert(UIAlertController(title: "正在清理…", message: "", preferredStyle: .alert))
                let path: String = {
                    switch(arg) {
                        case 1:
                            return "\(global_documents)/../.cache"
                        case 2:
                            return "\(global_documents)/../tmp"
                        default:
                            return "\(global_documents)/../.cache"
                    }
                }()
                if FileManager.default.fileExists(atPath: path) {
                    do {
                        try adv_rm( atPath: path)
                    } catch {
                    }
                }
            DismissAlert()
        }
    }
}
