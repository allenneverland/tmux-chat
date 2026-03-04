use serde::Serialize;
use std::env;
use std::path::PathBuf;
use std::process::Command;

use crate::tmux;

#[derive(Debug, Serialize)]
pub struct TmuxDiagnostics {
    pub daemon_user: String,
    pub tmux_binary: Option<String>,
    pub tmux_socket: Option<String>,
    pub session_count: usize,
    pub can_list_sessions: bool,
    pub last_tmux_error: Option<String>,
}

pub fn collect_diagnostics() -> TmuxDiagnostics {
    let daemon_user = detect_daemon_user();
    let tmux_binary = detect_tmux_binary();
    let tmux_socket = detect_tmux_socket();

    let (session_count, can_list_sessions, last_tmux_error) = match tmux::list_sessions() {
        Ok(sessions) => (sessions.len(), true, None),
        Err(error) => (0, false, Some(error.to_string())),
    };

    TmuxDiagnostics {
        daemon_user,
        tmux_binary,
        tmux_socket,
        session_count,
        can_list_sessions,
        last_tmux_error,
    }
}

fn detect_daemon_user() -> String {
    if let Ok(user) = env::var("USER") {
        let trimmed = user.trim();
        if !trimmed.is_empty() {
            return trimmed.to_string();
        }
    }

    let output = Command::new("id").arg("-un").output();
    if let Ok(output) = output {
        if output.status.success() {
            let value = String::from_utf8_lossy(&output.stdout).trim().to_string();
            if !value.is_empty() {
                return value;
            }
        }
    }

    "unknown".to_string()
}

fn detect_tmux_binary() -> Option<String> {
    let path = env::var_os("PATH")?;
    for dir in env::split_paths(&path) {
        let candidate: PathBuf = dir.join("tmux");
        if candidate.is_file() {
            return Some(candidate.to_string_lossy().to_string());
        }
    }
    None
}

fn detect_tmux_socket() -> Option<String> {
    let output = Command::new("tmux")
        .args(["display-message", "-p", "#{socket_path}"])
        .output()
        .ok()?;

    if !output.status.success() {
        return None;
    }

    let value = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if value.is_empty() {
        None
    } else {
        Some(value)
    }
}
