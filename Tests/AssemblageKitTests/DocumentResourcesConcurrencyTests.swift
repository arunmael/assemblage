import XCTest
import AppKit
@testable import AssemblageKit
@testable import AssemblageModel

/// `DocumentResources` wird während eines Exports von einem Hintergrund-Task
/// gelesen, während der Hauptthread weiterarbeitet.
///
/// Genau das ist laut Plan 2.1 gewollt („rechenintensive Vorgänge laufen
/// asynchron, damit die Oberfläche nie einfriert") — und heisst zugleich, dass
/// der Nutzer währenddessen ein weiteres Foto hereinziehen kann. Ohne
/// Absicherung wäre das ein Wettlauf auf derselben Datenstruktur, und Plan 2.1
/// verbietet Abstürze ausdrücklich.
///
/// Ein Wettlauf lässt sich nicht mit Sicherheit herbeiführen; dieser Test ist
/// deshalb ein Rauchtest: Ohne Absicherung stürzt er nahezu immer ab, mit
/// Absicherung nie. Ein bestandener Lauf ist ein Hinweis, kein Beweis.
final class DocumentResourcesConcurrencyTests: XCTestCase {

    func testConcurrentReadsAndWritesDoNotCrash() {
        let resources = DocumentResources()

        // Ein paar Dateien, die gelesen werden können.
        let vorhandene = (0..<20).map {
            resources.addOriginal(Data("Datei \($0)".utf8), fileExtension: "png")
        }

        let fertig = expectation(description: "alle Zugriffe durch")
        fertig.expectedFulfillmentCount = 2

        // Leser, wie der Export einer ist.
        DispatchQueue.global(qos: .userInitiated).async {
            for _ in 0..<2_000 {
                for name in vorhandene {
                    _ = resources.data(for: name)
                }
                _ = resources.fileNames
            }
            fertig.fulfill()
        }

        // Schreiber, wie ein Import während des Exports einer ist.
        DispatchQueue.global(qos: .userInitiated).async {
            for durchgang in 0..<2_000 {
                let name = resources.addOriginal(Data("neu \(durchgang)".utf8), fileExtension: "png")
                resources.replace(name, with: Data("ersetzt".utf8))
            }
            fertig.fulfill()
        }

        wait(for: [fertig], timeout: 60)

        // Die anfangs abgelegten Dateien müssen den Ansturm unbeschadet
        // überstanden haben.
        for name in vorhandene {
            XCTAssertNotNil(resources.data(for: name))
        }
    }
}
