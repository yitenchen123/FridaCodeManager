import SwiftUI

struct WikiView: View {
    var body: some View {
        NavigationView() {
            XMLDetailView(title: "百科", filePath: "https://raw.githubusercontent.com/fridakitten/FridaWikiXMLRepo/main/main.xml")
        }
    }
}
