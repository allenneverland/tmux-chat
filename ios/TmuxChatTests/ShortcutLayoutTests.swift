import Foundation
import Testing
@testable import TmuxChat

struct ShortcutLayoutTests {
    @Test
    func modifierStateMachineCyclesOneShotLockedOff() {
        var machine = ShortcutModifierStateMachine()

        #expect(machine.state(for: .control) == .off)
        machine.cycle(.control)
        #expect(machine.state(for: .control) == .oneShot)
        machine.cycle(.control)
        #expect(machine.state(for: .control) == .locked)
        machine.cycle(.control)
        #expect(machine.state(for: .control) == .off)
    }

    @Test
    func consumingModifiersClearsOneShotButKeepsLocked() {
        var machine = ShortcutModifierStateMachine()
        machine.cycle(.control) // one-shot
        machine.cycle(.alt) // one-shot
        machine.cycle(.alt) // locked

        let consumed = machine.consumeModifiers(base: [.shift])
        #expect(consumed == Set([.control, .alt, .shift]))
        #expect(machine.state(for: .control) == .off)
        #expect(machine.state(for: .alt) == .locked)
    }

    @Test
    func eventFactoryMergesDescriptorAndActiveModifiers() {
        let item = ShortcutToolbarItem.key(
            id: "test-key",
            label: "K",
            key: "k",
            code: "KeyK",
            text: "k",
            defaultModifiers: [.control]
        )
        let event = ShortcutInputEventFactory.makeEvent(
            for: item,
            activeModifiers: [.alt],
            source: .softwareBar
        )

        #expect(event != nil)
        #expect(event?.modifiers.ctrl == true)
        #expect(event?.modifiers.alt == true)
        #expect(event?.modifiers.shift == false)
        #expect(event?.key == "k")
        #expect(event?.code == "KeyK")
    }

    @Test
    func localeLayoutsExposeDifferentLabels() {
        let french = ShortcutToolbarCatalog.layout(
            locale: Locale(identifier: "fr_FR"),
            deviceClass: .phone,
            isLandscape: false
        )
        let spanish = ShortcutToolbarCatalog.layout(
            locale: Locale(identifier: "es_ES"),
            deviceClass: .phone,
            isLandscape: false
        )

        let frenchLabels = Set(french.items.map(\.label))
        let spanishLabels = Set(spanish.items.map(\.label))

        #expect(frenchLabels.contains("A"))
        #expect(frenchLabels.contains("Z"))
        #expect(spanishLabels.contains("Ñ"))
        #expect(frenchLabels != spanishLabels)
    }

    @Test
    func clearsLegacyShortcutCustomizationStorage() {
        let key = "shortcutLayout.v1"
        let marker = "shortcutLayout.v2.migrated"
        let defaults = UserDefaults(suiteName: "shortcut-layout-tests")!
        defaults.removePersistentDomain(forName: "shortcut-layout-tests")
        defaults.set(Data("legacy".utf8), forKey: key)

        ShortcutLayoutMigration.clearLegacyCustomLayout(userDefaults: defaults)

        #expect(defaults.data(forKey: key) == nil)
        #expect(defaults.bool(forKey: marker) == true)
    }
}
