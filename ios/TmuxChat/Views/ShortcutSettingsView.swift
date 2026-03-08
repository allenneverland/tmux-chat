import SwiftUI

struct ShortcutSettingsView: View {
    var body: some View {
        List {
            Section("Input Events") {
                Text("Shortcut customization has been removed.")
                Text("The app now uses a Blink-style event keyboard with locale-aware layouts and modifier states.")
                    .foregroundStyle(.secondary)
            }

            Section("Behavior") {
                Label("Single tap modifier: one-shot", systemImage: "1.circle")
                Label("Tap again: locked", systemImage: "2.circle")
                Label("Tap third time: off", systemImage: "3.circle")
            }
        }
        .navigationTitle("Shortcut Input")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        ShortcutSettingsView()
    }
}
