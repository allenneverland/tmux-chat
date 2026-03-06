import Foundation
import Testing
@testable import TmuxChat

@MainActor
struct ShortcutLayoutTests {
    @Test
    func tokenBuilderUsesExpectedPrefixOrder() {
        let token = TmuxShortcutTokenBuilder.token(
            baseToken: "c",
            modifiers: [.control, .alt]
        )
        #expect(token == "C-M-c")
    }

    @Test
    func tokenBuilderDeduplicatesMetaFromAltAndCommand() {
        let token = TmuxShortcutTokenBuilder.token(
            baseToken: "Left",
            modifiers: [.alt, .command]
        )
        #expect(token == "M-Left")
    }

    @Test
    func modifierSelectionCyclesAndClearsOneShot() {
        var selection = ShortcutModifierSelection()

        selection.cycle(.control)
        #expect(selection.state(for: .control) == .oneShot)

        selection.cycle(.control)
        #expect(selection.state(for: .control) == .locked)

        selection.cycle(.control)
        #expect(selection.state(for: .control) == .off)

        selection.cycle(.alt)
        selection.cycle(.command)
        selection.cycle(.command)
        selection.clearOneShotStates()

        #expect(selection.state(for: .alt) == .off)
        #expect(selection.state(for: .command) == .locked)
    }

    @Test
    func layoutManagerPersistsGroupsAndItems() throws {
        let suiteName = "ShortcutLayoutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let storageKey = "shortcut.layout.tests"
        defaults.removePersistentDomain(forName: suiteName)

        let manager = ShortcutLayoutManager(userDefaults: defaults, userDefaultsKey: storageKey)
        let initialCount = manager.groups.count
        #expect(initialCount >= 1)

        manager.addGroup(named: "Custom")
        let group = try #require(manager.selectedGroup)
        #expect(group.name == "Custom")

        manager.addKey("up", to: group.id)
        manager.addKey("letter_a", to: group.id)
        let updated = try #require(manager.selectedGroup)
        #expect(updated.items.count == 2)

        let reloaded = ShortcutLayoutManager(userDefaults: defaults, userDefaultsKey: storageKey)
        let reloadedGroup = try #require(reloaded.groups.first { $0.id == group.id })
        #expect(reloadedGroup.items.count == 2)

        defaults.removePersistentDomain(forName: suiteName)
    }
}
