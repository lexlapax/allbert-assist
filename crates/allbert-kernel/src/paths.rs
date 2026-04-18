use std::path::PathBuf;

use crate::error::KernelError;

#[derive(Debug, Clone)]
pub struct AllbertPaths {
    pub root: PathBuf,
    pub config: PathBuf,
    pub skills: PathBuf,
    pub memory: PathBuf,
    pub memory_index: PathBuf,
    pub memory_daily: PathBuf,
    pub memory_topics: PathBuf,
    pub memory_people: PathBuf,
    pub memory_projects: PathBuf,
    pub memory_decisions: PathBuf,
    pub traces: PathBuf,
    pub costs: PathBuf,
}

impl AllbertPaths {
    pub fn from_home() -> Result<Self, KernelError> {
        let home = dirs::home_dir()
            .ok_or_else(|| KernelError::InitFailed("could not resolve home directory".into()))?;
        Ok(Self::under(home.join(".allbert")))
    }

    pub fn under(root: PathBuf) -> Self {
        let memory = root.join("memory");
        Self {
            config: root.join("config.toml"),
            skills: root.join("skills"),
            memory_index: memory.join("MEMORY.md"),
            memory_daily: memory.join("daily"),
            memory_topics: memory.join("topics"),
            memory_people: memory.join("people"),
            memory_projects: memory.join("projects"),
            memory_decisions: memory.join("decisions"),
            traces: root.join("traces"),
            costs: root.join("costs.jsonl"),
            memory,
            root,
        }
    }

    pub fn ensure(&self) -> Result<(), KernelError> {
        for dir in [
            &self.root,
            &self.skills,
            &self.memory,
            &self.memory_daily,
            &self.memory_topics,
            &self.memory_people,
            &self.memory_projects,
            &self.memory_decisions,
            &self.traces,
        ] {
            std::fs::create_dir_all(dir).map_err(|e| {
                KernelError::InitFailed(format!("create {}: {e}", dir.display()))
            })?;
        }
        Ok(())
    }
}
