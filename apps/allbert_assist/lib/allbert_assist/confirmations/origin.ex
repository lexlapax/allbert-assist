defmodule AllbertAssist.Confirmations.Origin do
  @moduledoc """
  Shared confirmation origin metadata.

  Confirmation records are channel-neutral. Job-triggered confirmations carry
  job/run context here so approval surfaces can show where the request came
  from without creating a second job-specific approval queue.
  """

  @doc "Build a redaction-safe origin map from runner context."
  @spec from_context(map(), String.t()) :: map()
  def from_context(context, default_surface) when is_map(context) do
    request = field(context, :request, %{}) || %{}

    %{
      actor: first_present([field(request, :operator_id), field(context, :actor)], "local"),
      user_id: first_present([field(request, :user_id), field(context, :user_id)]),
      operator_id: first_present([field(request, :operator_id), field(context, :operator_id)]),
      thread_id: first_present([field(request, :thread_id), field(context, :thread_id)]),
      channel: first_present([field(request, :channel), field(context, :channel)], :unknown),
      surface: field(context, :surface, default_surface),
      session_id: first_present([field(request, :session_id), field(context, :session_id)]),
      app_id: first_present([field(request, :app_id), field(context, :app_id)]),
      job_id: first_present([field(request, :job_id), field(context, :job_id)]),
      run_id: first_present([field(request, :run_id), field(context, :run_id)]),
      response_target: field(context, :response_target)
    }
    |> drop_empty()
  end

  def from_context(_context, default_surface),
    do: %{actor: "local", channel: :unknown, surface: default_surface}

  defp field(map, key, default \\ nil)

  defp field(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp field(_map, _key, default), do: default

  defp first_present(values, default \\ nil) do
    Enum.find(values, default, &(&1 not in [nil, ""]))
  end

  defp drop_empty(map) do
    Map.reject(map, fn {_key, value} -> value in [nil, ""] end)
  end
end
