use std::path::PathBuf;

use serde_json::Value;

#[derive(Debug, Clone)]
pub struct Skill {
    pub name: String,
    pub description: String,
    pub allowed_tools: Vec<String>,
    pub body: String,
    pub path: PathBuf,
}

#[derive(Debug, Clone)]
pub struct ActiveSkill {
    pub name: String,
    pub args: Option<Value>,
}

#[derive(Default)]
pub struct SkillStore {
    skills: Vec<Skill>,
}

impl SkillStore {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn all(&self) -> &[Skill] {
        &self.skills
    }
}
