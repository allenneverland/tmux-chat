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
    func tokenBuilderSupportsMultipleModifiers() {
        let token = TmuxShortcutTokenBuilder.token(
            baseToken: "r",
            modifiers: [.control, .shift]
        )
        #expect(token == "C-S-r")

        let label = TmuxShortcutTokenBuilder.displayLabel(
            baseLabel: "R",
            modifiers: [.control, .shift]
        )
        #expect(label == "Ctrl+Shift+R")
    }

    @Test
    func keyboardBaseKeyParsesLetterAndSpace() {
        let letter = TmuxShortcutTokenBuilder.keyboardBaseKey(from: "C")
        #expect(letter?.label == "C")
        #expect(letter?.token == "c")

        let space = TmuxShortcutTokenBuilder.keyboardBaseKey(from: " ")
        #expect(space?.label == "Space")
        #expect(space?.token == "Space")
    }

    @Test
    func keyboardBaseKeyRejectsUnsupportedInput() {
        #expect(TmuxShortcutTokenBuilder.keyboardBaseKey(from: "") == nil)
        #expect(TmuxShortcutTokenBuilder.keyboardBaseKey(from: "ab") == nil)
        #expect(TmuxShortcutTokenBuilder.keyboardBaseKey(from: "\n") == nil)
        #expect(TmuxShortcutTokenBuilder.keyboardBaseKey(from: "😀") == nil)
    }

    @Test
    func iosMissingKeysIncludesEnter() {
        let hasEnter = ShortcutCatalog.iosMissingKeys.contains { $0.id == "enter" }
        #expect(hasEnter)
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

        let addedCtrlC = manager.addShortcut(baseLabel: "C", baseToken: "c", modifiers: [.control], to: group.id)
        #expect(addedCtrlC)

        let escapeKey = try #require(ShortcutCatalog.byID["escape"])
        let addedEscape = manager.addCatalogKey(escapeKey, modifiers: [], to: group.id)
        #expect(addedEscape)

        let updated = try #require(manager.selectedGroup)
        #expect(updated.items.count == 2)
        #expect(updated.items[0].token == "C-c")
        #expect(updated.items[1].token == "Escape")

        let reloaded = ShortcutLayoutManager(userDefaults: defaults, userDefaultsKey: storageKey)
        let reloadedGroup = try #require(reloaded.groups.first { $0.id == group.id })
        #expect(reloadedGroup.items.count == 2)
        #expect(reloadedGroup.items[0].token == "C-c")
        #expect(reloadedGroup.items[1].token == "Escape")

        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test
    func addShortcutRejectsInvalidToken() throws {
        let suiteName = "ShortcutLayoutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let storageKey = "shortcut.layout.tests"
        defaults.removePersistentDomain(forName: suiteName)

        let manager = ShortcutLayoutManager(userDefaults: defaults, userDefaultsKey: storageKey)
        manager.addGroup(named: "Scratch")
        let group = try #require(manager.selectedGroup)

        let added = manager.addShortcut(baseLabel: "Bad", baseToken: " ", modifiers: [], to: group.id)
        #expect(!added)
        #expect(manager.selectedGroup?.items.isEmpty == true)

        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test
    func moveItemReordersWithinGroup() throws {
        let suiteName = "ShortcutLayoutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let storageKey = "shortcut.layout.tests"
        defaults.removePersistentDomain(forName: suiteName)

        let manager = ShortcutLayoutManager(userDefaults: defaults, userDefaultsKey: storageKey)
        manager.addGroup(named: "Reorder")
        let group = try #require(manager.selectedGroup)

        #expect(manager.addShortcut(baseLabel: "A", baseToken: "a", modifiers: [], to: group.id))
        #expect(manager.addShortcut(baseLabel: "B", baseToken: "b", modifiers: [], to: group.id))
        #expect(manager.addShortcut(baseLabel: "C", baseToken: "c", modifiers: [], to: group.id))

        let firstSnapshot = try #require(manager.selectedGroup)
        let firstID = firstSnapshot.items[0].id
        let thirdID = firstSnapshot.items[2].id

        manager.moveItem(in: group.id, itemID: thirdID, before: firstID)

        let reordered = try #require(manager.selectedGroup)
        #expect(reordered.items.map(\.baseToken) == ["c", "a", "b"])

        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test
    func moveItemByIndexReordersWithinGroup() throws {
        let suiteName = "ShortcutLayoutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let storageKey = "shortcut.layout.tests"
        defaults.removePersistentDomain(forName: suiteName)

        let manager = ShortcutLayoutManager(userDefaults: defaults, userDefaultsKey: storageKey)
        manager.addGroup(named: "ReorderByIndex")
        let group = try #require(manager.selectedGroup)

        #expect(manager.addShortcut(baseLabel: "A", baseToken: "a", modifiers: [], to: group.id))
        #expect(manager.addShortcut(baseLabel: "B", baseToken: "b", modifiers: [], to: group.id))
        #expect(manager.addShortcut(baseLabel: "C", baseToken: "c", modifiers: [], to: group.id))

        let snapshot = try #require(manager.selectedGroup)
        let firstID = snapshot.items[0].id

        manager.moveItem(in: group.id, itemID: firstID, to: 2)

        let reordered = try #require(manager.selectedGroup)
        #expect(reordered.items.map(\.baseToken) == ["b", "c", "a"])

        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test
    func legacyKeyIDDecodesIntoShortcutItem() throws {
        let raw = """
        {
          "id": "86F46A6E-D5FC-4C31-83FC-CEB8DCC91D17",
          "keyID": "ctrl_c_letter"
        }
        """

        let item = try JSONDecoder().decode(ShortcutItem.self, from: Data(raw.utf8))
        #expect(item.token == "C-c")
        #expect(item.displayLabel == "Ctrl+C")
    }
}
