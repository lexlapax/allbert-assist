use allbert_kernel::{
    ConfirmDecision, ConfirmPrompter, ConfirmRequest, InputPrompter, InputRequest, InputResponse,
    Kernel,
};
use anyhow::Result;
use async_trait::async_trait;
use reedline::{DefaultPrompt, DefaultPromptSegment, Reedline, Signal};

pub struct TerminalConfirm;

#[async_trait]
impl ConfirmPrompter for TerminalConfirm {
    async fn confirm(&self, _req: ConfirmRequest) -> ConfirmDecision {
        // M1 stub: default-deny until the real y/N/always prompt lands in M3.
        ConfirmDecision::Deny
    }
}

pub struct TerminalInput;

#[async_trait]
impl InputPrompter for TerminalInput {
    async fn request_input(&self, _req: InputRequest) -> InputResponse {
        // M1 stub: return Cancelled until the real prompt lands in M3.
        InputResponse::Cancelled
    }
}

const HELP_TEXT: &str = "\
commands:
  /help     show this help
  /exit     leave the REPL
  anything else is sent to the kernel as a user turn";

pub async fn run_loop(kernel: &mut Kernel) -> Result<()> {
    let mut line_editor = Reedline::create();
    let prompt = DefaultPrompt::new(
        DefaultPromptSegment::Basic("allbert".into()),
        DefaultPromptSegment::Empty,
    );

    loop {
        match line_editor.read_line(&prompt)? {
            Signal::Success(buf) => {
                let trimmed = buf.trim();
                if trimmed.is_empty() {
                    continue;
                }
                match trimmed {
                    "/exit" | "/quit" => break,
                    "/help" => {
                        println!("{HELP_TEXT}");
                    }
                    _ => {
                        let summary = kernel.run_turn(trimmed).await?;
                        if summary.hit_turn_limit {
                            eprintln!("[kernel reported max-turns limit hit]");
                        }
                    }
                }
            }
            Signal::CtrlC => {
                eprintln!("(ctrl-c) type /exit to leave");
            }
            Signal::CtrlD => break,
        }
    }
    Ok(())
}
