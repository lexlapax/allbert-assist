defmodule Mix.Tasks.Allbert.Resources do
  @moduledoc """
  Inspect and revoke remembered Allbert resource grants.

  ## Usage

      mix allbert.resources grants list
      mix allbert.resources grants show GRANT_ID
      mix allbert.resources grants revoke GRANT_ID [--reason REASON...]
  """

  use Mix.Task

  alias AllbertAssist.Actions.Runner

  @shortdoc "Inspect and revoke remembered resource grants"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    args
    |> dispatch()
    |> print_result()
  end

  defp dispatch(["grants", "list"]) do
    with {:ok, response} <- completed_action("list_resource_grants", %{}) do
      {:ok, {:list, response.grants}}
    end
  end

  defp dispatch(["grants", "show", id]) do
    with {:ok, response} <- completed_action("show_resource_grant", %{id: id}) do
      {:ok, {:show, response.grant}}
    end
  end

  defp dispatch(["grants", "revoke", id | rest]) do
    params = %{id: id} |> maybe_put(:reason, parse_reason(rest))

    with {:ok, response} <- completed_action("revoke_resource_grant", params) do
      {:ok, {:revoked, response.grant}}
    end
  end

  defp dispatch(_args) do
    Mix.raise("""
    Usage:
      mix allbert.resources grants list
      mix allbert.resources grants show GRANT_ID
      mix allbert.resources grants revoke GRANT_ID [--reason REASON...]
    """)
  end

  defp print_result({:ok, {:list, []}}), do: Mix.shell().info("No remembered resource grants.")

  defp print_result({:ok, {:list, grants}}) do
    Enum.each(grants, &print_grant_summary/1)
  end

  defp print_result({:ok, {:show, grant}}) do
    print_grant_summary(grant)
    Mix.shell().info("Created: #{grant["created_at"]}")
    Mix.shell().info("Expires: #{Map.get(grant, "expires_at", "none")}")
    Mix.shell().info("Revoked: #{Map.get(grant, "revoked_at", "none")}")
    Mix.shell().info("Reason: #{Map.get(grant, "reason", "none")}")
    Mix.shell().info("Audit: #{Map.get(grant, "audit_path", "none")}")
  end

  defp print_result({:ok, {:revoked, grant}}) do
    Mix.shell().info("#{grant["id"]} status=revoked")
    print_grant_summary(grant)
  end

  defp print_result({:error, reason}) do
    Mix.raise("Resources command failed: #{inspect(reason)}")
  end

  defp print_grant_summary(grant) do
    scope = Map.get(grant, "scope", %{}) || %{}

    Mix.shell().info(
      "#{grant["id"]} status=#{grant_status(grant)} operation=#{grant["operation_class"]} access=#{grant["access_mode"]} resource_uri=#{grant["resource_uri"]} scope=#{scope["kind"]}:#{scope["value"]} consumer=#{Map.get(grant, "downstream_consumer", "none")}"
    )
  end

  defp grant_status(%{"revoked_at" => revoked_at}) when revoked_at not in [nil, ""],
    do: "revoked"

  defp grant_status(_grant), do: "active"

  defp completed_action(action_name, params) do
    case Runner.run(action_name, params, context()) do
      {:ok, %{status: :completed} = response} -> {:ok, response}
      {:ok, response} -> {:error, response_error(response)}
    end
  end

  defp response_error(%{error: error}), do: error
  defp response_error(%{message: message}), do: message

  defp context do
    %{actor: "local", channel: :cli, surface: "mix allbert.resources"}
  end

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

  defp maybe_put(params, _key, nil), do: params
  defp maybe_put(params, key, value), do: Map.put(params, key, value)
end
