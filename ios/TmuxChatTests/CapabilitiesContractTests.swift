import Foundation
import Testing
@testable import TmuxChat

struct CapabilitiesContractTests {
    @Test
    func decodesSchemaV2ShortcutFeatures() throws {
        let raw = """
        {
          "daemon": "tmux-chatd",
          "version": "1.0.22",
          "capabilities_schema_version": 2,
          "features": { "shortcut_keys": true },
          "endpoints": {
            "healthz": true,
            "capabilities": true,
            "diagnostics": true,
            "sessions": true,
            "panes": true,
            "pane_key": true,
            "notify": true
          }
        }
        """

        let caps = try JSONDecoder().decode(DaemonCapabilitiesResponse.self, from: Data(raw.utf8))
        #expect(caps.capabilitiesSchemaVersion == 2)
        #expect(caps.features?.shortcutKeys == true)
        #expect(caps.endpoints.paneKey == true)
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
        #expect(caps.shortcutKeysSupport == .unknown)
    }

    @Test
    func reportsUnsupportedShortcutWhenFeatureFalse() throws {
        let raw = """
        {
          "daemon": "tmux-chatd",
          "version": "1.0.22",
          "capabilities_schema_version": 2,
          "features": { "shortcut_keys": false },
          "endpoints": {
            "healthz": true,
            "capabilities": true,
            "diagnostics": true,
            "sessions": true,
            "panes": true,
            "pane_key": false,
            "notify": true
          }
        }
        """

        let caps = try JSONDecoder().decode(DaemonCapabilitiesResponse.self, from: Data(raw.utf8))
        #expect(caps.shortcutKeysSupport == .unsupported)
    }
}
