import ServiceManagement

/// Wrapper around the modern login-item API. SMAppService.mainApp registers the running
/// .app bundle to launch at login via LaunchServices (which gives it a proper GUI session,
/// so no `open -W` shim is needed). This type is the single source of truth for the state.
enum LoginItem {
    /// True when the app is currently registered to launch at login.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Register or unregister the app as a login item. Throws on failure so the UI can
    /// surface the error and reflect the real (unchanged) status.
    static func setEnabled(_ on: Bool) throws {
        if on {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
