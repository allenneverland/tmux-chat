import Foundation
import Testing
@testable import TmuxChat

struct CapabilitiesContractTests {
    @Test
    func decodesSchemaV3ShortcutFeatures() throws {
        let raw = """
        {
          "daemon": "tmux-chatd",
          "version": "1.0.22",
          "capabilities_schema_version": 3,
          "features": { "shortcut_keys": true },
          "endpoints": {
            "healthz": true,
            "capabilities": true,
            "diagnostics": true,
            "sessions": true,
            "panes": true,
            "pane_key": true,
            "pane_key_probe": true,
            "notify": true
          }
        }
        """

        let caps = try JSONDecoder().decode(DaemonCapabilitiesResponse.self, from: Data(raw.utf8))
        #expect(caps.capabilitiesSchemaVersion == 3)
        #expect(caps.features?.shortcutKeys == true)
        #expect(caps.endpoints.paneKey == true)
        #expect(caps.endpoints.paneKeyProbe == true)
        #expect(caps.supportsRequiredShortcutContract == true)
        #expect(caps.shortcutKeysSupport == .supported)
    }

    @Test
    func decodesLegacyCapabilitiesWithoutShortcutFeature() throws {
        let raw = """
        {
          "daemon": "tmux-chatd",
          "version": "1.0.22",
          "endpoints": {
            "healthz": true,
            "capabilities": true,
            "diagnostics": true,
            "sessions": true,
            "panes": true,
            "notify": true
          }
        }
        """

        let caps = try JSONDecoder().decode(DaemonCapabilitiesResponse.self, from: Data(raw.utf8))
        #expect(caps.capabilitiesSchemaVersion == nil)
        #expect(caps.features == nil)
        #expect(caps.endpoints.paneKey == nil)
        #expect(caps.endpoints.paneKeyProbe == nil)
        #expect(caps.supportsRequiredShortcutContract == false)
        #expect(caps.shortcutKeysSupport == .unknown)
    }

    @Test
    func reportsUnsupportedShortcutWhenFeatureFalse() throws {
        let raw = """
        {
          "daemon": "tmux-chatd",
          "version": "1.0.22",
          "capabilities_schema_version": 3,
          "features": { "shortcut_keys": false },
          "endpoints": {
            "healthz": true,
            "capabilities": true,
            "diagnostics": true,
            "sessions": true,
            "panes": true,
            "pane_key": false,
            "pane_key_probe": false,
            "notify": true
          }
        }
        """

        let caps = try JSONDecoder().decode(DaemonCapabilitiesResponse.self, from: Data(raw.utf8))
        #expect(caps.supportsRequiredShortcutContract == false)
        #expect(caps.shortcutKeysSupport == .unsupported)
    }
}
