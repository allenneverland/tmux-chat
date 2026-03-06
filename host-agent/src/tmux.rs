use std::{fs, path::Path, process::Command};

use anyhow::{Context, Result};

use crate::config::write_text_file;

pub const MANAGED_BLOCK_START: &str = "# >>> TMUX-CHAT HOST-AGENT START >>>";
pub const MANAGED_BLOCK_END: &str = "# <<< TMUX-CHAT HOST-AGENT END <<<";
pub const MANAGED_BLOCK_START_SUFFIX: &str = "HOST-AGENT START >>>";
pub const MANAGED_BLOCK_END_SUFFIX: &str = "HOST-AGENT END <<<";

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
    run_tmux_command(
        &["set-window-option", "-g", "monitor-bell", "on"],
        "failed to execute tmux set-window-option",
    )?;
    run_tmux_command(
        &["set-option", "-g", "bell-action", "any"],
        "failed to execute tmux set-option",
    )?;
    let run_shell = format!("run-shell \"{}\"", bell_run_shell_command(binary_path));
    run_tmux_command(
        &["set-hook", "-g", "alert-bell", &run_shell],
        "failed to execute tmux set-hook",
    )?;
    Ok(())
}

pub fn is_hook_configured(tmux_conf_path: &Path) -> Result<bool> {
    if !tmux_conf_path.exists() {
        return Ok(false);
    }
    let content = fs::read_to_string(tmux_conf_path)
        .with_context(|| format!("failed to read {}", tmux_conf_path.display()))?;
    Ok(has_managed_markers(&content)
        && content.contains("emit-bell")
        && content.contains("monitor-bell on")
        && content.contains("bell-action any"))
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

pub fn monitor_bell_value() -> Option<String> {
    query_tmux_value(&["show-window-options", "-gv", "monitor-bell"])
}

pub fn bell_action_value() -> Option<String> {
    query_tmux_value(&["show-options", "-gv", "bell-action"])
}

pub fn render_managed_block(binary_path: &Path) -> String {
    let monitor_bell_line = "set-window-option -g monitor-bell on";
    let bell_action_line = "set-option -g bell-action any";
    let hook_line = render_hook_line(binary_path);
    format!(
        "{MANAGED_BLOCK_START}\n# Managed by `host-agent install`; changes may be overwritten.\n{monitor_bell_line}\n{bell_action_line}\n{hook_line}\n{MANAGED_BLOCK_END}\n"
    )
}

pub fn upsert_managed_block(existing: &str, managed_block: &str) -> String {
    if let Some((block_start, tail_start)) = find_any_managed_block_range(existing) {
        let mut combined = String::new();
        combined.push_str(&existing[..block_start]);
        combined.push_str(managed_block);
        combined.push_str(&existing[tail_start..]);
        return combined;
    }

    if existing.trim().is_empty() {
        managed_block.to_string()
    } else if existing.ends_with('\n') {
        format!("{existing}\n{managed_block}")
    } else {
        format!("{existing}\n\n{managed_block}")
    }
}

fn find_block_range(
    existing: &str,
    start_marker: &str,
    end_marker: &str,
) -> Option<(usize, usize)> {
    let start = existing.find(start_marker)?;
    let end_rel = existing[start..].find(end_marker)?;
    let mut block_end = start + end_rel + end_marker.len();
    if existing[block_end..].starts_with('\n') {
        block_end += 1;
    }
    Some((start, block_end))
}

fn find_any_managed_block_range(existing: &str) -> Option<(usize, usize)> {
    if let Some(range) = find_block_range(existing, MANAGED_BLOCK_START, MANAGED_BLOCK_END) {
        return Some(range);
    }

    let start_suffix_pos = existing.find(MANAGED_BLOCK_START_SUFFIX)?;
    let block_start = existing[..start_suffix_pos]
        .rfind('\n')
        .map_or(0, |idx| idx + 1);
    let end_suffix_rel = existing[start_suffix_pos..].find(MANAGED_BLOCK_END_SUFFIX)?;
    let mut block_end = start_suffix_pos + end_suffix_rel + MANAGED_BLOCK_END_SUFFIX.len();
    if existing[block_end..].starts_with('\n') {
        block_end += 1;
    }
    Some((block_start, block_end))
}

fn has_managed_markers(content: &str) -> bool {
    find_any_managed_block_range(content).is_some()
}

fn render_hook_line(binary_path: &Path) -> String {
    let run_shell = bell_run_shell_command(binary_path);
    let escaped = escape_for_tmux_double_quotes(&run_shell);
    format!("set-hook -g alert-bell \"run-shell \\\"{escaped}\\\"\"")
}

fn bell_run_shell_command(binary_path: &Path) -> String {
    let binary = shell_quote(&binary_path.to_string_lossy());
    format!("{binary} emit-bell --pane-target #{{session_name}}:#{{window_index}}.#{{pane_index}}")
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

fn query_tmux_value(args: &[&str]) -> Option<String> {
    let output = Command::new("tmux").args(args).output().ok()?;
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

fn run_tmux_command(args: &[&str], spawn_context: &str) -> Result<()> {
    let output = Command::new("tmux")
        .args(args)
        .output()
        .context(spawn_context)?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        anyhow::bail!("tmux command `{}` failed: {}", args.join(" "), stderr);
    }
    Ok(())
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
        let old = format!("line1\n{MANAGED_BLOCK_START}\nold\n{MANAGED_BLOCK_END}\nline2\n");
        let new_block = format!("{MANAGED_BLOCK_START}\nnew-line\n{MANAGED_BLOCK_END}\n");

        let updated = upsert_managed_block(&old, &new_block);
        assert!(updated.contains("new-line"));
        assert!(!updated.contains("\nold\n"));
        assert!(updated.contains("line1"));
        assert!(updated.contains("line2"));
    }

    #[test]
    fn render_managed_block_contains_bell_settings_and_hook() {
        let block = render_managed_block(Path::new("/tmp/host-agent"));
        assert!(block.contains("set-window-option -g monitor-bell on"));
        assert!(block.contains("set-option -g bell-action any"));
        assert!(block.contains("set-hook -g alert-bell"));
        assert!(block.contains("emit-bell"));
    }
}
