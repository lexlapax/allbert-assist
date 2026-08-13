defmodule AllbertEmail.CLI do
  @moduledoc """
  `allbert admin channels email ...` — owned by this pack (v1.4 M12).

  Before the extraction, `allbert admin channels email ...` was routed inside
  `AllbertAssist.CLI.Areas.Channels`, which called `Email.Adapter` and
  `Email.Renderer` through compile-time aliases. That was fine while the
  plugin's source was path-injected into the residual; after extraction it
  would be a residual-to-pack return edge, which the R0 frozen DAG forbids
  (a pack may depend on the residual, never the reverse). So the command
  surface moves here, with the residual instead — following the same shape
  telegram used (`AllbertTelegram.CLI`).

  `AllbertAssist.CLI.PackGroups` resolves `["admin", "channels", "email"]` to
  this module via `AllbertEmail.Pack.cli_groups/0`, and
  `AllbertAssist.CLI.Commands.operator_table/0` merges that path in under its
  own literal table — the resolution is longest-prefix, so this table entry
  wins over the residual's `["admin", "channels"]` and `dispatch/2` receives
  only the argv remaining after `email` (e.g. `["poll-once"]`).

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
  alias AllbertEmail.Adapter
  alias AllbertEmail.Renderer

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

  @surface "allbert admin channels email"

  @usage """
  Usage:
    allbert admin channels email set-password --type imap|smtp PASSWORD
    allbert admin channels email map --external-user EMAIL --user USER
    allbert admin channels email unmap --external-user EMAIL
    allbert admin channels email simulate --external-user EMAIL [--new-thread] "prompt"
    allbert admin channels email poll-once
    allbert admin channels email doctor
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

  defp route(["set-password" | rest], ctx) do
    {opts, args, invalid} = parse!(rest)
    reject_invalid!(invalid)
    type = required!(opts, :type)
    password = single_arg!(args, "Password is required")
    set_email_password!(ctx, type, password)
  end

  defp route(["map" | rest], ctx) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)
    put_identity!(ctx, "email", required!(opts, :external_user), required!(opts, :user))
  end

  defp route(["unmap" | rest], ctx) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)
    remove_identity!(ctx, "email", required!(opts, :external_user))
  end

  defp route(["simulate" | rest], ctx) do
    {opts, args, invalid} = parse!(rest)
    reject_invalid!(invalid)

    simulate_email!(
      ctx,
      required!(opts, :external_user),
      single_arg!(args, "Prompt is required"),
      Keyword.get(opts, :new_thread, false)
    )
  end

  defp route(["poll-once"], _ctx) do
    {:ok, {:poll, "email", Adapter.poll_once()}}
  end

  defp route(["doctor"], ctx) do
    with {:ok, response} <- completed_action("email_doctor", %{}, ctx) do
      {:ok, {:doctor, "email", response.doctor}}
    end
  end

  defp route(_args, _ctx), do: {:usage, @usage}

  defp set_email_password!(ctx, "imap", password) do
    with {:ok, _response} <- configure_secret(ctx, "email", "imap_password", password) do
      {:ok, {:secret, "email", "imap_password"}}
    end
  end

  defp set_email_password!(ctx, "smtp", password) do
    with {:ok, _response} <- configure_secret(ctx, "email", "smtp_password", password) do
      {:ok, {:secret, "email", "smtp_password"}}
    end
  end

  defp set_email_password!(_ctx, type, _password),
    do: {:error, {:unknown_email_password_type, type}}

  defp simulate_email!(ctx, external_user_id, text, forced_new_thread?) do
    with {:ok, epoch} <- carried_epoch(ctx),
         {:ok, settings} <- Channels.channel_settings("email"),
         {:ok, user_id} <-
           Identity.resolve("email", external_user_id, Map.get(settings, "identity_map", [])),
         session_id <- Channels.derive_session_id("email", external_user_id, nil),
         {prompt, prompted_new_thread?} <- prompt_text(text),
         {:ok, event} <-
           Channels.create_event(
             %{
               channel: "email",
               provider: "email_imap",
               direction: "inbound",
               external_event_id: "sim_#{Ecto.UUID.generate()}",
               external_user_id: external_user_id,
               status: "received",
               payload_summary: "email simulate"
             },
             %{allbert_pack_epoch: epoch}
           ),
         {:ok, response} <-
           Runtime.submit_user_input(
             %{
               text: prompt,
               delivery_ack_capability: Runtime.fanout_delivery_ack_capability(),
               channel: "email",
               user_id: user_id,
               operator_id: user_id,
               session_id: session_id,
               new_thread: forced_new_thread? or prompted_new_thread?,
               metadata: simulate_metadata("email", "email_imap", event, nil)
             },
             allbert_pack_epoch: epoch
           ),
         {:ok, _subject, body, _html} <- Renderer.render_response(response),
         :ok <- EffectGuard.validate(epoch),
         {:ok, event} <- mark_simulated_event(event, response, user_id, session_id, epoch),
         :ok <- EffectGuard.validate(epoch),
         :ok <-
           Runtime.acknowledge_deliveries(response, %{channel: "email", allbert_pack_epoch: epoch}) do
      {:ok, {:simulate, event, [body]}}
    end
  end
end
