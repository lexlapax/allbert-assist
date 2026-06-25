defmodule Mix.Tasks.Allbert.Security do
  @moduledoc """
  Inspect Security Central status.

  ## Usage

      mix allbert.security status
      mix allbert.security review --recent [--limit N]
  """

  use Mix.Task

  alias AllbertAssist.Actions.Helper, as: ActionHelper
  alias AllbertAssist.Surfaces.ContextBuilder

  @shortdoc "Inspect Security Central status"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    args
    |> dispatch()
    |> print_result()
  end

  defp dispatch(["status"]) do
    with {:ok, response} <- completed_action("security_status", %{}) do
      {:ok, response.security_status}
    end
  end

  defp dispatch(["review", "--recent" | opts]) do
    with {:ok, response} <- completed_action("security_review", %{limit: parse_limit(opts)}) do
      {:ok, {:review, response.security_review}}
    end
  end

  defp dispatch(_args) do
    Mix.raise("""
    Usage:
      mix allbert.security status
      mix allbert.security review --recent [--limit N]
    """)
  end

  defp print_result({:ok, status}) when is_map(status) do
    Mix.shell().info("Security Central")
    Mix.shell().info("Permissions:")

    Enum.each(status.permission_defaults, fn policy ->
      Mix.shell().info(
        "- #{policy.permission} setting=#{policy.setting_key || "built_in"} configured=#{inspect(policy.configured)} effective=#{policy.effective} source=#{policy.source} capped=#{policy.capped?}"
      )
    end)

    Mix.shell().info("Safety floors:")

    Enum.each(status.safety_floors, fn floor ->
      Mix.shell().info("- #{floor.permission}=#{floor.floor}")
    end)

    Mix.shell().info(
      "Secrets: providers=#{status.secret_status.providers} configured=#{status.secret_status.configured} missing=#{status.secret_status.missing}"
    )

    Mix.shell().info("Future boundaries:")

    Enum.each(status.future_boundaries, fn boundary ->
      Mix.shell().info("- #{boundary.name} #{boundary.milestone} #{boundary.status}")
    end)
  end

  defp print_result({:ok, {:review, review}}) do
    Mix.shell().info("Security Review")
    Mix.shell().info("Generated: #{review.generated_at}")
    Mix.shell().info("Limit: #{review.limit}")

    print_review_section("Recent confirmations", review.confirmations)
    print_review_section("Recent denials", review.denials)
    print_review_section("Recent imports", review.imports)
    print_review_section("Recent external calls", review.external_calls)
    print_redaction_incidents(review.redaction_incidents)
    print_emergency_switches(review.emergency_switches)
  end

  defp print_result({:error, reason}) do
    Mix.raise("Security command failed: #{inspect(reason)}")
  end

  defp completed_action(action_name, params) do
    ActionHelper.completed_action(action_name, params, context())
  end

  defp parse_limit(["--limit", value | _rest]), do: value
  defp parse_limit([]), do: 10

  defp parse_limit(other) do
    Mix.raise("Unknown security review option(s): #{Enum.join(other, " ")}")
  end

  defp print_review_section(title, []), do: Mix.shell().info("#{title}: none")

  defp print_review_section(title, items) do
    Mix.shell().info("#{title}:")

    Enum.each(items, fn item ->
      Mix.shell().info(
        "- #{item.id} status=#{item.status} action=#{Map.get(item, :target_action, "unknown")} permission=#{Map.get(item, :target_permission, "unknown")} decision=#{get_in(item, [:security_decision, :decision]) || "unknown"}"
      )
    end)
  end

  defp print_redaction_incidents([]), do: Mix.shell().info("Redaction incidents: none")

  defp print_redaction_incidents(items) do
    Mix.shell().info("Redaction incidents:")

    Enum.each(items, fn item ->
      Mix.shell().info(
        "- #{item.category} id=#{item.id} status=#{item.status} action=#{Map.get(item, :target_action, "unknown")}"
      )
    end)
  end

  defp print_emergency_switches(switches) do
    Mix.shell().info("Emergency switches:")

    Enum.each(switches, fn switch ->
      Mix.shell().info(
        "- #{switch.key} value=#{inspect(switch.value)} hard_disabled=#{switch.hard_disabled?} boundary=#{switch.boundary}"
      )
    end)
  end

  defp context do
    ContextBuilder.cli_context(surface: "mix allbert.security")
  end
end
