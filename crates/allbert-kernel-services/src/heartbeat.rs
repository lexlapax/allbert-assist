use std::fs;
use std::path::Path;

use allbert_proto::ChannelKind;
use chrono::{Datelike, NaiveTime, TimeZone, Utc, Weekday};
use gray_matter::engine::YAML;
use gray_matter::Matter;
use serde::Deserialize;

use crate::{AllbertPaths, KernelError};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HeartbeatRecord {
    pub timezone: String,
    pub primary_channel: ChannelKind,
    pub quiet_hours: Vec<String>,
    pub check_ins: HeartbeatCheckIns,
    pub inbox_nag: HeartbeatInboxNag,
    pub body: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HeartbeatValidation {
    pub warnings: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HeartbeatCheckIns {
    pub daily_brief: HeartbeatCheckIn,
    pub weekly_review: HeartbeatCheckIn,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HeartbeatCheckIn {
    pub enabled: bool,
    pub day: Option<String>,
    pub time: Option<String>,
    pub channel: Option<ChannelKind>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HeartbeatInboxNag {
    pub enabled: bool,
    pub cadence: HeartbeatNagCadence,
    pub time: Option<String>,
    pub channel: Option<ChannelKind>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum HeartbeatNagCadence {
    Daily,
    Weekly,
    Off,
}

#[derive(Debug, Deserialize)]
struct HeartbeatFrontmatter {
    timezone: String,
    primary_channel: ChannelKind,
    #[serde(default)]
    quiet_hours: Vec<String>,
    #[serde(default)]
    check_ins: HeartbeatCheckInsFrontmatter,
    #[serde(default)]
    inbox_nag: HeartbeatInboxNagFrontmatter,
}

#[derive(Debug, Default, Deserialize)]
struct HeartbeatCheckInsFrontmatter {
    #[serde(default)]
    daily_brief: HeartbeatCheckInFrontmatter,
    #[serde(default)]
    weekly_review: HeartbeatCheckInFrontmatter,
}

#[derive(Debug, Default, Deserialize)]
struct HeartbeatCheckInFrontmatter {
    #[serde(default)]
    enabled: bool,
    #[serde(default)]
    day: Option<String>,
    #[serde(default)]
    time: Option<String>,
    #[serde(default)]
    channel: Option<ChannelKind>,
}

#[derive(Debug, Deserialize)]
struct HeartbeatInboxNagFrontmatter {
    #[serde(default = "default_inbox_nag_enabled")]
    enabled: bool,
    #[serde(default = "default_inbox_nag_cadence")]
    cadence: HeartbeatNagCadence,
    #[serde(default = "default_inbox_nag_time")]
    time: Option<String>,
    #[serde(default)]
    channel: Option<ChannelKind>,
}

impl Default for HeartbeatInboxNagFrontmatter {
    fn default() -> Self {
        Self {
            enabled: default_inbox_nag_enabled(),
            cadence: default_inbox_nag_cadence(),
            time: default_inbox_nag_time(),
            channel: None,
        }
    }
}

fn default_inbox_nag_enabled() -> bool {
    true
}

fn default_inbox_nag_cadence() -> HeartbeatNagCadence {
    HeartbeatNagCadence::Daily
}

fn default_inbox_nag_time() -> Option<String> {
    Some("09:00".into())
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

    validate_check_in(
        &mut warnings,
        "check_ins.daily_brief",
        &record.check_ins.daily_brief,
        false,
        record.primary_channel,
    );
    validate_check_in(
        &mut warnings,
        "check_ins.weekly_review",
        &record.check_ins.weekly_review,
        true,
        record.primary_channel,
    );
    if record.inbox_nag.enabled {
        let inbox_nag_active = !matches!(record.inbox_nag.cadence, HeartbeatNagCadence::Off);
        if inbox_nag_active {
            if record
                .inbox_nag
                .time
                .as_deref()
                .is_none_or(|value| !is_valid_hh_mm(value))
            {
                warnings.push("inbox_nag.time is invalid; expected HH:MM".into());
            }
            let channel = record.inbox_nag.channel.unwrap_or(record.primary_channel);
            if !supports_proactive_delivery(channel) {
                warnings.push(format!(
                    "inbox_nag targets `{}`, but proactive messages can only be delivered to `telegram`; run `heartbeat suggest --channel telegram`, review the generated file, and replace HEARTBEAT.md, or set `inbox_nag.enabled: false` to stay local-only",
                    channel_label(channel)
                ));
            }
        }
        if matches!(record.inbox_nag.cadence, HeartbeatNagCadence::Weekly)
            && record.inbox_nag.time.is_none()
        {
            warnings.push("inbox_nag.time is required for weekly inbox nags".into());
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
        check_ins: HeartbeatCheckIns {
            daily_brief: HeartbeatCheckIn {
                enabled: frontmatter.check_ins.daily_brief.enabled,
                day: frontmatter.check_ins.daily_brief.day,
                time: frontmatter.check_ins.daily_brief.time,
                channel: frontmatter.check_ins.daily_brief.channel,
            },
            weekly_review: HeartbeatCheckIn {
                enabled: frontmatter.check_ins.weekly_review.enabled,
                day: frontmatter.check_ins.weekly_review.day,
                time: frontmatter.check_ins.weekly_review.time,
                channel: frontmatter.check_ins.weekly_review.channel,
            },
        },
        inbox_nag: HeartbeatInboxNag {
            enabled: frontmatter.inbox_nag.enabled,
            cadence: frontmatter.inbox_nag.cadence,
            time: frontmatter.inbox_nag.time,
            channel: frontmatter.inbox_nag.channel,
        },
        body: parsed.content.trim().to_string(),
    })
}

pub fn quiet_hours_active(record: &HeartbeatRecord, now_utc: chrono::DateTime<Utc>) -> bool {
    let Ok(timezone) = record.timezone.parse::<chrono_tz::Tz>() else {
        return false;
    };
    let local = now_utc.with_timezone(&timezone);
    let current = local.time();
    record
        .quiet_hours
        .iter()
        .filter_map(|value| parse_quiet_hours_range(value))
        .any(|(start, end)| {
            if start <= end {
                current >= start && current < end
            } else {
                current >= start || current < end
            }
        })
}

pub fn check_in_enabled(record: &HeartbeatRecord, job_name: &str) -> bool {
    match job_name {
        "daily-brief" => record.check_ins.daily_brief.enabled,
        "weekly-review" => record.check_ins.weekly_review.enabled,
        _ => true,
    }
}

pub fn supports_proactive_delivery(channel: ChannelKind) -> bool {
    channel == ChannelKind::Telegram
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

fn parse_hh_mm(raw: &str) -> Option<NaiveTime> {
    if !is_valid_hh_mm(raw) {
        return None;
    }
    let mut pieces = raw.split(':');
    let hour = pieces.next()?.parse::<u32>().ok()?;
    let minute = pieces.next()?.parse::<u32>().ok()?;
    NaiveTime::from_hms_opt(hour, minute, 0)
}

fn parse_quiet_hours_range(raw: &str) -> Option<(NaiveTime, NaiveTime)> {
    let mut pieces = raw.split('-');
    let start = parse_hh_mm(pieces.next()?)?;
    let end = parse_hh_mm(pieces.next()?)?;
    if pieces.next().is_some() {
        return None;
    }
    Some((start, end))
}

fn is_valid_day_name(raw: &str) -> bool {
    weekday_from_name(raw).is_some()
}

fn weekday_from_name(raw: &str) -> Option<Weekday> {
    match raw.trim().to_ascii_lowercase().as_str() {
        "monday" => Some(Weekday::Mon),
        "tuesday" => Some(Weekday::Tue),
        "wednesday" => Some(Weekday::Wed),
        "thursday" => Some(Weekday::Thu),
        "friday" => Some(Weekday::Fri),
        "saturday" => Some(Weekday::Sat),
        "sunday" => Some(Weekday::Sun),
        _ => None,
    }
}

pub fn inbox_nag_due_at(
    record: &HeartbeatRecord,
    now_utc: chrono::DateTime<Utc>,
) -> Option<chrono::DateTime<Utc>> {
    if !record.inbox_nag.enabled || matches!(record.inbox_nag.cadence, HeartbeatNagCadence::Off) {
        return None;
    }
    let Ok(timezone) = record.timezone.parse::<chrono_tz::Tz>() else {
        return None;
    };
    let time = parse_hh_mm(record.inbox_nag.time.as_deref()?)?;
    let local_now = now_utc.with_timezone(&timezone);
    let candidate = local_now.date_naive().and_time(time);
    match record.inbox_nag.cadence {
        HeartbeatNagCadence::Daily => timezone
            .from_local_datetime(&candidate)
            .single()
            .map(|value| value.with_timezone(&Utc)),
        HeartbeatNagCadence::Weekly => {
            let weekday = local_now.weekday();
            let delta_days = (7 + weekday.num_days_from_monday() as i64
                - weekday.num_days_from_monday() as i64)
                % 7;
            timezone
                .from_local_datetime(
                    &(local_now.date_naive() - chrono::Duration::days(delta_days)).and_time(time),
                )
                .single()
                .map(|value| value.with_timezone(&Utc))
        }
        HeartbeatNagCadence::Off => None,
    }
}

fn validate_check_in(
    warnings: &mut Vec<String>,
    label: &str,
    check_in: &HeartbeatCheckIn,
    requires_day: bool,
    primary_channel: ChannelKind,
) {
    if !check_in.enabled {
        return;
    }
    if check_in
        .time
        .as_deref()
        .is_none_or(|value| !is_valid_hh_mm(value))
    {
        warnings.push(format!("{label}.time is invalid; expected HH:MM"));
    }
    if requires_day
        && check_in
            .day
            .as_deref()
            .is_none_or(|value| !is_valid_day_name(value))
    {
        warnings.push(format!(
            "{label}.day is invalid; expected a weekday like `Sunday`"
        ));
    }
    let channel = check_in.channel.unwrap_or(primary_channel);
    if !supports_proactive_delivery(channel) {
        warnings.push(format!(
            "{label} targets `{}`, but proactive messages can only be delivered to `telegram`; set `{label}.channel: telegram` or set `{label}.enabled: false`",
            channel_label(channel)
        ));
    }
}

fn channel_label(kind: ChannelKind) -> &'static str {
    match kind {
        ChannelKind::Cli => "cli",
        ChannelKind::Repl => "repl",
        ChannelKind::Jobs => "jobs",
        ChannelKind::Telegram => "telegram",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    #[test]
    fn heartbeat_validation_flags_bad_time_inputs() {
        let record = HeartbeatRecord {
            timezone: "Mars/OlympusMons".into(),
            primary_channel: ChannelKind::Repl,
            quiet_hours: vec!["22:00-07:00".into(), "9am-5pm".into()],
            check_ins: HeartbeatCheckIns {
                daily_brief: HeartbeatCheckIn {
                    enabled: false,
                    day: None,
                    time: None,
                    channel: None,
                },
                weekly_review: HeartbeatCheckIn {
                    enabled: false,
                    day: None,
                    time: None,
                    channel: None,
                },
            },
            inbox_nag: HeartbeatInboxNag {
                enabled: true,
                cadence: HeartbeatNagCadence::Daily,
                time: Some("09:00".into()),
                channel: Some(ChannelKind::Repl),
            },
            body: String::new(),
        };

        let validation = validate_heartbeat_record(&record);
        assert!(validation.warnings.len() >= 3);
    }

    #[test]
    fn heartbeat_validation_collapses_default_repl_proactive_warning() {
        let record = HeartbeatRecord {
            timezone: "UTC".into(),
            primary_channel: ChannelKind::Repl,
            quiet_hours: vec!["22:00-07:00".into()],
            check_ins: HeartbeatCheckIns {
                daily_brief: HeartbeatCheckIn {
                    enabled: false,
                    day: None,
                    time: None,
                    channel: None,
                },
                weekly_review: HeartbeatCheckIn {
                    enabled: false,
                    day: None,
                    time: None,
                    channel: None,
                },
            },
            inbox_nag: HeartbeatInboxNag {
                enabled: true,
                cadence: HeartbeatNagCadence::Daily,
                time: Some("09:00".into()),
                channel: Some(ChannelKind::Repl),
            },
            body: String::new(),
        };

        let validation = validate_heartbeat_record(&record);
        assert_eq!(validation.warnings.len(), 1);
        assert!(validation.warnings[0].contains("inbox_nag targets `repl`"));
        assert!(validation.warnings[0].contains("proactive messages can only be delivered"));
        assert!(validation.warnings[0].contains("heartbeat suggest --channel telegram"));
        assert!(validation.warnings[0].contains("inbox_nag.enabled: false"));
    }

    #[test]
    fn heartbeat_validation_does_not_warn_for_unused_repl_primary_channel() {
        let record = HeartbeatRecord {
            timezone: "UTC".into(),
            primary_channel: ChannelKind::Repl,
            quiet_hours: vec!["22:00-07:00".into()],
            check_ins: HeartbeatCheckIns {
                daily_brief: HeartbeatCheckIn {
                    enabled: false,
                    day: None,
                    time: None,
                    channel: None,
                },
                weekly_review: HeartbeatCheckIn {
                    enabled: false,
                    day: None,
                    time: None,
                    channel: None,
                },
            },
            inbox_nag: HeartbeatInboxNag {
                enabled: false,
                cadence: HeartbeatNagCadence::Daily,
                time: Some("09:00".into()),
                channel: None,
            },
            body: String::new(),
        };

        let validation = validate_heartbeat_record(&record);
        assert!(validation.warnings.is_empty());
    }

    #[test]
    fn parse_heartbeat_reads_full_v08_schema() {
        let raw = r#"---
version: 1
timezone: America/Los_Angeles
primary_channel: telegram
quiet_hours:
  - "22:00-07:00"
check_ins:
  daily_brief:
    enabled: true
    time: "08:00"
    channel: telegram
  weekly_review:
    enabled: true
    day: Sunday
    time: "20:00"
    channel: telegram
inbox_nag:
  enabled: true
  cadence: weekly
  time: "09:00"
  channel: telegram
---

# HEARTBEAT
"#;

        let record = parse_heartbeat_markdown(raw, Path::new("HEARTBEAT.md"))
            .expect("heartbeat should parse");
        assert_eq!(record.timezone, "America/Los_Angeles");
        assert_eq!(record.primary_channel, ChannelKind::Telegram);
        assert!(record.check_ins.daily_brief.enabled);
        assert_eq!(
            record.check_ins.weekly_review.day.as_deref(),
            Some("Sunday")
        );
        assert_eq!(record.inbox_nag.cadence, HeartbeatNagCadence::Weekly);
    }

    #[test]
    fn quiet_hours_active_respects_local_timezone_windows() {
        let record = HeartbeatRecord {
            timezone: "America/Los_Angeles".into(),
            primary_channel: ChannelKind::Telegram,
            quiet_hours: vec!["22:00-07:00".into()],
            check_ins: HeartbeatCheckIns {
                daily_brief: HeartbeatCheckIn {
                    enabled: false,
                    day: None,
                    time: None,
                    channel: None,
                },
                weekly_review: HeartbeatCheckIn {
                    enabled: false,
                    day: None,
                    time: None,
                    channel: None,
                },
            },
            inbox_nag: HeartbeatInboxNag {
                enabled: false,
                cadence: HeartbeatNagCadence::Off,
                time: None,
                channel: None,
            },
            body: String::new(),
        };

        let inside = Utc
            .with_ymd_and_hms(2026, 4, 23, 6, 0, 0)
            .single()
            .expect("timestamp should exist");
        let outside = Utc
            .with_ymd_and_hms(2026, 4, 23, 18, 0, 0)
            .single()
            .expect("timestamp should exist");
        assert!(quiet_hours_active(&record, inside));
        assert!(!quiet_hours_active(&record, outside));
    }
}
