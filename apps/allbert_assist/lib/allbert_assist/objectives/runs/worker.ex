defmodule AllbertAssist.Objectives.Runs.Worker do
  @moduledoc """
  Executes one already-planned Objective step through a bounded worker Adapter.

  The Interface resolves the registered action before choosing an Adapter.
  Adapter selection is deterministic runtime policy; model output cannot name
  or select an Adapter. Durable queue, retry, and cancellation authority stays
  with the Objective lifecycle and its RunServer.
  """

  alias AllbertAssist.Actions.Intent.DirectAnswer
  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Objectives.Fanout.Budget
  alias AllbertAssist.Objectives.Runs.CancelToken
  alias AllbertAssist.Objectives.Runs.Worker.{ActionAdapter, Grounding, JidoAdapter}
  alias AllbertAssist.RegistryContext

  @type adapter_name :: :ordinary | :jido
  @type result :: %{
          required(:adapter) => adapter_name(),
          required(:response) => map(),
          required(:quality_receipt) => map() | nil
        }

  @doc "Execute one registered action through its deterministic worker Adapter."
  @spec run(module() | String.t() | atom(), map(), map(), keyword()) ::
          {:ok, result()} | {:error, term()}
  def run(action, params, context, opts \\ [])
      when is_map(params) and is_map(context) and is_list(opts) do
    with {:ok, action_module} <- Registry.resolve(action, registry_opts(context)),
         :ok <- active(context),
         :ok <- authorize_plan_window(context, action_module),
         :ok <- authorize_retry(action_module, context),
         :ok <- authorize_action(context, action_module),
         {adapter_name, adapter} <- adapter_for(action_module),
         {:ok, response} <- adapter.run(action_module, params, context, opts) do
      worker_result(adapter_name, response)
    end
  end

  defp worker_result(
         :jido,
         %{response: response, quality_receipt: quality_receipt}
       ) do
    {:ok, %{adapter: :jido, response: response, quality_receipt: quality_receipt}}
  end

  defp worker_result(adapter, response),
    do: {:ok, %{adapter: adapter, response: response, quality_receipt: nil}}

  defp adapter_for(DirectAnswer), do: {:jido, JidoAdapter}
  defp adapter_for(_action_module), do: {:ordinary, ActionAdapter}

  defp active(context) do
    case CancelToken.checkpoint(context) do
      :ok -> :ok
      :cancelled -> {:error, :cancelled}
    end
  end

  defp authorize_plan_window(
         %{
           fanout_budget: %{"version" => 1} = budget,
           fanout_deadline_unix_ms: deadline,
           objective_run_attempt: attempt
         },
         DirectAnswer
       ) do
    with :ok <- Budget.authorize_worker(budget, attempt, deadline) do
      {:error, :quality_protocol_upgrade_required}
    end
  end

  defp authorize_plan_window(
         %{
           fanout_budget: %{} = budget,
           fanout_deadline_unix_ms: deadline,
           objective_run_attempt: attempt
         },
         _action_module
       ) do
    Budget.authorize_worker(budget, attempt, deadline)
  end

  # Pre-M9.b.4 objectives have no plan budget. Preserve that compatibility
  # only for explicitly resolved ordinary/legacy work or callers predating the
  # grounding context. A compiled v1.3 child never acquires a legacy budget by
  # losing or corrupting provenance.
  defp authorize_plan_window(
         %{
           fanout_grounding: %{source: source},
           fanout_budget: nil
         },
         _action_module
       )
       when source in [:ordinary, :legacy_ordinary],
       do: :ok

  defp authorize_plan_window(%{fanout_grounding: %{}}, _action_module),
    do: {:error, :invalid_fanout_budget_snapshot}

  defp authorize_plan_window(context, _action_module)
       when not is_map_key(context, :fanout_grounding),
       do: :ok

  defp authorize_plan_window(_context, _action_module),
    do: {:error, :invalid_fanout_budget_snapshot}

  defp authorize_retry(_action_module, context)
       when not is_map_key(context, :objective_run_attempt),
       do: :ok

  defp authorize_retry(_action_module, %{objective_run_attempt: 1}), do: :ok

  defp authorize_retry(action_module, %{objective_run_attempt: attempt} = context)
       when is_atom(action_module) and is_integer(attempt) and attempt > 1 do
    case Registry.capability(action_module, registry_opts(context)) do
      {:ok, %{retry_safety: :safe}} ->
        :ok

      {:ok, %{retry_safety: safety}} when safety in [:unsafe, :unknown] ->
        {:error, :fanout_worker_retry_unsafe}

      {:error, _reason} ->
        {:error, :fanout_worker_retry_unsafe}
    end
  end

  defp authorize_retry(_action_module, _context), do: {:error, :fanout_worker_retry_unsafe}

  defp authorize_action(%{fanout_grounding: %{} = grounding}, action_module),
    do: Grounding.authorize_action(grounding, action_module)

  defp authorize_action(_legacy_or_unframed_context, _action_module), do: :ok

  defp registry_opts(%{registry: registry}) when is_list(registry),
    do: RegistryContext.take(registry)

  defp registry_opts(_context), do: []
end
