defmodule StockSage.Actions.Evidence do
  @moduledoc false

  alias StockSage.{Actions, Evidence}

  def capability do
    Actions.capability(:stocksage_evidence_fetch, %{
      exposure: :internal,
      execution_mode: :req_http,
      skill_backed?: false,
      confirmation: :required
    })
  end

  def run(kind, action_name, params, context) do
    mode = Evidence.mode(params)
    context = evidence_context(mode, context)
    permission_decision = Actions.authorize(:stocksage_evidence_fetch, context)
    resource_access = [Evidence.resource_access(kind, params)]

    if Actions.allowed?(permission_decision) do
      case Evidence.fetch(kind, params) do
        {:ok, evidence} ->
          {:ok,
           %{
             message: "StockSage #{kind} evidence loaded in #{evidence.mode} mode.",
             status: :completed,
             evidence: evidence,
             resource_access: resource_access,
             actions: [
               Actions.action(
                 action_name,
                 :completed,
                 :stocksage_evidence_fetch,
                 permission_decision,
                 %{
                   kind: kind,
                   mode: evidence.mode,
                   ticker: evidence.ticker
                 }
               )
             ]
           }}

        {:error, reason} ->
          {:ok,
           %{
             message: "StockSage #{kind} evidence failed: #{inspect(reason)}",
             status: :error,
             error: reason,
             resource_access: resource_access,
             actions: [
               Actions.action(
                 action_name,
                 :error,
                 :stocksage_evidence_fetch,
                 permission_decision,
                 %{
                   kind: kind,
                   mode: mode,
                   error: reason
                 }
               )
             ]
           }}
      end
    else
      status = Actions.status_from_decision(permission_decision)

      {:ok,
       %{
         message: permission_decision.reason,
         status: status,
         error: :resource_access_required,
         resource_access: resource_access,
         actions: [
           Actions.action(action_name, status, :stocksage_evidence_fetch, permission_decision, %{
             kind: kind,
             mode: mode,
             error: :resource_access_required
           })
         ]
       }}
    end
  end

  defp evidence_context("fixture", context) do
    Map.put(context, :resource, %{kind: :fixture_evidence})
  end

  defp evidence_context(_mode, context), do: context
end
