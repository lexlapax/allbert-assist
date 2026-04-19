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

#[derive(Debug, Clone)]
pub struct AllbertPaths {
    pub root: PathBuf,
    pub config: PathBuf,
    pub run: PathBuf,
    pub daemon_socket: PathBuf,
    pub logs: PathBuf,
    pub daemon_log: PathBuf,
    pub daemon_debug_log: PathBuf,
    pub soul: PathBuf,
    pub user: PathBuf,
    pub identity: PathBuf,
    pub tools_notes: PathBuf,
    pub bootstrap: PathBuf,
    pub skills: PathBuf,
    pub memory: PathBuf,
    pub memory_index: PathBuf,
    pub memory_daily: PathBuf,
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
        let jobs = root.join("jobs");
        Self {
            root: root.clone(),
            config: root.join("config.toml"),
            run: root.join("run"),
            daemon_socket: root.join("run").join("daemon.sock"),
            logs: root.join("logs"),
            daemon_log: root.join("logs").join("daemon.log"),
            daemon_debug_log: root.join("logs").join("daemon.debug.log"),
            soul: root.join("SOUL.md"),
            user: root.join("USER.md"),
            identity: root.join("IDENTITY.md"),
            tools_notes: root.join("TOOLS.md"),
            bootstrap: root.join("BOOTSTRAP.md"),
            skills: root.join("skills"),
            memory_index: memory.join("MEMORY.md"),
            memory_daily: memory.join("daily"),
            memory_topics: memory.join("topics"),
            memory_people: memory.join("people"),
            memory_projects: memory.join("projects"),
            memory_decisions: memory.join("decisions"),
            jobs_definitions: jobs.join("definitions"),
            jobs_state: jobs.join("state"),
            jobs_runs: jobs.join("runs"),
            jobs_failures: jobs.join("failures"),
            jobs_templates: jobs.join("templates"),
            traces: root.join("traces"),
            costs: root.join("costs.jsonl"),
            memory,
            jobs,
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
            &self.run,
            &self.logs,
            &self.skills,
            &self.memory,
            &self.memory_daily,
            &self.memory_topics,
            &self.memory_people,
            &self.memory_projects,
            &self.memory_decisions,
            &self.jobs,
            &self.jobs_definitions,
            &self.jobs_state,
            &self.jobs_runs,
            &self.jobs_failures,
            &self.jobs_templates,
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

        Ok(())
    }

    pub fn bootstrap_files(&self) -> [(&'static str, &std::path::Path); 5] {
        [
            ("SOUL.md", self.soul.as_path()),
            ("USER.md", self.user.as_path()),
            ("IDENTITY.md", self.identity.as_path()),
            ("TOOLS.md", self.tools_notes.as_path()),
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

        std::fs::write(path, content)
            .map_err(|e| KernelError::InitFailed(format!("write {}: {e}", path.display())))
    }
}
