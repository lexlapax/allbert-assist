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
                "query": {"type": "string"}
            }
        })
    }

    async fn call(&self, input: Value, ctx: &mut ToolCtx<'_>) -> Result<ToolOutput, ToolError> {
        let parsed: WebSearchInput =
            serde_json::from_value(input).map_err(|err| ToolError::Dispatch(err.to_string()))?;
        let mut url = reqwest::Url::parse("https://html.duckduckgo.com/html/")
            .map_err(|err| ToolError::Dispatch(err.to_string()))?;
        url.query_pairs_mut().append_pair("q", &parsed.query);

        let response = ctx
            .web_client
            .get(url)
            .timeout(Duration::from_secs(ctx.security.web.timeout_s))
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
        let results = extract_duckduckgo_results(&body);
        Ok(ToolOutput {
            content: if results.is_empty() {
                "no results found".into()
            } else {
                results.join("\n")
            },
            ok: true,
        })
    }
}

#[derive(Debug, Deserialize)]
struct FetchUrlInput {
    url: String,
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
                "url": {"type": "string", "format": "uri"}
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
        Ok(ToolOutput {
            content: strip_html(&body),
            ok: true,
        })
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
                "tier": {"enum": ["durable", "staging", "all"]},
                "limit": {"type": "integer", "minimum": 1}
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
                "kind": {"enum": ["explicit_request", "learned_fact", "job_summary", "subagent_result", "curator_extraction"]},
                "summary": {"type": "string"},
                "tags": {"type": "array", "items": {"type": "string"}},
                "provenance": {}
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
        "Create a skill under ~/.allbert/skills/installed/<name>/SKILL.md"
    }

    fn schema(&self) -> Value {
        json!({
            "type": "object",
            "required": ["name", "description", "allowed_tools", "body"],
            "properties": {
                "name": {"type": "string"},
                "description": {"type": "string"},
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

fn extract_duckduckgo_results(body: &str) -> Vec<String> {
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
        results.push(format!("- {} ({})", title.trim(), href.trim()));
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
