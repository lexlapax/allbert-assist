use std::fs::OpenOptions;
use std::io::{BufRead, BufReader, Write};
use std::path::Path;

use serde::{Deserialize, Serialize};
use time::format_description::well_known::Rfc3339;
use time::OffsetDateTime;

use crate::error::KernelError;
use crate::llm::{Pricing, Usage};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CostEntry {
    pub ts: String,
    pub session: String,
    #[serde(default = "default_root_agent_name")]
    pub agent_name: String,
    #[serde(default)]
    pub parent_agent_name: Option<String>,
    pub provider: String,
    pub model: String,
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cache_read: u64,
    pub cache_create: u64,
    pub usd_estimate: f64,
}

pub fn estimate_usd(usage: &Usage, pricing: Option<Pricing>) -> f64 {
    let Some(pricing) = pricing else {
        return 0.0;
    };

    (usage.input_tokens as f64 * pricing.prompt_per_token_usd)
        + (usage.output_tokens as f64 * pricing.completion_per_token_usd)
        + (usage.cache_read as f64 * pricing.cache_read_per_token_usd)
        + (usage.cache_create as f64 * pricing.cache_create_per_token_usd)
        + pricing.request_usd
}

pub fn build_cost_entry(
    session: &str,
    agent_name: &str,
    parent_agent_name: Option<&str>,
    provider: &str,
    model: &str,
    usage: &Usage,
    pricing: Option<Pricing>,
) -> Result<CostEntry, KernelError> {
    Ok(CostEntry {
        ts: now_rfc3339()?,
        session: session.into(),
        agent_name: agent_name.into(),
        parent_agent_name: parent_agent_name.map(str::to_string),
        provider: provider.into(),
        model: model.into(),
        input_tokens: usage.input_tokens,
        output_tokens: usage.output_tokens,
        cache_read: usage.cache_read,
        cache_create: usage.cache_create,
        usd_estimate: estimate_usd(usage, pricing),
    })
}

pub fn append_cost_entry(path: &Path, entry: &CostEntry) -> Result<(), KernelError> {
    let encoded = serde_json::to_string(entry).map_err(|err| KernelError::Cost(err.to_string()))?;
    let mut file = OpenOptions::new().create(true).append(true).open(path)?;
    writeln!(file, "{encoded}")?;
    Ok(())
}

pub fn sum_costs_for_today(path: &Path) -> Result<f64, KernelError> {
    if !path.exists() {
        return Ok(0.0);
    }

    let today = local_now().date();
    let file = std::fs::File::open(path)?;
    let reader = BufReader::new(file);
    let mut total = 0.0;

    for line in reader.lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }

        let entry: CostEntry =
            serde_json::from_str(&line).map_err(|err| KernelError::Cost(err.to_string()))?;
        let timestamp = OffsetDateTime::parse(&entry.ts, &Rfc3339)
            .map_err(|err| KernelError::Cost(err.to_string()))?;
        if timestamp.to_offset(local_now().offset()).date() == today {
            total += entry.usd_estimate;
        }
    }

    Ok(total)
}

pub fn sum_costs_for_utc_day(path: &Path, day: time::Date) -> Result<f64, KernelError> {
    if !path.exists() {
        return Ok(0.0);
    }

    let file = std::fs::File::open(path)?;
    let reader = BufReader::new(file);
    let mut total = 0.0;

    for line in reader.lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }

        let entry: CostEntry =
            serde_json::from_str(&line).map_err(|err| KernelError::Cost(err.to_string()))?;
        let timestamp = OffsetDateTime::parse(&entry.ts, &Rfc3339)
            .map_err(|err| KernelError::Cost(err.to_string()))?;
        if timestamp.to_offset(time::UtcOffset::UTC).date() == day {
            total += entry.usd_estimate;
        }
    }

    Ok(total)
}

fn now_rfc3339() -> Result<String, KernelError> {
    local_now()
        .format(&Rfc3339)
        .map_err(|err| KernelError::Cost(err.to_string()))
}

fn local_now() -> OffsetDateTime {
    OffsetDateTime::now_local().unwrap_or_else(|_| OffsetDateTime::now_utc())
}

fn default_root_agent_name() -> String {
    "allbert/root".into()
}
