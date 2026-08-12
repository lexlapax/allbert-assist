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

  v1.4 M12 moved `telegram` and `email` routing out to those channels' own
  packs, and v1.4 M13 finished the job: `discord`, `slack`, `matrix`,
  `whatsapp`, and `signal` moved out the same way — each channel now owns its
  own CLI module, resolved through `AllbertAssist.CLI.PackGroups.contributed/0`
  the same way `delegated/1` below resolves telegram and email. Every channel
  was extracted into its own pack, where the residual calling its adapter
  through a compile-time alias would have been a residual-to-pack dependency
  the R0 frozen DAG forbids. This module now owns only the cross-channel
  `list`/`status`/`--parity`/`show`/`setup-check`/`identity-links` reads, none
  of which depend on any single channel's plugin code. The argument-parsing
  and gated-action helpers those routes share with every extracted pack live
  in `AllbertAssist.CLI.Channels.Support`, imported below, so the
  implementation exists once rather than once per module.
  """

  import AllbertAssist.CLI.Channels.Support,
    only: [
      parse!: 1,
      reject_invalid!: 1,
      required!: 2,
      completed_action: 3
    ]

  alias AllbertAssist.CLI.Areas.Render
  alias AllbertAssist.CLI.Channels.Support
  alias AllbertAssist.CLI.PackGroups
  alias AllbertAssist.Channels.ChannelParity
  alias AllbertAssist.Conversations.ChannelThread
  alias AllbertAssist.Surfaces.ContextBuilder

  @surface "allbert admin channels"

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
  # makes the binary path work. Without this, extracting a channel's routes
  # into its pack would have left `allbert admin channels <channel> ...`
  # working and the documented Mix equivalent falling through to usage. The
  # module is resolved from the sealed projection at runtime, so the Mix
  # surface is restored without reintroducing the compile-time dependency on a
  # pack that the extraction exists to remove.
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

  defp render({:error, {:guard, _message}} = result), do: Support.render(result)

  defp render({:error, _reason} = result), do: Support.render(result)

  defp render({:usage, _usage} = result), do: Support.render(result)

  # ── Actions / read helpers ───────────────────────────────────────────────────

  defp operator_report_params do
    %{render_mode: "operator_report", surface_policy_affordance: true}
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
end
