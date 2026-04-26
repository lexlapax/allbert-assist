use allbert_kernel::{
    list_diagnosis_reports, read_diagnosis_report, run_diagnosis_report,
    run_diagnosis_report_with_remediation, AllbertPaths, Config, DiagnosisRemediationKind,
    DiagnosisRemediationRequest, DiagnosisReportSummary, TraceReader,
};
use anyhow::{anyhow, bail, Result};
use clap::{Subcommand, ValueEnum};

#[derive(Subcommand, Debug)]
#[command(
    after_long_help = "EXAMPLES:\n  allbert-cli diagnose run\n  allbert-cli diagnose run --session repl-primary --json\n  allbert-cli diagnose list --offline\n  allbert-cli diagnose show diag_20260426T000000Z_12345678\n"
)]
pub enum DiagnoseCommand {
    /// Create a bounded diagnosis report from trace artifacts.
    Run {
        #[arg(long)]
        session: Option<String>,
        #[arg(long)]
        lookback_days: Option<u16>,
        #[arg(long)]
        remediate: Option<DiagnoseRemediationArg>,
        #[arg(long)]
        reason: Option<String>,
        #[arg(long)]
        json: bool,
    },
    /// List diagnosis reports.
    List {
        #[arg(long)]
        session: Option<String>,
        #[arg(long)]
        offline: bool,
        #[arg(long)]
        json: bool,
    },
    /// Show one diagnosis report.
    Show {
        diagnosis_id: String,
        #[arg(long)]
        offline: bool,
        #[arg(long)]
        json: bool,
    },
}

#[derive(Clone, Debug, ValueEnum)]
pub enum DiagnoseRemediationArg {
    Code,
    Skill,
    Memory,
}

impl From<DiagnoseRemediationArg> for DiagnosisRemediationKind {
    fn from(value: DiagnoseRemediationArg) -> Self {
        match value {
            DiagnoseRemediationArg::Code => Self::Code,
            DiagnoseRemediationArg::Skill => Self::Skill,
            DiagnoseRemediationArg::Memory => Self::Memory,
        }
    }
}

pub fn run(paths: &AllbertPaths, config: &Config, command: DiagnoseCommand) -> Result<()> {
    match command {
        DiagnoseCommand::Run {
            session,
            lookback_days,
            remediate,
            reason,
            json,
        } => {
            println!(
                "{}",
                run_report(
                    paths,
                    config,
                    session,
                    lookback_days,
                    remediate,
                    reason,
                    json
                )?
            );
        }
        DiagnoseCommand::List {
            session,
            offline,
            json,
        } => {
            println!(
                "{}",
                list_reports(paths, session.as_deref(), offline, json)?
            );
        }
        DiagnoseCommand::Show {
            diagnosis_id,
            offline,
            json,
        } => {
            println!("{}", show_report(paths, &diagnosis_id, offline, json)?);
        }
    }
    Ok(())
}

pub fn run_report(
    paths: &AllbertPaths,
    config: &Config,
    session: Option<String>,
    lookback_days: Option<u16>,
    remediate: Option<DiagnoseRemediationArg>,
    reason: Option<String>,
    json: bool,
) -> Result<String> {
    let active_session_id = resolve_active_session(paths, session.as_deref())?;
    let artifact = match (remediate, reason) {
        (Some(kind), Some(reason)) if !reason.trim().is_empty() => {
            run_diagnosis_report_with_remediation(
                paths,
                config,
                &active_session_id,
                session.as_deref(),
                lookback_days,
                DiagnosisRemediationRequest {
                    kind: kind.into(),
                    reason,
                },
            )?
        }
        (Some(_), _) => bail!("diagnosis remediation requires --reason <text>"),
        (None, Some(reason)) if !reason.trim().is_empty() => {
            bail!("--reason requires --remediate <code|skill|memory>")
        }
        _ => run_diagnosis_report(
            paths,
            &config.self_diagnosis,
            &active_session_id,
            session.as_deref(),
            lookback_days,
        )?,
    };
    if json {
        return Ok(serde_json::to_string_pretty(&artifact.summary)?);
    }
    Ok(render_run_summary(&artifact.summary))
}

pub fn list_reports(
    paths: &AllbertPaths,
    session: Option<&str>,
    offline: bool,
    json: bool,
) -> Result<String> {
    let entries = list_diagnosis_reports(paths, session)?;
    if json {
        let summaries = entries
            .iter()
            .map(|entry| &entry.summary)
            .collect::<Vec<_>>();
        return Ok(serde_json::to_string_pretty(&summaries)?);
    }
    let mut rendered = render_report_list(
        &entries
            .iter()
            .map(|entry| &entry.summary)
            .collect::<Vec<_>>(),
    );
    if offline {
        rendered = format!("offline diagnosis reports\n{rendered}");
    }
    Ok(rendered)
}

pub fn show_report(
    paths: &AllbertPaths,
    diagnosis_id: &str,
    offline: bool,
    json: bool,
) -> Result<String> {
    let artifact = read_diagnosis_report(paths, diagnosis_id)?;
    if json {
        return Ok(serde_json::to_string_pretty(&artifact.summary)?);
    }
    if offline {
        Ok(format!(
            "offline diagnosis report\n\n{}",
            artifact.report_markdown
        ))
    } else {
        Ok(artifact.report_markdown)
    }
}

fn resolve_active_session(paths: &AllbertPaths, session: Option<&str>) -> Result<String> {
    if let Some(session) = session {
        return Ok(session.to_string());
    }
    TraceReader::new(paths.clone())
        .latest_session_id()?
        .ok_or_else(|| anyhow!("no trace sessions found; pass --session after creating a trace"))
}

fn render_run_summary(summary: &DiagnosisReportSummary) -> String {
    let mut rendered = format!(
        "diagnosis report written\nid:             {}\nsession:        {}\nclassification: {} ({:.2})\nreport:         {}\nsummary:        {}/bundle.summary.json",
        summary.diagnosis_id,
        summary.session_id,
        summary.classification.label(),
        summary.confidence,
        summary.report_path,
        summary
            .report_path
            .trim_end_matches("/report.md")
    );
    if let Some(remediation) = &summary.remediation {
        rendered.push_str(&format!(
            "\nremediation:    {} ({:?})\nnext:           {}",
            remediation.kind, remediation.status, remediation.message
        ));
    }
    rendered
}

fn render_report_list(summaries: &[&DiagnosisReportSummary]) -> String {
    if summaries.is_empty() {
        return "no diagnosis reports".into();
    }
    let mut lines = vec!["diagnosis reports:".to_string()];
    for summary in summaries {
        lines.push(format!(
            "- {}  session={} classification={} confidence={:.2} report={}",
            summary.diagnosis_id,
            summary.session_id,
            summary.classification.label(),
            summary.confidence,
            summary.report_path
        ));
    }
    lines.join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;
    use allbert_kernel::{AllbertPaths, JsonlTraceWriter, TraceStorageLimits, TraceWriter};
    use allbert_proto::{Span, SpanKind, SpanStatus};
    use chrono::Utc;
    use std::collections::BTreeMap;

    fn temp_paths(name: &str) -> AllbertPaths {
        let unique = format!(
            "allbert-diagnose-cli-{name}-{}-{}",
            std::process::id(),
            chrono::Utc::now().timestamp_nanos_opt().unwrap_or_default()
        );
        let path = std::env::temp_dir().join(unique);
        let paths = AllbertPaths::under(path);
        paths.ensure().expect("paths");
        paths
    }

    fn write_fixture_trace(paths: &AllbertPaths, session: &str) {
        let writer = JsonlTraceWriter::new(paths, session, TraceStorageLimits::default()).unwrap();
        writer
            .span_ended(&Span {
                id: "span-a".into(),
                parent_id: None,
                session_id: session.into(),
                trace_id: "trace-a".into(),
                name: "provider call".into(),
                kind: SpanKind::Client,
                started_at: Utc::now(),
                ended_at: Some(Utc::now()),
                duration_ms: Some(42),
                status: SpanStatus::Error {
                    message: "provider timeout".into(),
                },
                attributes: BTreeMap::new(),
                events: Vec::new(),
            })
            .unwrap();
    }

    #[test]
    fn diagnose_run_writes_report_and_summary() {
        let paths = temp_paths("run");
        write_fixture_trace(&paths, "session-a");
        let output = run_report(
            &paths,
            &Config::default_template(),
            Some("session-a".into()),
            None,
            None,
            None,
            false,
        )
        .unwrap();
        assert!(output.contains("diagnosis report written"));
        let reports = list_diagnosis_reports(&paths, Some("session-a")).unwrap();
        assert_eq!(reports.len(), 1);
        assert!(std::path::Path::new(&reports[0].summary.report_path).exists());
    }

    #[test]
    fn list_and_show_render_existing_reports() {
        let paths = temp_paths("show");
        write_fixture_trace(&paths, "session-a");
        run_report(
            &paths,
            &Config::default_template(),
            Some("session-a".into()),
            None,
            None,
            None,
            false,
        )
        .unwrap();
        let listed = list_reports(&paths, Some("session-a"), true, false).unwrap();
        assert!(listed.contains("offline diagnosis reports"));
        let id = list_diagnosis_reports(&paths, Some("session-a")).unwrap()[0]
            .summary
            .diagnosis_id
            .clone();
        let shown = show_report(&paths, &id, true, false).unwrap();
        assert!(shown.contains("## Summary"));
        assert!(shown.contains("## Remediation Status"));
    }

    #[test]
    fn memory_remediation_stages_candidate_only() {
        let paths = temp_paths("memory-remediation");
        write_fixture_trace(&paths, "session-a");
        let mut config = Config::default_template();
        config.self_diagnosis.allow_remediation = true;
        let output = run_report(
            &paths,
            &config,
            Some("session-a".into()),
            None,
            Some(DiagnoseRemediationArg::Memory),
            Some("Remember the stable fix.".into()),
            false,
        )
        .unwrap();
        assert!(output.contains("remediation:    memory"));
        let staged =
            allbert_kernel::memory::list_staged_memory(&paths, &config.memory, None, None, None)
                .unwrap();
        assert_eq!(staged.len(), 1);
        assert_eq!(staged[0].kind, "explicit_request");
    }

    #[test]
    fn skill_remediation_creates_quarantined_self_diagnosed_skill() {
        let paths = temp_paths("skill-remediation");
        write_fixture_trace(&paths, "session-a");
        let mut config = Config::default_template();
        config.self_diagnosis.allow_remediation = true;
        let output = run_report(
            &paths,
            &config,
            Some("session-a".into()),
            None,
            Some(DiagnoseRemediationArg::Skill),
            Some("Draft a repeatable diagnostic helper.".into()),
            false,
        )
        .unwrap();
        assert!(output.contains("remediation:    skill"));
        let incoming = std::fs::read_dir(&paths.skills_incoming)
            .unwrap()
            .filter_map(|entry| entry.ok())
            .map(|entry| entry.path().join("SKILL.md"))
            .find(|path| path.exists())
            .expect("incoming skill should exist");
        let skill = std::fs::read_to_string(incoming).unwrap();
        assert!(skill.contains("provenance: self-diagnosed"));
    }

    #[test]
    fn remediation_requires_opt_in_and_reason() {
        let paths = temp_paths("remediation-gates");
        write_fixture_trace(&paths, "session-a");
        let err = run_report(
            &paths,
            &Config::default_template(),
            Some("session-a".into()),
            None,
            Some(DiagnoseRemediationArg::Memory),
            Some("Remember this.".into()),
            false,
        )
        .unwrap_err();
        assert!(err.to_string().contains("allow_remediation"));

        let mut config = Config::default_template();
        config.self_diagnosis.allow_remediation = true;
        let err = run_report(
            &paths,
            &config,
            Some("session-a".into()),
            None,
            Some(DiagnoseRemediationArg::Memory),
            Some(" ".into()),
            false,
        )
        .unwrap_err();
        assert!(err.to_string().contains("--reason"));
    }
}
