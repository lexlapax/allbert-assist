use allbert_kernel::{
    find_setting, persist_setting_value, reset_setting_value, settings_for_config, AllbertPaths,
    Config, SettingMutation, SettingPersistenceError, SettingRedactionPolicy, SettingsGroup,
};
use anyhow::{anyhow, Result};

pub fn list(config: &Config, group: Option<&str>) -> Result<String> {
    let group = group.map(parse_group).transpose()?;
    let mut rows = settings_for_config(config)
        .into_iter()
        .filter(|view| group.is_none_or(|group| view.group == group))
        .map(|view| {
            format!(
                "{} [{}]\n  current: {}\n  default: {}\n  restart: {}\n  privacy: {}",
                view.key,
                view.group.id(),
                render_value(&view.current_value, view.redaction),
                render_value(&view.default_value, view.redaction),
                view.restart.label(),
                view.redaction.label()
            )
        })
        .collect::<Vec<_>>();
    if rows.is_empty() {
        rows.push("no settings in this group".into());
    }
    Ok(rows.join("\n\n"))
}

pub fn show(config: &Config, key: &str) -> Result<String> {
    let trimmed = key.trim();
    let view = settings_for_config(config)
        .into_iter()
        .find(|view| view.key == trimmed);
    let Some(view) = view else {
        let prefix = format!("{trimmed}.");
        if settings_for_config(config)
            .iter()
            .any(|view| view.key.starts_with(&prefix))
        {
            return Ok(list_by_prefix(config, trimmed));
        }
        if parse_group(trimmed).is_ok() {
            return list(config, Some(trimmed));
        }
        return Err(anyhow!("unsupported setting key `{}`", trimmed));
    };
    Ok(format!(
        "{}\n{}\ncurrent: {}\ndefault: {}\nconfig path: {}\nrestart: {}\nprivacy: {}\nsafety: {}",
        view.key,
        view.description,
        render_value(&view.current_value, view.redaction),
        render_value(&view.default_value, view.redaction),
        view.config_path,
        view.restart.label(),
        view.redaction.label(),
        view.safety_note
    ))
}

pub fn explain(group: &str) -> Result<String> {
    let group = parse_group(group)?;
    let examples = match group {
        SettingsGroup::Ui => {
            "examples: repl.ui, repl.tui.spinner_style, repl.tui.status_line.items"
        }
        SettingsGroup::Activity => "examples: operator_ux.activity.stuck_notice_after_s",
        SettingsGroup::Intent => "examples: intent.tool_call_retry_enabled",
        SettingsGroup::Trace => {
            "examples: trace.enabled, trace.capture_messages, trace.redaction.provider_payloads"
        }
        SettingsGroup::SelfDiagnosis => {
            "examples: self_diagnosis.enabled, self_diagnosis.lookback_days"
        }
        SettingsGroup::LocalUtilities => {
            "examples: local_utilities.enabled, local_utilities.unix_pipe_timeout_s"
        }
        SettingsGroup::Memory => "examples: memory.prefetch_enabled, memory.trash_retention_days",
        SettingsGroup::Learning => {
            "examples: learning.enabled, learning.personality_digest.output_path"
        }
        SettingsGroup::Personalization => {
            "examples: learning.adapter_training.enabled, learning.adapter_training.allowed_backends"
        }
        SettingsGroup::SelfImprovement => {
            "examples: self_improvement.source_checkout, scripting.engine"
        }
        SettingsGroup::Providers => "examples: model.provider, model.model_id, model.max_tokens",
    };
    Ok(format!(
        "{} settings\n{}\n{}",
        group.label(),
        group_description(group),
        examples
    ))
}

pub fn set(paths: &AllbertPaths, key: &str, value: &str) -> Result<String> {
    let mutation = persist_setting_value(paths, key, value).map_err(render_persistence_error)?;
    Ok(render_mutation("updated", mutation))
}

pub fn reset(paths: &AllbertPaths, key: &str) -> Result<String> {
    let mutation = reset_setting_value(paths, key).map_err(render_persistence_error)?;
    Ok(render_mutation("reset", mutation))
}

pub fn handle_command(paths: &AllbertPaths, command: &str) -> Result<String> {
    let config = Config::load_or_create(paths)?;
    let args = command.split_whitespace().collect::<Vec<_>>();
    match args.as_slice() {
        ["/settings"] | ["/settings", "list"] => list(&config, None),
        ["/settings", "list", group] => list(&config, Some(group)),
        ["/settings", "show", key] => show(&config, key),
        ["/settings", "set", key, value @ ..] if !value.is_empty() => {
            set(paths, key, &value.join(" "))
        }
        ["/settings", "reset", key] => reset(paths, key),
        ["/settings", "explain", group] => explain(group),
        _ => Ok("usage: /settings list [group] | show <key> | set <key> <value> | reset <key> | explain <group>".into()),
    }
}

fn parse_group(raw: &str) -> Result<SettingsGroup> {
    let normalized = raw.trim().replace('-', "_");
    SettingsGroup::ALL
        .into_iter()
        .find(|group| group.id() == normalized)
        .ok_or_else(|| anyhow!("unsupported settings group `{raw}`"))
}

fn group_description(group: SettingsGroup) -> &'static str {
    match group {
        SettingsGroup::Ui => "Local terminal and status-line behavior.",
        SettingsGroup::Activity => "Daemon-owned live activity and stuck-hint display.",
        SettingsGroup::Intent => "Intent routing and tool-call repair behavior.",
        SettingsGroup::Trace => {
            "Durable session trace capture, privacy, retention, and export posture."
        }
        SettingsGroup::SelfDiagnosis => "Bounded trace diagnosis and remediation gate posture.",
        SettingsGroup::LocalUtilities => "Host-specific utility discovery and enablement posture.",
        SettingsGroup::Memory => "Memory routing, retention, and retrieval posture.",
        SettingsGroup::Learning => "Reviewed learning and personality digest behavior.",
        SettingsGroup::Personalization => {
            "Local personalization adapters, corpus inputs, and trainer limits."
        }
        SettingsGroup::SelfImprovement => "Review-first rebuild, scripting, and worktree posture.",
        SettingsGroup::Providers => "Non-secret model provider defaults.",
    }
}

fn list_by_prefix(config: &Config, prefix: &str) -> String {
    let prefix = format!("{}.", prefix.trim_end_matches('.'));
    let rows = settings_for_config(config)
        .into_iter()
        .filter(|view| view.key.starts_with(&prefix))
        .map(|view| {
            format!(
                "{} [{}]\n  current: {}\n  default: {}\n  restart: {}\n  privacy: {}",
                view.key,
                view.group.id(),
                render_value(&view.current_value, view.redaction),
                render_value(&view.default_value, view.redaction),
                view.restart.label(),
                view.redaction.label()
            )
        })
        .collect::<Vec<_>>();
    rows.join("\n\n")
}

fn render_value(value: &str, redaction: SettingRedactionPolicy) -> String {
    match redaction {
        SettingRedactionPolicy::Redacted => "[redacted]".into(),
        SettingRedactionPolicy::Path if value.is_empty() => "(unset)".into(),
        _ if value.is_empty() => "(empty)".into(),
        _ => value.to_string(),
    }
}

fn render_mutation(action: &str, mutation: SettingMutation) -> String {
    let previous = mutation.previous_value.unwrap_or_else(|| "(unset)".into());
    let next = mutation.new_value.unwrap_or_else(|| "(default)".into());
    format!(
        "{action} {}\nconfig path: {}\nprevious: {}\nnew: {}\nchanged: {}",
        mutation.key, mutation.config_path, previous, next, mutation.changed
    )
}

fn render_persistence_error(error: SettingPersistenceError) -> anyhow::Error {
    anyhow!(
        "{}\nremediation: use `allbert-cli settings show <key>` for supported keys, or edit config.toml manually when the setting is outside the typed allowlist",
        error
    )
}

#[allow(dead_code)]
fn _catalog_has_findable_settings() {
    let _ = find_setting("repl.ui");
}

#[cfg(test)]
mod tests {
    use super::*;

    struct TempRoot {
        path: std::path::PathBuf,
    }

    impl TempRoot {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "allbert-settings-cli-{}-{}",
                std::process::id(),
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .expect("time should be monotonic")
                    .as_nanos()
            ));
            std::fs::create_dir_all(&path).expect("temp root should exist");
            Self { path }
        }

        fn paths(&self) -> AllbertPaths {
            AllbertPaths::under(self.path.join("home"))
        }
    }

    impl Drop for TempRoot {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.path);
        }
    }

    fn test_paths() -> (TempRoot, AllbertPaths) {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().expect("paths should exist");
        Config::default_template()
            .persist(&paths)
            .expect("config should persist");
        (temp, paths)
    }

    #[test]
    fn settings_render_list_show_and_explain() {
        let (_temp, paths) = test_paths();
        let config = Config::load_or_create(&paths).expect("config should load");
        let listed = list(&config, Some("ui")).expect("list should render");
        assert!(listed.contains("repl.ui"));
        assert!(listed.contains("restart:"));
        assert!(listed.contains("privacy:"));

        let shown = show(&config, "repl.tui.spinner_style").expect("show should render");
        assert!(shown.contains("config path: repl.tui.spinner_style"));
        assert!(shown.contains("safety:"));

        let trace_group = show(&config, "trace").expect("group show should render");
        assert!(trace_group.contains("trace.enabled"));
        assert!(trace_group.contains("trace.redaction.secrets"));

        let explained = explain("activity").expect("explain should render");
        assert!(explained.contains("Activity settings"));
        assert!(explained.contains("stuck"));
    }

    #[test]
    fn settings_set_and_reset_persist_with_operator_output() {
        let (_temp, paths) = test_paths();
        let updated = set(&paths, "repl.tui.tick_ms", "120").expect("set should work");
        assert!(updated.contains("updated repl.tui.tick_ms"));
        let config = Config::load_or_create(&paths).expect("config should reload");
        assert_eq!(config.repl.tui.tick_ms, 120);

        let reset = reset(&paths, "repl.tui.tick_ms").expect("reset should work");
        assert!(reset.contains("reset repl.tui.tick_ms"));
        let config = Config::load_or_create(&paths).expect("config should reload");
        assert_eq!(config.repl.tui.tick_ms, 80);
    }

    #[test]
    fn settings_invalid_key_has_remediation() {
        let (_temp, paths) = test_paths();
        let err = set(&paths, "model.api_key_env", "OPENAI_API_KEY").unwrap_err();
        assert!(err.to_string().contains("remediation:"));
    }
}
