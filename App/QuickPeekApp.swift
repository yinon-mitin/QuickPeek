import SwiftUI

struct QuickPeekApp: App {
    var body: some Scene {
        Window("QuickPeek", id: "main") {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}

struct ContentView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("QuickPeek")
                .font(.largeTitle.bold())
            Text("Quick Look previews for code, configs, Markdown and tables. Select a file in Finder and press Space.")
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("If previews do not appear:").font(.headline)
                Text("1. Open System Settings → General → Login Items & Extensions → Quick Look.")
                Text("2. Turn on QuickPeek Preview.")
                Text("3. Turn off other extensions that handle the same files, such as Syntax Highlight.")
            }
            .foregroundStyle(.secondary)

            Button("Open Extension Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}
