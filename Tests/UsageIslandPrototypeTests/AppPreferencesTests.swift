import Foundation
import XCTest
@testable import UsageIslandPrototype

@MainActor
final class AppPreferencesTests: XCTestCase {
    func testSizeAndLanguageSurviveReload() throws {
        let suite = "UsageIsland.preferences.tests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.scale = 1.25
        preferences.language = .spanish
        preferences.position = .top
        preferences.autoHide = true
        let reloaded = AppPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.scale, 1.25)
        XCTAssertEqual(reloaded.language, .spanish)
        XCTAssertEqual(reloaded.position, .top)
        XCTAssertTrue(reloaded.autoHide)
        XCTAssertEqual(reloaded.text("Usage", "Consumo"), "Consumo")
        reloaded.language = .english
        XCTAssertEqual(reloaded.text("Usage", "Consumo"), "Usage")
    }

    func testInvalidStoredPreferencesFallBackAndScaleIsBounded() throws {
        let suite = "UsageIsland.preferences.tests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(-5.0, forKey: "appearance.scale")
        defaults.set("unsupported", forKey: "appearance.language")
        defaults.set("unsupported", forKey: "appearance.position")
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertEqual(preferences.scale, 0.75)
        XCTAssertEqual(preferences.language, .system)
        XCTAssertEqual(preferences.position, .right)
        XCTAssertFalse(preferences.autoHide)
        preferences.scale = 10
        XCTAssertEqual(preferences.scale, 1.5)
        preferences.scale = .nan
        XCTAssertEqual(preferences.scale, 1)
    }
}

@MainActor
final class OnboardingPreferenceTests: XCTestCase {
    func testNewInstallShowsWelcomeAndAvailablePercent() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertFalse(preferences.hasCompletedOnboarding)
        XCTAssertFalse(preferences.showsConsumedPercent, "new installs show what is left")
        XCTAssertTrue(preferences.usageAlerts)

        preferences.hasCompletedOnboarding = true
        XCTAssertTrue(AppPreferences(defaults: defaults).hasCompletedOnboarding)
    }

    func testPeopleUpgradingNeverSeeTheWelcome() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("top", forKey: "appearance.position")
        XCTAssertTrue(AppPreferences(defaults: defaults).hasCompletedOnboarding)
    }

    func testExistingChoiceOfPercentIsKept() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "appearance.showsConsumedPercent")
        XCTAssertTrue(AppPreferences(defaults: defaults).showsConsumedPercent)
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "UsageIsland.onboarding.tests.\(UUID())"
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }
}
