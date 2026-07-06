defmodule AllbertAssist.CLI.Areas.Skills do
  @moduledoc """
  Release-safe `skills` admin dispatch (v0.62 M8.7).

  The single source of truth for `mix allbert.skills` and `allbert admin skills`:
  `dispatch/2` parses the sub-argv, routes to the same registered actions the Mix
  task used, and returns `{rendered_output, exit_code}` — no `Mix.*` calls, so it
  runs inside the packaged release. `Mix.Tasks.Allbert.Skills` is a thin wrapper
  that prints the output through `Mix.shell/0`.
  """

  alias AllbertAssist.Actions.ErrorExtraction
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.CLI.Areas.Render
  alias AllbertAssist.Confirmations.OnlineSkillMetadata
  alias AllbertAssist.Confirmations.SkillScriptMetadata
  alias AllbertAssist.Surfaces.ContextBuilder

  @usage """
  Usage:
    mix allbert.skills validate PATH
    mix allbert.skills list
    mix allbert.skills create NAME ACTION PERMISSION DESCRIPTION... [--root ROOT] [--overwrite]
    mix allbert.skills run SKILL SCRIPT [--cwd PATH] [--timeout MS] [--max-output-bytes BYTES] -- [ARGS...]
    mix allbert.skills search-online QUERY...
    mix allbert.skills show-online SOURCE/ID
    mix allbert.skills audit-online SOURCE/ID
    mix allbert.skills import-online SOURCE/ID
    mix allbert.skills import-url URL
    mix allbert.skills import-local PATH
  """

  @spec dispatch([String.t()], map() | nil) :: {String.t(), non_neg_integer()}
  def dispatch(argv, context \\ nil) do
    argv
    |> route(context || default_context())
    |> render()
  end

  defp default_context, do: ContextBuilder.cli_context(surface: "allbert admin skills")

  # -- routing ---------------------------------------------------------------

  defp route([], ctx), do: route(["list"], ctx)

  defp route(["validate", path], ctx) do
    with {:ok, response} <- completed_action("validate_skill", %{path: path}, ctx) do
      {:ok, {:validation, response.validation}}
    end
  end

  defp route(["list"], ctx) do
    with {:ok, response} <- completed_action("list_skills", %{}, ctx) do
      {:ok, {:list, response.skills}}
    end
  end

  defp route(["create", name, action, permission | rest], ctx) do
    {description_parts, opts} = parse_create_options(rest)

    params =
      %{
        name: name,
        action: action,
        permission: permission,
        description: Enum.join(description_parts, " ")
      }
      |> maybe_put(:root, Map.get(opts, :root))
      |> maybe_put(:overwrite, Map.get(opts, :overwrite))

    with {:ok, response} <- completed_action("create_skill", params, ctx) do
      {:ok, {:created, response}}
    end
  end

  defp route(["run", skill_name, script_path | rest], ctx) do
    with {:ok, {opts, script_args}} <- parse_run_options(rest),
         params =
           %{
             skill_name: skill_name,
             script_path: script_path,
             args: script_args
           }
           |> maybe_put(:cwd, Map.get(opts, :cwd))
           |> maybe_put(:timeout_ms, Map.get(opts, :timeout_ms))
           |> maybe_put(:max_output_bytes, Map.get(opts, :max_output_bytes)),
         {:ok, response} <- runnable_action("run_skill_script", params, ctx) do
      {:ok, {:run, response}}
    end
  end

  defp route(["search-online" | query_parts], ctx) when query_parts != [] do
    params = %{query: Enum.join(query_parts, " ")}

    with {:ok, response} <- runnable_action("search_online_skills", params, ctx) do
      {:ok, {:online, response}}
    end
  end

  defp route(["show-online", ref], ctx) do
    with {:ok, response} <- runnable_action("show_online_skill", online_ref(ref), ctx) do
      {:ok, {:online, response}}
    end
  end

  defp route(["audit-online", ref], ctx) do
    with {:ok, response} <- runnable_action("audit_online_skill", online_ref(ref), ctx) do
      {:ok, {:online, response}}
    end
  end

  defp route(["import-online", ref], ctx) do
    with {:ok, response} <- runnable_action("import_online_skill", online_ref(ref), ctx) do
      {:ok, {:online, response}}
    end
  end

  defp route(["import-url", url], ctx) do
    with {:ok, response} <- runnable_action("import_remote_skill", %{url: url}, ctx) do
      {:ok, {:online, response}}
    end
  end

  defp route(["import-local", path], ctx) do
    with {:ok, response} <- runnable_action("import_local_skill", %{path: path}, ctx) do
      {:ok, {:online, response}}
    end
  end

  defp route(_args, _ctx), do: {:usage, @usage}

  # -- rendering -------------------------------------------------------------

  defp render({:ok, {:validation, validation}}), do: Render.ok(validation_lines(validation))

  defp render({:ok, {:list, skills}}) do
    Render.ok(
      ["Skills: #{length(skills)}"] ++
        Enum.map(skills, fn skill ->
          "- #{skill.name} source=#{skill.source_scope} trust=#{skill.trust_status} plugin=#{skill.plugin_id || "-"} action=#{primary_action(skill)}"
        end)
    )
  end

  defp render({:ok, {:created, response}}) do
    skill = response.skill

    Render.ok(
      confirmation_notice(response) ++
        ["Created: #{skill.skill_md_path}"] ++
        validation_lines(skill.validation)
    )
  end

  defp render({:ok, {:run, response}}) do
    action_lines =
      response
      |> Map.get(:actions, [])
      |> List.first()
      |> SkillScriptMetadata.action_lines()

    Render.ok(
      ["Status: #{response.status}", response.message] ++
        action_lines ++
        confirmation_id_line(response)
    )
  end

  defp render({:ok, {:online, response}}) do
    Render.ok(
      ["Status: #{response.status}", response.message] ++
        online_lines(response) ++
        confirmation_id_line(response)
    )
  end

  defp render({:usage, usage}), do: Render.usage(usage)
  defp render({:error, {:arg, message}}), do: Render.error(message)
  defp render({:error, reason}), do: Render.error("Skills command failed: #{inspect(reason)}")

  defp validation_lines(validation) do
    [
      "Validation: #{validation.status}",
      "Path: #{validation.path}",
      "Name: #{validation.name || "unknown"}",
      "Contract: #{validation.contract.validation_status}",
      "Execution eligible: #{validation.contract.execution_eligible?}"
    ] ++ diagnostics_lines(validation.diagnostics)
  end

  defp diagnostics_lines([]), do: ["Diagnostics: none"]

  defp diagnostics_lines(diagnostics) do
    ["Diagnostics:"] ++
      Enum.map(diagnostics, fn diagnostic ->
        "- #{diagnostic.severity} #{diagnostic.code}: #{diagnostic.message}"
      end)
  end

  defp confirmation_notice(%{status: :needs_confirmation} = response) do
    # v0.54 M10: create_skill is now confirmation-gated.
    id = Map.get(response, :confirmation_id) || get_in(response, [:confirmation, "id"])
    ["Needs confirmation. Approve with: mix allbert.confirmations approve #{id}"]
  end

  defp confirmation_notice(_response), do: []

  defp confirmation_id_line(response) do
    if Map.get(response, :confirmation_id) do
      ["Confirmation: #{response.confirmation_id}"]
    else
      []
    end
  end

  # -- action helpers --------------------------------------------------------

  defp completed_action(action_name, params, ctx) do
    case Runner.run(action_name, params, context(ctx)) do
      {:ok, %{status: :completed} = response} ->
        {:ok, response}

      {:ok, %{status: :needs_confirmation} = response} ->
        {:ok, response}

      {:ok, response} ->
        {:error, response_error(response)}
    end
  end

  defp runnable_action(action_name, params, ctx) do
    case Runner.run(action_name, params, context(ctx)) do
      {:ok, %{status: status} = response}
      when status in [:needs_confirmation, :denied, :completed, :failed, :timed_out] ->
        {:ok, response}

      {:ok, response} ->
        {:error, response_error(response)}
    end
  end

  defp response_error(response), do: ErrorExtraction.from_response(response)

  defp context(ctx) do
    ContextBuilder.cli_context(surface: surface(ctx), selected_skill: nil)
  end

  defp surface(ctx), do: Map.get(ctx, :surface) || "allbert admin skills"

  # -- online rendering helpers ----------------------------------------------

  defp online_ref(ref) do
    case String.split(ref, "/", parts: 2) do
      [source, id] -> %{source: source, id: id}
      [id] -> %{source: "skills_sh", id: id}
    end
  end

  defp online_lines(response) do
    cond do
      is_map(Map.get(response, :online_skill_search)) ->
        search_lines(response.online_skill_search)

      is_map(Map.get(response, :online_skill_detail)) ->
        detail_lines(response.online_skill_detail)

      is_map(Map.get(response, :online_skill_audit)) ->
        audit_lines(response.online_skill_audit)

      is_map(Map.get(response, :online_skill_import)) ->
        import_lines(response.online_skill_import)

      is_map(Map.get(response, :skill_import)) ->
        import_lines(response.skill_import)

      is_map(Map.get(response, :result)) and Map.get(response.result, :target_root) ->
        import_lines(response.result)

      true ->
        response
        |> Map.get(:confirmation)
        |> OnlineSkillMetadata.lines()
    end
  end

  defp search_lines(search) do
    [
      "Source: #{get_in(search, [:source, :id])}",
      "Results: #{length(Map.get(search, :results, []))}"
    ] ++
      Enum.map(Map.get(search, :results, []), fn result ->
        "- #{result.id}: #{result.description || result.title}"
      end)
  end

  defp detail_lines(detail) do
    [
      "Skill id: #{detail.id}",
      "Source URL: #{detail.source_url}",
      "Files: #{Enum.join(Map.get(detail, :files, []), ", ")}",
      "SKILL.md present: #{detail.skill_md_present?}"
    ]
  end

  defp audit_lines(audit) do
    [
      "Audit: #{audit.status}",
      "Skill: #{audit.skill_name || "unknown"}",
      "Import eligible: #{audit.import_eligible?}",
      "Warnings: #{Enum.join(Enum.map(audit.warnings, &to_string/1), ", ")}"
    ]
  end

  defp import_lines(import) do
    [
      "Imported target: #{import.target_root}",
      "Manifest: #{import.manifest_path}",
      "Enabled: #{import.enabled?}",
      "Trusted: #{import.trusted?}"
    ]
  end

  defp primary_action(skill) do
    skill
    |> get_in([:capability_contract, :actions])
    |> case do
      [action | _rest] -> action
      _other -> "-"
    end
  end

  # -- argument parsing helpers ----------------------------------------------

  defp parse_create_options(args) do
    parse_create_options(args, [], %{})
  end

  defp parse_create_options(["--root", root | rest], description, opts) do
    parse_create_options(rest, description, Map.put(opts, :root, root))
  end

  defp parse_create_options(["--overwrite" | rest], description, opts) do
    parse_create_options(rest, description, Map.put(opts, :overwrite, true))
  end

  defp parse_create_options([part | rest], description, opts) do
    parse_create_options(rest, [part | description], opts)
  end

  defp parse_create_options([], description, opts), do: {Enum.reverse(description), opts}

  defp parse_run_options(args) do
    {option_args, script_args} =
      case Enum.split_while(args, &(&1 != "--")) do
        {option_args, ["--" | script_args]} -> {option_args, script_args}
        {option_args, []} -> {option_args, []}
      end

    case parse_run_option_args(option_args, %{}) do
      {:ok, opts} -> {:ok, {opts, script_args}}
      {:error, _reason} = error -> error
    end
  end

  defp parse_run_option_args(["--cwd", cwd | rest], opts) do
    parse_run_option_args(rest, Map.put(opts, :cwd, cwd))
  end

  defp parse_run_option_args(["--timeout", value | rest], opts) do
    case parse_positive_integer("--timeout", value) do
      {:ok, integer} -> parse_run_option_args(rest, Map.put(opts, :timeout_ms, integer))
      {:error, _reason} = error -> error
    end
  end

  defp parse_run_option_args(["--max-output-bytes", value | rest], opts) do
    case parse_positive_integer("--max-output-bytes", value) do
      {:ok, integer} -> parse_run_option_args(rest, Map.put(opts, :max_output_bytes, integer))
      {:error, _reason} = error -> error
    end
  end

  defp parse_run_option_args([unknown | _rest], _opts) do
    {:error, {:arg, "Unknown allbert.skills run option: #{unknown}"}}
  end

  defp parse_run_option_args([], opts), do: {:ok, opts}

  defp parse_positive_integer(flag, value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _other -> {:error, {:arg, "#{flag} must be a positive integer"}}
    end
  end

  defp maybe_put(params, _key, nil), do: params
  defp maybe_put(params, key, value), do: Map.put(params, key, value)
end
