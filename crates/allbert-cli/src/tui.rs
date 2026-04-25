use std::io::{self, Stdout};
use std::time::Duration;

use allbert_daemon::DaemonClient;
use allbert_kernel::TuiSpinnerStyle;
use allbert_proto::{
    ActivitySnapshot, ClientMessage, ConfirmDecisionPayload, ConfirmReplyPayload,
    InputReplyPayload, InputResponsePayload, KernelEventPayload, ServerMessage, TelemetrySnapshot,
};
use anyhow::{Context, Result};
use crossterm::event::{
    DisableMouseCapture, EnableMouseCapture, Event, EventStream, KeyCode, KeyEvent, KeyModifiers,
};
use crossterm::execute;
use crossterm::terminal::{
    disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen,
};
use futures_util::StreamExt;
use ratatui::backend::CrosstermBackend;
use ratatui::layout::{Constraint, Direction, Layout};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Paragraph, Wrap};
use ratatui::{Frame, Terminal};

use crate::repl::{self, LocalCommand};

const MAX_TRANSCRIPT_LINES: usize = 500;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Modal {
    Confirm {
        request_id: u64,
        rendered: String,
        durable: bool,
    },
    Input {
        request_id: u64,
        prompt: String,
        allow_empty: bool,
    },
}

#[derive(Debug, Clone)]
pub struct TuiApp {
    transcript: Vec<String>,
    composer_input: String,
    modal_input: String,
    telemetry: Option<TelemetrySnapshot>,
    activity: Option<ActivitySnapshot>,
    status_items: Vec<String>,
    spinner_style: TuiSpinnerStyle,
    spinner_frame: usize,
    tick_ms: u64,
    modal: Option<Modal>,
    in_flight: bool,
    should_exit: bool,
}

impl TuiApp {
    pub fn new(status_items: Vec<String>) -> Self {
        Self {
            transcript: vec!["Allbert TUI ready. Type /help for commands.".into()],
            composer_input: String::new(),
            modal_input: String::new(),
            telemetry: None,
            activity: None,
            status_items,
            spinner_style: TuiSpinnerStyle::Braille,
            spinner_frame: 0,
            tick_ms: 80,
            modal: None,
            in_flight: false,
            should_exit: false,
        }
    }

    pub fn with_transcript(status_items: Vec<String>, transcript: Vec<String>) -> Self {
        let mut app = Self::new(status_items);
        for line in transcript {
            app.push_line(line);
        }
        app
    }

    pub fn set_telemetry(&mut self, telemetry: TelemetrySnapshot) {
        if let Some(activity) = telemetry.current_activity.clone() {
            self.activity = Some(activity);
        }
        self.telemetry = Some(telemetry);
    }

    pub fn configure_tui(&mut self, config: &allbert_kernel::TuiConfig) {
        self.spinner_style = config.spinner_style;
        self.tick_ms = config.tick_ms.clamp(40, 250);
    }

    pub fn advance_tick(&mut self) {
        self.spinner_frame = self.spinner_frame.wrapping_add(1);
    }

    pub fn modal(&self) -> Option<&Modal> {
        self.modal.as_ref()
    }

    pub fn should_exit(&self) -> bool {
        self.should_exit
    }

    pub fn push_line(&mut self, line: impl Into<String>) {
        self.transcript.push(line.into());
        let max_lines = MAX_TRANSCRIPT_LINES.max(self.status_items.len());
        if self.transcript.len() > max_lines {
            let overflow = self.transcript.len() - max_lines;
            self.transcript.drain(0..overflow);
        }
    }

    pub fn process_server_message(&mut self, message: ServerMessage) -> bool {
        match message {
            ServerMessage::Event(event) => self.process_event(event),
            ServerMessage::ConfirmRequest(request) => {
                let durable = matches!(
                    request.program.as_str(),
                    "upsert_job"
                        | "pause_job"
                        | "resume_job"
                        | "remove_job"
                        | "promote_staged_memory"
                );
                self.modal = Some(Modal::Confirm {
                    request_id: request.request_id,
                    rendered: request.rendered,
                    durable,
                });
            }
            ServerMessage::InputRequest(request) => {
                self.modal_input.clear();
                self.modal = Some(Modal::Input {
                    request_id: request.request_id,
                    prompt: request.prompt,
                    allow_empty: request.allow_empty,
                });
            }
            ServerMessage::TurnResult(result) => {
                self.in_flight = false;
                if result.hit_turn_limit {
                    self.push_line("[kernel reported max-turns limit]");
                }
                return true;
            }
            ServerMessage::Error(error) => {
                self.in_flight = false;
                self.push_line(format!("[error] {}", error.message));
                return true;
            }
            ServerMessage::SessionTelemetry(telemetry) => self.set_telemetry(telemetry),
            ServerMessage::ActivitySnapshot(activity) | ServerMessage::ActivityUpdate(activity) => {
                self.activity = Some(activity);
            }
            _ => {}
        }
        false
    }

    fn process_event(&mut self, event: KernelEventPayload) {
        match event {
            KernelEventPayload::AssistantText(text) => self.push_line(format!("allbert: {text}")),
            KernelEventPayload::ToolCall { name, .. } => {
                self.push_line(format!("[tool call: {name}]"))
            }
            KernelEventPayload::ToolResult { name, ok, .. } => {
                let tag = if ok { "ok" } else { "err" };
                self.push_line(format!("[tool result: {name} ({tag})]"));
            }
            KernelEventPayload::JobFailed {
                job_name,
                run_id,
                ended_at,
                stop_reason,
            } => self.push_line(format!(
                "[job failure] {job_name} run {run_id} at {ended_at}{}",
                stop_reason
                    .map(|value| format!(": {value}"))
                    .unwrap_or_default()
            )),
            KernelEventPayload::TurnDone { hit_turn_limit } if hit_turn_limit => {
                self.push_line("[turn hit max-turns limit]");
            }
            KernelEventPayload::SkillTier1Surfaced { .. }
            | KernelEventPayload::SkillTier2Activated { .. }
            | KernelEventPayload::SkillTier3Referenced { .. }
            | KernelEventPayload::Cost { .. }
            | KernelEventPayload::TurnDone { .. } => {}
        }
    }

    fn handle_local_command(&mut self, command: LocalCommand<'_>) -> Option<String> {
        match command {
            LocalCommand::Exit => {
                self.should_exit = true;
                None
            }
            LocalCommand::Help => Some(repl::HELP_TEXT.to_string()),
            LocalCommand::UnknownSlash(command) => Some(format!(
                "unknown command: {command}\nuse /help to see supported REPL commands"
            )),
            LocalCommand::Cost(_)
            | LocalCommand::Memory(_)
            | LocalCommand::Model(_)
            | LocalCommand::Setup
            | LocalCommand::Status
            | LocalCommand::StatusLine(_)
            | LocalCommand::Telemetry => None,
            LocalCommand::Turn(input) => Some(input.to_string()),
        }
    }
}

pub async fn run_loop(
    client: &mut DaemonClient,
    paths: &allbert_kernel::AllbertPaths,
    session_id: &str,
    config: &allbert_kernel::Config,
) -> Result<()> {
    let status_items = configured_status_items(config);
    let transcript = replay_session_tail(paths, session_id, config.repl.tui.max_transcript_events);
    let mut app = TuiApp::with_transcript(status_items, transcript);
    app.configure_tui(&config.repl.tui);
    if let Ok(telemetry) = client.session_telemetry().await {
        app.set_telemetry(telemetry);
    }

    let mut terminal = TerminalSession::enter(config.repl.tui.mouse)?;
    let result = run_event_loop(&mut terminal.terminal, client, paths, &mut app).await;
    terminal.exit()?;
    result
}

async fn run_event_loop(
    terminal: &mut Terminal<CrosstermBackend<Stdout>>,
    client: &mut DaemonClient,
    paths: &allbert_kernel::AllbertPaths,
    app: &mut TuiApp,
) -> Result<()> {
    let mut events = EventStream::new();
    let mut tick = tokio::time::interval(Duration::from_millis(app.tick_ms));
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let mut dirty = true;
    loop {
        if dirty || app.in_flight {
            terminal.draw(|frame| render(frame, app))?;
            dirty = false;
        }
        if app.should_exit() {
            return Ok(());
        }

        tokio::select! {
            _ = tick.tick() => {
                app.advance_tick();
                dirty = app.in_flight || app.activity.as_ref().is_some_and(|activity| {
                    !matches!(activity.phase, allbert_proto::ActivityPhase::Idle)
                });
            }
            maybe_event = events.next() => {
                match maybe_event {
                    Some(Ok(Event::Key(key))) => {
                        handle_key(client, paths, app, key).await?;
                        dirty = true;
                    }
                    Some(Ok(_)) => {}
                    Some(Err(error)) => return Err(error).context("read terminal event"),
                    None => return Ok(()),
                }
            }
            message = client.recv(), if app.in_flight => {
                match message {
                    Ok(message) => {
                        app.process_server_message(message);
                        dirty = true;
                    }
                    Err(error) => return Err(error).context("receive daemon message"),
                }
            }
        }
    }
}

async fn handle_key(
    client: &mut DaemonClient,
    paths: &allbert_kernel::AllbertPaths,
    app: &mut TuiApp,
    key: KeyEvent,
) -> Result<()> {
    if app.modal().is_some() {
        return handle_modal_key(client, app, key).await;
    }

    match key.code {
        KeyCode::Char('c') if key.modifiers.contains(KeyModifiers::CONTROL) => {
            if app.in_flight {
                app.push_line("cancel is not available yet; turn continues");
            } else {
                app.push_line("(ctrl-c) type /exit to leave");
            }
        }
        KeyCode::Char('d') if key.modifiers.contains(KeyModifiers::CONTROL) => {
            app.should_exit = true;
        }
        KeyCode::Char(ch) => app.composer_input.push(ch),
        KeyCode::Backspace => {
            app.composer_input.pop();
        }
        KeyCode::Enter => {
            if app.in_flight {
                app.push_line("turn in progress; draft kept");
                return Ok(());
            }
            let input = app.composer_input.trim().to_string();
            app.composer_input.clear();
            if input.is_empty() {
                return Ok(());
            }
            app.push_line(format!("you: {input}"));
            match repl::parse_local_command(&input) {
                LocalCommand::Status | LocalCommand::Telemetry => {
                    let telemetry = client.session_telemetry().await?;
                    app.set_telemetry(telemetry.clone());
                    app.push_line(render_telemetry_summary(&telemetry));
                }
                LocalCommand::Memory(command) => {
                    app.push_line(repl::handle_memory_command(paths, command)?);
                }
                LocalCommand::StatusLine(command) => {
                    app.push_line(repl::handle_statusline_command(paths, command)?);
                    let config = allbert_kernel::Config::load_or_create(paths)?;
                    app.status_items = configured_status_items(&config);
                }
                command => {
                    if let Some(turn) = app.handle_local_command(command) {
                        if matches!(repl::parse_local_command(&input), LocalCommand::Turn(_)) {
                            client.start_turn(turn).await?;
                            app.in_flight = true;
                        } else {
                            app.push_line(turn);
                        }
                    }
                }
            }
            for message in client.take_pending_events() {
                app.process_server_message(message);
            }
        }
        _ => {}
    }
    Ok(())
}

async fn handle_modal_key(
    client: &mut DaemonClient,
    app: &mut TuiApp,
    key: KeyEvent,
) -> Result<()> {
    let Some(modal) = app.modal.take() else {
        return Ok(());
    };
    match modal {
        Modal::Confirm {
            request_id,
            durable,
            ..
        } => {
            let decision = match key.code {
                KeyCode::Char('y') | KeyCode::Char('Y') => ConfirmDecisionPayload::AllowOnce,
                KeyCode::Char('a') | KeyCode::Char('A') if !durable => {
                    ConfirmDecisionPayload::AllowSession
                }
                _ => ConfirmDecisionPayload::Deny,
            };
            client
                .send(&ClientMessage::ConfirmReply(ConfirmReplyPayload {
                    request_id,
                    decision,
                }))
                .await?;
        }
        Modal::Input {
            request_id,
            prompt,
            allow_empty,
        } => match key.code {
            KeyCode::Char(ch) => {
                app.modal_input.push(ch);
                app.modal = Some(Modal::Input {
                    request_id,
                    prompt,
                    allow_empty,
                });
            }
            KeyCode::Backspace => {
                app.modal_input.pop();
                app.modal = Some(Modal::Input {
                    request_id,
                    prompt,
                    allow_empty,
                });
            }
            KeyCode::Esc => {
                app.modal_input.clear();
                client
                    .send(&ClientMessage::InputReply(InputReplyPayload {
                        request_id,
                        response: InputResponsePayload::Cancelled,
                    }))
                    .await?;
            }
            KeyCode::Enter => {
                let value = app.modal_input.trim_end_matches(['\r', '\n']).to_string();
                app.modal_input.clear();
                let response = if !allow_empty && value.trim().is_empty() {
                    InputResponsePayload::Cancelled
                } else {
                    InputResponsePayload::Submitted(value)
                };
                client
                    .send(&ClientMessage::InputReply(InputReplyPayload {
                        request_id,
                        response,
                    }))
                    .await?;
            }
            _ => {
                app.modal = Some(Modal::Input {
                    request_id,
                    prompt,
                    allow_empty,
                });
            }
        },
    }
    Ok(())
}

pub fn render(frame: &mut Frame<'_>, app: &TuiApp) {
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Min(5),
            Constraint::Length(3),
            Constraint::Length(1),
        ])
        .split(frame.area());

    let transcript = app
        .transcript
        .iter()
        .map(|line| Line::from(line.as_str()))
        .collect::<Vec<_>>();
    let transcript = Paragraph::new(transcript)
        .block(Block::default().title("Allbert").borders(Borders::ALL))
        .wrap(Wrap { trim: false });
    frame.render_widget(transcript, chunks[0]);

    let input = Paragraph::new(app.composer_input.as_str())
        .block(Block::default().title("Input").borders(Borders::ALL));
    frame.render_widget(input, chunks[1]);
    if app.modal().is_none() {
        let cursor_x = chunks[1]
            .x
            .saturating_add(1)
            .saturating_add(app.composer_input.chars().count() as u16);
        frame.set_cursor_position((cursor_x, chunks[1].y.saturating_add(1)));
    }

    let status = Paragraph::new(status_line(app, frame.area().width))
        .style(Style::default().fg(Color::Black).bg(Color::Gray));
    frame.render_widget(status, chunks[2]);

    if let Some(modal) = app.modal() {
        let area = centered_rect(70, 35, frame.area());
        let text = match modal {
            Modal::Confirm {
                rendered, durable, ..
            } => {
                let choices = if *durable { "[y/N]" } else { "[y/N/a]" };
                format!("{rendered}\n\nConfirm {choices}")
            }
            Modal::Input { prompt, .. } => format!("{prompt}\n\n{}", app.modal_input),
        };
        let modal = Paragraph::new(text)
            .block(Block::default().title("Approval").borders(Borders::ALL))
            .style(
                Style::default()
                    .fg(Color::Yellow)
                    .add_modifier(Modifier::BOLD),
            )
            .wrap(Wrap { trim: false });
        frame.render_widget(modal, area);
        if matches!(app.modal(), Some(Modal::Input { .. })) {
            let cursor_x = area
                .x
                .saturating_add(1)
                .saturating_add(app.modal_input.chars().count() as u16);
            frame.set_cursor_position((cursor_x, area.y.saturating_add(3)));
        }
    }
}

fn status_line(app: &TuiApp, width: u16) -> Line<'static> {
    let Some(telemetry) = app.telemetry.as_ref() else {
        return Line::from("telemetry pending");
    };
    let compact = width < 60;
    let mut items = if compact {
        vec![
            format!("model {}", telemetry.model.model_id),
            context_label(telemetry),
            format!("${:.4}", telemetry.session_cost_usd),
        ]
    } else {
        app.status_items
            .iter()
            .map(|item| status_item(item, telemetry))
            .collect::<Vec<_>>()
    };
    if let Some(activity) = activity_segment(app, compact) {
        items.insert(0, activity);
    }
    Line::from(
        items
            .join("  |  ")
            .split("  |  ")
            .enumerate()
            .flat_map(|(idx, item)| {
                if idx == 0 {
                    vec![Span::raw(item.to_string())]
                } else {
                    vec![Span::raw("  |  "), Span::raw(item.to_string())]
                }
            })
            .collect::<Vec<_>>(),
    )
}

fn activity_segment(app: &TuiApp, compact: bool) -> Option<String> {
    let activity = app.activity.as_ref()?;
    if matches!(activity.phase, allbert_proto::ActivityPhase::Idle) && !app.in_flight {
        return None;
    }
    let frames = app.spinner_style.frames();
    let spinner = frames
        .get(app.spinner_frame % frames.len().max(1))
        .copied()
        .unwrap_or("*");
    let seconds = activity.elapsed_ms as f64 / 1000.0;
    if compact {
        Some(format!("{spinner} {}", activity.label))
    } else {
        Some(format!("{spinner} {} {:.1}s", activity.label, seconds))
    }
}

fn status_item(item: &str, telemetry: &TelemetrySnapshot) -> String {
    match item {
        "model" => format!("model {}", telemetry.model.model_id),
        "context" => context_label(telemetry),
        "tokens" => format!("tok {}", telemetry.session_usage.total_tokens),
        "cost" => format!("cost ${:.4}", telemetry.session_cost_usd),
        "memory" => format!(
            "mem d{} s{} e{} f{}",
            telemetry.memory.durable_count,
            telemetry.memory.staged_count,
            telemetry.memory.episode_count,
            telemetry.memory.fact_count
        ),
        "intent" => format!(
            "intent {}",
            telemetry.last_resolved_intent.as_deref().unwrap_or("?")
        ),
        "skills" => format!("skills {}", telemetry.active_skills.len()),
        "inbox" => format!("inbox {}", telemetry.inbox_count),
        "channel" => format!("ch {:?}", telemetry.channel),
        "trace" => format!(
            "trace {}",
            if telemetry.trace_enabled { "on" } else { "off" }
        ),
        other => other.to_string(),
    }
}

fn context_label(telemetry: &TelemetrySnapshot) -> String {
    match (telemetry.context_used_tokens, telemetry.context_percent) {
        (Some(tokens), Some(percent)) => format!("ctx {tokens}/{:.0}%", percent),
        (Some(tokens), None) => format!("ctx {tokens}/?"),
        _ => "ctx ?".into(),
    }
}

fn render_telemetry_summary(snapshot: &TelemetrySnapshot) -> String {
    format!(
        "model: {}\ncontext: {}\ncost: ${:.6}\nmemory: durable {}, staged {}\ninbox: {}",
        snapshot.model.model_id,
        context_label(snapshot),
        snapshot.session_cost_usd,
        snapshot.memory.durable_count,
        snapshot.memory.staged_count,
        snapshot.inbox_count
    )
}

fn configured_status_items(config: &allbert_kernel::Config) -> Vec<String> {
    if !config.repl.tui.status_line.enabled {
        return Vec::new();
    }
    config
        .repl
        .tui
        .status_line
        .items
        .iter()
        .map(|item| item.label().to_string())
        .collect()
}

fn replay_session_tail(
    paths: &allbert_kernel::AllbertPaths,
    session_id: &str,
    max_lines: usize,
) -> Vec<String> {
    let path = paths.sessions.join(session_id).join("turns.md");
    let Ok(raw) = std::fs::read_to_string(path) else {
        return Vec::new();
    };
    let mut lines = raw.lines().map(str::to_string).collect::<Vec<_>>();
    if lines.len() > max_lines {
        lines.drain(0..lines.len() - max_lines);
    }
    lines
}

fn centered_rect(
    percent_x: u16,
    percent_y: u16,
    area: ratatui::layout::Rect,
) -> ratatui::layout::Rect {
    let vertical = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Percentage((100 - percent_y) / 2),
            Constraint::Percentage(percent_y),
            Constraint::Percentage((100 - percent_y) / 2),
        ])
        .split(area);
    let horizontal = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([
            Constraint::Percentage((100 - percent_x) / 2),
            Constraint::Percentage(percent_x),
            Constraint::Percentage((100 - percent_x) / 2),
        ])
        .split(vertical[1]);
    horizontal[1]
}

struct TerminalSession {
    terminal: Terminal<CrosstermBackend<Stdout>>,
    mouse: bool,
}

impl TerminalSession {
    fn enter(mouse: bool) -> Result<Self> {
        enable_raw_mode().context("enable terminal raw mode")?;
        let mut stdout = io::stdout();
        if mouse {
            execute!(stdout, EnterAlternateScreen, EnableMouseCapture)?;
        } else {
            execute!(stdout, EnterAlternateScreen)?;
        }
        let backend = CrosstermBackend::new(stdout);
        let mut terminal = Terminal::new(backend)?;
        terminal.clear()?;
        Ok(Self { terminal, mouse })
    }

    fn exit(&mut self) -> Result<()> {
        disable_raw_mode().context("disable terminal raw mode")?;
        if self.mouse {
            execute!(
                self.terminal.backend_mut(),
                LeaveAlternateScreen,
                DisableMouseCapture
            )?;
        } else {
            execute!(self.terminal.backend_mut(), LeaveAlternateScreen)?;
        }
        self.terminal.show_cursor()?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use allbert_proto::{
        ChannelKind, MemoryTelemetry, ModelConfigPayload, ProviderKind, TokenUsagePayload,
        TurnBudgetTelemetry,
    };
    use ratatui::backend::TestBackend;

    fn fixture_telemetry() -> TelemetrySnapshot {
        TelemetrySnapshot {
            session_id: "repl-primary".into(),
            channel: ChannelKind::Repl,
            provider: "ollama".into(),
            model: ModelConfigPayload {
                provider: ProviderKind::Ollama,
                model_id: "gemma4".into(),
                api_key_env: None,
                base_url: None,
                max_tokens: 4096,
                context_window_tokens: 100,
            },
            context_window_tokens: 100,
            context_used_tokens: Some(25),
            context_percent: Some(25.0),
            last_response_usage: Some(TokenUsagePayload {
                input_tokens: 20,
                output_tokens: 5,
                cache_read_tokens: 0,
                cache_create_tokens: 0,
                total_tokens: 25,
            }),
            session_usage: TokenUsagePayload {
                input_tokens: 50,
                output_tokens: 10,
                cache_read_tokens: 0,
                cache_create_tokens: 0,
                total_tokens: 60,
            },
            session_cost_usd: 0.0123,
            today_cost_usd: 0.0456,
            turn_budget: TurnBudgetTelemetry {
                limit_usd: 0.5,
                limit_seconds: 120,
                remaining_usd: None,
                remaining_seconds: None,
            },
            memory: MemoryTelemetry {
                synopsis_bytes: 0,
                ephemeral_bytes: 0,
                durable_count: 2,
                staged_count: 1,
                staged_this_turn: 0,
                prefetch_hit_count: 0,
                episode_count: 3,
                fact_count: 4,
                always_eligible_skills: vec!["memory-curator".into()],
            },
            active_skills: vec!["memory-curator".into()],
            last_agent_stack: vec!["allbert/root".into()],
            last_resolved_intent: Some("memory_query".into()),
            inbox_count: 1,
            trace_enabled: false,
            setup_version: 4,
            current_activity: None,
        }
    }

    fn rendered_buffer(terminal: &Terminal<TestBackend>) -> String {
        terminal
            .backend()
            .buffer()
            .content()
            .iter()
            .map(|cell| cell.symbol())
            .collect::<Vec<_>>()
            .join("")
    }

    #[test]
    fn tui_renders_transcript_input_and_status_line() {
        let backend = TestBackend::new(90, 20);
        let mut terminal = Terminal::new(backend).expect("terminal should build");
        let mut app = TuiApp::new(vec![
            "model".into(),
            "context".into(),
            "cost".into(),
            "memory".into(),
        ]);
        app.push_line("allbert: hello from the transcript");
        app.composer_input = "what next?".into();
        app.set_telemetry(fixture_telemetry());

        terminal.draw(|frame| render(frame, &app)).expect("draw");
        let rendered = rendered_buffer(&terminal);

        assert!(rendered.contains("hello from the transcript"));
        assert!(rendered.contains("what next?"));
        assert!(rendered.contains("model gemma4"));
        assert!(rendered.contains("ctx 25/25%"));
    }

    #[test]
    fn tui_narrow_terminal_uses_compact_status_line() {
        let backend = TestBackend::new(42, 10);
        let mut terminal = Terminal::new(backend).expect("terminal should build");
        let mut app = TuiApp::new(vec!["model".into(), "context".into(), "cost".into()]);
        app.set_telemetry(fixture_telemetry());

        terminal.draw(|frame| render(frame, &app)).expect("draw");
        let rendered = rendered_buffer(&terminal);

        assert!(rendered.contains("model gemma4"));
        assert!(rendered.contains("ctx 25/25%"));
    }

    #[test]
    fn tui_tick_advances_spinner_while_in_flight() {
        let mut app = TuiApp::new(vec!["model".into()]);
        app.set_telemetry(fixture_telemetry());
        app.in_flight = true;
        app.activity = Some(allbert_proto::ActivitySnapshot {
            phase: allbert_proto::ActivityPhase::Queued,
            label: "turn queued".into(),
            started_at: "2026-04-25T12:00:00Z".into(),
            elapsed_ms: 0,
            session_id: "repl-primary".into(),
            channel: ChannelKind::Repl,
            tool_name: None,
            tool_summary: None,
            skill_name: None,
            approval_id: None,
            last_progress_at: None,
            stuck_hint: None,
            next_actions: vec!["wait".into()],
        });

        let before = app.spinner_frame;
        app.advance_tick();
        let line = status_line(&app, 100)
            .spans
            .into_iter()
            .map(|span| span.content.into_owned())
            .collect::<String>();
        assert_ne!(app.spinner_frame, before);
        assert!(line.contains("turn queued"));
    }

    #[test]
    fn tui_processes_core_server_messages() {
        let mut app = TuiApp::new(vec![]);
        assert!(!app.process_server_message(ServerMessage::Event(
            KernelEventPayload::AssistantText("hi".into())
        )));
        assert!(
            !app.process_server_message(ServerMessage::Event(KernelEventPayload::ToolCall {
                name: "read_file".into(),
                input: serde_json::json!({})
            }))
        );
        assert!(!app.process_server_message(ServerMessage::ConfirmRequest(
            allbert_proto::ConfirmRequestPayload {
                request_id: 7,
                approval_id: Some("approval-7".into()),
                program: "write_file".into(),
                args: Vec::new(),
                cwd: None,
                rendered: "write?".into(),
                expires_at: None,
                context: None,
            }
        )));
        assert!(matches!(
            app.modal(),
            Some(Modal::Confirm { request_id: 7, .. })
        ));
        assert!(
            app.process_server_message(ServerMessage::TurnResult(allbert_proto::TurnResult {
                hit_turn_limit: false
            }))
        );
    }
}
