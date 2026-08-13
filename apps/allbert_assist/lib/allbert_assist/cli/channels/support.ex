defmodule AllbertAssist.CLI.Channels.Support do
  @moduledoc """
  Channel-generic CLI helpers shared across every `admin channels <channel>`
  route: the residual's remaining channels (discord, slack, matrix, whatsapp,
  signal, identity-links) and the extracted telegram/email packs (v1.4 M12).

  Before the telegram/email extraction these were `defp` inside
  `AllbertAssist.CLI.Areas.Channels`. None of them ever depended on
  `AllbertTelegram`/`AllbertEmail` — every function here already takes the
  channel name as a plain string argument — so they were shared CLI
  infrastructure sitting in the wrong module, not residual-private business
  logic. That is why they move to the residual side of the R0 DAG rather than
  into either pack: a pack may depend on the residual, never the reverse, and
  a copy living in one pack would either drift from or have to be duplicated
  into the other.

  Render clauses for the tags every channel can emit
  (`:secret`/`:setting`/`:identity`/`:unmapped`/`:poll`/`:doctor`/`:simulate`,
  plus the guard/error/usage fallbacks) live here too, for the same reason.
  Tags only one channel emits (`:webhook_post`, `:signal_link`, `:parity`,
  `:list`, `:status`, `:show`, `:setup_check`, `:identity_link*`) stay next to
  that channel's routing in `AllbertAssist.CLI.Areas.Channels`.

  Argument-guard failures throw `{:channels_guard, message}`, same shape as
  before the extraction. This module does not catch that throw — each
  `dispatch/2` that calls into it (the residual's `Areas.Channels` and both
  packs' `CLI` modules) owns catching it and rendering the result, so the
  guard unwinds to whichever dispatcher is running the current command.
  """

  alias AllbertAssist.Actions.Helper, as: ActionHelper
  alias AllbertAssist.Channels
  alias AllbertAssist.CLI.Areas.Render
  alias AllbertAssist.Pack.EffectGuard
  alias AllbertAssist.Settings

  @switches [
    action_id: :string,
    account: :string,
    aci: :string,
    bad_signature: :boolean,
    button_id: :string,
    chat: :string,
    channel: :string,
    custom_id: :string,
    device_name: :string,
    external_user: :string,
    guild: :string,
    link: :string,
    from: :string,
    message_id: :string,
    new_thread: :boolean,
    receiver: :string,
    room: :string,
    thread_ts: :string,
    thread_channel: :string,
    type: :string,
    url: :string,
    user: :string
  ]

  # ── Argument parsing ─────────────────────────────────────────────────────

  @spec parse!([String.t()]) ::
          {keyword(), [String.t()], [{String.t(), String.t() | nil}]}
  def parse!(args), do: OptionParser.parse(args, switches: @switches)

  @spec reject_invalid!([{String.t(), String.t() | nil}]) :: :ok | no_return()
  def reject_invalid!([]), do: :ok
  def reject_invalid!(invalid), do: guard_error!("Invalid option(s): #{inspect(invalid)}")

  @spec required!(keyword(), atom()) :: String.t() | no_return()
  def required!(opts, key) do
    case opts[key] do
      value when is_binary(value) and value != "" -> value
      _value -> guard_error!("--#{String.replace(Atom.to_string(key), "_", "-")} is required")
    end
  end

  @spec single_arg!([String.t()], String.t()) :: String.t() | no_return()
  def single_arg!([value], _message), do: value
  def single_arg!([], message), do: guard_error!(message)

  def single_arg!(args, _message),
    do: guard_error!("Expected one argument, got: #{inspect(args)}")

  # Raise a Mix-task-equivalent argument-guard failure; caught in each caller's
  # `dispatch/2` and rendered as an error (exit 1).
  @spec guard_error!(String.t()) :: no_return()
  def guard_error!(message), do: throw({:channels_guard, message})

  @spec prompt_text(String.t()) :: {String.t(), boolean()}
  def prompt_text("/new " <> text), do: {String.trim(text), true}
  def prompt_text(text), do: {text, false}

  # ── Epoch / gated-action seams ───────────────────────────────────────────

  @spec carried_epoch(map()) :: {:ok, term()} | {:error, :product_not_ready}
  def carried_epoch(%{allbert_pack_epoch: epoch}) do
    case EffectGuard.validate(epoch) do
      :ok -> {:ok, epoch}
      {:error, _reason} -> {:error, :product_not_ready}
    end
  end

  def carried_epoch(_ctx), do: {:error, :product_not_ready}

  @spec completed_action(String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def completed_action(action_name, params, ctx) do
    ActionHelper.completed_action(action_name, params, ctx)
  end

  # Every channel store/secret mutation goes through the Runner (Security
  # Central + audit), never a direct store call.
  @spec configure_setting(map(), String.t(), String.t(), term()) ::
          {:ok, map()} | {:error, term()}
  def configure_setting(ctx, channel, key, value) do
    completed_action(
      "configure_channel_setting",
      %{channel: channel, key: key, value: value},
      ctx
    )
  end

  @spec configure_secret(map(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def configure_secret(ctx, channel, credential, value) do
    completed_action(
      "configure_channel_secret",
      %{channel: channel, credential: credential, secret_value: value},
      ctx
    )
  end

  # The identity-map read stays direct (a pure read); only the mutation is
  # routed through the gated `configure_channel_setting` action.
  @spec put_identity!(map(), String.t(), String.t(), String.t()) ::
          {:ok, {:identity, String.t(), String.t(), String.t()}} | {:error, term()}
  def put_identity!(ctx, channel, external_user_id, user_id) do
    key = "channels.#{channel}.identity_map"
    {:ok, identity_map} = Settings.get(key)

    entry = %{
      external_user_id: external_user_id,
      user_id: user_id,
      enabled: true
    }

    updated =
      identity_map
      |> Enum.reject(&(identity_field(&1, "external_user_id") == external_user_id))
      |> Kernel.++([entry])

    with {:ok, _response} <- configure_setting(ctx, channel, "identity_map", updated) do
      {:ok, {:identity, channel, external_user_id, user_id}}
    end
  end

  @spec remove_identity!(map(), String.t(), String.t()) ::
          {:ok, {:unmapped, String.t(), String.t()}} | {:error, term()}
  def remove_identity!(ctx, channel, external_user_id) do
    key = "channels.#{channel}.identity_map"
    {:ok, identity_map} = Settings.get(key)

    updated =
      Enum.reject(identity_map, &(identity_field(&1, "external_user_id") == external_user_id))

    with {:ok, _response} <- configure_setting(ctx, channel, "identity_map", updated) do
      {:ok, {:unmapped, channel, external_user_id}}
    end
  end

  defp identity_field(map, key), do: Map.get(map, key, Map.get(map, String.to_atom(key)))

  # ── Simulate-path helpers ────────────────────────────────────────────────

  @spec simulate_metadata(String.t(), String.t(), struct(), String.t() | nil) :: map()
  def simulate_metadata(channel, provider, event, message_id) do
    %{
      channel: channel,
      provider: provider,
      external_event_id: event.external_event_id,
      external_user_id: event.external_user_id,
      external_chat_id: event.external_chat_id,
      external_message_id: message_id
    }
  end

  @spec mark_simulated_event(struct(), map(), String.t(), String.t() | nil, term()) ::
          {:ok, struct()} | {:error, term()}
  def mark_simulated_event(event, response, user_id, session_id, epoch) do
    Channels.update_event(
      event,
      %{
        status: "processed",
        user_id: user_id,
        session_id: session_id,
        thread_id: response_value(response, :thread_id),
        input_signal_id: response_value(response, :input_signal_id),
        trace_id: response_value(response, :trace_id)
      },
      %{allbert_pack_epoch: epoch}
    )
  end

  defp response_value(response, key) when is_map(response) do
    Map.get(response, key) || Map.get(response, Atom.to_string(key))
  end

  # ── Rendering ─────────────────────────────────────────────────────────────

  @typedoc """
  A tagged channel-CLI outcome this module knows how to render.

  Spelled out rather than left as `term()`: the residual channels area and both
  extracted channel packs emit these tags, so the union IS the shared vocabulary
  between them, and writing it down is what stops a pack inventing a tag nothing
  renders. A channel-specific tag stays private to its own area's `render/1`.
  """
  @type result ::
          {:ok,
           {:secret, term(), term()}
           | {:setting, term(), term(), term()}
           | {:identity, term(), term(), term()}
           | {:unmapped, term(), term()}
           | {:poll, term(), term()}
           | {:doctor, term(), map()}
           | {:simulate, term(), term()}}
          | {:error, term()}
          | {:usage, binary() | [binary()]}

  @spec render(result()) :: {String.t(), non_neg_integer()}
  def render({:ok, {:secret, channel, secret_name}}) do
    Render.ok("#{channel} #{secret_name}=stored")
  end

  def render({:ok, {:setting, channel, key, _value}}) do
    Render.ok("#{channel} #{key}=stored")
  end

  def render({:ok, {:identity, channel, external_user_id, user_id}}) do
    Render.ok("#{channel} #{external_user_id} -> #{user_id}")
  end

  def render({:ok, {:unmapped, channel, external_user_id}}) do
    Render.ok("#{channel} #{external_user_id} unmapped")
  end

  def render({:ok, {:simulate, event, rendered}}) do
    Render.ok(
      [
        "Event: #{event.channel}/#{event.external_event_id} status=#{event.status}",
        "User: #{event.user_id}",
        "Thread: #{event.thread_id}",
        "Response:"
      ] ++ List.wrap(rendered)
    )
  end

  def render({:ok, {:poll, channel, result}}) do
    Render.ok("#{channel} poll_once: #{inspect(result)}")
  end

  def render({:ok, {:doctor, channel, result}}) do
    Render.ok(
      [
        "#{channel} doctor status=#{Map.get(result, :status)}",
        "auth_ok=#{Map.get(result, :auth_ok)} endpoint_ok=#{Map.get(result, :endpoint_ok)}"
      ] ++
        doctor_field_line("gateway", Map.get(result, :gateway_status)) ++
        doctor_field_line("socket_mode", Map.get(result, :socket_mode_status)) ++
        doctor_field_line("poller", Map.get(result, :poller_status)) ++
        doctor_field_line("adapter", Map.get(result, :adapter_status)) ++
        doctor_field_line("control", Map.get(result, :control_mode)) ++
        doctor_field_line("local_only", Map.get(result, :control_local_only)) ++
        doctor_field_line("imap", Map.get(result, :imap_endpoint_ok)) ++
        doctor_field_line("smtp", Map.get(result, :smtp_endpoint_ok)) ++
        doctor_field_line("bot", Map.get(result, :bot_username)) ++
        doctor_field_line("user", Map.get(result, :user_id)) ++
        doctor_field_line("rooms", Map.get(result, :allowed_room_count))
    )
  end

  def render({:error, {:guard, message}}), do: Render.error(message)

  def render({:error, reason}) do
    Render.error("Channels command failed: #{inspect(reason)}")
  end

  def render({:usage, usage}), do: Render.usage(usage)

  defp doctor_field_line(_label, nil), do: []
  defp doctor_field_line(label, value), do: ["#{label}=#{value}"]
end
