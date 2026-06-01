defmodule AllbertBrowser.Driver.Playwright do
  @moduledoc """
  Playwright Chromium driver backed by the reviewed local Node bridge.

  The driver owns no policy authority. Browser actions perform permission,
  confirmation, and URL preflight checks before calls arrive here; this module
  only controls the already-approved local browser session.
  """

  @behaviour AllbertBrowser.Driver

  alias AllbertAssist.Settings

  @line_max_bytes 4_194_304
  @default_timeout_ms 30_000

  @impl true
  def verify(opts) do
    with {:ok, port} <- open_bridge(opts),
         {:ok, result} <- command(port, "verify", bridge_params(opts), timeout_ms(opts)) do
      close_port(port)
      {:ok, result}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def start_session(opts) do
    with {:ok, port} <- open_bridge(opts),
         session_id when is_binary(session_id) <- Keyword.fetch!(opts, :session_id),
         params <- Map.put(bridge_params(opts), :session_id, session_id),
         {:ok, result} <- command(port, "start_session", params, timeout_ms(opts)) do
      {:ok,
       %{
         port: port,
         session_id: session_id,
         browser: Map.get(result, :browser),
         playwright_version: Map.get(result, :playwright_version)
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def navigate(state, url, opts) do
    params =
      state
      |> session_params(opts)
      |> Map.put(:url, url)
      |> Map.put(:wait_until, normalize_wait_until(Keyword.get(opts, :wait_until)))

    with {:ok, result} <- command(state.port, "navigate", params, timeout_ms(opts)) do
      {:ok,
       %{
         state: state,
         page_meta: %{
           url: Map.get(result, :url, url),
           title: Map.get(result, :title, ""),
           status: Map.get(result, :status),
           redirected_to: Map.get(result, :redirected_to)
         }
       }}
    end
  end

  @impl true
  def click(state, selector, opts) do
    params =
      state
      |> session_params(opts)
      |> Map.put(:selector, selector)
      |> Map.put(:visible_label_preview, Keyword.get(opts, :visible_label_preview))

    with {:ok, result} <- command(state.port, "click", params, timeout_ms(opts)) do
      {:ok,
       %{
         state: state,
         click: %{
           selector: selector,
           visible_label_preview: Map.get(result, :visible_label_preview, ""),
           navigation_triggered?: Map.get(result, :navigation_triggered, false),
           url: Map.get(result, :url)
         }
       }}
    end
  end

  @impl true
  def fill(state, selector, opts) do
    params =
      state
      |> session_params(opts)
      |> Map.put(:selector, selector)
      |> Map.put(:value, Keyword.get(opts, :value, ""))
      |> Map.put(:value_preview, Keyword.get(opts, :value_preview, "[REDACTED]"))

    with {:ok, result} <- command(state.port, "fill", params, timeout_ms(opts)) do
      {:ok,
       %{
         state: state,
         fill: %{
           selector: selector,
           value_preview: Map.get(result, :value_preview, "[REDACTED]"),
           value_redacted?: Map.get(result, :value_redacted, true),
           url: Map.get(result, :url)
         }
       }}
    end
  end

  @impl true
  def download(state, url, opts) do
    params =
      state
      |> session_params(opts)
      |> Map.put(:url, url)
      |> Map.put(:filename, Keyword.get(opts, :filename))

    with {:ok, result} <- command(state.port, "download", params, timeout_ms(opts)) do
      {:ok,
       %{
         state: state,
         download: %{
           url: url,
           filename: Map.get(result, :filename),
           path: Map.get(result, :path),
           persisted?: Map.get(result, :persisted, false)
         }
       }}
    end
  end

  @impl true
  def extract(state, format, opts) do
    params =
      state
      |> session_params(opts)
      |> Map.put(:format, Atom.to_string(format))
      |> Map.put(:max_bytes, Keyword.get(opts, :max_bytes, setting("browser.extraction.max_bytes", 1_048_576)))

    command(state.port, "extract", params, timeout_ms(opts))
  end

  @impl true
  def screenshot(state, opts) do
    params =
      state
      |> session_params(opts)
      |> Map.put(:max_bytes, Keyword.get(opts, :max_bytes, setting("browser.screenshot.max_bytes", 524_288)))
      |> Map.put(:full_page, setting("browser.screenshot.full_page", false))
      |> Map.put(
        :redact_credential_inputs,
        setting("browser.screenshot.redact_credential_inputs", true)
      )

    with {:ok, result} <- command(state.port, "screenshot", params, timeout_ms(opts)),
         {:ok, content} <- decode_screenshot(result) do
      {:ok,
       %{
         state: state,
         content: content,
         bytes: Map.get(result, :bytes, byte_size(content)),
         redacted_credential_inputs?: Map.get(result, :redacted_credential_inputs, true)
       }}
    end
  end

  @impl true
  def close(%{port: port, session_id: session_id}) when is_port(port) do
    _ = command(port, "close_session", %{session_id: session_id}, @default_timeout_ms)
    _ = command(port, "shutdown", %{}, @default_timeout_ms)
    close_port(port)
    :ok
  end

  def close(_state), do: :ok

  defp open_bridge(opts) do
    with {:ok, node} <- node_path(),
         {:ok, bridge} <- bridge_path() do
      port_opts = [
        :binary,
        :exit_status,
        :hide,
        :use_stdio,
        {:args, [bridge]},
        {:cd, Path.dirname(bridge)},
        {:line, @line_max_bytes},
        {:env, port_env(opts)}
      ]

      {:ok, Port.open({:spawn_executable, node}, port_opts)}
    end
  rescue
    exception -> {:error, {:playwright_bridge_start_failed, Exception.message(exception)}}
  catch
    :exit, reason -> {:error, {:playwright_bridge_start_failed, reason}}
  end

  defp command(port, op, params, timeout_ms) do
    id = "pw-#{System.unique_integer([:positive])}"
    payload = Jason.encode!(%{id: id, op: op, params: params}) <> "\n"

    Port.command(port, payload)
    receive_response(port, id, timeout_ms, "")
  rescue
    exception -> {:error, {:playwright_bridge_command_failed, Exception.message(exception)}}
  end

  defp receive_response(port, id, timeout_ms, acc) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        decode_response(acc <> line, id)

      {^port, {:data, {:noeol, chunk}}} ->
        receive_response(port, id, timeout_ms, acc <> chunk)

      {^port, {:exit_status, status}} ->
        {:error, {:playwright_bridge_exited, status}}
    after
      timeout_ms ->
        {:error, :playwright_bridge_timeout}
    end
  end

  defp decode_response(line, id) do
    case Jason.decode(line, keys: :atoms) do
      {:ok, %{id: ^id, ok: true, result: result}} ->
        {:ok, result}

      {:ok, %{id: ^id, ok: false, error: error}} ->
        {:error, bridge_error(error)}

      {:ok, _other} ->
        {:error, :playwright_bridge_unexpected_response}

      {:error, reason} ->
        {:error, {:playwright_bridge_invalid_response, inspect(reason)}}
    end
  end

  defp bridge_error(%{kind: kind, message: message}), do: {to_atom(kind), message}
  defp bridge_error(error), do: {:playwright_bridge_error, inspect(error)}

  defp decode_screenshot(%{content_base64: encoded}) when is_binary(encoded) do
    case Base.decode64(encoded) do
      {:ok, content} -> {:ok, content}
      :error -> {:error, :invalid_screenshot_payload}
    end
  end

  defp decode_screenshot(_result), do: {:error, :missing_screenshot_payload}

  defp session_params(%{session_id: session_id}, opts) do
    bridge_params(opts)
    |> Map.put(:session_id, session_id)
  end

  defp bridge_params(opts) do
    %{
      timeout_ms: timeout_ms(opts),
      executable_path: setting("browser.driver.binary_path", nil),
      user_agent: setting("browser.session.user_agent", "AllbertBrowser/0.43 (+local research)"),
      javascript_enabled: setting("browser.session.javascript_enabled", true),
      host_resolver_rules: System.get_env("ALLBERT_BROWSER_HOST_RESOLVER_RULES")
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  defp timeout_ms(opts), do: Keyword.get(opts, :timeout_ms, setting("browser.navigation.timeout_ms", @default_timeout_ms))

  defp normalize_wait_until(value) when value in ["load", "domcontentloaded", "networkidle", "commit"], do: value
  defp normalize_wait_until(_value), do: "domcontentloaded"

  defp node_path do
    configured = setting("browser.driver.node_path", nil)

    cond do
      is_binary(configured) and configured != "" and File.exists?(configured) ->
        {:ok, configured}

      node = System.find_executable("node") ->
        {:ok, node}

      true ->
        {:error, :node_unavailable}
    end
  end

  defp bridge_path do
    path = Path.expand("../../../priv/playwright_bridge/bridge.js", __DIR__)

    if File.exists?(path), do: {:ok, path}, else: {:error, {:playwright_bridge_missing, path}}
  end

  defp port_env(_opts) do
    []
  end

  defp close_port(port) when is_port(port) do
    Port.close(port)
  rescue
    _exception -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp setting(key, fallback) do
    case Settings.get(key) do
      {:ok, value} -> value
      {:error, _reason} -> fallback
    end
  end

  defp to_atom(value) when is_atom(value), do: value
  defp to_atom(value) when is_binary(value), do: String.to_atom(value)
end
