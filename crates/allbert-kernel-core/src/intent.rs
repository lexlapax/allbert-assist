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
#[serde(deny_unknown_fields)]
pub struct RouteDecision {
    pub intent: Intent,
    pub action: RouteAction,
    pub confidence: RouteConfidence,
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

const ROUTE_DECISION_FIELDS: [&str; 12] = [
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
        for field in expected.iter() {
            if !object.contains_key(*field) {
                return Err(RouteDecisionError::MissingField((*field).into()));
            }
        }
        for field in object.keys() {
            if !expected.contains(field.as_str()) {
                return Err(RouteDecisionError::ExtraField(field.clone()));
            }
        }

        let mut decision: RouteDecision = serde_json::from_value(Value::Object(object.clone()))
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

    fn normalize_strings(&mut self) {
        self.clarifying_question = normalize_optional_string(self.clarifying_question.take(), 512);
        self.job_name = normalize_optional_string(self.job_name.take(), 128);
        self.job_description = normalize_optional_string(self.job_description.take(), 512);
        self.job_schedule = normalize_optional_string(self.job_schedule.take(), 128);
        self.job_prompt = normalize_optional_string(self.job_prompt.take(), 4096);
        self.memory_summary = normalize_optional_string(self.memory_summary.take(), 240);
        self.memory_content = normalize_optional_string(self.memory_content.take(), 16 * 1024);
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
        value["job_name"] = json!("   ");
        let decision = RouteDecision::from_value(value).expect("none action accepts absent fields");
        assert_eq!(decision.action, RouteAction::None);
        assert_eq!(decision.job_name, None);
        assert!(!decision.executable_action());
    }
}
