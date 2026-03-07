use axum::Json;
use serde::Serialize;

use crate::tmux;

const CAPABILITIES_SCHEMA_VERSION: u32 = 2;

#[derive(Serialize)]
pub struct HealthzResponse {
    pub status: &'static str,
}

#[derive(Serialize)]
pub struct CapabilitiesResponse {
    pub daemon: &'static str,
    pub version: &'static str,
    pub capabilities_schema_version: u32,
    pub features: FeatureCapabilities,
    pub endpoints: EndpointCapabilities,
}

#[derive(Serialize)]
pub struct FeatureCapabilities {
    pub shortcut_keys: bool,
}

#[derive(Serialize)]
pub struct EndpointCapabilities {
    pub healthz: bool,
    pub capabilities: bool,
    pub diagnostics: bool,
    pub sessions: bool,
    pub panes: bool,
    pub pane_key: bool,
    pub notify: bool,
}

pub async fn healthz() -> Json<HealthzResponse> {
    Json(HealthzResponse { status: "ok" })
}

pub async fn capabilities() -> Json<CapabilitiesResponse> {
    Json(CapabilitiesResponse {
        daemon: "tmux-chatd",
        version: env!("CARGO_PKG_VERSION"),
        capabilities_schema_version: CAPABILITIES_SCHEMA_VERSION,
        features: FeatureCapabilities {
            shortcut_keys: true,
        },
        endpoints: EndpointCapabilities {
            healthz: true,
            capabilities: true,
            diagnostics: true,
            sessions: true,
            panes: true,
            pane_key: true,
            notify: true,
        },
    })
}

pub async fn diagnostics() -> Json<tmux::TmuxDiagnostics> {
    Json(tmux::collect_diagnostics())
}

#[cfg(test)]
mod tests {
    use super::{CapabilitiesResponse, EndpointCapabilities, FeatureCapabilities};

    #[test]
    fn capabilities_json_includes_shortcut_contract_fields() {
        let payload = CapabilitiesResponse {
            daemon: "tmux-chatd",
            version: "1.0.22",
            capabilities_schema_version: 2,
            features: FeatureCapabilities {
                shortcut_keys: true,
            },
            endpoints: EndpointCapabilities {
                healthz: true,
                capabilities: true,
                diagnostics: true,
                sessions: true,
                panes: true,
                pane_key: true,
                notify: true,
            },
        };

        let value = serde_json::to_value(payload).expect("serialize capabilities payload");
        assert_eq!(
            value
                .get("capabilities_schema_version")
                .and_then(|v| v.as_u64()),
            Some(2)
        );
        assert_eq!(
            value
                .pointer("/features/shortcut_keys")
                .and_then(|v| v.as_bool()),
            Some(true)
        );
        assert_eq!(
            value
                .pointer("/endpoints/pane_key")
                .and_then(|v| v.as_bool()),
            Some(true)
        );
    }
}
