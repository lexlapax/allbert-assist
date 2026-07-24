alias AllbertAssist.CLI.Areas.Settings

Logger.configure(level: :warning)
channel_supervisor = AllbertAssist.Channels.Supervisor
opts = Application.get_env(:allbert_assist, channel_supervisor, [])
Application.put_env(:allbert_assist, channel_supervisor, Keyword.put(opts, :auto_poll?, false))
{:ok, _started} = Application.ensure_all_started(:allbert_assist)

transition = System.fetch_env!("V11_SETTINGS_TRANSITION")
channel = System.get_env("V11_CHANNEL")

dispatch = fn args, label ->
  {output, code} = Settings.dispatch(args)
  IO.puts(String.trim_trailing(output))

  if code != 0 do
    raise "#{label} failed"
  end

  output
end

set = fn key, value ->
  dispatch.(["set", key, to_string(value)], "setting #{key}")
end

get = fn key, marker ->
  output = dispatch.(["get", key], "read #{key}")

  if not String.contains?(output, marker) do
    raise "verification failed for #{key}"
  end
end

case transition do
  "notify-off" ->
    set.("channels.#{channel}.autonomous_notify.enabled", false)
    get.("channels.#{channel}.autonomous_notify.enabled", "enabled=false")

  "notify-on" ->
    set.("channels.#{channel}.autonomous_notify.enabled", true)
    set.("channels.#{channel}.autonomous_notify.level", "status_and_completion")
    set.("channels.#{channel}.autonomous_notify.min_interval_seconds", 30)
    get.("channels.#{channel}.autonomous_notify.enabled", "enabled=true")
    get.("channels.#{channel}.autonomous_notify.level", "status_and_completion")
    get.("channels.#{channel}.autonomous_notify.min_interval_seconds", "=30")

  "confirmation-on" ->
    set.("permissions.command_execute", "needs_confirmation")
    get.("permissions.command_execute", ~s(permissions.command_execute="needs_confirmation"))

  "confirmation-off" ->
    set.("permissions.command_execute", "denied")
    get.("permissions.command_execute", ~s(permissions.command_execute="denied"))

  "all-test" ->
    if System.get_env("V11_TEST_MODE") != "1" do
      raise "all-test settings transition requires a test-prepared harness state"
    end

    set.("channels.#{channel}.autonomous_notify.enabled", false)
    get.("channels.#{channel}.autonomous_notify.enabled", "enabled=false")
    set.("channels.#{channel}.autonomous_notify.enabled", true)
    set.("channels.#{channel}.autonomous_notify.level", "status_and_completion")
    set.("channels.#{channel}.autonomous_notify.min_interval_seconds", 30)
    get.("channels.#{channel}.autonomous_notify.enabled", "enabled=true")
    get.("channels.#{channel}.autonomous_notify.level", "status_and_completion")
    get.("channels.#{channel}.autonomous_notify.min_interval_seconds", "=30")
    set.("permissions.command_execute", "needs_confirmation")
    get.("permissions.command_execute", ~s(permissions.command_execute="needs_confirmation"))
    set.("permissions.command_execute", "denied")
    get.("permissions.command_execute", ~s(permissions.command_execute="denied"))

  other ->
    raise "unsupported settings transition: #{other}"
end

IO.puts("V11 SETTINGS TRANSITION PASS transition=#{transition}")
