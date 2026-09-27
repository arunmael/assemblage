import XCTest
import Foundation
@testable import AssemblageKit
@testable import AssemblageModel

/// Importierte Bytes gehören auf die Platte; alte Versionen bleiben für
/// laufende Leser und bereits zusammengestellte Sicherungen erhalten.
final class DocumentResourcesSpillTests: XCTestCase {
    private let manager = FileManager.default

    private func dateien(_ ressourcen: DocumentResources) throws -> [URL] {
        try manager.contentsOfDirectory(at: ressourcen.spillDirectoryURL, includingPropertiesForKeys: nil)
    }

    func testHinzufuegenLagertBytesAus() throws {
        let ressourcen = DocumentResources()
        XCTAssertFalse(manager.fileExists(atPath: ressourcen.spillDirectoryURL.path))
        let daten = Data((0..<65_536).map { UInt8(truncatingIfNeeded: $0) })
        let name = ressourcen.addOriginal(daten, fileExtension: "jpg")
        let dateien = try dateien(ressourcen)
        XCTAssertEqual(dateien.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(dateien.first)), daten)
        XCTAssertEqual(ressourcen.data(for: name), daten)
        let andere = DocumentResources()
        XCTAssertNotEqual(ressourcen.spillDirectoryURL, andere.spillDirectoryURL)
    }

    func testErsetzenBehaeltAlteDateiUndLiefertNeueBytes() throws {
        let ressourcen = DocumentResources()
        let alt = Data("alte Maske".utf8)
        let neu = Data("neue Maske".utf8)
        let name = ressourcen.addMask(alt)
        let alteDatei = try XCTUnwrap(dateien(ressourcen).first)
        let leser = ressourcen.data(for: name)
        ressourcen.replace(name, with: neu)
        XCTAssertEqual(ressourcen.data(for: name), neu)
        XCTAssertEqual(leser, alt)
        XCTAssertEqual(try Data(contentsOf: alteDatei), alt)
        XCTAssertEqual(try dateien(ressourcen).count, 2)
    }

    func testSicherungSchreibtAusgelagerteInhalte() throws {
        let ressourcen = DocumentResources()
        let original = Data(repeating: 137, count: 1024 * 1024)
        let maske = Data("ersetzte Maske".utf8)
        let dokument = Data("Dokument".utf8)
        let originalName = ressourcen.addOriginal(original, fileExtension: "jpg")
        let maskenName = ressourcen.addMask(Data("vorher".utf8))
        let vorher = ressourcen.makeFileWrapper(documentData: dokument)
        ressourcen.replace(maskenName, with: maske)
        let ziel = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? manager.removeItem(at: ziel) }
        try manager.createDirectory(at: ziel, withIntermediateDirectories: true)
        let paket = ziel.appendingPathComponent("aktuell")
        try ressourcen.makeFileWrapper(documentData: dokument)
            .write(to: paket, options: .atomic, originalContentsURL: nil)
        XCTAssertEqual(try Data(contentsOf: paket.appendingPathComponent(originalName)), original)
        XCTAssertEqual(try Data(contentsOf: paket.appendingPathComponent(maskenName)), maske)
        XCTAssertEqual(try Data(contentsOf: paket.appendingPathComponent(DocumentPackage.documentFileName)), dokument)
        let altesPaket = ziel.appendingPathComponent("vorher")
        try vorher.write(to: altesPaket, options: .atomic, originalContentsURL: nil)
        XCTAssertEqual(try Data(contentsOf: altesPaket.appendingPathComponent(maskenName)), Data("vorher".utf8))
    }

    func testFreigabeEntferntInstanzVerzeichnis() throws {
        var verzeichnis: URL!
        autoreleasepool {
            var ressourcen: DocumentResources? = DocumentResources()
            verzeichnis = ressourcen!.spillDirectoryURL
            _ = ressourcen!.addMask(Data("Maske".utf8))
            XCTAssertTrue(manager.fileExists(atPath: verzeichnis.path))
            ressourcen = nil
        }
        XCTAssertFalse(manager.fileExists(atPath: verzeichnis.path))
    }

    func testAufraeumenEntferntNurAlteVerzeichnisse() throws {
        let wurzel = manager.temporaryDirectory.appendingPathComponent("Assemblage-Auslagerung")
        let alt = wurzel.appendingPathComponent(UUID().uuidString)
        let jung = wurzel.appendingPathComponent(UUID().uuidString)
        let datei = wurzel.appendingPathComponent(UUID().uuidString)
        defer {
            for url in [alt, jung, datei] { try? manager.removeItem(at: url) }
        }
        for url in [alt, jung] {
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("Rest".utf8).write(to: url.appendingPathComponent("inhalt"))
        }
        try Data("keine Sitzung".utf8).write(to: datei)
        let gestern = Date().addingTimeInterval(-25 * 60 * 60)
        for url in [alt, datei] {
            try manager.setAttributes([.modificationDate: gestern], ofItemAtPath: url.path)
        }
        try manager.setAttributes([.modificationDate: Date()], ofItemAtPath: jung.path)
        DocumentResources.removeStaleSpillDirectories()
        XCTAssertFalse(manager.fileExists(atPath: alt.path))
        XCTAssertTrue(manager.fileExists(atPath: jung.path))
        XCTAssertTrue(manager.fileExists(atPath: datei.path))
    }

    func testSchreibfehlerBehaeltBytesImWrapper() throws {
        let ressourcen = DocumentResources()
        try manager.createDirectory(at: ressourcen.spillDirectoryURL.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
        // Eine Datei am Verzeichnispfad erzwingt einen Schreibfehler.
        try Data().write(to: ressourcen.spillDirectoryURL)
        let name = ressourcen.addMask(Data("Import".utf8))
        XCTAssertEqual(ressourcen.data(for: name), Data("Import".utf8))
        ressourcen.replace(name, with: Data("Ersatz".utf8))
        XCTAssertEqual(ressourcen.data(for: name), Data("Ersatz".utf8))
    }
}
