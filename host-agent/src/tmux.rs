use std::{fs, path::Path, process::Command};

use anyhow::{Context, Result};

use crate::config::write_text_file;

pub const MANAGED_BLOCK_START: &str = "# >>> REATTACH HOST-AGENT START >>>";
pub const MANAGED_BLOCK_END: &str = "# <<< REATTACH HOST-AGENT END <<<";

pub fn install_bell_hook(tmux_conf_path: &Path, binary_path: &Path) -> Result<()> {
    let existing = if tmux_conf_path.exists() {
        fs::read_to_string(tmux_conf_path)
            .with_context(|| format!("failed to read {}", tmux_conf_path.display()))?
    } else {
        String::new()
    };

    let managed = render_managed_block(binary_path);
    let updated = upsert_managed_block(&existing, &managed);
    if updated != existing {
        write_text_file(tmux_conf_path, &updated, 0o644)?;
    }

    Ok(())
}

pub fn apply_live_hook(binary_path: &Path) -> Result<()> {
    let run_shell = format!("run-shell \"{}\"", bell_run_shell_command(binary_path));
    let output = Command::new("tmux")
        .args(["set-hook", "-g", "alert-bell", &run_shell])
        .output()
        .context("failed to execute tmux set-hook")?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        anyhow::bail!("tmux set-hook failed: {}", stderr);
    }
    Ok(())
}

pub fn is_hook_configured(tmux_conf_path: &Path) -> Result<bool> {
    if !tmux_conf_path.exists() {
        return Ok(false);
    }
    let content = fs::read_to_string(tmux_conf_path)
        .with_context(|| format!("failed to read {}", tmux_conf_path.display()))?;
    Ok(content.contains(MANAGED_BLOCK_START)
        && content.contains(MANAGED_BLOCK_END)
        && content.contains("emit-bell"))
}

pub fn is_live_hook_active() -> bool {
    let output = Command::new("tmux")
        .args(["show-hooks", "-g", "alert-bell"])
        .output();

    match output {
        Ok(out) if out.status.success() => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            stdout.contains("emit-bell")
        }
        _ => false,
    }
}

pub fn render_managed_block(binary_path: &Path) -> String {
    let hook_line = render_hook_line(binary_path);
    format!(
        "{MANAGED_BLOCK_START}\n# Managed by `host-agent install`; changes may be overwritten.\n{hook_line}\n{MANAGED_BLOCK_END}\n"
    )
}

pub fn upsert_managed_block(existing: &str, managed_block: &str) -> String {
    if let Some(start) = existing.find(MANAGED_BLOCK_START) {
        if let Some(end_rel) = existing[start..].find(MANAGED_BLOCK_END) {
            let end = start + end_rel + MANAGED_BLOCK_END.len();
            let mut tail_start = end;
            if existing[tail_start..].starts_with('\n') {
                tail_start += 1;
            }
            let mut combined = String::new();
            combined.push_str(&existing[..start]);
            combined.push_str(managed_block);
            combined.push_str(&existing[tail_start..]);
            return combined;
        }
    }

    if existing.trim().is_empty() {
        managed_block.to_string()
    } else if existing.ends_with('\n') {
        format!("{existing}\n{managed_block}")
    } else {
        format!("{existing}\n\n{managed_block}")
    }
}

fn render_hook_line(binary_path: &Path) -> String {
    let run_shell = bell_run_shell_command(binary_path);
    let escaped = escape_for_tmux_double_quotes(&run_shell);
    format!("set-hook -g alert-bell \"run-shell \\\"{escaped}\\\"\"")
}

fn bell_run_shell_command(binary_path: &Path) -> String {
    let binary = shell_quote(&binary_path.to_string_lossy());
    format!(
        "{binary} emit-bell --pane-target #{{session_name}}:#{{window_index}}.#{{pane_index}}"
    )
}

fn escape_for_tmux_double_quotes(input: &str) -> String {
    input.replace('\\', "\\\\").replace('"', "\\\"")
}

fn shell_quote(raw: &str) -> String {
    let mut quoted = String::from("'");
    for ch in raw.chars() {
        if ch == '\'' {
            quoted.push_str("'\"'\"'");
        } else {
            quoted.push(ch);
        }
    }
    quoted.push('\'');
    quoted
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn upsert_managed_block_is_idempotent() {
        let existing = "set -g mouse on\n";
        let managed = format!(
            "{MANAGED_BLOCK_START}\nset-hook -g alert-bell \"run-shell test\"\n{MANAGED_BLOCK_END}\n"
        );
        let once = upsert_managed_block(existing, &managed);
        let twice = upsert_managed_block(&once, &managed);

        assert_eq!(once, twice);
        assert_eq!(once.matches(MANAGED_BLOCK_START).count(), 1);
        assert_eq!(once.matches(MANAGED_BLOCK_END).count(), 1);
    }

    #[test]
    fn upsert_replaces_existing_block() {
        let old = format!(
            "line1\n{MANAGED_BLOCK_START}\nold\n{MANAGED_BLOCK_END}\nline2\n"
        );
        let new_block = format!(
            "{MANAGED_BLOCK_START}\nnew-line\n{MANAGED_BLOCK_END}\n"
        );

        let updated = upsert_managed_block(&old, &new_block);
        assert!(updated.contains("new-line"));
        assert!(!updated.contains("\nold\n"));
        assert!(updated.contains("line1"));
        assert!(updated.contains("line2"));
    }
}
