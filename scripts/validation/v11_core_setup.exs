alias AllbertAssist.CLI.Areas.Channels
alias AllbertAssist.CLI.Areas.Onboarding
alias AllbertAssist.CLI.Areas.Settings
alias AllbertAssist.CLI.FirstRun

Logger.configure(level: :warning)
channel_supervisor = AllbertAssist.Channels.Supervisor
opts = Application.get_env(:allbert_assist, channel_supervisor, [])
Application.put_env(:allbert_assist, channel_supervisor, Keyword.put(opts, :auto_poll?, false))
{:ok, _started} = Application.ensure_all_started(:allbert_assist)

test_bypass? = System.get_env("V11_VALIDATION_TEST_BYPASS_ONBOARDING") == "1"

if test_bypass? do
  if System.get_env("V11_TEST_MODE") != "1" do
    raise "V11_VALIDATION_TEST_BYPASS_ONBOARDING requires a test-prepared harness state"
  end

  :ok = FirstRun.mark_onboarding_complete()
end

{onboarding_output, onboarding_code} = Onboarding.dispatch(["status"])
IO.puts(String.trim_trailing(onboarding_output))

if onboarding_code != 0 or not String.contains?(onboarding_output, "onboard status=complete") do
  raise "onboarding did not reach complete"
end

if not test_bypass? and not String.contains?(onboarding_output, "readiness=Ready") do
  raise "onboarding model readiness is not Ready"
end

settings = [
  {"objectives.fanout.enabled", "true"},
  {"objectives.fanout.rollout_mode", "automatic"},
  {"objectives.fanout.confirm_before_start", "false"},
  {"channels.tui.enabled", "true"},
  {"channels.tui.identity_map",
   ~s([{"external_user_id":"default","user_id":"local","enabled":true}])}
]

Enum.each(settings, fn {key, value} ->
  {output, code} = Settings.dispatch(["set", key, value])
  IO.puts(String.trim_trailing(output))

  if code != 0 do
    raise "failed to persist #{key}"
  end
end)

expected = [
  {"objectives.fanout.enabled", "objectives.fanout.enabled=true"},
  {"objectives.fanout.rollout_mode", ~s(objectives.fanout.rollout_mode="automatic")},
  {"channels.tui.enabled", "channels.tui.enabled=true"},
  {"channels.tui.identity_map", "external_user_id"}
]

Enum.each(expected, fn {key, marker} ->
  {output, code} = Settings.dispatch(["get", key])
  IO.puts(String.trim_trailing(output))

  if code != 0 or not String.contains?(output, marker) do
    raise "persisted setting verification failed for #{key}"
  end
end)

{tui_output, tui_code} = Channels.dispatch(["show", "tui"])
IO.puts(String.trim_trailing(tui_output))

if tui_code != 0 or not String.contains?(tui_output, "Enabled: true") or
     not String.contains?(tui_output, "Identities: 1") do
  raise "TUI channel verification failed"
end

IO.puts("V11 CORE SETTINGS PASS")
