import Foundation
import XCTest

@testable import UsageIslandPrototype

final class ReleaseWorkflowTests: XCTestCase {
    func testReleaseJobRunsTestsAndResilienceBeforePackageAndPublish() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".github/workflows/release.yml")
        let yaml = try String(contentsOf: url, encoding: .utf8)

        let testIndex = try firstIndex(of: "run: swift test", in: yaml)
        let resilienceIndex = try firstIndex(
            of: "run: ./Scripts/verify-resilience.sh",
            in: yaml
        )
        let packageIndex = try firstIndex(of: "Scripts/package-app.sh", in: yaml)
        let publishIndex = try firstIndex(of: "gh release create", in: yaml)

        XCTAssertLessThan(testIndex, resilienceIndex)
        XCTAssertLessThan(resilienceIndex, packageIndex)
        XCTAssertLessThan(packageIndex, publishIndex)
        let verifyJobIndex = try firstIndex(of: "  verify:", in: yaml)
        let releaseNeedsIndex = try firstIndex(of: "needs: verify", in: yaml)

        XCTAssertLessThan(verifyJobIndex, testIndex)
        XCTAssertLessThan(resilienceIndex, releaseNeedsIndex)
        XCTAssertLessThan(releaseNeedsIndex, packageIndex)
        XCTAssertFalse(yaml.contains("continue-on-error: true"))
        // Only keychain cleanup may run after a failure; publishing must not.
        for line in yaml.split(separator: "\n") where line.contains("if: always()") {
            XCTAssertTrue(line.contains("DEVELOPER_ID_CERTIFICATE_P12"), String(line))
        }
        XCTAssertTrue(yaml.contains("tags: ['v[0-9]+.[0-9]+.[0-9]+']"))

        // The tap only moves after the release it points to exists.
        let tapIndex = try firstIndex(of: "name: Update Homebrew tap", in: yaml)
        XCTAssertLessThan(publishIndex, tapIndex)
        XCTAssertTrue(yaml.contains("if: env.HOMEBREW_TAP_TOKEN != ''"))
    }

    private func firstIndex(of needle: String, in yaml: String) throws -> String.Index {
        guard let index = yaml.range(of: needle)?.lowerBound else {
            XCTFail("Missing \(needle) in release.yml")
            throw NSError(domain: "ReleaseWorkflowTests", code: 1)
        }
        return index
    }
}
