use std::fs;
use std::path::Path;

use allbert_proto::ChannelKind;
use gray_matter::engine::YAML;
use gray_matter::Matter;
use serde::Deserialize;

use crate::{AllbertPaths, KernelError};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HeartbeatRecord {
    pub timezone: String,
    pub primary_channel: ChannelKind,
    pub quiet_hours: Vec<String>,
    pub body: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HeartbeatValidation {
    pub warnings: Vec<String>,
}

#[derive(Debug, Deserialize)]
struct HeartbeatFrontmatter {
    timezone: String,
    primary_channel: ChannelKind,
    #[serde(default)]
    quiet_hours: Vec<String>,
}

pub fn load_heartbeat_record(paths: &AllbertPaths) -> Result<HeartbeatRecord, KernelError> {
    let raw = fs::read_to_string(&paths.heartbeat).map_err(|err| {
        KernelError::InitFailed(format!("read {}: {err}", paths.heartbeat.display()))
    })?;
    parse_heartbeat_markdown(&raw, &paths.heartbeat)
}

pub fn validate_heartbeat_record(record: &HeartbeatRecord) -> HeartbeatValidation {
    let mut warnings = Vec::new();

    if record.timezone.parse::<chrono_tz::Tz>().is_err() {
        warnings.push(format!(
            "timezone `{}` is not a known IANA timezone; expected values like `UTC` or `America/Los_Angeles`",
            record.timezone
        ));
    }

    for range in &record.quiet_hours {
        if !is_valid_quiet_hours_range(range) {
            warnings.push(format!(
                "quiet_hours entry `{range}` is invalid; expected HH:MM-HH:MM"
            ));
        }
    }

    HeartbeatValidation { warnings }
}

pub fn parse_heartbeat_markdown(raw: &str, path: &Path) -> Result<HeartbeatRecord, KernelError> {
    let matter = Matter::<YAML>::new();
    let parsed = matter
        .parse::<HeartbeatFrontmatter>(raw)
        .map_err(|err| KernelError::InitFailed(format!("parse {}: {err}", path.display())))?;
    let frontmatter = parsed.data.ok_or_else(|| {
        KernelError::InitFailed(format!("{} is missing YAML frontmatter", path.display()))
    })?;

    Ok(HeartbeatRecord {
        timezone: frontmatter.timezone,
        primary_channel: frontmatter.primary_channel,
        quiet_hours: frontmatter.quiet_hours,
        body: parsed.content.trim().to_string(),
    })
}

fn is_valid_quiet_hours_range(raw: &str) -> bool {
    let mut pieces = raw.split('-');
    let start = pieces.next();
    let end = pieces.next();
    if pieces.next().is_some() {
        return false;
    }
    match (start, end) {
        (Some(start), Some(end)) => is_valid_hh_mm(start) && is_valid_hh_mm(end),
        _ => false,
    }
}

fn is_valid_hh_mm(raw: &str) -> bool {
    let mut pieces = raw.split(':');
    let Some(hour) = pieces.next() else {
        return false;
    };
    let Some(minute) = pieces.next() else {
        return false;
    };
    if pieces.next().is_some() {
        return false;
    }
    let Ok(hour) = hour.parse::<u8>() else {
        return false;
    };
    let Ok(minute) = minute.parse::<u8>() else {
        return false;
    };
    hour < 24 && minute < 60
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn heartbeat_validation_flags_bad_time_inputs() {
        let record = HeartbeatRecord {
            timezone: "Mars/OlympusMons".into(),
            primary_channel: ChannelKind::Repl,
            quiet_hours: vec!["22:00-07:00".into(), "9am-5pm".into()],
            body: String::new(),
        };

        let validation = validate_heartbeat_record(&record);
        assert_eq!(validation.warnings.len(), 2);
    }
}
