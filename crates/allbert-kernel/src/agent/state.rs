use crate::llm::ChatMessage;
use crate::skills::ActiveSkill;

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
    pub turn_count: u32,
    pub cost_total_usd: f64,
}

impl AgentState {
    pub fn new(session_id: String) -> Self {
        Self::for_agent(session_id, AgentDefinition::root())
    }

    pub fn for_agent(session_id: String, root_agent: AgentDefinition) -> Self {
        Self {
            session_id,
            root_agent,
            messages: Vec::new(),
            active_skills: Vec::new(),
            turn_count: 0,
            cost_total_usd: 0.0,
        }
    }

    pub fn reset(&mut self, new_session_id: String) {
        self.session_id = new_session_id;
        self.messages.clear();
        self.active_skills.clear();
        self.turn_count = 0;
        self.cost_total_usd = 0.0;
    }

    pub fn agent_name(&self) -> &str {
        &self.root_agent.name
    }
}
