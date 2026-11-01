import SwiftUI
import AppKit

extension Binding where Value == RGBA {
    var color: Binding<Color> {
        Binding<Color>(get: { wrappedValue.swiftUI }, set: { wrappedValue = RGBA(NSColor($0)) })
    }
}

enum Fonts {
    static let families: [String] = NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }.sorted()
}

let quickColors: [UInt32] = [0xFFE680, 0xFFC2D4, 0xBDEBD5, 0xB3DCFF, 0xDCCBF5, 0xFFD3A8, 0xE9E9E9, 0xFFFFFF, 0x26262C, 0x1F3A5F, 0x3B2A20, 0x0E1A12]

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var format: (Double) -> String = { "\(Int($0))" }

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: $value, in: range, step: step)
                Text(format(value)).monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
            }
        }
    }
}

/// All the appearance controls of a note; used both on the note and in the theme editor.
struct StyleForm: View {
    @Binding var style: NoteStyle

    var body: some View {
        Section(L("Material")) {
            Picker(L("Surface"), selection: $style.material) {
                ForEach(NoteMaterial.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            if style.material.isTranslucent {
                SliderRow(title: L("Glass tint"), value: $style.glassTint, range: 0...0.8, step: 0.05) { "\(Int($0 * 100))%" }
                Text(L("The glass takes on the background color at this strength. What's behind the note stays visible."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        Section(L("Colors")) {
            HStack(spacing: 6) {
                ForEach(quickColors, id: \.self) { hex in
                    let c = RGBA(hex: hex)
                    Circle().fill(c.swiftUI)
                        .overlay(Circle().stroke(.primary.opacity(style.background == c ? 0.8 : 0.15), lineWidth: style.background == c ? 2 : 1))
                        .frame(width: 18, height: 18)
                        .onTapGesture { style.background = c; if !style.material.isTranslucent || style.glassTint > 0.3 { style.text = c.readableText } }
                        .help(L("Use this color"))
                }
            }
            ColorPicker(L("Background"), selection: $style.background.color, supportsOpacity: false)
            ColorPicker(L("Text"), selection: $style.text.color, supportsOpacity: false)
            Toggle(L("Custom bar color"), isOn: $style.useCustomHeader)
            if style.useCustomHeader {
                ColorPicker(L("Bar"), selection: $style.header.color, supportsOpacity: true)
            }
            if !style.material.isTranslucent {
                SliderRow(title: L("Opacity"), value: $style.opacity, range: 0.15...1, step: 0.05) { "\(Int($0 * 100))%" }
            }
        }
        Section(L("Text")) {
            Picker(L("Font"), selection: $style.fontName) {
                Text(L("System")).tag("")
                Divider()
                ForEach(Fonts.families, id: \.self) { Text($0).tag($0) }
            }
            SliderRow(title: L("Size"), value: $style.fontSize, range: 8...48)
            SliderRow(title: L("Line spacing"), value: $style.lineSpacing, range: 0...20)
            SliderRow(title: L("Margins"), value: $style.padding, range: 0...40)
        }
        Section(L("Shape")) {
            SliderRow(title: L("Corners"), value: $style.cornerRadius, range: 0...30)
            SliderRow(title: L("Border"), value: $style.borderWidth, range: 0...6, step: 0.5) { String(format: "%.1f", $0) }
            if style.borderWidth > 0 {
                ColorPicker(L("Border color"), selection: $style.border.color, supportsOpacity: true)
            }
            SliderRow(title: L("Bar height"), value: $style.headerHeight, range: 6...40)
            Toggle(L("Shadow"), isOn: $style.shadow)
            Toggle(L("Buttons only on hover"), isOn: $style.buttonsOnHover)
        }
    }
}

/// Static preview of a style.
struct NotePreview: View {
    let style: NoteStyle
    var text = L("Shopping list\n☐ Bread\n☑ Milk")

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(style.headerColor.swiftUI.opacity(style.opacity)).frame(height: style.headerHeight * 0.7)
            Text(text)
                .font(Font(style.font(size: style.fontSize) as CTFont))
                .lineSpacing(style.lineSpacing)
                .foregroundStyle(style.text.swiftUI)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(style.padding * 0.7)
        }
        .background(previewBackground)
        .clipShape(RoundedRectangle(cornerRadius: style.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: style.cornerRadius).stroke(style.border.swiftUI, lineWidth: style.borderWidth))
        .shadow(color: .black.opacity(style.shadow ? 0.25 : 0), radius: 6, y: 3)
    }
}

extension NotePreview {
    @ViewBuilder var previewBackground: some View {
        if style.material.isTranslucent {
            ZStack {
                // colorful backdrop to show off the glass transparency
                LinearGradient(colors: [.pink, .orange, .teal, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
                Rectangle().fill(style.material == .clearGlass ? .ultraThinMaterial : .regularMaterial)
                style.background.swiftUI.opacity(style.glassTint)
            }
        } else {
            style.background.swiftUI.opacity(style.opacity)
        }
    }
}

/// "Customize" popover of a single note.
struct NoteStyleEditor: View {
    let noteID: UUID
    @EnvironmentObject var store: NoteStore
    @Local private var newThemeName = ""
    @Local private var savedMessage: String?

    private var style: Binding<NoteStyle> {
        Binding(get: { store.note(noteID)?.style ?? NoteStyle() },
                set: { v in store.update(noteID) { $0.style = v } })
    }

    private func flag(_ kp: WritableKeyPath<Note, Bool>) -> Binding<Bool> {
        Binding(get: { store.note(noteID)?[keyPath: kp] ?? false },
                set: { v in store.update(noteID) { $0[keyPath: kp] = v } })
    }

    var body: some View {
        Form {
            Section(L("Theme")) {
                Menu(L("Apply a theme")) {
                    ForEach(store.themes) { t in
                        Button(t.name) { style.wrappedValue = t.style }
                    }
                }
                HStack {
                    TextField(L("New theme name"), text: $newThemeName)
                    Button(L("Save as theme")) {
                        let t = store.saveTheme(named: newThemeName, style: style.wrappedValue)
                        savedMessage = L("Saved \"%@\"", t.name)
                        newThemeName = ""
                    }
                }
                if let savedMessage { Text(savedMessage).font(.caption).foregroundStyle(.secondary) }
            }
            StyleForm(style: style)
            Section(L("Window")) {
                Toggle(L("Always on top"), isOn: flag(\.floating))
                Toggle(L("On all desktops"), isOn: flag(\.allSpaces))
                Toggle(L("Collapsed to bar"), isOn: flag(\.collapsed))
                Button(L("Apply this style to all notes")) {
                    let s = style.wrappedValue
                    for n in store.notes { store.update(n.id) { $0.style = s } }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 360, height: 560)
    }
}

/// Replacement for @State: with only the Command Line Tools, SwiftUI's macro plugin is missing.
@propertyWrapper
struct Local<Value>: DynamicProperty {
    final class Box: ObservableObject {
        @Published var value: Value
        init(_ v: Value) { value = v }
    }
    @StateObject private var box: Box
    init(wrappedValue: Value) { _box = StateObject(wrappedValue: Box(wrappedValue)) }
    var wrappedValue: Value {
        get { box.value }
        nonmutating set { box.value = newValue }
    }
    var projectedValue: Binding<Value> { $box.value }
}
