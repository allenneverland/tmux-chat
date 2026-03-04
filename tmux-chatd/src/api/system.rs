use axum::Json;
use serde::Serialize;

use crate::tmux;

#[derive(Serialize)]
pub struct HealthzResponse {
    pub status: &'static str,
}

#[derive(Serialize)]
pub struct CapabilitiesResponse {
    pub daemon: &'static str,
    pub version: &'static str,
    pub endpoints: EndpointCapabilities,
}

#[derive(Serialize)]
pub struct EndpointCapabilities {
    pub healthz: bool,
    pub capabilities: bool,
    pub diagnostics: bool,
    pub sessions: bool,
    pub panes: bool,
    pub notify: bool,
}

pub async fn healthz() -> Json<HealthzResponse> {
    Json(HealthzResponse { status: "ok" })
}

pub async fn capabilities() -> Json<CapabilitiesResponse> {
    Json(CapabilitiesResponse {
        daemon: "tmux-chatd",
        version: env!("CARGO_PKG_VERSION"),
        endpoints: EndpointCapabilities {
            healthz: true,
            capabilities: true,
            diagnostics: true,
            sessions: true,
            panes: true,
            notify: true,
        },
    })
}

pub async fn diagnostics() -> Json<tmux::TmuxDiagnostics> {
    Json(tmux::collect_diagnostics())
}
