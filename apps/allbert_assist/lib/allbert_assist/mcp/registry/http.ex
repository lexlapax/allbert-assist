defmodule AllbertAssist.Mcp.Registry.Http do
  @moduledoc false

  alias AllbertAssist.External.HttpClient
  alias AllbertAssist.External.RequestSpec

  @default_timeout_ms 5_000
  @default_max_response_bytes 512_000

  @spec get_json(String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def get_json(url, query \\ %{}, opts \\ %{}) when is_binary(url) and is_map(opts) do
    with {:ok, spec} <-
           RequestSpec.normalize(%{
             method: "GET",
             url: url,
             query: query,
             headers: Map.get(opts, :headers, Map.get(opts, "headers", [])),
             timeout_ms: int_opt(opts, :timeout_ms, @default_timeout_ms),
             max_response_bytes: int_opt(opts, :max_response_bytes, @default_max_response_bytes)
           }),
         {:ok, result} <- HttpClient.request(spec, plug: req_plug(context(opts))) do
      decode_response(result)
    else
      {:error, %RequestSpec{} = spec} ->
        {:error, {:http_policy_denied, spec.denial_reason}}
    end
  end

  @spec join_url(String.t(), String.t()) :: String.t()
  def join_url(base_url, path) when is_binary(base_url) and is_binary(path) do
    base_url
    |> URI.merge(path)
    |> URI.to_string()
  end

  defp decode_response(%{status: :completed, body_preview: body, truncated?: false}) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, decoded} -> {:error, {:unexpected_json_shape, decoded}}
      {:error, reason} -> {:error, {:invalid_json_response, reason}}
    end
  end

  defp decode_response(%{status: :completed, truncated?: true}) do
    {:error, :registry_response_truncated}
  end

  defp decode_response(%{http_status: status, body_preview: body}) when is_integer(status) do
    {:error, {:registry_http_error, status, body}}
  end

  defp decode_response(%{transport_error: reason}), do: {:error, {:registry_unreachable, reason}}
  defp decode_response(result), do: {:error, {:unexpected_registry_result, result}}

  defp int_opt(opts, key, default) do
    case Map.get(opts, key, Map.get(opts, Atom.to_string(key), default)) do
      value when is_integer(value) and value > 0 -> value
      _value -> default
    end
  end

  defp context(opts), do: Map.get(opts, :context, Map.get(opts, "context", %{}))

  defp req_plug(context) do
    get_in(context, [:mcp, :req_plug]) ||
      get_in(context, ["mcp", "req_plug"]) ||
      get_in(context, [:external, :req_plug]) ||
      get_in(context, ["external", "req_plug"])
  end
end
