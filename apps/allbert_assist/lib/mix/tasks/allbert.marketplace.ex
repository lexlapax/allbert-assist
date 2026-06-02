defmodule Mix.Tasks.Allbert.Marketplace do
  @moduledoc """
  Operate Marketplace Lite.

  M2 ships the minimal operator-validation commands. M3 completes the
  show/verify/mirror/doctor CLI surface after the full seed catalog lands.

  ## Usage

      mix allbert.marketplace list [--kind KIND]
      mix allbert.marketplace install ENTRY_ID
      mix allbert.marketplace installed
      mix allbert.marketplace rollback ENTRY_ID
  """

  use Mix.Task

  alias AllbertAssist.Actions.Runner

  @shortdoc "Operate Marketplace Lite"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    args
    |> dispatch()
    |> print_result()
  end

  defp dispatch(["list" | rest]) do
    {opts, rest, invalid} = OptionParser.parse(rest, strict: [kind: :string])
    reject_invalid!(invalid)
    reject_rest!(rest)

    params = %{} |> maybe_put(:kind, Keyword.get(opts, :kind))

    with {:ok, response} <- completed_action("list_marketplace_entries", params) do
      {:ok, {:list, response.result.entries}}
    end
  end

  defp dispatch(["install", entry_id]) do
    with {:ok, response} <- completed_action("install_marketplace_bundle", %{entry_id: entry_id}) do
      {:ok, {:installed, response.result.installed}}
    end
  end

  defp dispatch(["installed"]) do
    with {:ok, response} <- completed_action("list_installed_marketplace_bundles", %{}) do
      {:ok, {:installed_list, response.result.installed}}
    end
  end

  defp dispatch(["rollback", entry_id]) do
    with {:ok, response} <-
           completed_action("rollback_marketplace_install", %{entry_id: entry_id}) do
      {:ok, {:rolled_back, response.result.removed}}
    end
  end

  defp dispatch(_args) do
    Mix.raise("""
    Usage:
      mix allbert.marketplace list [--kind KIND]
      mix allbert.marketplace install ENTRY_ID
      mix allbert.marketplace installed
      mix allbert.marketplace rollback ENTRY_ID
    """)
  end

  defp print_result({:ok, {:list, []}}), do: Mix.shell().info("No marketplace entries.")

  defp print_result({:ok, {:list, entries}}) do
    Enum.each(entries, fn entry ->
      Mix.shell().info(
        "#{entry["id"]} version=#{entry["version"]} kind=#{entry["kind"]} bundle_hash=#{entry["bundle_hash"]}"
      )
    end)
  end

  defp print_result({:ok, {:installed, record}}) do
    Mix.shell().info(
      "#{record["entry_id"]} version=#{record["version"]} state=#{record["install_state"]} target=#{record["install_target"]}"
    )
  end

  defp print_result({:ok, {:installed_list, []}}),
    do: Mix.shell().info("No marketplace bundles installed.")

  defp print_result({:ok, {:installed_list, installed}}) do
    Enum.each(installed, fn record ->
      Mix.shell().info(
        "#{record["entry_id"]} version=#{record["version"]} state=#{record["install_state"]} target=#{record["install_target"]}"
      )
    end)
  end

  defp print_result({:ok, {:rolled_back, record}}) do
    Mix.shell().info("#{record["entry_id"]} version=#{record["version"]} rolled_back")
  end

  defp print_result({:error, reason}),
    do: Mix.raise("Marketplace command failed: #{inspect(reason)}")

  defp completed_action(action_name, params) do
    case Runner.run(action_name, params, context()) do
      {:ok, %{status: :completed} = response} -> {:ok, response}
      {:ok, response} -> {:error, response_error(response)}
    end
  end

  defp response_error(%{error: error}), do: error
  defp response_error(%{message: message}), do: message

  defp context do
    %{actor: "local", channel: :cli, surface: "mix allbert.marketplace"}
  end

  defp maybe_put(params, _key, nil), do: params
  defp maybe_put(params, key, value), do: Map.put(params, key, value)

  defp reject_invalid!([]), do: :ok
  defp reject_invalid!(invalid), do: Mix.raise("invalid option(s): #{inspect(invalid)}")
  defp reject_rest!([]), do: :ok
  defp reject_rest!(rest), do: Mix.raise("unexpected argument(s): #{Enum.join(rest, " ")}")
end
