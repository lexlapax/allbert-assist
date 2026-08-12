defmodule AllbertSlack.CLI do
  @moduledoc """
  `allbert admin channels slack ...` — owned by this pack (v1.4 M13).

  Follows the shape `AllbertTelegram.CLI` established at M12: before this
  extraction, `allbert admin channels slack ...` was routed inside
  `AllbertAssist.CLI.Areas.Channels`, which called `Slack.Adapter` and
  `Slack.Parser` through compile-time aliases. That was fine while the
  plugin's source was path-injected into the residual; after extraction it
  would be a residual-to-pack return edge, which the R0 frozen DAG forbids
  (a pack may depend on the residual, never the reverse). So the command
  surface moves here, with the residual instead.

  `AllbertAssist.CLI.PackGroups` resolves `["admin", "channels", "slack"]`
  to this module via `AllbertSlack.Pack.cli_groups/0`, and
  `AllbertAssist.CLI.Commands.operator_table/0` merges that path in under its
  own literal table — the resolution is longest-prefix, so this table entry
  wins over the residual's `["admin", "channels"]` and `dispatch/2` receives
  only the argv remaining after `slack` (e.g. `["doctor"]`).

  Argument-guard failures throw `{:channels_guard, message}`, same shape the
  residual and `AllbertAssist.CLI.Channels.Support` use; caught here and
  rendered as an error (exit 1).

  `:secret_ref` and `:list_setting` are tags only slack and discord emit (the
  bot-token-by-reference and allow-listed-id-set commands neither telegram nor
  email need), so unlike the pure Support delegation telegram/email use, this
  module keeps a small local `render/1` for those two tags before falling
  through to `Support.render/1` for everything else. The `add_setting_list_value!`
  / `remove_setting_list_value!` helpers are likewise duplicated from
  `AllbertDiscord.CLI` rather than shared: neither pack may depend on the
  other, and neither is in `Support`.
  """

  @behaviour AllbertAssist.CLI.Area

  alias AllbertAssist.CLI.Areas.Render
  alias AllbertAssist.CLI.Channels.Support
  alias AllbertAssist.Channels
  alias AllbertAssist.Settings
  alias AllbertAssist.Surfaces.ContextBuilder
  alias AllbertSlack.Adapter
  alias AllbertSlack.Parser

  import Support,
    only: [
      parse!: 1,
      reject_invalid!: 1,
      required!: 2,
      single_arg!: 2,
      guard_error!: 1,
      configure_setting: 4,
      put_identity!: 4,
      remove_identity!: 3,
      completed_action: 3
    ]

  @surface "allbert admin channels slack"

  @usage """
  Usage:
    allbert admin channels slack set-token TOKEN_REF
    allbert admin channels slack set-app-token APP_TOKEN_REF
    allbert admin channels slack set-team-id TEAM_ID
    allbert admin channels slack add-channel CHANNEL_ID
    allbert admin channels slack remove-channel CHANNEL_ID
    allbert admin channels slack map --external-user EXTERNAL --user USER
    allbert admin channels slack unmap --external-user EXTERNAL
    allbert admin channels slack simulate --channel CHANNEL --user EXTERNAL "prompt"
    allbert admin channels slack simulate --channel CHANNEL --thread-ts TS --user EXTERNAL "prompt"
    allbert admin channels slack simulate-callback --channel CHANNEL --user EXTERNAL --action-id allbert:v1:<verb>:<id>
    allbert admin channels slack doctor
  """

  @impl true
  @spec dispatch([String.t()], map() | nil) :: {String.t(), non_neg_integer()}
  def dispatch(argv, context \\ nil) do
    ctx = context || default_context()

    result =
      try do
        route(argv, ctx)
      catch
        {:channels_guard, message} -> {:error, {:guard, message}}
      end

    render(result)
  end

  defp default_context, do: ContextBuilder.cli_context(surface: @surface)

  # ── Routing ────────────────────────────────────────────────────────────────

  defp route(["set-token", token_ref], ctx) do
    with :ok <- validate_slack_token_ref(token_ref, :bot),
         {:ok, _response} <- configure_setting(ctx, "slack", "bot_token_ref", token_ref) do
      {:ok, {:secret_ref, "slack", "bot_token"}}
    end
  end

  defp route(["set-app-token", token_ref], ctx) do
    with :ok <- validate_slack_token_ref(token_ref, :app),
         {:ok, _response} <- configure_setting(ctx, "slack", "app_token_ref", token_ref) do
      {:ok, {:secret_ref, "slack", "app_token"}}
    end
  end

  defp route(["set-team-id", team_id], ctx) do
    with {:ok, _response} <- configure_setting(ctx, "slack", "workspace_team_id", team_id) do
      {:ok, {:setting, "slack", "workspace_team_id", team_id}}
    end
  end

  defp route(["add-channel", channel_id], ctx) do
    add_setting_list_value!(ctx, "slack", "allowed_channel_ids", channel_id)
  end

  defp route(["remove-channel", channel_id], ctx) do
    remove_setting_list_value!(ctx, "slack", "allowed_channel_ids", channel_id)
  end

  defp route(["map" | rest], ctx) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)
    put_identity!(ctx, "slack", required!(opts, :external_user), required!(opts, :user))
  end

  defp route(["unmap" | rest], ctx) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)
    remove_identity!(ctx, "slack", required!(opts, :external_user))
  end

  defp route(["simulate" | rest], _ctx) do
    {opts, args, invalid} = parse!(rest)
    reject_invalid!(invalid)

    simulate_slack!(
      required!(opts, :channel),
      required!(opts, :user),
      Keyword.get(opts, :thread_ts),
      single_arg!(args, "Prompt is required")
    )
  end

  defp route(["simulate-callback" | rest], _ctx) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)

    simulate_slack_callback!(
      required!(opts, :user),
      required!(opts, :channel),
      required!(opts, :action_id)
    )
  end

  defp route(["doctor"], ctx) do
    with {:ok, response} <- completed_action("slack_doctor", %{}, ctx) do
      {:ok, {:doctor, "slack", response.doctor}}
    end
  end

  defp route(_args, _ctx), do: {:usage, @usage}

  # ── Actions ───────────────────────────────────────────────────────────────

  defp add_setting_list_value!(ctx, channel, key, value) do
    setting_key = "channels.#{channel}.#{key}"
    {:ok, values} = Settings.get(setting_key)
    updated = values |> Kernel.++([to_string(value)]) |> Enum.uniq()

    with {:ok, _response} <- configure_setting(ctx, channel, key, updated) do
      {:ok, {:list_setting, channel, key, updated}}
    end
  end

  defp remove_setting_list_value!(ctx, channel, key, value) do
    setting_key = "channels.#{channel}.#{key}"
    {:ok, values} = Settings.get(setting_key)
    updated = Enum.reject(values, &(&1 == to_string(value)))

    with {:ok, _response} <- configure_setting(ctx, channel, key, updated) do
      {:ok, {:list_setting, channel, key, updated}}
    end
  end

  defp simulate_slack!(channel_id, external_user_id, thread_ts, text) do
    with {:ok, settings} <- Channels.channel_settings("slack"),
         event <-
           Parser.simulated_event(%{
             team_id: Map.get(settings, "workspace_team_id"),
             channel_id: channel_id,
             thread_ts: thread_ts,
             user_id: external_user_id,
             text: text
           }),
         {:ok, adapter} <- Adapter.start_link(name: nil, client_opts: [mode: :stub]),
         result <- Adapter.simulate_socket_envelope(adapter, event) do
      GenServer.stop(adapter)
      normalize_slack_simulation(result)
    end
  end

  defp simulate_slack_callback!(external_user_id, channel_id, action_id) do
    with {:ok, settings} <- Channels.channel_settings("slack"),
         event <-
           Parser.simulated_interactive(%{
             team_id: Map.get(settings, "workspace_team_id"),
             channel_id: channel_id,
             user_id: external_user_id,
             action_id: action_id
           }),
         {:ok, adapter} <- Adapter.start_link(name: nil, client_opts: [mode: :stub]),
         result <- Adapter.simulate_socket_envelope(adapter, event) do
      GenServer.stop(adapter)
      {:ok, {:poll, "slack", result}}
    end
  end

  defp normalize_slack_simulation({:ok, {:processed, event, rendered}}) do
    {:ok, {:simulate, event, Enum.map(rendered, &Map.get(&1, :text, ""))}}
  end

  defp normalize_slack_simulation(other), do: {:ok, {:poll, "slack", other}}

  defp validate_slack_token_ref("secret://channels/slack/" <> rest, _kind) when rest != "",
    do: :ok

  defp validate_slack_token_ref(_token_ref, :bot),
    do: guard_error!("Slack set-token accepts only secret://channels/slack/... refs")

  defp validate_slack_token_ref(_token_ref, :app),
    do: guard_error!("Slack set-app-token accepts only secret://channels/slack/... refs")

  # ── Rendering ────────────────────────────────────────────────────────────────

  defp render({:ok, {:secret_ref, channel, secret_name}}) do
    Render.ok("#{channel} #{secret_name}_ref=stored")
  end

  defp render({:ok, {:list_setting, channel, key, values}}) do
    Render.ok("#{channel} #{key}=#{Enum.join(values, ",")}")
  end

  defp render(result), do: Support.render(result)
end
