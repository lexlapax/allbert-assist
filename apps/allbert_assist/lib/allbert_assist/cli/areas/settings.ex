defmodule AllbertAssist.CLI.Areas.Settings do
  @moduledoc """
  Release-safe `settings` admin dispatch (v0.62 M8.7).

  The single source of truth for `mix allbert.settings` and
  `allbert admin settings`: `dispatch/2` parses the sub-argv, inspects and
  updates Settings Central through the same registered actions the Mix task
  used, and returns `{rendered_output, exit_code}` — no `Mix.*` calls, so it
  runs inside the packaged release. `Mix.Tasks.Allbert.Settings` is a thin
  wrapper that prints the output through `Mix.shell/0`.
  """

  alias AllbertAssist.Actions.Helper, as: ActionHelper
  alias AllbertAssist.CLI.Areas.Render
  alias AllbertAssist.Settings
  alias AllbertAssist.Surfaces.ContextBuilder

  @usage """
  Usage:
    allbert admin settings list
    allbert admin settings get KEY
    allbert admin settings explain KEY
    allbert admin settings set KEY VALUE
    allbert admin settings providers list
    allbert admin settings doctor
    allbert admin settings model-doctor
    allbert admin settings providers set-key PROVIDER
  """

  @spec dispatch([String.t()], map() | nil) :: {String.t(), non_neg_integer()}
  def dispatch(argv, context \\ nil) do
    argv
    |> route(context || default_context())
    |> render()
  end

  defp default_context, do: ContextBuilder.cli_context(surface: "allbert admin settings")

  defp route(["list"], ctx) do
    with {:ok, response} <- completed_action("list_settings", operator_report_params(), ctx) do
      {:ok, response.settings}
    end
  end

  defp route(["get", key], ctx) do
    with {:ok, response} <- completed_action("read_setting", %{key: key}, ctx) do
      {:ok, {:setting, response.setting}}
    end
  end

  defp route(["explain", key], ctx) do
    with {:ok, response} <- completed_action("explain_setting", %{key: key}, ctx) do
      {:ok, {:explanation, response.setting}}
    end
  end

  defp route(["set", key, value], ctx) do
    with {:ok, parsed} <- parse_value(key, value),
         {:ok, response} <-
           completed_action("update_setting", %{key: key, value: parsed}, ctx) do
      {:ok, {:written, response.setting}}
    end
  end

  defp route(["providers", "list"], ctx) do
    with {:ok, response} <-
           completed_action("list_provider_profiles", operator_report_params(), ctx) do
      {:ok, {:providers, response.providers}}
    end
  end

  defp route(["doctor"], ctx) do
    with {:ok, response} <- completed_action("settings_doctor", operator_report_params(), ctx) do
      {:ok, {:settings_doctor, response.message}}
    end
  end

  defp route(["model-doctor"], ctx) do
    with {:ok, response} <- completed_action("model_doctor", operator_report_params(), ctx) do
      {:ok, {:model_doctor, response.message}}
    end
  end

  defp route(["providers", "set-key", provider], ctx) do
    with {:ok, api_key} <- read_provider_key(provider),
         {:ok, response} <-
           completed_action(
             "set_provider_credential",
             %{provider: provider, mode: :set_secret, api_key: api_key},
             ctx
           ) do
      {:ok, {:provider_key, response.provider, response}}
    end
  end

  defp route(["providers", "set-key", _provider, _secret | _rest], _ctx) do
    {:raise,
     "Provider keys must be supplied through stdin or an interactive prompt, not as arguments."}
  end

  defp route(_args, _ctx), do: {:usage, @usage}

  defp render({:ok, settings}) when is_list(settings) do
    Render.ok(
      Enum.map(settings, fn setting ->
        "#{setting.key}=#{inspect(setting.value)} source=#{setting.source} writable=#{setting.writable?}"
      end)
    )
  end

  defp render({:ok, {:setting, setting}}), do: Render.ok(setting_lines(setting))

  defp render({:ok, {:explanation, setting}}) do
    Render.ok(
      setting_lines(setting) ++
        ["Writable: #{setting.writable?}", "Layers:"] ++
        Enum.map(setting.layers, &"- #{&1.source}: #{inspect(&1.value)}")
    )
  end

  defp render({:ok, {:written, setting}}) do
    Render.ok(
      [
        "Updated: #{setting.key}=#{inspect(setting.value)}",
        "Source: #{setting.source}"
      ] ++ diagnostic_lines(setting.diagnostics)
    )
  end

  defp render({:ok, {:providers, providers}}) do
    Render.ok(
      Enum.map(providers, fn provider ->
        "#{provider.name} type=#{provider.type} enabled=#{provider.enabled} credential=#{provider.credential_status}"
      end)
    )
  end

  defp render({:ok, {:provider_key, provider, result}}) do
    Render.ok(
      ["#{provider} credential=#{result.credential_status}"] ++
        diagnostic_lines(Map.get(result, :diagnostics, []))
    )
  end

  defp render({:ok, {:settings_doctor, message}}), do: Render.ok(message)
  defp render({:ok, {:model_doctor, message}}), do: Render.ok(message)
  defp render({:usage, usage}), do: Render.usage(usage)
  defp render({:raise, message}), do: Render.error(message)
  defp render({:error, reason}), do: Render.error("Settings command failed: #{inspect(reason)}")

  defp setting_lines(setting) do
    ["#{setting.key}=#{inspect(setting.value)}", "Source: #{setting.source}"]
  end

  defp read_provider_key(provider) do
    case IO.gets("") do
      :eof -> prompt_provider_key(provider)
      {:error, reason} -> {:error, reason}
      value -> normalize_provider_key(value)
    end
  end

  defp prompt_provider_key(provider) do
    IO.write("API key for #{provider}: ")

    case IO.gets("") do
      :eof -> {:error, :empty_provider_key}
      {:error, reason} -> {:error, reason}
      value -> normalize_provider_key(value)
    end
  end

  defp normalize_provider_key(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: {:error, :empty_provider_key}, else: {:ok, value}
  end

  defp completed_action(action_name, params, ctx) do
    ActionHelper.completed_action(action_name, params, ctx)
  end

  defp operator_report_params do
    %{render_mode: "operator_report", surface_policy_affordance: true}
  end

  defp parse_value(key, value) do
    cond do
      channel_identity_map_setting?(key) -> parse_channel_identity_map(value)
      string_list_setting?(key) -> parse_string_list(value)
      string_map_setting?(key) -> parse_string_map(value)
      true -> {:ok, parse_scalar_value(value)}
    end
  end

  defp parse_string_list(value) do
    trimmed = String.trim(value)

    if String.starts_with?(trimmed, "[") do
      parse_json_string_list(trimmed)
    else
      list =
        value
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      {:ok, list}
    end
  end

  defp parse_json_string_list(value) do
    case Jason.decode(value) do
      {:ok, items} when is_list(items) ->
        if Enum.all?(items, &is_binary/1) do
          {:ok, items}
        else
          {:raise, "Expected #{value} to be a JSON array of strings."}
        end

      {:ok, _other} ->
        {:raise, "Expected #{value} to be a JSON array of strings."}

      {:error, reason} ->
        {:raise, "Invalid JSON string list: #{Exception.message(reason)}"}
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
      %{type: type}
      when type in [
             :string_list,
             :profile_ref_list,
             :public_tool_list,
             :public_memory_namespace_list
           ] ->
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

  defp channel_identity_map_setting?(key) do
    case Map.get(Settings.schema(), key) do
      %{type: :channel_identity_map} -> true
      _schema -> false
    end
  end

  defp parse_channel_identity_map(value) do
    case Jason.decode(value) do
      {:ok, entries} when is_list(entries) ->
        {:ok, entries}

      {:ok, _other} ->
        {:raise, "Expected channel identity map settings to be a JSON array of objects."}

      {:error, reason} ->
        {:raise, "Invalid channel identity map JSON: #{Exception.message(reason)}"}
    end
  end

  defp parse_string_map(value) do
    case Jason.decode(value) do
      {:ok, map} when is_map(map) ->
        validate_string_map(map)

      {:ok, _other} ->
        {:raise, "Expected MCP map settings to be a JSON object with string values."}

      {:error, reason} ->
        {:raise, "Invalid JSON map: #{Exception.message(reason)}"}
    end
  end

  defp validate_string_map(map) do
    if Enum.all?(map, fn {key, value} -> is_binary(key) and is_binary(value) end) do
      {:ok, map}
    else
      {:raise, "Expected MCP map settings to be a JSON object with string values."}
    end
  end

  defp parse_float_or_string(value) do
    case Float.parse(value) do
      {float, ""} -> float
      _other -> value
    end
  end

  defp diagnostic_lines([]), do: []

  defp diagnostic_lines(diagnostics) do
    Enum.map(diagnostics, fn
      %{audit_path: audit_path} -> "Audit: #{audit_path}"
      diagnostic -> "Diagnostic: #{inspect(diagnostic)}"
    end)
  end
end
