defmodule Mix.Tasks.Allbert.Confirmations do
  @moduledoc """
  Inspect and resolve durable Allbert confirmation requests.

  ## Usage

      mix allbert.confirmations list
      mix allbert.confirmations list --resolved
      mix allbert.confirmations show CONFIRMATION_ID
      mix allbert.confirmations approve CONFIRMATION_ID [--reason REASON...] [--remember SCOPE] [--resource-index N|--remember-all] [--grant-expires-at ISO8601]
      mix allbert.confirmations deny CONFIRMATION_ID [--reason REASON...]
      mix allbert.confirmations expire
  """

  use Mix.Task

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Confirmations.ExternalRequestMetadata
  alias AllbertAssist.Confirmations.OnlineSkillMetadata
  alias AllbertAssist.Confirmations.PackageInstallMetadata
  alias AllbertAssist.Confirmations.ResourceMetadata
  alias AllbertAssist.Confirmations.ShellCommandMetadata
  alias AllbertAssist.Confirmations.SkillScriptMetadata

  @shortdoc "Inspect and resolve Allbert confirmation requests"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    args
    |> dispatch()
    |> print_result()
  end

  defp dispatch(["list" | opts]) do
    with {:ok, response} <- completed_action("list_confirmations", %{status: list_status(opts)}) do
      {:ok, {:list, response.confirmations}}
    end
  end

  defp dispatch(["show", id]) do
    with {:ok, response} <- completed_action("show_confirmation", %{id: id}) do
      {:ok, {:show, response.confirmation}}
    end
  end

  defp dispatch(["approve", id | rest]) do
    params = parse_approve_options(rest, %{id: id})

    with {:ok, response} <- completed_action("approve_confirmation", params) do
      {:ok, {:resolved, response.confirmation}}
    end
  end

  defp dispatch(["deny", id | rest]) do
    params = %{id: id} |> maybe_put(:reason, parse_reason(rest))

    with {:ok, response} <- completed_action("deny_confirmation", params) do
      {:ok, {:resolved, response.confirmation}}
    end
  end

  defp dispatch(["expire"]) do
    with {:ok, response} <- completed_action("expire_confirmations", %{}) do
      {:ok, {:expired, response.confirmations}}
    end
  end

  defp dispatch(_args) do
    Mix.raise("""
    Usage:
      mix allbert.confirmations list [--resolved|--all]
      mix allbert.confirmations show CONFIRMATION_ID
      mix allbert.confirmations approve CONFIRMATION_ID [--reason REASON...] [--remember SCOPE] [--resource-index N|--remember-all] [--grant-expires-at ISO8601]
      mix allbert.confirmations deny CONFIRMATION_ID [--reason REASON...]
      mix allbert.confirmations expire
    """)
  end

  defp print_result({:ok, {:list, []}}), do: Mix.shell().info("No confirmations.")

  defp print_result({:ok, {:list, confirmations}}) do
    Enum.each(confirmations, fn confirmation ->
      Mix.shell().info(summary(confirmation))
      print_external_request_metadata(confirmation)
      print_online_skill_metadata(confirmation)
      print_package_install_metadata(confirmation)
      print_resource_metadata(confirmation)
      print_remembered_grants(confirmation)
      print_shell_metadata(confirmation)
      print_skill_script_metadata(confirmation)
      print_status_note(confirmation)
    end)
  end

  defp print_result({:ok, {:show, confirmation}}) do
    Mix.shell().info(summary(confirmation))
    Mix.shell().info("Requested: #{confirmation["requested_at"]}")
    Mix.shell().info("Expires: #{confirmation["expires_at"]}")
    Mix.shell().info("Origin: #{origin_text(confirmation)}")
    Mix.shell().info("Resolver: #{resolver_text(confirmation)}")
    Mix.shell().info("Trace: #{Map.get(confirmation, "source_trace_id", "none")}")
    print_external_request_metadata(confirmation)
    print_online_skill_metadata(confirmation)
    print_package_install_metadata(confirmation)
    print_resource_metadata(confirmation)
    print_remembered_grants(confirmation)
    print_shell_metadata(confirmation)
    print_skill_script_metadata(confirmation)
    print_status_note(confirmation)
  end

  defp print_result({:ok, {:resolved, confirmation}}) do
    Mix.shell().info("#{confirmation["id"]} status=#{confirmation["status"]}")
    Mix.shell().info("Resolver: #{resolver_text(confirmation)}")
    print_external_request_metadata(confirmation)
    print_online_skill_metadata(confirmation)
    print_package_install_metadata(confirmation)
    print_resource_metadata(confirmation)
    print_remembered_grants(confirmation)
    print_shell_metadata(confirmation)
    print_skill_script_metadata(confirmation)
    print_status_note(confirmation)
  end

  defp print_result({:ok, {:expired, confirmations}}) do
    Mix.shell().info("Expired: #{length(confirmations)}")
  end

  defp print_result({:error, reason}) do
    Mix.raise("Confirmations command failed: #{inspect(reason)}")
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
    |> Enum.find_value(&get_in(&1, [:confirmation_metadata, :error]))
    |> case do
      nil -> message
      error -> error
    end
  end

  defp response_error(%{message: message}), do: message

  defp context do
    %{actor: "local", channel: :cli, surface: "mix allbert.confirmations"}
  end

  defp list_status(["--resolved"]), do: "resolved"
  defp list_status(["--all"]), do: "all"
  defp list_status([]), do: "pending"
  defp list_status(_opts), do: "pending"

  defp parse_reason(["--reason" | reason_parts]) do
    reason_parts
    |> Enum.join(" ")
    |> String.trim()
    |> case do
      "" -> nil
      reason -> reason
    end
  end

  defp parse_reason([]), do: nil
  defp parse_reason(_rest), do: nil

  defp parse_approve_options([], params), do: params

  defp parse_approve_options(["--reason" | rest], params) do
    {reason_parts, rest} = Enum.split_while(rest, &(not String.starts_with?(&1, "--")))

    reason_parts
    |> Enum.join(" ")
    |> blank_to_nil()
    |> then(&maybe_put(params, :reason, &1))
    |> then(&parse_approve_options(rest, &1))
  end

  defp parse_approve_options(["--remember", scope | rest], params) do
    parse_approve_options(rest, maybe_put(params, :remember_scope, blank_to_nil(scope)))
  end

  defp parse_approve_options(["--resource-index", index | rest], params) do
    parse_approve_options(
      rest,
      Map.put(params, :resource_index, parse_non_negative_integer!(index, "--resource-index"))
    )
  end

  defp parse_approve_options(["--remember-all" | rest], params) do
    parse_approve_options(rest, Map.put(params, :remember_all, true))
  end

  defp parse_approve_options(["--grant-expires-at", expires_at | rest], params) do
    parse_approve_options(rest, maybe_put(params, :expires_at, blank_to_nil(expires_at)))
  end

  defp parse_approve_options([unknown | _rest] = rest, params) do
    if String.starts_with?(unknown, "--") do
      Mix.raise("Unknown approve option: #{unknown}")
    else
      maybe_put(params, :reason, rest |> Enum.join(" ") |> blank_to_nil())
    end
  end

  defp maybe_put(params, _key, nil), do: params
  defp maybe_put(params, key, value), do: Map.put(params, key, value)

  defp summary(confirmation) do
    "#{confirmation["id"]} status=#{confirmation["status"]} target=#{target_name(confirmation)} permission=#{confirmation["target_permission"]} origin=#{origin_text(confirmation)}"
  end

  defp target_name(confirmation) do
    get_in(confirmation, ["target_action", "name"]) || "unknown"
  end

  defp origin_text(confirmation) do
    origin = Map.get(confirmation, "origin", %{})
    "#{Map.get(origin, "actor", "local")}/#{Map.get(origin, "channel", "unknown")}"
  end

  defp resolver_text(confirmation) do
    resolution = Map.get(confirmation, "operator_resolution", %{}) || %{}

    "#{Map.get(resolution, "resolver_actor", "none")}/#{Map.get(resolution, "resolver_channel", "none")}"
  end

  defp print_status_note(confirmation) do
    case Confirmations.status_note(confirmation) do
      nil -> :ok
      note -> Mix.shell().info("Note: #{note}")
    end
  end

  defp print_shell_metadata(confirmation) do
    confirmation
    |> ShellCommandMetadata.lines()
    |> Enum.each(fn line -> Mix.shell().info(line) end)
  end

  defp print_external_request_metadata(confirmation) do
    confirmation
    |> ExternalRequestMetadata.lines()
    |> Enum.each(fn line -> Mix.shell().info(line) end)
  end

  defp print_package_install_metadata(confirmation) do
    confirmation
    |> PackageInstallMetadata.lines()
    |> Enum.each(fn line -> Mix.shell().info(line) end)
  end

  defp print_resource_metadata(confirmation) do
    confirmation
    |> ResourceMetadata.lines()
    |> Enum.each(fn line -> Mix.shell().info(line) end)
  end

  defp print_remembered_grants(confirmation) do
    confirmation
    |> get_in(["operator_resolution", "remembered_grants"])
    |> List.wrap()
    |> Enum.each(fn grant ->
      scope = Map.get(grant, "scope", %{}) || %{}

      Mix.shell().info(
        "Remembered grant: #{grant["id"]} #{grant["operation_class"]} #{grant["access_mode"]} #{scope["kind"]}:#{scope["value"]}"
      )
    end)
  end

  defp print_online_skill_metadata(confirmation) do
    confirmation
    |> OnlineSkillMetadata.lines()
    |> Enum.each(fn line -> Mix.shell().info(line) end)
  end

  defp print_skill_script_metadata(confirmation) do
    confirmation
    |> SkillScriptMetadata.lines()
    |> Enum.each(fn line -> Mix.shell().info(line) end)
  end

  defp blank_to_nil(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp blank_to_nil(value), do: value

  defp parse_non_negative_integer!(value, option) do
    case Integer.parse(to_string(value)) do
      {integer, ""} when integer >= 0 -> integer
      _other -> Mix.raise("#{option} must be a non-negative integer")
    end
  end
end
