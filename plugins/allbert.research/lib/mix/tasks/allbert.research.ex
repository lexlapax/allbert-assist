defmodule Mix.Tasks.Allbert.Research do
  @moduledoc """
  Run one bounded research delegate objective.

      mix allbert.research "topic or https://example.com" [--max-sources=N]
  """

  use Mix.Task

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.Objectives.AgentRegistry
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Settings
  alias AllbertResearch.DelegateObjective

  @shortdoc "Run a research.specialist delegate objective"
  @usage_exit 64
  @failure_exit 1

  @impl true
  def run(args) do
    try do
      Mix.Task.run("app.start")

      args
      |> dispatch()
      |> print_result()
    catch
      {:research_error, code, message} ->
        Mix.shell().error(message)
        halt(code)
    end
  end

  defp dispatch(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [max_sources: :integer, user: :string, operator: :string]
      )

    reject_invalid!(invalid)

    case positional do
      [target] ->
        run_research(target, opts)

      [] ->
        fail!(@usage_exit, usage())

      extra ->
        fail!(@usage_exit, "Unexpected research arguments: #{Enum.join(extra, " ")}")
    end
  end

  defp run_research(target, opts) do
    user_id = user_id!(opts)
    ensure_research_registered!()
    ensure_research_enabled!()
    ensure_browser_ready!()

    max_sources = Keyword.get(opts, :max_sources)
    {:ok, session_id} = start_session!(target, user_id)

    with {:ok, entry} <- AgentRegistry.lookup(AllbertResearch.Runtime.agent_id()),
         {:ok, run} <-
           DelegateObjective.start(user_id, target,
             session_id: session_id,
             max_sources: max_sources,
             channel: :cli,
             source_intent: "mix allbert.research",
             trace_prefix: "cli_research"
           ) do
      {:ok,
       %{
         agent: entry,
         command: run.command,
         objective: run.objective,
         step: run.step,
         result: run.result,
         status: run.status,
         confirmation_id: run.confirmation_id,
         session_id: session_id
       }}
    else
      {:error, reason} ->
        fail!(@failure_exit, "Research delegate failed: #{inspect(reason)}")
    end
  end

  defp print_result({:ok, result}) do
    Mix.shell().info("Allbert research #{result.agent.id}")
    Mix.shell().info("Command: #{result.command}")
    Mix.shell().info("Status: #{result.status}")
    Mix.shell().info("Objective: #{result.objective.id}")

    if result.confirmation_id do
      Mix.shell().info("Confirmation: #{result.confirmation_id}")
    end

    if summary = summary(result.result) do
      Mix.shell().info("Summary: #{summary}")
    end

    if sources = sources(result.result) do
      Enum.each(sources, fn source ->
        Mix.shell().info("Source: #{Map.get(source, :url) || Map.get(source, "url")}")
      end)
    end
  end

  defp start_session!(target, user_id) do
    context = %{
      actor: user_id,
      user_id: user_id,
      operator_id: user_id,
      channel: :cli,
      surface: "research.cli",
      confirmation: %{approved?: true}
    }

    params = %{
      purpose: "mix allbert.research",
      expected_domains: target |> expected_domain() |> List.wrap()
    }

    case Runner.run("browser_start_session", params, context) do
      {:ok, %{status: :completed, session_id: session_id}} ->
        {:ok, session_id}

      {:ok, %{status: :needs_confirmation, confirmation_id: confirmation_id}} ->
        fail!(@failure_exit, "Browser session confirmation required: #{confirmation_id}")

      {:ok, response} ->
        fail!(@failure_exit, "Unable to start browser session: #{inspect(response)}")
    end
  end

  defp ensure_research_registered! do
    _ = PluginRegistry.register_module(AllbertResearch.Plugin)
    _ = AppRegistry.register(AllbertResearch.App)
    ensure_research_supervisor!()

    case AgentRegistry.lookup(AllbertResearch.Runtime.agent_id()) do
      {:ok, _entry} ->
        :ok

      {:error, :not_found} ->
        AllbertResearch.Runtime.register_if_available(
          AllbertResearch.Agent,
          AllbertResearch.Agent
        )

        case AgentRegistry.lookup(AllbertResearch.Runtime.agent_id()) do
          {:ok, _entry} -> :ok
          {:error, _reason} -> fail!(@failure_exit, "research.specialist is not registered.")
        end
    end
  end

  defp ensure_research_supervisor! do
    if Process.whereis(AllbertResearch.Supervisor) do
      :ok
    else
      case AllbertResearch.Supervisor.start_link([]) do
        {:ok, _pid} ->
          :ok

        {:error, {:already_started, _pid}} ->
          :ok

        {:error, reason} ->
          fail!(@failure_exit, "Unable to start research supervisor: #{inspect(reason)}")
      end
    end
  end

  defp ensure_research_enabled! do
    case Settings.get("research.enabled") do
      {:ok, true} ->
        :ok

      {:ok, false} ->
        fail!(@failure_exit, "Research is disabled. Set research.enabled true first.")

      {:error, reason} ->
        fail!(@failure_exit, "Unable to read research.enabled: #{inspect(reason)}")
    end
  end

  defp ensure_browser_ready! do
    ensure_browser_supervisor!()

    case Runner.run("browser_doctor", %{}, %{actor: "local", channel: :cli}) do
      {:ok, %{status: :completed, doctor: %{live_check_status: :ok}}} ->
        :ok

      {:ok, response} ->
        fail!(
          @failure_exit,
          "Browser doctor failed: #{inspect(response[:error] || response[:status])}"
        )
    end
  end

  defp ensure_browser_supervisor! do
    if Process.whereis(AllbertBrowser.Supervisor) do
      :ok
    else
      case AllbertBrowser.Supervisor.start_link([]) do
        {:ok, _pid} ->
          :ok

        {:error, {:already_started, _pid}} ->
          :ok

        {:error, reason} ->
          fail!(@failure_exit, "Unable to start browser supervisor: #{inspect(reason)}")
      end
    end
  end

  defp expected_domain(target) do
    case URI.parse(String.trim(target)) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _other -> nil
    end
  end

  defp summary(%{delegate_response: %{summary: summary}}), do: summary
  defp summary(%{"delegate_response" => %{"summary" => summary}}), do: summary
  defp summary(%{delegate_response: %{message: message}}), do: message
  defp summary(%{"delegate_response" => %{"message" => message}}), do: message
  defp summary(_result), do: nil

  defp sources(%{delegate_response: %{output_data: %{sources: sources}}}) when is_list(sources),
    do: sources

  defp sources(%{"delegate_response" => %{"output_data" => %{"sources" => sources}}})
       when is_list(sources),
       do: sources

  defp sources(_result), do: nil

  defp user_id!(opts) do
    user = blank_to_nil(opts[:user])
    operator = blank_to_nil(opts[:operator])

    cond do
      user && operator && user != operator ->
        fail!(@usage_exit, "--user and --operator must match when both are provided.")

      user ->
        user

      operator ->
        operator

      true ->
        "local"
    end
  end

  defp reject_invalid!([]), do: :ok
  defp reject_invalid!(invalid), do: fail!(@usage_exit, "Unknown options: #{inspect(invalid)}")

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp usage do
    """
    Usage:
      mix allbert.research "topic or https://example.com" [--max-sources=N]
    """
  end

  @spec fail!(non_neg_integer(), String.t()) :: no_return()
  defp fail!(code, message), do: throw({:research_error, code, message})

  defp halt(code) do
    :allbert_assist
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:halt_fun, &System.halt/1)
    |> then(& &1.(code))
  end
end
