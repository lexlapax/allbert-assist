use allbert_kernel_core::llm::{
    CompletionRequest, CompletionResponse, CompletionResponseFormat, LlmProvider,
};
use allbert_kernel_core::memory::{
    MemoryTier, ReadMemoryInput, SearchMemoryInput, StageMemoryInput, WriteMemoryInput,
};
use allbert_kernel_core::{
    exec_policy, AllbertPaths, Config, KernelError, ModelConfig, NormalizedExec, PolicyDecision,
    ProcessExecInput, Provider, ToolInvocation, ToolOutput, ToolRegistry,
};

#[test]
fn representative_core_imports_compile() {
    let _paths = AllbertPaths::under(std::env::temp_dir().join("allbert-core-imports"));
    let config = Config::default_template();
    let _model = ModelConfig {
        provider: Provider::Ollama,
        model_id: "gemma4".into(),
        api_key_env: None,
        base_url: None,
        max_tokens: 1024,
        context_window_tokens: 8192,
    };
    let _request = CompletionRequest {
        model: config.model.model_id.clone(),
        system: Some("system".into()),
        messages: Vec::new(),
        max_tokens: 1,
        tools: Vec::new(),
        response_format: CompletionResponseFormat::Text,
        temperature: None,
    };
    let _response: Option<CompletionResponse> = None;
    let _provider: Option<&dyn LlmProvider> = None;
    let _memory_tier = MemoryTier::Durable;
    let _read: Option<ReadMemoryInput> = None;
    let _write: Option<WriteMemoryInput> = None;
    let _search: Option<SearchMemoryInput> = None;
    let _stage: Option<StageMemoryInput> = None;
    let _process: Option<ProcessExecInput> = None;
    let _invocation = ToolInvocation {
        name: "process_exec".into(),
        input: serde_json::json!({}),
    };
    let _output = ToolOutput {
        content: String::new(),
        ok: true,
    };
    let registry = ToolRegistry::with_names(["process_exec"]);
    assert!(registry.contains("process_exec"));

    let normalized = NormalizedExec {
        program: "true".into(),
        args: Vec::new(),
        cwd: None,
    };
    match exec_policy(&normalized, &config.security, &Default::default()) {
        PolicyDecision::Deny(_) | PolicyDecision::AutoAllow | PolicyDecision::NeedsConfirm(_) => {}
    }

    let _error: Option<KernelError> = None;
}
