defmodule AllbertAssist.PublicProtocol.OpenAI.Mapping do
  @moduledoc """
  Text-only OpenAI-compatible request/response mapping for v0.51.

  This module intentionally implements a narrow Chat Completions shim. OpenAI
  request fields do not grant Allbert tool, media, retention, or routing
  authority.
  """

  alias AllbertAssist.PublicProtocol.{HttpIngress, ResultReadback}
  alias AllbertAssist.Runtime.Response
  alias AllbertAssist.Settings
  alias AllbertAssist.Surface.Renderer, as: SurfaceRenderer

  @surface "openai_api"
  @allowed_roles ~w[system developer user assistant]
  @allowed_request_fields ~w[
    allbert_session_id
    allbert_thread_id
    allbert_user_id
    messages
    model
    response_format
    stream
    user
  ]

  @type chat_request :: %{
          required(:model) => String.t(),
          required(:text) => String.t(),
          required(:stream?) => boolean(),
          required(:user_id) => String.t(),
          optional(:thread_id) => String.t(),
          optional(:session_id) => String.t()
        }

  @type error :: %{
          required(:status) => pos_integer(),
          required(:message) => String.t(),
          required(:type) => String.t(),
          required(:code) => String.t(),
          optional(:param) => String.t() | nil
        }

  @spec parse_chat_request(map(), map()) :: {:ok, chat_request()} | {:error, error()}
  def parse_chat_request(request, auth) when is_map(request) and is_map(auth) do
    with :ok <- reject_unsupported_fields(request),
         {:ok, model} <- require_string(request, "model"),
         :ok <- validate_enabled_model(model),
         :ok <- validate_response_format(Map.get(request, "response_format")),
         {:ok, stream?} <- stream_flag(Map.get(request, "stream", false)),
         {:ok, text} <- flatten_messages(Map.get(request, "messages")) do
      {:ok,
       %{
         model: model,
         text: text,
         stream?: stream?,
         user_id: user_id(request, auth),
         thread_id: optional_string(Map.get(request, "allbert_thread_id")),
         session_id: optional_string(Map.get(request, "allbert_session_id"))
       }}
    end
  end

  def parse_chat_request(_request, _auth),
    do: {:error, invalid("Request body must be a JSON object.")}

  @spec runtime_request(chat_request(), map()) :: map()
  def runtime_request(chat, auth) do
    %{
      text: chat.text,
      channel: :openai_api,
      user_id: chat.user_id,
      operator_id: chat.user_id,
      thread_id: Map.get(chat, :thread_id),
      session_id: Map.get(chat, :session_id),
      metadata: %{
        public_protocol: %{
          surface: @surface,
          client_id: Map.fetch!(auth, :client_id)
        },
        openai_api: %{
          model: chat.model
        }
      }
    }
    |> drop_nil_values()
  end

  @spec models_response() :: {:ok, map()} | {:error, error()}
  def models_response do
    case Settings.get("openai_api.models_enabled") do
      {:ok, models} when is_list(models) ->
        {:ok,
         %{
           "object" => "list",
           "data" =>
             Enum.map(models, fn model ->
               %{
                 "id" => model,
                 "object" => "model",
                 "created" => 0,
                 "owned_by" => "allbert"
               }
             end)
         }}

      {:error, reason} ->
        {:error, invalid("OpenAI API models are unavailable: #{inspect(reason)}.")}

      {:ok, other} ->
        {:error, invalid("OpenAI API models setting is invalid: #{inspect(other)}.")}
    end
  end

  @spec chat_completion(map(), chat_request(), map()) :: {:ok, map()} | {:error, error()}
  def chat_completion(runtime_response, chat, auth) when is_map(runtime_response) do
    case Response.status(runtime_response) do
      :completed ->
        {:ok, completion_object(runtime_response, chat)}

      :needs_confirmation ->
        pending_completion(runtime_response, chat, auth)

      :denied ->
        {:error, authorization_error(Map.get(runtime_response, :message, "Request was denied."))}

      status when status in [:error, :failed, :unsupported, :unavailable] ->
        {:error,
         invalid(
           Map.get(runtime_response, :message, "Allbert runtime returned #{status}."),
           "runtime_error"
         )}

      _status ->
        {:ok, completion_object(runtime_response, chat)}
    end
  end

  def chat_completion(_runtime_response, _chat, _auth),
    do: {:error, invalid("Allbert runtime returned an invalid response.", "runtime_error")}

  @spec sse_payload(map()) :: String.t()
  def sse_payload(completion) when is_map(completion) do
    chunk =
      %{
        "id" => completion["id"],
        "object" => "chat.completion.chunk",
        "created" => completion["created"],
        "model" => completion["model"],
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{
              "role" => "assistant",
              "content" => completion_content(completion)
            },
            "finish_reason" => "stop"
          }
        ],
        "usage" => nil
      }
      |> maybe_copy(completion, "allbert_status")
      |> maybe_copy(completion, "allbert_public_call_id")
      |> maybe_copy(completion, "allbert_trace_id")

    "data: #{Jason.encode!(chunk)}\n\ndata: [DONE]\n\n"
  end

  @spec ingress_error(term()) :: error()
  def ingress_error(reason) do
    %{
      status: HttpIngress.status(reason),
      message: ingress_message(reason),
      type: ingress_type(reason),
      code: ingress_code(reason),
      param: nil
    }
  end

  @spec runtime_error(term()) :: error()
  def runtime_error(reason),
    do: invalid("Allbert runtime failed: #{inspect(reason)}.", "runtime_error")

  @spec error_body(error()) :: map()
  def error_body(error) do
    %{
      "error" => %{
        "message" => error.message,
        "type" => error.type,
        "param" => Map.get(error, :param),
        "code" => error.code
      }
    }
  end

  @spec error_status(error()) :: pos_integer()
  def error_status(error), do: error.status

  defp pending_completion(runtime_response, chat, auth) do
    attrs = %{
      surface: @surface,
      client_id: Map.fetch!(auth, :client_id),
      action_label: "chat.completion",
      confirmation_id: confirmation_id(runtime_response),
      trace_id: Map.get(runtime_response, :trace_id),
      trace_metadata: %{status: "confirmation_pending"}
    }

    with {:ok, readback} <- ResultReadback.create(attrs) do
      {:ok,
       runtime_response
       |> completion_object(chat)
       |> Map.put("allbert_status", "pending")
       |> Map.put("allbert_public_call_id", readback.id)}
    else
      {:error, reason} ->
        {:error,
         invalid("Could not create public readback record: #{inspect(reason)}.", "readback_error")}
    end
  end

  defp completion_object(runtime_response, chat) do
    %{
      "id" => "chatcmpl_" <> Ecto.UUID.generate(),
      "object" => "chat.completion",
      "created" => System.system_time(:second),
      "model" => chat.model,
      "choices" => [
        %{
          "index" => 0,
          "message" => %{
            "role" => "assistant",
            "content" => SurfaceRenderer.response_text(runtime_response, %{payload: :message}),
            "tool_calls" => nil
          },
          "finish_reason" => "stop",
          "logprobs" => nil
        }
      ],
      "usage" => nil
    }
    |> maybe_put_trace(runtime_response)
  end

  defp reject_unsupported_fields(request) do
    request
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.find(&(&1 not in @allowed_request_fields))
    |> case do
      nil ->
        :ok

      field ->
        {:error,
         invalid(
           "Unsupported OpenAI-compatible request field: #{field}.",
           "unsupported_parameter",
           field
         )}
    end
  end

  defp validate_enabled_model(model) do
    case Settings.get("openai_api.models_enabled") do
      {:ok, models} when is_list(models) ->
        if model in models do
          :ok
        else
          {:error,
           invalid(
             "Model is not enabled for the OpenAI-compatible API.",
             "model_not_enabled",
             "model"
           )}
        end

      {:ok, _models} ->
        {:error,
         invalid(
           "Model is not enabled for the OpenAI-compatible API.",
           "model_not_enabled",
           "model"
         )}

      {:error, reason} ->
        {:error,
         invalid(
           "OpenAI API model settings are unavailable: #{inspect(reason)}.",
           "settings_error"
         )}
    end
  end

  defp validate_response_format(nil), do: :ok
  defp validate_response_format(%{"type" => "text"}), do: :ok

  defp validate_response_format(_format),
    do:
      {:error,
       invalid(
         ~S(Only response_format={"type":"text"} is supported in v0.51.),
         "unsupported_response_format",
         "response_format"
       )}

  defp stream_flag(value) when is_boolean(value), do: {:ok, value}

  defp stream_flag(_value),
    do: {:error, invalid("stream must be a boolean.", "invalid_type", "stream")}

  defp flatten_messages(messages) when is_list(messages) and messages != [] do
    messages
    |> Enum.reduce_while({:ok, []}, fn message, {:ok, lines} ->
      case message_line(message) do
        {:ok, line} -> {:cont, {:ok, [line | lines]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, lines} -> {:ok, lines |> Enum.reverse() |> Enum.join("\n")}
      {:error, error} -> {:error, error}
    end
  end

  defp flatten_messages(_messages),
    do: {:error, invalid("messages must be a non-empty array.", "invalid_type", "messages")}

  defp message_line(%{"role" => role} = message) when role in @allowed_roles do
    with :ok <- validate_assistant_no_tools(role, message),
         {:ok, content} <- message_content(message) do
      {:ok, "#{role}: #{content}"}
    end
  end

  defp message_line(%{"role" => role}),
    do: {:error, invalid("Unsupported message role: #{role}.", "unsupported_role", "messages")}

  defp message_line(_message),
    do:
      {:error,
       invalid(
         "Each message must be an object with a supported role.",
         "invalid_type",
         "messages"
       )}

  defp validate_assistant_no_tools("assistant", message) do
    cond do
      Map.has_key?(message, "tool_calls") and not is_nil(Map.get(message, "tool_calls")) ->
        {:error,
         invalid("assistant tool_calls are not supported.", "unsupported_parameter", "messages")}

      Map.has_key?(message, "function_call") and not is_nil(Map.get(message, "function_call")) ->
        {:error,
         invalid("assistant function_call is not supported.", "unsupported_parameter", "messages")}

      true ->
        :ok
    end
  end

  defp validate_assistant_no_tools(_role, _message), do: :ok

  defp message_content(%{"content" => content}) when is_binary(content) do
    if String.trim(content) == "" do
      {:error, invalid("message content must not be empty.", "invalid_type", "messages")}
    else
      {:ok, content}
    end
  end

  defp message_content(%{"content" => parts}) when is_list(parts) do
    parts
    |> Enum.reduce_while({:ok, []}, fn
      %{"type" => "text", "text" => text}, {:ok, texts} when is_binary(text) ->
        {:cont, {:ok, [text | texts]}}

      %{"type" => type}, {:ok, _texts} ->
        {:halt,
         {:error,
          invalid(
            "Unsupported content part type: #{type}.",
            "unsupported_content_part",
            "messages"
          )}}

      _part, {:ok, _texts} ->
        {:halt, {:error, invalid("Invalid content part.", "invalid_type", "messages")}}
    end)
    |> case do
      {:ok, texts} when texts != [] ->
        {:ok, texts |> Enum.reverse() |> Enum.join("\n")}

      {:ok, []} ->
        {:error, invalid("message content parts must not be empty.", "invalid_type", "messages")}

      {:error, error} ->
        {:error, error}
    end
  end

  defp message_content(_message),
    do: {:error, invalid("message content must be text.", "invalid_type", "messages")}

  defp require_string(request, field) do
    case Map.get(request, field) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, invalid("#{field} is required.", "missing_required_parameter", field)}
    end
  end

  defp user_id(request, auth) do
    optional_string(Map.get(request, "allbert_user_id")) ||
      optional_string(Map.get(request, "user")) ||
      "public-protocol:#{Map.fetch!(auth, :client_id)}"
  end

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

  defp completion_content(%{"choices" => [%{"message" => %{"content" => content}} | _rest]}),
    do: content

  defp completion_content(_completion), do: ""

  defp maybe_copy(target, source, key) do
    case Map.fetch(source, key) do
      {:ok, value} -> Map.put(target, key, value)
      :error -> target
    end
  end

  defp maybe_put_trace(body, %{trace_id: trace_id}) when is_binary(trace_id),
    do: Map.put(body, "allbert_trace_id", trace_id)

  defp maybe_put_trace(body, _response), do: body

  defp drop_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  defp invalid(message, code \\ "invalid_request", param \\ nil) do
    %{
      status: 400,
      message: message,
      type: "invalid_request_error",
      code: code,
      param: param
    }
  end

  defp authorization_error(message) do
    %{
      status: 403,
      message: message,
      type: "authorization_error",
      code: "authorization_error",
      param: nil
    }
  end

  defp ingress_message(:missing_client_id), do: "Missing public protocol client id."
  defp ingress_message(:missing_bearer_token), do: "Missing bearer token."
  defp ingress_message(:invalid_token), do: "Invalid bearer token."
  defp ingress_message(:unknown_client), do: "Unknown public protocol client."
  defp ingress_message(:client_disabled), do: "Public protocol client is disabled."
  defp ingress_message(:surface_disabled), do: "OpenAI-compatible API is disabled."
  defp ingress_message(:rate_limited), do: "Public protocol client is rate limited."

  defp ingress_message(:origin_denied),
    do: "Origin is not allowed for this public protocol surface."

  defp ingress_message(reason), do: "OpenAI-compatible request failed: #{inspect(reason)}."

  defp ingress_type(:rate_limited), do: "rate_limit_error"
  defp ingress_type(:origin_denied), do: "authorization_error"
  defp ingress_type(:surface_disabled), do: "authorization_error"

  defp ingress_type(reason)
       when reason in [
              :missing_client_id,
              :missing_bearer_token,
              :invalid_token,
              :unknown_client,
              :client_disabled
            ],
       do: "authentication_error"

  defp ingress_type(_reason), do: "invalid_request_error"

  defp ingress_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp ingress_code({reason, _value}) when is_atom(reason), do: Atom.to_string(reason)
  defp ingress_code(_reason), do: "invalid_request"
end
