use std::process::Command;

use crate::tmux::TmuxError;

fn run_send_keys(target: &str, args: &[&str]) -> Result<(), TmuxError> {
    let mut full_args = vec!["send-keys", "-t", target];
    full_args.extend_from_slice(args);

    let output = Command::new("tmux")
        .args(full_args)
        .output()
        .map_err(TmuxError::Io)?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(TmuxError::Command(stderr.to_string()));
    }

    Ok(())
}

pub fn send_keys(target: &str, text: &str) -> Result<(), TmuxError> {
    run_send_keys(target, &["-l", text])?;
    run_send_keys(target, &["Enter"])?;
    Ok(())
}

pub fn send_escape(target: &str) -> Result<(), TmuxError> {
    run_send_keys(target, &["Escape"])
}

pub fn send_key(target: &str, key: &str) -> Result<(), TmuxError> {
    run_send_keys(target, &[key])
}
