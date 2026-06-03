import Foundation
import Combine

/// Persisted user preferences, backed by UserDefaults. Single source of truth for the
/// menu-bar percentage toggle and the battery poll interval. Launch-at-login is NOT here;
/// that lives in `LoginItem` (SMAppService is its own source of truth).
@MainActor
final class AppSettings: ObservableObject {
    enum Keys {
        static let showPercentInMenuBar = "showPercentInMenuBar"
        static let pollIntervalSeconds = "pollIntervalSeconds"
        static let favouriteDeviceID = "favouriteDeviceID"
    }

    static let defaultPollIntervalSeconds = 120
    static let pollIntervalChoices = [10, 30, 60, 120, 300]

    /// Human label for a poll interval, e.g. "Every 30 seconds" / "Every 2 minutes".
    static func pollIntervalLabel(_ seconds: Int) -> String {
        switch seconds {
        case ..<60: return "Every \(seconds) seconds"
        case 60:    return "Every minute"
        default:    return "Every \(seconds / 60) minutes"
        }
    }

    @Published var showPercentInMenuBar: Bool {
        didSet { defaults.set(showPercentInMenuBar, forKey: Keys.showPercentInMenuBar) }
    }

    @Published var pollIntervalSeconds: Int {
        didSet { defaults.set(pollIntervalSeconds, forKey: Keys.pollIntervalSeconds) }
    }

    /// Stable id (from `DeviceReading.id`) of the device shown as primary in the menu bar.
    /// `nil` = no favourite chosen yet; the monitor falls back to the first online device.
    @Published var favouriteDeviceID: String? {
        didSet { defaults.set(favouriteDeviceID, forKey: Keys.favouriteDeviceID) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Default the menu-bar percentage to on when nothing is stored yet.
        if defaults.object(forKey: Keys.showPercentInMenuBar) == nil {
            defaults.set(true, forKey: Keys.showPercentInMenuBar)
        }
        self.showPercentInMenuBar = defaults.bool(forKey: Keys.showPercentInMenuBar)

        // `integer(forKey:)` returns 0 when unset; 0 is not a valid choice so it falls
        // back to the default. Also guards against any out-of-range stored value.
        let stored = defaults.integer(forKey: Keys.pollIntervalSeconds)
        self.pollIntervalSeconds = AppSettings.pollIntervalChoices.contains(stored)
            ? stored
            : AppSettings.defaultPollIntervalSeconds

        self.favouriteDeviceID = defaults.string(forKey: Keys.favouriteDeviceID)
    }
}
