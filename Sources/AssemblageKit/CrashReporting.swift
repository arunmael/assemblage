import Foundation
import MetricKit
import OSLog

/// Legt Diagnoseberichte lokal ab und räumt alte weg.
struct DiagnosticsStore {
    /// 90 Tage reichen auch bei selten gestarteten Installationen für die
    /// Fehlersuche, ohne Berichte unbegrenzt aufzubewahren.
    static let maximumAge: TimeInterval = 90 * 24 * 60 * 60

    /// Die zusätzliche Anzahlgrenze schützt vor vielen Berichten in kurzer
    /// Zeit; MetricKit-Payloads sind klein genug, dass 50 grosszügig bleiben.
    static let maximumReportCount = 50

    private static let filePrefix = "Assemblage-Diagnose-"

    let directory: URL

    /// Schreibt einen Bericht; gibt die angelegte Datei zurück.
    func write(_ payload: Data, receivedAt date: Date) throws -> URL {
        try createDirectoryIfNeeded()

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"

        let fileName = Self.filePrefix
            + formatter.string(from: date)
            + "-"
            + UUID().uuidString.lowercased()
            + ".json"
        let url = directory.appendingPathComponent(fileName, isDirectory: false)
        try payload.write(to: url, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        return url
    }

    /// Entfernt zu alte oder zu viele Berichte.
    func prune(now: Date) throws {
        let datedReports = try reportsWithDates()
        let oldestAllowedDate = now.addingTimeInterval(-Self.maximumAge)

        let recentReports = try datedReports.filter { report in
            guard report.date >= oldestAllowedDate else {
                try FileManager.default.removeItem(at: report.url)
                return false
            }
            return true
        }

        for report in recentReports.dropFirst(Self.maximumReportCount) {
            try FileManager.default.removeItem(at: report.url)
        }
    }

    /// Alle abgelegten Berichte, neueste zuerst.
    func reports() throws -> [URL] {
        try reportsWithDates().map(\.url)
    }

    private func createDirectoryIfNeeded() throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    private func reportsWithDates() throws -> [(url: URL, date: Date)] {
        try createDirectoryIfNeeded()
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        .compactMap { url -> (url: URL, date: Date)? in
            guard Self.isOwnReport(url),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let date = values.contentModificationDate
            else { return nil }
            return (url, date)
        }
        .sorted {
            if $0.date == $1.date {
                return $0.url.lastPathComponent > $1.url.lastPathComponent
            }
            return $0.date > $1.date
        }
    }

    private static func isOwnReport(_ url: URL) -> Bool {
        guard url.pathExtension == "json" else { return false }
        let stem = url.deletingPathExtension().lastPathComponent
        guard stem.hasPrefix(filePrefix) else { return false }

        let suffix = stem.dropFirst(filePrefix.count)
        guard suffix.count == 60 else { return false }
        let separator = suffix.index(suffix.startIndex, offsetBy: 23)
        guard suffix[separator] == "-" else { return false }

        let timestamp = String(suffix[..<separator])
        let uuidString = String(suffix[suffix.index(after: separator)...])
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        formatter.isLenient = false
        return formatter.date(from: timestamp) != nil && UUID(uuidString: uuidString) != nil
    }
}

/// Empfängt die von macOS nachträglich gelieferten MetricKit-Diagnosen.
///
/// MetricKit-Diagnosen gibt es auf macOS ab 12. Crashs, blockierte
/// Oberflächen (`MXHangDiagnostic`) und übermässige Plattenschreibvorgänge
/// (`MXDiskWriteExceptionDiagnostic`) sind auf dem Mac Teil des Payloads.
/// Die Zustellung ist aber nicht garantiert, erfolgt nur bei laufender App
/// mit registriertem Subscriber und üblicherweise ungefähr einmal täglich.
/// Ein Payload deckt bis zu 24 Stunden früherer Nutzung ab. Das ist deshalb
/// eine Hilfe für die spätere Fehlersuche, aber keine lückenlose oder sofortige
/// Absturzerkennung. Nicht jede iOS-Diagnose existiert auf dem Mac; insbesondere
/// ist `MXAppLaunchDiagnostic` dort ausdrücklich nicht verfügbar.
final class CrashReporter: NSObject, MXMetricManagerSubscriber {
    static let diagnosticsDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Assemblage", isDirectory: true)

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "de.arun.Assemblage",
        category: "Diagnoseberichte"
    )

    private let store: DiagnosticsStore
    private let fileQueue = DispatchQueue(label: "de.arun.Assemblage.Diagnoseberichte")

    init(store: DiagnosticsStore = DiagnosticsStore(directory: CrashReporter.diagnosticsDirectory)) {
        self.store = store
        super.init()
    }

    /// Die Registrierung selbst ist nicht werfend und erledigt keine
    /// Dateiarbeit. Das Aufräumen läuft getrennt, damit es den Start nicht
    /// verzögert und ein Dateisystemfehler die App nicht mitreisst.
    func start() {
        MXMetricManager.shared.add(self)
        fileQueue.async { [store] in
            do {
                try store.prune(now: Date())
            } catch {
                Self.logger.error("Alte Diagnoseberichte konnten nicht aufgeräumt werden: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let receivedAt = Date()
        fileQueue.async { [store] in
            for payload in payloads {
                do {
                    let readablePayload = Self.makeReadable(payload.jsonRepresentation())
                    _ = try store.write(readablePayload, receivedAt: receivedAt)
                } catch {
                    Self.logger.error("Ein Diagnosebericht konnte nicht abgelegt werden: \(error.localizedDescription, privacy: .public)")
                }
            }

            do {
                try store.prune(now: receivedAt)
            } catch {
                Self.logger.error("Diagnoseberichte konnten nicht aufgeräumt werden: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func makeReadable(_ data: Data) -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let formatted = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              )
        else { return data }
        return formatted
    }
}
