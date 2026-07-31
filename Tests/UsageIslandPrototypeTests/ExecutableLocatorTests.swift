import Foundation
import XCTest

@testable import UsageIslandPrototype

final class ExecutableLocatorTests: XCTestCase {
    func testLocatorFindsExecutableInInjectedSearchPath() throws {
        let expected = URL(fileURLWithPath: "/custom/bin/codex")
        let locator = ExecutableLocator(
            environmentPath: "/path/without/codex",
            additionalSearchPaths: [URL(fileURLWithPath: "/custom/bin")],
            commonSearchPaths: [],
            isExecutable: { $0.standardizedFileURL == expected.standardizedFileURL }
        )

        XCTAssertEqual(try locator.locate("codex"), expected)
    }

    func testLocatorReturnsTypedNotFoundError() {
        let locator = ExecutableLocator(
            environmentPath: nil,
            commonSearchPaths: [],
            isExecutable: { _ in false }
        )

        XCTAssertThrowsError(try locator.locate("codex")) { error in
            XCTAssertEqual(error as? JSONRPCError, .executableNotFound("codex"))
        }
    }

    func testNotFoundErrorStoresOnlySanitizedBasename() {
        let locator = ExecutableLocator(
            environmentPath: nil,
            commonSearchPaths: [],
            isExecutable: { _ in false }
        )

        XCTAssertThrowsError(
            try locator.locate("/private/token-value/codex$")
        ) { error in
            XCTAssertEqual(error as? JSONRPCError, .executableNotFound("codex"))
            XCTAssertFalse(error.localizedDescription.contains("token-value"))
        }
    }

    func testRelativePATHComponentsAreRejected() {
        let locator = ExecutableLocator(
            environmentPath: "relative-bin",
            commonSearchPaths: [],
            isExecutable: { $0.path.hasSuffix("/relative-bin/codex") }
        )

        XCTAssertThrowsError(try locator.locate("codex")) { error in
            XCTAssertEqual(error as? JSONRPCError, .executableNotFound("codex"))
        }
    }
}
