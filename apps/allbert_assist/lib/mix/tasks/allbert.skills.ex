defmodule Mix.Tasks.Allbert.Skills do
  @moduledoc """
  Validate and scaffold local Allbert Agent Skills.

  ## Usage

      mix allbert.skills validate PATH
      mix allbert.skills create NAME ACTION PERMISSION DESCRIPTION... [--root ROOT] [--overwrite]
      mix allbert.skills run SKILL SCRIPT [--cwd PATH] [--timeout MS] [--max-output-bytes BYTES] -- [ARGS...]
      mix allbert.skills search-online QUERY...
      mix allbert.skills show-online SOURCE/ID
      mix allbert.skills audit-online SOURCE/ID
      mix allbert.skills import-online SOURCE/ID
  """

  use Mix.Task

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Confirmations.OnlineSkillMetadata
  alias AllbertAssist.Confirmations.SkillScriptMetadata

  @shortdoc "Validate and scaffold local Allbert Agent Skills"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    args
    |> dispatch()
    |> print_result()
  end

  defp dispatch(["validate", path]) do
    with {:ok, response} <- completed_action("validate_skill", %{path: path}) do
      {:ok, {:validation, response.validation}}
    end
  end

  defp dispatch(["create", name, action, permission | rest]) do
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

    with {:ok, response} <- completed_action("create_skill", params) do
      {:ok, {:created, response.skill}}
    end
  end

  defp dispatch(["run", skill_name, script_path | rest]) do
    {opts, script_args} = parse_run_options(rest)

    params =
      %{
        skill_name: skill_name,
        script_path: script_path,
        args: script_args
      }
      |> maybe_put(:cwd, Map.get(opts, :cwd))
      |> maybe_put(:timeout_ms, Map.get(opts, :timeout_ms))
      |> maybe_put(:max_output_bytes, Map.get(opts, :max_output_bytes))

    with {:ok, response} <- runnable_action("run_skill_script", params) do
      {:ok, {:run, response}}
    end
  end

  defp dispatch(["search-online" | query_parts]) when query_parts != [] do
    params = %{query: Enum.join(query_parts, " ")}

    with {:ok, response} <- runnable_action("search_online_skills", params) do
      {:ok, {:online, response}}
    end
  end

  defp dispatch(["show-online", ref]) do
    with {:ok, response} <- runnable_action("show_online_skill", online_ref(ref)) do
      {:ok, {:online, response}}
    end
  end

  defp dispatch(["audit-online", ref]) do
    with {:ok, response} <- runnable_action("audit_online_skill", online_ref(ref)) do
      {:ok, {:online, response}}
    end
  end

  defp dispatch(["import-online", ref]) do
    with {:ok, response} <- runnable_action("import_online_skill", online_ref(ref)) do
      {:ok, {:online, response}}
    end
  end

  defp dispatch(_args) do
    Mix.raise("""
    Usage:
      mix allbert.skills validate PATH
      mix allbert.skills create NAME ACTION PERMISSION DESCRIPTION... [--root ROOT] [--overwrite]
      mix allbert.skills run SKILL SCRIPT [--cwd PATH] [--timeout MS] [--max-output-bytes BYTES] -- [ARGS...]
      mix allbert.skills search-online QUERY...
      mix allbert.skills show-online SOURCE/ID
      mix allbert.skills audit-online SOURCE/ID
      mix allbert.skills import-online SOURCE/ID
    """)
  end

  defp print_result({:ok, {:validation, validation}}) do
    Mix.shell().info("Validation: #{validation.status}")
    Mix.shell().info("Path: #{validation.path}")
    Mix.shell().info("Name: #{validation.name || "unknown"}")
    Mix.shell().info("Contract: #{validation.contract.validation_status}")
    Mix.shell().info("Execution eligible: #{validation.contract.execution_eligible?}")
    print_diagnostics(validation.diagnostics)
  end

  defp print_result({:ok, {:created, skill}}) do
    Mix.shell().info("Created: #{skill.skill_md_path}")
    print_result({:ok, {:validation, skill.validation}})
  end

  defp print_result({:ok, {:run, response}}) do
    Mix.shell().info("Status: #{response.status}")
    Mix.shell().info(response.message)

    response
    |> Map.get(:actions, [])
    |> List.first()
    |> SkillScriptMetadata.action_lines()
    |> Enum.each(fn line -> Mix.shell().info(line) end)

    if Map.get(response, :confirmation_id) do
      Mix.shell().info("Confirmation: #{response.confirmation_id}")
    end
  end

  defp print_result({:ok, {:online, response}}) do
    Mix.shell().info("Status: #{response.status}")
    Mix.shell().info(response.message)

    response
    |> online_lines()
    |> Enum.each(fn line -> Mix.shell().info(line) end)

    if Map.get(response, :confirmation_id) do
      Mix.shell().info("Confirmation: #{response.confirmation_id}")
    end
  end

  defp print_result({:error, reason}) do
    Mix.raise("Skills command failed: #{inspect(reason)}")
  end

  defp completed_action(action_name, params) do
    case Runner.run(action_name, params, context()) do
      {:ok, %{status: :completed} = response} -> {:ok, response}
      {:ok, response} -> {:error, response_error(response)}
    end
  end

  defp response_error(%{error: error}), do: error
  defp response_error(%{message: message}), do: message

  defp runnable_action(action_name, params) do
    case Runner.run(action_name, params, context()) do
      {:ok, %{status: status} = response}
      when status in [:needs_confirmation, :denied, :completed, :failed, :timed_out] ->
        {:ok, response}

      {:ok, response} ->
        {:error, response_error(response)}
    end
  end

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

    {parse_run_option_args(option_args, %{}), script_args}
  end

  defp parse_run_option_args(["--cwd", cwd | rest], opts) do
    parse_run_option_args(rest, Map.put(opts, :cwd, cwd))
  end

  defp parse_run_option_args(["--timeout", value | rest], opts) do
    parse_run_option_args(
      rest,
      Map.put(opts, :timeout_ms, parse_positive_integer!("--timeout", value))
    )
  end

  defp parse_run_option_args(["--max-output-bytes", value | rest], opts) do
    parse_run_option_args(
      rest,
      Map.put(opts, :max_output_bytes, parse_positive_integer!("--max-output-bytes", value))
    )
  end

  defp parse_run_option_args([unknown | _rest], _opts) do
    Mix.raise("Unknown allbert.skills run option: #{unknown}")
  end

  defp parse_run_option_args([], opts), do: opts

  defp parse_positive_integer!(flag, value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _other -> Mix.raise("#{flag} must be a positive integer")
    end
  end

  defp maybe_put(params, _key, nil), do: params
  defp maybe_put(params, key, value), do: Map.put(params, key, value)

  defp context do
    %{actor: "local", channel: :cli, surface: "mix allbert.skills", selected_skill: nil}
  end

  defp print_diagnostics([]), do: Mix.shell().info("Diagnostics: none")

  defp print_diagnostics(diagnostics) do
    Mix.shell().info("Diagnostics:")

    Enum.each(diagnostics, fn diagnostic ->
      Mix.shell().info("- #{diagnostic.severity} #{diagnostic.code}: #{diagnostic.message}")
    end)
  end
end
