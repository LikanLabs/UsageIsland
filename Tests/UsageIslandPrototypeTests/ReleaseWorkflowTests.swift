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
        XCTAssertFalse(yaml.contains("continue-on-error: true"))
        XCTAssertFalse(yaml.contains("if: always()"))
        XCTAssertTrue(yaml.contains("tags: ['v*.*.*']"))
    }

    private func firstIndex(of needle: String, in yaml: String) throws -> String.Index {
        guard let index = yaml.range(of: needle)?.lowerBound else {
            XCTFail("Missing \(needle) in release.yml")
            throw NSError(domain: "ReleaseWorkflowTests", code: 1)
        }
        return index
    }
}
