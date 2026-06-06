defmodule Mix.Tasks.Allbert.Settings do
  @moduledoc """
  Inspect and update Allbert Settings Central.

  ## Usage

      mix allbert.settings list
      mix allbert.settings get operator.timezone
      mix allbert.settings explain operator.timezone
      mix allbert.settings set operator.communication_style concise
      mix allbert.settings providers list
      printf 'sk-test\\n' | mix allbert.settings providers set-key openai
  """

  use Mix.Task

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Settings

  @shortdoc "Inspect and update Allbert Settings Central"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    args
    |> dispatch()
    |> print_result()
  end

  defp dispatch(["list"]) do
    with {:ok, response} <- completed_action("list_settings", %{}) do
      {:ok, response.settings}
    end
  end

  defp dispatch(["get", key]) do
    with {:ok, response} <- completed_action("read_setting", %{key: key}) do
      {:ok, {:setting, response.setting}}
    end
  end

  defp dispatch(["explain", key]) do
    with {:ok, response} <- completed_action("explain_setting", %{key: key}) do
      {:ok, {:explanation, response.setting}}
    end
  end

  defp dispatch(["set", key, value]) do
    with {:ok, response} <-
           completed_action("update_setting", %{key: key, value: parse_value(key, value)}) do
      {:ok, {:written, response.setting}}
    end
  end

  defp dispatch(["providers", "list"]) do
    with {:ok, response} <- completed_action("list_provider_profiles", %{}) do
      {:ok, {:providers, response.providers}}
    end
  end

  defp dispatch(["providers", "set-key", provider]) do
    with {:ok, api_key} <- read_provider_key(provider),
         {:ok, response} <-
           completed_action("set_provider_credential", %{
             provider: provider,
             mode: :set_secret,
             api_key: api_key
           }) do
      {:ok, {:provider_key, response.provider, response}}
    end
  end

  defp dispatch(["providers", "set-key", _provider, _secret | _rest]) do
    Mix.raise(
      "Provider keys must be supplied through stdin or an interactive prompt, not as arguments."
    )
  end

  defp dispatch(_args) do
    Mix.raise("""
    Usage:
      mix allbert.settings list
      mix allbert.settings get KEY
      mix allbert.settings explain KEY
      mix allbert.settings set KEY VALUE
      mix allbert.settings providers list
      mix allbert.settings providers set-key PROVIDER
    """)
  end

  defp print_result({:ok, settings}) when is_list(settings) do
    Enum.each(settings, fn setting ->
      Mix.shell().info(
        "#{setting.key}=#{inspect(setting.value)} source=#{setting.source} writable=#{setting.writable?}"
      )
    end)
  end

  defp print_result({:ok, {:setting, setting}}) do
    Mix.shell().info("#{setting.key}=#{inspect(setting.value)}")
    Mix.shell().info("Source: #{setting.source}")
  end

  defp print_result({:ok, {:explanation, setting}}) do
    print_result({:ok, {:setting, setting}})
    Mix.shell().info("Writable: #{setting.writable?}")
    Mix.shell().info("Layers:")
    Enum.each(setting.layers, &Mix.shell().info("- #{&1.source}: #{inspect(&1.value)}"))
  end

  defp print_result({:ok, {:written, setting}}) do
    Mix.shell().info("Updated: #{setting.key}=#{inspect(setting.value)}")
    Mix.shell().info("Source: #{setting.source}")
    print_diagnostics(setting.diagnostics)
  end

  defp print_result({:ok, {:providers, providers}}) do
    Enum.each(providers, fn provider ->
      Mix.shell().info(
        "#{provider.name} type=#{provider.type} enabled=#{provider.enabled} credential=#{provider.credential_status}"
      )
    end)
  end

  defp print_result({:ok, {:provider_key, provider, result}}) do
    Mix.shell().info("#{provider} credential=#{result.credential_status}")
    print_diagnostics(Map.get(result, :diagnostics, []))
  end

  defp print_result({:error, reason}) do
    Mix.raise("Settings command failed: #{inspect(reason)}")
  end

  defp read_provider_key(provider) do
    case IO.gets("") do
      :eof -> prompt_provider_key(provider)
      {:error, reason} -> {:error, reason}
      value -> normalize_provider_key(value)
    end
  end

  defp prompt_provider_key(provider) do
    "API key for #{provider}: "
    |> Mix.shell().prompt()
    |> normalize_provider_key()
  end

  defp normalize_provider_key(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: {:error, :empty_provider_key}, else: {:ok, value}
  end

  defp completed_action(action_name, params) do
    case Runner.run(action_name, params, context()) do
      {:ok, %{status: :completed} = response} -> {:ok, response}
      {:ok, response} -> {:error, response_error(response)}
    end
  end

  defp response_error(%{error: error}), do: error

  defp response_error(%{actions: actions, message: message}) when is_list(actions) do
    actions
    |> Enum.find_value(&get_in(&1, [:settings_metadata, :error]))
    |> case do
      nil -> message
      error -> error
    end
  end

  defp response_error(%{message: message}), do: message

  defp parse_value(key, value) do
    cond do
      string_list_setting?(key) -> parse_string_list(value)
      string_map_setting?(key) -> parse_string_map(value)
      true -> parse_scalar_value(value)
    end
  end

  defp parse_string_list(value) do
    trimmed = String.trim(value)

    if String.starts_with?(trimmed, "[") do
      parse_json_string_list(trimmed)
    else
      value
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
    end
  end

  defp parse_json_string_list(value) do
    case Jason.decode(value) do
      {:ok, items} when is_list(items) ->
        if Enum.all?(items, &is_binary/1) do
          items
        else
          Mix.raise("Expected #{value} to be a JSON array of strings.")
        end

      {:ok, _other} ->
        Mix.raise("Expected #{value} to be a JSON array of strings.")

      {:error, reason} ->
        Mix.raise("Invalid JSON string list: #{Exception.message(reason)}")
    end
  end

  defp parse_scalar_value("true"), do: true
  defp parse_scalar_value("false"), do: false

  defp parse_scalar_value(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _other -> parse_float_or_string(value)
    end
  end

  defp string_list_setting?(key) do
    case Map.get(Settings.schema(), key) do
      %{type: :string_list} ->
        true

      _schema ->
        Regex.match?(
          ~r/^(model_profiles\.[^.]+\.aliases|model_preferences\.(tasks|capabilities)\.[^.]+|mcp\.servers\.[^.]+\.(args|tool_allowlist|tool_denylist))$/,
          key
        )
    end
  end

  defp string_map_setting?(key) do
    case Map.get(Settings.schema(), key) do
      %{type: :mcp_secret_ref_string_map} -> true
      _schema -> Regex.match?(~r/^mcp\.servers\.[^.]+\.(env|headers)$/, key)
    end
  end

  defp parse_string_map(value) do
    case Jason.decode(value) do
      {:ok, map} when is_map(map) ->
        validate_string_map!(map)

      {:ok, _other} ->
        Mix.raise("Expected MCP map settings to be a JSON object with string values.")

      {:error, reason} ->
        Mix.raise("Invalid JSON map: #{Exception.message(reason)}")
    end
  end

  defp validate_string_map!(map) do
    if Enum.all?(map, fn {key, value} -> is_binary(key) and is_binary(value) end) do
      map
    else
      Mix.raise("Expected MCP map settings to be a JSON object with string values.")
    end
  end

  defp parse_float_or_string(value) do
    case Float.parse(value) do
      {float, ""} -> float
      _other -> value
    end
  end

  defp context do
    %{actor: "local", channel: :cli}
  end

  defp print_diagnostics([]), do: :ok

  defp print_diagnostics(diagnostics) do
    Enum.each(diagnostics, fn
      %{audit_path: audit_path} -> Mix.shell().info("Audit: #{audit_path}")
      diagnostic -> Mix.shell().info("Diagnostic: #{inspect(diagnostic)}")
    end)
  end
end
