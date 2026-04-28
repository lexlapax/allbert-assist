use std::collections::BTreeMap;
use std::fs;
use std::time::Duration;

use allbert_kernel_services::{add_identity_channel, ensure_identity_record, AllbertPaths, Config};
use allbert_proto::ChannelKind;
use anyhow::{anyhow, Context, Result};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone)]
pub struct TelegramSetupOptions {
    pub token_env: String,
    pub chat_id: Option<i64>,
    pub latest: bool,
    pub yes: bool,
    pub no_identity: bool,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct TelegramSetupResult {
    pub dry_run: bool,
    pub selected_chat_id: i64,
    pub bot_username: Option<String>,
    pub token_source: String,
    pub candidate_count: usize,
    pub candidates: Vec<TelegramChatCandidate>,
    pub wrote_token: bool,
    pub allowlist_added: bool,
    pub channel_enabled: bool,
    pub identity_added: bool,
    pub identity_skipped: bool,
    pub daemon_restart_recommended: bool,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct TelegramChatCandidate {
    pub chat_id: i64,
    pub update_id: i64,
    pub message_id: Option<i32>,
    pub from_id: Option<u64>,
    pub chat_type: Option<String>,
    pub label: Option<String>,
    pub text_excerpt: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TelegramBotIdentity {
    pub username: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct TelegramUpdate {
    pub update_id: i64,
    pub message: Option<TelegramMessage>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct TelegramMessage {
    pub message_id: Option<i32>,
    pub from: Option<TelegramUser>,
    pub chat: TelegramChat,
    pub text: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct TelegramUser {
    pub id: u64,
}

#[derive(Debug, Clone, Deserialize)]
pub struct TelegramChat {
    pub id: i64,
    #[serde(rename = "type")]
    pub chat_type: Option<String>,
    pub title: Option<String>,
    pub username: Option<String>,
    pub first_name: Option<String>,
    pub last_name: Option<String>,
}

pub struct HttpTelegramSetupApi {
    client: reqwest::Client,
}

impl HttpTelegramSetupApi {
    pub fn new() -> Result<Self> {
        Ok(Self {
            client: reqwest::Client::builder()
                .timeout(Duration::from_secs(15))
                .build()
                .context("build Telegram setup HTTP client")?,
        })
    }
}

impl HttpTelegramSetupApi {
    async fn get_me(&self, token: &str) -> Result<TelegramBotIdentity> {
        let url = format!("https://api.telegram.org/bot{token}/getMe");
        let response = self
            .client
            .get(url)
            .send()
            .await
            .context("call Telegram getMe")?
            .json::<TelegramApiResponse<TelegramGetMe>>()
            .await
            .context("parse Telegram getMe response")?;
        let result = response.into_result("getMe")?;
        Ok(TelegramBotIdentity {
            username: result.username,
        })
    }

    async fn get_updates(&self, token: &str) -> Result<Vec<TelegramUpdate>> {
        let url = format!("https://api.telegram.org/bot{token}/getUpdates");
        let response = self
            .client
            .get(url)
            .send()
            .await
            .context("call Telegram getUpdates")?
            .json::<TelegramApiResponse<Vec<TelegramUpdate>>>()
            .await
            .context("parse Telegram getUpdates response")?;
        response.into_result("getUpdates")
    }
}

#[derive(Debug, Deserialize)]
struct TelegramApiResponse<T> {
    ok: bool,
    result: Option<T>,
    description: Option<String>,
}

impl<T> TelegramApiResponse<T> {
    fn into_result(self, method: &str) -> Result<T> {
        if self.ok {
            self.result
                .ok_or_else(|| anyhow!("Telegram {method} response omitted result"))
        } else {
            Err(anyhow!(
                "Telegram {method} failed: {}",
                self.description
                    .unwrap_or_else(|| "unknown Telegram API error".into())
            ))
        }
    }
}

#[derive(Debug, Deserialize)]
struct TelegramGetMe {
    username: Option<String>,
}

pub async fn setup_telegram(
    paths: &AllbertPaths,
    options: TelegramSetupOptions,
    daemon_restart_recommended: bool,
) -> Result<TelegramSetupResult> {
    let (token, token_source) = resolve_token(paths, &options.token_env)?;
    let api = HttpTelegramSetupApi::new()?;
    let bot = api.get_me(&token).await?;
    let updates = if options.chat_id.is_some() {
        Vec::new()
    } else {
        api.get_updates(&token).await?
    };
    setup_telegram_from_resolved(
        paths,
        &options,
        &token,
        token_source,
        bot,
        updates,
        daemon_restart_recommended,
    )
}

fn setup_telegram_from_resolved(
    paths: &AllbertPaths,
    options: &TelegramSetupOptions,
    token: &str,
    token_source: String,
    bot: TelegramBotIdentity,
    updates: Vec<TelegramUpdate>,
    daemon_restart_recommended: bool,
) -> Result<TelegramSetupResult> {
    let (selected_chat_id, candidates) = if let Some(chat_id) = options.chat_id {
        (chat_id, Vec::new())
    } else {
        let candidates = chat_candidates_from_updates(&updates);
        let selected = select_chat_id(&candidates, options.latest)?;
        (selected, candidates)
    };

    let mut wrote_token = false;
    let mut allowlist_added = false;
    let mut channel_enabled = false;
    let mut identity_added = false;

    if options.yes {
        paths.ensure().context("ensure Allbert profile paths")?;
        wrote_token = persist_token_if_needed(paths, token)?;
        allowlist_added = append_allowlisted_chat_if_missing(paths, selected_chat_id)?;

        let mut config = Config::load_or_create(paths)?;
        if !config.channels.telegram.enabled {
            config.channels.telegram.enabled = true;
            config.persist(paths)?;
            channel_enabled = true;
        }

        if !options.no_identity {
            identity_added = add_identity_binding_if_missing(paths, selected_chat_id)?;
        }
    }

    Ok(TelegramSetupResult {
        dry_run: !options.yes,
        selected_chat_id,
        bot_username: bot.username,
        token_source,
        candidate_count: candidates.len(),
        candidates,
        wrote_token,
        allowlist_added,
        channel_enabled,
        identity_added,
        identity_skipped: options.no_identity,
        daemon_restart_recommended,
    })
}

fn resolve_token(paths: &AllbertPaths, token_env: &str) -> Result<(String, String)> {
    if let Ok(value) = std::env::var(token_env) {
        let token = value.trim().to_string();
        if !token.is_empty() {
            return Ok((token, format!("env:{token_env}")));
        }
    }
    let token = fs::read_to_string(&paths.telegram_bot_token)
        .unwrap_or_default()
        .trim()
        .to_string();
    if !token.is_empty() {
        return Ok((
            token,
            format!("file:{}", paths.telegram_bot_token.display()),
        ));
    }
    Err(anyhow!(
        "Telegram bot token not found. Export {token_env}=<bot-token> or write the token to {}.",
        paths.telegram_bot_token.display()
    ))
}

pub fn chat_candidates_from_updates(updates: &[TelegramUpdate]) -> Vec<TelegramChatCandidate> {
    let mut by_chat: BTreeMap<i64, TelegramChatCandidate> = BTreeMap::new();
    for update in updates {
        let Some(message) = &update.message else {
            continue;
        };
        let candidate = TelegramChatCandidate {
            chat_id: message.chat.id,
            update_id: update.update_id,
            message_id: message.message_id,
            from_id: message.from.as_ref().map(|from| from.id),
            chat_type: message.chat.chat_type.clone(),
            label: telegram_chat_label(&message.chat),
            text_excerpt: message.text.as_deref().map(excerpt),
        };
        let replace = by_chat
            .get(&candidate.chat_id)
            .map(|current| candidate.update_id >= current.update_id)
            .unwrap_or(true);
        if replace {
            by_chat.insert(candidate.chat_id, candidate);
        }
    }
    let mut candidates = by_chat.into_values().collect::<Vec<_>>();
    candidates.sort_by_key(|candidate| std::cmp::Reverse(candidate.update_id));
    candidates
}

fn select_chat_id(candidates: &[TelegramChatCandidate], latest: bool) -> Result<i64> {
    match candidates {
        [] => Err(anyhow!(
            "No Telegram chat candidates found. Send /start or any short message to the bot, then rerun `allbert-cli daemon channels setup telegram --latest --yes`."
        )),
        [candidate] => Ok(candidate.chat_id),
        many if latest => many
            .first()
            .map(|candidate| candidate.chat_id)
            .ok_or_else(|| anyhow!("No Telegram chat candidates found.")),
        many => Err(anyhow!(
            "Multiple Telegram chat candidates found; rerun with `--chat-id <id>` or `--latest`.\n{}",
            render_candidate_list(many)
        )),
    }
}

fn telegram_chat_label(chat: &TelegramChat) -> Option<String> {
    if let Some(title) = chat
        .title
        .as_deref()
        .filter(|value| !value.trim().is_empty())
    {
        return Some(title.trim().to_string());
    }
    let name = [chat.first_name.as_deref(), chat.last_name.as_deref()]
        .into_iter()
        .flatten()
        .filter(|part| !part.trim().is_empty())
        .collect::<Vec<_>>()
        .join(" ");
    if !name.trim().is_empty() {
        return Some(name);
    }
    chat.username
        .as_deref()
        .filter(|value| !value.trim().is_empty())
        .map(|username| format!("@{}", username.trim_start_matches('@')))
}

fn excerpt(text: &str) -> String {
    let trimmed = text.trim();
    const MAX: usize = 60;
    if trimmed.chars().count() <= MAX {
        return trimmed.to_string();
    }
    let mut out = trimmed.chars().take(MAX).collect::<String>();
    out.push_str("...");
    out
}

fn persist_token_if_needed(paths: &AllbertPaths, token: &str) -> Result<bool> {
    if fs::read_to_string(&paths.telegram_bot_token)
        .map(|raw| raw.trim() == token)
        .unwrap_or(false)
    {
        return Ok(false);
    }
    if let Some(parent) = paths.telegram_bot_token.parent() {
        fs::create_dir_all(parent).with_context(|| format!("create {}", parent.display()))?;
    }
    allbert_kernel_services::atomic_write(
        &paths.telegram_bot_token,
        format!("{token}\n").as_bytes(),
    )
    .with_context(|| format!("write {}", paths.telegram_bot_token.display()))?;
    Ok(true)
}

fn append_allowlisted_chat_if_missing(paths: &AllbertPaths, chat_id: i64) -> Result<bool> {
    let existing = fs::read_to_string(&paths.telegram_allowed_chats).unwrap_or_default();
    let mut values = Vec::new();
    for (idx, line) in existing.lines().enumerate() {
        let stripped = line.split('#').next().unwrap_or_default().trim();
        if stripped.is_empty() {
            continue;
        }
        values.push(stripped.parse::<i64>().with_context(|| {
            format!(
                "parse Telegram allowlisted chat on line {} in {}",
                idx + 1,
                paths.telegram_allowed_chats.display()
            )
        })?);
    }
    if values.contains(&chat_id) {
        return Ok(false);
    }
    if let Some(parent) = paths.telegram_allowed_chats.parent() {
        fs::create_dir_all(parent).with_context(|| format!("create {}", parent.display()))?;
    }
    let mut rendered = existing;
    if !rendered.is_empty() && !rendered.ends_with('\n') {
        rendered.push('\n');
    }
    rendered.push_str(&format!("{chat_id}\n"));
    allbert_kernel_services::atomic_write(&paths.telegram_allowed_chats, rendered.as_bytes())
        .with_context(|| format!("write {}", paths.telegram_allowed_chats.display()))?;
    Ok(true)
}

fn add_identity_binding_if_missing(paths: &AllbertPaths, chat_id: i64) -> Result<bool> {
    let sender = chat_id.to_string();
    let record = ensure_identity_record(paths)?;
    if record
        .channels
        .iter()
        .any(|binding| binding.kind == ChannelKind::Telegram && binding.sender == sender)
    {
        return Ok(false);
    }
    add_identity_channel(paths, ChannelKind::Telegram, &sender)?;
    Ok(true)
}

pub fn render_setup_result(result: &TelegramSetupResult) -> String {
    let mut lines = Vec::new();
    lines.push(if result.dry_run {
        "Telegram setup preview".to_string()
    } else {
        "Telegram setup applied".to_string()
    });
    lines.push(format!("chat id:      {}", result.selected_chat_id));
    lines.push(format!(
        "bot:          {}",
        result
            .bot_username
            .as_ref()
            .map(|username| format!("@{username}"))
            .unwrap_or_else(|| "(username unavailable)".into())
    ));
    lines.push(format!("token source: {}", result.token_source));
    if result.dry_run {
        lines.push("changes:      none (--yes not supplied)".into());
        lines.push("next:         rerun with --yes to write Telegram setup".into());
    } else {
        lines.push(format!(
            "token file:   {}",
            changed_label(result.wrote_token)
        ));
        lines.push(format!(
            "allowlist:    {}",
            changed_label(result.allowlist_added)
        ));
        lines.push(format!(
            "channel:      {}",
            changed_label(result.channel_enabled)
        ));
        lines.push(format!(
            "identity:     {}",
            if result.identity_skipped {
                "skipped (--no-identity)"
            } else {
                changed_label(result.identity_added)
            }
        ));
        if result.daemon_restart_recommended {
            lines.push("next:         restart the daemon to apply this change".into());
        }
    }
    if !result.candidates.is_empty() {
        lines.push(String::new());
        lines.push("discovered chats:".into());
        lines.push(render_candidate_list(&result.candidates));
    }
    lines.join("\n")
}

fn changed_label(changed: bool) -> &'static str {
    if changed {
        "updated"
    } else {
        "already current"
    }
}

fn render_candidate_list(candidates: &[TelegramChatCandidate]) -> String {
    candidates
        .iter()
        .map(|candidate| {
            format!(
                "- chat_id={} update_id={} message_id={} from_id={} type={} label={} text={}",
                candidate.chat_id,
                candidate.update_id,
                candidate
                    .message_id
                    .map(|value| value.to_string())
                    .unwrap_or_else(|| "(none)".into()),
                candidate
                    .from_id
                    .map(|value| value.to_string())
                    .unwrap_or_else(|| "(none)".into()),
                candidate.chat_type.as_deref().unwrap_or("(unknown)"),
                candidate.label.as_deref().unwrap_or("(unknown)"),
                candidate.text_excerpt.as_deref().unwrap_or("")
            )
        })
        .collect::<Vec<_>>()
        .join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    struct TempRoot {
        path: PathBuf,
    }

    impl TempRoot {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "allbert-telegram-setup-{}-{}",
                std::process::id(),
                uuid::Uuid::new_v4()
            ));
            fs::create_dir_all(&path).expect("temp root should create");
            Self { path }
        }

        fn paths(&self) -> AllbertPaths {
            AllbertPaths::under(self.path.clone())
        }
    }

    impl Drop for TempRoot {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.path);
        }
    }

    fn bot_identity() -> TelegramBotIdentity {
        TelegramBotIdentity {
            username: Some("allbert_test_bot".into()),
        }
    }

    fn update(update_id: i64, chat_id: i64, message_id: i32, from_id: u64) -> TelegramUpdate {
        TelegramUpdate {
            update_id,
            message: Some(TelegramMessage {
                message_id: Some(message_id),
                from: Some(TelegramUser { id: from_id }),
                chat: TelegramChat {
                    id: chat_id,
                    chat_type: Some("private".into()),
                    title: None,
                    username: None,
                    first_name: Some("Sandeep".into()),
                    last_name: None,
                },
                text: Some("hello bot".into()),
            }),
        }
    }

    fn setup_options() -> TelegramSetupOptions {
        TelegramSetupOptions {
            token_env: "ALLBERT_TEST_TELEGRAM_TOKEN".into(),
            chat_id: None,
            latest: false,
            yes: false,
            no_identity: false,
        }
    }

    #[test]
    fn candidates_extract_chat_id_not_message_or_user_id() {
        let candidates = chat_candidates_from_updates(&[update(336865692, 7336421071, 17, 222)]);
        assert_eq!(candidates.len(), 1);
        assert_eq!(candidates[0].chat_id, 7336421071);
        assert_eq!(candidates[0].message_id, Some(17));
        assert_eq!(candidates[0].from_id, Some(222));
        assert_ne!(candidates[0].chat_id, 17);
        assert_ne!(candidates[0].chat_id, 336865692);
        assert_ne!(candidates[0].chat_id, 222);
    }

    #[test]
    fn candidates_parse_bot_api_updates_shape() {
        let raw = r#"{
            "ok": true,
            "result": [{
                "update_id": 336865692,
                "message": {
                    "message_id": 17,
                    "from": { "id": 222 },
                    "chat": { "id": 7336421071, "type": "private", "first_name": "Sandeep" },
                    "text": "hello bot"
                }
            }]
        }"#;
        let response: TelegramApiResponse<Vec<TelegramUpdate>> =
            serde_json::from_str(raw).expect("Telegram update response should parse");
        let updates = response
            .into_result("getUpdates")
            .expect("Telegram response should be ok");
        let candidates = chat_candidates_from_updates(&updates);
        assert_eq!(candidates.len(), 1);
        assert_eq!(candidates[0].chat_id, 7336421071);
        assert_eq!(candidates[0].message_id, Some(17));
        assert_eq!(candidates[0].from_id, Some(222));
    }

    #[test]
    fn candidates_deduplicate_by_chat_and_keep_latest_update() {
        let candidates =
            chat_candidates_from_updates(&[update(1, 10, 5, 100), update(3, 10, 6, 100)]);
        assert_eq!(candidates.len(), 1);
        assert_eq!(candidates[0].chat_id, 10);
        assert_eq!(candidates[0].update_id, 3);
        assert_eq!(candidates[0].message_id, Some(6));
    }

    #[tokio::test]
    async fn setup_requires_token() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        std::env::remove_var("ALLBERT_TEST_TELEGRAM_TOKEN");
        let err = setup_telegram(&paths, setup_options(), false)
            .await
            .expect_err("missing token should fail");
        assert!(err.to_string().contains("Telegram bot token not found"));
    }

    #[test]
    fn setup_requires_updates_without_explicit_chat_id() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        let err = setup_telegram_from_resolved(
            &paths,
            &setup_options(),
            "123:abc",
            "env:ALLBERT_TEST_TELEGRAM_TOKEN".into(),
            bot_identity(),
            Vec::new(),
            false,
        )
        .expect_err("missing updates should fail");
        assert!(err.to_string().contains("Send /start"));
    }

    #[test]
    fn setup_dry_run_does_not_mutate_files() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        let result = setup_telegram_from_resolved(
            &paths,
            &setup_options(),
            "123:abc",
            "env:ALLBERT_TEST_TELEGRAM_TOKEN".into(),
            bot_identity(),
            vec![update(1, 99, 7, 8)],
            false,
        )
        .expect("dry run");
        assert!(result.dry_run);
        assert_eq!(result.selected_chat_id, 99);
        assert!(!paths.telegram_bot_token.exists());
        assert!(!paths.telegram_allowed_chats.exists());
    }

    #[test]
    fn setup_yes_writes_token_allowlist_channel_and_identity_idempotently() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        let mut options = setup_options();
        options.yes = true;
        let result = setup_telegram_from_resolved(
            &paths,
            &options,
            "123:abc",
            "env:ALLBERT_TEST_TELEGRAM_TOKEN".into(),
            bot_identity(),
            vec![update(1, 99, 7, 8)],
            true,
        )
        .expect("apply setup");
        assert!(!result.dry_run);
        assert!(result.wrote_token);
        assert!(result.allowlist_added);
        assert!(result.channel_enabled);
        assert!(result.identity_added);
        assert!(result.daemon_restart_recommended);

        let repeat = setup_telegram_from_resolved(
            &paths,
            &options,
            "123:abc",
            "env:ALLBERT_TEST_TELEGRAM_TOKEN".into(),
            bot_identity(),
            vec![update(1, 99, 7, 8)],
            false,
        )
        .expect("repeat setup");
        assert!(!repeat.wrote_token);
        assert!(!repeat.allowlist_added);
        assert!(!repeat.channel_enabled);
        assert!(!repeat.identity_added);

        let config = Config::load_or_create(&paths).expect("config");
        assert!(config.channels.telegram.enabled);
        assert_eq!(
            fs::read_to_string(&paths.telegram_bot_token).unwrap(),
            "123:abc\n"
        );
        assert_eq!(
            fs::read_to_string(&paths.telegram_allowed_chats).unwrap(),
            "99\n"
        );
        let identity = ensure_identity_record(&paths).expect("identity");
        assert!(identity
            .channels
            .iter()
            .any(|binding| binding.kind == ChannelKind::Telegram && binding.sender == "99"));
    }

    #[test]
    fn setup_multiple_candidates_require_latest_or_chat_id() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        let updates = vec![update(1, 10, 7, 8), update(2, 20, 8, 9)];
        let err = setup_telegram_from_resolved(
            &paths,
            &setup_options(),
            "123:abc",
            "env:ALLBERT_TEST_TELEGRAM_TOKEN".into(),
            bot_identity(),
            updates.clone(),
            false,
        )
        .expect_err("ambiguous candidates should fail");
        assert!(err
            .to_string()
            .contains("Multiple Telegram chat candidates"));

        let mut latest = setup_options();
        latest.latest = true;
        let result = setup_telegram_from_resolved(
            &paths,
            &latest,
            "123:abc",
            "env:ALLBERT_TEST_TELEGRAM_TOKEN".into(),
            bot_identity(),
            updates.clone(),
            false,
        )
        .expect("latest should select newest update");
        assert_eq!(result.selected_chat_id, 20);

        let mut explicit = setup_options();
        explicit.chat_id = Some(-100);
        let result = setup_telegram_from_resolved(
            &paths,
            &explicit,
            "123:abc",
            "env:ALLBERT_TEST_TELEGRAM_TOKEN".into(),
            bot_identity(),
            updates,
            false,
        )
        .expect("explicit chat id should not require candidate choice");
        assert_eq!(result.selected_chat_id, -100);
    }
}
