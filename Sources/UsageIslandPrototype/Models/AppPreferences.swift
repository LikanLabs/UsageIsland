import Combine
import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, spanish, english
    var id: String { rawValue }
}

enum EdgePosition: String, CaseIterable, Identifiable {
    case left, right, top
    var id: String { rawValue }
}

@MainActor
final class AppPreferences: ObservableObject {
    static let shared = AppPreferences()
    static let scaleRange = 0.75...1.5
    private let defaults: UserDefaults

    @Published var scale: Double {
        didSet {
            let valid = Self.validScale(scale)
            if scale != valid { scale = valid }
            defaults.set(valid, forKey: "appearance.scale")
        }
    }
    @Published var language: AppLanguage {
        didSet { defaults.set(language.rawValue, forKey: "appearance.language") }
    }
    @Published var position: EdgePosition {
        didSet { defaults.set(position.rawValue, forKey: "appearance.position") }
    }
    @Published var autoHide: Bool {
        didSet { defaults.set(autoHide, forKey: "appearance.autoHide") }
    }
    @Published var showsConsumedPercent: Bool {
        didSet { defaults.set(showsConsumedPercent, forKey: "appearance.showsConsumedPercent") }
    }
    /// Notify at 20 %, 10 % and 0 % remaining, and when a low window resets.
    @Published var usageAlerts: Bool {
        didSet { defaults.set(usageAlerts, forKey: "alerts.usage") }
    }
    /// The welcome page runs once. People upgrading from a version without
    /// it already set the app up, so they never see it.
    @Published var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: "onboarding.completed") }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        scale = Self.validScale(defaults.object(forKey: "appearance.scale") as? Double ?? 1)
        language = AppLanguage(rawValue: defaults.string(forKey: "appearance.language") ?? "") ?? .system
        position = EdgePosition(rawValue: defaults.string(forKey: "appearance.position") ?? "") ?? .right
        autoHide = defaults.bool(forKey: "appearance.autoHide")
        // New installs show what is left, matching the ring and the alerts.
        showsConsumedPercent = defaults.object(forKey: "appearance.showsConsumedPercent") as? Bool ?? false
        usageAlerts = defaults.object(forKey: "alerts.usage") as? Bool ?? true
        let existingInstall = ["appearance.scale", "appearance.language", "appearance.position",
                               "appearance.autoHide", "appearance.showsConsumedPercent", "alerts.usage"]
            .contains { defaults.object(forKey: $0) != nil }
        hasCompletedOnboarding = defaults.object(forKey: "onboarding.completed") as? Bool ?? existingInstall
    }

    var isSpanish: Bool {
        language == .spanish || (language == .system && Locale.preferredLanguages.first?.hasPrefix("es") == true)
    }
    /// Dates follow the displayed text language while keeping the user's
    /// region and clock preferences, so text and dates never mix languages.
    var locale: Locale {
        let code = isSpanish ? "es" : "en"
        let current = Locale.autoupdatingCurrent
        if current.language.languageCode?.identifier == code { return current }
        var components = Locale.Components(locale: current)
        components.languageComponents = Locale.Language.Components(languageCode: .init(code))
        return Locale(components: components)
    }
    func text(_ english: String, _ spanish: String) -> String { isSpanish ? spanish : english }

    private static func validScale(_ value: Double) -> Double {
        value.isFinite ? min(max(value, scaleRange.lowerBound), scaleRange.upperBound) : 1
    }
}
