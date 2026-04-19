use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::Path;
use std::str::FromStr;
use std::sync::Arc;

use chrono::{
    DateTime, Datelike, Duration as ChronoDuration, Local, NaiveTime, Timelike, Utc, Weekday,
};
use chrono_tz::Tz;
use cron::Schedule as CronSchedule;
use gray_matter::engine::YAML;
use gray_matter::Matter;
use serde::{Deserialize, Serialize};

use allbert_kernel::{
    llm::ProviderFactory, AllbertPaths, Config, FrontendAdapter, InputPrompter, InputRequest,
    InputResponse, Kernel, KernelError, ModelConfig, Provider,
};
use allbert_proto::{
    JobDefinitionPayload, JobReportPolicyPayload, JobRunRecordPayload, JobStatePayload,
    JobStatusPayload, ModelConfigPayload, ProviderKind,
};

use crate::error::DaemonError;

#[derive(Default)]
pub struct JobManager {
    definitions: HashMap<String, JobDefinition>,
    states: HashMap<String, JobState>,
    running: HashSet<String>,
}

impl JobManager {
    pub fn load(paths: &AllbertPaths, defaults: &Config) -> Result<Self, DaemonError> {
        let mut manager = Self::default();
        manager.reload(paths, defaults)?;
        Ok(manager)
    }

    pub fn reload(&mut self, paths: &AllbertPaths, defaults: &Config) -> Result<(), DaemonError> {
        let definitions = load_definitions(&paths.jobs_definitions)?;
        let states = load_states(&paths.jobs_state)?;
        self.definitions = definitions;
        self.states = states;

        let now = Utc::now();
        for (name, definition) in &self.definitions {
            let state = self.states.entry(name.clone()).or_default();
            if definition.enabled && state.next_due_at.is_none() {
                state.next_due_at = Some(definition.schedule.first_due_after(
                    now,
                    definition.timezone.as_deref(),
                    defaults.jobs.default_timezone.as_deref(),
                )?);
            }
        }
        self.persist_states(paths)?;
        Ok(())
    }

    pub fn list(&self) -> Vec<JobStatusPayload> {
        let mut jobs = self
            .definitions
            .values()
            .filter_map(|definition| self.status_for(&definition.name).ok())
            .collect::<Vec<_>>();
        jobs.sort_by(|a, b| a.definition.name.cmp(&b.definition.name));
        jobs
    }

    pub fn get(&self, name: &str) -> Result<JobStatusPayload, DaemonError> {
        self.status_for(name)
    }

    pub fn upsert(
        &mut self,
        paths: &AllbertPaths,
        defaults: &Config,
        definition: JobDefinitionPayload,
    ) -> Result<JobStatusPayload, DaemonError> {
        validate_job_name(&definition.name)?;
        let parsed = JobDefinition::from_payload(definition)?;
        write_definition_file(&paths.jobs_definitions, &parsed)?;
        self.definitions.insert(parsed.name.clone(), parsed.clone());
        let state = self.states.entry(parsed.name.clone()).or_default();
        if parsed.enabled {
            state.next_due_at = Some(parsed.schedule.first_due_after(
                Utc::now(),
                parsed.timezone.as_deref(),
                defaults.jobs.default_timezone.as_deref(),
            )?);
        }
        self.persist_states(paths)?;
        self.get(&parsed.name)
    }

    pub fn pause(
        &mut self,
        paths: &AllbertPaths,
        name: &str,
    ) -> Result<JobStatusPayload, DaemonError> {
        let state = self.states.entry(name.to_string()).or_default();
        state.paused = true;
        self.persist_states(paths)?;
        self.get(name)
    }

    pub fn resume(
        &mut self,
        paths: &AllbertPaths,
        defaults: &Config,
        name: &str,
        now: DateTime<Utc>,
    ) -> Result<JobStatusPayload, DaemonError> {
        let definition = self
            .definitions
            .get(name)
            .ok_or_else(|| DaemonError::Protocol(format!("job not found: {name}")))?;
        let state = self.states.entry(name.to_string()).or_default();
        state.paused = false;
        if state.next_due_at.is_none() {
            state.next_due_at = Some(definition.schedule.first_due_after(
                now,
                definition.timezone.as_deref(),
                defaults.jobs.default_timezone.as_deref(),
            )?);
        }
        self.persist_states(paths)?;
        self.get(name)
    }

    pub fn remove(&mut self, paths: &AllbertPaths, name: &str) -> Result<(), DaemonError> {
        self.definitions
            .remove(name)
            .ok_or_else(|| DaemonError::Protocol(format!("job not found: {name}")))?;
        self.states.remove(name);
        let definition_path = paths.jobs_definitions.join(format!("{name}.md"));
        let state_path = paths.jobs_state.join(format!("{name}.json"));
        if definition_path.exists() {
            fs::remove_file(definition_path)?;
        }
        if state_path.exists() {
            fs::remove_file(state_path)?;
        }
        Ok(())
    }

    pub async fn run_job_now(
        &mut self,
        paths: &AllbertPaths,
        defaults: &Config,
        provider_factory: Arc<dyn ProviderFactory>,
        name: &str,
    ) -> Result<JobRunRecordPayload, DaemonError> {
        let definition = self
            .definitions
            .get(name)
            .ok_or_else(|| DaemonError::Protocol(format!("job not found: {name}")))?
            .clone();
        if self.running.contains(name) {
            return Err(DaemonError::Protocol(format!(
                "job already running: {name}"
            )));
        }
        self.running.insert(name.to_string());
        let result = execute_job(paths, defaults, provider_factory, &definition).await;
        self.running.remove(name);

        let record = result?;
        let state = self.states.entry(name.to_string()).or_default();
        update_state_after_run(
            state,
            &definition,
            defaults,
            parse_rfc3339(&record.started_at)?,
            parse_rfc3339(&record.ended_at)?,
            &record.outcome,
        )?;
        self.persist_states(paths)?;
        append_run_record(paths, &record)?;
        Ok(record)
    }

    pub async fn sweep_due(
        &mut self,
        paths: &AllbertPaths,
        defaults: &Config,
        provider_factory: Arc<dyn ProviderFactory>,
        now: DateTime<Utc>,
    ) -> Result<Vec<JobRunRecordPayload>, DaemonError> {
        let names = self.definitions.keys().cloned().collect::<Vec<_>>();
        let mut runs = Vec::new();

        for name in names {
            let Some(definition) = self.definitions.get(&name).cloned() else {
                continue;
            };
            let state = self.states.entry(name.clone()).or_default();
            if !definition.enabled || state.paused {
                continue;
            }

            let Some(next_due) = state.next_due_at else {
                state.next_due_at = Some(definition.schedule.first_due_after(
                    now,
                    definition.timezone.as_deref(),
                    defaults.jobs.default_timezone.as_deref(),
                )?);
                continue;
            };

            if next_due > now {
                continue;
            }

            if self.running.contains(&name) {
                state.next_due_at = Some(definition.schedule.advance_until_future(
                    next_due,
                    now,
                    definition.timezone.as_deref(),
                    defaults.jobs.default_timezone.as_deref(),
                )?);
                continue;
            }

            self.running.insert(name.clone());
            let result = execute_job(paths, defaults, provider_factory.clone(), &definition).await;
            self.running.remove(&name);

            let record = result?;
            let started = parse_rfc3339(&record.started_at)?;
            let ended = parse_rfc3339(&record.ended_at)?;
            let state = self.states.entry(name.clone()).or_default();
            update_state_after_run(
                state,
                &definition,
                defaults,
                started,
                ended,
                &record.outcome,
            )?;
            append_run_record(paths, &record)?;
            runs.push(record);
        }

        self.persist_states(paths)?;
        Ok(runs)
    }

    fn status_for(&self, name: &str) -> Result<JobStatusPayload, DaemonError> {
        let definition = self
            .definitions
            .get(name)
            .ok_or_else(|| DaemonError::Protocol(format!("job not found: {name}")))?;
        let state = self.states.get(name).cloned().unwrap_or_default();
        Ok(JobStatusPayload {
            definition: definition.to_payload(),
            state: JobStatePayload {
                paused: state.paused,
                last_run_at: state.last_run_at.map(to_rfc3339),
                next_due_at: state.next_due_at.map(to_rfc3339),
                failure_streak: state.failure_streak,
                running: self.running.contains(name),
            },
        })
    }

    fn persist_states(&self, paths: &AllbertPaths) -> Result<(), DaemonError> {
        for (name, state) in &self.states {
            let path = paths.jobs_state.join(format!("{name}.json"));
            let encoded = serde_json::to_string_pretty(state)
                .map_err(|e| DaemonError::Protocol(format!("encode state: {e}")))?;
            fs::write(path, encoded)?;
        }
        Ok(())
    }
}

#[derive(Debug, Clone)]
pub struct JobDefinition {
    pub name: String,
    pub description: String,
    pub enabled: bool,
    pub schedule_raw: String,
    schedule: JobSchedule,
    pub skills: Vec<String>,
    pub timezone: Option<String>,
    pub model: Option<ModelConfigPayload>,
    pub allowed_tools: Vec<String>,
    pub timeout_s: Option<u64>,
    pub report: Option<JobReportPolicyPayload>,
    pub max_turns: Option<u32>,
    pub prompt: String,
}

impl JobDefinition {
    fn from_payload(payload: JobDefinitionPayload) -> Result<Self, DaemonError> {
        validate_job_name(&payload.name)?;
        if payload.description.trim().is_empty() {
            return Err(DaemonError::Protocol(
                "job description cannot be empty".into(),
            ));
        }
        let schedule = JobSchedule::parse(&payload.schedule)?;
        Ok(Self {
            name: payload.name,
            description: payload.description,
            enabled: payload.enabled,
            schedule_raw: payload.schedule,
            schedule,
            skills: payload.skills,
            timezone: payload.timezone,
            model: payload.model,
            allowed_tools: payload.allowed_tools,
            timeout_s: payload.timeout_s,
            report: payload.report,
            max_turns: payload.max_turns,
            prompt: payload.prompt,
        })
    }

    fn to_payload(&self) -> JobDefinitionPayload {
        JobDefinitionPayload {
            name: self.name.clone(),
            description: self.description.clone(),
            enabled: self.enabled,
            schedule: self.schedule_raw.clone(),
            skills: self.skills.clone(),
            timezone: self.timezone.clone(),
            model: self.model.clone(),
            allowed_tools: self.allowed_tools.clone(),
            timeout_s: self.timeout_s,
            report: self.report,
            max_turns: self.max_turns,
            prompt: self.prompt.clone(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
struct JobState {
    #[serde(default)]
    paused: bool,
    #[serde(default)]
    last_run_at: Option<DateTime<Utc>>,
    #[serde(default)]
    next_due_at: Option<DateTime<Utc>>,
    #[serde(default)]
    failure_streak: u32,
}

#[derive(Debug, Clone)]
enum JobSchedule {
    Hourly,
    Daily(Option<NaiveTime>),
    Weekly(Weekday, NaiveTime),
    Monthly,
    Every(ChronoDuration),
    Cron(String),
    Once(DateTime<Utc>),
}

impl JobSchedule {
    fn parse(raw: &str) -> Result<Self, DaemonError> {
        let raw = raw.trim();
        if raw == "@hourly" {
            return Ok(Self::Hourly);
        }
        if raw == "@daily" {
            return Ok(Self::Daily(None));
        }
        if raw == "@weekly" {
            return Ok(Self::Weekly(Weekday::Mon, parse_time("00:00")?));
        }
        if raw == "@monthly" {
            return Ok(Self::Monthly);
        }
        if let Some(time) = raw.strip_prefix("@daily at ") {
            return Ok(Self::Daily(Some(parse_time(time)?)));
        }
        if let Some(rest) = raw.strip_prefix("@weekly on ") {
            let parts: Vec<_> = rest.split(" at ").collect();
            if parts.len() != 2 {
                return Err(DaemonError::Protocol(format!(
                    "invalid weekly schedule: {raw}"
                )));
            }
            return Ok(Self::Weekly(
                parse_weekday(parts[0])?,
                parse_time(parts[1])?,
            ));
        }
        if let Some(rest) = raw.strip_prefix("every ") {
            return Ok(Self::Every(parse_duration(rest)?));
        }
        if let Some(rest) = raw.strip_prefix("cron:") {
            let expr = rest.trim();
            CronSchedule::from_str(expr)
                .map_err(|e| DaemonError::Protocol(format!("invalid cron schedule: {e}")))?;
            return Ok(Self::Cron(expr.to_string()));
        }
        if let Some(rest) = raw.strip_prefix("once at ") {
            return Ok(Self::Once(parse_rfc3339(rest.trim())?));
        }
        Err(DaemonError::Protocol(format!(
            "unsupported schedule: {raw}"
        )))
    }

    fn first_due_after(
        &self,
        now: DateTime<Utc>,
        job_tz: Option<&str>,
        default_tz: Option<&str>,
    ) -> Result<DateTime<Utc>, DaemonError> {
        match self {
            Self::Every(duration) => Ok(now + *duration),
            Self::Once(ts) => Ok(*ts),
            _ => self.next_after(now, job_tz, default_tz),
        }
    }

    fn advance_until_future(
        &self,
        anchor: DateTime<Utc>,
        now: DateTime<Utc>,
        job_tz: Option<&str>,
        default_tz: Option<&str>,
    ) -> Result<DateTime<Utc>, DaemonError> {
        match self {
            Self::Every(duration) => {
                let mut next = anchor;
                while next <= now {
                    next += *duration;
                }
                Ok(next)
            }
            Self::Once(ts) => Ok(*ts),
            _ => {
                let mut next = self.next_after(anchor, job_tz, default_tz)?;
                while next <= now {
                    next = self.next_after(next, job_tz, default_tz)?;
                }
                Ok(next)
            }
        }
    }

    fn next_after(
        &self,
        after: DateTime<Utc>,
        job_tz: Option<&str>,
        default_tz: Option<&str>,
    ) -> Result<DateTime<Utc>, DaemonError> {
        if let Some(tz_name) = job_tz.or(default_tz) {
            let tz: Tz = tz_name
                .parse()
                .map_err(|_| DaemonError::Protocol(format!("invalid timezone: {tz_name}")))?;
            self.next_after_in_tz(after, tz)
        } else {
            self.next_after_local(after)
        }
    }

    fn next_after_in_tz<TZ: chrono::TimeZone>(
        &self,
        after: DateTime<Utc>,
        tz: TZ,
    ) -> Result<DateTime<Utc>, DaemonError>
    where
        TZ::Offset: Send + Sync,
    {
        match self {
            Self::Hourly => {
                let local = after.with_timezone(&tz);
                let next = local
                    .with_minute(0)
                    .and_then(|dt| dt.with_second(0))
                    .and_then(|dt| dt.with_nanosecond(0))
                    .ok_or_else(|| DaemonError::Protocol("invalid hourly schedule".into()))?
                    + ChronoDuration::hours(1);
                Ok(next.with_timezone(&Utc))
            }
            Self::Daily(time) => {
                let local = after.with_timezone(&tz);
                let t = time.unwrap_or_else(|| parse_time("00:00").expect("valid fallback"));
                let date = local.date_naive();
                let candidate = tz
                    .from_local_datetime(&date.and_time(t))
                    .single()
                    .ok_or_else(|| {
                        DaemonError::Protocol("ambiguous local daily schedule".into())
                    })?;
                let next = if candidate > local {
                    candidate
                } else {
                    tz.from_local_datetime(&((date + ChronoDuration::days(1)).and_time(t)))
                        .single()
                        .ok_or_else(|| {
                            DaemonError::Protocol("ambiguous local daily schedule".into())
                        })?
                };
                Ok(next.with_timezone(&Utc))
            }
            Self::Weekly(weekday, time) => {
                let local = after.with_timezone(&tz);
                let mut date = local.date_naive();
                while date.weekday() != *weekday {
                    date = date + ChronoDuration::days(1);
                }
                let candidate = tz
                    .from_local_datetime(&date.and_time(*time))
                    .single()
                    .ok_or_else(|| {
                        DaemonError::Protocol("ambiguous local weekly schedule".into())
                    })?;
                let next = if candidate > local {
                    candidate
                } else {
                    let next_date = date + ChronoDuration::days(7);
                    tz.from_local_datetime(&next_date.and_time(*time))
                        .single()
                        .ok_or_else(|| {
                            DaemonError::Protocol("ambiguous local weekly schedule".into())
                        })?
                };
                Ok(next.with_timezone(&Utc))
            }
            Self::Monthly => {
                let local = after.with_timezone(&tz);
                let (year, month) = if local.month() == 12 {
                    (local.year() + 1, 1)
                } else {
                    (local.year(), local.month() + 1)
                };
                let next = tz
                    .with_ymd_and_hms(year, month, 1, 0, 0, 0)
                    .single()
                    .ok_or_else(|| DaemonError::Protocol("ambiguous monthly schedule".into()))?;
                Ok(next.with_timezone(&Utc))
            }
            Self::Cron(expr) => {
                let schedule = CronSchedule::from_str(expr)
                    .map_err(|e| DaemonError::Protocol(format!("invalid cron schedule: {e}")))?;
                schedule
                    .after(&after.with_timezone(&tz))
                    .next()
                    .map(|dt| dt.with_timezone(&Utc))
                    .ok_or_else(|| {
                        DaemonError::Protocol("cron schedule produced no next occurrence".into())
                    })
            }
            Self::Once(ts) => Ok(*ts),
            Self::Every(duration) => Ok(after + *duration),
        }
    }

    fn next_after_local(&self, after: DateTime<Utc>) -> Result<DateTime<Utc>, DaemonError> {
        self.next_after_in_tz(after, Local)
    }
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct JobFrontmatter {
    name: String,
    description: String,
    enabled: bool,
    schedule: String,
    #[serde(default)]
    skills: Vec<String>,
    #[serde(default)]
    timezone: Option<String>,
    #[serde(default)]
    model: Option<JobModelFrontmatter>,
    #[serde(rename = "allowed-tools", default)]
    allowed_tools: AllowedTools,
    #[serde(default)]
    timeout_s: Option<u64>,
    #[serde(default)]
    report: Option<JobReportPolicyPayload>,
    #[serde(default)]
    max_turns: Option<u32>,
}

#[derive(Debug, Deserialize)]
struct JobModelFrontmatter {
    provider: ProviderKind,
    model_id: String,
    api_key_env: String,
    max_tokens: Option<u32>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(untagged)]
enum AllowedTools {
    #[default]
    Missing,
    String(String),
    List(Vec<String>),
}

impl AllowedTools {
    fn normalize(self) -> Vec<String> {
        match self {
            Self::Missing => Vec::new(),
            Self::String(raw) => raw.split_whitespace().map(|v| v.to_string()).collect(),
            Self::List(values) => values,
        }
    }
}

fn load_definitions(root: &Path) -> Result<HashMap<String, JobDefinition>, DaemonError> {
    let mut out = HashMap::new();
    let matter = Matter::<YAML>::new();
    let Ok(entries) = fs::read_dir(root) else {
        return Ok(out);
    };

    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|ext| ext.to_str()) != Some("md") {
            continue;
        }
        let raw = fs::read_to_string(&path)?;
        let parsed = matter
            .parse::<JobFrontmatter>(&raw)
            .map_err(|e| DaemonError::Protocol(format!("parse {}: {e}", path.display())))?;
        let data = parsed.data.ok_or_else(|| {
            DaemonError::Protocol(format!("missing frontmatter in {}", path.display()))
        })?;
        validate_job_name(&data.name)?;
        let filename = path
            .file_stem()
            .and_then(|stem| stem.to_str())
            .unwrap_or_default();
        if filename != data.name {
            return Err(DaemonError::Protocol(format!(
                "job filename {} does not match frontmatter name {}",
                filename, data.name
            )));
        }

        let definition = JobDefinition {
            name: data.name,
            description: data.description,
            enabled: data.enabled,
            schedule_raw: data.schedule.clone(),
            schedule: JobSchedule::parse(&data.schedule)?,
            skills: data.skills,
            timezone: data.timezone,
            model: data.model.map(|model| ModelConfigPayload {
                provider: model.provider,
                model_id: model.model_id,
                api_key_env: model.api_key_env,
                max_tokens: model.max_tokens.unwrap_or(4096),
            }),
            allowed_tools: data.allowed_tools.normalize(),
            timeout_s: data.timeout_s,
            report: data.report,
            max_turns: data.max_turns,
            prompt: parsed.content.trim().to_string(),
        };
        out.insert(definition.name.clone(), definition);
    }

    Ok(out)
}

fn load_states(root: &Path) -> Result<HashMap<String, JobState>, DaemonError> {
    let mut out = HashMap::new();
    let Ok(entries) = fs::read_dir(root) else {
        return Ok(out);
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|ext| ext.to_str()) != Some("json") {
            continue;
        }
        let raw = fs::read_to_string(&path)?;
        let state: JobState = serde_json::from_str(&raw)
            .map_err(|e| DaemonError::Protocol(format!("parse {}: {e}", path.display())))?;
        let name = path
            .file_stem()
            .and_then(|stem| stem.to_str())
            .unwrap_or_default();
        out.insert(name.to_string(), state);
    }
    Ok(out)
}

fn write_definition_file(root: &Path, definition: &JobDefinition) -> Result<(), DaemonError> {
    fs::create_dir_all(root)?;
    let path = root.join(format!("{}.md", definition.name));
    let mut frontmatter = String::new();
    frontmatter.push_str("---\n");
    frontmatter.push_str(&format!("name: {}\n", definition.name));
    frontmatter.push_str(&format!(
        "description: {}\n",
        yaml_quote(&definition.description)
    ));
    frontmatter.push_str(&format!("enabled: {}\n", definition.enabled));
    frontmatter.push_str(&format!(
        "schedule: {}\n",
        yaml_quote(&definition.schedule_raw)
    ));
    if !definition.skills.is_empty() {
        let skills = serde_yaml::to_string(&definition.skills)
            .map_err(|e| DaemonError::Protocol(format!("encode skills: {e}")))?;
        frontmatter.push_str("skills:\n");
        for line in skills.lines().filter(|line| !line.trim().is_empty()) {
            frontmatter.push_str("  ");
            frontmatter.push_str(line);
            frontmatter.push('\n');
        }
    }
    if let Some(timezone) = &definition.timezone {
        frontmatter.push_str(&format!("timezone: {}\n", yaml_quote(timezone)));
    }
    if let Some(model) = &definition.model {
        frontmatter.push_str("model:\n");
        frontmatter.push_str(&format!(
            "  provider: {}\n  model_id: {}\n  api_key_env: {}\n  max_tokens: {}\n",
            match model.provider {
                ProviderKind::Anthropic => "anthropic",
                ProviderKind::Openrouter => "openrouter",
            },
            yaml_quote(&model.model_id),
            yaml_quote(&model.api_key_env),
            model.max_tokens
        ));
    }
    if !definition.allowed_tools.is_empty() {
        frontmatter.push_str("allowed-tools:\n");
        for tool in &definition.allowed_tools {
            frontmatter.push_str(&format!("  - {}\n", tool));
        }
    }
    if let Some(timeout_s) = definition.timeout_s {
        frontmatter.push_str(&format!("timeout_s: {}\n", timeout_s));
    }
    if let Some(report) = definition.report {
        frontmatter.push_str(&format!(
            "report: {}\n",
            match report {
                JobReportPolicyPayload::Always => "always",
                JobReportPolicyPayload::OnFailure => "on_failure",
                JobReportPolicyPayload::OnAnomaly => "on_anomaly",
            }
        ));
    }
    if let Some(max_turns) = definition.max_turns {
        frontmatter.push_str(&format!("max_turns: {}\n", max_turns));
    }
    frontmatter.push_str("---\n\n");
    frontmatter.push_str(definition.prompt.trim_end());
    frontmatter.push('\n');
    fs::write(path, frontmatter)?;
    Ok(())
}

fn validate_job_name(name: &str) -> Result<(), DaemonError> {
    if name.is_empty()
        || !name
            .chars()
            .all(|ch| ch.is_ascii_lowercase() || ch.is_ascii_digit() || ch == '-')
    {
        return Err(DaemonError::Protocol(format!(
            "invalid job name `{name}`; expected kebab-case"
        )));
    }
    Ok(())
}

fn yaml_quote(value: &str) -> String {
    format!("{:?}", value)
}

fn parse_time(raw: &str) -> Result<NaiveTime, DaemonError> {
    NaiveTime::parse_from_str(raw.trim(), "%H:%M")
        .map_err(|e| DaemonError::Protocol(format!("invalid time `{raw}`: {e}")))
}

fn parse_weekday(raw: &str) -> Result<Weekday, DaemonError> {
    match raw.trim().to_ascii_lowercase().as_str() {
        "monday" => Ok(Weekday::Mon),
        "tuesday" => Ok(Weekday::Tue),
        "wednesday" => Ok(Weekday::Wed),
        "thursday" => Ok(Weekday::Thu),
        "friday" => Ok(Weekday::Fri),
        "saturday" => Ok(Weekday::Sat),
        "sunday" => Ok(Weekday::Sun),
        other => Err(DaemonError::Protocol(format!("invalid weekday `{other}`"))),
    }
}

fn parse_duration(raw: &str) -> Result<ChronoDuration, DaemonError> {
    let raw = raw.trim();
    let (value, unit) = raw.split_at(raw.len().saturating_sub(1));
    let amount: i64 = value
        .parse()
        .map_err(|_| DaemonError::Protocol(format!("invalid duration `{raw}`")))?;
    match unit {
        "m" => Ok(ChronoDuration::minutes(amount)),
        "h" => Ok(ChronoDuration::hours(amount)),
        "d" => Ok(ChronoDuration::days(amount)),
        "s" => Ok(ChronoDuration::seconds(amount)),
        _ => Err(DaemonError::Protocol(format!(
            "invalid duration unit `{unit}`"
        ))),
    }
}

fn to_rfc3339(ts: DateTime<Utc>) -> String {
    ts.to_rfc3339()
}

pub(crate) fn parse_rfc3339(raw: &str) -> Result<DateTime<Utc>, DaemonError> {
    DateTime::parse_from_rfc3339(raw)
        .map(|dt| dt.with_timezone(&Utc))
        .map_err(|e| DaemonError::Protocol(format!("invalid timestamp `{raw}`: {e}")))
}

fn update_state_after_run(
    state: &mut JobState,
    definition: &JobDefinition,
    defaults: &Config,
    started_at: DateTime<Utc>,
    ended_at: DateTime<Utc>,
    outcome: &str,
) -> Result<(), DaemonError> {
    state.last_run_at = Some(ended_at);
    if outcome == "success" {
        state.failure_streak = 0;
    } else {
        state.failure_streak = state.failure_streak.saturating_add(1);
    }

    match definition.schedule {
        JobSchedule::Once(_) => {
            state.next_due_at = None;
            state.paused = true;
        }
        _ => {
            state.next_due_at = Some(definition.schedule.advance_until_future(
                state.next_due_at.unwrap_or(started_at),
                ended_at,
                definition.timezone.as_deref(),
                defaults.jobs.default_timezone.as_deref(),
            )?);
        }
    }
    Ok(())
}

async fn execute_job(
    paths: &AllbertPaths,
    defaults: &Config,
    provider_factory: Arc<dyn ProviderFactory>,
    definition: &JobDefinition,
) -> Result<JobRunRecordPayload, DaemonError> {
    let run_id = uuid::Uuid::new_v4().to_string();
    let session_id = format!("job-{}-{}", definition.name, &run_id[..8]);
    let started_at = Utc::now();

    let mut config = defaults.clone();
    config.security.auto_confirm = false;
    if let Some(model) = &definition.model {
        config.model = ModelConfig {
            provider: match model.provider {
                ProviderKind::Anthropic => Provider::Anthropic,
                ProviderKind::Openrouter => Provider::Openrouter,
            },
            model_id: model.model_id.clone(),
            api_key_env: model.api_key_env.clone(),
            max_tokens: model.max_tokens,
        };
    }
    if let Some(max_turns) = definition.max_turns {
        config.limits.max_turns = max_turns;
    }

    let adapter = FrontendAdapter {
        on_event: Box::new(|_| {}),
        confirm: Arc::new(JobConfirmPrompter),
        input: Arc::new(JobInputPrompter),
    };

    let mut kernel = Kernel::boot_with_paths_and_factory(
        config,
        adapter,
        paths.clone(),
        provider_factory,
        Some(session_id.clone()),
    )
    .await
    .map_err(map_kernel_error)?;

    let mut outcome = "success".to_string();
    let mut stop_reason = None;

    match kernel.run_turn(&definition.prompt).await {
        Ok(summary) => {
            if summary.hit_turn_limit {
                outcome = "limit".into();
                stop_reason = Some("hit max-turns limit".into());
            }
        }
        Err(err) => {
            outcome = "failure".into();
            stop_reason = Some(err.to_string());
        }
    }

    let ended_at = Utc::now();
    Ok(JobRunRecordPayload {
        run_id,
        job_name: definition.name.clone(),
        session_id,
        started_at: to_rfc3339(started_at),
        ended_at: to_rfc3339(ended_at),
        outcome,
        cost_usd: kernel.session_cost_usd(),
        skills_attached: definition.skills.clone(),
        stop_reason,
    })
}

fn append_run_record(
    paths: &AllbertPaths,
    record: &JobRunRecordPayload,
) -> Result<(), DaemonError> {
    use std::io::Write;

    fs::create_dir_all(&paths.jobs_runs)?;
    let date = &record.started_at[..10];
    let path = paths.jobs_runs.join(format!("{date}.jsonl"));
    let encoded = serde_json::to_string(record)
        .map_err(|e| DaemonError::Protocol(format!("encode run record: {e}")))?;
    let mut file = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)?;
    writeln!(file, "{encoded}")?;
    if record.outcome != "success" {
        fs::create_dir_all(&paths.jobs_failures)?;
        let failure_path = paths.jobs_failures.join(format!("{date}.jsonl"));
        let mut failures = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(failure_path)?;
        writeln!(
            failures,
            "{}",
            serde_json::to_string(record)
                .map_err(|e| DaemonError::Protocol(format!("encode failure record: {e}")))?
        )?;
    }
    Ok(())
}

fn map_kernel_error(error: KernelError) -> DaemonError {
    DaemonError::Protocol(error.to_string())
}

struct JobConfirmPrompter;

#[async_trait::async_trait]
impl allbert_kernel::ConfirmPrompter for JobConfirmPrompter {
    async fn confirm(
        &self,
        _req: allbert_kernel::ConfirmRequest,
    ) -> allbert_kernel::ConfirmDecision {
        allbert_kernel::ConfirmDecision::Deny
    }
}

struct JobInputPrompter;

#[async_trait::async_trait]
impl InputPrompter for JobInputPrompter {
    async fn request_input(&self, _req: InputRequest) -> InputResponse {
        InputResponse::Cancelled
    }
}
