defmodule AllbertAssist.PublicProtocol.Acp.Server do
  @moduledoc """
  Minimal ACP v1 stdio JSON-RPC server for v0.51.

  The server owns only process-local protocol session state. Durable work and
  authority continue to flow through Allbert runtime, Security Central, and
  public protocol readback.
  """

  alias AllbertAssist.PublicProtocol.Acp.Mapping
  alias AllbertAssist.Runtime

  defstruct initialized?: false,
            client_id: Mapping.default_client_id(),
            sessions: %{}

  @type state :: %__MODULE__{
          initialized?: boolean(),
          client_id: String.t(),
          sessions: map()
        }

  @spec new_state() :: state()
  def new_state, do: %__MODULE__{}

  @spec handle_line(String.t(), state()) :: {:ok, [String.t()], state()}
  def handle_line(line, %__MODULE__{} = state) when is_binary(line) do
    case Jason.decode(String.trim_trailing(line)) do
      {:ok, message} ->
        with {:ok, outbound, state} <- handle_message(message, state) do
          {:ok, Enum.map(outbound, &encode_line/1), state}
        end

      {:error, _reason} ->
        {:ok,
         [encode_line(error_response(nil, Mapping.parse_error("Invalid JSON-RPC message.")))],
         state}
    end
  end

  @spec handle_message(map(), state()) :: {:ok, [map()], state()}
  def handle_message(%{"method" => method} = message, %__MODULE__{} = state)
      when is_binary(method) do
    request_id = Map.get(message, "id")
    params = Map.get(message, "params", %{})

    case dispatch(method, params, request_id, state) do
      {:ok, outbound, state} when is_nil(request_id) ->
        {:ok, Enum.reject(outbound, &response?/1), state}

      {:ok, outbound, state} ->
        {:ok, outbound, state}

      {:error, _error, state} when is_nil(request_id) ->
        {:ok, [], state}

      {:error, error, state} ->
        {:ok, [error_response(request_id, error)], state}
    end
  end

  def handle_message(%{"id" => _id} = message, %__MODULE__{} = state)
      when is_map_key(message, "result") or is_map_key(message, "error") do
    {:ok, [], state}
  end

  def handle_message(_message, %__MODULE__{} = state) do
    {:ok,
     [error_response(nil, Mapping.invalid_request("JSON-RPC request must include a method."))],
     state}
  end

  @spec serve_stdio() :: no_return()
  def serve_stdio do
    _final_state =
      IO.stream(:stdio, :line)
      |> Enum.reduce(new_state(), fn line, state ->
        {:ok, outbound, state} = handle_line(line, state)
        Enum.each(outbound, &IO.write(:stdio, &1))
        state
      end)

    Process.sleep(:infinity)
  end

  defp dispatch("initialize", params, request_id, state) do
    client_id = Mapping.client_id(params)
    state = %{state | initialized?: true, client_id: client_id}

    {:ok, [success_response(request_id, Mapping.initialize_result(params))], state}
  end

  defp dispatch("session/new", params, request_id, state) do
    with :ok <- ensure_initialized(state),
         :ok <- ensure_surface_enabled(),
         {:ok, session_attrs} <- Mapping.validate_session_params(params) do
      session = %{
        id: "acp_sess_" <> Ecto.UUID.generate(),
        client_id: state.client_id,
        cwd: Map.get(session_attrs, :cwd)
      }

      state = put_in(state.sessions[session.id], session)

      {:ok, [success_response(request_id, %{"sessionId" => session.id})], state}
    else
      {:error, error} -> {:error, error, state}
    end
  end

  defp dispatch("session/prompt", params, request_id, state) do
    with :ok <- ensure_initialized(state),
         :ok <- ensure_surface_enabled(),
         {:ok, session} <- fetch_session(params, state),
         {:ok, text} <- Mapping.flatten_prompt(params),
         {:ok, runtime_response} <-
           Runtime.submit_user_input(Mapping.runtime_request(text, session)),
         {:ok, outbound} <- Mapping.prompt_outbound(runtime_response, session, request_id) do
      {:ok, outbound, state}
    else
      {:error, %{} = error} ->
        {:error, error, state}

      {:error, reason} ->
        {:error,
         Mapping.invalid_params("ACP prompt failed: #{inspect(reason)}.", "runtime_error", nil),
         state}
    end
  end

  defp dispatch("session/cancel", _params, request_id, state) do
    if is_nil(request_id) do
      {:ok, [], state}
    else
      {:ok, [success_response(request_id, %{"stopReason" => "cancelled"})], state}
    end
  end

  defp dispatch("session/request_permission", _params, _request_id, state) do
    {:error, Mapping.advisory_permission_error(), state}
  end

  defp dispatch(method, _params, _request_id, state) do
    {:error, Mapping.method_not_found("Unsupported ACP method: #{method}.", "unsupported_method"),
     state}
  end

  defp ensure_initialized(%{initialized?: true}), do: :ok
  defp ensure_initialized(_state), do: {:error, Mapping.not_initialized_error()}

  defp ensure_surface_enabled do
    if Mapping.surface_enabled?(), do: :ok, else: {:error, Mapping.surface_disabled_error()}
  end

  defp fetch_session(%{"sessionId" => session_id}, state) when is_binary(session_id) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, session} -> {:ok, session}
      :error -> {:error, Mapping.unknown_session_error()}
    end
  end

  defp fetch_session(_params, _state),
    do:
      {:error,
       Mapping.invalid_params("sessionId is required.", "missing_session_id", "sessionId")}

  defp success_response(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  defp error_response(id, error) do
    body = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{
        "code" => error.code,
        "message" => error.message
      }
    }

    case Map.get(error, :data) do
      data when is_map(data) and map_size(data) > 0 -> put_in(body, ["error", "data"], data)
      _data -> body
    end
  end

  defp response?(%{"id" => _id}), do: true
  defp response?(_message), do: false

  defp encode_line(message), do: Jason.encode!(message) <> "\n"
end
