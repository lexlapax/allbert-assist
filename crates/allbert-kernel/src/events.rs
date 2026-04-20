use serde_json::Value;

use crate::cost::CostEntry;

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
