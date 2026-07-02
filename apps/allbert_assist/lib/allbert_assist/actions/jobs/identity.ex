defmodule AllbertAssist.Actions.Jobs.Identity do
  @moduledoc """
  Shared server-derived identity resolution for the scheduled-job actions.

  Identity precedence puts the context-supplied `user_id` (set server-side by the
  caller, e.g. the LiveView `ContextBuilder`) ahead of any params-supplied value, so a
  client cannot scope a job read or mutation to another user via the request body.
  This is the same precedence the objectives actions use and the boundary the v0.61
  M10.3 JobsLive IDOR fix relies on.
  """

  @spec user_id(map(), map()) :: {:ok, String.t()} | {:error, :missing_user_id}
  def user_id(params, context) do
    case field(context, :user_id) || get_in_field(context, [:request, :user_id]) ||
           field(params, :user_id) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, :missing_user_id}
    end
  end

  defp get_in_field(value, keys) do
    Enum.reduce_while(keys, value, fn key, acc ->
      case field(acc, key) do
        nil -> {:halt, nil}
        found -> {:cont, found}
      end
    end)
  end

  @spec field(term(), atom()) :: term()
  def field(%_struct{} = struct, key), do: Map.get(struct, key)

  def field(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  def field(_value, _key), do: nil
end
