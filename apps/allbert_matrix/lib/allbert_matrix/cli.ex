defmodule AllbertMatrix.CLI do
  @moduledoc """
  `allbert admin channels matrix ...` — owned by this pack (v1.4 M13).

  Follows the shape `AllbertTelegram.CLI` established at M12: before this
  extraction, `allbert admin channels matrix ...` was routed inside
  `AllbertAssist.CLI.Areas.Channels`, which called `Matrix.Adapter` and
  `Matrix.Renderer` through compile-time aliases. That was fine while the
  plugin's source was path-injected into the residual; after extraction it
  would be a residual-to-pack return edge, which the R0 frozen DAG forbids
  (a pack may depend on the residual, never the reverse). So the command
  surface moves here, with the residual instead.

  `AllbertAssist.CLI.PackGroups` resolves `["admin", "channels", "matrix"]`
  to this module via `AllbertMatrix.Pack.cli_groups/0`, and
  `AllbertAssist.CLI.Commands.operator_table/0` merges that path in under its
  own literal table — the resolution is longest-prefix, so this table entry
  wins over the residual's `["admin", "channels"]` and `dispatch/2` receives
  only the argv remaining after `matrix` (e.g. `["poll-once"]`).

  Argument-guard failures throw `{:channels_guard, message}`, same shape the
  residual and `AllbertAssist.CLI.Channels.Support` use; caught here and
  rendered as an error (exit 1).
  """

  @behaviour AllbertAssist.CLI.Area

  alias AllbertAssist.Channels
  alias AllbertAssist.Channels.Identity
  alias AllbertAssist.CLI.Channels.Support
  alias AllbertAssist.Pack.EffectGuard
  alias AllbertAssist.Runtime
  alias AllbertAssist.Surfaces.ContextBuilder
  alias AllbertMatrix.Adapter
  alias AllbertMatrix.Renderer

  import Support,
    only: [
      parse!: 1,
      reject_invalid!: 1,
      required!: 2,
      single_arg!: 2,
      carried_epoch: 1,
      prompt_text: 1,
      simulate_metadata: 4,
      mark_simulated_event: 5,
      configure_secret: 4,
      put_identity!: 4,
      remove_identity!: 3,
      completed_action: 3
    ]

  @surface "allbert admin channels matrix"

  @usage """
  Usage:
    allbert admin channels matrix set-token TOKEN
    allbert admin channels matrix map --external-user MXID --user USER
    allbert admin channels matrix unmap --external-user MXID
    allbert admin channels matrix simulate --room ROOM --user MXID "prompt"
    allbert admin channels matrix poll-once
    allbert admin channels matrix doctor
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

    Support.render(result)
  end

  defp default_context, do: ContextBuilder.cli_context(surface: @surface)

  defp route(["set-token", token], ctx) do
    with {:ok, _response} <- configure_secret(ctx, "matrix", "access_token", token) do
      {:ok, {:secret, "matrix", "access_token"}}
    end
  end

  defp route(["map" | rest], ctx) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)
    put_identity!(ctx, "matrix", required!(opts, :external_user), required!(opts, :user))
  end

  defp route(["unmap" | rest], ctx) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)
    remove_identity!(ctx, "matrix", required!(opts, :external_user))
  end

  defp route(["simulate" | rest], ctx) do
    {opts, args, invalid} = parse!(rest)
    reject_invalid!(invalid)

    simulate_matrix!(
      ctx,
      required!(opts, :user),
      required!(opts, :room),
      single_arg!(args, "Prompt is required")
    )
  end

  defp route(["poll-once"], _ctx) do
    {:ok, {:poll, "matrix", Adapter.poll_once()}}
  end

  defp route(["doctor"], ctx) do
    with {:ok, response} <- completed_action("matrix_doctor", %{}, ctx) do
      {:ok, {:doctor, "matrix", response.doctor}}
    end
  end

  defp route(_args, _ctx), do: {:usage, @usage}

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
         {:ok, rendered} <- Renderer.render_response(response),
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
end
