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

  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Secrets

  @shortdoc "Inspect and update Allbert Settings Central"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    args
    |> dispatch()
    |> print_result()
  end

  defp dispatch(["list"]), do: Settings.list()

  defp dispatch(["get", key]) do
    with {:ok, setting} <- Settings.resolve(key) do
      {:ok, {:setting, setting}}
    end
  end

  defp dispatch(["explain", key]) do
    with {:ok, setting} <- Settings.explain(key) do
      {:ok, {:explanation, setting}}
    end
  end

  defp dispatch(["set", key, value]) do
    with {:ok, setting} <- Settings.put(key, parse_value(value), context()) do
      {:ok, {:written, setting}}
    end
  end

  defp dispatch(["providers", "list"]) do
    with {:ok, providers} <- Settings.list_provider_profiles() do
      {:ok, {:providers, providers}}
    end
  end

  defp dispatch(["providers", "set-key", provider]) do
    secret_ref = "secret://providers/#{provider}/api_key"

    with {:ok, api_key} <- read_provider_key(provider),
         {:ok, result} <- Secrets.put_secret(secret_ref, api_key, context()) do
      {:ok, {:provider_key, provider, result}}
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
    Mix.shell().info("#{provider} credential=#{result.status}")
    print_diagnostics(Map.get(result, :diagnostics, []))
  end

  defp print_result({:error, reason}) do
    Mix.raise("Settings command failed: #{inspect(reason)}")
  end

  defp read_provider_key(provider) do
    case IO.gets("") do
      :eof -> prompt_provider_key(provider)
      nil -> prompt_provider_key(provider)
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

  defp parse_value("true"), do: true
  defp parse_value("false"), do: false

  defp parse_value(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _other -> parse_float_or_string(value)
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
