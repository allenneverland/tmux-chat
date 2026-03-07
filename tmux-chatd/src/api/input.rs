use axum::{
    extract::{Path, Query},
    http::StatusCode,
    Extension, Json,
};
use serde::{Deserialize, Serialize};
use std::sync::Arc;

use crate::tmux;

pub type SharedKeyDispatchService = Arc<tmux::KeyDispatchService>;

#[derive(Deserialize)]
pub struct SendInputRequest {
    pub text: String,
}

#[derive(Deserialize)]
pub struct SendKeyRequest {
    pub key: String,
}

#[derive(Deserialize)]
pub struct SendKeysRequest {
    pub keys: Vec<String>,
}

#[derive(Deserialize, Default)]
pub struct SendKeyQuery {
    pub probe: Option<bool>,
}

#[derive(Debug, Serialize)]
pub struct ErrorResponse {
    pub code: &'static str,
    pub error: String,
}

fn key_token_is_valid(token: &str) -> bool {
    let trimmed = token.trim();
    if trimmed.is_empty() || trimmed.len() > 64 {
        return false;
    }
    if trimmed != token {
        return false;
    }
    trimmed
        .chars()
        .all(|c| c.is_ascii() && !c.is_ascii_control() && !c.is_ascii_whitespace())
}

pub async fn send_input(
    Path(target): Path<String>,
    Json(payload): Json<SendInputRequest>,
) -> Result<StatusCode, (StatusCode, Json<ErrorResponse>)> {
    match tmux::send_keys(&target, &payload.text) {
        Ok(()) => Ok(StatusCode::OK),
        Err(e) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ErrorResponse {
                code: "tmux_error",
                error: e.to_string(),
            }),
        )),
    }
}

pub async fn send_key(
    Extension(dispatcher): Extension<SharedKeyDispatchService>,
    Path(target): Path<String>,
    Query(query): Query<SendKeyQuery>,
    payload: Option<Json<SendKeyRequest>>,
) -> Result<StatusCode, (StatusCode, Json<ErrorResponse>)> {
    if query.probe.unwrap_or(false) {
        return Ok(StatusCode::NO_CONTENT);
    }

    let payload = payload.ok_or((
        StatusCode::BAD_REQUEST,
        Json(ErrorResponse {
            code: "missing_key_payload",
            error: "missing key payload".to_string(),
        }),
    ))?;
    let Json(SendKeyRequest { key }) = payload;

    if !key_token_is_valid(&key) {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(ErrorResponse {
                code: "invalid_key_token",
                error: "invalid key token".to_string(),
            }),
        ));
    }

    dispatch_single_key(dispatcher, target, key).await
}

pub async fn send_keys(
    Extension(dispatcher): Extension<SharedKeyDispatchService>,
    Path(target): Path<String>,
    Json(payload): Json<SendKeysRequest>,
) -> Result<StatusCode, (StatusCode, Json<ErrorResponse>)> {
    if payload.keys.is_empty() {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(ErrorResponse {
                code: "missing_keys_payload",
                error: "missing keys payload".to_string(),
            }),
        ));
    }
    if payload.keys.len() > 128 {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(ErrorResponse {
                code: "too_many_keys",
                error: "too many keys (max 128)".to_string(),
            }),
        ));
    }
    if payload.keys.iter().any(|token| !key_token_is_valid(token)) {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(ErrorResponse {
                code: "invalid_key_token",
                error: "invalid key token".to_string(),
            }),
        ));
    }

    match dispatcher.enqueue_keys(target, payload.keys).await {
        Ok(()) => Ok(StatusCode::ACCEPTED),
        Err(tmux::KeyDispatchError::QueueFull) => Err((
            StatusCode::TOO_MANY_REQUESTS,
            Json(ErrorResponse {
                code: "key_dispatch_queue_full",
                error: "key dispatch queue is full".to_string(),
            }),
        )),
        Err(tmux::KeyDispatchError::Unavailable) => Err((
            StatusCode::SERVICE_UNAVAILABLE,
            Json(ErrorResponse {
                code: "key_dispatch_unavailable",
                error: "key dispatch service unavailable".to_string(),
            }),
        )),
        Err(tmux::KeyDispatchError::Tmux(error)) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ErrorResponse {
                code: "tmux_error",
                error,
            }),
        )),
    }
}

pub async fn send_escape(
    Path(target): Path<String>,
) -> Result<StatusCode, (StatusCode, Json<ErrorResponse>)> {
    match tmux::send_escape(&target) {
        Ok(()) => Ok(StatusCode::OK),
        Err(e) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ErrorResponse {
                code: "tmux_error",
                error: e.to_string(),
            }),
        )),
    }
}

async fn dispatch_single_key(
    dispatcher: SharedKeyDispatchService,
    target: String,
    key: String,
) -> Result<StatusCode, (StatusCode, Json<ErrorResponse>)> {
    match dispatcher.dispatch_keys(target, vec![key]).await {
        Ok(()) => Ok(StatusCode::OK),
        Err(tmux::KeyDispatchError::QueueFull) => Err((
            StatusCode::TOO_MANY_REQUESTS,
            Json(ErrorResponse {
                code: "key_dispatch_queue_full",
                error: "key dispatch queue is full".to_string(),
            }),
        )),
        Err(tmux::KeyDispatchError::Unavailable) => Err((
            StatusCode::SERVICE_UNAVAILABLE,
            Json(ErrorResponse {
                code: "key_dispatch_unavailable",
                error: "key dispatch service unavailable".to_string(),
            }),
        )),
        Err(tmux::KeyDispatchError::Tmux(error)) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ErrorResponse {
                code: "tmux_error",
                error,
            }),
        )),
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use axum::http::Uri;
    use axum::{
        extract::{Path, Query},
        Extension,
    };

    use super::{key_token_is_valid, send_key, SendKeyQuery};
    use axum::http::StatusCode;

    #[test]
    fn accepts_valid_tokens() {
        let valid = [
            "Left", "Up", "C-c", "M-Left", "C-M-Left", "F12", "BSpace", ".", "C-.",
        ];
        for token in valid {
            assert!(key_token_is_valid(token), "expected valid token: {token}");
        }
    }

    #[test]
    fn rejects_invalid_tokens() {
        let invalid = [
            "",
            " ",
            " C-c",
            "C-c ",
            "C c",
            "C-c\n",
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        ];
        for token in invalid {
            assert!(
                !key_token_is_valid(token),
                "expected invalid token: {token:?}"
            );
        }
    }

    #[tokio::test]
    async fn probe_returns_no_content() {
        let dispatcher = Arc::new(crate::tmux::KeyDispatchService::new(1));
        let result = send_key(
            Extension(dispatcher),
            Path("dev:0.0".to_string()),
            Query(SendKeyQuery { probe: Some(true) }),
            None,
        )
        .await;
        assert!(matches!(result, Ok(StatusCode::NO_CONTENT)));
    }

    #[test]
    fn query_accepts_boolean_probe_flag() {
        let uri: Uri = "/panes/dev:0.0/key?probe=true"
            .parse()
            .expect("valid probe=true URI");
        let query = Query::<SendKeyQuery>::try_from_uri(&uri).expect("probe=true should parse");
        assert!(matches!(query.0.probe, Some(true)));
    }

    #[test]
    fn query_rejects_numeric_probe_flag() {
        let uri: Uri = "/panes/dev:0.0/key?probe=1"
            .parse()
            .expect("valid probe=1 URI");
        let query = Query::<SendKeyQuery>::try_from_uri(&uri);
        assert!(
            query.is_err(),
            "probe=1 must be rejected (bool-only contract)"
        );
    }
}
