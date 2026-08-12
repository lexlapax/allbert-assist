defmodule AllbertAssist.CLI.Areas.Channels do
  @moduledoc """
  Release-safe `channels` admin dispatch (v0.62 M8.7).

  The single source of truth for `mix allbert.channels` and
  `allbert admin channels`: `dispatch/2` parses the sub-argv, routes to the same
  registered actions and provider setup helpers the Mix task used, and returns
  `{rendered_output, exit_code}` — no `Mix.*` calls, so it runs inside the
  packaged release. `Mix.Tasks.Allbert.Channels` is a thin wrapper that disables
  channel auto-poll, starts the app, and prints the output through `Mix.shell/0`.

  Argument-guard failures that the Mix task raised via `Mix.raise/1` are surfaced
  as `throw({:channels_guard, message})`, caught in `dispatch/2`, and rendered as
  errors (exit 1); the trailing usage fall-through renders as usage (exit 2).

  v1.4 M12 moved `telegram` and `email` out to `AllbertTelegram.CLI` and
  `AllbertEmail.CLI`: those channels were extracted into their own packs, and
  the residual calling `Telegram.Adapter`/`Email.Adapter` through compile-time
  aliases would have been a residual-to-pack dependency the R0 frozen DAG
  forbids. This module still owns discord/slack/matrix/whatsapp/signal and the
  cross-channel `list`/`status`/`show`/`setup-check`/`identity-links` reads.
  The argument-parsing and gated-action helpers those routes share with the
  extracted packs now live in `AllbertAssist.CLI.Channels.Support`, imported
  below, so the implementation exists once rather than once per module.
  """

  import Ecto.Query

  import AllbertAssist.CLI.Channels.Support,
    only: [
      parse!: 1,
      reject_invalid!: 1,
      required!: 2,
      single_arg!: 2,
      guard_error!: 1,
      prompt_text: 1,
      carried_epoch: 1,
      completed_action: 3,
      configure_secret: 4,
      configure_setting: 4,
      put_identity!: 4,
      remove_identity!: 3,
      simulate_metadata: 4,
      mark_simulated_event: 5
    ]

  alias AllbertAssist.Channels
  alias AllbertAssist.Channels.ChannelParity
  alias AllbertAssist.Channels.Discord
  alias AllbertAssist.Channels.Identity
  alias AllbertAssist.Channels.Matrix
  alias AllbertAssist.Channels.Signal
  alias AllbertAssist.Channels.Slack
  alias AllbertAssist.Channels.WhatsApp
  alias AllbertAssist.CLI.Areas.Render
  alias AllbertAssist.CLI.Channels.Support
  alias AllbertAssist.CLI.PackGroups
  alias AllbertAssist.Conversations.ChannelThread
  alias AllbertAssist.Pack.EffectGuard
  alias AllbertAssist.Runtime
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Secrets
  alias AllbertAssist.Surfaces.ContextBuilder

  @surface "allbert admin channels"
  @simulate_gateway_timeout_ms 120_000

  @usage """
  Usage:
    allbert admin channels list
    allbert admin channels status
    allbert admin channels --parity
    allbert admin channels show telegram|email|discord|slack|matrix|whatsapp|signal
    allbert admin channels setup-check matrix|whatsapp|signal
    allbert admin channels identity-links add --link LINK --channel CHANNEL --receiver RECEIVER --external-user EXTERNAL --user USER
    allbert admin channels identity-links list [--link LINK] [--user USER]
    allbert admin channels identity-links remove --link LINK --channel CHANNEL --receiver RECEIVER --external-user EXTERNAL
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
    allbert admin channels matrix set-token TOKEN
    allbert admin channels matrix map --external-user MXID --user USER
    allbert admin channels matrix unmap --external-user MXID
    allbert admin channels matrix simulate --room ROOM --user MXID "prompt"
    allbert admin channels matrix poll-once
    allbert admin channels matrix doctor
    allbert admin channels whatsapp set-token TOKEN
    allbert admin channels whatsapp map --external-user PHONE --user USER
    allbert admin channels whatsapp unmap --external-user PHONE
    allbert admin channels whatsapp simulate --from PHONE [--message-id WAMID] "prompt"
    allbert admin channels whatsapp simulate-button --from PHONE --button-id allbert:v1:<verb>:<id>
    allbert admin channels whatsapp post-webhook --from PHONE [--message-id WAMID] [--bad-signature] [--url BASE] "prompt"
    allbert admin channels whatsapp doctor
    allbert admin channels signal map --aci ACI --user USER
    allbert admin channels signal unmap --aci ACI
    allbert admin channels signal simulate --aci ACI [--message-id TIMESTAMP_MS] "prompt"
    allbert admin channels signal link --account ACCOUNT [--device-name NAME]
    allbert admin channels signal doctor
  """

  @spec dispatch([String.t()], map() | nil) :: {String.t(), non_neg_integer()}
  def dispatch(argv, context \\ nil) do
    ctx = context || default_context()

    case delegated(argv) do
      {:ok, module, rest} ->
        module.dispatch(rest, ctx)

      :none ->
        result =
          try do
            route(argv, ctx)
          catch
            {:channels_guard, message} -> {:error, {:guard, message}}
          end

        render(result)
    end
  end

  # `mix allbert.channels telegram poll-once` reaches this module directly --
  # `Mix.Tasks.Allbert.Channels` calls `Areas.run(Areas.Channels, args)`, which
  # bypasses the CLI table and with it the contributed-group resolution that
  # makes the binary path work. Without this, extracting the telegram and email
  # routes into their packs would have left `allbert admin channels telegram
  # poll-once` working and the documented Mix equivalent falling through to
  # usage. The module is resolved from the sealed projection at runtime, so the
  # Mix surface is restored without reintroducing the compile-time dependency on
  # a pack that the extraction exists to remove.
  defp delegated([channel | rest]) when is_binary(channel) do
    case Map.fetch(PackGroups.contributed(), ["admin", "channels", channel]) do
      {:ok, {:area, module}} -> {:ok, module, rest}
      :error -> :none
    end
  end

  defp delegated(_argv), do: :none

  defp default_context, do: ContextBuilder.cli_context(surface: @surface)

  # ── Routing ────────────────────────────────────────────────────────────────

  defp route(["list"], ctx) do
    with {:ok, response} <-
           completed_action("list_channels", operator_report_params(), ctx) do
      {:ok, {:list, response.channels}}
    end
  end

  defp route(["status"], ctx) do
    with {:ok, response} <- completed_action("operator_channels", %{}, ctx) do
      {:ok, {:status, response}}
    end
  end

  defp route(["--parity"], ctx), do: route(["parity"], ctx)

  defp route(["parity"], _ctx) do
    case ChannelParity.verify() do
      :ok -> {:ok, {:parity, ChannelParity.table()}}
      {:error, errors} -> {:error, {:channel_parity_drift, errors}}
    end
  end

  defp route(["show", channel], ctx) do
    with {:ok, response} <- completed_action("show_channel", %{channel: channel}, ctx) do
      {:ok, {:show, response.channel}}
    end
  end

  defp route(["setup-check", channel], ctx) do
    with {:ok, response} <- completed_action("channel_setup_check", %{channel: channel}, ctx) do
      {:ok, {:setup_check, response.setup}}
    end
  end

  defp route(["matrix", "set-token", token], ctx) do
    with {:ok, _response} <- configure_secret(ctx, "matrix", "access_token", token) do
      {:ok, {:secret, "matrix", "access_token"}}
    end
  end

  defp route(["matrix", "map" | rest], ctx) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)
    put_identity!(ctx, "matrix", required!(opts, :external_user), required!(opts, :user))
  end

  defp route(["matrix", "unmap" | rest], ctx) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)
    remove_identity!(ctx, "matrix", required!(opts, :external_user))
  end

  defp route(["matrix", "simulate" | rest], ctx) do
    {opts, args, invalid} = parse!(rest)
    reject_invalid!(invalid)

    simulate_matrix!(
      ctx,
      required!(opts, :user),
      required!(opts, :room),
      single_arg!(args, "Prompt is required")
    )
  end

  defp route(["matrix", "poll-once"], _ctx) do
    {:ok, {:poll, "matrix", Matrix.Adapter.poll_once()}}
  end

  defp route(["matrix", "doctor"], ctx) do
    with {:ok, response} <- completed_action("matrix_doctor", %{}, ctx) do
      {:ok, {:doctor, "matrix", response.doctor}}
    end
  end

  defp route(["whatsapp", "set-token", token], ctx) do
    with {:ok, _response} <- configure_secret(ctx, "whatsapp", "access_token", token) do
      {:ok, {:secret, "whatsapp", "access_token"}}
    end
  end

  defp route(["whatsapp", "map" | rest], ctx) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)
    put_identity!(ctx, "whatsapp", required!(opts, :external_user), required!(opts, :user))
  end

  defp route(["whatsapp", "unmap" | rest], ctx) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)
    remove_identity!(ctx, "whatsapp", required!(opts, :external_user))
  end

  defp route(["whatsapp", "simulate" | rest], _ctx) do
    {opts, args, invalid} = parse!(rest)
    reject_invalid!(invalid)

    simulate_whatsapp!(
      required!(opts, :from),
      Keyword.get(opts, :message_id),
      single_arg!(args, "Prompt is required")
    )
  end

  defp route(["whatsapp", "simulate-button" | rest], _ctx) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)

    simulate_whatsapp_button!(
      required!(opts, :from),
      required!(opts, :button_id)
    )
  end

  defp route(["whatsapp", "post-webhook" | rest], ctx) do
    {opts, args, invalid} = parse!(rest)
    reject_invalid!(invalid)

    post_whatsapp_webhook!(
      required!(opts, :from),
      Keyword.get(opts, :message_id),
      Keyword.get(opts, :bad_signature, false),
      Keyword.get(opts, :url),
      single_arg!(args, "Prompt is required"),
      ctx
    )
  end

  defp route(["whatsapp", "doctor"], ctx) do
    with {:ok, response} <- completed_action("whatsapp_doctor", %{}, ctx) do
      {:ok, {:doctor, "whatsapp", response.doctor}}
    end
  end

  defp route(["signal", "map" | rest], ctx) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)
    put_signal_identity!(ctx, required!(opts, :aci), required!(opts, :user))
  end

  defp route(["signal", "unmap" | rest], ctx) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)
    remove_identity!(ctx, "signal", normalize_signal_aci!(required!(opts, :aci)))
  end

  defp route(["signal", "simulate" | rest], _ctx) do
    {opts, args, invalid} = parse!(rest)
    reject_invalid!(invalid)

    simulate_signal!(
      required!(opts, :aci),
      Keyword.get(opts, :message_id),
      single_arg!(args, "Prompt is required")
    )
  end

  defp route(["signal", "link" | rest], ctx) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)

    with {:ok, response} <-
           completed_action(
             "signal_link_device",
             %{
               account: required!(opts, :account),
               device_name: Keyword.get(opts, :device_name, "Allbert")
             },
             ctx
           ) do
      {:ok, {:signal_link, response}}
    end
  end

  defp route(["signal", "doctor"], ctx) do
    with {:ok, response} <- completed_action("signal_doctor", %{}, ctx) do
      {:ok, {:doctor, "signal", response.doctor}}
    end
  end

  defp route(["identity-links", "add" | rest], ctx) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)

    attrs = %{
      link_id: required!(opts, :link),
      user_id: required!(opts, :user),
      channel: required!(opts, :channel),
      receiver_account_ref: required!(opts, :receiver),
      external_user_id: required!(opts, :external_user)
    }

    with {:ok, response} <- completed_action("link_channel_identity", attrs, ctx) do
      {:ok, {:identity_link, response.link}}
    end
  end

  defp route(["identity-links", "list" | rest], _ctx) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)

    filters =
      %{
        link_id: Keyword.get(opts, :link),
        user_id: Keyword.get(opts, :user),
        channel: Keyword.get(opts, :channel),
        receiver_account_ref: Keyword.get(opts, :receiver)
      }
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Map.new()

    {:ok, {:identity_links, ChannelThread.list_identity_links(filters)}}
  end

  defp route(["identity-links", "remove" | rest], ctx) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)

    attrs = %{
      link_id: required!(opts, :link),
      channel: required!(opts, :channel),
      receiver_account_ref: required!(opts, :receiver),
      external_user_id: required!(opts, :external_user)
    }

    with {:ok, response} <- completed_action("unlink_channel_identity", attrs, ctx) do
      {:ok, {:identity_unlinked, response.link}}
    end
  end

  defp route(["discord", "set-token", token_ref], ctx) do
    with :ok <- validate_discord_token_ref(token_ref),
         {:ok, _response} <- configure_setting(ctx, "discord", "bot_token_ref", token_ref) do
      {:ok, {:secret_ref, "discord", "bot_token"}}
    end
  end

  defp route(["discord", "set-application-id", application_id], ctx) do
    with {:ok, _response} <-
           configure_setting(ctx, "discord", "application_id", application_id) do
      {:ok, {:setting, "discord", "application_id", application_id}}
    end
  end

  defp route(["discord", "add-guild", guild_id], ctx) do
    add_setting_list_value!(ctx, "discord", "allowed_guild_ids", guild_id)
  end

  defp route(["discord", "remove-guild", guild_id], ctx) do
    remove_setting_list_value!(ctx, "discord", "allowed_guild_ids", guild_id)
  end

  defp route(["discord", "add-channel", channel_id], ctx) do
    add_setting_list_value!(ctx, "discord", "allowed_channel_ids", channel_id)
  end

  defp route(["discord", "remove-channel", channel_id], ctx) do
    remove_setting_list_value!(ctx, "discord", "allowed_channel_ids", channel_id)
  end

  defp route(["discord", "map" | rest], ctx) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)
    put_identity!(ctx, "discord", required!(opts, :external_user), required!(opts, :user))
  end

  defp route(["discord", "unmap" | rest], ctx) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)
    remove_identity!(ctx, "discord", required!(opts, :external_user))
  end

  defp route(["discord", "simulate" | rest], _ctx) do
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

  defp route(["discord", "simulate-callback" | rest], _ctx) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)

    simulate_discord_callback!(
      required!(opts, :user),
      required!(opts, :custom_id)
    )
  end

  defp route(["discord", "doctor"], ctx) do
    with {:ok, response} <- completed_action("discord_doctor", %{}, ctx) do
      {:ok, {:doctor, "discord", response.doctor}}
    end
  end

  defp route(["slack", "set-token", token_ref], ctx) do
    with :ok <- validate_slack_token_ref(token_ref, :bot),
         {:ok, _response} <- configure_setting(ctx, "slack", "bot_token_ref", token_ref) do
      {:ok, {:secret_ref, "slack", "bot_token"}}
    end
  end

  defp route(["slack", "set-app-token", token_ref], ctx) do
    with :ok <- validate_slack_token_ref(token_ref, :app),
         {:ok, _response} <- configure_setting(ctx, "slack", "app_token_ref", token_ref) do
      {:ok, {:secret_ref, "slack", "app_token"}}
    end
  end

  defp route(["slack", "set-team-id", team_id], ctx) do
    with {:ok, _response} <- configure_setting(ctx, "slack", "workspace_team_id", team_id) do
      {:ok, {:setting, "slack", "workspace_team_id", team_id}}
    end
  end

  defp route(["slack", "add-channel", channel_id], ctx) do
    add_setting_list_value!(ctx, "slack", "allowed_channel_ids", channel_id)
  end

  defp route(["slack", "remove-channel", channel_id], ctx) do
    remove_setting_list_value!(ctx, "slack", "allowed_channel_ids", channel_id)
  end

  defp route(["slack", "map" | rest], ctx) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)
    put_identity!(ctx, "slack", required!(opts, :external_user), required!(opts, :user))
  end

  defp route(["slack", "unmap" | rest], ctx) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)
    remove_identity!(ctx, "slack", required!(opts, :external_user))
  end

  defp route(["slack", "simulate" | rest], _ctx) do
    {opts, args, invalid} = parse!(rest)
    reject_invalid!(invalid)

    simulate_slack!(
      required!(opts, :channel),
      required!(opts, :user),
      Keyword.get(opts, :thread_ts),
      single_arg!(args, "Prompt is required")
    )
  end

  defp route(["slack", "simulate-callback" | rest], _ctx) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)

    simulate_slack_callback!(
      required!(opts, :user),
      required!(opts, :channel),
      required!(opts, :action_id)
    )
  end

  defp route(["slack", "doctor"], ctx) do
    with {:ok, response} <- completed_action("slack_doctor", %{}, ctx) do
      {:ok, {:doctor, "slack", response.doctor}}
    end
  end

  defp route(_args, _ctx), do: {:usage, @usage}

  # ── Rendering ────────────────────────────────────────────────────────────────

  defp render({:ok, {:list, channels}}) do
    Render.ok(
      Enum.map(channels, fn channel ->
        "#{channel.channel} provider=#{channel.provider} release=#{channel.release_status} enabled=#{channel.enabled} identities=#{channel.identity_count} credentials=#{credential_status(channel.credential_status)}"
      end)
    )
  end

  defp render({:ok, {:status, response}}) do
    response
    |> response_value(:surface_payload)
    |> to_string()
    |> String.split("\n", trim: true)
    |> Render.ok()
  end

  defp render({:ok, {:parity, table}}) do
    Render.ok(table)
  end

  defp render({:ok, {:show, channel}}) do
    Render.ok(
      [
        "Channel: #{channel.channel}",
        "Provider: #{channel.provider}",
        "Release status: #{channel.release_status}"
      ] ++
        release_decision_lines(channel) ++
        [
          "Enabled: #{channel.enabled}",
          "Identities: #{channel.identity_count}",
          "Credentials: #{credential_status(channel.credential_status)}"
        ] ++
        doctor_summary_lines(channel) ++
        ["Last event: #{inspect(channel.last_event)}"]
    )
  end

  defp render({:ok, {:setup_check, setup}}) do
    retry = setup.retry_posture || %{}

    Render.ok(
      [
        "#{setup.channel} setup status=#{setup.setup_status}",
        "release=#{setup.release_status}"
      ] ++
        release_decision_lines(setup) ++
        [
          "enabled=#{setup.enabled}",
          "missing=#{diagnostic_status(setup.diagnostics)}",
          "settings=#{setup_fields(setup.required_settings)}",
          "secrets=#{secret_fields(setup.secret_status)}",
          "doctor=#{Map.get(setup.commands, :doctor)}",
          "smoke=#{Map.get(setup.commands, :smoke)}"
        ] ++
        pair_lines(setup.commands) ++
        ["automatic_provider_retry=#{Map.get(retry, :automatic_provider_retry?, false)}"]
    )
  end

  # `:secret`, `:setting`, `:identity`, `:unmapped`, `:poll`, `:doctor`, and
  # `:simulate` are tags every channel route can emit (not just the ones still
  # routed here), so their rendering lives once in `Support` and this
  # dispatcher delegates rather than keeping a second copy.
  defp render({:ok, {:secret, _channel, _secret_name}} = result), do: Support.render(result)

  defp render({:ok, {:secret_ref, channel, secret_name}}) do
    Render.ok("#{channel} #{secret_name}_ref=stored")
  end

  defp render({:ok, {:setting, _channel, _key, _value}} = result), do: Support.render(result)

  defp render({:ok, {:list_setting, channel, key, values}}) do
    Render.ok("#{channel} #{key}=#{Enum.join(values, ",")}")
  end

  defp render({:ok, {:identity, _channel, _external_user_id, _user_id}} = result),
    do: Support.render(result)

  defp render({:ok, {:unmapped, _channel, _external_user_id}} = result),
    do: Support.render(result)

  defp render({:ok, {:identity_link, link}}) do
    Render.ok(identity_link_line(link, "linked"))
  end

  defp render({:ok, {:identity_unlinked, link}}) do
    Render.ok(identity_link_line(link, "unlinked"))
  end

  defp render({:ok, {:identity_links, []}}) do
    Render.ok("identity links: none")
  end

  defp render({:ok, {:identity_links, links}}) do
    Render.ok(Enum.map(links, &identity_link_line(&1, "link")))
  end

  defp render({:ok, {:simulate, _event, _rendered}} = result), do: Support.render(result)

  defp render({:ok, {:poll, _channel, _result}} = result), do: Support.render(result)

  defp render({:ok, {:doctor, _channel, _result}} = result), do: Support.render(result)

  defp render({:ok, {:webhook_post, status, body, expected, bad_signature?}}) do
    label =
      if bad_signature?,
        do: "whatsapp post-webhook (bad-signature)",
        else: "whatsapp post-webhook (signed)"

    verdict =
      case {expected, status} do
        {:accept_202, 202} ->
          "PASS: signature verified and webhook accepted (HTTP 202)"

        {:deny_401, 401} ->
          "PASS: invalid signature rejected before parse (HTTP 401)"

        {:accept_202, other} ->
          "UNEXPECTED: expected HTTP 202, got #{other} " <>
            "(check that mix phx.server is running and channels.whatsapp.webhook_enabled, " <>
            "phone_number_id, and app_secret_ref are configured)"

        {:deny_401, other} ->
          "UNEXPECTED: expected HTTP 401 for a bad signature, got #{other}"
      end

    Render.ok([
      "#{label} -> HTTP #{status}",
      "response: #{body}",
      verdict
    ])
  end

  defp render({:ok, {:signal_link, response}}) do
    Render.ok([
      "signal device_link=status=#{response.status}",
      "signal link_data=#{Map.get(response, :link_data)}"
    ])
  end

  defp render({:error, {:guard, _message}} = result), do: Support.render(result)

  defp render({:error, _reason} = result), do: Support.render(result)

  defp render({:usage, _usage} = result), do: Support.render(result)

  # ── Actions / read helpers ───────────────────────────────────────────────────

  defp operator_report_params do
    %{render_mode: "operator_report", surface_policy_affordance: true}
  end

  defp put_signal_identity!(ctx, aci, user_id) do
    aci = normalize_signal_aci!(aci)
    put_identity!(ctx, "signal", aci, user_id)
  end

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

  defp simulate_matrix!(ctx, external_user_id, room_id, text) do
    with {:ok, epoch} <- carried_epoch(ctx),
         {:ok, settings} <- Channels.channel_settings("matrix"),
         {:ok, user_id} <-
           Identity.resolve("matrix", external_user_id, Map.get(settings, "identity_map", [])),
         session_id <- Channels.derive_session_id("matrix", external_user_id, room_id),
         {prompt, new_thread?} <- prompt_text(text),
         {:ok, event} <-
           Channels.create_event(
             %{
               channel: "matrix",
               provider: "matrix_client_server",
               direction: "inbound",
               external_event_id: "sim_" <> Ecto.UUID.generate(),
               external_user_id: external_user_id,
               external_chat_id: room_id,
               status: "received",
               payload_summary: "matrix simulate"
             },
             %{allbert_pack_epoch: epoch}
           ),
         {:ok, response} <-
           Runtime.submit_user_input(
             %{
               text: prompt,
               delivery_ack_capability: Runtime.fanout_delivery_ack_capability(),
               channel: "matrix",
               user_id: user_id,
               operator_id: user_id,
               session_id: session_id,
               new_thread: new_thread?,
               metadata: simulate_metadata("matrix", "matrix_client_server", event, nil)
             },
             allbert_pack_epoch: epoch
           ),
         {:ok, rendered} <- Matrix.Renderer.render_response(response),
         :ok <- EffectGuard.validate(epoch),
         {:ok, event} <- mark_simulated_event(event, response, user_id, session_id, epoch),
         :ok <- EffectGuard.validate(epoch),
         :ok <-
           Runtime.acknowledge_deliveries(response, %{
             channel: "matrix",
             allbert_pack_epoch: epoch
           }) do
      {:ok, {:simulate, event, rendered}}
    end
  end

  defp simulate_whatsapp!(external_user_id, message_id, text) do
    with {:ok, settings} <- Channels.channel_settings("whatsapp"),
         payload <-
           WhatsApp.Parser.simulated_text_webhook(%{
             from: external_user_id,
             phone_number_id: Map.get(settings, "phone_number_id"),
             display_phone_number: Map.get(settings, "phone_number_id"),
             waba_id: Map.get(settings, "waba_id"),
             message_id: message_id || "sim_" <> Ecto.UUID.generate(),
             text: text
           }),
         {:ok, adapter} <-
           WhatsApp.Adapter.start_link(name: nil, req_options: [mode: :stub]),
         result <- WhatsApp.Adapter.simulate_webhook_event(adapter, payload) do
      GenServer.stop(adapter)
      normalize_whatsapp_simulation(result)
    end
  end

  # Validates the live ADR 0056 signed-webhook auth path locally: it computes the
  # same `sha256=`-prefixed HMAC the ingress checks and issues a real HTTP POST to a
  # running endpoint, so (unlike `whatsapp simulate`, which injects in-process and
  # bypasses the HTTP/signature layer) it exercises `X-Hub-Signature-256`
  # verification before parse. `--bad-signature` sends a wrong digest to confirm the
  # HTTP 401 denial.
  defp post_whatsapp_webhook!(from, message_id, bad_signature?, base_url, text, context) do
    with {:ok, settings} <- Channels.channel_settings("whatsapp"),
         {:ok, phone_number_id} <- whatsapp_phone_number_id(settings),
         app_secret_ref <-
           Map.get(settings, "app_secret_ref", "secret://channels/whatsapp/app_secret"),
         {:ok, app_secret} <- Secrets.get_secret(app_secret_ref, secret_context()) do
      payload =
        WhatsApp.Parser.simulated_text_webhook(%{
          from: from,
          phone_number_id: phone_number_id,
          display_phone_number: Map.get(settings, "phone_number_id"),
          waba_id: Map.get(settings, "waba_id"),
          message_id: message_id || "wamid." <> Ecto.UUID.generate(),
          text: text
        })

      raw_body = Jason.encode!(payload)
      signature = whatsapp_webhook_signature(app_secret, raw_body, bad_signature?)
      base = base_url || System.get_env("ALLBERT_WEBHOOK_BASE_URL") || "http://127.0.0.1:4000"

      url =
        String.trim_trailing(base, "/") <> "/webhooks/whatsapp/" <> URI.encode(phone_number_id)

      post_signed_whatsapp_webhook(
        url,
        raw_body,
        signature,
        bad_signature?,
        Map.get(context, :allbert_pack_epoch)
      )
    end
  end

  defp whatsapp_phone_number_id(settings) do
    case Map.get(settings, "phone_number_id") do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, :whatsapp_phone_number_id_not_configured}
    end
  end

  defp whatsapp_webhook_signature(app_secret, raw_body, false) do
    "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, app_secret, raw_body), case: :lower)
  end

  defp whatsapp_webhook_signature(_app_secret, _raw_body, true) do
    # Correct shape (64 lowercase hex), wrong bytes: passes the format check so the
    # ingress reaches `secure_compare`, which then rejects it as invalid.
    "sha256=" <> String.duplicate("0", 64)
  end

  defp post_signed_whatsapp_webhook(url, raw_body, signature, bad_signature?, epoch) do
    expected = if bad_signature?, do: :deny_401, else: :accept_202

    with :ok <- EffectGuard.validate(epoch),
         result <-
           Req.post(url,
             headers: [
               {"content-type", "application/json"},
               {"x-hub-signature-256", signature}
             ],
             body: raw_body,
             decode_body: false,
             retry: false
           ) do
      case result do
        {:ok, %Req.Response{status: status, body: body}} ->
          {:ok, {:webhook_post, status, to_string(body), expected, bad_signature?}}

        {:error, exception} when is_exception(exception) ->
          {:error, {:webhook_post_transport, Exception.message(exception)}}

        {:error, reason} ->
          {:error, {:webhook_post_transport, reason}}
      end
    end
  end

  defp simulate_whatsapp_button!(external_user_id, button_id) do
    with {:ok, settings} <- Channels.channel_settings("whatsapp"),
         payload <-
           WhatsApp.Parser.simulated_button_webhook(%{
             from: external_user_id,
             phone_number_id: Map.get(settings, "phone_number_id"),
             display_phone_number: Map.get(settings, "phone_number_id"),
             waba_id: Map.get(settings, "waba_id"),
             button_id: button_id
           }),
         {:ok, adapter} <-
           WhatsApp.Adapter.start_link(name: nil, req_options: [mode: :stub]),
         result <- WhatsApp.Adapter.simulate_webhook_event(adapter, payload) do
      GenServer.stop(adapter)
      {:ok, {:poll, "whatsapp", result}}
    end
  end

  defp simulate_signal!(aci, message_id, text) do
    aci = normalize_signal_aci!(aci)
    timestamp_ms = signal_message_timestamp(message_id)

    with {:ok, settings} <- Channels.channel_settings("signal"),
         notification <-
           Signal.Parser.simulated_receive_notification(%{
             source_aci: aci,
             timestamp_ms: timestamp_ms,
             text: text
           }),
         {:ok, adapter} <-
           Signal.Adapter.start_link(name: nil, client_opts: [mode: :stub]),
         result <- Signal.Adapter.simulate_daemon_notification(adapter, notification) do
      GenServer.stop(adapter)
      normalize_signal_simulation(result, settings)
    end
  end

  defp simulate_discord!(guild_id, channel_id, external_user_id, thread_channel_id, text) do
    with {:ok, settings} <- Channels.channel_settings("discord"),
         event <-
           Discord.Parser.simulated_message_event(%{
             guild_id: guild_id,
             channel_id: channel_id,
             thread_channel_id: thread_channel_id,
             user_id: external_user_id,
             application_id: Map.get(settings, "application_id"),
             text: text
           }),
         {:ok, adapter} <- Discord.Adapter.start_link(name: nil, client_opts: [mode: :stub]),
         result <-
           Discord.Adapter.simulate_gateway_event(adapter, event, @simulate_gateway_timeout_ms) do
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
         {:ok, adapter} <- Discord.Adapter.start_link(name: nil, client_opts: [mode: :stub]),
         result <-
           Discord.Adapter.simulate_gateway_event(adapter, event, @simulate_gateway_timeout_ms) do
      GenServer.stop(adapter)
      normalize_discord_simulation(result)
    end
  end

  defp simulate_slack!(channel_id, external_user_id, thread_ts, text) do
    with {:ok, settings} <- Channels.channel_settings("slack"),
         event <-
           Slack.Parser.simulated_event(%{
             team_id: Map.get(settings, "workspace_team_id"),
             channel_id: channel_id,
             thread_ts: thread_ts,
             user_id: external_user_id,
             text: text
           }),
         {:ok, adapter} <- Slack.Adapter.start_link(name: nil, client_opts: [mode: :stub]),
         result <- Slack.Adapter.simulate_socket_envelope(adapter, event) do
      GenServer.stop(adapter)
      normalize_slack_simulation(result)
    end
  end

  defp simulate_slack_callback!(external_user_id, channel_id, action_id) do
    with {:ok, settings} <- Channels.channel_settings("slack"),
         event <-
           Slack.Parser.simulated_interactive(%{
             team_id: Map.get(settings, "workspace_team_id"),
             channel_id: channel_id,
             user_id: external_user_id,
             action_id: action_id
           }),
         {:ok, adapter} <- Slack.Adapter.start_link(name: nil, client_opts: [mode: :stub]),
         result <- Slack.Adapter.simulate_socket_envelope(adapter, event) do
      GenServer.stop(adapter)
      {:ok, {:poll, "slack", result}}
    end
  end

  defp normalize_discord_simulation({:ok, {:processed, event, rendered}}) do
    {:ok, {:simulate, event, Enum.map(rendered, &Map.get(&1, :content, ""))}}
  end

  defp normalize_discord_simulation(other), do: {:ok, {:poll, "discord", other}}

  defp normalize_slack_simulation({:ok, {:processed, event, rendered}}) do
    {:ok, {:simulate, event, Enum.map(rendered, &Map.get(&1, :text, ""))}}
  end

  defp normalize_slack_simulation(other), do: {:ok, {:poll, "slack", other}}

  defp normalize_whatsapp_simulation({:ok, %{processed: processed} = summary})
       when processed > 0 do
    event =
      AllbertAssist.Repo.one(
        from event in AllbertAssist.Channels.Event,
          where: event.channel == "whatsapp",
          order_by: [desc: event.inserted_at],
          limit: 1
      )

    {:ok, {:simulate, event, ["whatsapp processed=#{summary.processed}"]}}
  end

  defp normalize_whatsapp_simulation(other), do: {:ok, {:poll, "whatsapp", other}}

  defp normalize_signal_simulation({:ok, %{processed: processed} = summary}, _settings)
       when processed > 0 do
    event =
      AllbertAssist.Repo.one(
        from event in AllbertAssist.Channels.Event,
          where: event.channel == "signal",
          order_by: [desc: event.inserted_at],
          limit: 1
      )

    {:ok, {:simulate, event, ["signal processed=#{summary.processed}"]}}
  end

  defp normalize_signal_simulation(other, _settings), do: {:ok, {:poll, "signal", other}}

  defp normalize_signal_aci!(aci) do
    aci = Signal.Parser.normalize_aci(aci)

    if Signal.Parser.valid_aci?(aci) do
      aci
    else
      guard_error!("Signal identity must be an ACI UUID")
    end
  end

  defp signal_message_timestamp(nil), do: System.system_time(:millisecond)

  defp signal_message_timestamp(value) do
    case Integer.parse(to_string(value)) do
      {timestamp, ""} -> timestamp
      _error -> guard_error!("--message-id must be a Signal timestamp in milliseconds")
    end
  end

  defp validate_discord_token_ref("secret://channels/discord/" <> rest) when rest != "",
    do: :ok

  defp validate_discord_token_ref(_token_ref),
    do: guard_error!("Discord set-token accepts only secret://channels/discord/... refs")

  defp validate_slack_token_ref("secret://channels/slack/" <> rest, _kind) when rest != "",
    do: :ok

  defp validate_slack_token_ref(_token_ref, :bot),
    do: guard_error!("Slack set-token accepts only secret://channels/slack/... refs")

  defp validate_slack_token_ref(_token_ref, :app),
    do: guard_error!("Slack set-app-token accepts only secret://channels/slack/... refs")

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

  defp credential_status(statuses) when is_map(statuses) do
    statuses
    |> Map.values()
    |> Enum.uniq()
    |> Enum.map(&to_string/1)
    |> Enum.join(",")
  end

  defp credential_status(_statuses), do: "unknown"

  defp diagnostic_status([]), do: "none"

  defp diagnostic_status(diagnostics) do
    diagnostics
    |> Enum.map(&to_string/1)
    |> Enum.join(",")
  end

  defp setup_fields(fields) do
    fields
    |> Enum.map(fn field ->
      "#{field.name}=#{setup_field_status(field)}"
    end)
    |> Enum.join(",")
  end

  defp setup_field_status(%{required?: true, configured?: true}), do: "configured"
  defp setup_field_status(%{required?: true, configured?: false}), do: "missing"
  defp setup_field_status(%{required?: false, configured?: true}), do: "configured_optional"
  defp setup_field_status(%{required?: false, configured?: false}), do: "optional"

  defp secret_fields(fields) do
    fields
    |> Enum.map(fn field ->
      "#{field.name}=#{field.status}#{secret_required_suffix(field)}"
    end)
    |> Enum.join(",")
  end

  defp secret_required_suffix(%{required?: true}), do: ""
  defp secret_required_suffix(%{required?: false}), do: "_optional"

  defp release_decision_lines(%{release_decision: %{live_use_allowed?: true}}), do: []

  defp release_decision_lines(%{release_decision: %{decision: decision}})
       when is_binary(decision) do
    ["Release decision: #{decision}"]
  end

  defp release_decision_lines(_value), do: []

  defp doctor_summary_lines(%{doctor: doctor}) when is_map(doctor) do
    ["Doctor: #{doctor_status(doctor)}"]
  end

  defp doctor_summary_lines(_channel), do: []

  defp pair_lines(commands) do
    case Map.get(commands, :pair) do
      command when is_binary(command) -> ["pair=#{command}"]
      _command -> []
    end
  end

  defp doctor_status(doctor) do
    Map.get(doctor, "status", Map.get(doctor, :status, "unknown"))
  end

  defp identity_link_line(link, prefix) do
    "#{prefix} #{link.link_id} user=#{link.user_id} channel=#{link.channel} receiver=#{link.receiver_account_ref} external_user=#{link.external_user_id}"
  end

  defp response_value(response, key) when is_map(response) do
    Map.get(response, key) || Map.get(response, Atom.to_string(key))
  end

  defp secret_context,
    do: ContextBuilder.cli_context(surface: @surface, audit?: false)
end
