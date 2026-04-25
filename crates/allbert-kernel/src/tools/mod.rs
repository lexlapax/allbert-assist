use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use serde::Deserialize;
use serde_json::{json, Value};
use tokio::process::Command;

use crate::adapter::{InputPrompter, InputRequest, InputResponse};
use crate::config::SecurityConfig;
use crate::error::ToolError;
use crate::security::sandbox;

#[derive(Debug, Clone)]
pub struct ToolInvocation {
    pub name: String,
    pub input: Value,
}

#[derive(Debug, Clone)]
pub struct ToolOutput {
    pub content: String,
    pub ok: bool,
}

#[async_trait]
pub trait ToolRuntime: Send {
    fn read_memory(&mut self, input: Value) -> ToolOutput;
    fn write_memory(&mut self, input: Value) -> ToolOutput;
    fn search_memory(&mut self, input: Value) -> ToolOutput;
    async fn stage_memory(&mut self, input: Value) -> ToolOutput;
    fn list_staged_memory(&mut self, input: Value) -> ToolOutput;
    async fn promote_staged_memory(&mut self, input: Value) -> ToolOutput;
    fn reject_staged_memory(&mut self, input: Value) -> ToolOutput;
    async fn forget_memory(&mut self, input: Value) -> ToolOutput;

    fn list_skills(&mut self, input: Value) -> ToolOutput;
    fn invoke_skill(&mut self, input: Value) -> ToolOutput;
    fn read_reference(&mut self, input: Value) -> ToolOutput;
    async fn run_skill_script(&mut self, input: Value) -> ToolOutput;
    fn create_skill(&mut self, input: Value) -> ToolOutput;

    async fn spawn_subagent(&mut self, input: Value) -> ToolOutput;
}

pub struct ToolCtx<'a> {
    pub input: Arc<dyn InputPrompter>,
    pub security: SecurityConfig,
    pub web_client: reqwest::Client,
    pub runtime: &'a mut dyn ToolRuntime,
}

#[async_trait]
pub trait Tool: Send + Sync {
    fn name(&self) -> &'static str;
    fn description(&self) -> &'static str;
    fn schema(&self) -> Value;
    async fn call(&self, input: Value, ctx: &mut ToolCtx<'_>) -> Result<ToolOutput, ToolError>;
}

#[derive(Default)]
pub struct ToolRegistry {
    by_name: HashMap<String, Arc<dyn Tool>>,
}

impl ToolRegistry {
    pub fn builtins() -> Self {
        let mut registry = Self::default();
        registry.register(ProcessExecTool);
        registry.register(ReadFileTool);
        registry.register(WriteFileTool);
        registry.register(RequestInputTool);
        registry.register(WebSearchTool);
        registry.register(FetchUrlTool);
        registry.register(ReadMemoryTool);
        registry.register(WriteMemoryTool);
        registry.register(SearchMemoryTool);
        registry.register(StageMemoryTool);
        registry.register(ListStagedMemoryTool);
        registry.register(PromoteStagedMemoryTool);
        registry.register(RejectStagedMemoryTool);
        registry.register(ForgetMemoryTool);
        registry.register(ListSkillsTool);
        registry.register(InvokeSkillTool);
        registry.register(ReadReferenceTool);
        registry.register(RunSkillScriptTool);
        registry.register(CreateSkillTool);
        registry.register(SpawnSubagentTool);
        registry
    }

    pub fn register<T: Tool + 'static>(&mut self, tool: T) {
        self.by_name.insert(tool.name().into(), Arc::new(tool));
    }

    pub fn tool_names(&self) -> Vec<String> {
        let mut names = self.by_name.keys().cloned().collect::<Vec<_>>();
        names.sort();
        names
    }

    pub fn prompt_catalog(&self) -> String {
        let mut entries = self.by_name.values().collect::<Vec<_>>();
        entries.sort_by_key(|tool| tool.name());

        let mut catalog = String::new();
        for tool in entries {
            catalog.push_str("- ");
            catalog.push_str(tool.name());
            catalog.push_str(": ");
            catalog.push_str(tool.description());
            catalog.push_str("\n  schema: ");
            catalog.push_str(&tool.schema().to_string());
            catalog.push('\n');
        }
        catalog.trim_end().to_string()
    }

    pub fn lookup(&self, name: &str) -> Option<Arc<dyn Tool>> {
        self.by_name.get(name).cloned()
    }

    pub async fn dispatch(
        &self,
        invocation: ToolInvocation,
        ctx: &mut ToolCtx<'_>,
    ) -> Result<ToolOutput, ToolError> {
        let tool = self
            .by_name
            .get(&invocation.name)
            .ok_or_else(|| ToolError::NotFound(invocation.name.clone()))?;
        tool.call(invocation.input, ctx).await
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct ProcessExecInput {
    pub program: String,
    #[serde(default)]
    pub args: Option<Vec<String>>,
    #[serde(default)]
    pub cwd: Option<String>,
    #[serde(default)]
    pub timeout_s: Option<u64>,
}

struct ProcessExecTool;

#[async_trait]
impl Tool for ProcessExecTool {
    fn name(&self) -> &'static str {
        "process_exec"
    }

    fn description(&self) -> &'static str {
        "Run a direct subprocess without shell parsing"
    }

    fn schema(&self) -> Value {
        json!({
            "type": "object",
            "required": ["program"],
            "properties": {
                "program": {"type": "string"},
                "args": {"type": "array", "items": {"type": "string"}},
                "cwd": {"type": "string"},
                "timeout_s": {"type": "integer", "minimum": 1}
            }
        })
    }

    async fn call(&self, input: Value, _ctx: &mut ToolCtx<'_>) -> Result<ToolOutput, ToolError> {
        let parsed: ProcessExecInput =
            serde_json::from_value(input).map_err(|err| ToolError::Dispatch(err.to_string()))?;
        let mut command = Command::new(&parsed.program);
        command.args(parsed.args.unwrap_or_default());
        if let Some(cwd) = parsed.cwd {
            command.current_dir(cwd);
        }
        command.stdout(std::process::Stdio::piped());
        command.stderr(std::process::Stdio::piped());

        let timeout = Duration::from_secs(parsed.timeout_s.unwrap_or(30));
        let output = match tokio::time::timeout(timeout, command.output()).await {
            Ok(Ok(output)) => output,
            Ok(Err(err)) => {
                return Err(ToolError::Dispatch(format!(
                    "run {} failed: {err}",
                    parsed.program
                )))
            }
            Err(_) => {
                return Ok(ToolOutput {
                    content: format!("process timed out after {}s", timeout.as_secs()),
                    ok: false,
                });
            }
        };

        let mut content = String::new();
        if !output.stdout.is_empty() {
            content.push_str(&String::from_utf8_lossy(&output.stdout));
        }
        if !output.stderr.is_empty() {
            if !content.is_empty() {
                content.push('\n');
            }
            content.push_str(&String::from_utf8_lossy(&output.stderr));
        }
        if content.trim().is_empty() {
            content = if output.status.success() {
                "process completed with no output".into()
            } else {
                format!("process exited with status {}", output.status)
            };
        }

        Ok(ToolOutput {
            content,
            ok: output.status.success(),
        })
    }
}

#[derive(Debug, Deserialize)]
struct ReadFileInput {
    path: String,
    #[serde(default)]
    max_bytes: Option<usize>,
}

struct ReadFileTool;

#[async_trait]
impl Tool for ReadFileTool {
    fn name(&self) -> &'static str {
        "read_file"
    }

    fn description(&self) -> &'static str {
        "Read a UTF-8 text file under configured roots"
    }

    fn schema(&self) -> Value {
        json!({
            "type": "object",
            "required": ["path"],
            "properties": {
                "path": {"type": "string"},
                "max_bytes": {"type": "integer", "minimum": 1}
            }
        })
    }

    async fn call(&self, input: Value, ctx: &mut ToolCtx<'_>) -> Result<ToolOutput, ToolError> {
        let parsed: ReadFileInput =
            serde_json::from_value(input).map_err(|err| ToolError::Dispatch(err.to_string()))?;
        let path = sandbox::check(Path::new(&parsed.path), &ctx.security.fs_roots)
            .map_err(ToolError::Dispatch)?;
        let limit = parsed.max_bytes.unwrap_or(1_048_576).min(1_048_576);
        let bytes = tokio::fs::read(&path)
            .await
            .map_err(|err| ToolError::Dispatch(err.to_string()))?;
        let bytes = &bytes[..bytes.len().min(limit)];
        let content = std::str::from_utf8(bytes)
            .map_err(|_| ToolError::Dispatch("file is not valid UTF-8".into()))?
            .to_string();
        Ok(ToolOutput { content, ok: true })
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct WriteFileInput {
    pub path: String,
    pub content: String,
    #[serde(default)]
    pub create_dirs: Option<bool>,
}

struct WriteFileTool;

#[async_trait]
impl Tool for WriteFileTool {
    fn name(&self) -> &'static str {
        "write_file"
    }

    fn description(&self) -> &'static str {
        "Write a UTF-8 text file under configured roots"
    }

    fn schema(&self) -> Value {
        json!({
            "type": "object",
            "required": ["path", "content"],
            "properties": {
                "path": {"type": "string"},
                "content": {"type": "string"},
                "create_dirs": {"type": "boolean"}
            }
        })
    }

    async fn call(&self, input: Value, ctx: &mut ToolCtx<'_>) -> Result<ToolOutput, ToolError> {
        let parsed: WriteFileInput =
            serde_json::from_value(input).map_err(|err| ToolError::Dispatch(err.to_string()))?;
        let target = sandbox::check_write_target(Path::new(&parsed.path), &ctx.security.fs_roots)
            .map_err(ToolError::Dispatch)?;

        if parsed.create_dirs.unwrap_or(false) {
            if let Some(parent) = target.parent() {
                tokio::fs::create_dir_all(parent)
                    .await
                    .map_err(|err| ToolError::Dispatch(err.to_string()))?;
            }
        }

        tokio::fs::write(&target, parsed.content.as_bytes())
            .await
            .map_err(|err| ToolError::Dispatch(err.to_string()))?;
        Ok(ToolOutput {
            content: format!("wrote {}", target.display()),
            ok: true,
        })
    }
}

#[derive(Debug, Deserialize)]
struct RequestInputToolInput {
    prompt: String,
    #[serde(default = "default_allow_empty")]
    allow_empty: bool,
}

fn default_allow_empty() -> bool {
    true
}

struct RequestInputTool;

#[async_trait]
impl Tool for RequestInputTool {
    fn name(&self) -> &'static str {
        "request_input"
    }

    fn description(&self) -> &'static str {
        "Ask the frontend for more user input"
    }

    fn schema(&self) -> Value {
        json!({
            "type": "object",
            "required": ["prompt"],
            "properties": {
                "prompt": {"type": "string"},
                "allow_empty": {"type": "boolean"}
            }
        })
    }

    async fn call(&self, input: Value, ctx: &mut ToolCtx<'_>) -> Result<ToolOutput, ToolError> {
        let parsed: RequestInputToolInput =
            serde_json::from_value(input).map_err(|err| ToolError::Dispatch(err.to_string()))?;
        let response = ctx
            .input
            .request_input(InputRequest {
                prompt: parsed.prompt,
                allow_empty: parsed.allow_empty,
            })
            .await;

        Ok(match response {
            InputResponse::Submitted(value) => ToolOutput {
                content: value,
                ok: true,
            },
            InputResponse::Cancelled => ToolOutput {
                content: "input request cancelled".into(),
                ok: false,
            },
        })
    }
}

#[derive(Debug, Deserialize)]
struct WebSearchInput {
    query: String,
    #[serde(default)]
    record_as: Option<String>,
}

struct WebSearchTool;

#[async_trait]
impl Tool for WebSearchTool {
    fn name(&self) -> &'static str {
        "web_search"
    }

    fn description(&self) -> &'static str {
        "Run a simple DuckDuckGo HTML search"
    }

    fn schema(&self) -> Value {
        json!({
            "type": "object",
            "required": ["query"],
            "properties": {
                "query": {"type": "string"},
                "record_as": {"type": "string"}
            }
        })
    }

    async fn call(&self, input: Value, ctx: &mut ToolCtx<'_>) -> Result<ToolOutput, ToolError> {
        let parsed: WebSearchInput =
            serde_json::from_value(input).map_err(|err| ToolError::Dispatch(err.to_string()))?;
        let results = duckduckgo_search(
            &ctx.web_client,
            &parsed.query,
            Duration::from_secs(ctx.security.web.timeout_s),
        )
        .await?;
        let mut content = if results.is_empty() {
            "no results found".into()
        } else {
            render_duckduckgo_results(&results)
        };
        if let Some(record_as) = parsed
            .record_as
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
        {
            if let Some(top) = results.first() {
                if let Some(staged_note) = maybe_stage_research_capture(
                    ctx,
                    format!(
                        "# {}\n\n- source_url: {}\n- query: {}\n\n## Search results\n\n{}",
                        record_as,
                        top.url,
                        parsed.query,
                        render_duckduckgo_results(&results)
                    ),
                    record_as,
                    &top.url,
                    json!({
                        "source_url": top.url,
                        "query": parsed.query,
                        "fetched_at": time::OffsetDateTime::now_utc()
                            .format(&time::format_description::well_known::Rfc3339)
                            .unwrap_or_else(|_| "unknown".into())
                    }),
                )
                .await?
                {
                    content.push_str("\n\n");
                    content.push_str(&staged_note);
                }
            }
        }
        Ok(ToolOutput { content, ok: true })
    }
}

#[derive(Debug, Deserialize)]
struct FetchUrlInput {
    url: String,
    #[serde(default)]
    record_as: Option<String>,
}

struct FetchUrlTool;

#[async_trait]
impl Tool for FetchUrlTool {
    fn name(&self) -> &'static str {
        "fetch_url"
    }

    fn description(&self) -> &'static str {
        "Fetch a web page or text document over HTTP(S)"
    }

    fn schema(&self) -> Value {
        json!({
            "type": "object",
            "required": ["url"],
            "properties": {
                "url": {"type": "string", "format": "uri"},
                "record_as": {"type": "string"}
            }
        })
    }

    async fn call(&self, input: Value, ctx: &mut ToolCtx<'_>) -> Result<ToolOutput, ToolError> {
        let parsed: FetchUrlInput =
            serde_json::from_value(input).map_err(|err| ToolError::Dispatch(err.to_string()))?;
        let response = ctx
            .web_client
            .get(&parsed.url)
            .timeout(Duration::from_secs(ctx.security.web.timeout_s))
            .send()
            .await
            .map_err(|err| ToolError::Dispatch(err.to_string()))?;

        let status = response.status();
        if !status.is_success() {
            return Err(ToolError::Dispatch(format!(
                "fetch request failed with status {status}"
            )));
        }

        let body = response
            .text()
            .await
            .map_err(|err| ToolError::Dispatch(err.to_string()))?;
        let stripped = strip_html(&body);
        let mut content = stripped.clone();
        if let Some(record_as) = parsed
            .record_as
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
        {
            if let Some(staged_note) = maybe_stage_research_capture(
                ctx,
                format!(
                    "# {}\n\n- source_url: {}\n\n{}",
                    record_as, parsed.url, stripped
                ),
                record_as,
                &parsed.url,
                json!({
                    "source_url": parsed.url,
                    "fetched_at": time::OffsetDateTime::now_utc()
                        .format(&time::format_description::well_known::Rfc3339)
                        .unwrap_or_else(|_| "unknown".into())
                }),
            )
            .await?
            {
                content.push_str("\n\n");
                content.push_str(&staged_note);
            }
        }
        Ok(ToolOutput { content, ok: true })
    }
}

struct ReadMemoryTool;

#[async_trait]
impl Tool for ReadMemoryTool {
    fn name(&self) -> &'static str {
        "read_memory"
    }

    fn description(&self) -> &'static str {
        "Read a memory file relative to ~/.allbert/memory"
    }

    fn schema(&self) -> Value {
        json!({
            "type": "object",
            "required": ["path"],
            "properties": {
                "path": {"type": "string"}
            }
        })
    }

    async fn call(&self, input: Value, ctx: &mut ToolCtx<'_>) -> Result<ToolOutput, ToolError> {
        Ok(ctx.runtime.read_memory(input))
    }
}

struct WriteMemoryTool;

#[async_trait]
impl Tool for WriteMemoryTool {
    fn name(&self) -> &'static str {
        "write_memory"
    }

    fn description(&self) -> &'static str {
        "Write, append, or daily-append memory content"
    }

    fn schema(&self) -> Value {
        json!({
            "type": "object",
            "required": ["content", "mode"],
            "properties": {
                "path": {"type": "string"},
                "content": {"type": "string"},
                "mode": {"enum": ["write", "append", "daily"]},
                "summary": {"type": "string"}
            }
        })
    }

    async fn call(&self, input: Value, ctx: &mut ToolCtx<'_>) -> Result<ToolOutput, ToolError> {
        Ok(ctx.runtime.write_memory(input))
    }
}

struct SearchMemoryTool;

#[async_trait]
impl Tool for SearchMemoryTool {
    fn name(&self) -> &'static str {
        "search_memory"
    }

    fn description(&self) -> &'static str {
        "Search curated memory by query with optional tier filtering"
    }

    fn schema(&self) -> Value {
        json!({
            "type": "object",
            "required": ["query"],
            "properties": {
                "query": {"type": "string"},
                "tier": {"enum": ["durable", "staging", "episode", "fact", "all"]},
                "limit": {"type": "integer", "minimum": 1},
                "include_superseded": {"type": "boolean"}
            }
        })
    }

    async fn call(&self, input: Value, ctx: &mut ToolCtx<'_>) -> Result<ToolOutput, ToolError> {
        Ok(ctx.runtime.search_memory(input))
    }
}

struct StageMemoryTool;

#[async_trait]
impl Tool for StageMemoryTool {
    fn name(&self) -> &'static str {
        "stage_memory"
    }

    fn description(&self) -> &'static str {
        "Stage candidate durable memory for later operator review"
    }

    fn schema(&self) -> Value {
        json!({
            "type": "object",
            "required": ["content", "kind", "summary"],
            "properties": {
                "content": {"type": "string"},
                "kind": {"enum": ["explicit_request", "learned_fact", "job_summary", "subagent_result", "curator_extraction", "research"]},
                "summary": {"type": "string"},
                "tags": {"type": "array", "items": {"type": "string"}},
                "provenance": {},
                "facts": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "required": ["subject", "predicate", "object"],
                        "properties": {
                            "id": {"type": "string"},
                            "subject": {"type": "string"},
                            "predicate": {"type": "string"},
                            "object": {"type": "string"},
                            "valid_from": {"type": "string"},
                            "valid_until": {"type": "string"},
                            "supersedes": {"type": "array", "items": {"type": "string"}},
                            "source": {}
                        }
                    }
                }
            }
        })
    }

    async fn call(&self, input: Value, ctx: &mut ToolCtx<'_>) -> Result<ToolOutput, ToolError> {
        Ok(ctx.runtime.stage_memory(input).await)
    }
}

struct ListStagedMemoryTool;

#[async_trait]
impl Tool for ListStagedMemoryTool {
    fn name(&self) -> &'static str {
        "list_staged_memory"
    }

    fn description(&self) -> &'static str {
        "List staged memory entries awaiting review"
    }

    fn schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "kind": {"type": "string"},
                "limit": {"type": "integer", "minimum": 1}
            }
        })
    }

    async fn call(&self, input: Value, ctx: &mut ToolCtx<'_>) -> Result<ToolOutput, ToolError> {
        Ok(ctx.runtime.list_staged_memory(input))
    }
}

struct PromoteStagedMemoryTool;

#[async_trait]
impl Tool for PromoteStagedMemoryTool {
    fn name(&self) -> &'static str {
        "promote_staged_memory"
    }

    fn description(&self) -> &'static str {
        "Promote one staged entry into durable memory after confirmation"
    }

    fn schema(&self) -> Value {
        json!({
            "type": "object",
            "required": ["id"],
            "properties": {
                "id": {"type": "string"},
                "path": {"type": "string"},
                "summary": {"type": "string"}
            }
        })
    }

    async fn call(&self, input: Value, ctx: &mut ToolCtx<'_>) -> Result<ToolOutput, ToolError> {
        Ok(ctx.runtime.promote_staged_memory(input).await)
    }
}

struct RejectStagedMemoryTool;

#[async_trait]
impl Tool for RejectStagedMemoryTool {
    fn name(&self) -> &'static str {
        "reject_staged_memory"
    }

    fn description(&self) -> &'static str {
        "Reject one staged entry and move it into the rejection audit queue"
    }

    fn schema(&self) -> Value {
        json!({
            "type": "object",
            "required": ["id"],
            "properties": {
                "id": {"type": "string"},
                "reason": {"type": "string"}
            }
        })
    }

    async fn call(&self, input: Value, ctx: &mut ToolCtx<'_>) -> Result<ToolOutput, ToolError> {
        Ok(ctx.runtime.reject_staged_memory(input))
    }
}

struct ForgetMemoryTool;

#[async_trait]
impl Tool for ForgetMemoryTool {
    fn name(&self) -> &'static str {
        "forget_memory"
    }

    fn description(&self) -> &'static str {
        "Forget matching durable memory after confirmation"
    }

    fn schema(&self) -> Value {
        json!({
            "type": "object",
            "required": ["target"],
            "properties": {
                "target": {"type": "string"}
            }
        })
    }

    async fn call(&self, input: Value, ctx: &mut ToolCtx<'_>) -> Result<ToolOutput, ToolError> {
        Ok(ctx.runtime.forget_memory(input).await)
    }
}

struct ListSkillsTool;

#[async_trait]
impl Tool for ListSkillsTool {
    fn name(&self) -> &'static str {
        "list_skills"
    }

    fn description(&self) -> &'static str {
        "List installed skills and their descriptions"
    }

    fn schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {}
        })
    }

    async fn call(&self, input: Value, ctx: &mut ToolCtx<'_>) -> Result<ToolOutput, ToolError> {
        Ok(ctx.runtime.list_skills(input))
    }
}

struct InvokeSkillTool;

#[async_trait]
impl Tool for InvokeSkillTool {
    fn name(&self) -> &'static str {
        "invoke_skill"
    }

    fn description(&self) -> &'static str {
        "Activate a skill for this session, optionally with JSON args"
    }

    fn schema(&self) -> Value {
        json!({
            "type": "object",
            "required": ["name"],
            "properties": {
                "name": {"type": "string"},
                "args": {"type": "object"}
            }
        })
    }

    async fn call(&self, input: Value, ctx: &mut ToolCtx<'_>) -> Result<ToolOutput, ToolError> {
        Ok(ctx.runtime.invoke_skill(input))
    }
}

struct ReadReferenceTool;

#[async_trait]
impl Tool for ReadReferenceTool {
    fn name(&self) -> &'static str {
        "read_reference"
    }

    fn description(&self) -> &'static str {
        "Read an installed skill resource under references/ or assets/ on demand"
    }

    fn schema(&self) -> Value {
        json!({
            "type": "object",
            "required": ["skill", "path"],
            "properties": {
                "skill": {"type": "string"},
                "path": {"type": "string"},
                "max_bytes": {"type": "integer", "minimum": 1}
            }
        })
    }

    async fn call(&self, input: Value, ctx: &mut ToolCtx<'_>) -> Result<ToolOutput, ToolError> {
        Ok(ctx.runtime.read_reference(input))
    }
}

struct RunSkillScriptTool;

#[async_trait]
impl Tool for RunSkillScriptTool {
    fn name(&self) -> &'static str {
        "run_skill_script"
    }

    fn description(&self) -> &'static str {
        "Run a declared script from an active skill using its configured interpreter"
    }

    fn schema(&self) -> Value {
        json!({
            "type": "object",
            "required": ["skill", "script"],
            "properties": {
                "skill": {"type": "string"},
                "script": {"type": "string"},
                "args": {"type": "array", "items": {"type": "string"}},
                "timeout_s": {"type": "integer", "minimum": 1}
            }
        })
    }

    async fn call(&self, input: Value, ctx: &mut ToolCtx<'_>) -> Result<ToolOutput, ToolError> {
        Ok(ctx.runtime.run_skill_script(input).await)
    }
}

struct CreateSkillTool;

#[async_trait]
impl Tool for CreateSkillTool {
    fn name(&self) -> &'static str {
        "create_skill"
    }

    fn description(&self) -> &'static str {
        "Create a self-authored skill draft under ~/.allbert/skills/incoming/<name>/SKILL.md"
    }

    fn schema(&self) -> Value {
        json!({
            "type": "object",
            "required": ["name", "description", "skip_quarantine", "allowed_tools", "body"],
            "properties": {
                "name": {"type": "string"},
                "description": {"type": "string"},
                "skip_quarantine": {"type": "boolean"},
                "allowed_tools": {"type": "array", "items": {"type": "string"}},
                "body": {"type": "string"}
            }
        })
    }

    async fn call(&self, input: Value, ctx: &mut ToolCtx<'_>) -> Result<ToolOutput, ToolError> {
        Ok(ctx.runtime.create_skill(input))
    }
}

struct SpawnSubagentTool;

#[async_trait]
impl Tool for SpawnSubagentTool {
    fn name(&self) -> &'static str {
        "spawn_subagent"
    }

    fn description(&self) -> &'static str {
        "Run a bounded sub-agent with a fresh message history inside the current session"
    }

    fn schema(&self) -> Value {
        json!({
            "type": "object",
            "required": ["name", "prompt"],
            "properties": {
                "name": {"type": "string"},
                "prompt": {"type": "string"},
                "context": {},
                "memory_hints": {"type": "array", "items": {"type": "string"}}
            }
        })
    }

    async fn call(&self, input: Value, ctx: &mut ToolCtx<'_>) -> Result<ToolOutput, ToolError> {
        Ok(ctx.runtime.spawn_subagent(input).await)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct SearchResult {
    title: String,
    url: String,
}

async fn duckduckgo_search(
    client: &reqwest::Client,
    query: &str,
    timeout: Duration,
) -> Result<Vec<SearchResult>, ToolError> {
    duckduckgo_search_at(client, query, timeout, "https://html.duckduckgo.com/html/").await
}

async fn duckduckgo_search_at(
    client: &reqwest::Client,
    query: &str,
    timeout: Duration,
    base_url: &str,
) -> Result<Vec<SearchResult>, ToolError> {
    let mut url =
        reqwest::Url::parse(base_url).map_err(|err| ToolError::Dispatch(err.to_string()))?;
    url.query_pairs_mut().append_pair("q", query);

    let response = client
        .get(url)
        .timeout(timeout)
        .send()
        .await
        .map_err(|err| ToolError::Dispatch(err.to_string()))?;

    let status = response.status();
    if !status.is_success() {
        return Err(ToolError::Dispatch(format!(
            "search request failed with status {status}"
        )));
    }

    let body = response
        .text()
        .await
        .map_err(|err| ToolError::Dispatch(err.to_string()))?;
    Ok(extract_duckduckgo_results(&body))
}

async fn maybe_stage_research_capture(
    ctx: &mut ToolCtx<'_>,
    content: String,
    record_as: &str,
    source_url: &str,
    provenance: Value,
) -> Result<Option<String>, ToolError> {
    let staged = ctx
        .runtime
        .stage_memory(json!({
            "content": content,
            "kind": "research",
            "summary": record_as,
            "provenance": provenance,
            "fingerprint_basis": format!("{}\n{}", record_as.trim(), source_url.trim()),
        }))
        .await;
    if staged.ok {
        Ok(Some(format!(
            "[staged research memory from {}]",
            source_url.trim()
        )))
    } else {
        Ok(Some(format!(
            "[research memory not staged: {}]",
            staged.content.trim()
        )))
    }
}

fn render_duckduckgo_results(results: &[SearchResult]) -> String {
    results
        .iter()
        .map(|result| format!("- {} ({})", result.title.trim(), result.url.trim()))
        .collect::<Vec<_>>()
        .join("\n")
}

fn extract_duckduckgo_results(body: &str) -> Vec<SearchResult> {
    let mut results = Vec::new();
    let needle = "result__a";
    let mut search_start = 0;

    while let Some(class_idx) = body[search_start..].find(needle) {
        let start = search_start + class_idx;
        let href_marker = "href=\"";
        let Some(href_idx) = body[start..].find(href_marker) else {
            break;
        };
        let href_start = start + href_idx + href_marker.len();
        let Some(href_end_rel) = body[href_start..].find('"') else {
            break;
        };
        let href_end = href_start + href_end_rel;

        let title_start = body[href_end..]
            .find('>')
            .map(|offset| href_end + offset + 1);
        let Some(title_start) = title_start else {
            break;
        };
        let Some(title_end_rel) = body[title_start..].find("</a>") else {
            break;
        };
        let title_end = title_start + title_end_rel;
        let title = strip_html(&body[title_start..title_end]).replace('\n', " ");
        let href = html_unescape(&body[href_start..href_end]);
        results.push(SearchResult {
            title: title.trim().to_string(),
            url: href.trim().to_string(),
        });
        search_start = title_end;

        if results.len() >= 5 {
            break;
        }
    }

    results
}

fn strip_html(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    let mut in_tag = false;
    for ch in input.chars() {
        match ch {
            '<' => in_tag = true,
            '>' => in_tag = false,
            _ if !in_tag => out.push(ch),
            _ => {}
        }
    }
    html_unescape(&out)
}

fn html_unescape(input: &str) -> String {
    input
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
}

#[cfg(test)]
#[allow(clippy::field_reassign_with_default)]
mod tests {
    use super::*;
    use crate::config::WebSecurityConfig;
    use serde_json::json;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;

    struct NoInput;

    #[async_trait]
    impl InputPrompter for NoInput {
        async fn request_input(&self, _req: InputRequest) -> InputResponse {
            InputResponse::Cancelled
        }
    }

    #[derive(Default)]
    struct RecordingRuntime {
        staged: Vec<Value>,
    }

    #[async_trait]
    impl ToolRuntime for RecordingRuntime {
        fn read_memory(&mut self, _input: Value) -> ToolOutput {
            ToolOutput {
                content: String::new(),
                ok: true,
            }
        }
        fn write_memory(&mut self, _input: Value) -> ToolOutput {
            ToolOutput {
                content: String::new(),
                ok: true,
            }
        }
        fn search_memory(&mut self, _input: Value) -> ToolOutput {
            ToolOutput {
                content: String::new(),
                ok: true,
            }
        }
        async fn stage_memory(&mut self, input: Value) -> ToolOutput {
            self.staged.push(input);
            ToolOutput {
                content: "{\"id\":\"stg_test\"}".into(),
                ok: true,
            }
        }
        fn list_staged_memory(&mut self, _input: Value) -> ToolOutput {
            ToolOutput {
                content: String::new(),
                ok: true,
            }
        }
        async fn promote_staged_memory(&mut self, _input: Value) -> ToolOutput {
            ToolOutput {
                content: String::new(),
                ok: true,
            }
        }
        fn reject_staged_memory(&mut self, _input: Value) -> ToolOutput {
            ToolOutput {
                content: String::new(),
                ok: true,
            }
        }
        async fn forget_memory(&mut self, _input: Value) -> ToolOutput {
            ToolOutput {
                content: String::new(),
                ok: true,
            }
        }
        fn list_skills(&mut self, _input: Value) -> ToolOutput {
            ToolOutput {
                content: String::new(),
                ok: true,
            }
        }
        fn invoke_skill(&mut self, _input: Value) -> ToolOutput {
            ToolOutput {
                content: String::new(),
                ok: true,
            }
        }
        fn read_reference(&mut self, _input: Value) -> ToolOutput {
            ToolOutput {
                content: String::new(),
                ok: true,
            }
        }
        async fn run_skill_script(&mut self, _input: Value) -> ToolOutput {
            ToolOutput {
                content: String::new(),
                ok: true,
            }
        }
        fn create_skill(&mut self, _input: Value) -> ToolOutput {
            ToolOutput {
                content: String::new(),
                ok: true,
            }
        }
        async fn spawn_subagent(&mut self, _input: Value) -> ToolOutput {
            ToolOutput {
                content: String::new(),
                ok: true,
            }
        }
    }

    async fn serve_once(body: &'static str, content_type: &'static str) -> String {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut buffer = [0_u8; 2048];
            let _ = stream.read(&mut buffer).await;
            let response = format!(
                "HTTP/1.1 200 OK\r\ncontent-length: {}\r\ncontent-type: {}\r\nconnection: close\r\n\r\n{}",
                body.len(),
                content_type,
                body
            );
            stream.write_all(response.as_bytes()).await.unwrap();
        });
        format!("http://{}", addr)
    }

    fn test_security() -> SecurityConfig {
        let mut security = SecurityConfig::default();
        security.web = WebSecurityConfig::default();
        security
    }

    #[tokio::test]
    async fn duckduckgo_search_at_extracts_results() {
        let base = serve_once(
            r#"<html><body><a class="result__a" href="https://example.com/one">One</a><a class="result__a" href="https://example.com/two">Two</a></body></html>"#,
            "text/html",
        )
        .await;
        let client = reqwest::Client::new();
        let results = duckduckgo_search_at(
            &client,
            "example",
            Duration::from_secs(5),
            &format!("{}/html/", base),
        )
        .await
        .unwrap();
        assert_eq!(results.len(), 2);
        assert_eq!(results[0].url, "https://example.com/one");
    }

    #[tokio::test]
    async fn fetch_url_record_as_stages_research_memory() {
        let base = serve_once(
            "<html><body><h1>Guide</h1><p>Useful details.</p></body></html>",
            "text/html",
        )
        .await;
        let mut runtime = RecordingRuntime::default();
        let mut ctx = ToolCtx {
            input: Arc::new(NoInput),
            security: test_security(),
            web_client: reqwest::Client::new(),
            runtime: &mut runtime,
        };
        let output = FetchUrlTool
            .call(
                json!({
                    "url": base,
                    "record_as": "Useful guide summary"
                }),
                &mut ctx,
            )
            .await
            .unwrap();
        assert!(output.ok);
        assert!(output.content.contains("Useful details."));
        assert!(output.content.contains("[staged research memory"));
        assert_eq!(runtime.staged.len(), 1);
        assert_eq!(runtime.staged[0]["kind"], "research");
        assert_eq!(runtime.staged[0]["summary"], "Useful guide summary");
        assert_eq!(runtime.staged[0]["provenance"]["source_url"], base);
        assert!(runtime.staged[0]["fingerprint_basis"]
            .as_str()
            .unwrap()
            .contains("Useful guide summary"));
    }

    #[tokio::test]
    async fn web_search_record_as_stages_research_memory() {
        let base = serve_once(
            r#"<html><body><a class="result__a" href="https://example.com/postgres">Postgres defaults</a></body></html>"#,
            "text/html",
        )
        .await;
        let mut runtime = RecordingRuntime::default();
        let results = duckduckgo_search_at(
            &reqwest::Client::new(),
            "postgres defaults",
            Duration::from_secs(5),
            &format!("{}/html/", base),
        )
        .await
        .unwrap();
        let mut ctx = ToolCtx {
            input: Arc::new(NoInput),
            security: test_security(),
            web_client: reqwest::Client::new(),
            runtime: &mut runtime,
        };
        let note = maybe_stage_research_capture(
            &mut ctx,
            format!(
                "# {}\n\n- source_url: {}\n- query: {}\n\n## Search results\n\n{}",
                "Postgres defaults",
                results[0].url,
                "postgres defaults",
                render_duckduckgo_results(&results)
            ),
            "Postgres defaults",
            &results[0].url,
            json!({
                "source_url": results[0].url,
                "query": "postgres defaults",
                "fetched_at": "2026-04-20T00:00:00Z"
            }),
        )
        .await
        .unwrap();
        assert_eq!(
            note.as_deref(),
            Some("[staged research memory from https://example.com/postgres]")
        );
        assert_eq!(runtime.staged.len(), 1);
        assert_eq!(runtime.staged[0]["kind"], "research");
        assert_eq!(
            runtime.staged[0]["provenance"]["query"],
            "postgres defaults"
        );
    }
}
