use std::collections::BTreeSet;
use std::fs;
use std::path::Path;

use allbert_proto::ChannelKind;
use gray_matter::engine::YAML;
use gray_matter::Matter;
use serde::{Deserialize, Serialize};
use time::format_description::well_known::Rfc3339;
use time::OffsetDateTime;
use uuid::Uuid;

use crate::{AllbertPaths, KernelError};

pub const LEGACY_SENTINEL_IDENTITY: &str = "usr_legacy_unmapped";
pub const LOCAL_REPL_SENDER: &str = "local";

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct IdentityChannelBinding {
    pub kind: ChannelKind,
    pub sender: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IdentityRecord {
    pub id: String,
    pub name: String,
    pub created_at: String,
    pub channels: Vec<IdentityChannelBinding>,
    pub body: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IdentityConsistency {
    pub warnings: Vec<String>,
    pub migration_candidates: Vec<IdentityChannelBinding>,
}

#[derive(Debug, Deserialize)]
struct IdentityFrontmatter {
    id: String,
    name: String,
    created_at: String,
    channels: Vec<IdentityChannelBinding>,
}

pub fn ensure_identity_record(paths: &AllbertPaths) -> Result<IdentityRecord, KernelError> {
    paths.ensure()?;
    if !paths.identity_user.exists() {
        let seeded = IdentityRecord {
            id: generate_user_id(),
            name: "primary".into(),
            created_at: now_rfc3339()?,
            channels: vec![IdentityChannelBinding {
                kind: ChannelKind::Repl,
                sender: "local".into(),
            }],
            body: String::new(),
        };
        save_identity_record(paths, &seeded)?;
        return Ok(seeded);
    }
    load_identity_record(paths)
}

pub fn load_identity_record(paths: &AllbertPaths) -> Result<IdentityRecord, KernelError> {
    let raw = fs::read_to_string(&paths.identity_user).map_err(|err| {
        KernelError::InitFailed(format!("read {}: {err}", paths.identity_user.display()))
    })?;
    parse_identity_markdown(&raw, &paths.identity_user)
}

pub fn save_identity_record(
    paths: &AllbertPaths,
    record: &IdentityRecord,
) -> Result<(), KernelError> {
    validate_record(record, Some(&paths.identity_user))?;
    let rendered = render_identity_markdown(record);
    crate::atomic_write(&paths.identity_user, rendered.as_bytes()).map_err(|err| {
        KernelError::InitFailed(format!("write {}: {err}", paths.identity_user.display()))
    })
}

pub fn add_identity_channel(
    paths: &AllbertPaths,
    kind: ChannelKind,
    sender: &str,
) -> Result<IdentityRecord, KernelError> {
    let mut record = ensure_identity_record(paths)?;
    let sender = normalize_sender(sender)?;
    if record
        .channels
        .iter()
        .any(|binding| binding.kind == kind && binding.sender == sender)
    {
        return Err(KernelError::Request(format!(
            "identity already includes channel binding {kind:?}:{sender}"
        )));
    }
    record
        .channels
        .push(IdentityChannelBinding { kind, sender });
    sort_bindings(&mut record.channels);
    save_identity_record(paths, &record)?;
    Ok(record)
}

pub fn remove_identity_channel(
    paths: &AllbertPaths,
    kind: ChannelKind,
    sender: &str,
) -> Result<IdentityRecord, KernelError> {
    let mut record = ensure_identity_record(paths)?;
    let sender = normalize_sender(sender)?;
    let original_len = record.channels.len();
    record
        .channels
        .retain(|binding| !(binding.kind == kind && binding.sender == sender));
    if record.channels.len() == original_len {
        return Err(KernelError::Request(format!(
            "identity does not include channel binding {kind:?}:{sender}"
        )));
    }
    if record.channels.is_empty() {
        return Err(KernelError::Request(
            "identity must retain at least one channel binding".into(),
        ));
    }
    save_identity_record(paths, &record)?;
    Ok(record)
}

pub fn rename_identity(
    paths: &AllbertPaths,
    new_name: &str,
) -> Result<IdentityRecord, KernelError> {
    let mut record = ensure_identity_record(paths)?;
    let trimmed = new_name.trim();
    if trimmed.is_empty() {
        return Err(KernelError::Request(
            "identity name must not be empty".into(),
        ));
    }
    record.name = trimmed.into();
    save_identity_record(paths, &record)?;
    Ok(record)
}

pub fn identity_inconsistencies(
    paths: &AllbertPaths,
    record: &IdentityRecord,
) -> Result<IdentityConsistency, KernelError> {
    let mut warnings = Vec::new();
    let allowlisted_telegram = load_telegram_allowlist(&paths.telegram_allowed_chats)?;
    let record_telegram: BTreeSet<String> = record
        .channels
        .iter()
        .filter(|binding| binding.kind == ChannelKind::Telegram)
        .map(|binding| binding.sender.clone())
        .collect();

    for sender in record_telegram.difference(&allowlisted_telegram) {
        warnings.push(format!(
            "telegram sender {sender} is present in identity/user.md but missing from {}",
            paths.telegram_allowed_chats.display()
        ));
    }

    let migration_candidates = allowlisted_telegram
        .difference(&record_telegram)
        .map(|sender| IdentityChannelBinding {
            kind: ChannelKind::Telegram,
            sender: sender.clone(),
        })
        .collect::<Vec<_>>();

    if !migration_candidates.is_empty() {
        warnings.push(format!(
            "{} Telegram allowlisted sender(s) are not yet mapped into identity continuity. Use `allbert-cli identity add-channel telegram <sender>` to promote them.",
            migration_candidates.len()
        ));
    }

    Ok(IdentityConsistency {
        warnings,
        migration_candidates,
    })
}

pub fn resolve_identity_id_for_sender(
    paths: &AllbertPaths,
    kind: ChannelKind,
    sender: &str,
) -> Result<Option<String>, KernelError> {
    let record = ensure_identity_record(paths)?;
    let sender = normalize_sender(sender)?;
    Ok(record
        .channels
        .iter()
        .find(|binding| binding.kind == kind && binding.sender == sender)
        .map(|_| record.id))
}

fn parse_identity_markdown(raw: &str, path: &Path) -> Result<IdentityRecord, KernelError> {
    let matter = Matter::<YAML>::new();
    let parsed = matter
        .parse::<IdentityFrontmatter>(raw)
        .map_err(|err| KernelError::InitFailed(format!("parse {}: {err}", path.display())))?;
    let frontmatter = parsed.data.ok_or_else(|| {
        KernelError::InitFailed(format!("{} is missing YAML frontmatter", path.display()))
    })?;
    let body = parsed.content.trim().to_string();
    let record = IdentityRecord {
        id: frontmatter.id,
        name: frontmatter.name,
        created_at: frontmatter.created_at,
        channels: frontmatter.channels,
        body,
    };
    validate_record(&record, Some(path))?;
    Ok(record)
}

fn validate_record(record: &IdentityRecord, path: Option<&Path>) -> Result<(), KernelError> {
    let label = path
        .map(|value| value.display().to_string())
        .unwrap_or_else(|| "identity record".into());
    if !record.id.starts_with("usr_") || record.id.len() <= 4 {
        return Err(KernelError::InitFailed(format!(
            "{label}: id must start with `usr_`"
        )));
    }
    if record.name.trim().is_empty() {
        return Err(KernelError::InitFailed(format!(
            "{label}: name must not be empty"
        )));
    }
    OffsetDateTime::parse(&record.created_at, &Rfc3339).map_err(|err| {
        KernelError::InitFailed(format!("{label}: created_at must be RFC3339 ({err})"))
    })?;
    if record.channels.is_empty() {
        return Err(KernelError::InitFailed(format!(
            "{label}: channels must contain at least one sender"
        )));
    }
    let mut seen = BTreeSet::new();
    for binding in &record.channels {
        let normalized = normalize_sender(&binding.sender)?;
        if normalized != binding.sender {
            return Err(KernelError::InitFailed(format!(
                "{label}: sender values must not include leading or trailing whitespace"
            )));
        }
        let key = format!("{}:{}", channel_kind_label(binding.kind), binding.sender);
        if !seen.insert(key) {
            return Err(KernelError::InitFailed(format!(
                "{label}: duplicate channel binding {}:{}",
                channel_kind_label(binding.kind),
                binding.sender
            )));
        }
    }
    Ok(())
}

fn render_identity_markdown(record: &IdentityRecord) -> String {
    let mut rendered = format!(
        "---\nid: {}\nname: \"{}\"\ncreated_at: {}\nchannels:\n",
        record.id,
        escape_yaml_double_quoted(&record.name),
        record.created_at
    );
    for binding in &record.channels {
        rendered.push_str(&format!(
            "  - kind: {}\n    sender: \"{}\"\n",
            channel_kind_label(binding.kind),
            escape_yaml_double_quoted(&binding.sender)
        ));
    }
    rendered.push_str("---\n\n");
    if !record.body.trim().is_empty() {
        rendered.push_str(record.body.trim());
        rendered.push('\n');
    }
    rendered
}

fn now_rfc3339() -> Result<String, KernelError> {
    OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .map_err(|err| KernelError::InitFailed(format!("format time: {err}")))
}

fn normalize_sender(sender: &str) -> Result<String, KernelError> {
    let trimmed = sender.trim();
    if trimmed.is_empty() {
        return Err(KernelError::Request("sender must not be empty".into()));
    }
    Ok(trimmed.into())
}

fn sort_bindings(bindings: &mut [IdentityChannelBinding]) {
    bindings.sort_by(|a, b| {
        channel_kind_label(a.kind)
            .cmp(channel_kind_label(b.kind))
            .then_with(|| a.sender.cmp(&b.sender))
    });
}

fn load_telegram_allowlist(path: &Path) -> Result<BTreeSet<String>, KernelError> {
    if !path.exists() {
        return Ok(BTreeSet::new());
    }
    let raw = fs::read_to_string(path)
        .map_err(|err| KernelError::InitFailed(format!("read {}: {err}", path.display())))?;
    let mut senders = BTreeSet::new();
    for (idx, line) in raw.lines().enumerate() {
        let stripped = line.split('#').next().unwrap_or_default().trim();
        if stripped.is_empty() {
            continue;
        }
        stripped.parse::<i64>().map_err(|err| {
            KernelError::InitFailed(format!(
                "parse Telegram allowlisted chat on line {} in {}: {err}",
                idx + 1,
                path.display()
            ))
        })?;
        senders.insert(stripped.into());
    }
    Ok(senders)
}

fn channel_kind_label(kind: ChannelKind) -> &'static str {
    match kind {
        ChannelKind::Cli => "cli",
        ChannelKind::Repl => "repl",
        ChannelKind::Jobs => "jobs",
        ChannelKind::Telegram => "telegram",
    }
}

fn generate_user_id() -> String {
    let mut bytes = [0u8; 16];
    let now_ms = OffsetDateTime::now_utc().unix_timestamp_nanos() / 1_000_000;
    let time_bytes = (now_ms as u64).to_be_bytes();
    bytes[..6].copy_from_slice(&time_bytes[2..]);
    let random = Uuid::new_v4();
    bytes[6..].copy_from_slice(&random.as_bytes()[..10]);
    format!("usr_{}", encode_crockford_base32(&bytes))
}

fn encode_crockford_base32(bytes: &[u8; 16]) -> String {
    const ALPHABET: &[u8; 32] = b"0123456789ABCDEFGHJKMNPQRSTVWXYZ";
    let mut value = u128::from_be_bytes(*bytes);
    let mut encoded = [b'0'; 26];
    for idx in (0..26).rev() {
        encoded[idx] = ALPHABET[(value & 0x1f) as usize];
        value >>= 5;
    }
    String::from_utf8(encoded.to_vec()).expect("crockford output is ascii")
}

fn escape_yaml_double_quoted(value: &str) -> String {
    value.replace('\\', "\\\\").replace('"', "\\\"")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ensure_identity_record_seeds_local_repl_binding() {
        let temp = tempfile::tempdir().expect("tempdir");
        let paths = AllbertPaths::under(temp.path().join(".allbert"));
        let record = ensure_identity_record(&paths).expect("identity should seed");

        assert!(record.id.starts_with("usr_"));
        assert_eq!(record.name, "primary");
        assert_eq!(
            record.channels,
            vec![IdentityChannelBinding {
                kind: ChannelKind::Repl,
                sender: "local".into()
            }]
        );
        assert!(paths.identity_user.exists());
    }

    #[test]
    fn identity_consistency_surfaces_telegram_drift() {
        let temp = tempfile::tempdir().expect("tempdir");
        let paths = AllbertPaths::under(temp.path().join(".allbert"));
        paths.ensure().expect("paths ensure");
        fs::write(&paths.telegram_allowed_chats, "12345\n67890\n").expect("write allowlist");
        let record = IdentityRecord {
            id: "usr_test".into(),
            name: "primary".into(),
            created_at: "2026-04-20T18:00:00Z".into(),
            channels: vec![
                IdentityChannelBinding {
                    kind: ChannelKind::Repl,
                    sender: "local".into(),
                },
                IdentityChannelBinding {
                    kind: ChannelKind::Telegram,
                    sender: "67890".into(),
                },
            ],
            body: String::new(),
        };

        let consistency = identity_inconsistencies(&paths, &record).expect("consistency");
        assert_eq!(
            consistency.migration_candidates,
            vec![IdentityChannelBinding {
                kind: ChannelKind::Telegram,
                sender: "12345".into()
            }]
        );
        assert_eq!(consistency.warnings.len(), 1);
    }

    #[test]
    fn remove_identity_channel_refuses_to_empty_record() {
        let temp = tempfile::tempdir().expect("tempdir");
        let paths = AllbertPaths::under(temp.path().join(".allbert"));
        ensure_identity_record(&paths).expect("seed");
        let err = remove_identity_channel(&paths, ChannelKind::Repl, "local")
            .expect_err("should refuse empty identity");
        assert!(err
            .to_string()
            .contains("identity must retain at least one channel binding"));
    }
}
