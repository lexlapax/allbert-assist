use serde_json::Value;

use crate::cost::CostEntry;

#[derive(Debug, Clone)]
pub enum KernelEvent {
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
