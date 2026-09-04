import Foundation
import XCTest
@testable import AssemblageKit

final class DiagnosticsStoreTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AssemblageDiagnosticsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: scratch.path
        )
        try? FileManager.default.removeItem(at: scratch)
    }

    func testWriteStoresPayloadUnchanged() throws {
        let payload = Data("{\"absturz\":true}".utf8)
        let store = DiagnosticsStore(directory: scratch)

        let report = try store.write(payload, receivedAt: Date(timeIntervalSince1970: 1_700_000_000))

        XCTAssertTrue(FileManager.default.fileExists(atPath: report.path))
        XCTAssertEqual(try Data(contentsOf: report), payload)
    }

    func testTwoReportsInSameSecondDoNotOverwriteEachOther() throws {
        let store = DiagnosticsStore(directory: scratch)
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        let first = try store.write(Data("eins".utf8), receivedAt: date)
        let second = try store.write(Data("zwei".utf8), receivedAt: date)

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(
            Set(try store.reports().map(\.lastPathComponent)),
            Set([first.lastPathComponent, second.lastPathComponent])
        )
        XCTAssertEqual(try Data(contentsOf: first), Data("eins".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("zwei".utf8))
    }

    func testReportsReturnsNewestFirst() throws {
        let store = DiagnosticsStore(directory: scratch)
        let newest = try store.write(Data("neu".utf8), receivedAt: Date(timeIntervalSince1970: 300))
        let oldest = try store.write(Data("alt".utf8), receivedAt: Date(timeIntervalSince1970: 100))
        let middle = try store.write(Data("mitte".utf8), receivedAt: Date(timeIntervalSince1970: 200))

        XCTAssertEqual(
            try store.reports().map(\.lastPathComponent),
            [newest, middle, oldest].map(\.lastPathComponent)
        )
    }

    func testPruneRemovesOldReportsAndKeepsRecentReports() throws {
        let store = DiagnosticsStore(directory: scratch)
        let now = Date(timeIntervalSince1970: 20_000_000)
        let old = try store.write(
            Data("alt".utf8),
            receivedAt: now.addingTimeInterval(-(DiagnosticsStore.maximumAge + 1))
        )
        let recent = try store.write(
            Data("neu".utf8),
            receivedAt: now.addingTimeInterval(-DiagnosticsStore.maximumAge + 1)
        )

        try store.prune(now: now)

        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertEqual(try store.reports().map(\.lastPathComponent), [recent.lastPathComponent])
    }

    func testPruneRemovesExcessReportsAndKeepsNewestLimit() throws {
        let store = DiagnosticsStore(directory: scratch)
        let now = Date(timeIntervalSince1970: 20_000_000)
        var reports: [URL] = []
        for offset in 0..<(DiagnosticsStore.maximumReportCount + 2) {
            reports.append(try store.write(
                Data("\(offset)".utf8),
                receivedAt: now.addingTimeInterval(TimeInterval(offset - 100))
            ))
        }

        try store.prune(now: now)

        let remaining = try store.reports()
        XCTAssertEqual(remaining.count, DiagnosticsStore.maximumReportCount)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reports[0].path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: reports[1].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: reports.last!.path))
    }

    func testPruneOnEmptyDirectoryDoesNotThrow() throws {
        let store = DiagnosticsStore(directory: scratch)

        XCTAssertNoThrow(try store.prune(now: Date()))
        XCTAssertEqual(try store.reports(), [])
    }

    func testWriteCreatesMissingDirectory() throws {
        let directory = scratch.appendingPathComponent("noch/nicht/vorhanden")
        let store = DiagnosticsStore(directory: directory)

        let report = try store.write(Data("bericht".utf8), receivedAt: Date())

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: report.path))
    }

    func testPruneDoesNotDeleteForeignFiles() throws {
        let store = DiagnosticsStore(directory: scratch)
        let foreign = scratch.appendingPathComponent("Assemblage-Diagnose-eigene-notiz.json")
        try Data("behalten".utf8).write(to: foreign)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 0)],
            ofItemAtPath: foreign.path
        )

        try store.prune(now: Date(timeIntervalSince1970: 20_000_000))

        XCTAssertEqual(try Data(contentsOf: foreign), Data("behalten".utf8))
        XCTAssertEqual(try store.reports(), [])
    }

    func testWriteToNonWritableDirectoryThrows() throws {
        let directory = scratch.appendingPathComponent("gesperrt")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        let store = DiagnosticsStore(directory: directory)

        XCTAssertThrowsError(try store.write(Data("bericht".utf8), receivedAt: Date()))
    }
}
