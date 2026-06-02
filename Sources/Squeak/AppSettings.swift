import Foundation
import Combine

/// Persisted user preferences, backed by UserDefaults. Single source of truth for the
/// menu-bar percentage toggle and the battery poll interval. Launch-at-login is NOT here;
/// that lives in `LoginItem` (SMAppService is its own source of truth).
@MainActor
final class AppSettings: ObservableObject {
    enum Keys {
        static let showPercentInMenuBar = "showPercentInMenuBar"
        static let pollIntervalMinutes = "pollIntervalMinutes"
    }

    static let defaultPollIntervalMinutes = 2
    static let pollIntervalChoices = [1, 2, 5, 10, 30]

    @Published var showPercentInMenuBar: Bool {
        didSet { defaults.set(showPercentInMenuBar, forKey: Keys.showPercentInMenuBar) }
    }

    @Published var pollIntervalMinutes: Int {
        didSet { defaults.set(pollIntervalMinutes, forKey: Keys.pollIntervalMinutes) }
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
        let stored = defaults.integer(forKey: Keys.pollIntervalMinutes)
        self.pollIntervalMinutes = AppSettings.pollIntervalChoices.contains(stored)
            ? stored
            : AppSettings.defaultPollIntervalMinutes
    }
}
