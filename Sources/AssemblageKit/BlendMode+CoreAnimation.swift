import QuartzCore
import AssemblageModel

extension AssemblageModel.BlendMode {
    /// Name des Core-Image-Blend-Filters für `CALayer.compositingFilter`.
    ///
    /// Damit übernimmt Core Animation das Mischen live auf der GPU (Plan 7.2)
    /// — ohne dass die Ebenenkette bei jedem Reglerzug neu gerendert werden
    /// muss. `normal` braucht keinen Filter; `nil` ist hier also kein Fehler,
    /// sondern der Normalfall.
    var compositingFilterName: String? {
        switch self {
        case .normal: return nil
        case .multiply: return "multiplyBlendMode"
        case .screen: return "screenBlendMode"
        case .overlay: return "overlayBlendMode"
        case .lighten: return "lightenBlendMode"
        case .darken: return "darkenBlendMode"
        }
    }

    /// Beschriftung für die Oberfläche (Plan 5.2 nennt die deutschen Namen).
    var localizedName: String {
        switch self {
        case .normal: return "Normal"
        case .multiply: return "Multiplizieren"
        case .screen: return "Negativ multiplizieren"
        case .overlay: return "Ineinanderkopieren"
        case .lighten: return "Aufhellen"
        case .darken: return "Abdunkeln"
        }
    }
}
