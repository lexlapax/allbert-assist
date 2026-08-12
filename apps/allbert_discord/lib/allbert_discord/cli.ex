defmodule AllbertDiscord.CLI do
  @moduledoc """
  `allbert admin channels discord ...` — owned by this pack (v1.4 M13).

  Follows the shape `AllbertTelegram.CLI` established at M12: before this
  extraction, `allbert admin channels discord ...` was routed inside
  `AllbertAssist.CLI.Areas.Channels`, which called `Discord.Adapter` and
  `Discord.Parser` through compile-time aliases. That was fine while the
  plugin's source was path-injected into the residual; after extraction it
  would be a residual-to-pack return edge, which the R0 frozen DAG forbids
  (a pack may depend on the residual, never the reverse). So the command
  surface moves here, with the residual instead.

  `AllbertAssist.CLI.PackGroups` resolves `["admin", "channels", "discord"]`
  to this module via `AllbertDiscord.Pack.cli_groups/0`, and
  `AllbertAssist.CLI.Commands.operator_table/0` merges that path in under its
  own literal table — the resolution is longest-prefix, so this table entry
  wins over the residual's `["admin", "channels"]` and `dispatch/2` receives
  only the argv remaining after `discord` (e.g. `["doctor"]`).

  Argument-guard failures throw `{:channels_guard, message}`, same shape the
  residual and `AllbertAssist.CLI.Channels.Support` use; caught here and
  rendered as an error (exit 1).

  `:secret_ref` and `:list_setting` are tags only discord and slack emit (the
  bot-token-by-reference and allow-listed-id-set commands neither telegram nor
  email need), so unlike the pure Support delegation telegram/email use, this
  module keeps a small local `render/1` for those two tags before falling
  through to `Support.render/1` for everything else.
  """

  @behaviour AllbertAssist.CLI.Area

  alias AllbertAssist.CLI.Areas.Render
  alias AllbertAssist.CLI.Channels.Support
  alias AllbertAssist.Channels
  alias AllbertAssist.Settings
  alias AllbertAssist.Surfaces.ContextBuilder
  alias AllbertDiscord.Adapter
  alias AllbertDiscord.Parser

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

  @surface "allbert admin channels discord"
  @simulate_gateway_timeout_ms 120_000

  @usage """
  Usage:
    allbert admin channels discord set-token TOKEN_REF
    allbert admin channels discord set-application-id APPLICATION_ID
    allbert admin channels discord add-guild GUILD_ID
    allbert admin channels discord remove-guild GUILD_ID
    allbert admin channels discord add-channel CHANNEL_ID
    allbert admin channels discord remove-channel CHANNEL_ID
    allbert admin channels discord map --external-user EXTERNAL --user USER
    allbert admin channels discord unmap --external-user EXTERNAL
    allbert admin channels discord simulate --guild GUILD --channel CHANNEL --user EXTERNAL "prompt"
    allbert admin channels discord simulate --guild GUILD --channel CHANNEL --thread-channel THREAD --user EXTERNAL "prompt"
    allbert admin channels discord simulate-callback --user EXTERNAL --custom-id allbert:v1:<verb>:<id>
    allbert admin channels discord doctor
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
    with :ok <- validate_discord_token_ref(token_ref),
         {:ok, _response} <- configure_setting(ctx, "discord", "bot_token_ref", token_ref) do
      {:ok, {:secret_ref, "discord", "bot_token"}}
    end
  end

  defp route(["set-application-id", application_id], ctx) do
    with {:ok, _response} <-
           configure_setting(ctx, "discord", "application_id", application_id) do
      {:ok, {:setting, "discord", "application_id", application_id}}
    end
  end

  defp route(["add-guild", guild_id], ctx) do
    add_setting_list_value!(ctx, "discord", "allowed_guild_ids", guild_id)
  end

  defp route(["remove-guild", guild_id], ctx) do
    remove_setting_list_value!(ctx, "discord", "allowed_guild_ids", guild_id)
  end

  defp route(["add-channel", channel_id], ctx) do
    add_setting_list_value!(ctx, "discord", "allowed_channel_ids", channel_id)
  end

  defp route(["remove-channel", channel_id], ctx) do
    remove_setting_list_value!(ctx, "discord", "allowed_channel_ids", channel_id)
  end

  defp route(["map" | rest], ctx) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)
    put_identity!(ctx, "discord", required!(opts, :external_user), required!(opts, :user))
  end

  defp route(["unmap" | rest], ctx) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)
    remove_identity!(ctx, "discord", required!(opts, :external_user))
  end

  defp route(["simulate" | rest], _ctx) do
    {opts, args, invalid} = parse!(rest)
    reject_invalid!(invalid)

    simulate_discord!(
      required!(opts, :guild),
      required!(opts, :channel),
      required!(opts, :user),
      Keyword.get(opts, :thread_channel),
      single_arg!(args, "Prompt is required")
    )
  end

  defp route(["simulate-callback" | rest], _ctx) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)

    simulate_discord_callback!(
      required!(opts, :user),
      required!(opts, :custom_id)
    )
  end

  defp route(["doctor"], ctx) do
    with {:ok, response} <- completed_action("discord_doctor", %{}, ctx) do
      {:ok, {:doctor, "discord", response.doctor}}
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

  defp simulate_discord!(guild_id, channel_id, external_user_id, thread_channel_id, text) do
    with {:ok, settings} <- Channels.channel_settings("discord"),
         event <-
           Parser.simulated_message_event(%{
             guild_id: guild_id,
             channel_id: channel_id,
             thread_channel_id: thread_channel_id,
             user_id: external_user_id,
             application_id: Map.get(settings, "application_id"),
             text: text
           }),
         {:ok, adapter} <- Adapter.start_link(name: nil, client_opts: [mode: :stub]),
         result <-
           Adapter.simulate_gateway_event(adapter, event, @simulate_gateway_timeout_ms) do
      GenServer.stop(adapter)
      normalize_discord_simulation(result)
    end
  end

  defp simulate_discord_callback!(external_user_id, custom_id) do
    with {:ok, settings} <- Channels.channel_settings("discord"),
         event <-
           %{
             "t" => "INTERACTION_CREATE",
             "d" =>
               %{
                 "id" => "sim_" <> Ecto.UUID.generate(),
                 "token" => "sim_token_" <> Ecto.UUID.generate(),
                 "guild_id" => first_setting(settings, "allowed_guild_ids"),
                 "channel_id" => first_setting(settings, "allowed_channel_ids"),
                 "user" => %{"id" => external_user_id},
                 "data" => %{"custom_id" => custom_id}
               }
               |> compact()
           },
         {:ok, adapter} <- Adapter.start_link(name: nil, client_opts: [mode: :stub]),
         result <-
           Adapter.simulate_gateway_event(adapter, event, @simulate_gateway_timeout_ms) do
      GenServer.stop(adapter)
      normalize_discord_simulation(result)
    end
  end

  defp normalize_discord_simulation({:ok, {:processed, event, rendered}}) do
    {:ok, {:simulate, event, Enum.map(rendered, &Map.get(&1, :content, ""))}}
  end

  defp normalize_discord_simulation(other), do: {:ok, {:poll, "discord", other}}

  defp validate_discord_token_ref("secret://channels/discord/" <> rest) when rest != "",
    do: :ok

  defp validate_discord_token_ref(_token_ref),
    do: guard_error!("Discord set-token accepts only secret://channels/discord/... refs")

  defp first_setting(settings, key) do
    case Map.get(settings, key, []) do
      [value | _rest] -> value
      value when is_binary(value) and value != "" -> value
      _other -> nil
    end
  end

  defp compact(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, %{}, []] end)
    |> Map.new()
  end

  # ── Rendering ────────────────────────────────────────────────────────────────

  defp render({:ok, {:secret_ref, channel, secret_name}}) do
    Render.ok("#{channel} #{secret_name}_ref=stored")
  end

  defp render({:ok, {:list_setting, channel, key, values}}) do
    Render.ok("#{channel} #{key}=#{Enum.join(values, ",")}")
  end

  defp render(result), do: Support.render(result)
end
