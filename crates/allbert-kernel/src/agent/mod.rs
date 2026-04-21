pub mod state;

pub use state::{AgentDefinition, AgentState, StagedNoticeEntry};

pub trait Agent: Send + Sync {
    fn name(&self) -> &str;
    fn description(&self) -> &str;
}

impl Agent for AgentDefinition {
    fn name(&self) -> &str {
        &self.name
    }

    fn description(&self) -> &str {
        &self.description
    }
}
