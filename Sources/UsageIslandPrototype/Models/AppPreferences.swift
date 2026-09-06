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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        scale = Self.validScale(defaults.object(forKey: "appearance.scale") as? Double ?? 1)
        language = AppLanguage(rawValue: defaults.string(forKey: "appearance.language") ?? "") ?? .system
        position = EdgePosition(rawValue: defaults.string(forKey: "appearance.position") ?? "") ?? .right
        autoHide = defaults.bool(forKey: "appearance.autoHide")
        showsConsumedPercent = defaults.object(forKey: "appearance.showsConsumedPercent") as? Bool ?? true
    }

    var isSpanish: Bool {
        language == .spanish || (language == .system && Locale.preferredLanguages.first?.hasPrefix("es") == true)
    }
    var locale: Locale {
        language == .system ? .autoupdatingCurrent : Locale(identifier: isSpanish ? "es" : "en")
    }
    func text(_ english: String, _ spanish: String) -> String { isSpanish ? spanish : english }

    private static func validScale(_ value: Double) -> Double {
        value.isFinite ? min(max(value, scaleRange.lowerBound), scaleRange.upperBound) : 1
    }
}
