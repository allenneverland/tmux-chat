import Foundation
import Testing
@testable import TmuxChat

struct CapabilitiesContractTests {
    @Test
    func decodesSchemaV5InputEventsFeatures() throws {
        let raw = """
        {
          "daemon": "tmux-chatd",
          "version": "1.1.0",
          "capabilities_schema_version": 5,
          "features": {
            "input_events_v1": {
              "enabled": true,
              "max_batch": 128,
              "supports_repeat": true
            }
          },
          "endpoints": {
            "healthz": true,
            "capabilities": true,
            "diagnostics": true,
            "sessions": true,
            "panes": true,
            "pane_input_events": true,
            "notify": true
          }
        }
        """

        let caps = try JSONDecoder().decode(DaemonCapabilitiesResponse.self, from: Data(raw.utf8))
        #expect(caps.capabilitiesSchemaVersion == 5)
        #expect(caps.features?.inputEventsV1?.enabled == true)
        #expect(caps.features?.inputEventsV1?.maxBatch == 128)
        #expect(caps.endpoints.paneInputEvents == true)
        #expect(caps.supportsInputEventsContract == true)
        #expect(caps.maxInputEventsBatch == 128)
        #expect(caps.inputEventsSupport == .supported)
    }

    @Test
    func decodesLegacyCapabilitiesWithoutInputEventsFeature() throws {
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
        #expect(caps.endpoints.paneInputEvents == nil)
        #expect(caps.supportsInputEventsContract == false)
        #expect(caps.inputEventsSupport == .unknown)
    }

    @Test
    func reportsUnsupportedInputEventsWhenFeatureDisabled() throws {
        let raw = """
        {
          "daemon": "tmux-chatd",
          "version": "1.1.0",
          "capabilities_schema_version": 5,
          "features": {
            "input_events_v1": {
              "enabled": false,
              "max_batch": 64,
              "supports_repeat": false
            }
          },
          "endpoints": {
            "healthz": true,
            "capabilities": true,
            "diagnostics": true,
            "sessions": true,
            "panes": true,
            "pane_input_events": false,
            "notify": true
          }
        }
        """

        let caps = try JSONDecoder().decode(DaemonCapabilitiesResponse.self, from: Data(raw.utf8))
        #expect(caps.supportsInputEventsContract == false)
        #expect(caps.inputEventsSupport == .unsupported)
        #expect(caps.maxInputEventsBatch == 64)
        #expect(caps.supportsInputEventsRepeat == false)
    }
}
