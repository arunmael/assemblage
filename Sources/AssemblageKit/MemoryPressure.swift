import Foundation

/// Meldet, wenn macOS knapp an Arbeitsspeicher wird.
///
/// Das System schickt diese Warnung, **bevor** es anfängt auszulagern oder
/// Programme zu beenden. Wer darauf reagiert und entbehrliche Bitmaps
/// freigibt, bleibt flüssig; wer es nicht tut, wird ausgelagert — und genau
/// das fühlt sich an wie Ruckeln bei scheinbar geringer Auslastung.
@MainActor
final class MemoryPressure {

    enum Level: Comparable {
        case normal, warning, critical
    }

    static let shared = MemoryPressure()

    static let didChangeNotification = Notification.Name("Assemblage.MemoryPressure.didChange")

    private(set) var level: Level = .normal
    private let source: DispatchSourceMemoryPressure

    private init() {
        source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let ereignis = self.source.data
                let neu: Level = if ereignis.contains(.critical) {
                    .critical
                } else if ereignis.contains(.warning) {
                    .warning
                } else {
                    .normal
                }
                self.report(neu)
            }
        }
        source.activate()
    }

    /// Auch für Tests: stellt eine Meldung des Systems nach.
    func report(_ neu: Level) {
        level = neu
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}
