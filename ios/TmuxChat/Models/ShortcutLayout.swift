import Foundation
import Observation
import SwiftUI

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
    let defaultModifiers: Set<ShortcutModifier>

    init(
        id: String,
        label: String,
        tmuxToken: String,
        category: ShortcutCatalogCategory,
        defaultModifiers: Set<ShortcutModifier> = []
    ) {
        self.id = id
        self.label = label
        self.tmuxToken = tmuxToken
        self.category = category
        self.defaultModifiers = defaultModifiers
    }
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
        .init(id: "ctrl_a_letter", label: "A", tmuxToken: "a", category: .editing, defaultModifiers: [.control]),
        .init(id: "ctrl_c_letter", label: "C", tmuxToken: "c", category: .editing, defaultModifiers: [.control]),
        .init(id: "ctrl_d_letter", label: "D", tmuxToken: "d", category: .editing, defaultModifiers: [.control]),
        .init(id: "ctrl_z_letter", label: "Z", tmuxToken: "z", category: .editing, defaultModifiers: [.control])
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

    static let iosMissingKeyIDs: [String] = [
        "escape", "tab", "enter", "backspace", "delete", "insert",
        "up", "down", "left", "right", "home", "end", "page_up", "page_down"
    ] + (1...12).map { "function_f\($0)" }

    static let iosMissingKeys: [ShortcutCatalogKey] =
        iosMissingKeyIDs.compactMap { byID[$0] }

    static func keys(for category: ShortcutCatalogCategory) -> [ShortcutCatalogKey] {
        all.filter { $0.category == category }
    }
}

struct ShortcutBaseKey: Hashable {
    let label: String
    let token: String
}

struct ShortcutItem: Identifiable, Codable, Hashable {
    var id: UUID
    var baseLabel: String
    var baseToken: String
    var modifiers: Set<ShortcutModifier>

    init(
        id: UUID = UUID(),
        baseLabel: String,
        baseToken: String,
        modifiers: Set<ShortcutModifier> = []
    ) {
        self.id = id
        self.baseLabel = baseLabel
        self.baseToken = baseToken
        self.modifiers = modifiers
    }

    var token: String {
        TmuxShortcutTokenBuilder.token(baseToken: baseToken, modifiers: modifiers)
    }

    var displayLabel: String {
        TmuxShortcutTokenBuilder.displayLabel(baseLabel: baseLabel, modifiers: modifiers)
    }

    static func fromCatalog(id: String, extraModifiers: Set<ShortcutModifier> = []) -> ShortcutItem? {
        guard let key = ShortcutCatalog.byID[id] else {
            return nil
        }
        return ShortcutItem(
            baseLabel: key.label,
            baseToken: key.tmuxToken,
            modifiers: key.defaultModifiers.union(extraModifiers)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case baseLabel
        case baseToken
        case modifiers
        case keyID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let itemID = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()

        if let baseLabel = try container.decodeIfPresent(String.self, forKey: .baseLabel),
           let baseToken = try container.decodeIfPresent(String.self, forKey: .baseToken) {
            let modifiers = try container.decodeIfPresent(Set<ShortcutModifier>.self, forKey: .modifiers) ?? []
            self.init(id: itemID, baseLabel: baseLabel, baseToken: baseToken, modifiers: modifiers)
            return
        }

        if let legacyKeyID = try container.decodeIfPresent(String.self, forKey: .keyID),
           let legacy = ShortcutCatalog.byID[legacyKeyID] {
            self.init(
                id: itemID,
                baseLabel: legacy.label,
                baseToken: legacy.tmuxToken,
                modifiers: legacy.defaultModifiers
            )
            return
        }

        throw DecodingError.dataCorruptedError(
            forKey: .baseToken,
            in: container,
            debugDescription: "Shortcut item is missing key data"
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(baseLabel, forKey: .baseLabel)
        try container.encode(baseToken, forKey: .baseToken)
        try container.encode(modifiers, forKey: .modifiers)
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

    static func displayLabel(baseLabel: String, modifiers: Set<ShortcutModifier>) -> String {
        let ordered = ShortcutModifier.allCases
            .filter { modifiers.contains($0) }
            .map(\.displayName)

        guard !ordered.isEmpty else {
            return baseLabel
        }
        return ordered.joined(separator: "+") + "+" + baseLabel
    }

    static func keyboardBaseKey(from raw: String) -> ShortcutBaseKey? {
        guard raw.count == 1,
              raw.unicodeScalars.count == 1,
              let scalar = raw.unicodeScalars.first,
              scalar.isASCII else {
            return nil
        }

        if scalar.value == 32 {
            return ShortcutBaseKey(label: "Space", token: "Space")
        }

        let isASCIIControl = scalar.value < 32 || scalar.value == 127
        guard !scalar.properties.isWhitespace, !isASCIIControl else {
            return nil
        }

        if (65...90).contains(scalar.value) || (97...122).contains(scalar.value) {
            let letter = String(Character(scalar)).lowercased()
            return ShortcutBaseKey(label: letter.uppercased(), token: letter)
        }

        let symbol = String(Character(scalar))
        return ShortcutBaseKey(label: symbol, token: symbol)
    }

    static func isValidKeyToken(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 64, trimmed == token else {
            return false
        }
        return trimmed.unicodeScalars.allSatisfy { scalar in
            let isASCIIControl = scalar.value < 32 || scalar.value == 127
            return scalar.isASCII && !isASCIIControl && !scalar.properties.isWhitespace
        }
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

    var selectedGroupItems: [ShortcutItem] {
        selectedGroup?.items ?? []
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

    @discardableResult
    func addShortcut(
        baseLabel: String,
        baseToken: String,
        modifiers: Set<ShortcutModifier>,
        to groupID: UUID,
        at index: Int? = nil
    ) -> Bool {
        let cleanLabel = baseLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanLabel.isEmpty,
              let groupIndex = layout.groups.firstIndex(where: { $0.id == groupID }) else {
            return false
        }

        let item = ShortcutItem(baseLabel: cleanLabel, baseToken: baseToken, modifiers: modifiers)
        guard TmuxShortcutTokenBuilder.isValidKeyToken(item.token) else {
            return false
        }

        if let index {
            let clamped = max(0, min(index, layout.groups[groupIndex].items.count))
            layout.groups[groupIndex].items.insert(item, at: clamped)
        } else {
            layout.groups[groupIndex].items.append(item)
        }
        save()
        return true
    }

    @discardableResult
    func addCatalogKey(
        _ key: ShortcutCatalogKey,
        modifiers: Set<ShortcutModifier>,
        to groupID: UUID,
        at index: Int? = nil
    ) -> Bool {
        addShortcut(
            baseLabel: key.label,
            baseToken: key.tmuxToken,
            modifiers: key.defaultModifiers.union(modifiers),
            to: groupID,
            at: index
        )
    }

    func moveItem(in groupID: UUID, itemID: UUID, before targetID: UUID?) {
        guard let groupIndex = layout.groups.firstIndex(where: { $0.id == groupID }) else {
            return
        }
        guard itemID != targetID else {
            return
        }

        var items = layout.groups[groupIndex].items
        guard let sourceIndex = items.firstIndex(where: { $0.id == itemID }) else {
            return
        }

        let moved = items.remove(at: sourceIndex)

        let destinationIndex: Int
        if let targetID,
           let targetIndex = items.firstIndex(where: { $0.id == targetID }) {
            destinationIndex = targetIndex
        } else {
            destinationIndex = items.count
        }

        items.insert(moved, at: destinationIndex)
        layout.groups[groupIndex].items = items
        save()
    }

    func moveItem(in groupID: UUID, itemID: UUID, to destinationIndex: Int) {
        guard let groupIndex = layout.groups.firstIndex(where: { $0.id == groupID }) else {
            return
        }

        var items = layout.groups[groupIndex].items
        guard !items.isEmpty,
              let sourceIndex = items.firstIndex(where: { $0.id == itemID }) else {
            return
        }

        let clampedDestination = max(0, min(destinationIndex, items.count - 1))
        guard sourceIndex != clampedDestination else {
            return
        }

        let moved = items.remove(at: sourceIndex)
        items.insert(moved, at: clampedDestination)
        layout.groups[groupIndex].items = items
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

    private static func sanitize(_ layout: ShortcutLayout) -> ShortcutLayout {
        let sanitizedGroups = layout.groups.map { group in
            var next = group
            next.items = group.items.filter { item in
                TmuxShortcutTokenBuilder.isValidKeyToken(item.token) &&
                    !item.baseLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
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
                ShortcutItem.fromCatalog(id: "up")!,
                ShortcutItem.fromCatalog(id: "down")!,
                ShortcutItem.fromCatalog(id: "left")!,
                ShortcutItem.fromCatalog(id: "right")!,
                ShortcutItem.fromCatalog(id: "home")!,
                ShortcutItem.fromCatalog(id: "end")!,
                ShortcutItem.fromCatalog(id: "page_up")!,
                ShortcutItem.fromCatalog(id: "page_down")!
            ]
        )

        let control = ShortcutGroup(
            name: "Control",
            items: [
                ShortcutItem.fromCatalog(id: "escape")!,
                ShortcutItem.fromCatalog(id: "tab")!,
                ShortcutItem.fromCatalog(id: "backspace")!,
                ShortcutItem.fromCatalog(id: "enter")!,
                ShortcutItem.fromCatalog(id: "letter_a", extraModifiers: [.control])!,
                ShortcutItem.fromCatalog(id: "letter_c", extraModifiers: [.control])!,
                ShortcutItem.fromCatalog(id: "letter_d", extraModifiers: [.control])!,
                ShortcutItem.fromCatalog(id: "letter_z", extraModifiers: [.control])!
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
