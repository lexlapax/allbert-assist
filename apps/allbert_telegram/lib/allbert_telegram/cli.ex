defmodule AllbertTelegram.CLI do
  @moduledoc """
  `allbert admin channels telegram ...` — owned by this pack (v1.4 M12).

  Before the extraction, `allbert admin channels telegram ...` was routed
  inside `AllbertAssist.CLI.Areas.Channels`, which called `Telegram.Adapter`
  and `Telegram.Renderer` through compile-time aliases. That was fine while
  the plugin's source was path-injected into the residual; after extraction it
  would be a residual-to-pack return edge, which the R0 frozen DAG forbids
  (a pack may depend on the residual, never the reverse). So the command
  surface moves here, with the residual instead.

  `AllbertAssist.CLI.PackGroups` resolves `["admin", "channels", "telegram"]`
  to this module via `AllbertTelegram.Pack.cli_groups/0`, and
  `AllbertAssist.CLI.Commands.operator_table/0` merges that path in under its
  own literal table — the resolution is longest-prefix, so this table entry
  wins over the residual's `["admin", "channels"]` and `dispatch/2` receives
  only the argv remaining after `telegram` (e.g. `["poll-once"]`).

  Argument-guard failures throw `{:channels_guard, message}`, same shape the
  residual and `AllbertAssist.CLI.Channels.Support` use; caught here and
  rendered as an error (exit 1).
  """

  @behaviour AllbertAssist.CLI.Area

  alias AllbertAssist.CLI.Channels.Support
  alias AllbertAssist.Channels
  alias AllbertAssist.Channels.Identity
  alias AllbertAssist.Pack.EffectGuard
  alias AllbertAssist.Runtime
  alias AllbertAssist.Surfaces.ContextBuilder
  alias AllbertTelegram.Adapter
  alias AllbertTelegram.Renderer

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

  @surface "allbert admin channels telegram"

  @usage """
  Usage:
    allbert admin channels telegram set-token TOKEN
    allbert admin channels telegram map --external-user EXTERNAL --user USER
    allbert admin channels telegram unmap --external-user EXTERNAL
    allbert admin channels telegram simulate --external-user EXTERNAL --chat CHAT "prompt"
    allbert admin channels telegram poll-once
    allbert admin channels telegram doctor
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
    with {:ok, _response} <- configure_secret(ctx, "telegram", "bot_token", token) do
      {:ok, {:secret, "telegram", "bot_token"}}
    end
  end

  defp route(["map" | rest], ctx) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)
    put_identity!(ctx, "telegram", required!(opts, :external_user), required!(opts, :user))
  end

  defp route(["unmap" | rest], ctx) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)
    remove_identity!(ctx, "telegram", required!(opts, :external_user))
  end

  defp route(["simulate" | rest], ctx) do
    {opts, args, invalid} = parse!(rest)
    reject_invalid!(invalid)

    simulate_telegram!(
      ctx,
      required!(opts, :external_user),
      required!(opts, :chat),
      single_arg!(args, "Prompt is required")
    )
  end

  defp route(["poll-once"], _ctx) do
    {:ok, {:poll, "telegram", Adapter.poll_once()}}
  end

  defp route(["doctor"], ctx) do
    with {:ok, response} <- completed_action("telegram_doctor", %{}, ctx) do
      {:ok, {:doctor, "telegram", response.doctor}}
    end
  end

  defp route(_args, _ctx), do: {:usage, @usage}

  defp simulate_telegram!(ctx, external_user_id, chat_id, text) do
    with {:ok, epoch} <- carried_epoch(ctx),
         {:ok, settings} <- Channels.channel_settings("telegram"),
         {:ok, user_id} <-
           Identity.resolve("telegram", external_user_id, Map.get(settings, "identity_map", [])),
         session_id <- Channels.derive_session_id("telegram", external_user_id, chat_id),
         {prompt, new_thread?} <- prompt_text(text),
         {:ok, event} <-
           Channels.create_event(
             %{
               channel: "telegram",
               provider: "telegram_bot_api",
               direction: "inbound",
               external_event_id: "sim_#{Ecto.UUID.generate()}",
               external_user_id: external_user_id,
               external_chat_id: chat_id,
               status: "received",
               payload_summary: "telegram simulate"
             },
             %{allbert_pack_epoch: epoch}
           ),
         {:ok, response} <-
           Runtime.submit_user_input(
             %{
               text: prompt,
               delivery_ack_capability: Runtime.fanout_delivery_ack_capability(),
               channel: "telegram",
               user_id: user_id,
               operator_id: user_id,
               session_id: session_id,
               new_thread: new_thread?,
               metadata: simulate_metadata("telegram", "telegram_bot_api", event, nil)
             },
             allbert_pack_epoch: epoch
           ),
         {:ok, rendered, _keyboard} <- Renderer.render_response(response),
         :ok <- EffectGuard.validate(epoch),
         {:ok, event} <- mark_simulated_event(event, response, user_id, session_id, epoch),
         :ok <- EffectGuard.validate(epoch),
         :ok <-
           Runtime.acknowledge_deliveries(response, %{
             channel: "telegram",
             allbert_pack_epoch: epoch
           }) do
      {:ok, {:simulate, event, rendered}}
    end
  end
end
