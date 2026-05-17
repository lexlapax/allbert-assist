defmodule Mix.Tasks.Stocksage.Agents do
  @moduledoc """
  Inspect StockSage native specialist agents.

      mix stocksage.agents list [--user USER] [--operator USER]
      mix stocksage.agents show AGENT_ID [--user USER] [--operator USER]
  """

  use Mix.Task

  alias AllbertAssist.Actions.Runner

  @shortdoc "List or show StockSage native specialist agents"
  @switches [user: :string, operator: :string]

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    args
    |> dispatch()
    |> print_result()
  end

  defp dispatch(["list" | rest]) do
    {opts, [], invalid} = OptionParser.parse(rest, switches: @switches)

    with :ok <- reject_invalid(invalid),
         {:ok, user_id} <- resolve_user(opts),
         {:ok, response} <- run_action("list_stocksage_agents", %{user_id: user_id}, user_id) do
      {:ok, {:list, response.agents}}
    end
  end

  defp dispatch(["show", agent_id | rest]) do
    {opts, [], invalid} = OptionParser.parse(rest, switches: @switches)

    with :ok <- reject_invalid(invalid),
         {:ok, user_id} <- resolve_user(opts),
         {:ok, response} <-
           run_action("show_stocksage_agent", %{user_id: user_id, agent_id: agent_id}, user_id) do
      case response.status do
        :completed -> {:ok, {:show, response.agent}}
        :not_found -> {:error, {:not_found, agent_id}}
      end
    end
  end

  defp dispatch(_args), do: {:error, :usage}

  defp run_action(action, params, user_id) do
    case Runner.run(action, params, context(user_id)) do
      {:ok, %{status: :completed} = response} -> {:ok, response}
      {:ok, %{status: :not_found} = response} -> {:ok, response}
      {:ok, response} -> {:error, Map.get(response, :error, :action_failed)}
    end
  end

  defp context(user_id) do
    %{
      request: %{channel: :cli, user_id: user_id, operator_id: user_id, app_id: :stocksage},
      channel: :cli,
      actor: user_id,
      surface: "cli",
      app_id: :stocksage
    }
  end

  defp print_result({:ok, {:list, agents}}) do
    Mix.shell().info("StockSage native agents")
    Mix.shell().info("Returned: #{length(agents)}")

    Enum.each(agents, fn agent ->
      Mix.shell().info(
        "#{agent.id} role=#{agent.role} status=#{agent.status} prompt_version=#{agent.prompt_version} model=#{format_value(agent.model_profile)} tools=#{Enum.join(agent.tools, ",")}"
      )
    end)
  end

  defp print_result({:ok, {:show, agent}}) do
    Mix.shell().info("StockSage native agent #{agent.id}")
    Mix.shell().info("Role: #{agent.role}")
    Mix.shell().info("Module: #{inspect(agent.module)}")
    Mix.shell().info("Type: #{agent.type}")
    Mix.shell().info("Status: #{agent.status}")
    Mix.shell().info("Prompt version: #{agent.prompt_version}")
    Mix.shell().info("Prompt path: #{agent.prompt_path}")
    Mix.shell().info("Model profile: #{format_value(agent.model_profile)}")

    Mix.shell().info(
      "Tools: #{if agent.tools == [], do: "-", else: Enum.join(agent.tools, ", ")}"
    )
  end

  defp print_result({:error, reason}), do: Mix.raise(format_reason(reason))

  defp reject_invalid([]), do: :ok
  defp reject_invalid(invalid), do: {:error, {:invalid_options, invalid}}

  defp resolve_user(opts) do
    user = normalize_user(Keyword.get(opts, :user))
    operator = normalize_user(Keyword.get(opts, :operator))

    cond do
      user && operator && user != operator -> {:error, {:user_operator_mismatch, user, operator}}
      user -> {:ok, user}
      operator -> {:ok, operator}
      true -> {:ok, "local"}
    end
  end

  defp normalize_user(nil), do: nil

  defp normalize_user(user) when is_binary(user) do
    case String.trim(user) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp format_reason(:usage) do
    """
    Usage:
      mix stocksage.agents list [--user USER] [--operator USER]
      mix stocksage.agents show AGENT_ID [--user USER] [--operator USER]
    """
  end

  defp format_reason({:invalid_options, invalid}), do: "invalid options #{inspect(invalid)}"
  defp format_reason({:not_found, agent_id}), do: "StockSage native agent not found: #{agent_id}"
  defp format_reason(:action_failed), do: "StockSage agents action failed"

  defp format_reason({:user_operator_mismatch, user, operator}),
    do: "--user #{user} differs from --operator #{operator}"

  defp format_reason(reason), do: inspect(reason)

  defp format_value(nil), do: "-"
  defp format_value(value), do: to_string(value)
end
