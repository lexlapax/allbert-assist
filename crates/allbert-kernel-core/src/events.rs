use serde_json::Value;

use crate::cost::CostEntry;

#[derive(Debug, Clone, Default)]
pub struct ActivityTransition {
    pub phase: allbert_proto::ActivityPhase,
    pub label: String,
    pub tool_name: Option<String>,
    pub tool_summary: Option<String>,
    pub skill_name: Option<String>,
    pub approval_id: Option<String>,
    pub next_actions: Vec<String>,
}

#[derive(Debug, Clone)]
pub enum KernelEvent {
    SkillTier1Surfaced {
        skill_name: String,
    },
    SkillTier2Activated {
        skill_name: String,
    },
    SkillTier3Referenced {
        skill_name: String,
        path: String,
    },
    Activity(ActivityTransition),
    AssistantText(String),
    ToolCall {
        name: String,
        input: Value,
    },
    ToolResult {
        name: String,
        ok: bool,
        content: String,
    },
    Cost(CostEntry),
    TurnDone {
        hit_turn_limit: bool,
    },
}
