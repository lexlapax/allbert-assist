use allbert_kernel_services::{
    rag_doctor, rag_gc, rag_status, rebuild_rag_index, search_rag, AllbertPaths, Config,
    RagIndexRunStatus, RagRebuildRequest, RagRetrievalMode, RagSearchRequest, RagSourceKind,
};
use anyhow::{anyhow, Result};
use clap::Subcommand;

#[derive(Subcommand, Debug)]
pub enum RagCommand {
    /// Show RAG index status.
    Status {
        /// Emit JSON.
        #[arg(long)]
        json: bool,
    },
    /// Run RAG readiness checks.
    Doctor {
        /// Emit JSON.
        #[arg(long)]
        json: bool,
    },
    /// Rebuild the local RAG index.
    Rebuild {
        /// Rebuild only if sources are stale.
        #[arg(long)]
        stale_only: bool,
        /// Limit rebuild to a source kind.
        #[arg(long = "source")]
        sources: Vec<String>,
        /// Include vectors when the vector backend is available.
        #[arg(long)]
        vectors: bool,
        /// Force lexical-only rebuild.
        #[arg(long)]
        no_vectors: bool,
    },
    /// Search the local RAG index.
    Search {
        query: String,
        /// Limit search to a source kind.
        #[arg(long = "source")]
        sources: Vec<String>,
        /// Retrieval mode: lexical, hybrid, or vector.
        #[arg(long)]
        mode: Option<String>,
        /// Maximum result count.
        #[arg(long, default_value_t = 10)]
        limit: usize,
        /// Emit JSON.
        #[arg(long)]
        json: bool,
    },
    /// Garbage-collect orphaned RAG rows.
    Gc {
        /// Preview GC without mutating the database.
        #[arg(long)]
        dry_run: bool,
    },
}

pub fn run(paths: &AllbertPaths, config: &Config, command: RagCommand) -> Result<()> {
    match command {
        RagCommand::Status { json } => {
            let status = rag_status(paths, config)?;
            if json {
                println!("{}", serde_json::to_string_pretty(&status)?);
            } else {
                println!(
                    "rag:       {}\nmode:      {}\nsources:   {}\nchunks:    {}\nvectors:   {}",
                    if status.enabled {
                        "enabled"
                    } else {
                        "disabled"
                    },
                    status.mode.label(),
                    status.source_count,
                    status.chunk_count,
                    format_vector_posture(&status.vector_posture)
                );
                if let Some(reason) = status.degraded_reason {
                    println!("note:      {reason}");
                }
            }
            Ok(())
        }
        RagCommand::Doctor { json } => {
            let report = rag_doctor(paths, config)?;
            if json {
                println!("{}", serde_json::to_string_pretty(&report)?);
            } else {
                println!(
                    "rag doctor: {}\ndb:         {}\nsources:    {}\nchunks:     {}\nvectors:    {} ({})",
                    if report.ok { "ok" } else { "issues" },
                    report.db_path.display(),
                    report.source_count,
                    report.chunk_count,
                    report.vector_count,
                    format_vector_posture(&report.vector_posture)
                );
                for issue in report.issues {
                    println!("- {issue}");
                }
            }
            Ok(())
        }
        RagCommand::Rebuild {
            stale_only,
            sources,
            vectors,
            no_vectors,
        } => {
            let include_vectors = vectors && !no_vectors;
            let summary = rebuild_rag_index(
                paths,
                config,
                RagRebuildRequest {
                    stale_only,
                    sources: parse_sources(&sources)?,
                    include_vectors,
                    trigger: "cli".into(),
                },
            )?;
            println!(
                "rag rebuild: {}\nrun:         {}\nsources:     {}\nchunks:      {}\nvectors:     {}\nelapsed_ms:  {}\n{}",
                format_run_status(summary.status),
                summary.run_id,
                summary.source_count,
                summary.chunk_count,
                summary.vector_count,
                summary.elapsed_ms,
                summary.message
            );
            Ok(())
        }
        RagCommand::Search {
            query,
            sources,
            mode,
            limit,
            json,
        } => {
            let response = search_rag(
                paths,
                config,
                RagSearchRequest {
                    query,
                    sources: parse_sources(&sources)?,
                    mode: mode.as_deref().map(parse_mode).transpose()?,
                    limit: Some(limit),
                    include_review_only: false,
                },
            )?;
            if json {
                println!("{}", serde_json::to_string_pretty(&response)?);
            } else if response.results.is_empty() {
                println!("no RAG results");
                if let Some(reason) = response.degraded_reason {
                    println!("note: {reason}");
                }
            } else {
                for (idx, result) in response.results.iter().enumerate() {
                    println!(
                        "{}. [{}] {} ({})\n{}\n",
                        idx + 1,
                        result.source_kind.label(),
                        result.title,
                        result.source_id,
                        result.snippet
                    );
                }
                if let Some(reason) = response.degraded_reason {
                    println!("note: {reason}");
                }
            }
            Ok(())
        }
        RagCommand::Gc { dry_run } => {
            let summary = rag_gc(paths, dry_run)?;
            println!(
                "rag gc:     {}\norphans:    {}\nvacuumed:   {}",
                if dry_run { "dry-run" } else { "applied" },
                summary.orphan_chunks,
                if summary.vacuumed { "yes" } else { "no" }
            );
            Ok(())
        }
    }
}

fn parse_sources(values: &[String]) -> Result<Vec<RagSourceKind>> {
    values
        .iter()
        .map(|value| {
            RagSourceKind::parse(value).ok_or_else(|| anyhow!("unsupported RAG source `{value}`"))
        })
        .collect()
}

fn parse_mode(value: &str) -> Result<RagRetrievalMode> {
    match value.trim().replace('-', "_").to_ascii_lowercase().as_str() {
        "hybrid" => Ok(RagRetrievalMode::Hybrid),
        "vector" => Ok(RagRetrievalMode::Vector),
        "lexical" => Ok(RagRetrievalMode::Lexical),
        _ => Err(anyhow!("unsupported RAG mode `{value}`")),
    }
}

fn format_vector_posture(posture: &allbert_kernel_services::RagVectorPosture) -> &'static str {
    match posture {
        allbert_kernel_services::RagVectorPosture::Healthy => "healthy",
        allbert_kernel_services::RagVectorPosture::Disabled => "disabled",
        allbert_kernel_services::RagVectorPosture::MissingModel => "missing-model",
        allbert_kernel_services::RagVectorPosture::Stale => "stale",
        allbert_kernel_services::RagVectorPosture::Degraded => "degraded",
        allbert_kernel_services::RagVectorPosture::Unavailable => "unavailable",
    }
}

fn format_run_status(status: RagIndexRunStatus) -> &'static str {
    match status {
        RagIndexRunStatus::Pending => "pending",
        RagIndexRunStatus::Running => "running",
        RagIndexRunStatus::Succeeded => "succeeded",
        RagIndexRunStatus::Skipped => "skipped",
        RagIndexRunStatus::Cancelled => "cancelled",
        RagIndexRunStatus::Failed => "failed",
    }
}
