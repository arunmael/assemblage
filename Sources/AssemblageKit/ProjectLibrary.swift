import AppKit

/// Ein gefundenes Assemblage-Projekt.
struct ProjectEntry: Equatable, Identifiable {
    var url: URL
    var name: String
    var modifiedAt: Date
    var id: URL { url }
}

enum ProjectLibrary {
    private static let fileExtension = "assemblage"

    /// Führt zuletzt benutzte und von Spotlight gefundene Projekte zusammen.
    /// Der Datumszugriff kommt von aussen, damit die Logik ohne Platte
    /// vollständig prüfbar bleibt.
    static func entries(
        recent: [URL],
        found: [URL],
        modificationDate: (URL) -> Date?
    ) -> [ProjectEntry] {
        var bekanntePfade = Set<URL>()
        var ergebnis: [ProjectEntry] = []

        for url in recent + found {
            guard url.pathExtension.caseInsensitiveCompare(fileExtension) == .orderedSame else {
                continue
            }

            guard let datum = modificationDate(url) else { continue }
            let schlüssel = url.standardizedFileURL.resolvingSymlinksInPath()
            guard bekanntePfade.insert(schlüssel).inserted else { continue }

            ergebnis.append(ProjectEntry(
                url: url,
                name: url.deletingPathExtension().lastPathComponent,
                modifiedAt: datum
            ))
        }

        return ergebnis.sorted { links, rechts in
            if links.modifiedAt != rechts.modifiedAt {
                return links.modifiedAt > rechts.modifiedAt
            }
            let namensvergleich = links.name.localizedStandardCompare(rechts.name)
            if namensvergleich != .orderedSame {
                return namensvergleich == .orderedAscending
            }
            return links.url.absoluteString < rechts.url.absoluteString
        }
    }
}

/// Beobachtet Spotlight und meldet die Pfade passender Dokumentpakete.
/// Die Instanz wird mit dem Projekte-Fenster gestoppt, damit nach dessen
/// Schliessen weder Beobachter noch eine laufende Abfrage übrig bleiben.
@MainActor
final class ProjectFinder {
    private let query = NSMetadataQuery()
    private let notificationCenter: NotificationCenter
    private let onChange: ([URL]) -> Void
    private var observers: [NSObjectProtocol] = []
    private(set) var isRunning = false

    init(
        notificationCenter: NotificationCenter = .default,
        onChange: @escaping ([URL]) -> Void
    ) {
        self.notificationCenter = notificationCenter
        self.onChange = onChange
        query.predicate = NSPredicate(format: "kMDItemFSName LIKE[c] %@", "*.assemblage")
        query.searchScopes = [NSMetadataQueryLocalComputerScope]
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true

        for name in [
            Notification.Name.NSMetadataQueryDidFinishGathering,
            Notification.Name.NSMetadataQueryDidUpdate
        ] {
            observers.append(notificationCenter.addObserver(
                forName: name,
                object: query,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reportResults() }
            })
        }
        query.start()
    }

    func stop() {
        guard isRunning || !observers.isEmpty else { return }
        query.stop()
        for observer in observers {
            notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
        isRunning = false
    }

    private func reportResults() {
        query.disableUpdates()
        let urls = query.results.compactMap { result -> URL? in
            guard let item = result as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String
            else { return nil }
            return URL(fileURLWithPath: path)
        }
        query.enableUpdates()
        onChange(urls)
    }

    deinit {
        query.stop()
        for observer in observers {
            notificationCenter.removeObserver(observer)
        }
    }
}
