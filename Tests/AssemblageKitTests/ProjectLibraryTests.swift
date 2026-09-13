import XCTest
@testable import AssemblageKit

final class ProjectLibraryTests: XCTestCase {
    private let älter = Date(timeIntervalSince1970: 1_000)
    private let neuer = Date(timeIntervalSince1970: 2_000)

    func testDoppelteStandardisierteURLsErscheinenNurEinmal() {
        let direkt = URL(fileURLWithPath: "/tmp/Collage.assemblage")
        let mitPunkt = URL(fileURLWithPath: "/tmp/./Collage.assemblage")

        let result = ProjectLibrary.entries(
            recent: [mitPunkt],
            found: [direkt],
            modificationDate: { _ in self.neuer }
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.url, mitPunkt, "der Eintrag aus den zuletzt benutzten Dokumenten gewinnt")
    }

    func testFremdeDateiendungenWerdenAusgeschlossen() {
        let result = ProjectLibrary.entries(
            recent: [URL(fileURLWithPath: "/tmp/Bild.png")],
            found: [URL(fileURLWithPath: "/tmp/Text.txt")],
            modificationDate: { _ in self.neuer }
        )

        XCTAssertTrue(result.isEmpty)
    }

    func testSortiertNachDatumUndBeiGleichstandAlphabetisch() {
        let alpha = URL(fileURLWithPath: "/tmp/Alpha.assemblage")
        let beta = URL(fileURLWithPath: "/tmp/Beta.assemblage")
        let neu = URL(fileURLWithPath: "/tmp/Neu.assemblage")

        let result = ProjectLibrary.entries(
            recent: [beta, neu],
            found: [alpha],
            modificationDate: { url in url == neu ? self.neuer : self.älter }
        )

        XCTAssertEqual(result.map(\.name), ["Neu", "Alpha", "Beta"])
    }

    func testURLsOhneÄnderungsdatumWerdenAusgeschlossen() {
        let vorhanden = URL(fileURLWithPath: "/tmp/Vorhanden.assemblage")
        let gelöscht = URL(fileURLWithPath: "/tmp/Geloescht.assemblage")

        let result = ProjectLibrary.entries(
            recent: [vorhanden, gelöscht],
            found: [],
            modificationDate: { $0 == vorhanden ? self.neuer : nil }
        )

        XCTAssertEqual(result.map(\.url), [vorhanden])
    }

    func testLeereFundlisteBehältZuletztBenutzteDokumente() {
        let zuletztBenutzt = URL(fileURLWithPath: "/tmp/Zuletzt.assemblage")

        let result = ProjectLibrary.entries(
            recent: [zuletztBenutzt],
            found: [],
            modificationDate: { _ in self.neuer }
        )

        XCTAssertEqual(result.map(\.url), [zuletztBenutzt])
    }
}
