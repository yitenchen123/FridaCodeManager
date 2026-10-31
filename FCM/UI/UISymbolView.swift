 /*
 SymbolView.swift

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
import UIKit

struct SFSymbolView: View {
    var body: some View {
        List {
            NavigationLink( destination: SFSymbolListView(symbols: gSFSymbols())) {
                Text("全部")
            }
            Section(header: Text("分类")) {
                NavigationLink( destination: SFSymbolListView(symbols: gcommunication())) {
                    Label("通讯",systemImage: "bubble.left.and.bubble.right.fill")
                }
                NavigationLink( destination: SFSymbolListView(symbols: gweather())) {
                    Label("天气",systemImage: "cloud.moon.rain.fill")
                }
                NavigationLink( destination: SFSymbolListView(symbols: gdevices())) {
                    Label("设备",systemImage: "airpodspro")
                }
                NavigationLink( destination: SFSymbolListView(symbols: gconnectivity())) {
                    Label("连接",systemImage: "network")
                }
                NavigationLink( destination: SFSymbolListView(symbols: gnature())) {
                    Label("自然",systemImage: "leaf.fill")
                }
            }
        }
        .listStyle(InsetGroupedListStyle())
        .navigationBarTitle("SF 符号")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct SFSymbolListView: View {
    @State var symbols: [String]
    var body: some View {
        List(symbols, id: \.self) { symbolName in
            Button( action: {
                copyToClipboard(text: symbolName)
            }){
                HStack {
                    Image(systemName: symbolName)
                        .frame(width: 30, height: 30)
                    Spacer()
                    Text(symbolName)
                }
            }
        }
        .navigationBarTitle("SF 符号")
        .navigationBarTitleDisplayMode(.inline)
        .listStyle(InsetGroupedListStyle())
    }
}
