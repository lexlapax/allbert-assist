use std::path::PathBuf;

use crate::error::KernelError;

const SOUL_TEMPLATE: &str = r#"# SOUL

## Purpose
Help the user as a calm, practical, local-first assistant.

## Values
- Be honest about limits.
- Prefer concrete next steps.
- Keep the work inspectable.

## Tone
- Warm, collaborative, and direct.
- Concise by default; expand when asked.

## Boundaries
- Do not pretend work happened when it did not.
- Ask before changing durable identity, memory, or security-sensitive files.
"#;

const USER_TEMPLATE: &str = r#"# USER

## Preferred name
- Unknown

## Timezone
- Unknown

## Working style
- Fill this in during bootstrap.

## Current priorities
- Fill this in during bootstrap.
"#;

const IDENTITY_TEMPLATE: &str = r#"# IDENTITY

## Name
Allbert

## Role
A local assistant for the user.

## Style
Calm, practical, and collaborative.
"#;

const TOOLS_TEMPLATE: &str = r#"# TOOLS

## Environment notes
- Record durable local conventions and environment facts here.

## Editing rules
- Keep notes short and factual.
- Move reusable procedures into skills instead of this file.
- Incoming channel images are referenced by session-scoped local paths; no raw binary belongs in prompt text.
"#;

const BOOTSTRAP_TEMPLATE: &str = r#"# BOOTSTRAP

Use this file only during initial setup.

Before acting, make sure the durable bootstrap files capture:
- what the user wants to be called;
- how the assistant should sound;
- any stable working preferences;
- any durable local environment conventions.

Ask only for missing essentials. Once the details are written into SOUL.md,
USER.md, IDENTITY.md, and TOOLS.md, remove BOOTSTRAP.md.
"#;

const HEARTBEAT_TEMPLATE: &str = r#"---
version: 1
timezone: UTC
primary_channel: repl
quiet_hours:
  - "22:00-07:00"
check_ins:
  daily_brief:
    enabled: false
  weekly_review:
    enabled: false
inbox_nag:
  enabled: true
  cadence: daily
  time: "09:00"
  channel: repl
---

# HEARTBEAT

Adjust cadence and quiet windows to match when and where you want proactive nudges.
"#;

const DAILY_BRIEF_TEMPLATE: &str = r#"---
name: daily-brief
description: "Generate a short morning brief with recent notes, open work, and suggested next steps."
enabled: false
schedule: "@daily at 09:00"
report: always
---
Review recent durable notes, memory, and any recent daily activity.
Write a short markdown brief to reports/daily-brief.md with concrete next steps.
"#;

const WEEKLY_REVIEW_TEMPLATE: &str = r#"---
name: weekly-review
description: "Generate a weekly review with progress, blockers, and follow-up items."
enabled: false
schedule: "@weekly on monday at 09:00"
report: always
---
Summarize the last week of durable notes and memory.
Write a markdown weekly review to reports/weekly-review.md with completed work, blockers, and next actions.
"#;

const MEMORY_COMPILE_TEMPLATE: &str = r#"---
name: memory-compile
description: "Promote stable facts from recent notes into durable memory and leave a compile report."
enabled: false
schedule: "@daily at 18:00"
report: on_failure
---
Review recent daily notes for durable facts worth keeping.
Use stage_memory for candidate durable facts, do not write durable notes directly, and write a short markdown report to reports/memory-compile.md summarizing what was staged.
"#;

const TRACE_TRIAGE_TEMPLATE: &str = r#"---
name: trace-triage
description: "Review recent traces for anomalies and write a compact triage note when needed."
enabled: false
schedule: "every 6h"
report: on_anomaly
---
Inspect recent trace and log files for repeated failures, unusual tool churn, or model issues.
Write a markdown triage note to reports/trace-triage.md only when there is something actionable to report.
"#;

const SYSTEM_HEALTH_CHECK_TEMPLATE: &str = r#"---
name: system-health-check
description: "Check core local runtime health and write a small status note on failure or anomaly."
enabled: false
schedule: "every 12h"
report: on_anomaly
---
Check daemon logs, bootstrap files, and core runtime directories for obvious breakage.
Write a markdown status note to reports/system-health-check.md only when there is an actionable anomaly.
"#;

const PERSONALITY_DIGEST_TEMPLATE: &str = r#"---
name: personality-digest
description: "Draft a reviewed PERSONALITY.md learned overlay from approved memory and bounded recent episode summaries."
enabled: false
schedule: "@weekly on sunday at 18:00"
report: always
allowed-tools:
  - stage_memory
---
Run the personality digest learning job.
Do not mutate SOUL.md. Draft the learned overlay first and require explicit operator acceptance before installing PERSONALITY.md.
"#;

const MEMORY_CURATOR_SKILL_TEMPLATE: &str = include_str!("../../../skills/memory-curator/SKILL.md");
const MEMORY_CURATOR_EXTRACT_AGENT_TEMPLATE: &str =
    include_str!("../../../skills/memory-curator/agents/extract-from-turn.md");
const RUST_REBUILD_SKILL_TEMPLATE: &str = include_str!("../../../skills/rust-rebuild/SKILL.md");
const SKILL_AUTHOR_SKILL_TEMPLATE: &str = include_str!("../../../skills/skill-author/SKILL.md");

#[derive(Debug, Clone)]
pub struct AllbertPaths {
    pub root: PathBuf,
    pub config: PathBuf,
    pub config_last_good: PathBuf,
    pub config_dir: PathBuf,
    pub channel_configs: PathBuf,
    pub run: PathBuf,
    pub daemon_socket: PathBuf,
    pub daemon_lock: PathBuf,
    pub logs: PathBuf,
    pub daemon_log: PathBuf,
    pub daemon_debug_log: PathBuf,
    pub secrets: PathBuf,
    pub channel_secrets: PathBuf,
    pub telegram_allowed_chats: PathBuf,
    pub telegram_bot_token: PathBuf,
    pub identity_dir: PathBuf,
    pub identity_user: PathBuf,
    pub soul: PathBuf,
    pub user: PathBuf,
    pub identity: PathBuf,
    pub tools_notes: PathBuf,
    pub agents_notes: PathBuf,
    pub personality: PathBuf,
    pub bootstrap: PathBuf,
    pub heartbeat: PathBuf,
    pub skills: PathBuf,
    pub skills_installed: PathBuf,
    pub skills_incoming: PathBuf,
    pub memory: PathBuf,
    pub memory_index: PathBuf,
    pub memory_manifest: PathBuf,
    pub memory_notes: PathBuf,
    pub memory_daily: PathBuf,
    pub memory_staging: PathBuf,
    pub memory_staging_expired: PathBuf,
    pub memory_staging_rejected: PathBuf,
    pub memory_index_dir: PathBuf,
    pub memory_index_meta: PathBuf,
    pub memory_index_lock: PathBuf,
    pub memory_reconcile_meta: PathBuf,
    pub memory_migrations: PathBuf,
    pub memory_legacy_v04: PathBuf,
    pub memory_trash: PathBuf,
    pub memory_topics: PathBuf,
    pub memory_people: PathBuf,
    pub memory_projects: PathBuf,
    pub memory_decisions: PathBuf,
    pub jobs: PathBuf,
    pub jobs_definitions: PathBuf,
    pub jobs_state: PathBuf,
    pub jobs_runs: PathBuf,
    pub jobs_failures: PathBuf,
    pub jobs_templates: PathBuf,
    pub learning: PathBuf,
    pub learning_personality_digest: PathBuf,
    pub learning_personality_digest_runs: PathBuf,
    pub learning_personality_digest_consent: PathBuf,
    pub adapters_root: PathBuf,
    pub adapters_runs: PathBuf,
    pub adapters_installed: PathBuf,
    pub adapters_incoming: PathBuf,
    pub adapters_runtime: PathBuf,
    pub adapters_active: PathBuf,
    pub adapters_history: PathBuf,
    pub adapters_evals: PathBuf,
    pub self_improvement: PathBuf,
    pub self_improvement_history: PathBuf,
    pub worktrees: PathBuf,
    pub sessions: PathBuf,
    pub sessions_archive: PathBuf,
    pub sessions_trash: PathBuf,
    pub traces: PathBuf,
    pub costs: PathBuf,
}

impl AllbertPaths {
    pub fn from_home() -> Result<Self, KernelError> {
        if let Some(root) = std::env::var_os("ALLBERT_HOME") {
            return Ok(Self::under(PathBuf::from(root)));
        }
        let home = dirs::home_dir()
            .ok_or_else(|| KernelError::InitFailed("could not resolve home directory".into()))?;
        Ok(Self::under(home.join(".allbert")))
    }

    pub fn under(root: PathBuf) -> Self {
        let memory = root.join("memory");
        let memory_index_dir = memory.join("index");
        let jobs = root.join("jobs");
        let learning = root.join("learning");
        let learning_personality_digest = learning.join("personality-digest");
        let adapters_root = root.join("adapters");
        let self_improvement = root.join("self-improvement");
        let sessions = root.join("sessions");
        let config_dir = root.join("config");
        let channel_secrets = root.join("secrets");
        let identity_dir = root.join("identity");
        Self {
            root: root.clone(),
            config: root.join("config.toml"),
            config_last_good: root.join("config.toml.last-good"),
            config_dir: config_dir.clone(),
            channel_configs: config_dir.clone(),
            run: root.join("run"),
            daemon_socket: root.join("run").join("daemon.sock"),
            daemon_lock: root.join("daemon.lock"),
            logs: root.join("logs"),
            daemon_log: root.join("logs").join("daemon.log"),
            daemon_debug_log: root.join("logs").join("daemon.debug.log"),
            secrets: root.join("secrets"),
            channel_secrets: channel_secrets.clone(),
            telegram_allowed_chats: config_dir.join("channels.telegram.allowed_chats"),
            telegram_bot_token: channel_secrets.join("telegram").join("bot_token"),
            identity_dir: identity_dir.clone(),
            identity_user: identity_dir.join("user.md"),
            soul: root.join("SOUL.md"),
            user: root.join("USER.md"),
            identity: root.join("IDENTITY.md"),
            tools_notes: root.join("TOOLS.md"),
            agents_notes: root.join("AGENTS.md"),
            personality: root.join("PERSONALITY.md"),
            bootstrap: root.join("BOOTSTRAP.md"),
            heartbeat: root.join("HEARTBEAT.md"),
            skills: root.join("skills"),
            skills_installed: root.join("skills").join("installed"),
            skills_incoming: root.join("skills").join("incoming"),
            memory_index: memory.join("MEMORY.md"),
            memory_manifest: memory.join("manifest.json"),
            memory_notes: memory.join("notes"),
            memory_daily: memory.join("daily"),
            memory_staging: memory.join("staging"),
            memory_staging_expired: memory.join("staging").join(".expired"),
            memory_staging_rejected: memory.join("reject"),
            memory_index_meta: memory_index_dir.join("meta.json"),
            memory_index_lock: memory_index_dir.join(".rebuild.lock"),
            memory_reconcile_meta: memory_index_dir.join("reconcile.json"),
            memory_index_dir: memory_index_dir.clone(),
            memory_migrations: memory.join("migrations"),
            memory_legacy_v04: memory.join(".legacy-v04"),
            memory_trash: memory.join("trash"),
            memory_topics: memory.join("topics"),
            memory_people: memory.join("people"),
            memory_projects: memory.join("projects"),
            memory_decisions: memory.join("decisions"),
            jobs_definitions: jobs.join("definitions"),
            jobs_state: jobs.join("state"),
            jobs_runs: jobs.join("runs"),
            jobs_failures: jobs.join("failures"),
            jobs_templates: jobs.join("templates"),
            learning_personality_digest_runs: learning_personality_digest.join("runs"),
            learning_personality_digest_consent: learning_personality_digest.join("consent.json"),
            learning_personality_digest,
            learning,
            adapters_runs: adapters_root.join("runs"),
            adapters_installed: adapters_root.join("installed"),
            adapters_incoming: adapters_root.join("incoming"),
            adapters_runtime: adapters_root.join("runtime"),
            adapters_active: adapters_root.join("active.json"),
            adapters_history: adapters_root.join("history.jsonl"),
            adapters_evals: adapters_root.join("evals"),
            adapters_root,
            self_improvement_history: self_improvement.join("history.md"),
            self_improvement,
            worktrees: root.join("worktrees"),
            sessions_archive: sessions.join(".archive"),
            sessions_trash: sessions.join(".trash"),
            traces: root.join("traces"),
            costs: root.join("costs.jsonl"),
            memory,
            jobs,
            sessions,
        }
    }

    pub fn ensure(&self) -> Result<(), KernelError> {
        let needs_initial_bootstrap = !self.soul.exists()
            && !self.user.exists()
            && !self.identity.exists()
            && !self.tools_notes.exists()
            && !self.bootstrap.exists();

        for dir in [
            &self.root,
            &self.config_dir,
            &self.channel_configs,
            &self.run,
            &self.logs,
            &self.secrets,
            &self.channel_secrets,
            &self.identity_dir,
            &self.skills,
            &self.skills_installed,
            &self.skills_incoming,
            &self.memory,
            &self.memory_notes,
            &self.memory_daily,
            &self.memory_staging,
            &self.memory_staging_expired,
            &self.memory_staging_rejected,
            &self.memory_index_dir,
            &self.memory_migrations,
            &self.memory_trash,
            &self.jobs,
            &self.jobs_definitions,
            &self.jobs_state,
            &self.jobs_runs,
            &self.jobs_failures,
            &self.jobs_templates,
            &self.learning,
            &self.learning_personality_digest,
            &self.learning_personality_digest_runs,
            &self.adapters_root,
            &self.adapters_runs,
            &self.adapters_installed,
            &self.adapters_incoming,
            &self.adapters_runtime,
            &self.adapters_evals,
            &self.self_improvement,
            &self.worktrees,
            &self.sessions,
            &self.sessions_archive,
            &self.sessions_trash,
            &self.traces,
        ] {
            std::fs::create_dir_all(dir)
                .map_err(|e| KernelError::InitFailed(format!("create {}: {e}", dir.display())))?;
        }

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;

            std::fs::set_permissions(&self.run, std::fs::Permissions::from_mode(0o700)).map_err(
                |e| {
                    KernelError::InitFailed(format!(
                        "set permissions on {}: {e}",
                        self.run.display()
                    ))
                },
            )?;
        }

        for (path, template) in [
            (&self.soul, SOUL_TEMPLATE),
            (&self.user, USER_TEMPLATE),
            (&self.identity, IDENTITY_TEMPLATE),
            (&self.tools_notes, TOOLS_TEMPLATE),
        ] {
            self.seed_file_if_missing(path, template)?;
        }

        if needs_initial_bootstrap {
            self.seed_file_if_missing(&self.bootstrap, BOOTSTRAP_TEMPLATE)?;
        }

        self.seed_file_if_missing(&self.memory_index, "# MEMORY\n\n")?;
        self.seed_file_if_missing(&self.heartbeat, HEARTBEAT_TEMPLATE)?;
        self.seed_file_if_missing(&self.memory_notes.join(".keep"), "")?;
        self.seed_file_if_missing(&self.memory_staging.join(".keep"), "")?;
        self.seed_file_if_missing(&self.telegram_allowed_chats, "")?;
        self.seed_file_if_missing(
            &self
                .skills_installed
                .join("memory-curator")
                .join("SKILL.md"),
            MEMORY_CURATOR_SKILL_TEMPLATE,
        )?;
        self.seed_file_if_missing(
            &self
                .skills_installed
                .join("memory-curator")
                .join("agents")
                .join("extract-from-turn.md"),
            MEMORY_CURATOR_EXTRACT_AGENT_TEMPLATE,
        )?;
        self.seed_file_if_missing(
            &self.skills_installed.join("rust-rebuild").join("SKILL.md"),
            RUST_REBUILD_SKILL_TEMPLATE,
        )?;
        let skill_author_path = self.skills_installed.join("skill-author").join("SKILL.md");
        let seeded_skill_author = !skill_author_path.exists();
        self.seed_file_if_missing(&skill_author_path, SKILL_AUTHOR_SKILL_TEMPLATE)?;
        if seeded_skill_author {
            let installed_at = chrono::Utc::now().to_rfc3339();
            self.seed_file_if_missing(
                &self
                    .skills_installed
                    .join("skill-author")
                    .join(".allbert-install.toml"),
                &first_party_skill_install_metadata(
                    "allbert:first-party/skill-author",
                    &installed_at,
                ),
            )?;
        }

        let daily_brief = self.jobs_templates.join("daily-brief.md");
        let weekly_review = self.jobs_templates.join("weekly-review.md");
        let memory_compile = self.jobs_templates.join("memory-compile.md");
        let trace_triage = self.jobs_templates.join("trace-triage.md");
        let system_health_check = self.jobs_templates.join("system-health-check.md");
        let personality_digest = self.jobs_templates.join("personality-digest.md");
        for (path, template) in [
            (&daily_brief, DAILY_BRIEF_TEMPLATE),
            (&weekly_review, WEEKLY_REVIEW_TEMPLATE),
            (&memory_compile, MEMORY_COMPILE_TEMPLATE),
            (&trace_triage, TRACE_TRIAGE_TEMPLATE),
            (&system_health_check, SYSTEM_HEALTH_CHECK_TEMPLATE),
            (&personality_digest, PERSONALITY_DIGEST_TEMPLATE),
        ] {
            self.seed_file_if_missing(path, template)?;
        }

        Ok(())
    }

    pub fn bootstrap_files(&self) -> [(&'static str, &std::path::Path); 8] {
        [
            ("SOUL.md", self.soul.as_path()),
            ("USER.md", self.user.as_path()),
            ("IDENTITY.md", self.identity.as_path()),
            ("TOOLS.md", self.tools_notes.as_path()),
            ("PERSONALITY.md", self.personality.as_path()),
            ("AGENTS.md", self.agents_notes.as_path()),
            ("HEARTBEAT.md", self.heartbeat.as_path()),
            ("BOOTSTRAP.md", self.bootstrap.as_path()),
        ]
    }

    fn seed_file_if_missing(
        &self,
        path: &std::path::Path,
        content: &str,
    ) -> Result<(), KernelError> {
        if path.exists() {
            return Ok(());
        }

        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).map_err(|e| {
                KernelError::InitFailed(format!("create {}: {e}", parent.display()))
            })?;
        }

        atomic_write(path, content.as_bytes())
            .map_err(|e| KernelError::InitFailed(format!("write {}: {e}", path.display())))
    }
}

fn first_party_skill_install_metadata(identity: &str, installed_at: &str) -> String {
    format!(
        "tree_sha256 = \"first-party-seed\"\napproved_at = \"{installed_at}\"\ninstalled_at = \"{installed_at}\"\n\n[source]\nkind = \"first_party\"\nidentity = \"{identity}\"\n"
    )
}

fn atomic_write(path: &std::path::Path, bytes: &[u8]) -> Result<(), std::io::Error> {
    crate::atomic_write(path, bytes)
}

#[cfg(test)]
mod tests {
    use super::AllbertPaths;

    #[test]
    fn ensure_creates_channel_config_and_secret_roots() {
        let temp = tempfile::tempdir().expect("tempdir");
        let paths = AllbertPaths::under(temp.path().join(".allbert"));
        paths.ensure().expect("paths ensure");

        assert!(paths.config_dir.is_dir());
        assert!(paths.secrets.is_dir());
        assert!(paths.telegram_allowed_chats.exists());
        assert_eq!(
            paths.telegram_bot_token,
            paths.channel_secrets.join("telegram").join("bot_token")
        );
    }

    #[test]
    fn ensure_seeds_first_party_skill_author_with_install_metadata() {
        let temp = tempfile::tempdir().expect("tempdir");
        let paths = AllbertPaths::under(temp.path().join(".allbert"));
        paths.ensure().expect("paths ensure");

        let skill_author = paths.skills_installed.join("skill-author");
        let skill = std::fs::read_to_string(skill_author.join("SKILL.md"))
            .expect("skill-author should be seeded");
        assert!(skill.contains("name: skill-author"));
        assert!(skill.contains("provenance: external"));

        let metadata = std::fs::read_to_string(skill_author.join(".allbert-install.toml"))
            .expect("first-party install metadata should be seeded");
        assert!(metadata.contains("kind = \"first_party\""));
        assert!(metadata.contains("allbert:first-party/skill-author"));
    }
}
