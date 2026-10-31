 /* 
 Home.swift 

 Copyright (C) 2023, 2024 SparkleChan and SeanIsTethered 
 Copyright (C) 2024 fridakitten 

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

  ______    _     _         _____        __ _                           ______                    _       _   _
 |  ___|  (_)   | |       /  ___|      / _| |                          |  ___|                  | |     | | (_)
 | |_ _ __ _  __| | __ _  \ `--.  ___ | |_| |___      ____ _ _ __ ___  | |_ ___  _   _ _ __   __| | __ _| |_ _  ___  _ __
 |  _| '__| |/ _` |/ _` |  `--. \/ _ \|  _| __\ \ /\ / / _` | '__/ _ \ |  _/ _ \| | | | '_ \ / _` |/ _` | __| |/ _ \| '_ \
 | | | |  | | (_| | (_| | /\__/ / (_) | | | |_ \ V  V / (_| | | |  __/ | || (_) | |_| | | | | (_| | (_| | |_| | (_) | | | |
 \_| |_|  |_|\__,_|\__,_| \____/ \___/|_|  \__| \_/\_/ \__,_|_|  \___| \_| \___/ \__,_|_| |_|\__,_|\__,_|\__|_|\___/|_| |_|
 Founded by. Sean Boleslawski, Benjamin Hornbeck and Lucienne Salim in 2023
 */ 
    
import SwiftUI
import UniformTypeIdentifiers

struct Home: View {
    @State private var fileImporter = false
    @State private var zipImporter = false
    @State private var importing = false
    @State private var showProj = false
    @State private var about = false
    @State private var hello = UUID()
    @Binding var hellnah: UUID
    @Environment(\.presentationMode) private var presentationMode

    @State var AppName: String = ""
    @State var BundleID: String = ""

    #if jailbreak
    @State private var type = 1
    #elseif trollstore || stock
    @State private var type = 2
    #endif

    var body: some View {
        NavigationView {
            List {
                changelogSection
                projectButtonsSection
                aboutButton
            }
            .listStyle(InsetGroupedListStyle())
            .navigationTitle("FridaCodeManager")
            .navigationBarTitleDisplayMode(.inline)
            .fileImporter(isPresented: $fileImporter, allowedContentTypes: [.project], onCompletion: handleFileImport)
            .fileImporter(isPresented: $zipImporter, allowedContentTypes: [.zip, .archive], allowsMultipleSelection: false, onCompletion: handleZipImport)
            .disabled(importing)
            .overlay {
                if importing {
                    importingOverlay
                }
            }
            .sheet(isPresented: $showProj) {
                BottomPopupView {
                    POHeader(title: "新建工程")
                    POTextField(title: "应用名称", content: $AppName)
                    POTextField(title: "包标识符（Bundle ID）", content: $BundleID)
                    POPicker(function: createProject_trigger, title: "类型", arrays: [PickerArrays(title: "应用", items: [PickerItems(id: 1, name: "Swift"), PickerItems(id: 2, name: "ObjC"), PickerItems(id: 3, name: "Swift/ObjC"), PickerItems(id: 5, name: "Swift/C++")]), PickerArrays(title: "二进制", items: [PickerItems(id: 4, name: "C")])], type: $type)
                }
                .background(BackgroundClearView())
                .edgesIgnoringSafeArea([.bottom])
            }
        }
        .navigationViewStyle(.stack)
    }

    private func createProject_trigger() -> Void {
        if AppName != "", BundleID != "", isBashSafe(filename: AppName), isBashSafe(filename: BundleID) {
            haptfeedback(1)
            showProj = false
            _ = MakeApplicationProject(AppName, BundleID, type: type)
            (AppName, BundleID, hellnah) = ("", "", UUID())
        } else {
            haptfeedback(2)
        }
    }

    private var changelogSection: some View {
        Section(header: Text("更新日志")) {
            VStack {
                Spacer().frame(height: 10)
                ScrollView {
                    HStack {
                        Text(changelog)
                            .font(.system(size: 11))
                        Spacer()
                    }
                }
                Spacer()
            }
            .frame(height: UIScreen.main.bounds.height / 4)
        }
    }

    private var projectButtonsSection: some View {
        Section {
            Button(action: {
                AppName = ""
                BundleID = ""
                showProj = true
            }) {
                listItem(label: "新建工程", systemImageName: "+", text: "创建一个 FCM 工程")
            }
            Button(action: {
                fileImporter = true
            }) {
                listItem(label: "导入工程", systemImageName: "↑", text: "导入一个已有的 FCM 工程（.sproj）")
            }
            Button(action: {
                zipImporter = true
            }) {
                listItem(label: "从 ZIP 导入", systemImageName: "⇩", text: "从 zip 源码包导入工程")
            }
        }
    }

    private var aboutButton: some View {
        Button(action: {
            hello = UUID()
            about = true
        }) {
            listItem(label: "关于", systemImageName: "i", text: "查看本应用的相关信息")
        }
        .sheet(isPresented: $about) {
            Frida(hello: $hello)
        }
    }

    private func listItem(label: String, systemImageName: String, text: String) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(label).font(.headline)
                Text(text).font(.subheadline).foregroundColor(.gray)
            }
            Spacer()
            ZStack {
                Rectangle()
                    .foregroundColor(.secondary)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 30, height: 30)
                    .cornerRadius(4)
                Text(systemImageName)
                    .foregroundColor(Color(.systemBackground))
                    .frame(width: 20, height: 20)
                    .font(Font.custom("Menlo", size: 16).bold())
            }
        }
    }

    private var importingOverlay: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                Text("正在导入…").font(.footnote)
            }
            .padding(24)
            .background(Color(.systemBackground))
            .cornerRadius(14)
        }
    }

    private func handleZipImport(result: Result<[URL], Error>) -> Void {
        switch result {
        case .success(let urls):
            guard let fileURL = urls.first else { return }
            importing = true
            DispatchQueue.global(qos: .userInitiated).async {
                let scope = fileURL.startAccessingSecurityScopedResource()
                let outcome = importProjectArchive(target: fileURL.path)
                if scope { fileURL.stopAccessingSecurityScopedResource() }
                DispatchQueue.main.async {
                    importing = false
                    haptfeedback(outcome.ok ? 1 : 2)
                    showAlert(with: outcome.message)
                    hellnah = UUID()
                }
            }
        case .failure(let error):
            importing = false
            showAlert(with: "导入失败：\(error.localizedDescription)")
        }
    }

    private func handleFileImport(result: Result<URL, Error>) -> Void {
        switch result {
        case .success(let fileURL):
            importProj(target: fileURL.path)
            hellnah = UUID()
        case .failure(let error):
            print("Error importing file: \(error.localizedDescription)")
        }
    }
}

func isBashSafe(filename: String) -> Bool {
    let unsafeCharacters = [";", "&", "|", "<", ">", "`", "$", "(", ")", "{", "}", "[", "]", "/", "\"", "'", "\\", "\n", "\t", "\""]
    for char in unsafeCharacters {
        if filename.contains(char) {
            return false
        }
    }
    if filename.range(of: "[^\\x20-\\x7E]", options: .regularExpression) != nil {
        return false
    }
    return true
}

extension UTType {
    static var project: UTType { UTType(filenameExtension: "sproj")! }
}
