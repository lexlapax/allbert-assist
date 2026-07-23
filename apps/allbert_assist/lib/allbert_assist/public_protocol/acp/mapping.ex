defmodule AllbertAssist.PublicProtocol.Acp.Mapping do
  @moduledoc """
  Bounded ACP v1 mapping for the v0.51 stdio public protocol surface.

  The implementation is intentionally text-only. ACP client metadata and
  permission responses are not Allbert authority.
  """

  alias AllbertAssist.App.CoreApp
  alias AllbertAssist.PublicProtocol.ResultReadback
  alias AllbertAssist.Runtime
  alias AllbertAssist.Runtime.Response
  alias AllbertAssist.Settings
  alias AllbertAssist.Surface.Renderer, as: SurfaceRenderer

  @surface "acp_stdio"
  @protocol_version 1
  @default_client_id "stdio-client"

  @type session :: %{
          required(:id) => String.t(),
          required(:client_id) => String.t(),
          optional(:cwd) => String.t() | nil
        }

  @type error :: %{
          required(:code) => integer(),
          required(:message) => String.t(),
          optional(:data) => map()
        }

  @spec protocol_version() :: 1
  def protocol_version, do: @protocol_version

  @spec surface() :: String.t()
  def surface, do: @surface

  @spec default_client_id() :: String.t()
  def default_client_id, do: @default_client_id

  @spec surface_enabled?() :: boolean()
  def surface_enabled? do
    enabled?("acp_server.enabled") and enabled?("acp_server.stdio.enabled")
  end

  @spec initialize_result(map()) :: map()
  def initialize_result(params) when is_map(params) do
    %{
      "protocolVersion" => chosen_protocol_version(Map.get(params, "protocolVersion")),
      "agentCapabilities" => %{
        "promptCapabilities" => %{},
        "sessionCapabilities" => %{}
      },
      "agentInfo" => %{
        "name" => "allbert-assist",
        "title" => "Allbert Assist",
        "version" => CoreApp.version()
      },
      "authMethods" => []
    }
  end

  def initialize_result(_params), do: initialize_result(%{})

  @spec client_id(map()) :: String.t()
  def client_id(%{"clientInfo" => %{"name" => name}}) when is_binary(name) and name != "",
    do: String.slice(name, 0, 128)

  def client_id(%{"clientInfo" => %{"title" => title}}) when is_binary(title) and title != "",
    do: String.slice(title, 0, 128)

  def client_id(_params), do: @default_client_id

  @spec validate_session_params(map()) :: {:ok, map()} | {:error, error()}
  def validate_session_params(params) when is_map(params) do
    cond do
      non_empty?(Map.get(params, "mcpServers")) ->
        {:error,
         invalid_params(
           "Client-supplied mcpServers are not supported by the v0.51 ACP surface.",
           "mcpservers_no_authority",
           "mcpServers"
         )}

      non_empty?(Map.get(params, "additionalDirectories")) ->
        {:error,
         invalid_params(
           "Client-supplied additionalDirectories are not supported by the v0.51 ACP surface.",
           "additional_directories_no_authority",
           "additionalDirectories"
         )}

      present?(Map.get(params, "permissionMode")) ->
        {:error,
         invalid_params(
           "Client-supplied permissionMode is advisory metadata and is not supported by the v0.51 ACP surface.",
           "permission_mode_no_authority",
           "permissionMode"
         )}

      true ->
        {:ok, %{cwd: optional_string(Map.get(params, "cwd"))}}
    end
  end

  def validate_session_params(_params),
    do: {:error, invalid_params("session/new params must be an object.", "invalid_params", nil)}

  @spec flatten_prompt(map()) :: {:ok, String.t()} | {:error, error()}
  def flatten_prompt(%{"prompt" => prompt}) when is_list(prompt) and prompt != [] do
    prompt
    |> Enum.reduce_while({:ok, []}, fn block, {:ok, lines} ->
      case text_block(block) do
        {:ok, text} -> {:cont, {:ok, [text | lines]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, lines} -> {:ok, lines |> Enum.reverse() |> Enum.join("\n")}
      {:error, error} -> {:error, error}
    end
  end

  def flatten_prompt(%{"prompt" => _prompt}),
    do:
      {:error,
       invalid_params(
         "prompt must be a non-empty text content array.",
         "invalid_prompt",
         "prompt"
       )}

  def flatten_prompt(_params),
    do: {:error, invalid_params("session/prompt requires prompt.", "missing_prompt", "prompt")}

  @spec runtime_request(String.t(), session()) :: map()
  def runtime_request(text, session) when is_binary(text) and is_map(session) do
    user_id = "public-protocol:#{Map.fetch!(session, :client_id)}"

    %{
      text: text,
      delivery_ack_capability: Runtime.fanout_delivery_ack_capability(),
      channel: :acp_stdio,
      user_id: user_id,
      operator_id: user_id,
      session_id: Map.fetch!(session, :id),
      metadata: %{
        public_protocol: %{
          surface: @surface,
          client_id: Map.fetch!(session, :client_id)
        },
        acp: %{
          session_id: Map.fetch!(session, :id),
          cwd: Map.get(session, :cwd)
        }
      }
    }
  end

  @spec prompt_outbound(map(), session(), term()) :: {:ok, [map()]} | {:error, error()}
  def prompt_outbound(runtime_response, session, request_id) when is_map(runtime_response) do
    case Response.status(runtime_response) do
      :needs_confirmation ->
        pending_prompt_outbound(runtime_response, session, request_id)

      :denied ->
        {:error, authorization_error(Map.get(runtime_response, :message, "Request was denied."))}

      status when status in [:error, :failed, :unsupported, :unavailable] ->
        {:error,
         runtime_error(Map.get(runtime_response, :message, "Allbert runtime returned #{status}."))}

      _status ->
        {:ok,
         [
           agent_message_chunk(
             Map.fetch!(session, :id),
             SurfaceRenderer.response_text(runtime_response, %{payload: :message})
           ),
           prompt_response(request_id, %{"stopReason" => "end_turn"})
         ]}
    end
  end

  def prompt_outbound(_runtime_response, _session, _request_id),
    do: {:error, runtime_error("Allbert runtime returned an invalid response.")}

  @spec advisory_permission_error() :: error()
  def advisory_permission_error do
    method_not_found(
      "session/request_permission is a client-side ACP method. ACP permission responses are advisory and never authorize Allbert execution.",
      "client_permission_not_authority"
    )
  end

  @spec surface_disabled_error() :: error()
  def surface_disabled_error,
    do: server_error("ACP stdio surface is disabled.", "surface_disabled")

  @spec not_initialized_error() :: error()
  def not_initialized_error,
    do: server_error("ACP connection has not been initialized.", "not_initialized")

  @spec unknown_session_error() :: error()
  def unknown_session_error,
    do: invalid_params("Unknown ACP session.", "unknown_session", "sessionId")

  @spec invalid_params(String.t(), String.t(), String.t() | nil) :: error()
  def invalid_params(message, code, param) do
    %{
      code: -32_602,
      message: message,
      data: compact_data(%{"code" => code, "param" => param})
    }
  end

  @spec parse_error(String.t()) :: error()
  def parse_error(message),
    do: %{code: -32_700, message: message, data: %{"code" => "parse_error"}}

  @spec invalid_request(String.t()) :: error()
  def invalid_request(message),
    do: %{code: -32_600, message: message, data: %{"code" => "invalid_request"}}

  @spec method_not_found(String.t(), String.t()) :: error()
  def method_not_found(message, code),
    do: %{code: -32_601, message: message, data: %{"code" => code}}

  defp pending_prompt_outbound(runtime_response, session, request_id) do
    attrs = %{
      surface: @surface,
      client_id: Map.fetch!(session, :client_id),
      turn_label: "session/prompt",
      confirmation_id: confirmation_id(runtime_response),
      trace_id: Map.get(runtime_response, :trace_id),
      trace_metadata: %{status: "confirmation_pending"}
    }

    with {:ok, readback} <- ResultReadback.create(attrs) do
      pending_text =
        Map.get(
          runtime_response,
          :message,
          "Allbert operator confirmation is required before this result is available."
        )

      {:ok,
       [
         agent_message_chunk(Map.fetch!(session, :id), pending_text),
         advisory_permission_request(Map.fetch!(session, :id), readback.id),
         prompt_response(request_id, %{
           "stopReason" => "end_turn",
           "allbertStatus" => "confirmation_pending",
           "allbertPublicCallId" => readback.id
         })
       ]}
    else
      {:error, reason} ->
        {:error, runtime_error("Could not create public readback record: #{inspect(reason)}.")}
    end
  end

  defp prompt_response(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  defp agent_message_chunk(session_id, text) do
    %{
      "jsonrpc" => "2.0",
      "method" => "session/update",
      "params" => %{
        "sessionId" => session_id,
        "update" => %{
          "sessionUpdate" => "agent_message_chunk",
          "messageId" => "msg_" <> Ecto.UUID.generate(),
          "content" => %{"type" => "text", "text" => to_string(text)}
        }
      }
    }
  end

  defp advisory_permission_request(session_id, public_call_id) do
    %{
      "jsonrpc" => "2.0",
      "id" => "acp_perm_" <> Ecto.UUID.generate(),
      "method" => "session/request_permission",
      "params" => %{
        "sessionId" => session_id,
        "toolCall" => %{
          "toolCallId" => public_call_id,
          "title" => "Allbert operator confirmation required",
          "kind" => "other",
          "status" => "pending"
        },
        "options" => [
          %{"optionId" => "acknowledge", "name" => "Acknowledge", "kind" => "allow_once"},
          %{"optionId" => "dismiss", "name" => "Dismiss", "kind" => "reject_once"}
        ],
        "_meta" => %{
          "allbertPublicCallId" => public_call_id,
          "allbertAuthority" => "operator_confirmation_required"
        }
      }
    }
  end

  defp text_block(%{"type" => "text", "text" => text}) when is_binary(text) do
    case String.trim(text) do
      "" -> {:error, invalid_params("text content must not be empty.", "empty_text", "prompt")}
      trimmed -> {:ok, trimmed}
    end
  end

  defp text_block(%{"type" => type}) when is_binary(type) do
    {:error,
     invalid_params(
       "Unsupported ACP content block type: #{type}.",
       "unsupported_content_block",
       "prompt"
     )}
  end

  defp text_block(_block),
    do: {:error, invalid_params("Invalid ACP content block.", "invalid_content_block", "prompt")}

  defp chosen_protocol_version(@protocol_version), do: @protocol_version
  defp chosen_protocol_version(_version), do: @protocol_version

  defp enabled?(key) do
    case Settings.get(key) do
      {:ok, true} -> true
      _other -> false
    end
  end

  defp non_empty?(value) when is_list(value), do: value != []
  defp non_empty?(nil), do: false
  defp non_empty?(_value), do: true

  defp present?(nil), do: false
  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: true

  defp optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp optional_string(_value), do: nil

  defp confirmation_id(response) do
    response
    |> Map.get(:approval_handoff, Map.get(response, "approval_handoff", %{}))
    |> case do
      %{confirmation_id: id} when is_binary(id) -> id
      %{"confirmation_id" => id} when is_binary(id) -> id
      _handoff -> nil
    end
  end

  defp authorization_error(message), do: server_error(message, "authorization_error")
  defp runtime_error(message), do: server_error(message, "runtime_error")

  defp server_error(message, code) do
    %{
      code: -32_000,
      message: message,
      data: %{"code" => code}
    }
  end

  defp compact_data(data), do: Map.reject(data, fn {_key, value} -> is_nil(value) end)
end
