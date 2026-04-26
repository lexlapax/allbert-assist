use serde::{Deserialize, Serialize};

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
}
