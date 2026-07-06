defmodule AllbertAssist.CLI.Areas.Marketplace do
  @moduledoc """
  Release-safe `marketplace` admin dispatch (v0.62 M8.7).

  The single source of truth for `mix allbert.marketplace` and
  `allbert admin marketplace`: `dispatch/2` parses the sub-argv, routes to the
  same registered actions the Mix task used, and returns
  `{rendered_output, exit_code}` — no `Mix.*` calls, so it runs inside the
  packaged release. `Mix.Tasks.Allbert.Marketplace` is a thin wrapper that starts
  the app and prints the output through `Mix.shell/0`.

  Argument-guard failures that the Mix task raised via `Mix.raise/1`
  (`invalid option(s)`, `unexpected argument(s)`) are surfaced as
  `throw({:marketplace_guard, message})`, caught in `dispatch/2`, and rendered as
  errors (exit 1); per-command and top-level usage fall-throughs render as usage
  (exit 2).
  """

  alias AllbertAssist.Actions.ErrorExtraction
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.CLI.Areas.Render
  alias AllbertAssist.Marketplace.Catalog
  alias AllbertAssist.Runtime.Response
  alias AllbertAssist.Surfaces.ContextBuilder

  @surface "allbert admin marketplace"

  @usage """
  Usage:
    mix allbert.marketplace list [--kind KIND]
    mix allbert.marketplace show ENTRY_ID
    mix allbert.marketplace install ENTRY_ID [--version VERSION]
    mix allbert.marketplace installed
    mix allbert.marketplace rollback ENTRY_ID
    mix allbert.marketplace verify ENTRY_ID
    mix allbert.marketplace mirror
    mix allbert.marketplace doctor
  """

  @spec dispatch([String.t()], map() | nil) :: {String.t(), non_neg_integer()}
  def dispatch(argv, context \\ nil) do
    ctx = context || default_context()

    result =
      try do
        route(argv, ctx)
      catch
        {:marketplace_guard, message} -> {:error, {:guard, message}}
      end

    render(result)
  end

  defp default_context, do: ContextBuilder.cli_context(surface: @surface)

  # ── Routing ────────────────────────────────────────────────────────────────

  defp route(["list" | rest], ctx) do
    {opts, rest, invalid} = OptionParser.parse(rest, strict: [kind: :string])
    reject_invalid!(invalid)
    reject_rest!(rest)

    params = %{} |> maybe_put(:kind, Keyword.get(opts, :kind))

    with {:ok, response} <- completed_action("list_marketplace_entries", params, ctx) do
      {:ok, {:list, response.result.entries}}
    end
  end

  defp route(["show" | rest], ctx) do
    {opts, rest, invalid} = OptionParser.parse(rest, strict: [version: :string])
    reject_invalid!(invalid)

    case rest do
      [entry_id] ->
        params =
          %{} |> maybe_put(:version, Keyword.get(opts, :version)) |> Map.put(:entry_id, entry_id)

        with {:ok, response} <- completed_action("inspect_marketplace_entry", params, ctx) do
          {:ok, {:show, response.result}}
        end

      _other ->
        {:usage, "usage: mix allbert.marketplace show ENTRY_ID [--version VERSION]"}
    end
  end

  defp route(["install" | rest], ctx) do
    {opts, rest, invalid} = OptionParser.parse(rest, strict: [version: :string])
    reject_invalid!(invalid)

    case rest do
      [entry_id] ->
        params =
          %{} |> maybe_put(:version, Keyword.get(opts, :version)) |> Map.put(:entry_id, entry_id)

        with {:ok, response} <- completed_action("install_marketplace_bundle", params, ctx) do
          {:ok, {:installed, response.result.installed}}
        end

      _other ->
        {:usage, "usage: mix allbert.marketplace install ENTRY_ID [--version VERSION]"}
    end
  end

  defp route(["installed"], ctx) do
    with {:ok, response} <- completed_action("list_installed_marketplace_bundles", %{}, ctx) do
      {:ok, {:installed_list, response.result.installed}}
    end
  end

  defp route(["rollback", entry_id], ctx) do
    with {:ok, response} <-
           completed_action("rollback_marketplace_install", %{entry_id: entry_id}, ctx) do
      {:ok, {:rolled_back, response.result.removed}}
    end
  end

  defp route(["verify", entry_id], ctx) do
    with {:ok, response} <-
           completed_action("verify_marketplace_bundle_hash", %{entry_id: entry_id}, ctx) do
      {:ok, {:verified, response.result}}
    end
  end

  defp route(["mirror"], ctx) do
    with {:ok, response} <- completed_action("list_marketplace_entries", %{}, ctx) do
      {:ok, {:mirrored, Catalog.mirror_path(), length(response.result.entries)}}
    end
  end

  defp route(["doctor" | rest], ctx) do
    {opts, rest, invalid} = OptionParser.parse(rest, strict: [verbose: :boolean])
    reject_invalid!(invalid)
    reject_rest!(rest)

    params = %{verbose: Keyword.get(opts, :verbose, false)}

    with {:ok, response} <- action_response("marketplace_doctor", params, ctx) do
      {:ok, {:doctor, response}}
    end
  end

  defp route(_args, _ctx), do: {:usage, @usage}

  # ── Rendering ────────────────────────────────────────────────────────────────

  defp render({:ok, {:list, []}}), do: Render.ok("No marketplace entries.")

  defp render({:ok, {:list, entries}}) do
    Render.ok(
      Enum.map(entries, fn entry ->
        "#{entry["id"]} version=#{entry["version"]} kind=#{entry["kind"]} bundle_hash=#{entry["bundle_hash"]}"
      end)
    )
  end

  defp render({:ok, {:show, result}}) do
    entry = Map.fetch!(result, :entry)
    manifest = Map.fetch!(result, :bundle_manifest)

    Render.ok(
      [
        "Entry: #{entry["id"]}",
        "Name: #{entry["name"]}",
        "Version: #{entry["version"]}",
        "Kind: #{entry["kind"]}",
        "Description: #{entry["description"]}",
        "Bundle hash: #{entry["bundle_hash"]}",
        "Marketplace URI: #{entry["marketplace_uri"]}",
        "Installable: #{Map.fetch!(result, :installable?)}"
      ] ++ install_target_lines(manifest) ++ manifest_files_lines(manifest)
    )
  end

  defp render({:ok, {:installed, record}}) do
    Render.ok(
      "#{record["entry_id"]} version=#{record["version"]} state=#{record["install_state"]} target=#{record["install_target"]}"
    )
  end

  defp render({:ok, {:installed_list, []}}), do: Render.ok("No marketplace bundles installed.")

  defp render({:ok, {:installed_list, installed}}) do
    Render.ok(
      Enum.map(installed, fn record ->
        "#{record["entry_id"]} version=#{record["version"]} state=#{record["install_state"]} target=#{record["install_target"]}"
      end)
    )
  end

  defp render({:ok, {:rolled_back, record}}) do
    Render.ok("#{record["entry_id"]} version=#{record["version"]} rolled_back")
  end

  defp render({:ok, {:verified, result}}) do
    entry = Map.fetch!(result, :entry)
    manifest = Map.fetch!(result, :bundle_manifest)

    Render.ok(
      "#{entry["id"]} version=#{entry["version"]} status=#{result.status} bundle_hash=#{manifest["bundle_hash"]}"
    )
  end

  defp render({:ok, {:mirrored, path, count}}) do
    Render.ok("Marketplace index mirrored to #{path} entries=#{count}")
  end

  defp render({:ok, {:doctor, response}}) do
    result = doctor_result(response)

    header =
      "Marketplace doctor status=#{Response.status(response)} live_check_status=#{result[:live_check_status] || result["live_check_status"]}"

    diagnostic_lines =
      result
      |> diagnostics()
      |> Enum.map(fn diagnostic ->
        "Diagnostic #{diagnostic_code(diagnostic)}: #{diagnostic_message(diagnostic)}"
      end)

    Render.ok([header | diagnostic_lines])
  end

  # v0.54 M10: install/rollback are confirmation-gated. Surface the approval path
  # (exit 0) instead of dereferencing the not-yet-written result. The Mix task
  # printed this notice as a side effect before falling through; here it is the
  # rendered output.
  defp render({:needs_confirmation, response}) do
    id = Map.get(response, :confirmation_id) || get_in(response, [:confirmation, "id"])
    Render.ok("Needs confirmation. Approve with: mix allbert.confirmations approve #{id}")
  end

  defp render({:error, {:guard, message}}), do: Render.error(message)

  defp render({:error, reason}),
    do: Render.error("Marketplace command failed: #{inspect(reason)}")

  defp render({:usage, usage}), do: Render.usage(usage)

  # ── Actions / read helpers ───────────────────────────────────────────────────

  defp completed_action(action_name, params, ctx) do
    with {:ok, response} <- action_response(action_name, params, ctx) do
      case Response.status(response) do
        :completed ->
          {:ok, response}

        :needs_confirmation ->
          {:needs_confirmation, response}

        _status ->
          {:error, response_error(response)}
      end
    end
  end

  defp action_response(action_name, params, ctx), do: Runner.run(action_name, params, ctx)

  defp response_error(response), do: ErrorExtraction.from_response(response)

  defp install_target_lines(%{"resolved_install_target" => target}),
    do: ["Install target: #{target}"]

  defp install_target_lines(_manifest), do: []

  defp manifest_files_lines(%{"files" => files}) do
    ["Files:"] ++
      Enum.map(files, fn file ->
        "  #{file["path"]} sha256=#{file["sha256"]}"
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

  defp maybe_put(params, _key, nil), do: params
  defp maybe_put(params, key, value), do: Map.put(params, key, value)

  # Raise a Mix-task-equivalent argument-guard failure; caught in `dispatch/2`
  # and rendered as an error (exit 1). Replaces the Mix task's `Mix.raise/1`
  # guards so the area module stays free of `Mix.*`.
  defp reject_invalid!([]), do: :ok

  defp reject_invalid!(invalid),
    do: throw({:marketplace_guard, "invalid option(s): #{inspect(invalid)}"})

  defp reject_rest!([]), do: :ok

  defp reject_rest!(rest),
    do: throw({:marketplace_guard, "unexpected argument(s): #{Enum.join(rest, " ")}"})
end
