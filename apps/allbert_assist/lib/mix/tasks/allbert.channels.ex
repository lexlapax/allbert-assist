defmodule Mix.Tasks.Allbert.Channels do
  @moduledoc """
  Inspect and operate local channel adapters.

  ## Usage

      mix allbert.channels list
      mix allbert.channels status
      mix allbert.channels show telegram|email|discord|slack|matrix|whatsapp|signal
      mix allbert.channels setup-check matrix|whatsapp|signal
      mix allbert.channels telegram set-token TOKEN
      mix allbert.channels telegram map --external-user EXTERNAL --user USER
      mix allbert.channels telegram unmap --external-user EXTERNAL
      mix allbert.channels telegram simulate --external-user EXTERNAL --chat CHAT "prompt"
      mix allbert.channels telegram poll-once
      mix allbert.channels telegram doctor
      mix allbert.channels email set-password --type imap PASSWORD
      mix allbert.channels email set-password --type smtp PASSWORD
      mix allbert.channels email map --external-user EMAIL --user USER
      mix allbert.channels email unmap --external-user EMAIL
      mix allbert.channels email simulate --external-user EMAIL [--new-thread] "prompt"
      mix allbert.channels email poll-once
      mix allbert.channels email doctor
      mix allbert.channels identity-links add --link LINK --channel CHANNEL --receiver RECEIVER --external-user EXTERNAL --user USER
      mix allbert.channels identity-links list [--link LINK] [--user USER]
      mix allbert.channels identity-links remove --link LINK --channel CHANNEL --receiver RECEIVER --external-user EXTERNAL
      mix allbert.channels discord set-token TOKEN_REF
      mix allbert.channels discord set-application-id APPLICATION_ID
      mix allbert.channels discord add-guild GUILD_ID
      mix allbert.channels discord add-channel CHANNEL_ID
      mix allbert.channels discord map --external-user EXTERNAL --user USER
      mix allbert.channels discord simulate --guild GUILD --channel CHANNEL --user EXTERNAL "prompt"
      mix allbert.channels discord simulate-callback --user EXTERNAL --custom-id allbert:v1:<verb>:<id>
      mix allbert.channels discord doctor
      mix allbert.channels slack set-token TOKEN_REF
      mix allbert.channels slack set-app-token APP_TOKEN_REF
      mix allbert.channels slack set-team-id TEAM_ID
      mix allbert.channels slack add-channel CHANNEL_ID
      mix allbert.channels slack map --external-user EXTERNAL --user USER
      mix allbert.channels slack simulate --channel CHANNEL [--thread-ts TS] --user EXTERNAL "prompt"
      mix allbert.channels slack simulate-callback --channel CHANNEL --user EXTERNAL --action-id allbert:v1:<verb>:<id>
      mix allbert.channels slack doctor
      mix allbert.channels matrix set-token TOKEN
      mix allbert.channels matrix map --external-user MXID --user USER
      mix allbert.channels matrix unmap --external-user MXID
      mix allbert.channels matrix simulate --room ROOM --user MXID "prompt"
      mix allbert.channels matrix poll-once
      mix allbert.channels matrix doctor
      mix allbert.channels whatsapp set-token TOKEN
      mix allbert.channels whatsapp map --external-user PHONE --user USER
      mix allbert.channels whatsapp unmap --external-user PHONE
      mix allbert.channels whatsapp simulate --from PHONE [--message-id WAMID] "prompt"
      mix allbert.channels whatsapp simulate-button --from PHONE --button-id allbert:v1:<verb>:<id>
      mix allbert.channels whatsapp post-webhook --from PHONE [--message-id WAMID] [--bad-signature] [--url BASE] "prompt"
      mix allbert.channels whatsapp doctor
      mix allbert.channels signal map --aci ACI --user USER
      mix allbert.channels signal unmap --aci ACI
      mix allbert.channels signal simulate --aci ACI [--message-id TIMESTAMP_MS] "prompt"
      mix allbert.channels signal link --account ACCOUNT [--device-name NAME]
      mix allbert.channels signal doctor

  The dispatch logic is shared with the packaged `allbert admin channels` command
  (`AllbertAssist.CLI.Areas.Channels`); this task is a thin Mix-shell wrapper that
  disables channel auto-poll before starting the app.
  """

  use Mix.Task

  alias AllbertAssist.CLI.Areas

  @shortdoc "Inspect and operate local channel adapters"

  @impl true
  def run(args) do
    disable_channel_auto_poll!()
    Mix.Task.run("app.start")
    Areas.run(Areas.Channels, args)
  end

  defp disable_channel_auto_poll! do
    opts = Application.get_env(:allbert_assist, AllbertAssist.Channels.Supervisor, [])

    Application.put_env(
      :allbert_assist,
      AllbertAssist.Channels.Supervisor,
      Keyword.put(opts, :auto_poll?, false)
    )
  end
end
