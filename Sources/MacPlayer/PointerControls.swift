import SwiftUI

// Everything that can be clicked shows the pointing hand (the maintainer's request, 0.8.3).
//
// These types have the same names as SwiftUI's and are found first inside this module, so every `Button`, `Toggle`, `Picker`, `Menu` and
// `ColorPicker` of the app gets the hand without touching each place. They only wrap SwiftUI's own control: its look, its style
// (`.buttonStyle`, `.pickerStyle`…), keyboard shortcuts and accessibility stay SwiftUI's. Something clickable that is not one of these
// (a card with a tap gesture) uses `.clickable()`.

extension View {
    /// The pointing hand over this view: it can be clicked.
    func clickable() -> some View { pointerStyle(.link) }
}

struct Button<Label: View>: View {
    private let base: SwiftUI.Button<Label>
    init(action: @escaping () -> Void, @ViewBuilder label: () -> Label) { base = SwiftUI.Button(action: action, label: label) }
    init(role: ButtonRole?, action: @escaping () -> Void, @ViewBuilder label: () -> Label) { base = SwiftUI.Button(role: role, action: action, label: label) }
    var body: some View { base.pointerStyle(.link) }
}

extension Button where Label == Text {
    init<S: StringProtocol>(_ title: S, action: @escaping () -> Void) { base = SwiftUI.Button(title, action: action) }
    init<S: StringProtocol>(_ title: S, role: ButtonRole?, action: @escaping () -> Void) { base = SwiftUI.Button(title, role: role, action: action) }
}

struct Toggle<Label: View>: View {
    private let base: SwiftUI.Toggle<Label>
    init(isOn: Binding<Bool>, @ViewBuilder label: () -> Label) { base = SwiftUI.Toggle(isOn: isOn, label: label) }
    var body: some View { base.pointerStyle(.link) }
}

extension Toggle where Label == Text {
    init<S: StringProtocol>(_ title: S, isOn: Binding<Bool>) { base = SwiftUI.Toggle(title, isOn: isOn) }
}

struct Picker<Label: View, SelectionValue: Hashable, Content: View>: View {
    private let base: SwiftUI.Picker<Label, SelectionValue, Content>
    init(selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {
        base = SwiftUI.Picker(selection: selection, content: content, label: label)
    }
    var body: some View { base.pointerStyle(.link) }
}

extension Picker where Label == Text {
    init<S: StringProtocol>(_ title: S, selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content) {
        base = SwiftUI.Picker(title, selection: selection, content: content)
    }
}

struct Menu<Label: View, Content: View>: View {
    private let base: SwiftUI.Menu<Label, Content>
    init(@ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) { base = SwiftUI.Menu(content: content, label: label) }
    var body: some View { base.pointerStyle(.link) }
}

extension Menu where Label == Text {
    init<S: StringProtocol>(_ title: S, @ViewBuilder content: () -> Content) { base = SwiftUI.Menu(title, content: content) }
}

struct ColorPicker<Label: View>: View {
    private let base: SwiftUI.ColorPicker<Label>
    init(selection: Binding<Color>, supportsOpacity: Bool = true, @ViewBuilder label: () -> Label) {
        base = SwiftUI.ColorPicker(selection: selection, supportsOpacity: supportsOpacity, label: label)
    }
    var body: some View { base.pointerStyle(.link) }
}

extension ColorPicker where Label == Text {
    init<S: StringProtocol>(_ title: S, selection: Binding<Color>, supportsOpacity: Bool = true) {
        base = SwiftUI.ColorPicker(title, selection: selection, supportsOpacity: supportsOpacity)
    }
}
