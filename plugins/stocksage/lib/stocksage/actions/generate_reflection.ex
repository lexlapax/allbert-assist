defmodule StockSage.Actions.GenerateReflection do
  @moduledoc false

  use Jido.Action,
    name: "generate_reflection",
    description: "Generate a StockSage-local reflection for a resolved outcome.",
    category: "stocksage",
    tags: ["stocksage", "reflection", "write"],
    schema: [
      user_id: [type: :string, required: false],
      outcome_id: [type: :string, required: true],
      max_chars: [type: :integer, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Settings
  alias StockSage.{Actions, Reflections}

  def capability, do: Actions.capability(:stocksage_write, %{exposure: :internal})

  @impl true
  def run(params, context) do
    permission_decision = Actions.authorize(:stocksage_write, context)

    with true <- reflections_enabled?(),
         {:ok, user_id} <- Actions.user_id(params, context),
         {:ok, outcome_id} <- outcome_id(params) do
      if Actions.allowed?(permission_decision) do
        case Reflections.generate(user_id, outcome_id,
               max_chars: Actions.field(params, :max_chars, default_max_chars())
             ) do
          {:ok, reflection} ->
            {:ok,
             %{
               message: "Generated StockSage reflection for #{reflection.symbol}.",
               status: :completed,
               reflection: reflection,
               actions: [
                 Actions.action(
                   "generate_reflection",
                   :completed,
                   :stocksage_write,
                   permission_decision,
                   %{
                     reflection_id: reflection.entry_id,
                     outcome_id: reflection.outcome_id,
                     analysis_id: reflection.analysis_id,
                     symbol: reflection.symbol,
                     promoted_to_allbert_memory: false
                   }
                 )
               ]
             }}

          {:error, reason} ->
            {:ok, error_response(reason, permission_decision)}
        end
      else
        status = Actions.status_from_decision(permission_decision)

        {:ok,
         %{
           message: "StockSage reflections are not available to this request.",
           status: status,
           error: :permission_denied,
           actions: [
             Actions.action(
               "generate_reflection",
               status,
               :stocksage_write,
               permission_decision,
               %{
                 error: :permission_denied
               }
             )
           ]
         }}
      end
    else
      false ->
        {:ok,
         %{
           message: "StockSage reflections are disabled by settings.",
           status: :denied,
           error: :reflections_disabled,
           actions: [
             Actions.action(
               "generate_reflection",
               :denied,
               :stocksage_write,
               permission_decision,
               %{
                 error: :reflections_disabled
               }
             )
           ]
         }}

      {:error, :missing_user_id} ->
        Actions.missing_user("generate_reflection", :stocksage_write, permission_decision)

      {:error, reason} ->
        {:ok, error_response(reason, permission_decision)}
    end
  end

  defp outcome_id(params) do
    case Actions.field(params, :outcome_id) |> Actions.blank_to_nil() do
      nil -> {:error, :missing_outcome_id}
      value -> {:ok, value}
    end
  end

  defp reflections_enabled? do
    case Settings.get("stocksage.reflections.enabled") do
      {:ok, false} -> false
      _other -> true
    end
  end

  defp default_max_chars do
    case Settings.get("stocksage.reflections.max_chars") do
      {:ok, value} -> value
      _other -> 1_200
    end
  end

  defp error_response(reason, permission_decision) do
    %{
      message: "Could not generate StockSage reflection: #{inspect(reason)}.",
      status: :error,
      error: reason,
      actions: [
        Actions.action("generate_reflection", :error, :stocksage_write, permission_decision, %{
          error: reason
        })
      ]
    }
  end
end
