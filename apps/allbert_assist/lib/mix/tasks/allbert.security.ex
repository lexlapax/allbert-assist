defmodule Mix.Tasks.Allbert.Security do
  @moduledoc """
  Inspect Security Central status.

  ## Usage

      mix allbert.security status
  """

  use Mix.Task

  alias AllbertAssist.Actions.Runner

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

  defp dispatch(_args) do
    Mix.raise("""
    Usage:
      mix allbert.security status
    """)
  end

  defp print_result({:ok, status}) do
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

  defp print_result({:error, reason}) do
    Mix.raise("Security command failed: #{inspect(reason)}")
  end

  defp completed_action(action_name, params) do
    case Runner.run(action_name, params, context()) do
      {:ok, %{status: :completed} = response} -> {:ok, response}
      {:ok, response} -> {:error, response_error(response)}
    end
  end

  defp response_error(%{error: error}), do: error
  defp response_error(%{message: message}), do: message

  defp context do
    %{actor: "local", channel: :cli}
  end
end
