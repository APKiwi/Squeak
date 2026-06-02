import SwiftUI
import AppKit

/// Content of the Settings (preferences) window. Three controls: launch at login,
/// show percentage in the menu bar, and battery update frequency.
struct SettingsView: View {
    @ObservedObject var settings: AppSettings

    // Login state lives in SMAppService, not UserDefaults. Seed from the real status and
    // write back through LoginItem on change.
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, newValue in
                    do {
                        try LoginItem.setEnabled(newValue)
                    } catch {
                        loginError = error.localizedDescription
                        // Snap the toggle back to the actual status; never lie about state.
                        launchAtLogin = LoginItem.isEnabled
                    }
                }

            Toggle("Show percentage in menu bar", isOn: $settings.showPercentInMenuBar)

            Picker("Update frequency", selection: $settings.pollIntervalSeconds) {
                ForEach(AppSettings.pollIntervalChoices, id: \.self) { seconds in
                    Text(AppSettings.pollIntervalLabel(seconds))
                        .tag(seconds)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 340)
        // Accessory (LSUIElement) apps open windows behind the frontmost app; activating
        // brings the Settings window to the front when it appears.
        .onAppear { NSApp.activate(ignoringOtherApps: true) }
        .alert(
            "Couldn't change login item",
            isPresented: Binding(
                get: { loginError != nil },
                set: { if !$0 { loginError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(loginError ?? "")
        }
    }
}
