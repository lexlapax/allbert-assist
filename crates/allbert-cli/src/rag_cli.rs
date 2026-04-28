use allbert_kernel_services::{
    create_rag_collection, delete_rag_collection, list_rag_collections, rag_doctor, rag_gc,
    rag_status, rebuild_rag_index, search_rag, AllbertPaths, Config, RagCollectionCreateRequest,
    RagCollectionStatus, RagCollectionType, RagFetchPolicy, RagIndexRunStatus, RagRebuildRequest,
    RagRetrievalMode, RagSearchRequest, RagSourceKind,
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
        /// Limit rebuild to system or user collections.
        #[arg(long = "collection-type")]
        collection_type: Option<String>,
        /// Limit rebuild to collection names.
        #[arg(long = "collection")]
        collections: Vec<String>,
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
        /// Limit search to system or user collections.
        #[arg(long = "collection-type")]
        collection_type: Option<String>,
        /// Limit search to collection names.
        #[arg(long = "collection")]
        collections: Vec<String>,
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
    /// Manage user RAG collections.
    Collections {
        #[command(subcommand)]
        command: RagCollectionsCommand,
    },
}

#[derive(Subcommand, Debug)]
pub enum RagCollectionsCommand {
    /// List system and user collections.
    List {
        /// Limit to system or user collections.
        #[arg(long = "collection-type")]
        collection_type: Option<String>,
        /// Emit JSON.
        #[arg(long)]
        json: bool,
    },
    /// Show one collection.
    Show {
        name: String,
        /// Limit to system or user collections.
        #[arg(long = "collection-type")]
        collection_type: Option<String>,
        /// Emit JSON.
        #[arg(long)]
        json: bool,
    },
    /// Create a user collection from local files/directories and/or web URLs.
    Create {
        name: String,
        /// Source URI or path. Repeat for multiple sources.
        #[arg(long = "source", required = true)]
        sources: Vec<String>,
        /// Human-readable title.
        #[arg(long)]
        title: Option<String>,
        /// Human-readable description.
        #[arg(long)]
        description: Option<String>,
        /// Allow http:// URL ingestion for this collection.
        #[arg(long)]
        allow_insecure_http: bool,
        /// Disable robots.txt checks for this collection.
        #[arg(long = "no-robots")]
        no_robots: bool,
    },
    /// Delete a user collection manifest and catalog rows.
    Delete { name: String },
    /// Ingest or rebuild one user collection.
    Ingest {
        name: String,
        /// Include vectors when the vector backend is available.
        #[arg(long)]
        vectors: bool,
        /// Force lexical-only rebuild.
        #[arg(long)]
        no_vectors: bool,
    },
    /// Search one user collection.
    Search {
        name: String,
        query: String,
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
}

pub fn run(paths: &AllbertPaths, config: &Config, command: RagCommand) -> Result<()> {
    match command {
        RagCommand::Status { json } => {
            let status = rag_status(paths, config)?;
            if json {
                println!("{}", serde_json::to_string_pretty(&status)?);
            } else {
                println!(
                    "rag:         {}\nmode:        {}\ncollections: {}\nsources:     {}\nchunks:      {}\nvectors:     {}",
                    if status.enabled {
                        "enabled"
                    } else {
                        "disabled"
                    },
                    status.mode.label(),
                    status.collection_count,
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
            collection_type,
            collections,
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
                    collection_type: parse_optional_collection_type(collection_type.as_deref())?,
                    collections,
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
            collection_type,
            collections,
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
                    collection_type: parse_optional_collection_type(collection_type.as_deref())?,
                    collections,
                    mode: mode.as_deref().map(parse_mode).transpose()?,
                    limit: Some(limit),
                    include_review_only: false,
                },
            )?;
            if json {
                println!("{}", serde_json::to_string_pretty(&response)?);
            } else {
                print_search_results(&response);
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
        RagCommand::Collections { command } => run_collections(paths, config, command),
    }
}

fn run_collections(
    paths: &AllbertPaths,
    config: &Config,
    command: RagCollectionsCommand,
) -> Result<()> {
    match command {
        RagCollectionsCommand::List {
            collection_type,
            json,
        } => {
            let statuses = list_rag_collections(
                paths,
                config,
                parse_optional_collection_type(collection_type.as_deref())?,
            )?;
            if json {
                println!("{}", serde_json::to_string_pretty(&statuses)?);
            } else if statuses.is_empty() {
                println!("no RAG collections");
            } else {
                for status in statuses {
                    println!("{}", render_collection_status(&status));
                }
            }
            Ok(())
        }
        RagCollectionsCommand::Show {
            name,
            collection_type,
            json,
        } => {
            let wanted_type = parse_optional_collection_type(collection_type.as_deref())?;
            let normalized = normalize_collection_name_for_cli(&name);
            let statuses = list_rag_collections(paths, config, wanted_type)?;
            let Some(status) = statuses
                .into_iter()
                .find(|status| status.collection_name == normalized)
            else {
                return Err(anyhow!("RAG collection `{name}` was not found"));
            };
            if json {
                println!("{}", serde_json::to_string_pretty(&status)?);
            } else {
                println!("{}", render_collection_status(&status));
            }
            Ok(())
        }
        RagCollectionsCommand::Create {
            name,
            sources,
            title,
            description,
            allow_insecure_http,
            no_robots,
        } => {
            let fetch_policy = RagFetchPolicy {
                allow_insecure_http,
                respect_robots_txt: !no_robots,
                ..RagFetchPolicy::default()
            };
            let summary = create_rag_collection(
                paths,
                config,
                RagCollectionCreateRequest {
                    collection_name: name,
                    title,
                    description,
                    source_uris: sources,
                    fetch_policy,
                },
            )?;
            println!(
                "rag collection created: {}:{}\nmanifest: {}\nsources: {}\n{}",
                summary.collection_type.label(),
                summary.collection_name,
                summary
                    .manifest_path
                    .as_ref()
                    .map(|path| path.display().to_string())
                    .unwrap_or_else(|| "(none)".into()),
                summary.source_uris.len(),
                summary.message
            );
            Ok(())
        }
        RagCollectionsCommand::Delete { name } => {
            let summary = delete_rag_collection(paths, &name)?;
            println!(
                "rag collection deleted: {}:{}\nsources retained: {}\n{}",
                summary.collection_type.label(),
                summary.collection_name,
                summary.source_uris.len(),
                summary.message
            );
            Ok(())
        }
        RagCollectionsCommand::Ingest {
            name,
            vectors,
            no_vectors,
        } => {
            let include_vectors = vectors && !no_vectors;
            let summary = rebuild_rag_index(
                paths,
                config,
                RagRebuildRequest {
                    stale_only: false,
                    sources: vec![RagSourceKind::UserDocument, RagSourceKind::WebUrl],
                    collection_type: Some(RagCollectionType::User),
                    collections: vec![name],
                    include_vectors,
                    trigger: "cli-user-collection-ingest".into(),
                },
            )?;
            println!(
                "rag collection ingest: {}\nrun:         {}\nsources:     {}\nchunks:      {}\nvectors:     {}\nelapsed_ms:  {}\n{}",
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
        RagCollectionsCommand::Search {
            name,
            query,
            mode,
            limit,
            json,
        } => {
            let response = search_rag(
                paths,
                config,
                RagSearchRequest {
                    query,
                    sources: vec![RagSourceKind::UserDocument, RagSourceKind::WebUrl],
                    collection_type: Some(RagCollectionType::User),
                    collections: vec![name],
                    mode: mode.as_deref().map(parse_mode).transpose()?,
                    limit: Some(limit),
                    include_review_only: false,
                },
            )?;
            if json {
                println!("{}", serde_json::to_string_pretty(&response)?);
            } else {
                print_search_results(&response);
            }
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

fn parse_optional_collection_type(value: Option<&str>) -> Result<Option<RagCollectionType>> {
    value.map(parse_collection_type).transpose()
}

fn parse_collection_type(value: &str) -> Result<RagCollectionType> {
    RagCollectionType::parse(value)
        .ok_or_else(|| anyhow!("unsupported RAG collection type `{value}`"))
}

fn normalize_collection_name_for_cli(value: &str) -> String {
    value
        .trim()
        .chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() || ch == '-' || ch == '_' {
                ch.to_ascii_lowercase()
            } else {
                '-'
            }
        })
        .collect::<String>()
        .trim_matches('-')
        .to_string()
}

fn render_collection_status(status: &RagCollectionStatus) -> String {
    format!(
        "{}:{}\ntitle:     {}\nsource:    {}\nsources:   {}\nchunks:    {}\nvectors:   {} ({})\nstale:     {}\nlast_used: {}",
        status.collection_type.label(),
        status.collection_name,
        status.title,
        status.source_uri,
        status.source_count,
        status.chunk_count,
        status.vector_count,
        format_vector_posture(&status.vector_posture),
        if status.stale { "yes" } else { "no" },
        status.last_accessed_at.as_deref().unwrap_or("never")
    )
}

fn print_search_results(response: &allbert_kernel_services::RagSearchResponse) {
    if response.results.is_empty() {
        println!("no RAG results");
        if let Some(reason) = response.degraded_reason.as_ref() {
            println!("note: {reason}");
        }
        return;
    }
    for (idx, result) in response.results.iter().enumerate() {
        println!(
            "{}. [{}:{}:{}] {} ({})\n{}\n",
            idx + 1,
            result.collection_type.label(),
            result.collection_name,
            result.source_kind.label(),
            result.title,
            result.source_id,
            result.snippet
        );
    }
    if let Some(reason) = response.degraded_reason.as_ref() {
        println!("note: {reason}");
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
