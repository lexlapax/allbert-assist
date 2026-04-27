use std::collections::HashSet;
use std::path::Path;

use serde_json::{json, Value};

use crate::config::SecurityConfig;
use crate::security::{exec_policy, NormalizedExec, PolicyDecision};
use crate::tools::{ToolInvocation, ToolRegistry};

#[derive(Debug, Clone, PartialEq)]
pub enum ParsedToolCall {
    Named { name: String, input: Value },
    DirectSpawn { program: String, args: Vec<String> },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ToolParseError {
    MalformedJson(String),
    UnsupportedShape(String),
    ToolUnavailable(String),
    ToolNotAllowed(String),
    ExecPolicy(String),
}

impl std::fmt::Display for ToolParseError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::MalformedJson(err) => write!(f, "tool call JSON is malformed: {err}"),
            Self::UnsupportedShape(shape) => write!(f, "unsupported tool call shape: {shape}"),
            Self::ToolUnavailable(tool) => write!(f, "tool `{tool}` is not active this turn"),
            Self::ToolNotAllowed(tool) => {
                write!(f, "tool `{tool}` is not permitted by active skill policy")
            }
            Self::ExecPolicy(reason) => write!(f, "direct spawn rejected by exec policy: {reason}"),
        }
    }
}

impl std::error::Error for ToolParseError {}

pub fn parse_tool_call_blocks(text: &str) -> Result<Vec<ParsedToolCall>, ToolParseError> {
    let mut calls = Vec::new();
    let mut start = 0usize;
    let open = "<tool_call>";
    let close = "</tool_call>";

    while let Some(open_idx_rel) = text[start..].find(open) {
        let open_idx = start + open_idx_rel + open.len();
        let Some(close_idx_rel) = text[open_idx..].find(close) else {
            return Err(ToolParseError::UnsupportedShape(
                "missing </tool_call> close tag".into(),
            ));
        };
        let close_idx = open_idx + close_idx_rel;
        let raw = text[open_idx..close_idx].trim();
        let value = serde_json::from_str::<Value>(raw)
            .map_err(|err| ToolParseError::MalformedJson(err.to_string()))?;
        calls.push(parse_json_call(value)?);
        start = close_idx + close.len();
    }

    Ok(calls)
}

pub fn resolve_tool_calls(
    parsed: Vec<ParsedToolCall>,
    catalog: &ToolRegistry,
    active_skill_policy: Option<&HashSet<String>>,
    security: &SecurityConfig,
) -> Result<Vec<ToolInvocation>, ToolParseError> {
    parsed
        .into_iter()
        .map(|call| match call {
            ParsedToolCall::Named { name, input } => Ok(ToolInvocation { name, input }),
            ParsedToolCall::DirectSpawn { program, args } => {
                resolve_direct_spawn(program, args, catalog, active_skill_policy, security)
            }
        })
        .collect()
}

pub fn parse_and_resolve_tool_calls(
    text: &str,
    catalog: &ToolRegistry,
    active_skill_policy: Option<&HashSet<String>>,
    security: &SecurityConfig,
) -> Result<Vec<ToolInvocation>, ToolParseError> {
    resolve_tool_calls(
        parse_tool_call_blocks(text)?,
        catalog,
        active_skill_policy,
        security,
    )
}

pub fn corrective_retry_message(tool_catalog: &str) -> String {
    format!(
        "Your previous response used an invalid tool-call shape. If you need a tool, respond only with one or more XML blocks exactly like <tool_call>{{\"name\":\"tool_name\",\"input\":{{...}}}}</tool_call>. The active tool catalog is:\n{tool_catalog}\nDo not invent keys outside the listed schemas."
    )
}

fn parse_json_call(value: Value) -> Result<ParsedToolCall, ToolParseError> {
    if let Some(program) = value.get("program").and_then(Value::as_str) {
        let args = value
            .get("args")
            .and_then(Value::as_array)
            .ok_or_else(|| {
                ToolParseError::UnsupportedShape("program args must be an array".into())
            })?
            .iter()
            .map(|value| {
                value.as_str().map(str::to_string).ok_or_else(|| {
                    ToolParseError::UnsupportedShape("program args must be strings".into())
                })
            })
            .collect::<Result<Vec<_>, _>>()?;
        return Ok(ParsedToolCall::DirectSpawn {
            program: program.to_string(),
            args,
        });
    }

    if let Some(function) = value.get("function") {
        let name = function
            .get("name")
            .and_then(Value::as_str)
            .ok_or_else(|| ToolParseError::UnsupportedShape("function.name is missing".into()))?;
        let input = object_input(function.get("arguments"), "function.arguments")?;
        return Ok(ParsedToolCall::Named {
            name: name.to_string(),
            input,
        });
    }

    if let Some(name) = value.get("name").and_then(Value::as_str) {
        let input = match value.get("input").or_else(|| value.get("arguments")) {
            Some(raw) => object_input(Some(raw), "name input/arguments")?,
            None => flat_named_input(&value)?,
        };
        return Ok(ParsedToolCall::Named {
            name: name.to_string(),
            input,
        });
    }

    if let Some(name) = value.get("tool").and_then(Value::as_str) {
        let input = object_input(
            value
                .get("input")
                .or_else(|| value.get("args"))
                .or_else(|| value.get("arguments"))
                .or_else(|| value.get("parameters")),
            "tool input/args/arguments/parameters",
        )?;
        return Ok(ParsedToolCall::Named {
            name: name.to_string(),
            input,
        });
    }

    Err(ToolParseError::UnsupportedShape(
        "expected name, tool, function, or program".into(),
    ))
}

fn flat_named_input(value: &Value) -> Result<Value, ToolParseError> {
    let Some(object) = value.as_object() else {
        return Err(ToolParseError::UnsupportedShape(
            "name input/arguments is missing".into(),
        ));
    };
    let mut input = serde_json::Map::new();
    for (key, item) in object {
        if key != "name" {
            input.insert(key.clone(), item.clone());
        }
    }
    if input.is_empty() {
        return Err(ToolParseError::UnsupportedShape(
            "name input/arguments is missing".into(),
        ));
    }
    Ok(Value::Object(input))
}

fn object_input(value: Option<&Value>, label: &str) -> Result<Value, ToolParseError> {
    let Some(value) = value else {
        return Err(ToolParseError::UnsupportedShape(format!(
            "{label} is missing"
        )));
    };
    if value.is_object() {
        return Ok(value.clone());
    }
    if let Some(raw) = value.as_str() {
        let parsed = serde_json::from_str::<Value>(raw)
            .map_err(|err| ToolParseError::MalformedJson(err.to_string()))?;
        if parsed.is_object() {
            return Ok(parsed);
        }
    }
    Err(ToolParseError::UnsupportedShape(format!(
        "{label} must be an object"
    )))
}

fn resolve_direct_spawn(
    program: String,
    mut args: Vec<String>,
    catalog: &ToolRegistry,
    active_skill_policy: Option<&HashSet<String>>,
    security: &SecurityConfig,
) -> Result<ToolInvocation, ToolParseError> {
    if catalog.lookup("process_exec").is_none() {
        return Err(ToolParseError::ToolUnavailable("process_exec".into()));
    }
    if let Some(allowed) = active_skill_policy {
        if !allowed.contains("process_exec") {
            return Err(ToolParseError::ToolNotAllowed("process_exec".into()));
        }
    }

    if let Some(first) = args.first() {
        let basename = Path::new(&program)
            .file_name()
            .and_then(|value| value.to_str())
            .unwrap_or(program.as_str());
        if first == &program || first == basename {
            args.remove(0);
        }
    }

    let normalized = NormalizedExec {
        program: program.clone(),
        args: args.clone(),
        cwd: None,
    };
    if let PolicyDecision::Deny(reason) = exec_policy(&normalized, security, &HashSet::new()) {
        return Err(ToolParseError::ExecPolicy(reason));
    }

    Ok(ToolInvocation {
        name: "process_exec".into(),
        input: json!({
            "program": program,
            "args": args,
        }),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::SecurityConfig;

    fn resolve(text: &str) -> Result<Vec<ToolInvocation>, ToolParseError> {
        let mut security = SecurityConfig::default();
        security.exec_allow.push("date".into());
        parse_and_resolve_tool_calls(text, &ToolRegistry::builtins(), None, &security)
    }

    #[test]
    fn accepts_canonical_and_alias_shapes() {
        let cases = [
            r#"<tool_call>{"name":"request_input","input":{"prompt":"x"}}</tool_call>"#,
            r#"<tool_call>{"name":"request_input","arguments":{"prompt":"x"}}</tool_call>"#,
            r#"<tool_call>{"tool":"request_input","args":{"prompt":"x"}}</tool_call>"#,
            r#"<tool_call>{"function":{"name":"request_input","arguments":{"prompt":"x"}}}</tool_call>"#,
        ];
        for case in cases {
            let calls = resolve(case).expect(case);
            assert_eq!(calls[0].name, "request_input");
            assert_eq!(calls[0].input["prompt"], "x");
        }
    }

    #[test]
    fn accepts_flat_named_call_with_payload_fields() {
        let calls = resolve(
            r#"<tool_call>{"name":"upsert_job","description":"Daily review","schedule":"@daily at 07:00","prompt":"Run review."}</tool_call>"#,
        )
        .expect("flat named call should resolve");
        assert_eq!(calls[0].name, "upsert_job");
        assert_eq!(calls[0].input["description"], "Daily review");
        assert_eq!(calls[0].input["schedule"], "@daily at 07:00");
        assert!(calls[0].input.get("name").is_none());
    }

    #[test]
    fn rejects_empty_flat_named_call() {
        let err = parse_tool_call_blocks(r#"<tool_call>{"name":"upsert_job"}</tool_call>"#)
            .expect_err("empty flat call should fail");
        assert!(matches!(err, ToolParseError::UnsupportedShape(_)));
    }

    #[test]
    fn direct_spawn_drops_duplicate_program_arg() {
        let calls = resolve(r#"<tool_call>{"program":"date","args":["date"]}</tool_call>"#)
            .expect("direct spawn should resolve");
        assert_eq!(calls[0].name, "process_exec");
        assert_eq!(calls[0].input["program"], "date");
        assert_eq!(calls[0].input["args"].as_array().unwrap().len(), 0);
    }

    #[test]
    fn direct_spawn_respects_active_skill_policy() {
        let allowed = HashSet::from(["request_input".to_string()]);
        let err = resolve_tool_calls(
            parse_tool_call_blocks(r#"<tool_call>{"program":"date","args":[]}</tool_call>"#)
                .unwrap(),
            &ToolRegistry::builtins(),
            Some(&allowed),
            &SecurityConfig::default(),
        )
        .unwrap_err();
        assert!(matches!(err, ToolParseError::ToolNotAllowed(_)));
    }
}
