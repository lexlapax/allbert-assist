use std::collections::{BTreeSet, HashMap};

use serde::Deserialize;
use serde_json::Value;

#[derive(Debug, Clone)]
pub struct ToolInvocation {
    pub name: String,
    pub input: Value,
}

#[derive(Debug, Clone)]
pub struct ToolOutput {
    pub content: String,
    pub ok: bool,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ProcessExecInput {
    pub program: String,
    #[serde(default)]
    pub args: Option<Vec<String>>,
    #[serde(default)]
    pub cwd: Option<String>,
    #[serde(default)]
    pub timeout_s: Option<u64>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct WriteFileInput {
    pub path: String,
    pub content: String,
}

#[derive(Default, Debug, Clone)]
pub struct ToolRegistry {
    known: BTreeSet<String>,
    aliases: HashMap<String, String>,
}

impl ToolRegistry {
    pub fn builtins() -> Self {
        Self::with_names([
            "process_exec",
            "read_file",
            "write_file",
            "request_input",
            "web_search",
            "fetch_url",
            "read_memory",
            "write_memory",
            "search_memory",
            "stage_memory",
            "list_staged_memory",
            "promote_staged_memory",
            "reject_staged_memory",
            "forget_memory",
            "list_skills",
            "invoke_skill",
            "read_reference",
            "run_skill_script",
            "create_skill",
            "self_diagnose",
            "unix_pipe",
            "spawn_subagent",
        ])
    }

    pub fn empty() -> Self {
        Self::default()
    }

    pub fn with_names(names: impl IntoIterator<Item = impl Into<String>>) -> Self {
        Self {
            known: names.into_iter().map(Into::into).collect(),
            aliases: HashMap::new(),
        }
    }

    pub fn register_name(&mut self, name: impl Into<String>) {
        self.known.insert(name.into());
    }

    pub fn register_alias(&mut self, alias: impl Into<String>, canonical: impl Into<String>) {
        self.aliases.insert(alias.into(), canonical.into());
    }

    pub fn tool_names(&self) -> Vec<String> {
        self.known.iter().cloned().collect()
    }

    pub fn contains(&self, name: &str) -> bool {
        self.known.contains(name)
    }

    pub fn lookup(&self, name: &str) -> Option<String> {
        self.resolve_name(name)
    }

    pub fn resolve_name(&self, name: &str) -> Option<String> {
        if self.known.contains(name) {
            Some(name.to_string())
        } else {
            self.aliases
                .get(name)
                .filter(|canonical| self.known.contains(*canonical))
                .cloned()
        }
    }
}
