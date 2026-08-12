defmodule AllbertSignal.CLI do
  @moduledoc """
  `allbert admin channels signal ...` — owned by this pack (v1.4 M13).

  Follows the shape `AllbertTelegram.CLI` established at M12: before this
  extraction, `allbert admin channels signal ...` was routed inside
  `AllbertAssist.CLI.Areas.Channels`, which called `Signal.Adapter` and
  `Signal.Parser` through compile-time aliases. That was fine while the
  plugin's source was path-injected into the residual; after extraction it
  would be a residual-to-pack return edge, which the R0 frozen DAG forbids
  (a pack may depend on the residual, never the reverse). So the command
  surface moves here, with the residual instead.

  `AllbertAssist.CLI.PackGroups` resolves `["admin", "channels", "signal"]`
  to this module via `AllbertSignal.Pack.cli_groups/0`, and
  `AllbertAssist.CLI.Commands.operator_table/0` merges that path in under its
  own literal table — the resolution is longest-prefix, so this table entry
  wins over the residual's `["admin", "channels"]` and `dispatch/2` receives
  only the argv remaining after `signal` (e.g. `["doctor"]`).

  Argument-guard failures throw `{:channels_guard, message}`, same shape the
  residual and `AllbertAssist.CLI.Channels.Support` use; caught here and
  rendered as an error (exit 1).

  `:signal_link` is a tag only this channel emits (the signal-cli device-link
  QR flow has no equivalent on any other channel), so unlike the pure Support
  delegation telegram/email use, this module keeps a small local `render/1`
  for that tag before falling through to `Support.render/1` for everything
  else.
  """

  @behaviour AllbertAssist.CLI.Area

  import Ecto.Query

  alias AllbertAssist.CLI.Areas.Render
  alias AllbertAssist.CLI.Channels.Support
  alias AllbertAssist.Channels
  alias AllbertAssist.Surfaces.ContextBuilder
  alias AllbertSignal.Adapter
  alias AllbertSignal.Parser

  import Support,
    only: [
      parse!: 1,
      reject_invalid!: 1,
      required!: 2,
      single_arg!: 2,
      guard_error!: 1,
      put_identity!: 4,
      remove_identity!: 3,
      completed_action: 3
    ]

  @surface "allbert admin channels signal"

  @usage """
  Usage:
    allbert admin channels signal map --aci ACI --user USER
    allbert admin channels signal unmap --aci ACI
    allbert admin channels signal simulate --aci ACI [--message-id TIMESTAMP_MS] "prompt"
    allbert admin channels signal link --account ACCOUNT [--device-name NAME]
    allbert admin channels signal doctor
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

  defp route(["map" | rest], ctx) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)
    put_signal_identity!(ctx, required!(opts, :aci), required!(opts, :user))
  end

  defp route(["unmap" | rest], ctx) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)
    remove_identity!(ctx, "signal", normalize_signal_aci!(required!(opts, :aci)))
  end

  defp route(["simulate" | rest], _ctx) do
    {opts, args, invalid} = parse!(rest)
    reject_invalid!(invalid)

    simulate_signal!(
      required!(opts, :aci),
      Keyword.get(opts, :message_id),
      single_arg!(args, "Prompt is required")
    )
  end

  defp route(["link" | rest], ctx) do
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

  defp route(["doctor"], ctx) do
    with {:ok, response} <- completed_action("signal_doctor", %{}, ctx) do
      {:ok, {:doctor, "signal", response.doctor}}
    end
  end

  defp route(_args, _ctx), do: {:usage, @usage}

  # ── Actions ───────────────────────────────────────────────────────────────

  defp put_signal_identity!(ctx, aci, user_id) do
    aci = normalize_signal_aci!(aci)
    put_identity!(ctx, "signal", aci, user_id)
  end

  defp simulate_signal!(aci, message_id, text) do
    aci = normalize_signal_aci!(aci)
    timestamp_ms = signal_message_timestamp(message_id)

    with {:ok, settings} <- Channels.channel_settings("signal"),
         notification <-
           Parser.simulated_receive_notification(%{
             source_aci: aci,
             timestamp_ms: timestamp_ms,
             text: text
           }),
         {:ok, adapter} <- Adapter.start_link(name: nil, client_opts: [mode: :stub]),
         result <- Adapter.simulate_daemon_notification(adapter, notification) do
      GenServer.stop(adapter)
      normalize_signal_simulation(result, settings)
    end
  end

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
    aci = Parser.normalize_aci(aci)

    if Parser.valid_aci?(aci) do
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

  # ── Rendering ────────────────────────────────────────────────────────────────

  defp render({:ok, {:signal_link, response}}) do
    Render.ok([
      "signal device_link=status=#{response.status}",
      "signal link_data=#{Map.get(response, :link_data)}"
    ])
  end

  defp render(result), do: Support.render(result)
end
