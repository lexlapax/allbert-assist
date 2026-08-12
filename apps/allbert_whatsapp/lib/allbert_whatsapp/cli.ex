defmodule AllbertWhatsApp.CLI do
  @moduledoc """
  `allbert admin channels whatsapp ...` — owned by this pack (v1.4 M13).

  Follows the shape `AllbertTelegram.CLI` established at M12: before this
  extraction, `allbert admin channels whatsapp ...` was routed inside
  `AllbertAssist.CLI.Areas.Channels`, which called `WhatsApp.Adapter` and
  `WhatsApp.Parser` through compile-time aliases. That was fine while the
  plugin's source was path-injected into the residual; after extraction it
  would be a residual-to-pack return edge, which the R0 frozen DAG forbids
  (a pack may depend on the residual, never the reverse). So the command
  surface moves here, with the residual instead.

  `AllbertAssist.CLI.PackGroups` resolves `["admin", "channels", "whatsapp"]`
  to this module via `AllbertWhatsApp.Pack.cli_groups/0`, and
  `AllbertAssist.CLI.Commands.operator_table/0` merges that path in under its
  own literal table — the resolution is longest-prefix, so this table entry
  wins over the residual's `["admin", "channels"]` and `dispatch/2` receives
  only the argv remaining after `whatsapp` (e.g. `["doctor"]`).

  Argument-guard failures throw `{:channels_guard, message}`, same shape the
  residual and `AllbertAssist.CLI.Channels.Support` use; caught here and
  rendered as an error (exit 1).

  `:webhook_post` is a tag only this channel emits (`post-webhook` is the one
  simulate-style command that issues a real signed HTTP request instead of
  injecting in-process), so unlike the pure Support delegation telegram/email
  use, this module keeps a small local `render/1` for that tag before falling
  through to `Support.render/1` for everything else.
  """

  @behaviour AllbertAssist.CLI.Area

  import Ecto.Query

  alias AllbertAssist.Channels
  alias AllbertAssist.CLI.Areas.Render
  alias AllbertAssist.CLI.Channels.Support
  alias AllbertAssist.Pack.EffectGuard
  alias AllbertAssist.Settings.Secrets
  alias AllbertAssist.Surfaces.ContextBuilder
  alias AllbertWhatsApp.Adapter
  alias AllbertWhatsApp.Parser

  import Support,
    only: [
      parse!: 1,
      reject_invalid!: 1,
      required!: 2,
      single_arg!: 2,
      configure_secret: 4,
      put_identity!: 4,
      remove_identity!: 3,
      completed_action: 3
    ]

  @surface "allbert admin channels whatsapp"

  @usage """
  Usage:
    allbert admin channels whatsapp set-token TOKEN
    allbert admin channels whatsapp map --external-user PHONE --user USER
    allbert admin channels whatsapp unmap --external-user PHONE
    allbert admin channels whatsapp simulate --from PHONE [--message-id WAMID] "prompt"
    allbert admin channels whatsapp simulate-button --from PHONE --button-id allbert:v1:<verb>:<id>
    allbert admin channels whatsapp post-webhook --from PHONE [--message-id WAMID] [--bad-signature] [--url BASE] "prompt"
    allbert admin channels whatsapp doctor
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

  defp route(["set-token", token], ctx) do
    with {:ok, _response} <- configure_secret(ctx, "whatsapp", "access_token", token) do
      {:ok, {:secret, "whatsapp", "access_token"}}
    end
  end

  defp route(["map" | rest], ctx) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)
    put_identity!(ctx, "whatsapp", required!(opts, :external_user), required!(opts, :user))
  end

  defp route(["unmap" | rest], ctx) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)
    remove_identity!(ctx, "whatsapp", required!(opts, :external_user))
  end

  defp route(["simulate" | rest], _ctx) do
    {opts, args, invalid} = parse!(rest)
    reject_invalid!(invalid)

    simulate_whatsapp!(
      required!(opts, :from),
      Keyword.get(opts, :message_id),
      single_arg!(args, "Prompt is required")
    )
  end

  defp route(["simulate-button" | rest], _ctx) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)

    simulate_whatsapp_button!(
      required!(opts, :from),
      required!(opts, :button_id)
    )
  end

  defp route(["post-webhook" | rest], ctx) do
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

  defp route(["doctor"], ctx) do
    with {:ok, response} <- completed_action("whatsapp_doctor", %{}, ctx) do
      {:ok, {:doctor, "whatsapp", response.doctor}}
    end
  end

  defp route(_args, _ctx), do: {:usage, @usage}

  # ── Actions ───────────────────────────────────────────────────────────────

  defp simulate_whatsapp!(external_user_id, message_id, text) do
    with {:ok, settings} <- Channels.channel_settings("whatsapp"),
         payload <-
           Parser.simulated_text_webhook(%{
             from: external_user_id,
             phone_number_id: Map.get(settings, "phone_number_id"),
             display_phone_number: Map.get(settings, "phone_number_id"),
             waba_id: Map.get(settings, "waba_id"),
             message_id: message_id || "sim_" <> Ecto.UUID.generate(),
             text: text
           }),
         {:ok, adapter} <-
           Adapter.start_link(name: nil, req_options: [mode: :stub]),
         result <- Adapter.simulate_webhook_event(adapter, payload) do
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
        Parser.simulated_text_webhook(%{
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
           Parser.simulated_button_webhook(%{
             from: external_user_id,
             phone_number_id: Map.get(settings, "phone_number_id"),
             display_phone_number: Map.get(settings, "phone_number_id"),
             waba_id: Map.get(settings, "waba_id"),
             button_id: button_id
           }),
         {:ok, adapter} <-
           Adapter.start_link(name: nil, req_options: [mode: :stub]),
         result <- Adapter.simulate_webhook_event(adapter, payload) do
      GenServer.stop(adapter)
      {:ok, {:poll, "whatsapp", result}}
    end
  end

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

  defp secret_context,
    do: ContextBuilder.cli_context(surface: @surface, audit?: false)

  # ── Rendering ────────────────────────────────────────────────────────────────

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

  defp render(result), do: Support.render(result)
end
