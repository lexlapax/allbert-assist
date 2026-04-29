use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::BTreeSet;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Intent {
    Task,
    Chat,
    Schedule,
    MemoryQuery,
    Meta,
}

impl Intent {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Task => "task",
            Self::Chat => "chat",
            Self::Schedule => "schedule",
            Self::MemoryQuery => "memory_query",
            Self::Meta => "meta",
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        match raw.trim().to_ascii_lowercase().as_str() {
            "task" => Some(Self::Task),
            "chat" => Some(Self::Chat),
            "schedule" => Some(Self::Schedule),
            "memory_query" => Some(Self::MemoryQuery),
            "meta" => Some(Self::Meta),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RouteAction {
    None,
    ScheduleUpsert,
    SchedulePause,
    ScheduleResume,
    ScheduleRemove,
    MemoryStageExplicit,
}

impl RouteAction {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::None => "none",
            Self::ScheduleUpsert => "schedule_upsert",
            Self::SchedulePause => "schedule_pause",
            Self::ScheduleResume => "schedule_resume",
            Self::ScheduleRemove => "schedule_remove",
            Self::MemoryStageExplicit => "memory_stage_explicit",
        }
    }

    pub fn is_action(&self) -> bool {
        !matches!(self, Self::None)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RouteConfidence {
    Low,
    Medium,
    High,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RouteExecutionPath {
    AnswerDirect,
    Clarify,
    ToolFirst,
    TerminalAction,
}

impl RouteExecutionPath {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::AnswerDirect => "answer_direct",
            Self::Clarify => "clarify",
            Self::ToolFirst => "tool_first",
            Self::TerminalAction => "terminal_action",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RouteCapability {
    ClearWeb,
    MemorySearch,
    RagSearch,
    LocalFiles,
    Jobs,
    Identity,
    Inbox,
    Profile,
    UserInput,
    Subagent,
}

impl RouteCapability {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::ClearWeb => "clear_web",
            Self::MemorySearch => "memory_search",
            Self::RagSearch => "rag_search",
            Self::LocalFiles => "local_files",
            Self::Jobs => "jobs",
            Self::Identity => "identity",
            Self::Inbox => "inbox",
            Self::Profile => "profile",
            Self::UserInput => "user_input",
            Self::Subagent => "subagent",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RouteToolStrategy {
    None,
    Prefer,
    RequireOne,
    RequireAny,
}

impl RouteToolStrategy {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::None => "none",
            Self::Prefer => "prefer",
            Self::RequireOne => "require_one",
            Self::RequireAny => "require_any",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RouteEvidencePolicy {
    None,
    PreferLocal,
    RequireLocal,
    RequireFreshExternal,
}

impl RouteEvidencePolicy {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::None => "none",
            Self::PreferLocal => "prefer_local",
            Self::RequireLocal => "require_local",
            Self::RequireFreshExternal => "require_fresh_external",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RouteMutationRisk {
    ReadOnly,
    ProfileWrite,
    ExternalEffect,
}

impl RouteMutationRisk {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::ReadOnly => "read_only",
            Self::ProfileWrite => "profile_write",
            Self::ExternalEffect => "external_effect",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RouteDecision {
    pub intent: Intent,
    pub action: RouteAction,
    pub confidence: RouteConfidence,
    pub execution_path: RouteExecutionPath,
    pub required_capabilities: Vec<RouteCapability>,
    pub tool_strategy: RouteToolStrategy,
    pub preferred_tools: Vec<String>,
    pub required_tools: Vec<String>,
    pub evidence_policy: RouteEvidencePolicy,
    pub mutation_risk: RouteMutationRisk,
    pub tool_query_hint: Option<String>,
    pub needs_clarification: bool,
    pub clarifying_question: Option<String>,
    pub job_name: Option<String>,
    pub job_description: Option<String>,
    pub job_schedule: Option<String>,
    pub job_prompt: Option<String>,
    pub memory_summary: Option<String>,
    pub memory_content: Option<String>,
    pub reason: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RouteDecisionError {
    MalformedJson(String),
    NotObject,
    MissingField(String),
    ExtraField(String),
    InvalidShape(String),
}

impl std::fmt::Display for RouteDecisionError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::MalformedJson(err) => write!(f, "route decision JSON is malformed: {err}"),
            Self::NotObject => write!(f, "route decision must be a JSON object"),
            Self::MissingField(field) => {
                write!(f, "route decision missing required field `{field}`")
            }
            Self::ExtraField(field) => write!(f, "route decision has unsupported field `{field}`"),
            Self::InvalidShape(reason) => write!(f, "invalid route decision: {reason}"),
        }
    }
}

impl std::error::Error for RouteDecisionError {}

const BASE_ROUTE_DECISION_FIELDS: [&str; 12] = [
    "intent",
    "action",
    "confidence",
    "needs_clarification",
    "clarifying_question",
    "job_name",
    "job_description",
    "job_schedule",
    "job_prompt",
    "memory_summary",
    "memory_content",
    "reason",
];

const ROUTE_DECISION_FIELDS: [&str; 20] = [
    "intent",
    "action",
    "confidence",
    "execution_path",
    "required_capabilities",
    "tool_strategy",
    "preferred_tools",
    "required_tools",
    "evidence_policy",
    "mutation_risk",
    "tool_query_hint",
    "needs_clarification",
    "clarifying_question",
    "job_name",
    "job_description",
    "job_schedule",
    "job_prompt",
    "memory_summary",
    "memory_content",
    "reason",
];

impl RouteDecision {
    pub fn schema() -> Value {
        json!({
            "type": "object",
            "additionalProperties": false,
            "required": ROUTE_DECISION_FIELDS,
            "properties": {
                "intent": {
                    "type": "string",
                    "enum": ["task", "chat", "schedule", "memory_query", "meta"]
                },
                "action": {
                    "type": "string",
                    "enum": [
                        "none",
                        "schedule_upsert",
                        "schedule_pause",
                        "schedule_resume",
                        "schedule_remove",
                        "memory_stage_explicit"
                    ]
                },
                "confidence": {
                    "type": "string",
                    "enum": ["low", "medium", "high"]
                },
                "execution_path": {
                    "type": "string",
                    "enum": ["answer_direct", "clarify", "tool_first", "terminal_action"]
                },
                "required_capabilities": {
                    "type": "array",
                    "items": {
                        "type": "string",
                        "enum": [
                            "clear_web",
                            "memory_search",
                            "rag_search",
                            "local_files",
                            "jobs",
                            "identity",
                            "inbox",
                            "profile",
                            "user_input",
                            "subagent"
                        ]
                    }
                },
                "tool_strategy": {
                    "type": "string",
                    "enum": ["none", "prefer", "require_one", "require_any"]
                },
                "preferred_tools": {
                    "type": "array",
                    "items": { "type": "string" }
                },
                "required_tools": {
                    "type": "array",
                    "items": { "type": "string" }
                },
                "evidence_policy": {
                    "type": "string",
                    "enum": ["none", "prefer_local", "require_local", "require_fresh_external"]
                },
                "mutation_risk": {
                    "type": "string",
                    "enum": ["read_only", "profile_write", "external_effect"]
                },
                "tool_query_hint": { "type": ["string", "null"], "maxLength": 256 },
                "needs_clarification": { "type": "boolean" },
                "clarifying_question": { "type": ["string", "null"] },
                "job_name": { "type": ["string", "null"] },
                "job_description": { "type": ["string", "null"] },
                "job_schedule": { "type": ["string", "null"] },
                "job_prompt": { "type": ["string", "null"] },
                "memory_summary": { "type": ["string", "null"], "maxLength": 240 },
                "memory_content": { "type": ["string", "null"] },
                "reason": { "type": "string", "maxLength": 512 }
            }
        })
    }

    pub fn from_json_str(raw: &str) -> Result<Self, RouteDecisionError> {
        let value: Value = serde_json::from_str(raw)
            .map_err(|err| RouteDecisionError::MalformedJson(err.to_string()))?;
        Self::from_value(value)
    }

    pub fn from_value(value: Value) -> Result<Self, RouteDecisionError> {
        let object = value.as_object().ok_or(RouteDecisionError::NotObject)?;
        let expected = ROUTE_DECISION_FIELDS.into_iter().collect::<BTreeSet<_>>();
        let required = BASE_ROUTE_DECISION_FIELDS
            .into_iter()
            .collect::<BTreeSet<_>>();
        for field in required.iter() {
            if !object.contains_key(*field) {
                return Err(RouteDecisionError::MissingField((*field).into()));
            }
        }
        for field in object.keys() {
            if !expected.contains(field.as_str()) {
                return Err(RouteDecisionError::ExtraField(field.clone()));
            }
        }

        let mut object = object.clone();
        add_default_turn_plan_fields(&mut object);
        let mut decision: RouteDecision = serde_json::from_value(Value::Object(object))
            .map_err(|err| RouteDecisionError::InvalidShape(err.to_string()))?;
        decision.normalize_strings();
        decision.validate()?;
        Ok(decision)
    }

    pub fn executable_action(&self) -> bool {
        self.action.is_action()
            && self.confidence == RouteConfidence::High
            && !self.needs_clarification
            && self.action_requirements_met()
    }

    pub fn apply_lexical_turn_plan(&mut self, user_input: &str) {
        if self.action.is_action() || self.needs_clarification {
            return;
        }
        let Some(query_hint) = clear_web_query_hint(user_input) else {
            return;
        };
        self.execution_path = RouteExecutionPath::ToolFirst;
        self.required_capabilities = vec![RouteCapability::ClearWeb];
        self.tool_strategy = RouteToolStrategy::RequireOne;
        self.preferred_tools = vec!["web_search".into()];
        self.required_tools = vec!["web_search".into()];
        self.evidence_policy = RouteEvidencePolicy::RequireFreshExternal;
        self.mutation_risk = RouteMutationRisk::ReadOnly;
        self.tool_query_hint = Some(query_hint);
    }

    fn normalize_strings(&mut self) {
        self.clarifying_question = normalize_optional_string(self.clarifying_question.take(), 512);
        self.job_name = normalize_optional_string(self.job_name.take(), 128);
        self.job_description = normalize_optional_string(self.job_description.take(), 512);
        self.job_schedule = normalize_optional_string(self.job_schedule.take(), 128);
        self.job_prompt = normalize_optional_string(self.job_prompt.take(), 4096);
        self.memory_summary = normalize_optional_string(self.memory_summary.take(), 240);
        self.memory_content = normalize_optional_string(self.memory_content.take(), 16 * 1024);
        self.preferred_tools = normalize_tool_names(std::mem::take(&mut self.preferred_tools));
        self.required_tools = normalize_tool_names(std::mem::take(&mut self.required_tools));
        self.tool_query_hint = normalize_optional_string(self.tool_query_hint.take(), 256);
        self.reason = truncate_to_bytes(self.reason.trim(), 512);
    }

    fn validate(&self) -> Result<(), RouteDecisionError> {
        if self.needs_clarification && self.clarifying_question.is_none() {
            return Err(RouteDecisionError::InvalidShape(
                "clarifying_question is required when needs_clarification is true".into(),
            ));
        }
        if !self.action_requirements_met() {
            return Err(RouteDecisionError::InvalidShape(format!(
                "required fields missing for action `{}`",
                self.action.as_str()
            )));
        }
        if self.reason.trim().is_empty() {
            return Err(RouteDecisionError::InvalidShape(
                "reason must not be empty".into(),
            ));
        }
        if self.tool_strategy == RouteToolStrategy::None
            && (!self.required_tools.is_empty() || !self.preferred_tools.is_empty())
        {
            return Err(RouteDecisionError::InvalidShape(
                "tool_strategy none cannot include tools".into(),
            ));
        }
        if matches!(
            self.tool_strategy,
            RouteToolStrategy::RequireOne | RouteToolStrategy::RequireAny
        ) && self.required_tools.is_empty()
        {
            return Err(RouteDecisionError::InvalidShape(
                "required_tools must not be empty when tool_strategy requires tools".into(),
            ));
        }
        Ok(())
    }

    fn action_requirements_met(&self) -> bool {
        match self.action {
            RouteAction::None => true,
            RouteAction::ScheduleUpsert => {
                self.job_name.is_some()
                    && self.job_description.is_some()
                    && self.job_schedule.is_some()
                    && self.job_prompt.is_some()
            }
            RouteAction::SchedulePause
            | RouteAction::ScheduleResume
            | RouteAction::ScheduleRemove => self.job_name.is_some(),
            RouteAction::MemoryStageExplicit => {
                self.memory_summary.is_some() && self.memory_content.is_some()
            }
        }
    }
}

fn add_default_turn_plan_fields(object: &mut serde_json::Map<String, Value>) {
    object
        .entry("execution_path")
        .or_insert_with(|| json!("answer_direct"));
    object
        .entry("required_capabilities")
        .or_insert_with(|| json!([]));
    object
        .entry("tool_strategy")
        .or_insert_with(|| json!("none"));
    object.entry("preferred_tools").or_insert_with(|| json!([]));
    object.entry("required_tools").or_insert_with(|| json!([]));
    object
        .entry("evidence_policy")
        .or_insert_with(|| json!("none"));
    object
        .entry("mutation_risk")
        .or_insert_with(|| json!("read_only"));
    object.entry("tool_query_hint").or_insert(Value::Null);
}

fn normalize_tool_names(values: Vec<String>) -> Vec<String> {
    let mut seen = BTreeSet::new();
    values
        .into_iter()
        .filter_map(|raw| normalize_optional_string(Some(raw), 128))
        .filter(|name| {
            let valid = name
                .chars()
                .all(|ch| ch.is_ascii_lowercase() || ch.is_ascii_digit() || ch == '_');
            valid && seen.insert(name.clone())
        })
        .collect()
}

fn normalize_optional_string(value: Option<String>, max_bytes: usize) -> Option<String> {
    value.and_then(|raw| {
        let trimmed = truncate_to_bytes(raw.trim(), max_bytes);
        if trimmed.is_empty() {
            None
        } else {
            Some(trimmed)
        }
    })
}

fn clear_web_query_hint(input: &str) -> Option<String> {
    let trimmed = input.trim();
    if trimmed.is_empty() {
        return None;
    }
    let lower = trimmed.to_ascii_lowercase();
    for prefix in [
        "web search for ",
        "web search ",
        "search the web for ",
        "search the web ",
        "search online for ",
        "search online ",
        "look up ",
        "google ",
        "browse for ",
        "browse ",
    ] {
        if let Some(rest) = lower.strip_prefix(prefix) {
            let offset = lower.len() - rest.len();
            let query = trimmed[offset..].trim();
            return (!query.is_empty()).then(|| query.to_string());
        }
    }

    if local_today_context(&lower) {
        return None;
    }

    let current_info_cues = [
        "today's top news",
        "todays top news",
        "top news today",
        "latest news",
        "breaking news",
        "current events",
        "what happened today",
        "who won today",
        "latest on ",
        "latest about ",
        "most recent ",
        "right now",
    ];
    if current_info_cues.iter().any(|cue| lower.contains(cue)) {
        return Some(trimmed.to_string());
    }
    None
}

fn local_today_context(lower: &str) -> bool {
    [
        "today's cost",
        "todays cost",
        "cost today",
        "what did we do today",
        "what have we done today",
        "our session today",
        "my session today",
        "memory today",
        "inbox today",
        "heartbeat today",
        "profile today",
        "jobs today",
    ]
    .iter()
    .any(|cue| lower.contains(cue))
}

fn truncate_to_bytes(input: &str, max_bytes: usize) -> String {
    if input.len() <= max_bytes {
        return input.to_string();
    }

    let mut end = max_bytes;
    while end > 0 && !input.is_char_boundary(end) {
        end -= 1;
    }
    input[..end].to_string()
}

pub fn classify_by_rules(input: &str) -> Option<Intent> {
    let normalized = normalize(input);

    if normalized.is_empty() {
        return Some(Intent::Chat);
    }

    if contains_any(
        &normalized,
        &[
            "schedule ",
            "scheduled ",
            "what jobs",
            "which jobs",
            "list jobs",
            "pause ",
            "resume ",
            "remove ",
            "delete ",
            "run it now",
            "pause it",
            "resume it",
            "remove it",
            "delete it",
            "why did that job fail",
            "job fail",
            "job failed",
            "failed job",
            " pause ",
            " resume ",
            " remove ",
            " delete ",
            " run the ",
            " job now",
            "recurring",
            "every day",
            "every week",
            "every month",
            "daily ",
            "weekly ",
            "cron ",
            "remind me",
            "set up a job",
            "set up job",
            "run every",
        ],
    ) {
        return Some(Intent::Schedule);
    }

    if contains_any(
        &normalized,
        &[
            "remember ",
            "memory",
            "what do you remember",
            "what do you know about",
            "recall ",
            "from memory",
        ],
    ) {
        return Some(Intent::MemoryQuery);
    }

    if contains_any(
        &normalized,
        &[
            "/help",
            "/status",
            "/model",
            "help ",
            "what can you do",
            "show status",
            "show config",
            "which model",
            "current model",
            "what version",
            "who are you",
            "how do i use",
        ],
    ) {
        return Some(Intent::Meta);
    }

    if is_chat_like(&normalized) {
        return Some(Intent::Chat);
    }

    if looks_ambiguous(&normalized) {
        return None;
    }

    Some(Intent::Task)
}

pub fn default_intent(input: &str) -> Intent {
    let normalized = normalize(input);
    if is_chat_like(&normalized) {
        Intent::Chat
    } else {
        Intent::Task
    }
}

fn normalize(input: &str) -> String {
    input.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn contains_any(haystack: &str, needles: &[&str]) -> bool {
    needles.iter().any(|needle| haystack.contains(needle))
}

fn is_chat_like(normalized: &str) -> bool {
    matches!(
        normalized,
        "hi" | "hello"
            | "hey"
            | "thanks"
            | "thank you"
            | "good morning"
            | "good afternoon"
            | "good evening"
            | "how are you"
    ) || contains_any(
        normalized,
        &[
            "hello ",
            "hey ",
            "hi ",
            "how are you",
            "thank you",
            "thanks ",
            "nice to meet you",
            "good morning",
            "good afternoon",
            "good evening",
        ],
    )
}

fn looks_ambiguous(normalized: &str) -> bool {
    contains_any(normalized, &["hmm", "maybe", "not sure", "thoughts"])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rule_classifier_covers_taxonomy_examples() {
        assert_eq!(
            classify_by_rules("schedule a daily review at 07:00"),
            Some(Intent::Schedule)
        );
        assert_eq!(
            classify_by_rules("what do you remember about rust?"),
            Some(Intent::MemoryQuery)
        );
        assert_eq!(classify_by_rules("what can you do?"), Some(Intent::Meta));
        assert_eq!(classify_by_rules("hello there"), Some(Intent::Chat));
        assert_eq!(
            classify_by_rules("implement the parser fix"),
            Some(Intent::Task)
        );
    }

    #[test]
    fn default_intent_prefers_chat_for_small_talk() {
        assert_eq!(default_intent("thanks"), Intent::Chat);
        assert_eq!(default_intent("review this diff"), Intent::Task);
    }

    fn base_decision() -> serde_json::Value {
        json!({
            "intent": "schedule",
            "action": "schedule_upsert",
            "confidence": "high",
            "execution_path": "terminal_action",
            "required_capabilities": [],
            "tool_strategy": "none",
            "preferred_tools": [],
            "required_tools": [],
            "evidence_policy": "none",
            "mutation_risk": "profile_write",
            "tool_query_hint": null,
            "needs_clarification": false,
            "clarifying_question": null,
            "job_name": "daily-review",
            "job_description": "Daily review",
            "job_schedule": "@daily at 07:00",
            "job_prompt": "Run a concise daily review.",
            "memory_summary": null,
            "memory_content": null,
            "reason": "User asked to schedule a recurring daily review."
        })
    }

    #[test]
    fn route_decision_validates_action_matrix() {
        let decision = RouteDecision::from_value(base_decision()).expect("valid route decision");
        assert_eq!(decision.intent, Intent::Schedule);
        assert_eq!(decision.action, RouteAction::ScheduleUpsert);
        assert!(decision.executable_action());

        let mut invalid = base_decision();
        invalid["job_prompt"] = serde_json::Value::Null;
        let err = RouteDecision::from_value(invalid).unwrap_err();
        assert!(err.to_string().contains("schedule_upsert"));
    }

    #[test]
    fn route_decision_rejects_missing_or_extra_fields() {
        let mut missing = base_decision();
        missing.as_object_mut().unwrap().remove("reason");
        assert!(matches!(
            RouteDecision::from_value(missing),
            Err(RouteDecisionError::MissingField(_))
        ));

        let mut extra = base_decision();
        extra["unexpected"] = json!(true);
        assert!(matches!(
            RouteDecision::from_value(extra),
            Err(RouteDecisionError::ExtraField(_))
        ));
    }

    #[test]
    fn route_decision_normalizes_empty_optional_strings() {
        let mut value = base_decision();
        value["action"] = json!("none");
        value["execution_path"] = json!("answer_direct");
        value["mutation_risk"] = json!("read_only");
        value["job_name"] = json!("   ");
        let decision = RouteDecision::from_value(value).expect("none action accepts absent fields");
        assert_eq!(decision.action, RouteAction::None);
        assert_eq!(decision.job_name, None);
        assert!(!decision.executable_action());
    }

    #[test]
    fn route_decision_supports_tool_first_clear_web_plan() {
        let mut value = base_decision();
        value["intent"] = json!("task");
        value["action"] = json!("none");
        value["execution_path"] = json!("tool_first");
        value["required_capabilities"] = json!(["clear_web"]);
        value["tool_strategy"] = json!("require_one");
        value["preferred_tools"] = json!(["web_search"]);
        value["required_tools"] = json!(["web_search"]);
        value["evidence_policy"] = json!("require_fresh_external");
        value["mutation_risk"] = json!("read_only");
        value["tool_query_hint"] = json!("today's top news");
        value["job_name"] = serde_json::Value::Null;
        value["job_description"] = serde_json::Value::Null;
        value["job_schedule"] = serde_json::Value::Null;
        value["job_prompt"] = serde_json::Value::Null;
        let decision = RouteDecision::from_value(value).expect("tool-first plan should validate");
        assert_eq!(decision.execution_path, RouteExecutionPath::ToolFirst);
        assert_eq!(
            decision.required_capabilities,
            vec![RouteCapability::ClearWeb]
        );
        assert_eq!(decision.required_tools, vec!["web_search"]);
        assert_eq!(
            decision.evidence_policy,
            RouteEvidencePolicy::RequireFreshExternal
        );
    }

    #[test]
    fn lexical_turn_plan_marks_explicit_and_current_web_requests() {
        let mut explicit = RouteDecision::from_value({
            let mut value = base_decision();
            value["intent"] = json!("task");
            value["action"] = json!("none");
            value["execution_path"] = json!("answer_direct");
            value["mutation_risk"] = json!("read_only");
            value["job_name"] = serde_json::Value::Null;
            value["job_description"] = serde_json::Value::Null;
            value["job_schedule"] = serde_json::Value::Null;
            value["job_prompt"] = serde_json::Value::Null;
            value
        })
        .expect("base none decision");
        explicit.apply_lexical_turn_plan("web search for today's top news");
        assert_eq!(explicit.execution_path, RouteExecutionPath::ToolFirst);
        assert_eq!(explicit.required_tools, vec!["web_search"]);
        assert_eq!(
            explicit.tool_query_hint.as_deref(),
            Some("today's top news")
        );

        let mut current = explicit.clone();
        current.execution_path = RouteExecutionPath::AnswerDirect;
        current.required_capabilities.clear();
        current.tool_strategy = RouteToolStrategy::None;
        current.preferred_tools.clear();
        current.required_tools.clear();
        current.evidence_policy = RouteEvidencePolicy::None;
        current.tool_query_hint = None;
        current.apply_lexical_turn_plan("what's today's top news?");
        assert_eq!(current.execution_path, RouteExecutionPath::ToolFirst);
        assert_eq!(current.required_tools, vec!["web_search"]);
    }

    #[test]
    fn lexical_turn_plan_does_not_mark_local_today_questions() {
        let mut decision = RouteDecision::from_value({
            let mut value = base_decision();
            value["intent"] = json!("meta");
            value["action"] = json!("none");
            value["execution_path"] = json!("answer_direct");
            value["mutation_risk"] = json!("read_only");
            value["job_name"] = serde_json::Value::Null;
            value["job_description"] = serde_json::Value::Null;
            value["job_schedule"] = serde_json::Value::Null;
            value["job_prompt"] = serde_json::Value::Null;
            value
        })
        .expect("base none decision");
        decision.apply_lexical_turn_plan("what is today's cost?");
        assert_eq!(decision.execution_path, RouteExecutionPath::AnswerDirect);
        assert!(decision.required_tools.is_empty());
    }
}
