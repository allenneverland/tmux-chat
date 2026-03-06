use axum::{extract::Path, http::StatusCode, Json};
use serde::{Deserialize, Serialize};

use crate::tmux;

#[derive(Deserialize)]
pub struct SendInputRequest {
    pub text: String,
}

#[derive(Deserialize)]
pub struct SendKeyRequest {
    pub key: String,
}

#[derive(Serialize)]
pub struct ErrorResponse {
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
                error: e.to_string(),
            }),
        )),
    }
}

pub async fn send_key(
    Path(target): Path<String>,
    Json(payload): Json<SendKeyRequest>,
) -> Result<StatusCode, (StatusCode, Json<ErrorResponse>)> {
    if !key_token_is_valid(&payload.key) {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(ErrorResponse {
                error: "invalid key token".to_string(),
            }),
        ));
    }

    match tmux::send_key(&target, &payload.key) {
        Ok(()) => Ok(StatusCode::OK),
        Err(e) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ErrorResponse {
                error: e.to_string(),
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
                error: e.to_string(),
            }),
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::key_token_is_valid;

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
}
