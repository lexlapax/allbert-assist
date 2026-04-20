use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};

use gray_matter::engine::YAML;
use gray_matter::Matter;
use serde::Deserialize;
use serde_json::Value;

use crate::error::SkillError;
use crate::intent::Intent;

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

#[derive(Debug, Clone, Deserialize)]
pub struct InvokeSkillInput {
    pub name: String,
    #[serde(default)]
    pub args: Option<Value>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct CreateSkillInput {
    pub name: String,
    pub description: String,
    #[serde(default)]
    pub allowed_tools: Vec<String>,
    pub body: String,
}

#[derive(Default)]
pub struct SkillStore {
    skills: Vec<Skill>,
}

impl SkillStore {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn discover(root: &Path) -> Self {
        let mut skills = Vec::new();
        for skill_md in find_skill_files(root) {
            match Self::load_skill_file(&skill_md) {
                Ok(skill) => skills.push(skill),
                Err(err) => {
                    tracing::warn!("ignoring invalid skill at {}: {err}", skill_md.display());
                }
            }
        }
        skills.sort_by(|a, b| a.name.cmp(&b.name));
        Self { skills }
    }

    pub fn all(&self) -> &[Skill] {
        &self.skills
    }

    pub fn get(&self, name: &str) -> Option<&Skill> {
        self.skills.iter().find(|skill| skill.name == name)
    }

    pub fn upsert_active_skill(
        active_skills: &mut Vec<ActiveSkill>,
        name: &str,
        args: Option<Value>,
    ) {
        if let Some(existing) = active_skills.iter_mut().find(|skill| skill.name == name) {
            existing.args = args;
            return;
        }
        active_skills.push(ActiveSkill {
            name: name.into(),
            args,
        });
    }

    pub fn allowed_tool_union(&self, active_skills: &[ActiveSkill]) -> Option<HashSet<String>> {
        if active_skills.is_empty() {
            return None;
        }

        let mut allowed = HashSet::new();
        for active in active_skills {
            if let Some(skill) = self.get(&active.name) {
                allowed.extend(skill.allowed_tools.iter().cloned());
            }
        }
        Some(allowed)
    }

    pub fn create(
        &mut self,
        skills_root: &Path,
        name: &str,
        description: &str,
        allowed_tools: &[String],
        body: &str,
    ) -> Result<Skill, SkillError> {
        validate_skill_name(name)?;
        let skill_dir = skills_root.join(name);
        let skill_path = skill_dir.join("SKILL.md");
        fs::create_dir_all(&skill_dir)
            .map_err(|err| SkillError::Load(format!("create {}: {err}", skill_dir.display())))?;

        let mut frontmatter = String::new();
        frontmatter.push_str("---\n");
        frontmatter.push_str(&format!("name: {}\n", name));
        frontmatter.push_str(&format!("description: {}\n", yaml_quote(description)));
        if !allowed_tools.is_empty() {
            frontmatter.push_str("allowed-tools: ");
            frontmatter.push_str(&allowed_tools.join(" "));
            frontmatter.push('\n');
        }
        frontmatter.push_str("---\n\n");
        frontmatter.push_str(body.trim_end());
        frontmatter.push('\n');

        fs::write(&skill_path, frontmatter)
            .map_err(|err| SkillError::Load(format!("write {}: {err}", skill_path.display())))?;
        let skill = Self::load_skill_file(&skill_path)?;
        self.replace(skill.clone());
        Ok(skill)
    }

    pub fn manifest_prompt(&self) -> String {
        if self.skills.is_empty() {
            return "No skills are currently installed.".into();
        }

        self.skills
            .iter()
            .map(|skill| {
                format!(
                    "- {}: {} (allowed-tools: {})",
                    skill.name,
                    skill.description,
                    if skill.allowed_tools.is_empty() {
                        "none".into()
                    } else {
                        skill.allowed_tools.join(", ")
                    }
                )
            })
            .collect::<Vec<_>>()
            .join("\n")
    }

    pub fn intent_hint_prompt(&self, intent: &Intent) -> Option<String> {
        let keywords: &[&str] = match intent {
            Intent::Task => &["task", "write", "note", "capture", "review"],
            Intent::Chat => &[],
            Intent::Schedule => &["schedule", "job", "review", "recurring", "daily", "weekly"],
            Intent::MemoryQuery => &["memory", "note", "recall", "remember", "capture"],
            Intent::Meta => &["help", "status", "model", "config", "assistant"],
        };

        if keywords.is_empty() {
            return None;
        }

        let relevant = self
            .skills
            .iter()
            .filter(|skill| {
                let haystack = format!(
                    "{} {}",
                    skill.name.to_ascii_lowercase(),
                    skill.description.to_ascii_lowercase()
                );
                keywords.iter().any(|keyword| haystack.contains(keyword))
            })
            .map(|skill| format!("- {}: {}", skill.name, skill.description))
            .collect::<Vec<_>>();

        if relevant.is_empty() {
            None
        } else {
            Some(relevant.join("\n"))
        }
    }

    pub fn active_prompt(
        &self,
        active_skills: &[ActiveSkill],
        max_skill_args_bytes: usize,
    ) -> String {
        let mut blocks = Vec::new();
        for active in active_skills {
            let Some(skill) = self.get(&active.name) else {
                continue;
            };
            let mut block = format!("### Skill: {}\n{}\n", skill.name, skill.body.trim());
            if let Some(args) = &active.args {
                let serialized = serde_json::to_string_pretty(args).unwrap_or_else(|_| "{}".into());
                let truncated = truncate_to_bytes(&serialized, max_skill_args_bytes);
                block = format!(
                    "### Skill: {}\nInvocation arguments (JSON):\n{}\n\n{}",
                    skill.name,
                    truncated,
                    skill.body.trim()
                );
            }
            blocks.push(block);
        }
        blocks.join("\n\n")
    }

    fn replace(&mut self, skill: Skill) {
        if let Some(index) = self
            .skills
            .iter()
            .position(|existing| existing.name == skill.name)
        {
            self.skills[index] = skill;
        } else {
            self.skills.push(skill);
            self.skills.sort_by(|a, b| a.name.cmp(&b.name));
        }
    }

    fn load_skill_file(path: &Path) -> Result<Skill, SkillError> {
        let raw = fs::read_to_string(path)
            .map_err(|err| SkillError::Load(format!("read {}: {err}", path.display())))?;
        let matter = Matter::<YAML>::new();
        let parsed = matter
            .parse::<Frontmatter>(&raw)
            .map_err(|err| SkillError::Load(format!("parse {}: {err}", path.display())))?;
        let data = parsed.data.ok_or_else(|| {
            SkillError::Load(format!("missing frontmatter in {}", path.display()))
        })?;

        validate_skill_name(&data.name)?;
        if data.description.trim().is_empty() {
            return Err(SkillError::Load(format!(
                "missing description in {}",
                path.display()
            )));
        }

        Ok(Skill {
            name: data.name,
            description: data.description,
            allowed_tools: data.allowed_tools.normalize(),
            body: parsed.content.trim().to_string(),
            path: path.to_path_buf(),
        })
    }
}

#[derive(Debug, Deserialize)]
struct Frontmatter {
    name: String,
    description: String,
    #[serde(rename = "allowed-tools", default)]
    allowed_tools: AllowedTools,
}

#[derive(Debug, Default, Deserialize)]
#[serde(untagged)]
enum AllowedTools {
    #[default]
    Missing,
    String(String),
    List(Vec<String>),
}

impl AllowedTools {
    fn normalize(self) -> Vec<String> {
        match self {
            Self::Missing => Vec::new(),
            Self::String(raw) => raw
                .split_whitespace()
                .map(|tool| tool.to_string())
                .collect(),
            Self::List(values) => values,
        }
    }
}

fn find_skill_files(root: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    walk_for_skill_files(root, &mut out);
    out
}

fn walk_for_skill_files(root: &Path, out: &mut Vec<PathBuf>) {
    let Ok(entries) = fs::read_dir(root) else {
        return;
    };

    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            walk_for_skill_files(&path, out);
        } else if path
            .file_name()
            .and_then(|name| name.to_str())
            .is_some_and(|name| name.eq_ignore_ascii_case("SKILL.md"))
        {
            out.push(path);
        }
    }
}

fn validate_skill_name(name: &str) -> Result<(), SkillError> {
    if name.is_empty() {
        return Err(SkillError::Load("skill name cannot be empty".into()));
    }
    if name.len() > 64 {
        return Err(SkillError::Load("skill name is too long".into()));
    }
    if name
        .chars()
        .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '-' | '_' | '.'))
    {
        Ok(())
    } else {
        Err(SkillError::Load(format!(
            "skill name '{}' contains unsupported characters",
            name
        )))
    }
}

fn yaml_quote(value: &str) -> String {
    format!("{value:?}")
}

fn truncate_to_bytes(input: &str, max_bytes: usize) -> String {
    if input.as_bytes().len() <= max_bytes {
        return input.to_string();
    }

    let mut end = max_bytes;
    while end > 0 && !input.is_char_boundary(end) {
        end -= 1;
    }
    input[..end].to_string()
}
