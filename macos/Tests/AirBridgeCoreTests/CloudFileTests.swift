import XCTest
@testable import AirBridgeCore

final class CloudFileTests: XCTestCase {
    func testLocalFileIsNotDataless() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("local.bin")
        try Data(repeating: 7, count: 1000).write(to: f)
        XCTAssertFalse(OutgoingFile.isDataless(f))
        XCTAssertEqual(try OutgoingFile.collect([dir]).count, 1)
    }

    /// Placeholders can't be created in a test; set AIRBRIDGE_DATALESS_SAMPLE to an
    /// iCloud file that is not downloaded (`ls -lO` shows "dataless") to check one.
    func testDatalessFileIsRefused() throws {
        guard let p = ProcessInfo.processInfo.environment["AIRBRIDGE_DATALESS_SAMPLE"] else {
            throw XCTSkip("AIRBRIDGE_DATALESS_SAMPLE not set")
        }
        let u = URL(fileURLWithPath: p)
        XCTAssertTrue(OutgoingFile.isDataless(u))
        XCTAssertThrowsError(try OutgoingFile.collect([u])) { XCTAssertTrue($0 is CloudFilesNotDownloaded) }
    }
}
