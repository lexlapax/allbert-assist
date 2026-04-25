use std::collections::BTreeMap;
use std::path::Path;

use allbert_kernel::{AllbertPaths, Config};
use allbert_proto::{
    ChannelKind, InboxApprovalPayload, InboxResolveResultPayload, PatchApprovalPayload,
};
use anyhow::{anyhow, Context, Result};
use gray_matter::engine::YAML;
use gray_matter::Matter;
use serde::{Deserialize, Serialize};
use time::format_description::well_known::Rfc3339;
use time::OffsetDateTime;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ApprovalView {
    pub id: String,
    pub session_id: String,
    pub channel: ChannelKind,
    pub sender: String,
    pub agent: String,
    pub tool: String,
    pub request_id: u64,
    pub kind: String,
    pub requested_at: String,
    pub expires_at: String,
    pub status: String,
    pub resolved_at: Option<String>,
    pub resolver: Option<String>,
    pub reply: Option<String>,
    pub rendered: String,
    pub path: String,
    pub patch: Option<PatchApprovalPayload>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InboxPendingSummary {
    pub total_pending: usize,
    pub by_kind: BTreeMap<String, usize>,
}

#[derive(Debug, serde::Deserialize)]
struct SessionMetaIdentity {
    identity_id: Option<String>,
}

#[derive(Debug, Serialize, Deserialize)]
struct ApprovalFrontmatter {
    id: String,
    session_id: String,
    channel: ChannelKind,
    sender: String,
    agent: String,
    tool: String,
    request_id: u64,
    #[serde(default = "default_approval_kind")]
    kind: String,
    requested_at: String,
    expires_at: String,
    status: String,
    #[serde(default)]
    resolved_at: Option<String>,
    #[serde(default)]
    resolver: Option<String>,
    #[serde(default)]
    reply: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    source_checkout: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    branch: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    worktree_path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    validation: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    artifact_path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    overall: Option<String>,
}

fn default_approval_kind() -> String {
    "tool-approval".to_string()
}

pub fn list(paths: &AllbertPaths, json: bool) -> Result<String> {
    let mut approvals = load_all(paths)?;
    approvals.retain(|approval| approval.status == "pending");
    approvals.sort_by(|a, b| b.requested_at.cmp(&a.requested_at));

    render_list_entries(&approvals, json)
}

pub fn render_list_entries(entries: &[ApprovalView], json: bool) -> Result<String> {
    let approvals = entries.to_vec();

    if json {
        return Ok(serde_json::to_string_pretty(&approvals)?);
    }

    if approvals.is_empty() {
        return Ok("no pending approvals".into());
    }

    let mut lines = vec!["pending approvals:".to_string()];
    for approval in approvals {
        lines.push(format!(
            "- {}  session={}  channel={}  tool={}  requested_at={}",
            approval.id,
            approval.session_id,
            channel_label(approval.channel),
            approval.tool,
            approval.requested_at
        ));
        lines.push(format!(
            "  kind={}  sender={}  expires_at={}  agent={}",
            approval.kind, approval.sender, approval.expires_at, approval.agent
        ));
        if let Some(patch) = approval.patch.as_ref() {
            lines.push(format!(
                "  patch={}  validation={}  branch={}",
                patch.overall, patch.validation, patch.branch
            ));
        }
    }
    Ok(lines.join("\n"))
}

pub fn show(paths: &AllbertPaths, approval_id: &str, json: bool) -> Result<String> {
    let approval = load(paths, approval_id)?;

    render_show_entry(&approval, json)
}

pub fn load(paths: &AllbertPaths, approval_id: &str) -> Result<ApprovalView> {
    load_all(paths)?
        .into_iter()
        .find(|approval| approval.id == approval_id)
        .ok_or_else(|| anyhow!("approval not found: {approval_id}"))
}

pub fn render_show_entry(approval: &ApprovalView, json: bool) -> Result<String> {
    if json {
        return Ok(serde_json::to_string_pretty(&approval)?);
    }

    let patch_details = approval
        .patch
        .as_ref()
        .map(|patch| render_patch_details(approval, patch))
        .unwrap_or_default();
    let body = format!("{}{}", patch_details, approval.rendered.trim());

    Ok(format!(
        "approval:          {}\nsession:           {}\nchannel:           {}\nstatus:            {}\ntool:              {}\nagent:             {}\nsender:            {}\nrequested at:      {}\nexpires at:        {}\nresolved at:       {}\nresolver:          {}\nreply:             {}\nfile:              {}\n\n{}",
        approval.id,
        approval.session_id,
        channel_label(approval.channel),
        approval.status,
        approval.tool,
        approval.agent,
        approval.sender,
        approval.requested_at,
        approval.expires_at,
        approval.resolved_at.as_deref().unwrap_or("(pending)"),
        approval.resolver.as_deref().unwrap_or("(pending)"),
        approval.reply.as_deref().unwrap_or("(pending)"),
        approval.path,
        body,
    ))
}

pub fn render_resolution(result: &InboxResolveResultPayload) -> String {
    let mut rendered = format!("{} {}", result.status, result.approval_id);
    if let Some(note) = &result.note {
        rendered.push_str(&format!("\n{note}"));
    }
    rendered
}

fn load_all(paths: &AllbertPaths) -> Result<Vec<ApprovalView>> {
    let mut approvals = Vec::new();
    if !paths.sessions.exists() {
        return Ok(approvals);
    }

    for session_entry in std::fs::read_dir(&paths.sessions)
        .with_context(|| format!("read {}", paths.sessions.display()))?
    {
        let session_entry = session_entry?;
        if !session_entry.file_type()?.is_dir() {
            continue;
        }
        let session_name = session_entry.file_name();
        if session_name.to_string_lossy().starts_with('.') {
            continue;
        }
        let approvals_dir = session_entry.path().join("approvals");
        if !approvals_dir.is_dir() {
            continue;
        }
        for entry in std::fs::read_dir(&approvals_dir)
            .with_context(|| format!("read {}", approvals_dir.display()))?
        {
            let entry = entry?;
            if !entry.file_type()?.is_file() {
                continue;
            }
            if entry.path().extension().and_then(|value| value.to_str()) != Some("md") {
                continue;
            }
            approvals.push(load_one(&entry.path())?);
        }
    }

    Ok(approvals)
}

pub fn pending_summary_for_identity(
    paths: &AllbertPaths,
    identity_id: &str,
) -> Result<Option<InboxPendingSummary>> {
    let approvals = load_all(paths)?;
    let identity_by_session = session_identity_map(paths)?;
    let mut by_kind = BTreeMap::new();
    let mut total_pending = 0usize;
    for approval in approvals {
        if approval.status != "pending" {
            continue;
        }
        if identity_by_session
            .get(&approval.session_id)
            .map(String::as_str)
            != Some(identity_id)
        {
            continue;
        }
        total_pending += 1;
        *by_kind.entry(approval.kind).or_insert(0) += 1;
    }
    if total_pending == 0 {
        Ok(None)
    } else {
        Ok(Some(InboxPendingSummary {
            total_pending,
            by_kind,
        }))
    }
}

pub fn render_repl_attach_inbox_summary(summary: &InboxPendingSummary) -> String {
    let mut segments = vec![format!(
        "{} pending approval{}",
        summary.total_pending,
        if summary.total_pending == 1 { "" } else { "s" }
    )];
    for (kind, count) in summary
        .by_kind
        .iter()
        .filter(|(kind, _)| *kind != "tool-approval")
    {
        let label = match kind.as_str() {
            "cost-cap-override" => "cost-cap override",
            "job-approval" => "job approval",
            "patch-approval" => "patch approval",
            _ => kind,
        };
        segments.push(format!(
            "{} {}{}",
            count,
            label,
            if *count == 1 { "" } else { "s" }
        ));
    }
    format!("{}, see allbert-cli inbox list", segments.join(", "))
}

fn session_identity_map(paths: &AllbertPaths) -> Result<BTreeMap<String, String>> {
    let mut map = BTreeMap::new();
    if !paths.sessions.exists() {
        return Ok(map);
    }
    for session_entry in std::fs::read_dir(&paths.sessions)
        .with_context(|| format!("read {}", paths.sessions.display()))?
    {
        let session_entry = session_entry?;
        if !session_entry.file_type()?.is_dir() {
            continue;
        }
        let session_name = session_entry.file_name().to_string_lossy().to_string();
        if session_name.starts_with('.') {
            continue;
        }
        let meta_path = session_entry.path().join("meta.json");
        if !meta_path.exists() {
            continue;
        }
        let raw =
            std::fs::read(&meta_path).with_context(|| format!("read {}", meta_path.display()))?;
        let parsed: SessionMetaIdentity = match serde_json::from_slice(&raw) {
            Ok(parsed) => parsed,
            Err(_) => continue,
        };
        if let Some(identity_id) = parsed.identity_id {
            map.insert(session_name, identity_id);
        }
    }
    Ok(map)
}

fn load_one(path: &Path) -> Result<ApprovalView> {
    let raw = std::fs::read_to_string(path).with_context(|| format!("read {}", path.display()))?;
    let matter = Matter::<YAML>::new();
    let parsed = matter
        .parse::<ApprovalFrontmatter>(&raw)
        .map_err(|err| anyhow!("parse approval {}: {err}", path.display()))?;
    let frontmatter = parsed
        .data
        .ok_or_else(|| anyhow!("approval file missing frontmatter: {}", path.display()))?;

    let patch = patch_payload_from_frontmatter(&frontmatter);
    Ok(ApprovalView {
        id: frontmatter.id,
        session_id: frontmatter.session_id,
        channel: frontmatter.channel,
        sender: frontmatter.sender,
        agent: frontmatter.agent,
        tool: frontmatter.tool,
        request_id: frontmatter.request_id,
        kind: frontmatter.kind,
        requested_at: frontmatter.requested_at,
        expires_at: frontmatter.expires_at,
        status: frontmatter.status,
        resolved_at: frontmatter.resolved_at,
        resolver: frontmatter.resolver,
        reply: frontmatter.reply,
        rendered: parsed.content.trim().to_string(),
        path: path.display().to_string(),
        patch,
    })
}

fn patch_payload_from_frontmatter(
    frontmatter: &ApprovalFrontmatter,
) -> Option<PatchApprovalPayload> {
    if frontmatter.kind != "patch-approval" {
        return None;
    }
    Some(PatchApprovalPayload {
        source_checkout: frontmatter.source_checkout.clone().unwrap_or_default(),
        branch: frontmatter.branch.clone().unwrap_or_default(),
        worktree_path: frontmatter.worktree_path.clone().unwrap_or_default(),
        validation: frontmatter.validation.clone().unwrap_or_default(),
        artifact_path: frontmatter.artifact_path.clone().unwrap_or_default(),
        overall: frontmatter.overall.clone().unwrap_or_default(),
    })
}

fn render_patch_details(approval: &ApprovalView, patch: &PatchApprovalPayload) -> String {
    let stats = patch_stats(&patch.artifact_path);
    format!(
        "patch approval:\nsource checkout:  {}\nbranch:           {}\nworktree:         {}\nvalidation:       {}\noverall:          {}\nartifact:         {}\nfile stats:       {}\nnext steps:       allbert-cli self-improvement diff {} | allbert-cli self-improvement install {}\n\n",
        fallback(&patch.source_checkout),
        fallback(&patch.branch),
        fallback(&patch.worktree_path),
        fallback(&patch.validation),
        fallback(&patch.overall),
        fallback(&patch.artifact_path),
        stats,
        approval.id,
        approval.id,
    )
}

fn fallback(value: &str) -> &str {
    if value.trim().is_empty() {
        "(missing)"
    } else {
        value
    }
}

fn patch_stats(artifact_path: &str) -> String {
    let Ok(raw) = std::fs::read_to_string(artifact_path) else {
        return "unavailable".into();
    };
    let mut files = Vec::new();
    let mut added = 0usize;
    let mut removed = 0usize;
    for line in raw.lines() {
        if let Some(rest) = line.strip_prefix("diff --git ") {
            files.push(rest.to_string());
        } else if line.starts_with('+') && !line.starts_with("+++") {
            added += 1;
        } else if line.starts_with('-') && !line.starts_with("---") {
            removed += 1;
        }
    }
    if files.is_empty() && added == 0 && removed == 0 {
        "0 files, +0/-0".into()
    } else {
        format!("{} file(s), +{added}/-{removed}", files.len())
    }
}

fn maybe_cleanup_rejected_patch_worktree(
    config: &Config,
    approval: &ApprovalView,
) -> Result<Option<String>> {
    let Some(patch) = approval.patch.as_ref() else {
        return Ok(None);
    };
    if config.self_improvement.keep_rejected_worktree {
        return Ok(Some(format!(
            "rejected patch worktree preserved by self_improvement.keep_rejected_worktree: {}",
            fallback(&patch.worktree_path)
        )));
    }
    if patch.worktree_path.trim().is_empty() {
        return Ok(Some(
            "patch approval has no worktree_path to clean up".into(),
        ));
    }
    let path = Path::new(&patch.worktree_path);
    if !path.exists() {
        return Ok(Some(format!(
            "patch worktree already absent: {}",
            path.display()
        )));
    }
    std::fs::remove_dir_all(path)
        .with_context(|| format!("remove rejected patch worktree {}", path.display()))?;
    Ok(Some(format!(
        "removed rejected patch worktree: {}",
        path.display()
    )))
}

pub fn resolve(
    paths: &AllbertPaths,
    config: &Config,
    approval_id: &str,
    accept: bool,
    reason: Option<&str>,
) -> Result<String> {
    let approval = load_all(paths)?
        .into_iter()
        .find(|approval| approval.id == approval_id)
        .ok_or_else(|| anyhow!("approval not found: {approval_id}"))?;
    if approval.status != "pending" {
        return Ok(format!(
            "approval {} is already {}",
            approval.id, approval.status
        ));
    }
    let path = Path::new(&approval.path);
    let raw = std::fs::read_to_string(path).with_context(|| format!("read {}", path.display()))?;
    let matter = Matter::<YAML>::new();
    let parsed = matter
        .parse::<ApprovalFrontmatter>(&raw)
        .map_err(|err| anyhow!("parse approval {}: {err}", path.display()))?;
    let mut frontmatter = parsed
        .data
        .ok_or_else(|| anyhow!("approval file missing frontmatter: {}", path.display()))?;
    frontmatter.status = if accept {
        "accepted".into()
    } else {
        "rejected".into()
    };
    frontmatter.resolved_at = Some(now_rfc3339());
    frontmatter.resolver = Some("cli".into());
    frontmatter.reply = reason.map(|value| value.to_string());
    let frontmatter = serde_yaml::to_string(&frontmatter)?;
    let rendered = format!("---\n{}---\n\n{}", frontmatter, parsed.content.trim());
    atomic_write(path, rendered.as_bytes()).with_context(|| format!("write {}", path.display()))?;
    let mut message = format!(
        "{} {}",
        if accept { "accepted" } else { "rejected" },
        approval.id
    );
    if !accept {
        if let Some(note) = maybe_cleanup_rejected_patch_worktree(config, &approval)? {
            message.push_str(&format!("\n{note}"));
        }
    }
    Ok(message)
}

fn now_rfc3339() -> String {
    OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .unwrap_or_else(|_| "1970-01-01T00:00:00Z".to_string())
}

fn channel_label(kind: ChannelKind) -> &'static str {
    match kind {
        ChannelKind::Cli => "cli",
        ChannelKind::Repl => "repl",
        ChannelKind::Jobs => "jobs",
        ChannelKind::Telegram => "telegram",
    }
}

fn atomic_write(path: &Path, bytes: &[u8]) -> Result<()> {
    let Some(_parent) = path.parent() else {
        return Err(anyhow!("path has no parent: {}", path.display()));
    };
    allbert_kernel::atomic_write(path, bytes).with_context(|| format!("write {}", path.display()))
}

impl From<InboxApprovalPayload> for ApprovalView {
    fn from(value: InboxApprovalPayload) -> Self {
        Self {
            id: value.id,
            session_id: value.session_id,
            channel: value.channel,
            sender: value.sender,
            agent: value.agent,
            tool: value.tool,
            request_id: value.request_id,
            kind: value.kind,
            requested_at: value.requested_at,
            expires_at: value.expires_at,
            status: value.status,
            resolved_at: value.resolved_at,
            resolver: value.resolver,
            reply: value.reply,
            rendered: value.rendered,
            path: value.path,
            patch: value.patch,
        }
    }
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicUsize, Ordering};

    use super::*;

    static TEMP_COUNTER: AtomicUsize = AtomicUsize::new(0);

    struct TempRoot {
        path: PathBuf,
    }

    impl TempRoot {
        fn new() -> Self {
            let unique = format!(
                "allbert-approvals-{}-{}",
                std::process::id(),
                TEMP_COUNTER.fetch_add(1, Ordering::Relaxed)
            );
            let path = std::env::temp_dir().join(unique);
            std::fs::create_dir_all(&path).expect("temp root should create");
            Self { path }
        }

        fn paths(&self) -> AllbertPaths {
            AllbertPaths::under(self.path.clone())
        }
    }

    impl Drop for TempRoot {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.path);
        }
    }

    #[test]
    fn list_filters_to_pending_entries() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().expect("paths should ensure");

        write_approval(
            &paths,
            "session-a",
            "appr_pending",
            "pending",
            "2026-04-20T10:00:00Z",
        );
        write_approval(
            &paths,
            "session-b",
            "appr_done",
            "accepted",
            "2026-04-20T09:00:00Z",
        );

        let rendered = list(&paths, false).expect("list should render");
        assert!(rendered.contains("appr_pending"));
        assert!(!rendered.contains("appr_done"));
    }

    #[test]
    fn show_renders_resolution_details() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().expect("paths should ensure");
        write_approval(
            &paths,
            "session-a",
            "appr_done",
            "accepted",
            "2026-04-20T10:00:00Z",
        );

        let rendered = show(&paths, "appr_done", false).expect("show should render");
        assert!(rendered.contains("approval:          appr_done"));
        assert!(rendered.contains("status:            accepted"));
        assert!(rendered.contains("process_exec --flag"));
    }

    #[test]
    fn pending_summary_filters_to_identity() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().expect("paths should ensure");
        write_session_meta(&paths, "session-a", Some("usr_a"));
        write_session_meta(&paths, "session-b", Some("usr_b"));
        write_approval(
            &paths,
            "session-a",
            "appr_a",
            "pending",
            "2026-04-20T10:00:00Z",
        );
        write_approval(
            &paths,
            "session-b",
            "appr_b",
            "pending",
            "2026-04-20T09:00:00Z",
        );

        let summary = pending_summary_for_identity(&paths, "usr_a")
            .expect("summary should load")
            .expect("summary should exist");
        assert_eq!(summary.total_pending, 1);
        assert_eq!(summary.by_kind.get("tool-approval"), Some(&1));
    }

    #[test]
    fn repl_attach_summary_mentions_special_kinds() {
        let mut summary = InboxPendingSummary {
            total_pending: 3,
            by_kind: BTreeMap::new(),
        };
        summary.by_kind.insert("tool-approval".into(), 2);
        summary.by_kind.insert("cost-cap-override".into(), 1);
        let rendered = render_repl_attach_inbox_summary(&summary);
        assert!(rendered.contains("3 pending approvals"));
        assert!(rendered.contains("1 cost-cap override"));
        assert!(rendered.contains("see allbert-cli inbox list"));
    }

    #[test]
    fn patch_approval_show_renders_metadata_stats_and_next_steps() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().expect("paths should ensure");
        let artifact = paths
            .sessions
            .join("session-a")
            .join("artifacts")
            .join("approval_patch")
            .join("patch.diff");
        write_patch_artifact(&artifact);
        let worktree = paths.root.join("worktrees/patch-a");
        std::fs::create_dir_all(&worktree).expect("worktree should create");
        write_patch_approval(&paths, "session-a", "approval_patch", &artifact, &worktree);

        let rendered = show(&paths, "approval_patch", false).expect("show should render");

        assert!(rendered.contains("patch approval:"));
        assert!(rendered.contains("overall:          safe-to-merge"));
        assert!(rendered.contains("file stats:"));
        assert!(rendered.contains("allbert-cli self-improvement diff approval_patch"));
        assert!(rendered.contains(artifact.to_string_lossy().as_ref()));
    }

    #[test]
    fn patch_approval_accept_records_only_and_preserves_worktree() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().expect("paths should ensure");
        let artifact = paths
            .sessions
            .join("session-a")
            .join("artifacts")
            .join("approval_patch")
            .join("patch.diff");
        write_patch_artifact(&artifact);
        let worktree = paths.root.join("worktrees/patch-a");
        std::fs::create_dir_all(&worktree).expect("worktree should create");
        write_patch_approval(&paths, "session-a", "approval_patch", &artifact, &worktree);

        let rendered = resolve(
            &paths,
            &Config::default_template(),
            "approval_patch",
            true,
            Some("looks good"),
        )
        .expect("accept should resolve");

        assert!(rendered.contains("accepted approval_patch"));
        assert!(worktree.exists());
    }

    #[test]
    fn patch_approval_reject_removes_worktree_by_default() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().expect("paths should ensure");
        let artifact = paths
            .sessions
            .join("session-a")
            .join("artifacts")
            .join("approval_patch")
            .join("patch.diff");
        write_patch_artifact(&artifact);
        let worktree = paths.root.join("worktrees/patch-a");
        std::fs::create_dir_all(&worktree).expect("worktree should create");
        write_patch_approval(&paths, "session-a", "approval_patch", &artifact, &worktree);

        let rendered = resolve(
            &paths,
            &Config::default_template(),
            "approval_patch",
            false,
            Some("not this one"),
        )
        .expect("reject should resolve");

        assert!(rendered.contains("rejected approval_patch"));
        assert!(rendered.contains("removed rejected patch worktree"));
        assert!(!worktree.exists());
    }

    #[test]
    fn patch_approval_reject_can_preserve_worktree_by_config() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().expect("paths should ensure");
        let artifact = paths
            .sessions
            .join("session-a")
            .join("artifacts")
            .join("approval_patch")
            .join("patch.diff");
        write_patch_artifact(&artifact);
        let worktree = paths.root.join("worktrees/patch-a");
        std::fs::create_dir_all(&worktree).expect("worktree should create");
        write_patch_approval(&paths, "session-a", "approval_patch", &artifact, &worktree);
        let mut config = Config::default_template();
        config.self_improvement.keep_rejected_worktree = true;

        let rendered =
            resolve(&paths, &config, "approval_patch", false, None).expect("reject should resolve");

        assert!(rendered.contains("preserved"));
        assert!(worktree.exists());
    }

    fn write_approval(
        paths: &AllbertPaths,
        session_id: &str,
        approval_id: &str,
        status: &str,
        requested_at: &str,
    ) {
        let dir = paths.sessions.join(session_id).join("approvals");
        std::fs::create_dir_all(&dir).expect("approval dir should create");
        let content = format!(
            "---\nid: {approval_id}\nsession_id: {session_id}\nchannel: telegram\nsender: telegram:123\nagent: allbert/root\ntool: process_exec\nrequest_id: 7\nrequested_at: {requested_at}\nexpires_at: 2026-04-20T11:00:00Z\nstatus: {status}\nresolved_at: 2026-04-20T10:05:00Z\nresolver: telegram:123\nreply: approved\n---\n\nprocess_exec --flag\n"
        );
        std::fs::write(dir.join(format!("{approval_id}.md")), content)
            .expect("approval file should write");
    }

    fn write_patch_approval(
        paths: &AllbertPaths,
        session_id: &str,
        approval_id: &str,
        artifact_path: &Path,
        worktree_path: &Path,
    ) {
        let dir = paths.sessions.join(session_id).join("approvals");
        std::fs::create_dir_all(&dir).expect("approval dir should create");
        let content = format!(
            "---\nid: {approval_id}\nsession_id: {session_id}\nchannel: repl\nsender: local\nagent: allbert/root\ntool: rust-rebuild\nrequest_id: 42\nkind: patch-approval\nrequested_at: 2026-04-20T10:00:00Z\nexpires_at: 2026-04-20T11:00:00Z\nstatus: pending\nsource_checkout: /tmp/allbert-source\nbranch: allbert-rebuild-test\nworktree_path: {}\nvalidation: passed\noverall: safe-to-merge\nartifact_path: {}\n---\n\nPatch summary for approval.\n",
            worktree_path.display(),
            artifact_path.display()
        );
        std::fs::write(dir.join(format!("{approval_id}.md")), content)
            .expect("approval file should write");
    }

    fn write_patch_artifact(path: &Path) {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).expect("artifact parent should create");
        }
        std::fs::write(
            path,
            "diff --git a/src/lib.rs b/src/lib.rs\n--- a/src/lib.rs\n+++ b/src/lib.rs\n@@ -1 +1 @@\n-old\n+new\n",
        )
        .expect("artifact should write");
    }

    fn write_session_meta(paths: &AllbertPaths, session_id: &str, identity_id: Option<&str>) {
        let dir = paths.sessions.join(session_id);
        std::fs::create_dir_all(&dir).expect("session dir should create");
        let content = match identity_id {
            Some(identity_id) => {
                format!("{{\"identity_id\":\"{identity_id}\"}}")
            }
            None => "{\"identity_id\":null}".to_string(),
        };
        std::fs::write(dir.join("meta.json"), content).expect("meta should write");
    }
}
