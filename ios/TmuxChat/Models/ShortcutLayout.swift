import Foundation
import GameController
import Observation
import SwiftUI

enum ShortcutModifier: String, CaseIterable, Hashable, Identifiable {
    case control
    case alt
    case shift
    case meta

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .control:
            return "Ctrl"
        case .alt:
            return "Alt"
        case .shift:
            return "Shift"
        case .meta:
            return "Meta"
        }
    }
}

enum ShortcutModifierActivationState: Hashable {
    case off
    case oneShot
    case locked

    var isActive: Bool {
        switch self {
        case .off:
            return false
        case .oneShot, .locked:
            return true
        }
    }
}

struct ShortcutModifierStateMachine: Hashable {
    private var states: [ShortcutModifier: ShortcutModifierActivationState] = {
        Dictionary(uniqueKeysWithValues: ShortcutModifier.allCases.map { ($0, .off) })
    }()

    mutating func cycle(_ modifier: ShortcutModifier) {
        switch state(for: modifier) {
        case .off:
            states[modifier] = .oneShot
        case .oneShot:
            states[modifier] = .locked
        case .locked:
            states[modifier] = .off
        }
    }

    mutating func clearAll() {
        for modifier in ShortcutModifier.allCases {
            states[modifier] = .off
        }
    }

    mutating func consumeModifiers(base: Set<ShortcutModifier>) -> Set<ShortcutModifier> {
        let active = activeModifiers
        let merged = active.union(base)
        for (modifier, state) in states where state == .oneShot {
            states[modifier] = .off
        }
        return merged
    }

    func state(for modifier: ShortcutModifier) -> ShortcutModifierActivationState {
        states[modifier] ?? .off
    }

    var activeModifiers: Set<ShortcutModifier> {
        Set(states.compactMap { $0.value.isActive ? $0.key : nil })
    }

    var hasActiveModifiers: Bool {
        !activeModifiers.isEmpty
    }

    var activeModifiersLabel: String {
        ShortcutModifier.allCases
            .filter { activeModifiers.contains($0) }
            .map(\.displayName)
            .joined(separator: "+")
    }
}

struct ShortcutInputDescriptor: Hashable {
    let key: String
    let code: String
    let text: String?
    let defaultModifiers: Set<ShortcutModifier>
    let supportsRepeat: Bool

    init(
        key: String,
        code: String,
        text: String? = nil,
        defaultModifiers: Set<ShortcutModifier> = [],
        supportsRepeat: Bool = true
    ) {
        self.key = key
        self.code = code
        self.text = text
        self.defaultModifiers = defaultModifiers
        self.supportsRepeat = supportsRepeat
    }
}

enum ShortcutToolbarItemKind: Hashable {
    case modifier(ShortcutModifier)
    case key(ShortcutInputDescriptor)
}

struct ShortcutToolbarItem: Identifiable, Hashable {
    let id: String
    let label: String
    let kind: ShortcutToolbarItemKind

    static func modifier(_ modifier: ShortcutModifier, label: String? = nil) -> ShortcutToolbarItem {
        ShortcutToolbarItem(
            id: "modifier-\(modifier.rawValue)",
            label: label ?? modifier.displayName,
            kind: .modifier(modifier)
        )
    }

    static func key(
        id: String,
        label: String,
        key: String,
        code: String,
        text: String? = nil,
        defaultModifiers: Set<ShortcutModifier> = [],
        supportsRepeat: Bool = true
    ) -> ShortcutToolbarItem {
        ShortcutToolbarItem(
            id: id,
            label: label,
            kind: .key(
                ShortcutInputDescriptor(
                    key: key,
                    code: code,
                    text: text,
                    defaultModifiers: defaultModifiers,
                    supportsRepeat: supportsRepeat
                )
            )
        )
    }
}

struct ShortcutToolbarLayout: Hashable {
    let id: String
    let items: [ShortcutToolbarItem]
}

enum ShortcutToolbarDeviceClass {
    case phone
    case pad

    static var current: ShortcutToolbarDeviceClass {
        UIDevice.current.userInterfaceIdiom == .pad ? .pad : .phone
    }
}

enum ShortcutToolbarCatalog {
    static func layout(
        locale: Locale = .autoupdatingCurrent,
        deviceClass: ShortcutToolbarDeviceClass,
        isLandscape: Bool
    ) -> ShortcutToolbarLayout {
        let language = locale.language.languageCode?.identifier.lowercased() ?? locale.identifier.lowercased()
        let localizedLetters = localeLetters(for: language)

        var items: [ShortcutToolbarItem] = [
            .modifier(.control),
            .modifier(.alt),
            .modifier(.shift),
            .modifier(.meta),
            .key(id: "esc", label: "Esc", key: "Escape", code: "Escape", supportsRepeat: false),
            .key(id: "tab", label: "Tab", key: "Tab", code: "Tab", supportsRepeat: false),
            .key(id: "up", label: "↑", key: "ArrowUp", code: "ArrowUp"),
            .key(id: "down", label: "↓", key: "ArrowDown", code: "ArrowDown"),
            .key(id: "left", label: "←", key: "ArrowLeft", code: "ArrowLeft"),
            .key(id: "right", label: "→", key: "ArrowRight", code: "ArrowRight"),
            .key(id: "home", label: "Home", key: "Home", code: "Home"),
            .key(id: "end", label: "End", key: "End", code: "End"),
            .key(id: "page-up", label: "PgUp", key: "PageUp", code: "PageUp"),
            .key(id: "page-down", label: "PgDn", key: "PageDown", code: "PageDown"),
            .key(id: "enter", label: "Enter", key: "Enter", code: "Enter", supportsRepeat: false),
            .key(id: "backspace", label: "⌫", key: "Backspace", code: "Backspace"),
            .key(id: "delete", label: "Del", key: "Delete", code: "Delete"),
        ]

        items.append(contentsOf: localizedLetters)

        if deviceClass == .pad || isLandscape {
            items.append(contentsOf: [
                .key(id: "f1", label: "F1", key: "F1", code: "F1"),
                .key(id: "f2", label: "F2", key: "F2", code: "F2"),
                .key(id: "f5", label: "F5", key: "F5", code: "F5"),
                .key(id: "f10", label: "F10", key: "F10", code: "F10"),
                .key(id: "f12", label: "F12", key: "F12", code: "F12"),
                .key(id: "slash", label: "/", key: "/", code: "Slash", text: "/"),
                .key(id: "minus", label: "-", key: "-", code: "Minus", text: "-"),
                .key(id: "left-bracket", label: "[", key: "[", code: "BracketLeft", text: "["),
                .key(id: "right-bracket", label: "]", key: "]", code: "BracketRight", text: "]"),
                .key(id: "semicolon", label: ";", key: ";", code: "Semicolon", text: ";"),
            ])
        }

        return ShortcutToolbarLayout(
            id: "\(language)-\(deviceClass == .pad ? "pad" : "phone")-\(isLandscape ? "landscape" : "portrait")",
            items: items
        )
    }

    private static func localeLetters(for language: String) -> [ShortcutToolbarItem] {
        switch language {
        case "fr":
            return [
                .key(id: "fr-a", label: "A", key: "a", code: "KeyA", text: "a"),
                .key(id: "fr-z", label: "Z", key: "z", code: "KeyZ", text: "z"),
                .key(id: "fr-e", label: "E", key: "e", code: "KeyE", text: "e"),
                .key(id: "fr-r", label: "R", key: "r", code: "KeyR", text: "r"),
                .key(id: "fr-t", label: "T", key: "t", code: "KeyT", text: "t"),
                .key(id: "fr-y", label: "Y", key: "y", code: "KeyY", text: "y"),
            ]
        case "de":
            return [
                .key(id: "de-q", label: "Q", key: "q", code: "KeyQ", text: "q"),
                .key(id: "de-w", label: "W", key: "w", code: "KeyW", text: "w"),
                .key(id: "de-e", label: "E", key: "e", code: "KeyE", text: "e"),
                .key(id: "de-r", label: "R", key: "r", code: "KeyR", text: "r"),
                .key(id: "de-t", label: "T", key: "t", code: "KeyT", text: "t"),
                .key(id: "de-z", label: "Z", key: "z", code: "KeyZ", text: "z"),
            ]
        case "es":
            return [
                .key(id: "es-q", label: "Q", key: "q", code: "KeyQ", text: "q"),
                .key(id: "es-w", label: "W", key: "w", code: "KeyW", text: "w"),
                .key(id: "es-e", label: "E", key: "e", code: "KeyE", text: "e"),
                .key(id: "es-r", label: "R", key: "r", code: "KeyR", text: "r"),
                .key(id: "es-t", label: "T", key: "t", code: "KeyT", text: "t"),
                .key(id: "es-ntilde", label: "Ñ", key: ";", code: "Semicolon", text: ";"),
            ]
        case "ru":
            return [
                .key(id: "ru-yi", label: "Й", key: "q", code: "KeyQ", text: "q"),
                .key(id: "ru-tse", label: "Ц", key: "w", code: "KeyW", text: "w"),
                .key(id: "ru-u", label: "У", key: "e", code: "KeyE", text: "e"),
                .key(id: "ru-ka", label: "К", key: "r", code: "KeyR", text: "r"),
                .key(id: "ru-ie", label: "Е", key: "t", code: "KeyT", text: "t"),
                .key(id: "ru-en", label: "Н", key: "y", code: "KeyY", text: "y"),
            ]
        default:
            return [
                .key(id: "default-q", label: "Q", key: "q", code: "KeyQ", text: "q"),
                .key(id: "default-w", label: "W", key: "w", code: "KeyW", text: "w"),
                .key(id: "default-e", label: "E", key: "e", code: "KeyE", text: "e"),
                .key(id: "default-r", label: "R", key: "r", code: "KeyR", text: "r"),
                .key(id: "default-t", label: "T", key: "t", code: "KeyT", text: "t"),
                .key(id: "default-y", label: "Y", key: "y", code: "KeyY", text: "y"),
            ]
        }
    }
}

enum ShortcutInputEventFactory {
    static func makeEvent(
        for item: ShortcutToolbarItem,
        activeModifiers: Set<ShortcutModifier>,
        source: InputEventSource,
        action: InputEventAction = .press
    ) -> InputEvent? {
        guard case .key(let descriptor) = item.kind else {
            return nil
        }

        let allModifiers = activeModifiers.union(descriptor.defaultModifiers)
        return InputEvent(
            action: action,
            key: descriptor.key,
            code: descriptor.code,
            modifiers: toInputEventModifiers(allModifiers),
            text: descriptor.text,
            source: source,
            timestampMs: UInt64(Date().timeIntervalSince1970 * 1_000)
        )
    }

    private static func toInputEventModifiers(_ modifiers: Set<ShortcutModifier>) -> InputEventModifiers {
        InputEventModifiers(
            ctrl: modifiers.contains(.control),
            alt: modifiers.contains(.alt),
            shift: modifiers.contains(.shift),
            meta: modifiers.contains(.meta)
        )
    }
}

enum ShortcutLayoutMigration {
    private static let legacyKeys = ["shortcutLayout.v1"]
    private static let migrationMarkerKey = "shortcutLayout.v2.migrated"

    static func clearLegacyCustomLayout(userDefaults: UserDefaults = .standard) {
        guard !userDefaults.bool(forKey: migrationMarkerKey) else { return }
        legacyKeys.forEach { userDefaults.removeObject(forKey: $0) }
        userDefaults.set(true, forKey: migrationMarkerKey)
    }
}

@MainActor
@Observable
final class HardwareKeyboardMonitor {
    private(set) var isConnected: Bool = false
    var captureEnabled = false {
        didSet { configureKeyCapture() }
    }
    var onInputEvent: ((InputEvent) -> Void)?
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var activeModifiers: Set<ShortcutModifier> = []
    @ObservationIgnored private var pressedCodes: Set<Int> = []
    @ObservationIgnored private var capturedKeyboardID: ObjectIdentifier?

    private struct KeyDescriptor {
        let key: String
        let code: String
        let text: String?
    }

    init() {
        refreshConnectionState()
        startPolling()
    }

    deinit {
        pollingTask?.cancel()
    }

    private func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                self.refreshConnectionState()
                self.configureKeyCapture()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func refreshConnectionState() {
        isConnected = GCKeyboard.coalesced != nil
        if !isConnected {
            activeModifiers.removeAll()
            pressedCodes.removeAll()
        }
    }

    private func configureKeyCapture() {
        guard captureEnabled,
              let keyboard = GCKeyboard.coalesced,
              let keyboardInput = keyboard.keyboardInput else {
            detachKeyCapture()
            return
        }

        let keyboardID = ObjectIdentifier(keyboard)
        guard capturedKeyboardID != keyboardID else {
            return
        }

        keyboardInput.keyChangedHandler = { [weak self] _, _, keyCode, pressed in
            guard let self else { return }
            Task { @MainActor in
                self.handleKeyChange(keyCode: keyCode, pressed: pressed)
            }
        }
        capturedKeyboardID = keyboardID
    }

    private func detachKeyCapture() {
        if let keyboard = GCKeyboard.coalesced {
            keyboard.keyboardInput?.keyChangedHandler = nil
        }
        capturedKeyboardID = nil
        activeModifiers.removeAll()
        pressedCodes.removeAll()
    }

    private func handleKeyChange(keyCode: GCKeyCode, pressed: Bool) {
        if let modifier = modifier(for: keyCode) {
            if pressed {
                activeModifiers.insert(modifier)
            } else {
                activeModifiers.remove(modifier)
            }
            return
        }

        guard let descriptor = descriptor(for: keyCode) else {
            return
        }

        let codeValue = Int(keyCode.rawValue)
        if !pressed {
            pressedCodes.remove(codeValue)
            return
        }

        let action: InputEventAction = pressedCodes.contains(codeValue) ? .repeatAction : .press
        pressedCodes.insert(codeValue)
        let event = InputEvent(
            action: action,
            key: descriptor.key,
            code: descriptor.code,
            modifiers: InputEventModifiers(
                ctrl: activeModifiers.contains(.control),
                alt: activeModifiers.contains(.alt),
                shift: activeModifiers.contains(.shift),
                meta: activeModifiers.contains(.meta)
            ),
            text: descriptor.text,
            source: .hardwareKeyboard,
            timestampMs: UInt64(Date().timeIntervalSince1970 * 1_000)
        )
        onInputEvent?(event)
    }

    private func modifier(for keyCode: GCKeyCode) -> ShortcutModifier? {
        switch keyCode {
        case .leftControl, .rightControl:
            return .control
        case .leftAlt, .rightAlt:
            return .alt
        case .leftShift, .rightShift:
            return .shift
        case .leftGUI, .rightGUI:
            return .meta
        default:
            return nil
        }
    }

    private func descriptor(for keyCode: GCKeyCode) -> KeyDescriptor? {
        switch keyCode {
        case .keyA: return KeyDescriptor(key: "a", code: "KeyA", text: "a")
        case .keyB: return KeyDescriptor(key: "b", code: "KeyB", text: "b")
        case .keyC: return KeyDescriptor(key: "c", code: "KeyC", text: "c")
        case .keyD: return KeyDescriptor(key: "d", code: "KeyD", text: "d")
        case .keyE: return KeyDescriptor(key: "e", code: "KeyE", text: "e")
        case .keyF: return KeyDescriptor(key: "f", code: "KeyF", text: "f")
        case .keyG: return KeyDescriptor(key: "g", code: "KeyG", text: "g")
        case .keyH: return KeyDescriptor(key: "h", code: "KeyH", text: "h")
        case .keyI: return KeyDescriptor(key: "i", code: "KeyI", text: "i")
        case .keyJ: return KeyDescriptor(key: "j", code: "KeyJ", text: "j")
        case .keyK: return KeyDescriptor(key: "k", code: "KeyK", text: "k")
        case .keyL: return KeyDescriptor(key: "l", code: "KeyL", text: "l")
        case .keyM: return KeyDescriptor(key: "m", code: "KeyM", text: "m")
        case .keyN: return KeyDescriptor(key: "n", code: "KeyN", text: "n")
        case .keyO: return KeyDescriptor(key: "o", code: "KeyO", text: "o")
        case .keyP: return KeyDescriptor(key: "p", code: "KeyP", text: "p")
        case .keyQ: return KeyDescriptor(key: "q", code: "KeyQ", text: "q")
        case .keyR: return KeyDescriptor(key: "r", code: "KeyR", text: "r")
        case .keyS: return KeyDescriptor(key: "s", code: "KeyS", text: "s")
        case .keyT: return KeyDescriptor(key: "t", code: "KeyT", text: "t")
        case .keyU: return KeyDescriptor(key: "u", code: "KeyU", text: "u")
        case .keyV: return KeyDescriptor(key: "v", code: "KeyV", text: "v")
        case .keyW: return KeyDescriptor(key: "w", code: "KeyW", text: "w")
        case .keyX: return KeyDescriptor(key: "x", code: "KeyX", text: "x")
        case .keyY: return KeyDescriptor(key: "y", code: "KeyY", text: "y")
        case .keyZ: return KeyDescriptor(key: "z", code: "KeyZ", text: "z")
        case .one: return KeyDescriptor(key: "1", code: "Digit1", text: "1")
        case .two: return KeyDescriptor(key: "2", code: "Digit2", text: "2")
        case .three: return KeyDescriptor(key: "3", code: "Digit3", text: "3")
        case .four: return KeyDescriptor(key: "4", code: "Digit4", text: "4")
        case .five: return KeyDescriptor(key: "5", code: "Digit5", text: "5")
        case .six: return KeyDescriptor(key: "6", code: "Digit6", text: "6")
        case .seven: return KeyDescriptor(key: "7", code: "Digit7", text: "7")
        case .eight: return KeyDescriptor(key: "8", code: "Digit8", text: "8")
        case .nine: return KeyDescriptor(key: "9", code: "Digit9", text: "9")
        case .zero: return KeyDescriptor(key: "0", code: "Digit0", text: "0")
        case .hyphen: return KeyDescriptor(key: "-", code: "Minus", text: "-")
        case .equalSign: return KeyDescriptor(key: "=", code: "Equal", text: "=")
        case .openBracket: return KeyDescriptor(key: "[", code: "BracketLeft", text: "[")
        case .closeBracket: return KeyDescriptor(key: "]", code: "BracketRight", text: "]")
        case .backslash: return KeyDescriptor(key: "\\", code: "Backslash", text: "\\")
        case .semicolon: return KeyDescriptor(key: ";", code: "Semicolon", text: ";")
        case .quote: return KeyDescriptor(key: "'", code: "Quote", text: "'")
        case .graveAccentAndTilde: return KeyDescriptor(key: "`", code: "Backquote", text: "`")
        case .comma: return KeyDescriptor(key: ",", code: "Comma", text: ",")
        case .period: return KeyDescriptor(key: ".", code: "Period", text: ".")
        case .slash: return KeyDescriptor(key: "/", code: "Slash", text: "/")
        case .returnOrEnter: return KeyDescriptor(key: "Enter", code: "Enter", text: nil)
        case .escape: return KeyDescriptor(key: "Escape", code: "Escape", text: nil)
        case .deleteOrBackspace: return KeyDescriptor(key: "Backspace", code: "Backspace", text: nil)
        case .tab: return KeyDescriptor(key: "Tab", code: "Tab", text: nil)
        case .spacebar: return KeyDescriptor(key: "Space", code: "Space", text: " ")
        case .upArrow: return KeyDescriptor(key: "ArrowUp", code: "ArrowUp", text: nil)
        case .downArrow: return KeyDescriptor(key: "ArrowDown", code: "ArrowDown", text: nil)
        case .leftArrow: return KeyDescriptor(key: "ArrowLeft", code: "ArrowLeft", text: nil)
        case .rightArrow: return KeyDescriptor(key: "ArrowRight", code: "ArrowRight", text: nil)
        case .home: return KeyDescriptor(key: "Home", code: "Home", text: nil)
        case .end: return KeyDescriptor(key: "End", code: "End", text: nil)
        case .pageUp: return KeyDescriptor(key: "PageUp", code: "PageUp", text: nil)
        case .pageDown: return KeyDescriptor(key: "PageDown", code: "PageDown", text: nil)
        case .insert: return KeyDescriptor(key: "Insert", code: "Insert", text: nil)
        case .deleteForward: return KeyDescriptor(key: "Delete", code: "Delete", text: nil)
        default:
            return nil
        }
    }
}
