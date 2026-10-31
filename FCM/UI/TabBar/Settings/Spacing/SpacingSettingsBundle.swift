import Foundation
import SwiftUI

struct SpacingSettingsBundle: View {
    @AppStorage("tabmode") var mode: Int = 0
    @AppStorage("tabspacing") var spacing: Int = 4

    var body: some View {
        List {
            Section(header: Text("模式")) {
                Picker("", selection: $mode) {
                    Text("制表符（Tab）").tag(0)
                    Text("空格").tag(1)
                }
                .pickerStyle(SegmentedPickerStyle())
            }
            if mode == 1 {
                Stepper("Spaces: \(spacing)", value: $spacing, in: 2...8)
            }
        }
        .navigationTitle("缩进")
        .navigationBarTitleDisplayMode(.inline)
    }
}
