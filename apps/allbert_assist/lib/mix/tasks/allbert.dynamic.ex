defmodule Mix.Tasks.Allbert.Dynamic do
  @moduledoc """
  Inspect v0.37 dynamic draft and integration metadata.

  ## Usage

      mix allbert.dynamic drafts list
      mix allbert.dynamic drafts show SLUG
      mix allbert.dynamic integrations show SLUG [REVISION]
  """

  use Mix.Task

  alias AllbertAssist.Actions.Runner

  @shortdoc "Inspect v0.37 dynamic capability metadata"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    args
    |> dispatch()
    |> print_result()
  end

  defp dispatch(["drafts", "list"]) do
    with {:ok, response} <- completed_action("list_dynamic_drafts", %{}) do
      {:ok, {:drafts, response.drafts}}
    end
  end

  defp dispatch(["drafts", "show", slug]) do
    with {:ok, response} <- completed_action("show_dynamic_draft", %{slug: slug}) do
      {:ok, {:draft, response.draft}}
    end
  end

  defp dispatch(["integrations", "show", slug]) do
    with {:ok, response} <- completed_action("show_dynamic_integration", %{slug: slug}) do
      {:ok, {:integration, response.integration}}
    end
  end

  defp dispatch(["integrations", "show", slug, revision]) do
    with {:ok, response} <-
           completed_action("show_dynamic_integration", %{slug: slug, revision: revision}) do
      {:ok, {:integration, response.integration}}
    end
  end

  defp dispatch(_args), do: Mix.raise(usage())

  defp print_result({:ok, {:drafts, []}}), do: Mix.shell().info("No dynamic drafts found.")

  defp print_result({:ok, {:drafts, drafts}}) do
    Enum.each(drafts, fn draft ->
      Mix.shell().info(
        "#{draft.slug} revision=#{draft.revision} tier=#{draft.tier} gate=#{draft.gate_status || "not_run"}"
      )
    end)
  end

  defp print_result({:ok, {:draft, draft}}) do
    Mix.shell().info("Slug: #{draft.slug}")
    Mix.shell().info("Revision: #{draft.revision}")
    Mix.shell().info("Tier: #{draft.tier}")
    Mix.shell().info("Producer: #{draft.producer}")
    Mix.shell().info("Gate: #{draft.gate_status || "not_run"}")
    Mix.shell().info("Static validation: #{draft.static_validation_status || "not_run"}")
    Mix.shell().info("Root: #{draft.root}")
  end

  defp print_result({:ok, {:integration, integration}}) do
    Mix.shell().info("Slug: #{integration.slug}")
    Mix.shell().info("Revision: #{integration.revision}")
    Mix.shell().info("Tier: #{integration.tier}")
    Mix.shell().info("Root: #{integration.root}")
  end

  defp print_result({:error, reason}) do
    Mix.raise("Dynamic metadata command failed: #{inspect(reason)}")
  end

  defp completed_action(action_name, params) do
    case Runner.run(action_name, params, %{actor: "local", channel: :cli, surface: "cli"}) do
      {:ok, %{status: :completed} = response} -> {:ok, response}
      {:ok, response} -> {:error, response_error(response)}
    end
  end

  defp response_error(%{error: error}), do: error
  defp response_error(%{message: message}), do: message

  defp usage do
    """
    Usage:
      mix allbert.dynamic drafts list
      mix allbert.dynamic drafts show SLUG
      mix allbert.dynamic integrations show SLUG [REVISION]
    """
  end
end
