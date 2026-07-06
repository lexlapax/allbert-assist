defmodule AllbertAssist.CLI.Areas.Plan do
  @moduledoc """
  Release-safe `plan` admin dispatch (v0.62 M8.7).

  The single source of truth for `mix allbert.plan` and `allbert admin plan`:
  `dispatch/2` parses the sub-argv, routes to the same registered actions the
  Mix task used (scoping each run to a per-user context), and returns
  `{rendered_output, exit_code}` — no `Mix.*` calls, so it runs inside the
  packaged release. `Mix.Tasks.Allbert.Plan` is a thin wrapper that prints the
  output through `Mix.shell/0`.
  """

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.CLI.Areas.Render
  alias AllbertAssist.Surfaces.ContextBuilder

  @usage_exit 64
  @not_found_exit 65
  @dialyzer {:nowarn_function, fail!: 2}

  @spec dispatch([String.t()], map() | nil) :: {String.t(), non_neg_integer()}
  def dispatch(argv, context \\ nil) do
    argv
    |> route(context || default_context())
    |> render()
  end

  defp default_context, do: ContextBuilder.cli_context(surface: "allbert admin plan")

  defp route(argv, ctx) do
    do_route(argv, ctx)
  catch
    {:plan_error, @usage_exit, message} -> {:usage, message}
    {:plan_error, _code, message} -> {:error, {:raw, message}}
  end

  defp do_route(["list" | args], _ctx) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [format: :string, status: :string, user: :string])

    reject_invalid!(invalid)
    reject_rest!(rest, "list")

    params =
      %{
        user_id: user_id(opts),
        status: opts[:status],
        format: opts[:format]
      }
      |> drop_nil()

    with {:ok, %{status: :completed, output_data: output_data}} <-
           Runner.run("list_plan_runs", params, context(params[:user_id])) do
      {:ok, {:list, output_data, opts[:format]}}
    else
      {:ok, response} -> {:error, response}
    end
  end

  defp do_route(["show", objective_id | args], _ctx) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [user: :string])
    reject_invalid!(invalid)
    reject_rest!(rest, "show")

    params = %{id: objective_id, user_id: user_id(opts)}

    with {:ok, %{status: :completed} = response} <-
           Runner.run("show_objective", params, context(params.user_id)) do
      {:ok, {:show, response}}
    else
      {:ok, %{status: :not_found}} -> fail!(@not_found_exit, "Plan run not found.")
      {:ok, response} -> {:error, response}
    end
  end

  defp do_route(["cancel", objective_id | args], _ctx) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [reason: :string, user: :string])
    reject_invalid!(invalid)
    reject_rest!(rest, "cancel")

    params = %{
      objective_id: objective_id,
      user_id: user_id(opts),
      reason: required_reason!(opts)
    }

    with {:ok, %{status: :cancelled} = response} <-
           Runner.run("cancel_plan_run", params, context(params.user_id)) do
      {:ok, {:cancel, response}}
    else
      {:ok, response} -> {:error, response}
    end
  end

  defp do_route(_args, _ctx) do
    fail!(
      @usage_exit,
      """
      Usage:
        mix allbert.plan list [--format ids] [--status running] [--user USER]
        mix allbert.plan show OBJECTIVE_ID [--user USER]
        mix allbert.plan cancel OBJECTIVE_ID --reason REASON [--user USER]
      """
    )
  end

  defp render({:ok, {:list, %{ids: ids}, "ids"}}), do: Render.ok(ids)
  defp render({:ok, {:list, %{plans: []}, _format}}), do: Render.ok("No plan runs.")

  defp render({:ok, {:list, %{plans: plans}, _format}}) do
    Render.ok(
      Enum.map(plans, fn plan ->
        "#{plan.id} #{plan.status} #{plan.source_intent || "workflow:none"}"
      end)
    )
  end

  defp render({:ok, {:show, response}}) do
    objective = response.objective

    Render.ok([
      "Plan: #{objective.id}",
      "Status: #{objective.status}",
      "Workflow: #{objective[:source_intent] || "none"}",
      "Steps: #{length(response.steps)}",
      "Events: #{length(response.events)}"
    ])
  end

  defp render({:ok, {:cancel, response}}), do: Render.ok(response.message)
  defp render({:usage, message}), do: Render.usage(message)
  defp render({:error, {:raw, message}}), do: Render.error(message)
  defp render({:error, reason}), do: Render.error("Plan command failed: #{inspect(reason)}")

  defp context(nil), do: context("local")

  defp context(user_id) do
    ContextBuilder.cli_context(actor: "local", user_id: user_id, surface: "mix allbert.plan")
  end

  defp user_id(opts), do: Keyword.get(opts, :user, "local")

  defp required_reason!(opts) do
    case Keyword.get(opts, :reason) do
      value when is_binary(value) and value != "" -> value
      _other -> fail!(@usage_exit, "--reason is required")
    end
  end

  defp drop_nil(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  defp reject_invalid!([]), do: :ok
  defp reject_invalid!(invalid), do: fail!(@usage_exit, "Invalid options: #{inspect(invalid)}")

  defp reject_rest!([], _command), do: :ok

  defp reject_rest!(rest, command),
    do: fail!(@usage_exit, "Unexpected #{command} args: #{inspect(rest)}")

  defp fail!(code, message), do: throw({:plan_error, code, message})
end
