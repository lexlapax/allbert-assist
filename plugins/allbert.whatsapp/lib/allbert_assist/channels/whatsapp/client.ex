defmodule AllbertAssist.Channels.WhatsApp.Client do
  @moduledoc false

  alias AllbertAssist.External.HttpPolicy
  alias AllbertAssist.External.RequestSpec
  alias AllbertAssist.Runtime.Redactor

  @base_url "https://graph.facebook.com"
  @default_api_version "v23.0"
  @default_max_response_bytes 1_048_576

  def phone_number(access_token, phone_number_id, opts \\ []) do
    case client_mode(opts) do
      :stub ->
        stub_phone_number(phone_number_id, opts)

      :real ->
        request(
          :get,
          access_token,
          phone_number_id,
          [params: %{fields: "display_phone_number,verified_name,quality_rating"}],
          opts
        )
    end
  end

  def send_text(access_token, phone_number_id, to, text, opts \\ []) do
    payload =
      %{
        "messaging_product" => "whatsapp",
        "recipient_type" => "individual",
        "to" => to,
        "type" => "text",
        "text" => %{"body" => text}
      }
      |> maybe_put_context(Keyword.get(opts, :context_message_id))

    send_message(access_token, phone_number_id, payload, opts)
  end

  def send_interactive_buttons(access_token, phone_number_id, to, body, buttons, opts \\ []) do
    payload =
      %{
        "messaging_product" => "whatsapp",
        "recipient_type" => "individual",
        "to" => to,
        "type" => "interactive",
        "interactive" => %{
          "type" => "button",
          "body" => %{"text" => body},
          "action" => %{
            "buttons" =>
              Enum.map(buttons, fn button ->
                %{
                  "type" => "reply",
                  "reply" => %{
                    "id" => Map.fetch!(button, :id),
                    "title" => Map.fetch!(button, :title)
                  }
                }
              end)
          }
        }
      }
      |> maybe_put_context(Keyword.get(opts, :context_message_id))

    send_message(access_token, phone_number_id, payload, opts)
  end

  def send_message(access_token, phone_number_id, payload, opts \\ []) do
    case client_mode(opts) do
      :stub -> stub_send_message(phone_number_id, payload, opts)
      :real -> request(:post, access_token, "#{phone_number_id}/messages", [json: payload], opts)
    end
  end

  def send_text_request(phone_number_id, to, text, opts \\ []) do
    context = Keyword.get(opts, :context_message_id)

    payload =
      %{
        "messaging_product" => "whatsapp",
        "recipient_type" => "individual",
        "to" => to,
        "type" => "text",
        "text" => %{"body" => text}
      }
      |> maybe_put_context(context)

    build_request(:post, "#{phone_number_id}/messages", json: payload)
  end

  def send_buttons_request(phone_number_id, to, body, buttons, opts \\ []) do
    context = Keyword.get(opts, :context_message_id)

    payload =
      %{
        "messaging_product" => "whatsapp",
        "recipient_type" => "individual",
        "to" => to,
        "type" => "interactive",
        "interactive" => %{
          "type" => "button",
          "body" => %{"text" => body},
          "action" => %{
            "buttons" =>
              Enum.map(buttons, fn button ->
                %{
                  "type" => "reply",
                  "reply" => %{
                    "id" => Map.fetch!(button, :id),
                    "title" => Map.fetch!(button, :title)
                  }
                }
              end)
          }
        }
      }
      |> maybe_put_context(context)

    build_request(:post, "#{phone_number_id}/messages", json: payload)
  end

  def phone_number_request(phone_number_id) do
    build_request(:get, phone_number_id,
      params: %{fields: "display_phone_number,verified_name,quality_rating"}
    )
  end

  defp request(method, access_token, path, request_opts, opts) do
    with {:ok, token} <- validate_access_token(access_token),
         request <- build_request(method, path, request_opts, opts),
         :ok <- validate_policy(request, request_opts, opts) do
      [
        method: method,
        url: request.url,
        headers: [{"authorization", "Bearer " <> token}],
        retry: false,
        redirect: false,
        receive_timeout: Keyword.get(opts, :receive_timeout, 10_000)
      ]
      |> Keyword.merge(request_opts)
      |> Keyword.delete(:params)
      |> Keyword.delete(:max_response_bytes)
      |> Keyword.merge(Keyword.take(opts, [:plug]))
      |> Req.request()
      |> normalize_response()
    end
  end

  defp build_request(method, path, request_opts, opts \\ []) do
    api_version =
      opts |> Keyword.get(:api_version, @default_api_version) |> normalize_api_version()

    url = "#{@base_url}/#{api_version}/#{String.trim_leading(to_string(path), "/")}"
    {url, request_opts} = apply_query_params(url, request_opts)
    uri = URI.parse(url)

    %{
      method: method,
      url: url,
      path: uri.path,
      headers: [{"authorization", "Bearer [REDACTED]"}],
      redacted_headers: [{"authorization", "[REDACTED]"}],
      body: request_opts |> Keyword.get(:json) |> Redactor.redact()
    }
  end

  defp validate_policy(request, request_opts, opts) do
    uri = URI.parse(request.url)
    max_response_bytes = Keyword.get(opts, :max_response_bytes, @default_max_response_bytes)

    spec = %RequestSpec{
      method: request.method |> Atom.to_string() |> String.upcase(),
      url: URI.to_string(uri),
      uri: uri,
      profile: "whatsapp_cloud_api",
      host: String.downcase(uri.host || ""),
      path: uri.path || "/",
      query: uri.query,
      headers: [],
      body: request_body(request_opts),
      body_summary: body_summary(request_opts),
      timeout_ms: Keyword.get(opts, :receive_timeout, 10_000),
      max_response_bytes: max_response_bytes,
      allow_redirects?: false,
      max_redirects: 0,
      retry_policy: "none",
      redact_request_headers: ["authorization", "cookie", "x-api-key"],
      redact_response_headers: ["set-cookie", "authorization"],
      source_text: nil,
      enabled?: true,
      profile_enabled?: true,
      allowed_hosts: ["graph.facebook.com"],
      blocked_hosts: [],
      allowed_paths: [
        "/#{normalize_api_version(Keyword.get(opts, :api_version, @default_api_version))}"
      ],
      allowed_methods: ["GET", "POST"]
    }

    case HttpPolicy.validate(spec) do
      :ok -> :ok
      {:error, reason} -> {:error, {:whatsapp_http_policy_denied, reason}}
    end
  end

  defp apply_query_params(url, request_opts) do
    case Keyword.pop(request_opts, :params) do
      {nil, request_opts} ->
        {url, request_opts}

      {params, request_opts} ->
        uri = URI.parse(url)
        query = params |> URI.encode_query() |> merge_query(uri.query)
        {URI.to_string(%{uri | query: query}), request_opts}
    end
  end

  defp merge_query(query, nil), do: query
  defp merge_query(query, ""), do: query
  defp merge_query(query, existing), do: "#{existing}&#{query}"

  defp request_body(request_opts) do
    case Keyword.get(request_opts, :json) do
      nil -> Keyword.get(request_opts, :body)
      json -> Jason.encode!(json)
    end
  end

  defp body_summary(request_opts) do
    case request_body(request_opts) do
      nil -> %{type: "none", bytes: 0}
      body when is_binary(body) -> %{type: body_type(request_opts), bytes: byte_size(body)}
    end
  end

  defp body_type(request_opts) do
    if Keyword.has_key?(request_opts, :json), do: "json", else: "raw"
  end

  defp normalize_response({:ok, %{status: status, body: body}}) when status in 200..299,
    do: {:ok, body}

  defp normalize_response({:ok, %{status: status, body: body}}),
    do: {:error, {:whatsapp_error, status, Redactor.redact(body)}}

  defp normalize_response({:error, %Req.TransportError{} = error}),
    do: {:error, {:transport_error, error.reason}}

  defp normalize_response({:error, reason}), do: {:error, {:transport_error, reason}}

  defp stub_phone_number(phone_number_id, _opts) do
    {:ok,
     %{
       "id" => phone_number_id,
       "display_phone_number" => "+#{phone_number_id}",
       "verified_name" => "Allbert Fixture",
       "quality_rating" => "GREEN"
     }}
  end

  defp stub_send_message(_phone_number_id, _payload, opts) do
    case Keyword.get(opts, :stub_result, :success) do
      :success ->
        {:ok, %{"messages" => [%{"id" => "wamid.fixture." <> Ecto.UUID.generate()}]}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_access_token(token) when is_binary(token) do
    token = String.trim(token)
    if token == "", do: {:error, :missing_whatsapp_access_token}, else: {:ok, token}
  end

  defp validate_access_token(_token), do: {:error, :missing_whatsapp_access_token}

  defp maybe_put_context(payload, value) when is_binary(value) and value != "",
    do: Map.put(payload, "context", %{"message_id" => value})

  defp maybe_put_context(payload, _value), do: payload

  defp normalize_api_version(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.trim_leading("/")
    |> case do
      "" -> @default_api_version
      version -> version
    end
  end

  defp normalize_api_version(_value), do: @default_api_version

  defp client_mode(opts), do: Keyword.get(opts, :mode, :real)
end
