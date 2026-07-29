defmodule AllbertAssist.Runtime.Attach.TUIProtocol do
  @moduledoc """
  State-free protocol authority for additive daemon-backed TUI Attach sessions.

  This module owns only packet classification, schema validation, bounded
  construction, and deterministic sequence transitions. It holds no process or
  runtime state and grants no application authority.
  """

  alias AllbertAssist.Runtime.Redactor

  @session_protocol 1
  @attach_token_bytes 43
  @max_integer 9_223_372_036_854_775_807
  @open_body_bytes 16 * 1_024
  @frame_body_bytes 64 * 1_024
  @container_depth 8
  @map_keys 32
  @list_items 256
  @open_close_codes [
    :invalid_open,
    :unsupported_kind,
    :token_mismatch,
    :home_mismatch,
    :uid_mismatch,
    :version_mismatch,
    :protocol_mismatch,
    :identity_denied,
    :already_attached,
    :capacity,
    :runtime_unavailable
  ]
  @open_message_bytes 1_024
  @open_keys [
    :kind,
    :frame,
    :session_protocol,
    :protocol,
    :home,
    :uid,
    :version,
    :token,
    :profile,
    :terminal
  ]
  @terminal_keys [:columns, :rows, :color, :unicode?]
  @terminal_colors [:none, :ansi16, :ansi256, :truecolor]
  @open_close_keys [
    :kind,
    :frame,
    :session_protocol,
    :code,
    :message
  ]
  @envelope_keys [
    :kind,
    :session_protocol,
    :frame,
    :session_id,
    :seq,
    :ack,
    :payload
  ]
  @flow_keys [
    :session_id,
    :outbound_direction,
    :bootstrapped?,
    :next_send_seq,
    :highest_sent_seq,
    :last_received_seq,
    :ack_to_send,
    :last_peer_ack,
    :retained_unacknowledged,
    :retained_unacknowledged_bytes,
    :ack_due?,
    :send_exhausted?,
    :receive_exhausted?
  ]
  @default_max_text_bytes 12_000
  @maximum_max_text_bytes 32_000
  @line_items 256
  @line_bytes 8 * 1_024
  @lines_bytes 48 * 1_024
  @queue_bytes 256 * 1_024
  @daemon_inbound_frames 32
  @daemon_outbound_frames 64
  @unacknowledged_frames 32
  @render_states [:idle, :thinking, :streaming, :confirming, :coding, :background, :error]
  @delta_modes [:append, :replace_live, :clear_live]
  @terminal_outcomes [:completed, :rejected, :failed, :outcome_unknown]
  @error_codes [
    :invalid_input,
    :receipt_conflict,
    :receipt_key_unavailable,
    :confirmation_rejected,
    :runtime_error,
    :outcome_unknown
  ]
  @close_codes [
    :normal,
    :client_detach,
    :daemon_shutdown,
    :protocol_error,
    :frame_too_large,
    :sequence_error,
    :ack_error,
    :overflow,
    :runtime_unavailable
  ]

  @type limits :: %{
          open_body_bytes: 16_384,
          frame_body_bytes: 65_536,
          container_depth: 8,
          map_keys: 32,
          list_items: 256,
          max_sequence: 9_223_372_036_854_775_807,
          default_max_text_bytes: 12_000,
          maximum_max_text_bytes: 32_000,
          daemon_inbound: %{frames: 32, bytes: 262_144},
          daemon_outbound_unsent: %{frames: 64, bytes: 262_144},
          daemon_unacknowledged: %{frames: 32, bytes: 262_144},
          client_outbound_unsent: %{frames: 32, bytes: 262_144},
          client_unacknowledged: %{frames: 32, bytes: 262_144}
        }

  @doc "The additive TUI session protocol version."
  @spec session_protocol() :: 1
  def session_protocol, do: @session_protocol

  @doc "Frozen v1 decode, structure, sequence, and pressure limits."
  @spec limits() :: limits()
  def limits do
    %{
      open_body_bytes: @open_body_bytes,
      frame_body_bytes: @frame_body_bytes,
      container_depth: @container_depth,
      map_keys: @map_keys,
      list_items: @list_items,
      max_sequence: @max_integer,
      default_max_text_bytes: @default_max_text_bytes,
      maximum_max_text_bytes: @maximum_max_text_bytes,
      daemon_inbound: %{frames: @daemon_inbound_frames, bytes: @queue_bytes},
      daemon_outbound_unsent: %{frames: @daemon_outbound_frames, bytes: @queue_bytes},
      daemon_unacknowledged: %{frames: @unacknowledged_frames, bytes: @queue_bytes},
      client_outbound_unsent: %{frames: @unacknowledged_frames, bytes: @queue_bytes},
      client_unacknowledged: %{frames: @unacknowledged_frames, bytes: @queue_bytes}
    }
  end

  @doc "Return a conservative encoded-byte bound for one valid frozen-v1 frame."
  @spec encoded_frame_upper_bound(
          :client_to_daemon | :daemon_to_client,
          atom(),
          map(),
          keyword()
        ) :: {:ok, pos_integer()} | {:error, atom()}
  def encoded_frame_upper_bound(direction, frame, payload, opts \\ [])

  def encoded_frame_upper_bound(direction, frame, %{} = payload, opts)
      when direction in [:client_to_daemon, :daemon_to_client] and is_atom(frame) and
             is_list(opts) do
    envelope = %{
      kind: :tui_session,
      session_protocol: @session_protocol,
      frame: frame,
      session_id: :binary.copy(<<255>>, 32),
      seq: @max_integer,
      ack: @max_integer,
      payload: payload
    }

    with :ok <- validate_frame(direction, envelope, opts),
         {:ok, encoded_bytes} <- encoded_frame_bytes(envelope) do
      {:ok, encoded_bytes}
    end
  end

  def encoded_frame_upper_bound(_direction, _frame, _payload, _opts),
    do: {:error, :protocol_error}

  @doc "The frozen daemon presentation eviction order under outbound pressure."
  @spec pressure_drop_order() :: nonempty_list(:status | :delta)
  def pressure_drop_order, do: [:status, :delta]

  @doc "Generate a cryptographically random v1 session identifier."
  @spec new_session_id() :: <<_::256>>
  def new_session_id, do: :crypto.strong_rand_bytes(32)

  @doc "Generate a canonical receipt id from 16 cryptographically random bytes."
  @spec new_receipt_id() :: String.t()
  def new_receipt_id do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  @doc "Classify an initial Attach request without changing kind-absent behavior."
  @spec classify_kind(map()) :: {:ok, :command | :tui_session} | {:error, :unsupported_kind}
  def classify_kind(%{} = request) do
    case Map.fetch(request, :kind) do
      :error -> {:ok, :command}
      {:ok, :command} -> {:ok, :command}
      {:ok, :tui_session} -> {:ok, :tui_session}
      {:ok, _unsupported} -> {:error, :unsupported_kind}
    end
  end

  def classify_kind(_request), do: {:error, :unsupported_kind}

  @doc "Normalize an untrusted TUI profile selector without resolving identity."
  @spec normalize_profile(term()) :: {:ok, String.t()} | {:error, :invalid_profile}
  def normalize_profile(profile) when is_binary(profile) do
    if String.valid?(profile) do
      normalized = String.trim(profile)
      normalized = if normalized == "", do: "default", else: normalized

      if byte_size(normalized) <= 128,
        do: {:ok, normalized},
        else: {:error, :invalid_profile}
    else
      {:error, :invalid_profile}
    end
  end

  def normalize_profile(_profile), do: {:error, :invalid_profile}

  @doc "Apply the exact `tui-input-v1` receipt/dispatch normalizer."
  @spec normalize_input(term(), pos_integer()) ::
          {:ok, String.t()} | {:error, :invalid_input}
  def normalize_input(input, max_text_bytes)
      when is_binary(input) and is_integer(max_text_bytes) and max_text_bytes >= 1 and
             max_text_bytes <= @maximum_max_text_bytes do
    if String.valid?(input) and byte_size(input) <= max_text_bytes do
      normalized =
        input
        |> String.replace("\r\n", "\n")
        |> String.replace("\r", "\n")
        |> String.trim()

      if normalized != "" and byte_size(normalized) <= max_text_bytes,
        do: {:ok, normalized},
        else: {:error, :invalid_input}
    else
      {:error, :invalid_input}
    end
  end

  def normalize_input(_input, _max_text_bytes), do: {:error, :invalid_input}

  @doc "Build and validate the exact v1 client session-open packet."
  @spec session_open(map(), term(), term()) :: {:ok, map()} | {:error, atom()}
  def session_open(%{} = identity, profile, terminal) do
    with {:ok, normalized_profile} <- normalize_profile(profile) do
      open = %{
        kind: :tui_session,
        frame: :open,
        session_protocol: @session_protocol,
        protocol: Map.get(identity, :protocol),
        home: Map.get(identity, :home),
        uid: Map.get(identity, :uid),
        version: Map.get(identity, :version),
        token: Map.get(identity, :token),
        profile: normalized_profile,
        terminal: terminal
      }

      validate_open(open, identity)
    else
      {:error, :invalid_profile} -> {:error, :invalid_open}
    end
  end

  def session_open(_identity, _profile, _terminal), do: {:error, :invalid_open}

  @doc "Whether a packet uses the ETF COMPRESSED tag."
  @spec compressed_term?(term()) :: boolean()
  def compressed_term?(<<131, 80, _rest::binary>>), do: true
  def compressed_term?(_payload), do: false

  @doc "Decode and validate one uncompressed, bounded v1 session open."
  @spec decode_open(binary(), map()) :: {:ok, map()} | {:error, atom()}
  def decode_open(payload, expected) when is_binary(payload) do
    with :ok <- encoded_body_allowed(payload, @open_body_bytes, :invalid_open),
         {:ok, open} <- safe_session_term(payload, :invalid_open),
         true <- valid_structure?(open) do
      validate_open(open, expected)
    else
      false -> {:error, :invalid_open}
      {:error, reason} -> {:error, reason}
    end
  end

  def decode_open(_payload, _expected), do: {:error, :invalid_open}

  @doc "Validate and normalize the exact v1 TUI session-open map."
  @spec validate_open(map(), map()) :: {:ok, map()} | {:error, atom()}
  def validate_open(%{} = open, %{} = expected) do
    with :ok <- exact_keys(open, @open_keys),
         :ok <- validate_open_shape(open),
         {:ok, profile} <- normalize_profile(open.profile),
         :ok <- validate_open_identity(open, expected) do
      {:ok, %{open | profile: profile}}
    else
      {:error, :invalid_profile} -> {:error, :invalid_open}
      {:error, reason} -> {:error, reason}
    end
  end

  def validate_open(_open, _expected), do: {:error, :invalid_open}

  @doc "Validate one exact direction-specific post-open frame envelope and payload."
  @spec validate_frame(:client_to_daemon | :daemon_to_client, map(), keyword()) ::
          :ok | {:error, atom()}
  def validate_frame(direction, frame, opts \\ [])

  def validate_frame(direction, %{} = frame, opts)
      when direction in [:client_to_daemon, :daemon_to_client] and is_list(opts) do
    with true <- valid_structure?(frame),
         :ok <- exact_keys(frame, @envelope_keys, :protocol_error),
         :ok <- validate_envelope(frame),
         :ok <- validate_payload(direction, frame.frame, frame.payload, opts) do
      :ok
    else
      false -> {:error, :protocol_error}
      {:error, reason} -> {:error, reason}
    end
  end

  def validate_frame(_direction, _frame, _opts), do: {:error, :protocol_error}

  @doc "Decode and validate one uncompressed, bounded post-open session frame."
  @spec decode_frame(binary(), :client_to_daemon | :daemon_to_client, keyword()) ::
          {:ok, map()} | {:error, atom()}
  def decode_frame(payload, direction, opts \\ [])

  def decode_frame(payload, direction, opts) when is_binary(payload) and is_list(opts) do
    with :ok <-
           encoded_body_allowed(
             payload,
             @frame_body_bytes,
             :frame_too_large,
             :protocol_error
           ),
         {:ok, frame} <- safe_session_term(payload, :protocol_error),
         true <- valid_structure?(frame),
         :ok <- validate_frame(direction, frame, opts) do
      {:ok, frame}
    else
      false -> {:error, :protocol_error}
      {:error, reason} -> {:error, reason}
    end
  end

  def decode_frame(_payload, _direction, _opts), do: {:error, :protocol_error}

  @doc "Decode the one bounded response that either rejects or accepts a session open."
  @spec decode_initial_response(binary()) ::
          {:ok, map(), map()}
          | {:error, {:open_rejected, atom(), String.t()} | atom()}
  def decode_initial_response(payload) when is_binary(payload) do
    with :ok <-
           encoded_body_allowed(
             payload,
             @frame_body_bytes,
             :frame_too_large,
             :protocol_error
           ),
         {:ok, response} <- safe_session_term(payload, :protocol_error),
         true <- valid_structure?(response) do
      classify_initial_response(payload, response)
    else
      false -> {:error, :protocol_error}
      {:error, reason} -> {:error, reason}
    end
  end

  def decode_initial_response(_payload), do: {:error, :protocol_error}

  @doc "Create pure directional sequence state for one accepted session id."
  @spec new_flow(binary()) :: {:ok, map()} | {:error, :protocol_error}
  def new_flow(session_id) when is_binary(session_id) and byte_size(session_id) == 32 do
    {:ok,
     %{
       session_id: session_id,
       outbound_direction: nil,
       bootstrapped?: false,
       next_send_seq: 1,
       highest_sent_seq: 0,
       last_received_seq: 0,
       ack_to_send: 0,
       last_peer_ack: 0,
       retained_unacknowledged: %{},
       retained_unacknowledged_bytes: 0,
       ack_due?: false,
       send_exhausted?: false,
       receive_exhausted?: false
     }}
  end

  def new_flow(_session_id), do: {:error, :protocol_error}

  @doc "Build the next outbound frame and advance pure send/ack-window state."
  @spec send_frame(map(), :client_to_daemon | :daemon_to_client, atom(), map(), keyword()) ::
          {:ok, map(), map()} | {:error, atom()}
  def send_frame(flow, direction, frame, payload, opts \\ [])

  def send_frame(%{} = flow, direction, frame, %{} = payload, opts)
      when direction in [:client_to_daemon, :daemon_to_client] and is_list(opts) do
    with :ok <- validate_flow(flow),
         :ok <- send_state_available(flow),
         {:ok, flow} <- bind_outbound(flow, direction),
         :ok <- validate_send_bootstrap(flow, direction, frame),
         envelope <- outbound_envelope(flow, frame, payload),
         :ok <- validate_frame(direction, envelope, opts),
         :ok <- send_sequence_available(flow, direction, frame, payload),
         {:ok, encoded_bytes} <- encoded_frame_bytes(envelope),
         {:ok, retained, retained_bytes} <- retain_outbound(flow, envelope, encoded_bytes) do
      exhausted? = envelope.seq == @max_integer

      next_flow = %{
        flow
        | bootstrapped?: flow.bootstrapped? or frame == :snapshot,
          next_send_seq: if(exhausted?, do: nil, else: envelope.seq + 1),
          highest_sent_seq: envelope.seq,
          retained_unacknowledged: retained,
          retained_unacknowledged_bytes: retained_bytes,
          ack_due?: false,
          send_exhausted?: exhausted?
      }

      {:ok, envelope, next_flow}
    end
  end

  def send_frame(_flow, _direction, _frame, _payload, _opts),
    do: {:error, :protocol_error}

  @doc """
  Deterministically reduces two adjacent same-revision presentation deltas.

  Both inputs and the combined result must satisfy the frozen daemon delta
  schema and bounds. `:no_reduction` tells the queue owner to retain the two
  frames separately; it is not a protocol failure.
  """
  @spec reduce_adjacent_deltas(map(), map()) :: {:ok, map()} | :no_reduction
  def reduce_adjacent_deltas(previous, current)
      when is_map(previous) and is_map(current) do
    with :ok <- validate_payload(:daemon_to_client, :delta, previous, []),
         :ok <- validate_payload(:daemon_to_client, :delta, current, []),
         true <- previous.render_revision == current.render_revision,
         reduced <- reduce_delta_payload(previous, current),
         :ok <- validate_payload(:daemon_to_client, :delta, reduced, []) do
      {:ok, reduced}
    else
      _invalid -> :no_reduction
    end
  end

  def reduce_adjacent_deltas(_previous, _current), do: :no_reduction

  @doc "Validate one inbound frame and atomically advance sequence/cumulative-ack state."
  @spec accept_frame(map(), :client_to_daemon | :daemon_to_client, map(), keyword()) ::
          {:ok, map()} | {:error, atom()}
  def accept_frame(flow, direction, frame, opts \\ [])

  def accept_frame(%{} = flow, direction, %{} = frame, opts)
      when direction in [:client_to_daemon, :daemon_to_client] and is_list(opts) do
    with :ok <- validate_flow(flow),
         {:ok, flow} <- bind_inbound(flow, direction),
         :ok <- validate_transition_schema(flow, direction, frame, opts),
         :ok <- validate_receive_bootstrap(flow, direction, frame),
         :ok <- validate_incoming_sequence(flow, direction, frame),
         :ok <- validate_incoming_ack(flow, frame.ack) do
      retained =
        Map.reject(flow.retained_unacknowledged, fn {seq, _bytes} -> seq <= frame.ack end)

      retained_bytes = retained |> Map.values() |> Enum.sum()

      {:ok,
       %{
         flow
         | bootstrapped?: flow.bootstrapped? or frame.frame == :snapshot,
           last_received_seq: frame.seq,
           ack_to_send: frame.seq,
           last_peer_ack: frame.ack,
           retained_unacknowledged: retained,
           retained_unacknowledged_bytes: retained_bytes,
           ack_due?: flow.ack_due? or frame.frame != :ack,
           receive_exhausted?: frame.seq == @max_integer
       }}
    end
  end

  def accept_frame(_flow, _direction, _frame, _opts),
    do: {:error, :protocol_error}

  @doc "Build the exact bounded close packet used before session acceptance."
  @spec open_close(atom(), term()) :: map()
  def open_close(code, message) when code in @open_close_codes do
    %{
      kind: :tui_session,
      frame: :close,
      session_protocol: @session_protocol,
      code: code,
      message: bounded_message(message, @open_message_bytes, "TUI session rejected.")
    }
  end

  def open_close(_code, _message),
    do: open_close(:invalid_open, "Invalid TUI session open.")

  @doc "Build an allowlisted, redacted, bounded post-open close payload."
  @spec close_payload(atom(), term()) :: map()
  def close_payload(code, message) when code in @close_codes do
    %{code: code, message: bounded_message(message, 1_024, "TUI session closed.")}
  end

  def close_payload(_code, _message),
    do: %{code: :protocol_error, message: "Protocol error."}

  @doc "Build an allowlisted, redacted, bounded post-open error payload."
  @spec error_payload(atom(), term(), term()) :: map()
  def error_payload(code, message, input_receipt_id)
      when code in @error_codes and
             (is_nil(input_receipt_id) or is_binary(input_receipt_id)) do
    if valid_optional_receipt_id?(input_receipt_id) do
      %{
        code: code,
        message: bounded_message(message, 4_096, "Runtime error."),
        input_receipt_id: input_receipt_id
      }
    else
      error_payload(:runtime_error, "Runtime error.", nil)
    end
  end

  def error_payload(_code, _message, _input_receipt_id),
    do: %{code: :runtime_error, message: "Runtime error.", input_receipt_id: nil}

  defp classify_initial_response(_payload, %{frame: :close} = response) do
    with :ok <- validate_open_close(response) do
      {:error, {:open_rejected, response.code, response.message}}
    end
  end

  defp classify_initial_response(payload, %{frame: :snapshot}) do
    opts = [max_text_bytes: @maximum_max_text_bytes]

    with {:ok, frame} <- decode_frame(payload, :daemon_to_client, opts),
         {:ok, flow} <- new_flow(frame.session_id),
         {:ok, accepted_flow} <- accept_frame(flow, :daemon_to_client, frame, opts) do
      {:ok, frame, accepted_flow}
    end
  end

  defp classify_initial_response(_payload, _response), do: {:error, :protocol_error}

  defp validate_open_close(response) do
    with :ok <- exact_keys(response, @open_close_keys, :protocol_error),
         true <- response.kind == :tui_session,
         true <- response.frame == :close,
         true <- response.session_protocol == @session_protocol,
         true <- response.code in @open_close_codes,
         true <- bounded_utf8?(response.message, 0, @open_message_bytes) do
      :ok
    else
      _invalid -> {:error, :protocol_error}
    end
  end

  defp validate_open_shape(open) do
    with :ok <- validate_open_tags(open),
         :ok <- validate_open_identity_shape(open),
         true <- valid_terminal?(open.terminal) do
      :ok
    else
      false -> {:error, :invalid_open}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_open_tags(open) do
    cond do
      open.kind != :tui_session -> {:error, :unsupported_kind}
      open.frame != :open -> {:error, :invalid_open}
      not is_integer(open.session_protocol) -> {:error, :invalid_open}
      not is_integer(open.protocol) -> {:error, :invalid_open}
      true -> :ok
    end
  end

  defp validate_open_identity_shape(open) do
    cond do
      not bounded_utf8?(open.home, 1, 4_096) ->
        {:error, :invalid_open}

      not canonical_home?(open.home) ->
        {:error, :invalid_open}

      not bounded_utf8?(open.uid, 1, 32) ->
        {:error, :invalid_open}

      not bounded_utf8?(open.version, 0, 64) ->
        {:error, :invalid_open}

      not (is_binary(open.token) and byte_size(open.token) == @attach_token_bytes) ->
        {:error, :token_mismatch}

      true ->
        :ok
    end
  end

  defp validate_open_identity(open, expected) do
    cond do
      not expected_identity?(expected) -> {:error, :invalid_open}
      open.session_protocol != @session_protocol -> {:error, :protocol_mismatch}
      open.protocol != expected.protocol -> {:error, :protocol_mismatch}
      not tokens_match?(open.token, expected.token) -> {:error, :token_mismatch}
      open.home != expected.home -> {:error, :home_mismatch}
      open.uid != expected.uid -> {:error, :uid_mismatch}
      open.version != expected.version -> {:error, :version_mismatch}
      true -> :ok
    end
  end

  defp expected_identity?(expected) do
    is_integer(Map.get(expected, :protocol)) and
      is_binary(Map.get(expected, :home)) and
      is_binary(Map.get(expected, :uid)) and
      is_binary(Map.get(expected, :version)) and
      is_binary(Map.get(expected, :token)) and
      byte_size(expected.token) == @attach_token_bytes
  end

  defp valid_terminal?(%{} = terminal) do
    exact_keys(terminal, @terminal_keys) == :ok and
      integer_in?(terminal.columns, 1, 500) and
      integer_in?(terminal.rows, 1, 200) and
      terminal.color in @terminal_colors and
      is_boolean(terminal.unicode?)
  end

  defp valid_terminal?(_terminal), do: false

  defp exact_keys(map, expected, error_code \\ :invalid_open) do
    if map_size(map) == length(expected) and Enum.all?(expected, &Map.has_key?(map, &1)),
      do: :ok,
      else: {:error, error_code}
  end

  defp integer_in?(value, minimum, maximum),
    do: is_integer(value) and value >= minimum and value <= maximum

  defp bounded_utf8?(value, minimum, maximum) do
    is_binary(value) and String.valid?(value) and
      byte_size(value) >= minimum and byte_size(value) <= maximum
  end

  defp canonical_home?(home) do
    Path.expand(home) == home
  rescue
    _error -> false
  end

  defp tokens_match?(candidate, expected)
       when is_binary(candidate) and is_binary(expected) and
              byte_size(candidate) == byte_size(expected) do
    Plug.Crypto.secure_compare(candidate, expected)
  end

  defp tokens_match?(_candidate, _expected), do: false

  defp validate_flow(flow) do
    with :ok <- exact_keys(flow, @flow_keys, :protocol_error),
         true <- valid_flow_identity?(flow),
         true <- valid_flow_flags?(flow),
         true <- valid_send_position?(flow),
         true <- valid_receive_position?(flow),
         true <- valid_peer_ack_position?(flow),
         true <- valid_retained_window?(flow) do
      :ok
    else
      false -> {:error, :protocol_error}
      {:error, reason} -> {:error, reason}
    end
  end

  defp valid_flow_identity?(flow) do
    is_binary(flow.session_id) and byte_size(flow.session_id) == 32 and
      flow.outbound_direction in [nil, :client_to_daemon, :daemon_to_client] and
      (not flow.bootstrapped? or not is_nil(flow.outbound_direction))
  end

  defp valid_flow_flags?(flow) do
    is_boolean(flow.bootstrapped?) and is_boolean(flow.ack_due?) and
      is_boolean(flow.send_exhausted?) and is_boolean(flow.receive_exhausted?)
  end

  defp valid_send_position?(%{send_exhausted?: true} = flow) do
    is_nil(flow.next_send_seq) and flow.highest_sent_seq == @max_integer
  end

  defp valid_send_position?(%{send_exhausted?: false} = flow) do
    integer_in?(flow.highest_sent_seq, 0, @max_integer - 1) and
      flow.next_send_seq == flow.highest_sent_seq + 1
  end

  defp valid_send_position?(_flow), do: false

  defp valid_receive_position?(flow) do
    integer_in?(flow.last_received_seq, 0, @max_integer) and
      flow.ack_to_send == flow.last_received_seq and
      flow.receive_exhausted? == (flow.last_received_seq == @max_integer)
  end

  defp valid_peer_ack_position?(flow) do
    integer_in?(flow.last_peer_ack, 0, @max_integer) and
      flow.last_peer_ack <= flow.highest_sent_seq
  end

  defp valid_retained_window?(flow) when is_map(flow.retained_unacknowledged) do
    if Enum.all?(flow.retained_unacknowledged, &valid_retained_entry?(&1, flow)) do
      retained_bytes = flow.retained_unacknowledged |> Map.values() |> Enum.sum()

      map_size(flow.retained_unacknowledged) <= @unacknowledged_frames and
        retained_bytes == flow.retained_unacknowledged_bytes and
        retained_bytes <= @queue_bytes
    else
      false
    end
  end

  defp valid_retained_window?(_flow), do: false

  defp valid_retained_entry?({seq, bytes}, flow) do
    integer_in?(seq, flow.last_peer_ack + 1, flow.highest_sent_seq) and
      is_integer(bytes) and bytes > 0
  end

  defp bind_outbound(%{outbound_direction: nil} = flow, direction),
    do: {:ok, %{flow | outbound_direction: direction}}

  defp bind_outbound(%{outbound_direction: direction} = flow, direction), do: {:ok, flow}
  defp bind_outbound(_flow, _direction), do: {:error, :protocol_error}

  defp bind_inbound(%{outbound_direction: nil} = flow, direction),
    do: {:ok, %{flow | outbound_direction: opposite_direction(direction)}}

  defp bind_inbound(%{outbound_direction: outbound} = flow, direction) do
    if opposite_direction(direction) == outbound,
      do: {:ok, flow},
      else: {:error, :protocol_error}
  end

  defp opposite_direction(:client_to_daemon), do: :daemon_to_client
  defp opposite_direction(:daemon_to_client), do: :client_to_daemon

  defp validate_send_bootstrap(%{bootstrapped?: false}, :daemon_to_client, :snapshot), do: :ok

  defp validate_send_bootstrap(%{bootstrapped?: false}, _direction, _frame),
    do: {:error, :protocol_error}

  defp validate_send_bootstrap(_flow, _direction, _frame), do: :ok

  defp validate_receive_bootstrap(
         %{bootstrapped?: false},
         :daemon_to_client,
         %{frame: :snapshot, seq: 1, ack: 0}
       ),
       do: :ok

  defp validate_receive_bootstrap(%{bootstrapped?: false}, _direction, _frame),
    do: {:error, :protocol_error}

  defp validate_receive_bootstrap(_flow, _direction, _frame), do: :ok

  defp send_state_available(%{send_exhausted?: true}), do: {:error, :sequence_error}
  defp send_state_available(_flow), do: :ok

  defp send_sequence_available(
         %{next_send_seq: @max_integer},
         :daemon_to_client,
         :close,
         %{code: :sequence_error}
       ),
       do: :ok

  defp send_sequence_available(%{next_send_seq: @max_integer}, _direction, _frame, _payload),
    do: {:error, :sequence_error}

  defp send_sequence_available(_flow, _direction, _frame, _payload), do: :ok

  defp outbound_envelope(flow, frame, payload) do
    %{
      kind: :tui_session,
      session_protocol: @session_protocol,
      frame: frame,
      session_id: flow.session_id,
      seq: flow.next_send_seq,
      ack: flow.ack_to_send,
      payload: payload
    }
  end

  defp encoded_frame_bytes(frame) do
    encoded_bytes = frame |> :erlang.term_to_binary() |> byte_size()

    if encoded_bytes <= @frame_body_bytes,
      do: {:ok, encoded_bytes},
      else: {:error, :frame_too_large}
  rescue
    _error -> {:error, :protocol_error}
  end

  defp retain_outbound(flow, %{frame: :ack}, _encoded_bytes) do
    {:ok, flow.retained_unacknowledged, flow.retained_unacknowledged_bytes}
  end

  defp retain_outbound(flow, frame, encoded_bytes) do
    retained = Map.put(flow.retained_unacknowledged, frame.seq, encoded_bytes)
    retained_bytes = flow.retained_unacknowledged_bytes + encoded_bytes

    if map_size(retained) <= @unacknowledged_frames and retained_bytes <= @queue_bytes,
      do: {:ok, retained, retained_bytes},
      else: {:error, :overflow}
  end

  defp reduce_delta_payload(previous, %{mode: :append, lines: lines}) do
    case previous.mode do
      :append -> %{previous | lines: previous.lines ++ lines}
      :replace_live -> %{previous | lines: previous.lines ++ lines}
      :clear_live -> %{previous | mode: :replace_live, lines: lines}
    end
  end

  defp reduce_delta_payload(previous, %{mode: :replace_live, lines: lines}),
    do: %{previous | mode: :replace_live, lines: lines}

  defp reduce_delta_payload(previous, %{mode: :clear_live}),
    do: %{previous | mode: :clear_live, lines: []}

  defp validate_transition_schema(flow, direction, frame, opts) do
    with true <- is_integer(Map.get(frame, :seq)) and is_integer(Map.get(frame, :ack)),
         normalized = %{frame | seq: 1, ack: 0},
         :ok <- validate_frame(direction, normalized, opts),
         true <- frame.session_id == flow.session_id,
         {:ok, _encoded_bytes} <- encoded_frame_bytes(frame) do
      :ok
    else
      false -> {:error, :protocol_error}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_incoming_sequence(%{receive_exhausted?: true}, _direction, _frame),
    do: {:error, :sequence_error}

  defp validate_incoming_sequence(flow, direction, frame) do
    expected = flow.last_received_seq + 1

    cond do
      not integer_in?(frame.seq, 1, @max_integer) or frame.seq != expected ->
        {:error, :sequence_error}

      frame.seq < @max_integer ->
        :ok

      direction == :daemon_to_client and frame.frame == :close and
          frame.payload.code == :sequence_error ->
        :ok

      true ->
        {:error, :sequence_error}
    end
  end

  defp validate_incoming_ack(flow, ack) do
    if integer_in?(ack, 0, @max_integer) and
         ack >= flow.last_peer_ack and ack <= flow.highest_sent_seq,
       do: :ok,
       else: {:error, :ack_error}
  end

  defp validate_envelope(frame) do
    with true <- valid_envelope_identity?(frame),
         true <- valid_envelope_counters?(frame),
         true <- is_atom(frame.frame) and is_map(frame.payload) do
      :ok
    else
      false -> {:error, :protocol_error}
    end
  end

  defp valid_envelope_identity?(frame) do
    frame.kind == :tui_session and frame.session_protocol == @session_protocol and
      is_binary(frame.session_id) and byte_size(frame.session_id) == 32
  end

  defp valid_envelope_counters?(frame) do
    integer_in?(frame.seq, 1, @max_integer) and integer_in?(frame.ack, 0, @max_integer)
  end

  defp validate_payload(:client_to_daemon, :input, payload, opts) do
    with :ok <- exact_payload_keys(payload, [:input_receipt_id, :text]),
         true <- valid_receipt_id?(payload.input_receipt_id),
         true <- bounded_utf8?(payload.text, 0, input_bytes(opts)) do
      :ok
    else
      _invalid -> {:error, :protocol_error}
    end
  end

  defp validate_payload(:client_to_daemon, :resize, payload, _opts) do
    with :ok <- exact_payload_keys(payload, [:columns, :rows]),
         true <- integer_in?(payload.columns, 1, 500),
         true <- integer_in?(payload.rows, 1, 200) do
      :ok
    else
      _invalid -> {:error, :protocol_error}
    end
  end

  defp validate_payload(:client_to_daemon, :cancel, payload, _opts) do
    with :ok <- exact_payload_keys(payload, [:reason]),
         true <- payload.reason in [:operator_escape, :operator_interrupt] do
      :ok
    else
      _invalid -> {:error, :protocol_error}
    end
  end

  defp validate_payload(:client_to_daemon, :confirmation, payload, _opts) do
    with :ok <- exact_payload_keys(payload, [:confirmation_id, :decision]),
         true <- bounded_utf8?(payload.confirmation_id, 1, 128),
         true <- payload.decision in [:approve, :deny] do
      :ok
    else
      _invalid -> {:error, :protocol_error}
    end
  end

  defp validate_payload(:client_to_daemon, :ack, payload, _opts) do
    if map_size(payload) == 0, do: :ok, else: {:error, :protocol_error}
  end

  defp validate_payload(:client_to_daemon, :detach, payload, _opts) do
    with :ok <- exact_payload_keys(payload, [:reason]),
         true <- payload.reason in [:operator_exit, :eof] do
      :ok
    else
      _invalid -> {:error, :protocol_error}
    end
  end

  defp validate_payload(:daemon_to_client, :snapshot, payload, _opts) do
    with :ok <- exact_payload_keys(payload, [:render_revision, :state, :lines, :gap?]),
         true <- integer_in?(payload.render_revision, 0, @max_integer),
         true <- payload.state in @render_states,
         true <- valid_lines?(payload.lines),
         true <- is_boolean(payload.gap?) do
      :ok
    else
      _invalid -> {:error, :protocol_error}
    end
  end

  defp validate_payload(:daemon_to_client, :delta, payload, _opts) do
    with :ok <- exact_payload_keys(payload, [:render_revision, :mode, :lines]),
         true <- integer_in?(payload.render_revision, 1, @max_integer),
         true <- payload.mode in @delta_modes,
         true <- payload.mode != :clear_live or payload.lines == [],
         true <- valid_lines?(payload.lines) do
      :ok
    else
      _invalid -> {:error, :protocol_error}
    end
  end

  defp validate_payload(:daemon_to_client, :status, payload, _opts) do
    with :ok <-
           exact_payload_keys(payload, [
             :render_revision,
             :state,
             :text,
             :input_receipt_id
           ]),
         true <- integer_in?(payload.render_revision, 0, @max_integer),
         true <- payload.state in @render_states,
         true <- bounded_utf8?(payload.text, 0, 4_096),
         true <- valid_optional_receipt_id?(payload.input_receipt_id) do
      :ok
    else
      _invalid -> {:error, :protocol_error}
    end
  end

  defp validate_payload(:daemon_to_client, :confirmation, payload, _opts) do
    with :ok <- exact_payload_keys(payload, [:confirmation_id, :prompt, :expires_at_unix_ms]),
         true <- bounded_utf8?(payload.confirmation_id, 1, 128),
         true <- bounded_utf8?(payload.prompt, 0, 12 * 1_024),
         true <- integer_in?(payload.expires_at_unix_ms, 0, @max_integer) do
      :ok
    else
      _invalid -> {:error, :protocol_error}
    end
  end

  defp validate_payload(:daemon_to_client, :completion, payload, _opts) do
    with :ok <-
           exact_payload_keys(payload, [
             :input_receipt_id,
             :outcome,
             :duplicate?,
             :result_ref,
             :lines
           ]),
         true <- valid_receipt_id?(payload.input_receipt_id),
         true <- payload.outcome in @terminal_outcomes,
         true <- is_boolean(payload.duplicate?),
         true <- valid_result_ref?(payload.result_ref),
         true <- valid_lines?(payload.lines) do
      :ok
    else
      _invalid -> {:error, :protocol_error}
    end
  end

  defp validate_payload(:daemon_to_client, :error, payload, _opts) do
    with :ok <- exact_payload_keys(payload, [:code, :message, :input_receipt_id]),
         true <- payload.code in @error_codes,
         true <- bounded_utf8?(payload.message, 0, 4_096),
         true <- valid_optional_receipt_id?(payload.input_receipt_id) do
      :ok
    else
      _invalid -> {:error, :protocol_error}
    end
  end

  defp validate_payload(:daemon_to_client, :close, payload, _opts) do
    with :ok <- exact_payload_keys(payload, [:code, :message]),
         true <- payload.code in @close_codes,
         true <- bounded_utf8?(payload.message, 0, 1_024) do
      :ok
    else
      _invalid -> {:error, :protocol_error}
    end
  end

  defp validate_payload(_direction, _frame, _payload, _opts),
    do: {:error, :protocol_error}

  defp exact_payload_keys(payload, keys) do
    exact_keys(payload, keys, :protocol_error)
  end

  defp input_bytes(opts) do
    case Keyword.get(opts, :max_text_bytes, @default_max_text_bytes) do
      value when is_integer(value) and value >= 1 and value <= @maximum_max_text_bytes -> value
      _invalid -> @default_max_text_bytes
    end
  end

  defp valid_receipt_id?(receipt_id) when is_binary(receipt_id) and byte_size(receipt_id) == 22 do
    case Base.url_decode64(receipt_id, padding: false) do
      {:ok, decoded} ->
        byte_size(decoded) == 16 and
          Base.url_encode64(decoded, padding: false) == receipt_id

      :error ->
        false
    end
  end

  defp valid_receipt_id?(_receipt_id), do: false

  defp valid_optional_receipt_id?(nil), do: true
  defp valid_optional_receipt_id?(receipt_id), do: valid_receipt_id?(receipt_id)

  defp valid_result_ref?(nil), do: true
  defp valid_result_ref?(result_ref), do: bounded_utf8?(result_ref, 0, 256)

  defp valid_lines?(lines) when is_list(lines), do: valid_lines?(lines, 0, 0)
  defp valid_lines?(_lines), do: false

  defp valid_lines?([], _count, _bytes), do: true
  defp valid_lines?(_lines, count, _bytes) when count >= @line_items, do: false

  defp valid_lines?([line | rest], count, bytes) do
    if bounded_utf8?(line, 0, @line_bytes) and bytes + byte_size(line) <= @lines_bytes do
      valid_lines?(rest, count + 1, bytes + byte_size(line))
    else
      false
    end
  end

  defp valid_lines?(_improper, _count, _bytes), do: false

  defp encoded_body_allowed(payload, max_bytes, oversized_code, compressed_code \\ :invalid_open) do
    cond do
      byte_size(payload) > max_bytes -> {:error, oversized_code}
      compressed_term?(payload) -> {:error, compressed_code}
      true -> :ok
    end
  end

  defp safe_session_term(payload, error_code) do
    {:ok, :erlang.binary_to_term(payload, [:safe])}
  rescue
    _error -> {:error, error_code}
  end

  defp valid_structure?(term), do: valid_structure?(term, 0)

  defp valid_structure?(term, depth) when is_map(term) do
    depth < @container_depth and map_size(term) <= @map_keys and
      Enum.all?(term, fn {key, value} ->
        valid_structure?(key, depth + 1) and valid_structure?(value, depth + 1)
      end)
  end

  defp valid_structure?(term, depth) when is_list(term) do
    depth < @container_depth and valid_list?(term, depth + 1, 0)
  end

  defp valid_structure?(term, _depth)
       when is_atom(term) or is_binary(term) or is_integer(term),
       do: true

  defp valid_structure?(_term, _depth), do: false

  defp valid_list?([], _depth, _count), do: true
  defp valid_list?(_list, _depth, count) when count >= @list_items, do: false

  defp valid_list?([head | tail], depth, count) do
    valid_structure?(head, depth) and valid_list?(tail, depth, count + 1)
  end

  defp valid_list?(_improper_tail, _depth, _count), do: false

  defp bounded_message(message, max_bytes, fallback) when is_binary(message) do
    redacted = Redactor.redact(message, :logs)

    cond do
      not is_binary(redacted) -> fallback
      not String.valid?(redacted) -> fallback
      byte_size(redacted) <= max_bytes -> redacted
      true -> take_utf8(redacted, max_bytes, [])
    end
  end

  defp bounded_message(_message, _max_bytes, fallback), do: fallback

  defp take_utf8(_rest, remaining, acc) when remaining <= 0,
    do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp take_utf8(<<>>, _remaining, acc),
    do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp take_utf8(<<codepoint::utf8, rest::binary>>, remaining, acc) do
    encoded = <<codepoint::utf8>>

    if byte_size(encoded) <= remaining do
      take_utf8(rest, remaining - byte_size(encoded), [encoded | acc])
    else
      take_utf8(<<>>, 0, acc)
    end
  end
end
