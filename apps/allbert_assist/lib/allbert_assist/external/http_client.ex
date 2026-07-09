defmodule AllbertAssist.External.HttpClient do
  @moduledoc """
  Req-backed executor for already confirmed external request specs.
  """

  alias AllbertAssist.External.RequestSpec
  alias AllbertAssist.External.TLS

  def request(%RequestSpec{} = spec, opts \\ []) do
    started = System.monotonic_time()

    spec
    |> req_options(opts)
    |> Req.request()
    |> case do
      {:ok, response} ->
        {:ok, response_result(spec, response, duration_ms(started))}

      {:error, %Req.TransportError{} = error} ->
        {:ok, transport_error_result(spec, error.reason, duration_ms(started))}

      {:error, reason} ->
        {:ok, transport_error_result(spec, reason, duration_ms(started))}
    end
  end

  defp req_options(spec, opts) do
    [
      method: method_atom(spec.method),
      url: spec.url,
      headers: spec.headers,
      body: spec.body,
      receive_timeout: spec.timeout_ms,
      retry: retry_option(spec),
      redirect: spec.allow_redirects?,
      max_redirects: spec.max_redirects
    ]
    |> maybe_put(:plug, Keyword.get(opts, :plug))
    |> Keyword.merge(TLS.connect_options())
  end

  defp response_result(spec, response, duration_ms) do
    body = body_to_binary(response.body)
    {preview, truncated?} = capped_preview(body, spec.max_response_bytes)
    status = if response.status < 400, do: :completed, else: :failed

    %{
      status: status,
      http_status: response.status,
      duration_ms: duration_ms,
      request: RequestSpec.summary(spec),
      response_headers: redact_response_headers(response.headers, spec),
      body_preview: preview,
      response_body_bytes: byte_size(body),
      truncated?: truncated?,
      retry_policy: spec.retry_policy,
      redirect_policy: %{
        allow_redirects?: spec.allow_redirects?,
        max_redirects: spec.max_redirects
      }
    }
  end

  defp transport_error_result(spec, reason, duration_ms) do
    %{
      status: :failed,
      http_status: nil,
      duration_ms: duration_ms,
      request: RequestSpec.summary(spec),
      response_headers: [],
      body_preview: "",
      response_body_bytes: 0,
      truncated?: false,
      transport_error: inspect(reason),
      retry_policy: spec.retry_policy,
      redirect_policy: %{
        allow_redirects?: spec.allow_redirects?,
        max_redirects: spec.max_redirects
      }
    }
  end

  defp redact_response_headers(headers, spec) do
    headers
    |> normalize_response_headers()
    |> RequestSpec.redact_headers(spec.redact_response_headers)
  end

  defp normalize_response_headers(headers) when is_map(headers) do
    Enum.map(headers, fn {name, values} ->
      value = if is_list(values), do: Enum.join(values, ","), else: to_string(values)
      {String.downcase(to_string(name)), value}
    end)
  end

  defp body_to_binary(body) when is_binary(body), do: body
  defp body_to_binary(nil), do: ""

  defp body_to_binary(body) do
    case Jason.encode(body) do
      {:ok, encoded} -> encoded
      {:error, _reason} -> inspect(body)
    end
  end

  defp capped_preview(body, cap) do
    if byte_size(body) > cap do
      {binary_part(body, 0, cap), true}
    else
      {body, false}
    end
  end

  defp duration_ms(started) do
    System.monotonic_time()
    |> Kernel.-(started)
    |> System.convert_time_unit(:native, :millisecond)
  end

  defp retry_option(%{retry_policy: "safe_idempotent"}), do: :safe
  defp retry_option(_spec), do: false

  defp method_atom("GET"), do: :get
  defp method_atom("HEAD"), do: :head
  defp method_atom("POST"), do: :post
  defp method_atom("PUT"), do: :put
  defp method_atom("PATCH"), do: :patch
  defp method_atom("DELETE"), do: :delete

  defp maybe_put(options, _key, nil), do: options
  defp maybe_put(options, key, value), do: Keyword.put(options, key, value)
end
