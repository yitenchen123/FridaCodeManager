 /*
 AboutView.swift

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

struct Frida: View {
    @Binding var hello: UUID

    var credits = {
        var save = [
            ("SeanIsTethered", "主要开发者", "https://github.com/seanistethered.png"),
            ("AppInstaller iOS", "开发者", "https://github.com/AppInstalleriOSGH.png"),
            ("RoothideDev", "贡献者", "https://github.com/roothide.png"),
            ("Lorenzo Ferron", "贡献者", "https://github.com/miticollo.png"),
            ("Paolo Forni", "贡献者", "https://github.com/Pe13.png"),
            ("Manuel Chakravarty", "贡献者", "https://github.com/mchakravarty.png"),
            ("Ayame Yumemi", "图标设计", "https://github.com/ayayame09.png")
        ]
        if UserDefaults.standard.bool(forKey: "GIT_ENABLED") {
            if let gitToken = UserDefaults.standard.string(forKey: "GIT_TOKEN"),
                let user = getGithubUsername(fromToken: gitToken) {
                save.append((user, "用户", "https://github.com/\(user).png"))
            }
        }
        return save
    }()

    private let sideCredits = [
        ("Opa334", "TrollStore 支持", "https://github.com/opa334.png"),
        ("Theos", "SDK", "https://github.com/theos.png")
    ]

    private let others = [
        ("Chariz", "软件源托管", "https://github.com/chariz.png")
    ]

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("关于")) {
                    Text("FridaCodeManager \(global_version)")
                }

                ForEach([
                    ("鸣谢", credits),
                    ("协助", sideCredits),
                    ("其他", others)
                ], id: \.0) { sectionTitle, sectionCredits in
                    Section(header: Text(sectionTitle)) {
                        ForEach(sectionCredits.indices, id: \.self) { index in
                            HStack {
                                AsyncImageLoaderView(urlString: sectionCredits[index].2, width: 50, height: 50)
                                    .shadow(color: Color.black.opacity(0.5), radius: 2, x: 0, y: 2)
                                Spacer()
                                VStack {
                                    Text(sectionCredits[index].0)
                                        .foregroundColor(.primary)
                                        .font(.system(size: 14, weight: .bold))
                                    Text(sectionCredits[index].1)
                                        .foregroundColor(.secondary)
                                        .font(.system(size: 12, weight: .semibold))
                                }
                                .frame(width: 200)
                                Spacer()
                            }
                        }
                    }
                }
            }
            .id(hello)
            .navigationTitle("关于")
            .navigationBarTitleDisplayMode(.inline)
            .listStyle(InsetGroupedListStyle())
        }
    }
}
