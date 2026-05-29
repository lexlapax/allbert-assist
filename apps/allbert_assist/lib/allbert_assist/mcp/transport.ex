defmodule AllbertAssist.Mcp.Transport do
  @moduledoc """
  Allbert-owned MCP transport boundary.

  HTTP-like transports route through `External.HttpClient` and stdio uses an
  explicit argv `Port`. This module owns no durable state; stdio ports are
  opened for one bounded action and closed at the end of the action.
  """

  alias AllbertAssist.External.HttpClient
  alias AllbertAssist.External.RequestSpec
  alias AllbertAssist.Mcp.Diagnostics
  alias AllbertAssist.Mcp.ServerConfig

  @json_header {"content-type", "application/json"}

  @type connection :: map()

  @spec open(ServerConfig.t(), map()) :: {:ok, connection()} | {:error, term()}
  def open(%ServerConfig{transport: transport} = config, context)
      when transport in [:streamable_http, :sse] do
    {:ok, %{kind: :http, config: config, context: context}}
  end

  def open(%ServerConfig{transport: :stdio} = config, _context) do
    with {:ok, executable} <- find_executable(config.command),
         {:ok, port} <- open_port(executable, config) do
      {:ok, %{kind: :stdio, config: config, port: port, buffer: ""}}
    end
  end

  @spec close(connection()) :: :ok
  def close(%{kind: :stdio, port: port}) when is_port(port) do
    Port.close(port)
    :ok
  rescue
    _exception -> :ok
  end

  def close(_connection), do: :ok

  @spec request(connection(), map(), keyword()) ::
          {:ok, map(), connection()} | {:error, term(), connection()}
  def request(%{kind: :http, config: config, context: context} = conn, payload, _opts) do
    with {:ok, body} <- Jason.encode(payload),
         {:ok, spec} <- request_spec(config, body),
         {:ok, result} <- HttpClient.request(spec, plug: req_plug(context)),
         {:ok, response} <- decode_http_response(result) do
      {:ok, response, conn}
    else
      {:error, %RequestSpec{} = spec} ->
        {:error, {:endpoint_denied, spec.denial_reason, Diagnostics.new(:endpoint_denied)}, conn}

      {:error, reason} ->
        {:error, reason, conn}
    end
  end

  def request(%{kind: :stdio, port: port} = conn, payload, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, conn.config.timeout_ms)

    with {:ok, encoded} <- Jason.encode(payload),
         true <- Port.command(port, encoded <> "\n"),
         {:ok, response} <- receive_stdio_response(port, payload["id"], timeout_ms, "") do
      {:ok, response, conn}
    else
      false ->
        {:error, {:stdio_start_failed, Diagnostics.new(:stdio_start_failed)}, conn}

      {:error, reason} ->
        {:error, reason, conn}
    end
  end

  @spec notify(connection(), map()) :: {:ok, connection()} | {:error, term(), connection()}
  def notify(%{kind: :http} = conn, _payload), do: {:ok, conn}

  def notify(%{kind: :stdio, port: port} = conn, payload) do
    with {:ok, encoded} <- Jason.encode(payload),
         true <- Port.command(port, encoded <> "\n") do
      {:ok, conn}
    else
      false -> {:error, {:stdio_start_failed, Diagnostics.new(:stdio_start_failed)}, conn}
      {:error, reason} -> {:error, reason, conn}
    end
  end

  defp request_spec(config, body) do
    RequestSpec.normalize(%{
      method: "POST",
      url: config.base_url,
      headers: http_headers(config),
      body: body,
      timeout_ms: config.timeout_ms,
      max_response_bytes: config.max_response_bytes
    })
  end

  defp http_headers(config) do
    config.headers
    |> Enum.map(fn {key, value} -> {key, value} end)
    |> Enum.reject(fn {name, _value} -> sensitive_header?(name) end)
    |> put_json_header()
  end

  defp put_json_header(headers) do
    if Enum.any?(headers, fn {name, _value} ->
         String.downcase(to_string(name)) == "content-type"
       end) do
      headers
    else
      [@json_header | headers]
    end
  end

  defp sensitive_header?(name) do
    name
    |> to_string()
    |> String.downcase()
    |> Kernel.in(["authorization", "cookie", "x-api-key"])
  end

  defp decode_http_response(%{status: :completed, body_preview: body}) do
    decode_wire_response(body)
  end

  defp decode_http_response(%{http_status: status}) when is_integer(status) and status >= 400 do
    {:error, {:endpoint_http_error, Diagnostics.new(:endpoint_http_error)}}
  end

  defp decode_http_response(%{transport_error: _reason}) do
    {:error, {:endpoint_unreachable, Diagnostics.new(:endpoint_unreachable)}}
  end

  defp decode_http_response(_result),
    do: {:error, {:protocol_error, Diagnostics.new(:protocol_error)}}

  defp decode_wire_response(body) when is_binary(body) do
    body
    |> String.trim()
    |> sse_data()
    |> Jason.decode()
    |> case do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _other -> {:error, {:protocol_error, Diagnostics.new(:protocol_error)}}
    end
  end

  defp sse_data("event:" <> _rest = body) do
    body
    |> String.split("\n")
    |> Enum.find_value("", fn line ->
      line = String.trim(line)

      if String.starts_with?(line, "data:") do
        line |> String.replace_prefix("data:", "") |> String.trim()
      end
    end)
  end

  defp sse_data(body), do: body

  defp find_executable(command) when is_binary(command) do
    case System.find_executable(command) do
      nil -> {:error, {:stdio_launcher_missing, Diagnostics.new(:stdio_launcher_missing)}}
      executable -> {:ok, executable}
    end
  end

  defp find_executable(_command),
    do: {:error, {:stdio_launcher_missing, Diagnostics.new(:stdio_launcher_missing)}}

  defp open_port(executable, config) do
    port =
      Port.open(
        {:spawn_executable, executable},
        [
          :binary,
          :exit_status,
          :hide,
          :use_stdio,
          :stderr_to_stdout,
          {:args, config.args},
          {:env, Map.to_list(config.env)},
          {:line, config.max_response_bytes}
        ]
      )

    {:ok, port}
  rescue
    _exception -> {:error, {:stdio_start_failed, Diagnostics.new(:stdio_start_failed)}}
  end

  defp receive_stdio_response(port, request_id, timeout_ms, acc) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        decode_stdio_line(line, request_id, port, timeout_ms, acc)

      {^port, {:data, {:noeol, chunk}}} ->
        receive_stdio_response(port, request_id, timeout_ms, acc <> chunk)

      {^port, {:exit_status, _status}} ->
        {:error, {:endpoint_unreachable, Diagnostics.new(:endpoint_unreachable)}}
    after
      timeout_ms ->
        {:error, {:endpoint_unreachable, Diagnostics.new(:endpoint_unreachable)}}
    end
  end

  defp decode_stdio_line(line, request_id, port, timeout_ms, acc) do
    body = acc <> line

    case Jason.decode(body) do
      {:ok, %{"id" => ^request_id} = decoded} ->
        {:ok, decoded}

      {:ok, _other} ->
        receive_stdio_response(port, request_id, timeout_ms, "")

      {:error, _reason} ->
        receive_stdio_response(port, request_id, timeout_ms, "")
    end
  end

  defp req_plug(context) do
    get_in(context, [:mcp, :req_plug]) ||
      get_in(context, ["mcp", "req_plug"]) ||
      get_in(context, [:external, :req_plug]) ||
      get_in(context, ["external", "req_plug"])
  end
end
