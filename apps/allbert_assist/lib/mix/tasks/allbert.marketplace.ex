defmodule Mix.Tasks.Allbert.Marketplace do
  @moduledoc """
  Operate Marketplace Lite.

  M2 ships the minimal operator-validation commands. M3 completes the
  show/verify/mirror/doctor CLI surface after the full seed catalog lands.

  ## Usage

      mix allbert.marketplace list [--kind KIND]
      mix allbert.marketplace show ENTRY_ID
      mix allbert.marketplace install ENTRY_ID [--version VERSION]
      mix allbert.marketplace installed
      mix allbert.marketplace rollback ENTRY_ID
      mix allbert.marketplace verify ENTRY_ID
      mix allbert.marketplace mirror
      mix allbert.marketplace doctor
  """

  use Mix.Task

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Marketplace.Catalog
  alias AllbertAssist.Runtime.Response

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

  defp dispatch(["show" | rest]) do
    {opts, rest, invalid} = OptionParser.parse(rest, strict: [version: :string])
    reject_invalid!(invalid)

    case rest do
      [entry_id] ->
        params =
          %{} |> maybe_put(:version, Keyword.get(opts, :version)) |> Map.put(:entry_id, entry_id)

        with {:ok, response} <- completed_action("inspect_marketplace_entry", params) do
          {:ok, {:show, response.result}}
        end

      _other ->
        Mix.raise("usage: mix allbert.marketplace show ENTRY_ID [--version VERSION]")
    end
  end

  defp dispatch(["install" | rest]) do
    {opts, rest, invalid} = OptionParser.parse(rest, strict: [version: :string])
    reject_invalid!(invalid)

    case rest do
      [entry_id] ->
        params =
          %{} |> maybe_put(:version, Keyword.get(opts, :version)) |> Map.put(:entry_id, entry_id)

        with {:ok, response} <- completed_action("install_marketplace_bundle", params) do
          {:ok, {:installed, response.result.installed}}
        end

      _other ->
        Mix.raise("usage: mix allbert.marketplace install ENTRY_ID [--version VERSION]")
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

  defp dispatch(["verify", entry_id]) do
    with {:ok, response} <-
           completed_action("verify_marketplace_bundle_hash", %{entry_id: entry_id}) do
      {:ok, {:verified, response.result}}
    end
  end

  defp dispatch(["mirror"]) do
    with {:ok, response} <- completed_action("list_marketplace_entries", %{}) do
      {:ok, {:mirrored, Catalog.mirror_path(), length(response.result.entries)}}
    end
  end

  defp dispatch(["doctor" | rest]) do
    {opts, rest, invalid} = OptionParser.parse(rest, strict: [verbose: :boolean])
    reject_invalid!(invalid)
    reject_rest!(rest)

    params = %{verbose: Keyword.get(opts, :verbose, false)}

    with {:ok, response} <- action_response("marketplace_doctor", params) do
      {:ok, {:doctor, response}}
    end
  end

  defp dispatch(_args) do
    Mix.raise("""
    Usage:
      mix allbert.marketplace list [--kind KIND]
      mix allbert.marketplace show ENTRY_ID
      mix allbert.marketplace install ENTRY_ID [--version VERSION]
      mix allbert.marketplace installed
      mix allbert.marketplace rollback ENTRY_ID
      mix allbert.marketplace verify ENTRY_ID
      mix allbert.marketplace mirror
      mix allbert.marketplace doctor
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

  defp print_result({:ok, {:show, result}}) do
    entry = Map.fetch!(result, :entry)
    manifest = Map.fetch!(result, :bundle_manifest)

    Mix.shell().info("Entry: #{entry["id"]}")
    Mix.shell().info("Name: #{entry["name"]}")
    Mix.shell().info("Version: #{entry["version"]}")
    Mix.shell().info("Kind: #{entry["kind"]}")
    Mix.shell().info("Description: #{entry["description"]}")
    Mix.shell().info("Bundle hash: #{entry["bundle_hash"]}")
    Mix.shell().info("Marketplace URI: #{entry["marketplace_uri"]}")
    Mix.shell().info("Installable: #{Map.fetch!(result, :installable?)}")
    print_install_target(manifest)
    print_manifest_files(manifest)
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

  defp print_result({:ok, {:verified, result}}) do
    entry = Map.fetch!(result, :entry)
    manifest = Map.fetch!(result, :bundle_manifest)

    Mix.shell().info(
      "#{entry["id"]} version=#{entry["version"]} status=#{result.status} bundle_hash=#{manifest["bundle_hash"]}"
    )
  end

  defp print_result({:ok, {:mirrored, path, count}}) do
    Mix.shell().info("Marketplace index mirrored to #{path} entries=#{count}")
  end

  defp print_result({:ok, {:doctor, response}}) do
    result = doctor_result(response)

    Mix.shell().info(
      "Marketplace doctor status=#{Response.status(response)} live_check_status=#{result[:live_check_status] || result["live_check_status"]}"
    )

    result
    |> diagnostics()
    |> Enum.each(fn diagnostic ->
      Mix.shell().info(
        "Diagnostic #{diagnostic_code(diagnostic)}: #{diagnostic_message(diagnostic)}"
      )
    end)
  end

  defp print_result({:error, reason}),
    do: Mix.raise("Marketplace command failed: #{inspect(reason)}")

  defp completed_action(action_name, params) do
    with {:ok, response} <- action_response(action_name, params) do
      case Response.status(response) do
        :completed ->
          {:ok, response}

        :needs_confirmation ->
          # v0.54 M10: this action is now confirmation-gated. Surface the approval
          # path instead of failing.
          id = Map.get(response, :confirmation_id) || get_in(response, [:confirmation, "id"])

          Mix.shell().info(
            "Needs confirmation. Approve with: mix allbert.confirmations approve #{id}"
          )

          {:ok, response}

        _status ->
          {:error, response_error(response)}
      end
    end
  end

  defp action_response(action_name, params), do: Runner.run(action_name, params, context())

  defp response_error(%{error: error}), do: error
  defp response_error(%{message: message}), do: message

  defp print_install_target(%{"resolved_install_target" => target}),
    do: Mix.shell().info("Install target: #{target}")

  defp print_install_target(_manifest), do: :ok

  defp print_manifest_files(%{"files" => files}) do
    Mix.shell().info("Files:")

    Enum.each(files, fn file ->
      Mix.shell().info("  #{file["path"]} sha256=#{file["sha256"]}")
    end)
  end

  defp doctor_result(%{doctor: doctor}) when is_map(doctor) and map_size(doctor) > 0, do: doctor
  defp doctor_result(%{result: result}) when is_map(result), do: result
  defp doctor_result(response), do: response

  defp diagnostics(%{diagnostics: diagnostics}) when is_list(diagnostics), do: diagnostics
  defp diagnostics(%{"diagnostics" => diagnostics}) when is_list(diagnostics), do: diagnostics
  defp diagnostics(_result), do: []

  defp diagnostic_code(%{code: code}), do: code
  defp diagnostic_code(%{"code" => code}), do: code
  defp diagnostic_code(_diagnostic), do: :unknown

  defp diagnostic_message(%{message: message}), do: message
  defp diagnostic_message(%{"message" => message}), do: message
  defp diagnostic_message(diagnostic), do: inspect(diagnostic)

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
