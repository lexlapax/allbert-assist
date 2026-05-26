defmodule Mix.Tasks.Allbert.Dynamic do
  @moduledoc """
  Inspect v0.37 dynamic draft and integration metadata.

  ## Usage

      mix allbert.dynamic drafts list
      mix allbert.dynamic drafts show SLUG
      mix allbert.dynamic drafts request SLUG SUMMARY...
      mix allbert.dynamic drafts discard SLUG
      mix allbert.dynamic drafts integrate SLUG
      mix allbert.dynamic integrations show SLUG [REVISION]
      mix allbert.dynamic integrations rollback SLUG [REVISION]
      mix allbert.dynamic integrations disable
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

  defp dispatch(["drafts", "request", slug | summary_parts]) when summary_parts != [] do
    params = %{
      slug: slug,
      summary: Enum.join(summary_parts, " "),
      source: "operator",
      explicit_generation?: true
    }

    with {:ok, response} <- completed_action("request_dynamic_draft", params) do
      {:ok, {:requested, response}}
    end
  end

  defp dispatch(["drafts", "integrate", slug]) do
    case Runner.run("integrate_dynamic_draft", %{slug: slug}, context()) do
      {:ok, %{status: :completed} = response} -> {:ok, {:integrated, response}}
      {:ok, %{status: :needs_confirmation} = response} -> {:ok, {:confirmation, response}}
      {:ok, response} -> {:error, response_error(response)}
    end
  end

  defp dispatch(["drafts", "discard", slug]) do
    with {:ok, response} <- completed_action("discard_dynamic_draft", %{slug: slug}) do
      {:ok, {:discarded, response}}
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

  defp dispatch(["integrations", "rollback", slug]) do
    rollback(slug, nil)
  end

  defp dispatch(["integrations", "rollback", slug, revision]) do
    rollback(slug, revision)
  end

  defp dispatch(["integrations", "disable"]) do
    with {:ok, response} <- completed_action("disable_dynamic_live_loader", %{}) do
      {:ok, {:disabled, response}}
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

  defp print_result({:ok, {:confirmation, response}}) do
    Mix.shell().info(response.message)
    Mix.shell().info("Approve with:")
    Mix.shell().info("  mix allbert.confirmations approve #{response.confirmation_id}")
  end

  defp print_result({:ok, {:requested, response}}) do
    Mix.shell().info(response.message)
    Mix.shell().info("Draft root: #{response.draft.root}")
  end

  defp print_result({:ok, {:discarded, response}}) do
    Mix.shell().info(response.message)
  end

  defp print_result({:ok, {:integrated, response}}) do
    Mix.shell().info(response.message)
  end

  defp print_result({:ok, {:rolled_back, response}}) do
    Mix.shell().info(response.message)
  end

  defp print_result({:ok, {:disabled, response}}) do
    Mix.shell().info(response.message)
  end

  defp print_result({:error, reason}) do
    Mix.raise("Dynamic metadata command failed: #{inspect(reason)}")
  end

  defp completed_action(action_name, params) do
    case Runner.run(action_name, params, context()) do
      {:ok, %{status: :completed} = response} -> {:ok, response}
      {:ok, response} -> {:error, response_error(response)}
    end
  end

  defp rollback(slug, revision) do
    params = if is_nil(revision), do: %{slug: slug}, else: %{slug: slug, revision: revision}

    case Runner.run("rollback_dynamic_integration", params, context()) do
      {:ok, %{status: :completed} = response} -> {:ok, {:rolled_back, response}}
      {:ok, %{status: :needs_confirmation} = response} -> {:ok, {:confirmation, response}}
      {:ok, response} -> {:error, response_error(response)}
    end
  end

  defp context do
    %{actor: "local", channel: :cli, surface: "cli"}
  end

  defp response_error(%{error: error}), do: error
  defp response_error(%{message: message}), do: message

  defp usage do
    """
    Usage:
      mix allbert.dynamic drafts list
      mix allbert.dynamic drafts show SLUG
      mix allbert.dynamic drafts request SLUG SUMMARY...
      mix allbert.dynamic drafts discard SLUG
      mix allbert.dynamic drafts integrate SLUG
      mix allbert.dynamic integrations show SLUG [REVISION]
      mix allbert.dynamic integrations rollback SLUG [REVISION]
      mix allbert.dynamic integrations disable
    """
  end
end
