use std::collections::{HashMap, HashSet, VecDeque};

use crate::intent::Intent;
use crate::llm::ChatMessage;
use crate::memory::SearchMemoryHit;
use crate::skills::ActiveSkill;
use crate::ModelConfig;

#[derive(Debug, Clone)]
pub struct AgentDefinition {
    pub name: String,
    pub description: String,
}

impl AgentDefinition {
    pub fn root() -> Self {
        Self {
            name: "allbert/root".into(),
            description: "Default root agent for a session.".into(),
        }
    }
}

#[derive(Debug)]
pub struct AgentState {
    pub session_id: String,
    pub root_agent: AgentDefinition,
    pub messages: Vec<ChatMessage>,
    pub active_skills: Vec<ActiveSkill>,
    pub allowed_tools: Option<HashSet<String>>,
    pub model_override: Option<ModelConfig>,
    pub turn_count: u32,
    pub cost_total_usd: f64,
    pub last_resolved_intent: Option<Intent>,
    pub last_agent_stack: Vec<String>,
    pub surfaced_skills_this_turn: HashSet<String>,
    pub activated_skills_this_turn: HashSet<String>,
    pub referenced_resources_this_turn: HashSet<String>,
    pub reference_cache_this_turn: HashMap<String, String>,
    pub ephemeral_memory: VecDeque<String>,
    pub memory_prefetch_override: Option<bool>,
    pub memory_context_sections: Vec<String>,
    pub turn_prefetch_hits: Vec<SearchMemoryHit>,
    pub pending_memory_refresh_query: Option<String>,
    pub memory_refreshes_this_turn: u32,
    pub staged_entries_this_turn: usize,
    pub current_job_name: Option<String>,
}

impl AgentState {
    pub fn new(session_id: String) -> Self {
        Self::for_agent(session_id, AgentDefinition::root())
    }

    pub fn for_agent(session_id: String, root_agent: AgentDefinition) -> Self {
        let root_name = root_agent.name.clone();
        Self {
            session_id,
            root_agent,
            messages: Vec::new(),
            active_skills: Vec::new(),
            allowed_tools: None,
            model_override: None,
            turn_count: 0,
            cost_total_usd: 0.0,
            last_resolved_intent: None,
            last_agent_stack: vec![root_name],
            surfaced_skills_this_turn: HashSet::new(),
            activated_skills_this_turn: HashSet::new(),
            referenced_resources_this_turn: HashSet::new(),
            reference_cache_this_turn: HashMap::new(),
            ephemeral_memory: VecDeque::new(),
            memory_prefetch_override: None,
            memory_context_sections: Vec::new(),
            turn_prefetch_hits: Vec::new(),
            pending_memory_refresh_query: None,
            memory_refreshes_this_turn: 0,
            staged_entries_this_turn: 0,
            current_job_name: None,
        }
    }

    pub fn reset(&mut self, new_session_id: String) {
        self.session_id = new_session_id;
        self.messages.clear();
        self.active_skills.clear();
        self.allowed_tools = None;
        self.model_override = None;
        self.turn_count = 0;
        self.cost_total_usd = 0.0;
        self.last_resolved_intent = None;
        self.last_agent_stack = vec![self.root_agent.name.clone()];
        self.surfaced_skills_this_turn.clear();
        self.activated_skills_this_turn.clear();
        self.referenced_resources_this_turn.clear();
        self.reference_cache_this_turn.clear();
        self.ephemeral_memory.clear();
        self.memory_prefetch_override = None;
        self.memory_context_sections.clear();
        self.turn_prefetch_hits.clear();
        self.pending_memory_refresh_query = None;
        self.memory_refreshes_this_turn = 0;
        self.staged_entries_this_turn = 0;
        self.current_job_name = None;
    }

    pub fn agent_name(&self) -> &str {
        &self.root_agent.name
    }

    pub fn begin_turn(&mut self) {
        self.surfaced_skills_this_turn.clear();
        self.activated_skills_this_turn.clear();
        self.referenced_resources_this_turn.clear();
        self.reference_cache_this_turn.clear();
        self.turn_prefetch_hits.clear();
        self.pending_memory_refresh_query = None;
        self.memory_refreshes_this_turn = 0;
        self.staged_entries_this_turn = 0;
    }

    pub fn append_ephemeral_note(&mut self, note: impl Into<String>, max_bytes: usize) {
        let note = note.into();
        if note.trim().is_empty() {
            return;
        }

        self.ephemeral_memory.push_back(note);
        while self.ephemeral_memory_bytes() > max_bytes {
            if self.ephemeral_memory.pop_front().is_none() {
                break;
            }
        }
    }

    pub fn ephemeral_summary(&self, max_bytes: usize) -> String {
        let joined = self
            .ephemeral_memory
            .iter()
            .map(String::as_str)
            .collect::<Vec<_>>()
            .join("\n");
        truncate_to_bytes(&joined, max_bytes)
    }

    fn ephemeral_memory_bytes(&self) -> usize {
        self.ephemeral_memory
            .iter()
            .map(|entry| entry.as_bytes().len())
            .sum()
    }

    pub fn replace_ephemeral_memory<I>(&mut self, notes: I, max_bytes: usize)
    where
        I: IntoIterator<Item = String>,
    {
        self.ephemeral_memory.clear();
        for note in notes {
            self.append_ephemeral_note(note, max_bytes);
        }
    }

    pub fn ephemeral_notes(&self) -> Vec<String> {
        self.ephemeral_memory.iter().cloned().collect()
    }
}

fn truncate_to_bytes(input: &str, max_bytes: usize) -> String {
    if input.as_bytes().len() <= max_bytes {
        return input.to_string();
    }

    let mut end = 0usize;
    for (idx, ch) in input.char_indices() {
        let next = idx + ch.len_utf8();
        if next > max_bytes {
            break;
        }
        end = next;
    }
    input[..end].to_string()
}
