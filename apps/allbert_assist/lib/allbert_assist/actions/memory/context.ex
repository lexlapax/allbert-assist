defmodule AllbertAssist.Actions.Memory.Context do
  @moduledoc false

  @spec user_id(map(), map()) :: {:ok, String.t()} | {:error, :missing_user_id}
  def user_id(params, context) when is_map(params) and is_map(context) do
    [
      Map.get(params, :user_id),
      Map.get(params, "user_id"),
      Map.get(context, :user_id),
      Map.get(context, "user_id"),
      get_in(context, [:request, :user_id]),
      get_in(context, ["request", "user_id"]),
      Map.get(context, :operator_id),
      Map.get(context, :actor)
    ]
    |> Enum.find(&present?/1)
    |> case do
      nil -> {:error, :missing_user_id}
      user_id -> {:ok, to_string(user_id)}
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
