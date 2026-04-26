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
use tokio_util::sync::CancellationToken;

use allbert_kernel::{
    llm::ProviderFactory, AllbertPaths, Config, FrontendAdapter, Kernel, KernelError, ModelConfig,
    Provider,
};
use allbert_proto::{
    ActivityPhase, ActivitySnapshot, ChannelKind, JobBudgetPayload, JobDefinitionPayload,
    JobReportPolicyPayload, JobRunRecordPayload, JobStatePayload, JobStatusPayload,
    ModelConfigPayload, ProviderKind,
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
        if self.running.contains(name) {
            return Err(DaemonError::Protocol(format!(
                "cannot remove running job: {name}"
            )));
        }
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

    pub fn prepare_run_now(
        &mut self,
        defaults: &Config,
        name: &str,
    ) -> Result<JobDefinition, DaemonError> {
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
        if self.running.len() >= defaults.jobs.max_concurrent_runs {
            return Err(DaemonError::Protocol(format!(
                "job concurrency limit reached: {}",
                defaults.jobs.max_concurrent_runs
            )));
        }
        self.running.insert(name.to_string());
        Ok(definition)
    }

    pub fn plan_due_runs(
        &mut self,
        paths: &AllbertPaths,
        defaults: &Config,
        now: DateTime<Utc>,
    ) -> Result<Vec<JobDefinition>, DaemonError> {
        let mut names = self.definitions.keys().cloned().collect::<Vec<_>>();
        names.sort();
        let available_slots = defaults
            .jobs
            .max_concurrent_runs
            .saturating_sub(self.running.len());
        let mut planned = Vec::new();

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

            if planned.len() >= available_slots {
                continue;
            }

            self.running.insert(name.clone());
            planned.push(definition);
        }

        self.persist_states(paths)?;
        Ok(planned)
    }

    pub fn finish_run(
        &mut self,
        paths: &AllbertPaths,
        defaults: &Config,
        name: &str,
        record: JobRunRecordPayload,
    ) -> Result<JobRunRecordPayload, DaemonError> {
        self.running.remove(name);
        let definition = self
            .definitions
            .get(name)
            .cloned()
            .ok_or_else(|| DaemonError::Protocol(format!("job not found: {name}")))?;
        let state = self.states.entry(name.to_string()).or_default();
        update_state_after_run(
            state,
            &definition,
            defaults,
            &record.run_id,
            parse_rfc3339(&record.started_at)?,
            parse_rfc3339(&record.ended_at)?,
            &record.outcome,
            record.stop_reason.as_deref(),
        )?;
        self.persist_states(paths)?;
        append_run_record(paths, &record)?;
        Ok(record)
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
                last_run_id: state.last_run_id,
                last_outcome: state.last_outcome,
                last_stop_reason: state.last_stop_reason,
            },
        })
    }

    fn persist_states(&self, paths: &AllbertPaths) -> Result<(), DaemonError> {
        for (name, state) in &self.states {
            let path = paths.jobs_state.join(format!("{name}.json"));
            let encoded = serde_json::to_string_pretty(state)
                .map_err(|e| DaemonError::Protocol(format!("encode state: {e}")))?;
            atomic_write(&path, encoded.as_bytes())?;
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
    pub budget: Option<JobBudgetPayload>,
    pub session_name: Option<String>,
    pub memory_prefetch: Option<bool>,
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
            budget: payload.budget,
            session_name: payload.session_name,
            memory_prefetch: payload.memory_prefetch,
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
            budget: self.budget.clone(),
            session_name: self.session_name.clone(),
            memory_prefetch: self.memory_prefetch,
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
    #[serde(default)]
    last_run_id: Option<String>,
    #[serde(default)]
    last_outcome: Option<String>,
    #[serde(default)]
    last_stop_reason: Option<String>,
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
                    date += ChronoDuration::days(1);
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
    #[serde(default)]
    budget: Option<JobBudgetFrontmatter>,
    #[serde(default)]
    session_name: Option<String>,
    #[serde(default)]
    memory: Option<JobMemoryFrontmatter>,
}

#[derive(Debug, Deserialize, Default)]
#[serde(deny_unknown_fields)]
struct JobMemoryFrontmatter {
    #[serde(default)]
    prefetch: Option<bool>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct JobBudgetFrontmatter {
    #[serde(default)]
    max_turn_usd: Option<f64>,
    #[serde(default)]
    max_turn_s: Option<u64>,
}

#[derive(Debug, Deserialize)]
struct JobModelFrontmatter {
    provider: ProviderKind,
    model_id: String,
    #[serde(default)]
    api_key_env: Option<String>,
    #[serde(default)]
    base_url: Option<String>,
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
                base_url: model.base_url,
                max_tokens: model.max_tokens.unwrap_or(4096),
                context_window_tokens: 0,
            }),
            allowed_tools: data.allowed_tools.normalize(),
            timeout_s: data.timeout_s,
            report: data.report,
            max_turns: data.max_turns,
            budget: data.budget.map(|budget| JobBudgetPayload {
                max_turn_usd: budget.max_turn_usd,
                max_turn_s: budget.max_turn_s,
            }),
            session_name: data.session_name,
            memory_prefetch: data.memory.and_then(|memory| memory.prefetch),
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
            "  provider: {}\n  model_id: {}\n",
            Provider::from_proto_kind(model.provider).label(),
            yaml_quote(&model.model_id)
        ));
        if let Some(api_key_env) = &model.api_key_env {
            frontmatter.push_str(&format!("  api_key_env: {}\n", yaml_quote(api_key_env)));
        }
        if let Some(base_url) = &model.base_url {
            frontmatter.push_str(&format!("  base_url: {}\n", yaml_quote(base_url)));
        }
        frontmatter.push_str(&format!("  max_tokens: {}\n", model.max_tokens));
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
    if let Some(budget) = &definition.budget {
        if budget.max_turn_usd.is_some() || budget.max_turn_s.is_some() {
            frontmatter.push_str("budget:\n");
            if let Some(max_turn_usd) = budget.max_turn_usd {
                frontmatter.push_str(&format!("  max_turn_usd: {:.6}\n", max_turn_usd));
            }
            if let Some(max_turn_s) = budget.max_turn_s {
                frontmatter.push_str(&format!("  max_turn_s: {}\n", max_turn_s));
            }
        }
    }
    if let Some(session_name) = &definition.session_name {
        frontmatter.push_str(&format!("session_name: {}\n", yaml_quote(session_name)));
    }
    if let Some(prefetch) = definition.memory_prefetch {
        frontmatter.push_str("memory:\n");
        frontmatter.push_str(&format!("  prefetch: {}\n", prefetch));
    }
    frontmatter.push_str("---\n\n");
    frontmatter.push_str(definition.prompt.trim_end());
    frontmatter.push('\n');
    atomic_write(&path, frontmatter.as_bytes())?;
    Ok(())
}

fn atomic_write(path: &Path, bytes: &[u8]) -> Result<(), std::io::Error> {
    let Some(parent) = path.parent() else {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            format!("path has no parent: {}", path.display()),
        ));
    };
    let _ = parent;
    allbert_kernel::atomic_write(path, bytes)
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

#[allow(clippy::too_many_arguments)]
fn update_state_after_run(
    state: &mut JobState,
    definition: &JobDefinition,
    defaults: &Config,
    run_id: &str,
    started_at: DateTime<Utc>,
    ended_at: DateTime<Utc>,
    outcome: &str,
    stop_reason: Option<&str>,
) -> Result<(), DaemonError> {
    state.last_run_at = Some(ended_at);
    state.last_run_id = Some(run_id.to_string());
    state.last_outcome = Some(outcome.to_string());
    state.last_stop_reason = stop_reason.map(|value| value.to_string());
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

#[allow(clippy::too_many_arguments)]
pub(crate) async fn execute_job(
    paths: &AllbertPaths,
    defaults: &Config,
    provider_factory: Arc<dyn ProviderFactory>,
    shared_ephemeral_sessions: Arc<tokio::sync::Mutex<HashMap<String, Vec<String>>>>,
    shutdown: CancellationToken,
    definition: &JobDefinition,
    run_id: String,
    session_id: String,
    adapter: FrontendAdapter,
) -> JobRunRecordPayload {
    let started_at = Utc::now();

    let mut config = defaults.clone();
    config.security.auto_confirm = false;
    if let Some(model) = &definition.model {
        config.model = ModelConfig {
            provider: Provider::from_proto_kind(model.provider),
            model_id: model.model_id.clone(),
            api_key_env: model.api_key_env.clone(),
            base_url: model.base_url.clone(),
            max_tokens: model.max_tokens,
            context_window_tokens: 0,
        };
    }
    if let Some(max_turns) = definition.max_turns {
        config.limits.max_turns = max_turns;
    }
    if let Some(budget) = &definition.budget {
        if let Some(max_turn_usd) = budget.max_turn_usd {
            config.limits.max_turn_usd = max_turn_usd;
        }
        if let Some(max_turn_s) = budget.max_turn_s {
            config.limits.max_turn_s = max_turn_s;
        }
    }
    if matches!(definition.memory_prefetch, Some(false)) {
        config.memory.prefetch_enabled = false;
    }

    let ended_at;
    if definition.name == allbert_kernel::PERSONALITY_ADAPTER_JOB_NAME {
        let result = allbert_kernel::run_personality_adapter_training_with_session(
            paths,
            &config,
            &session_id,
        );
        ended_at = Utc::now();
        let (outcome, stop_reason) = match result {
            Ok(_) => ("success".to_string(), None),
            Err(err) => ("failure".to_string(), Some(err.to_string())),
        };
        return JobRunRecordPayload {
            run_id,
            job_name: definition.name.clone(),
            session_id: session_id.clone(),
            started_at: to_rfc3339(started_at),
            ended_at: to_rfc3339(ended_at),
            outcome,
            cost_usd: 0.0,
            skills_attached: definition.skills.clone(),
            stop_reason,
            last_activity: Some(ActivitySnapshot {
                phase: ActivityPhase::Training,
                label: "personality adapter training finished".into(),
                started_at: to_rfc3339(started_at),
                elapsed_ms: ended_at
                    .signed_duration_since(started_at)
                    .num_milliseconds()
                    .max(0)
                    .try_into()
                    .unwrap_or(u64::MAX),
                session_id,
                channel: ChannelKind::Jobs,
                tool_name: None,
                tool_summary: None,
                skill_name: None,
                approval_id: None,
                last_progress_at: Some(to_rfc3339(ended_at)),
                stuck_hint: None,
                next_actions: vec!["review the adapter approval".into()],
            }),
        };
    }

    let boot = Kernel::boot_with_paths_and_factory(
        config,
        adapter,
        paths.clone(),
        provider_factory,
        Some(session_id.clone()),
    );
    tokio::pin!(boot);
    let (outcome, stop_reason, cost_usd) = match tokio::select! {
        _ = shutdown.cancelled() => None,
        result = &mut boot => Some(result),
    } {
        None => {
            ended_at = Utc::now();
            (
                "interrupted".to_string(),
                Some("daemon shutdown".into()),
                0.0,
            )
        }
        Some(Ok(mut kernel)) => {
            if let Some(session_name) = &definition.session_name {
                if let Some(snapshot) = shared_ephemeral_sessions
                    .lock()
                    .await
                    .get(session_name)
                    .cloned()
                {
                    kernel.restore_ephemeral_memory(snapshot);
                }
            }
            let (outcome, stop_reason) = {
                if let Some(err) = definition
                    .skills
                    .iter()
                    .find_map(|skill| kernel.activate_session_skill(skill, None).err())
                {
                    ("failure".to_string(), Some(err.to_string()))
                } else {
                    let turn = kernel.run_job_turn(&definition.name, &definition.prompt);
                    tokio::pin!(turn);
                    tokio::select! {
                        _ = shutdown.cancelled() => {
                            ("interrupted".to_string(), Some("daemon shutdown".into()))
                        }
                        result = &mut turn => match result {
                            Ok(summary) => {
                                if summary.hit_turn_limit {
                                    (
                                        "limit".to_string(),
                                        summary
                                            .stop_reason
                                            .clone()
                                            .or_else(|| Some("hit turn limit".into())),
                                    )
                                } else {
                                    ("success".to_string(), None)
                                }
                            }
                            Err(err) => match err {
                                KernelError::CostCap(message) => {
                                    ("cap-reached".to_string(), Some(message))
                                }
                                other => ("failure".to_string(), Some(other.to_string())),
                            },
                        }
                    }
                }
            };
            if let Some(session_name) = &definition.session_name {
                shared_ephemeral_sessions
                    .lock()
                    .await
                    .insert(session_name.clone(), kernel.ephemeral_memory_entries());
            }
            ended_at = Utc::now();
            (outcome, stop_reason, kernel.session_cost_usd())
        }
        Some(Err(err)) => {
            ended_at = Utc::now();
            (
                "failure".to_string(),
                Some(map_kernel_error(err).to_string()),
                0.0,
            )
        }
    };

    JobRunRecordPayload {
        run_id,
        job_name: definition.name.clone(),
        session_id,
        started_at: to_rfc3339(started_at),
        ended_at: to_rfc3339(ended_at),
        outcome,
        cost_usd,
        skills_attached: definition.skills.clone(),
        stop_reason,
        last_activity: None,
    }
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

pub(crate) fn list_run_records(
    paths: &AllbertPaths,
    name: Option<&str>,
    only_failures: bool,
    limit: usize,
) -> Result<Vec<JobRunRecordPayload>, DaemonError> {
    let root = if only_failures {
        &paths.jobs_failures
    } else {
        &paths.jobs_runs
    };
    let Ok(entries) = fs::read_dir(root) else {
        return Ok(Vec::new());
    };

    let mut files = entries
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| path.extension().and_then(|ext| ext.to_str()) == Some("jsonl"))
        .collect::<Vec<_>>();
    files.sort();
    files.reverse();

    let mut records = Vec::new();
    let clamped_limit = limit.clamp(1, 100);
    for path in files {
        let raw = fs::read_to_string(&path)?;
        for line in raw.lines().rev() {
            if line.trim().is_empty() {
                continue;
            }
            let record: JobRunRecordPayload = serde_json::from_str(line)
                .map_err(|e| DaemonError::Protocol(format!("parse {}: {e}", path.display())))?;
            if let Some(job_name) = name {
                if record.job_name != job_name {
                    continue;
                }
            }
            records.push(record);
            if records.len() >= clamped_limit {
                return Ok(records);
            }
        }
    }
    Ok(records)
}

fn map_kernel_error(error: KernelError) -> DaemonError {
    DaemonError::Protocol(error.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    static TEMP_COUNTER: AtomicUsize = AtomicUsize::new(0);

    struct TempJobsRoot {
        root: std::path::PathBuf,
    }

    impl TempJobsRoot {
        fn new() -> Self {
            let counter = TEMP_COUNTER.fetch_add(1, Ordering::Relaxed);
            let root = std::env::temp_dir().join(format!(
                "allbert-daemon-jobs-{}-{counter}",
                std::process::id()
            ));
            fs::create_dir_all(&root).expect("temp jobs root should be created");
            Self { root }
        }
    }

    impl Drop for TempJobsRoot {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }

    #[test]
    fn job_definition_writer_omits_api_key_env_for_keyless_ollama() {
        let temp = TempJobsRoot::new();
        let definition = JobDefinition::from_payload(JobDefinitionPayload {
            name: "local-brief".into(),
            description: "Local brief".into(),
            enabled: true,
            schedule: "@daily".into(),
            skills: Vec::new(),
            timezone: None,
            model: Some(ModelConfigPayload {
                provider: ProviderKind::Ollama,
                model_id: "gemma4".into(),
                api_key_env: None,
                base_url: Some("http://127.0.0.1:11434".into()),
                max_tokens: 2048,
                context_window_tokens: 0,
            }),
            allowed_tools: Vec::new(),
            timeout_s: None,
            report: None,
            max_turns: None,
            budget: None,
            session_name: None,
            memory_prefetch: None,
            prompt: "Summarize locally.".into(),
        })
        .expect("payload should convert");

        write_definition_file(&temp.root, &definition).expect("definition should write");
        let raw = fs::read_to_string(temp.root.join("local-brief.md"))
            .expect("definition file should read");
        assert!(raw.contains("provider: ollama"));
        assert!(raw.contains("base_url:"));
        assert!(!raw.contains("api_key_env:"));

        let loaded = load_definitions(&temp.root).expect("definition should load");
        let model = loaded
            .get("local-brief")
            .and_then(|definition| definition.model.as_ref())
            .expect("model should load");
        assert_eq!(model.provider, ProviderKind::Ollama);
        assert_eq!(model.api_key_env, None);
        assert_eq!(model.base_url.as_deref(), Some("http://127.0.0.1:11434"));
    }
}
