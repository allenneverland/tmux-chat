import Foundation
import Observation
import SwiftUI

enum ShortcutCatalogCategory: String, CaseIterable, Codable, Identifiable {
    case navigation
    case control
    case editing
    case symbols
    case numbers
    case letters
    case function

    var id: String { rawValue }

    var title: String {
        switch self {
        case .navigation:
            return "Navigation"
        case .control:
            return "Control"
        case .editing:
            return "Editing"
        case .symbols:
            return "Symbols"
        case .numbers:
            return "Numbers"
        case .letters:
            return "Letters"
        case .function:
            return "Function"
        }
    }
}

struct ShortcutCatalogKey: Identifiable, Codable, Hashable {
    let id: String
    let label: String
    let tmuxToken: String
    let category: ShortcutCatalogCategory
}

enum ShortcutCatalog {
    static let navigation: [ShortcutCatalogKey] = [
        .init(id: "up", label: "Up", tmuxToken: "Up", category: .navigation),
        .init(id: "down", label: "Down", tmuxToken: "Down", category: .navigation),
        .init(id: "left", label: "Left", tmuxToken: "Left", category: .navigation),
        .init(id: "right", label: "Right", tmuxToken: "Right", category: .navigation),
        .init(id: "home", label: "Home", tmuxToken: "Home", category: .navigation),
        .init(id: "end", label: "End", tmuxToken: "End", category: .navigation),
        .init(id: "page_up", label: "PageUp", tmuxToken: "PageUp", category: .navigation),
        .init(id: "page_down", label: "PageDn", tmuxToken: "PageDown", category: .navigation)
    ]

    static let control: [ShortcutCatalogKey] = [
        .init(id: "escape", label: "Esc", tmuxToken: "Escape", category: .control),
        .init(id: "tab", label: "Tab", tmuxToken: "Tab", category: .control),
        .init(id: "enter", label: "Enter", tmuxToken: "Enter", category: .control),
        .init(id: "backspace", label: "Backspace", tmuxToken: "BSpace", category: .control),
        .init(id: "delete", label: "Delete", tmuxToken: "DC", category: .control),
        .init(id: "insert", label: "Insert", tmuxToken: "IC", category: .control),
        .init(id: "space", label: "Space", tmuxToken: "Space", category: .control)
    ]

    static let editing: [ShortcutCatalogKey] = [
        .init(id: "ctrl_a_letter", label: "a", tmuxToken: "a", category: .editing),
        .init(id: "ctrl_c_letter", label: "c", tmuxToken: "c", category: .editing),
        .init(id: "ctrl_d_letter", label: "d", tmuxToken: "d", category: .editing),
        .init(id: "ctrl_z_letter", label: "z", tmuxToken: "z", category: .editing)
    ]

    static let symbols: [ShortcutCatalogKey] = [
        .init(id: "symbol_dot", label: ".", tmuxToken: ".", category: .symbols),
        .init(id: "symbol_comma", label: ",", tmuxToken: ",", category: .symbols),
        .init(id: "symbol_slash", label: "/", tmuxToken: "/", category: .symbols),
        .init(id: "symbol_backslash", label: "\\", tmuxToken: "\\", category: .symbols),
        .init(id: "symbol_semicolon", label: ";", tmuxToken: ";", category: .symbols),
        .init(id: "symbol_quote", label: "'", tmuxToken: "'", category: .symbols),
        .init(id: "symbol_minus", label: "-", tmuxToken: "-", category: .symbols),
        .init(id: "symbol_equal", label: "=", tmuxToken: "=", category: .symbols),
        .init(id: "symbol_left_bracket", label: "[", tmuxToken: "[", category: .symbols),
        .init(id: "symbol_right_bracket", label: "]", tmuxToken: "]", category: .symbols),
        .init(id: "symbol_backtick", label: "`", tmuxToken: "`", category: .symbols)
    ]

    static let numbers: [ShortcutCatalogKey] = (0...9).map { number in
        ShortcutCatalogKey(
            id: "number_\(number)",
            label: "\(number)",
            tmuxToken: "\(number)",
            category: .numbers
        )
    }

    static let letters: [ShortcutCatalogKey] = (0..<26).map { offset in
        let scalar = UnicodeScalar(97 + offset)!
        let letter = String(Character(scalar))
        return ShortcutCatalogKey(
            id: "letter_\(letter)",
            label: letter.uppercased(),
            tmuxToken: letter,
            category: .letters
        )
    }

    static let function: [ShortcutCatalogKey] = (1...12).map { number in
        ShortcutCatalogKey(
            id: "function_f\(number)",
            label: "F\(number)",
            tmuxToken: "F\(number)",
            category: .function
        )
    }

    static let all: [ShortcutCatalogKey] =
        navigation + control + editing + symbols + numbers + letters + function

    static let byID: [String: ShortcutCatalogKey] = {
        Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    }()

    static func keys(for category: ShortcutCatalogCategory) -> [ShortcutCatalogKey] {
        all.filter { $0.category == category }
    }
}

struct ShortcutItem: Identifiable, Codable, Hashable {
    var id: UUID
    var keyID: String

    init(id: UUID = UUID(), keyID: String) {
        self.id = id
        self.keyID = keyID
    }
}

struct ShortcutGroup: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var items: [ShortcutItem]

    init(id: UUID = UUID(), name: String, items: [ShortcutItem]) {
        self.id = id
        self.name = name
        self.items = items
    }
}

struct ShortcutLayout: Codable, Hashable {
    var groups: [ShortcutGroup]
    var selectedGroupID: UUID?
}

enum ShortcutModifier: String, CaseIterable, Codable, Hashable, Identifiable {
    case control
    case alt
    case command
    case shift

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .control:
            return "Ctrl"
        case .alt:
            return "Alt"
        case .command:
            return "Cmd"
        case .shift:
            return "Shift"
        }
    }
}

enum ShortcutModifierState: Int, Codable, Hashable {
    case off
    case oneShot
    case locked

    mutating func cycle() {
        switch self {
        case .off:
            self = .oneShot
        case .oneShot:
            self = .locked
        case .locked:
            self = .off
        }
    }

    var isActive: Bool {
        self != .off
    }
}

struct ShortcutModifierSelection: Codable, Hashable {
    private(set) var states: [ShortcutModifier: ShortcutModifierState] = {
        Dictionary(uniqueKeysWithValues: ShortcutModifier.allCases.map { ($0, .off) })
    }()

    func state(for modifier: ShortcutModifier) -> ShortcutModifierState {
        states[modifier] ?? .off
    }

    mutating func cycle(_ modifier: ShortcutModifier) {
        var value = states[modifier] ?? .off
        value.cycle()
        states[modifier] = value
    }

    mutating func clearOneShotStates() {
        for modifier in ShortcutModifier.allCases {
            if states[modifier] == .oneShot {
                states[modifier] = .off
            }
        }
    }

    var activeModifiers: Set<ShortcutModifier> {
        Set(
            states
                .filter { $0.value.isActive }
                .map { $0.key }
        )
    }
}

enum TmuxShortcutTokenBuilder {
    static func token(baseToken: String, modifiers: Set<ShortcutModifier>) -> String {
        var prefixes: [String] = []
        if modifiers.contains(.control) {
            prefixes.append("C")
        }
        if modifiers.contains(.alt) || modifiers.contains(.command) {
            prefixes.append("M")
        }
        if modifiers.contains(.shift) {
            prefixes.append("S")
        }

        guard !prefixes.isEmpty else {
            return baseToken
        }
        return prefixes.joined(separator: "-") + "-" + baseToken
    }
}

@MainActor
@Observable
class ShortcutLayoutManager {
    static let shared = ShortcutLayoutManager()

    private(set) var layout: ShortcutLayout
    private let userDefaults: UserDefaults
    private let userDefaultsKey: String

    init(
        userDefaults: UserDefaults = .standard,
        userDefaultsKey: String = "shortcutLayout.v1"
    ) {
        self.userDefaults = userDefaults
        self.userDefaultsKey = userDefaultsKey
        self.layout = Self.defaultLayout()
        load()
    }

    private func load() {
        guard let data = userDefaults.data(forKey: userDefaultsKey),
              let decoded = try? JSONDecoder().decode(ShortcutLayout.self, from: data) else {
            layout = Self.defaultLayout()
            return
        }
        layout = Self.sanitize(decoded)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(layout) else { return }
        userDefaults.set(data, forKey: userDefaultsKey)
    }

    var groups: [ShortcutGroup] {
        layout.groups
    }

    var selectedGroupID: UUID? {
        layout.selectedGroupID
    }

    var selectedGroup: ShortcutGroup? {
        guard let id = layout.selectedGroupID else {
            return layout.groups.first
        }
        return layout.groups.first { $0.id == id } ?? layout.groups.first
    }

    var selectedGroupKeys: [ShortcutCatalogKey] {
        guard let selectedGroup else { return [] }
        return selectedGroup.items.compactMap { ShortcutCatalog.byID[$0.keyID] }
    }

    func key(for item: ShortcutItem) -> ShortcutCatalogKey? {
        ShortcutCatalog.byID[item.keyID]
    }

    func selectGroup(_ id: UUID) {
        guard layout.groups.contains(where: { $0.id == id }) else { return }
        layout.selectedGroupID = id
        save()
    }

    func addGroup(named rawName: String?) {
        let trimmed = rawName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let candidate = trimmed.isEmpty ? "Group" : trimmed
        let uniqueName = makeUniqueGroupName(candidate)
        let newGroup = ShortcutGroup(name: uniqueName, items: [])
        layout.groups.append(newGroup)
        layout.selectedGroupID = newGroup.id
        save()
    }

    func renameGroup(id: UUID, to rawName: String) {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = layout.groups.firstIndex(where: { $0.id == id }) else {
            return
        }
        layout.groups[index].name = trimmed
        save()
    }

    func deleteGroups(at offsets: IndexSet) {
        guard offsets.count < layout.groups.count else { return }
        layout.groups.remove(atOffsets: offsets)
        normalizeSelection()
        save()
    }

    func deleteGroup(_ id: UUID) {
        guard layout.groups.count > 1 else { return }
        layout.groups.removeAll { $0.id == id }
        normalizeSelection()
        save()
    }

    func moveGroups(from source: IndexSet, to destination: Int) {
        layout.groups.move(fromOffsets: source, toOffset: destination)
        normalizeSelection()
        save()
    }

    func addKey(_ keyID: String, to groupID: UUID, at index: Int? = nil) {
        guard ShortcutCatalog.byID[keyID] != nil,
              let groupIndex = layout.groups.firstIndex(where: { $0.id == groupID }) else {
            return
        }

        let item = ShortcutItem(keyID: keyID)
        if let index {
            let clamped = max(0, min(index, layout.groups[groupIndex].items.count))
            layout.groups[groupIndex].items.insert(item, at: clamped)
        } else {
            layout.groups[groupIndex].items.append(item)
        }
        save()
    }

    func moveItems(in groupID: UUID, from source: IndexSet, to destination: Int) {
        guard let groupIndex = layout.groups.firstIndex(where: { $0.id == groupID }) else {
            return
        }
        layout.groups[groupIndex].items.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func deleteItems(in groupID: UUID, at offsets: IndexSet) {
        guard let groupIndex = layout.groups.firstIndex(where: { $0.id == groupID }) else {
            return
        }
        layout.groups[groupIndex].items.remove(atOffsets: offsets)
        save()
    }

    func removeItem(_ itemID: UUID, from groupID: UUID) {
        guard let groupIndex = layout.groups.firstIndex(where: { $0.id == groupID }) else {
            return
        }
        layout.groups[groupIndex].items.removeAll { $0.id == itemID }
        save()
    }

    func handleDropPayload(_ payload: String, to groupID: UUID) {
        let parts = payload.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0] == "catalog" else { return }
        addKey(parts[1], to: groupID)
    }

    private static func sanitize(_ layout: ShortcutLayout) -> ShortcutLayout {
        var sanitizedGroups = layout.groups.map { group in
            var next = group
            next.items = group.items.filter { ShortcutCatalog.byID[$0.keyID] != nil }
            return next
        }
        if sanitizedGroups.isEmpty {
            return defaultLayout()
        }

        let selectedID = layout.selectedGroupID
        if let selectedID,
           sanitizedGroups.contains(where: { $0.id == selectedID }) {
            return ShortcutLayout(groups: sanitizedGroups, selectedGroupID: selectedID)
        }

        return ShortcutLayout(groups: sanitizedGroups, selectedGroupID: sanitizedGroups.first?.id)
    }

    private static func defaultLayout() -> ShortcutLayout {
        let nav = ShortcutGroup(
            name: "Nav",
            items: [
                ShortcutItem(keyID: "up"),
                ShortcutItem(keyID: "down"),
                ShortcutItem(keyID: "left"),
                ShortcutItem(keyID: "right"),
                ShortcutItem(keyID: "home"),
                ShortcutItem(keyID: "end"),
                ShortcutItem(keyID: "page_up"),
                ShortcutItem(keyID: "page_down")
            ]
        )

        let control = ShortcutGroup(
            name: "Control",
            items: [
                ShortcutItem(keyID: "escape"),
                ShortcutItem(keyID: "tab"),
                ShortcutItem(keyID: "backspace"),
                ShortcutItem(keyID: "enter"),
                ShortcutItem(keyID: "space"),
                ShortcutItem(keyID: "letter_a"),
                ShortcutItem(keyID: "letter_c"),
                ShortcutItem(keyID: "letter_d"),
                ShortcutItem(keyID: "letter_z")
            ]
        )

        return ShortcutLayout(groups: [nav, control], selectedGroupID: nav.id)
    }

    private func normalizeSelection() {
        if layout.groups.isEmpty {
            let fallback = Self.defaultLayout()
            layout = fallback
            return
        }

        if let selected = layout.selectedGroupID,
           layout.groups.contains(where: { $0.id == selected }) {
            return
        }

        layout.selectedGroupID = layout.groups.first?.id
    }

    private func makeUniqueGroupName(_ base: String) -> String {
        let existing = Set(layout.groups.map { $0.name.lowercased() })
        if !existing.contains(base.lowercased()) {
            return base
        }

        var counter = 2
        while true {
            let candidate = "\(base) \(counter)"
            if !existing.contains(candidate.lowercased()) {
                return candidate
            }
            counter += 1
        }
    }
}
