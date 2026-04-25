use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use allbert_daemon::{DaemonClient, DaemonError};
use allbert_kernel::{
    apply_trace_gc, export_session_otlp_json, plan_trace_gc, AllbertPaths, Config, TraceReader,
};
use allbert_proto::{
    AttributeValue, ClientKind, ServerMessage, Span, SpanStatus, TraceSessionSummary,
};
use anyhow::{Context, Result};

pub fn show(paths: &AllbertPaths, session: Option<&str>) -> Result<String> {
    let reader = TraceReader::new(paths.clone());
    let Some(session_id) = resolve_session(&reader, session)? else {
        return Ok("no trace sessions".into());
    };
    let result = reader.read_session(&session_id)?;
    Ok(render_span_tree(
        &session_id,
        &result.spans,
        result.warnings.len(),
    ))
}

pub fn list(paths: &AllbertPaths, limit: usize) -> Result<String> {
    let reader = TraceReader::new(paths.clone());
    let mut summaries = reader.list_sessions()?;
    summaries.truncate(limit);
    Ok(render_session_summaries(&summaries))
}

pub fn show_span(paths: &AllbertPaths, session: Option<&str>, span_id: &str) -> Result<String> {
    let reader = TraceReader::new(paths.clone());
    let span = reader
        .find_span(session, span_id)?
        .ok_or_else(|| anyhow::anyhow!("trace span not found: {span_id}"))?;
    Ok(render_span_detail(&span))
}

pub fn export(
    paths: &AllbertPaths,
    config: &Config,
    session: &str,
    format: &str,
    out: Option<&Path>,
) -> Result<String> {
    if format != "otlp-json" {
        anyhow::bail!("unsupported trace export format `{format}`; supported: otlp-json");
    }
    let output = export_session_otlp_json(paths, &config.trace, session, out)?;
    Ok(format!(
        "exported trace session {session}\nformat: otlp-json\npath: {}",
        output.display()
    ))
}

pub fn gc(paths: &AllbertPaths, config: &Config, dry_run: bool) -> Result<String> {
    let plan = plan_trace_gc(
        paths,
        config.trace.retention_days,
        config.trace.total_disk_cap_mb,
    )?;
    if dry_run {
        return Ok(render_gc_plan(&plan, true, 0, 0));
    }
    let result = apply_trace_gc(&plan)?;
    Ok(render_gc_plan(
        &plan,
        false,
        result.removed,
        result.freed_bytes,
    ))
}

pub async fn tail(paths: &AllbertPaths, session: Option<String>) -> Result<()> {
    let mut client = DaemonClient::connect(paths, ClientKind::Cli)
        .await
        .map_err(map_tail_connect_error)?;
    let session_id = client
        .trace_subscribe(session)
        .await
        .context("subscribe to trace stream")?;
    println!("tailing trace session {session_id}; press Ctrl-C to stop");
    loop {
        tokio::select! {
            _ = tokio::signal::ctrl_c() => {
                let _ = client.trace_unsubscribe(Some(session_id)).await;
                return Ok(());
            }
            message = client.recv() => {
                match message? {
                    ServerMessage::TraceSpan(span) => {
                        println!("{}", render_span_compact(&span));
                    }
                    ServerMessage::Error(error) => anyhow::bail!("{}", error.message),
                    _ => {}
                }
            }
        }
    }
}

fn map_tail_connect_error(error: DaemonError) -> anyhow::Error {
    match error {
        DaemonError::VersionMismatch { .. } => anyhow::anyhow!(
            "trace tail requires a v0.12.2 daemon; upgrade or restart the daemon, then retry"
        ),
        other => anyhow::anyhow!(
            "trace tail requires a running compatible daemon. Start it with `allbert-cli daemon start`.\nunderlying error: {other}"
        ),
    }
}

fn resolve_session(reader: &TraceReader, session: Option<&str>) -> Result<Option<String>> {
    match session {
        Some(session) => Ok(Some(session.to_string())),
        None => Ok(reader.latest_session_id()?),
    }
}

fn render_session_summaries(summaries: &[TraceSessionSummary]) -> String {
    if summaries.is_empty() {
        return "no trace sessions".into();
    }
    let mut lines = vec!["trace sessions:".to_string()];
    for summary in summaries {
        lines.push(format!(
            "- {}  spans={} roots={} duration={} bytes={} last_touched={} rotated={} truncated={}",
            summary.session_id,
            summary.span_count,
            summary.root_span_count,
            render_duration(summary.total_duration_ms),
            render_bytes(summary.bytes),
            summary.last_touched_at,
            yes_no(summary.has_rotated_archives),
            summary.truncated_count
        ));
    }
    lines.join("\n")
}

pub fn render_span_tree(session_id: &str, spans: &[Span], warning_count: usize) -> String {
    if spans.is_empty() {
        return format!("trace session {session_id}: no spans");
    }
    let mut children: BTreeMap<Option<String>, Vec<&Span>> = BTreeMap::new();
    for span in spans {
        children
            .entry(span.parent_id.clone())
            .or_default()
            .push(span);
    }
    let mut lines = vec![format!(
        "trace session {session_id}: {} span(s)",
        spans.len()
    )];
    if warning_count > 0 {
        lines.push(format!(
            "warnings: {warning_count} malformed record(s) skipped"
        ));
    }
    if let Some(roots) = children.get(&None).cloned() {
        for span in roots {
            render_span_node(span, &children, 0, &mut lines);
        }
    }
    lines.join("\n")
}

fn render_span_node(
    span: &Span,
    children: &BTreeMap<Option<String>, Vec<&Span>>,
    depth: usize,
    lines: &mut Vec<String>,
) {
    lines.push(format!(
        "{}- {} [{}] {} {}",
        "  ".repeat(depth),
        span.name,
        span.id,
        render_span_status(&span.status),
        span.duration_ms
            .map(render_duration)
            .unwrap_or_else(|| "open".into())
    ));
    if let Some(child_spans) = children.get(&Some(span.id.clone())).cloned() {
        for child in child_spans {
            render_span_node(child, children, depth + 1, lines);
        }
    }
}

pub fn render_span_detail(span: &Span) -> String {
    let mut lines = vec![
        format!("span:       {}", span.id),
        format!("name:       {}", span.name),
        format!("session:    {}", span.session_id),
        format!("trace:      {}", span.trace_id),
        format!(
            "parent:     {}",
            span.parent_id.as_deref().unwrap_or("(none)")
        ),
        format!("kind:       {:?}", span.kind),
        format!("status:     {}", render_span_status(&span.status)),
        format!("started:    {}", span.started_at),
        format!(
            "ended:      {}",
            span.ended_at
                .map(|value| value.to_string())
                .unwrap_or_else(|| "(open)".into())
        ),
        format!(
            "duration:   {}",
            span.duration_ms
                .map(render_duration)
                .unwrap_or_else(|| "(open)".into())
        ),
    ];
    if !span.attributes.is_empty() {
        lines.push("attributes:".into());
        for (key, value) in &span.attributes {
            lines.push(format!("  {key}: {}", render_attribute_value(value)));
        }
    }
    if !span.events.is_empty() {
        lines.push("events:".into());
        for event in &span.events {
            lines.push(format!("  - {} at {}", event.name, event.timestamp));
            for (key, value) in &event.attributes {
                lines.push(format!("      {key}: {}", render_attribute_value(value)));
            }
        }
    }
    lines.join("\n")
}

pub fn render_span_compact(span: &Span) -> String {
    format!(
        "{} [{}] {} {}",
        span.name,
        span.id,
        render_span_status(&span.status),
        span.duration_ms
            .map(render_duration)
            .unwrap_or_else(|| "open".into())
    )
}

fn render_span_status(status: &SpanStatus) -> String {
    match status {
        SpanStatus::Ok => "ok".into(),
        SpanStatus::Error { message } => format!("error({message})"),
    }
}

fn render_attribute_value(value: &AttributeValue) -> String {
    match value {
        AttributeValue::String(value) => value.clone(),
        AttributeValue::Int(value) => value.to_string(),
        AttributeValue::Float(value) => value.to_string(),
        AttributeValue::Bool(value) => yes_no(*value).into(),
        AttributeValue::StringArray(values) => values.join(", "),
        AttributeValue::IntArray(values) => values
            .iter()
            .map(|value| value.to_string())
            .collect::<Vec<_>>()
            .join(", "),
    }
}

fn render_gc_plan(
    plan: &allbert_kernel::TraceGcPlan,
    dry_run: bool,
    removed: usize,
    freed_bytes: u64,
) -> String {
    if plan.candidates.is_empty() {
        return format!(
            "trace gc: nothing to remove\ntotal: {} / cap {}",
            render_bytes(plan.total_bytes),
            render_bytes(plan.cap_bytes)
        );
    }
    let mut lines = vec![format!(
        "trace gc: {}{} artifact(s), {}",
        if dry_run { "would remove " } else { "removed " },
        if dry_run {
            plan.candidates.len()
        } else {
            removed
        },
        if dry_run {
            render_bytes(
                plan.candidates
                    .iter()
                    .map(|candidate| candidate.bytes)
                    .sum(),
            )
        } else {
            render_bytes(freed_bytes)
        }
    )];
    for candidate in &plan.candidates {
        lines.push(format!(
            "- {}  {}  {}  {}",
            candidate.session_id,
            render_bytes(candidate.bytes),
            candidate.reason,
            candidate.path.display()
        ));
    }
    lines.join("\n")
}

fn render_duration(ms: u64) -> String {
    if ms >= 60_000 {
        format!("{:.1}s", ms as f64 / 1000.0)
    } else if ms >= 1000 {
        format!("{:.2}s", ms as f64 / 1000.0)
    } else {
        format!("{ms}ms")
    }
}

fn render_bytes(bytes: u64) -> String {
    if bytes >= 1024 * 1024 {
        format!("{:.1} MiB", bytes as f64 / (1024.0 * 1024.0))
    } else if bytes >= 1024 {
        format!("{:.1} KiB", bytes as f64 / 1024.0)
    } else {
        format!("{bytes} B")
    }
}

fn yes_no(value: bool) -> &'static str {
    if value {
        "yes"
    } else {
        "no"
    }
}

pub fn output_path(raw: Option<String>) -> Option<PathBuf> {
    raw.map(PathBuf::from)
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use allbert_proto::{SpanKind, SpanStatus};
    use chrono::{DateTime, Utc};

    use super::*;

    fn ts(seconds: i64) -> DateTime<Utc> {
        DateTime::from_timestamp(seconds, 0).expect("timestamp")
    }

    fn span(id: &str, parent_id: Option<&str>, name: &str, started_at: i64) -> Span {
        Span {
            id: id.into(),
            parent_id: parent_id.map(str::to_string),
            session_id: "repl-primary".into(),
            trace_id: "11111111111111111111111111111111".into(),
            name: name.into(),
            kind: SpanKind::Internal,
            started_at: ts(started_at),
            ended_at: Some(ts(started_at + 1)),
            duration_ms: Some(1000),
            status: SpanStatus::Ok,
            attributes: BTreeMap::new(),
            events: Vec::new(),
        }
    }

    #[test]
    fn span_tree_renders_parent_child_shape() {
        let spans = vec![
            span("1111111111111111", None, "turn", 1),
            span("2222222222222222", Some("1111111111111111"), "chat", 2),
        ];
        let rendered = render_span_tree("repl-primary", &spans, 0);
        assert!(rendered.contains("trace session repl-primary: 2 span(s)"));
        assert!(rendered.contains("- turn [1111111111111111] ok 1.00s"));
        assert!(rendered.contains("  - chat [2222222222222222] ok 1.00s"));
    }
}
