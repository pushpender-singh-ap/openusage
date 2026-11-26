import Foundation

/// Refresh preferences are shared by all account cards of a provider and by the app and CLI.
struct RefreshSetting: Equatable, Sendable {
    static let key = "openusage.refreshMinutesByProvider.v1"
    static let didChangeNotification = Notification.Name("ProviderRefreshIntervalsDidChange")
    private static let choices = [5, 10, 15, 30, 60]
    private var minutesByFamily: [String: Int] = [:]

    init() {}

    init(defaults: UserDefaults) {
        for (family, value) in defaults.dictionary(forKey: Self.key) ?? [:] {
            guard let minutes = value as? Int, Self.options(for: family).contains(minutes) else {
                AppLog.warn(.config, "Ignoring invalid refresh interval for \(family)")
                continue
            }
            setMinutes(minutes, for: family)
        }
    }

    static func minimumMinutes(for providerID: String) -> Int {
        ProviderAccountID.family(of: providerID) == "claude" ? 10 : 5
    }

    static func options(for providerID: String) -> [Int] {
        choices.filter { $0 >= minimumMinutes(for: providerID) }
    }

    func minutes(for providerID: String) -> Int {
        minutesByFamily[ProviderAccountID.family(of: providerID)] ?? Self.minimumMinutes(for: providerID)
    }

    func interval(for providerID: String) -> TimeInterval {
        TimeInterval(minutes(for: providerID) * 60)
    }

    mutating func setMinutes(_ minutes: Int, for providerID: String) {
        let family = ProviderAccountID.family(of: providerID)
        guard Self.options(for: family).contains(minutes) else { return }
        minutesByFamily[family] = minutes == Self.minimumMinutes(for: family) ? nil : minutes
    }

    func save(to defaults: UserDefaults) {
        if minutesByFamily.isEmpty {
            defaults.removeObject(forKey: Self.key)
        } else {
            defaults.set(minutesByFamily, forKey: Self.key)
        }
    }
}
