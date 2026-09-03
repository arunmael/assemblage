import SwiftUI
import AssemblageModel

/// Das kontextabhängige Eigenschaften-Panel rechts im Dokumentfenster.
struct InspectorView: View {

    @ObservedObject var state: DocumentState

    private var editing: InspectorEditing {
        InspectorEditing(state: state)
    }

    var body: some View {
        Form {
            if let layer = state.selectedLayer {
                layerSections(layer)
            } else {
                documentSection
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Ohne Auswahl: das Dokument

    private var documentSection: some View {
        Section("Dokument") {
            LabeledContent("Leinwand", value: formatted(state.document.canvas))
            LabeledContent("Ebenen", value: "\(state.document.layers.count)")
        }
    }

    // MARK: - Gemeinsame Ebeneneigenschaften

    @ViewBuilder
    private func layerSections(_ layer: Layer) -> some View {
        Section("Ebene") {
            textField(
                "Name",
                value: layerBinding(fallback: layer.name, actionName: "Ebene umbenennen", get: { $0.name }) {
                    $0.name = $1
                },
                actionName: "Ebene umbenennen"
            )

            valueSlider(
                "Deckkraft",
                value: layerBinding(fallback: layer.opacity, actionName: "Deckkraft ändern", get: { $0.opacity }) {
                    $0.opacity = $1
                },
                range: 0...1,
                actionName: "Deckkraft ändern",
                valueText: { "\(Int(($0 * 100).rounded())) %" }
            )

            Picker("Modus", selection: layerBinding(
                fallback: layer.blendMode.rawValue,
                actionName: "Blend-Modus ändern",
                get: { $0.blendMode.rawValue }
            ) { layer, rawValue in
                guard let mode = BlendMode(rawValue: rawValue) else { return }
                layer.blendMode = mode
            }) {
                ForEach(BlendMode.allCases, id: \.rawValue) { mode in
                    Text(mode.localizedName).tag(mode.rawValue)
                }
            }
        }

        transformSection(layer)

        switch layer.content {
        case .image(let image):
            imageSection(image)
        case .text(let text):
            textSection(text)
        case .shape(let shape):
            shapeSection(shape)
        }

        if let mask = layer.mask {
            maskSection(mask)
        }
    }

    private func transformSection(_ layer: Layer) -> some View {
        Section("Position und Transformation") {
            numberField("Position X", fallback: layer.transform.x, actionName: "Position ändern", get: {
                $0.transform.x
            }) {
                $0.transform.x = $1
            }
            numberField("Position Y", fallback: layer.transform.y, actionName: "Position ändern", get: {
                $0.transform.y
            }) {
                $0.transform.y = $1
            }
            numberField("Skalierung X (%)", fallback: layer.transform.scaleX * 100, actionName: "Skalierung ändern", get: {
                $0.transform.scaleX * 100
            }) {
                $0.transform.scaleX = $1 / 100
            }
            numberField("Skalierung Y (%)", fallback: layer.transform.scaleY * 100, actionName: "Skalierung ändern", get: {
                $0.transform.scaleY * 100
            }) {
                $0.transform.scaleY = $1 / 100
            }
            numberField("Drehung (°)", fallback: layer.transform.rotationDegrees, actionName: "Drehung ändern", get: {
                $0.transform.rotationDegrees
            }) {
                $0.transform.rotationDegrees = $1
            }
        }
    }

    // MARK: - Bildebene

    private func imageSection(_ content: ImageLayerContent) -> some View {
        Section("Bild") {
            LabeledContent("Datei", value: (content.originalFileReference as NSString).lastPathComponent)
            if let crop = content.cropRect {
                LabeledContent("Zuschnitt", value: format(crop.width, crop.height))
            }

            adjustmentSlider("Helligkeit", fallback: content.adjustments.brightness, range: -1...1, keyPath: \.brightness)
            adjustmentSlider("Kontrast", fallback: content.adjustments.contrast, range: -1...1, keyPath: \.contrast)
            adjustmentSlider("Sättigung", fallback: content.adjustments.saturation, range: -1...1, keyPath: \.saturation)
            adjustmentSlider("Wärme", fallback: content.adjustments.warmth, range: -1...1, keyPath: \.warmth)
            adjustmentSlider("Weichzeichnen", fallback: content.adjustments.blurRadius, range: 0...1, keyPath: \.blurRadius)
            adjustmentSlider("Schärfen", fallback: content.adjustments.sharpenAmount, range: 0...1, keyPath: \.sharpenAmount)

            Button("Zurücksetzen") {
                editing.resetAdjustments()
            }
            .disabled(content.adjustments == .neutral)
        }
    }

    private func adjustmentSlider(
        _ title: String,
        fallback: Double,
        range: ClosedRange<Double>,
        keyPath: WritableKeyPath<ImageAdjustments, Double>
    ) -> some View {
        let actionName = "\(title) ändern"
        let binding = Binding<Double>(
            get: {
                guard case .image(let content) = state.selectedLayer?.content else { return fallback }
                return content.adjustments[keyPath: keyPath]
            },
            set: { newValue in
                editing.updateSelectedLayer(actionName: actionName) { layer in
                    guard case .image(var content) = layer.content else { return }
                    content.adjustments[keyPath: keyPath] = newValue
                    layer.content = .image(content)
                }
            }
        )
        return valueSlider(
            title,
            value: binding,
            range: range,
            actionName: actionName,
            valueText: { String(format: "%.2f", $0) }
        )
    }

    // MARK: - Textebene

    private func textSection(_ content: TextLayerContent) -> some View {
        Section("Text") {
            textField(
                "Inhalt",
                value: textContentBinding(fallback: content.string, actionName: "Text ändern", get: { $0.string }) {
                    $0.string = $1
                },
                actionName: "Text ändern"
            )
            numberField("Schriftgrösse", fallback: content.fontSize, actionName: "Schriftgrösse ändern", get: { layer in
                guard case .text(let text) = layer.content else { return content.fontSize }
                return text.fontSize
            }) { layer, value in
                guard case .text(var text) = layer.content else { return }
                text.fontSize = max(1, value)
                layer.content = .text(text)
            }
            colorPicker("Farbe", fallback: content.colorHex, actionName: "Textfarbe ändern") { layer, hex in
                guard case .text(var text) = layer.content else { return }
                text.colorHex = hex
                layer.content = .text(text)
            }
            Picker("Ausrichtung", selection: textContentBinding(
                fallback: content.alignment.rawValue,
                actionName: "Textausrichtung ändern",
                get: { $0.alignment.rawValue }
            ) { text, rawValue in
                guard let alignment = TextAlignment(rawValue: rawValue) else { return }
                text.alignment = alignment
            }) {
                Text("Links").tag(TextAlignment.left.rawValue)
                Text("Zentriert").tag(TextAlignment.center.rawValue)
                Text("Rechts").tag(TextAlignment.right.rawValue)
            }
        }
    }

    // MARK: - Formebene

    private func shapeSection(_ content: ShapeLayerContent) -> some View {
        Section("Form") {
            numberField("Breite", fallback: content.size.width, actionName: "Formgrösse ändern", get: { layer in
                guard case .shape(let shape) = layer.content else { return content.size.width }
                return shape.size.width
            }) { layer, value in
                guard case .shape(var shape) = layer.content else { return }
                shape.size.width = max(0, value)
                layer.content = .shape(shape)
            }
            numberField("Höhe", fallback: content.size.height, actionName: "Formgrösse ändern", get: { layer in
                guard case .shape(let shape) = layer.content else { return content.size.height }
                return shape.size.height
            }) { layer, value in
                guard case .shape(var shape) = layer.content else { return }
                shape.size.height = max(0, value)
                layer.content = .shape(shape)
            }
            if content.kind == .roundedRectangle {
                numberField("Eckenradius", fallback: content.cornerRadius, actionName: "Eckenradius ändern", get: { layer in
                    guard case .shape(let shape) = layer.content else { return content.cornerRadius }
                    return shape.cornerRadius
                }) { layer, value in
                    guard case .shape(var shape) = layer.content else { return }
                    shape.cornerRadius = max(0, value)
                    layer.content = .shape(shape)
                }
            }
            colorPicker("Farbe", fallback: content.fillColorHex, actionName: "Formfarbe ändern") { layer, hex in
                guard case .shape(var shape) = layer.content else { return }
                shape.fillColorHex = hex
                layer.content = .shape(shape)
            }
        }
    }

    private func maskSection(_ mask: LayerMask) -> some View {
        Section("Maske") {
            LabeledContent("Herkunft", value: mask.source == .manualBrush ? "Pinsel" : "Automatisch")
            LabeledContent("Umgekehrt", value: mask.isInverted ? "Ja" : "Nein")
            LabeledContent("Aktiv", value: mask.isEnabled ? "Ja" : "Nein")
        }
    }

    // MARK: - Eingabeelemente

    private func valueSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        actionName: String,
        valueText: @escaping (Double) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(valueText(value.wrappedValue))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range, onEditingChanged: editingChanged(actionName: actionName))
                .controlSize(.large)
                .frame(minHeight: 36)
        }
        .padding(.vertical, 3)
    }

    private func textField(_ title: String, value: Binding<String>, actionName: String) -> some View {
        TextField(title, text: value, onEditingChanged: editingChanged(actionName: actionName))
            .textFieldStyle(.roundedBorder)
            .controlSize(.large)
    }

    private func numberField(
        _ title: String,
        fallback: Double,
        actionName: String,
        get: @escaping (Layer) -> Double,
        update: @escaping (inout Layer, Double) -> Void
    ) -> some View {
        let binding = Binding<String>(
            get: { number(state.selectedLayer.map(get) ?? fallback) },
            set: { text in
                guard let value = InspectorEditing.number(from: text) else { return }
                editing.updateSelectedLayer(actionName: actionName) { update(&$0, value) }
            }
        )
        return LabeledContent(title) {
            TextField("", text: binding, onEditingChanged: editingChanged(actionName: actionName))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(minWidth: 72)
        }
    }

    private func colorPicker(
        _ title: String,
        fallback: String,
        actionName: String,
        update: @escaping (inout Layer, String) -> Void
    ) -> some View {
        let binding = Binding<Color>(
            get: { color(from: colorHex(in: state.selectedLayer) ?? fallback) },
            set: { color in
                guard let hex = hex(from: color) else { return }
                editing.updateSelectedLayer(actionName: actionName) { update(&$0, hex) }
            }
        )
        return ColorPicker(title, selection: binding, supportsOpacity: true)
            .controlSize(.large)
            .frame(minHeight: 36)
    }

    private func layerBinding<Value>(
        fallback: Value,
        actionName: String,
        get: @escaping (Layer) -> Value,
        update: @escaping (inout Layer, Value) -> Void
    ) -> Binding<Value> {
        Binding(
            get: { state.selectedLayer.map(get) ?? fallback },
            set: { value in
                editing.updateSelectedLayer(actionName: actionName) { update(&$0, value) }
            }
        )
    }

    private func textContentBinding<Value>(
        fallback: Value,
        actionName: String,
        get: @escaping (TextLayerContent) -> Value,
        update: @escaping (inout TextLayerContent, Value) -> Void
    ) -> Binding<Value> {
        Binding(
            get: {
                guard case .text(let content) = state.selectedLayer?.content else { return fallback }
                return get(content)
            },
            set: { value in
                editing.updateSelectedLayer(actionName: actionName) { layer in
                    guard case .text(var content) = layer.content else { return }
                    update(&content, value)
                    layer.content = .text(content)
                }
            }
        )
    }

    private func editingChanged(actionName: String) -> (Bool) -> Void {
        { isEditing in
            if isEditing {
                editing.beginEditing()
            } else {
                editing.endEditing(actionName: actionName)
            }
        }
    }

    // MARK: - Farben und Zahlenformat

    private func colorHex(in layer: Layer?) -> String? {
        guard let layer else { return nil }
        switch layer.content {
        case .text(let content): return content.colorHex
        case .shape(let content): return content.fillColorHex
        case .image: return nil
        }
    }

    private func color(from hex: String) -> Color {
        let rgba = RGBA(hex: hex) ?? .black
        return Color(.sRGB, red: rgba.red, green: rgba.green, blue: rgba.blue, opacity: rgba.alpha)
    }

    private func hex(from color: Color) -> String? {
        guard let converted = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        return RGBA(
            red: Double(converted.redComponent),
            green: Double(converted.greenComponent),
            blue: Double(converted.blueComponent),
            alpha: Double(converted.alphaComponent)
        ).hexString
    }

    private func number(_ value: Double) -> String {
        value.rounded() == value ? String(format: "%.0f", value) : String(format: "%.2f", value)
    }

    private func formatted(_ size: Size) -> String {
        format(size.width, size.height)
    }

    private func format(_ a: Double, _ b: Double) -> String {
        "\(number(a)) × \(number(b))"
    }
}
