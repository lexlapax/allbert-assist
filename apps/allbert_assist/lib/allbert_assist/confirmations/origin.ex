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
    metadata = field(request, :metadata, %{}) || field(context, :metadata, %{}) || %{}

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
    |> put_optional_map(:session, session_snapshot(context, request))
    |> put_optional_map(:coding, coding_snapshot(context, request, metadata))
    |> drop_empty()
  end

  def from_context(_context, default_surface),
    do: %{actor: "local", channel: :unknown, surface: default_surface}

  defp field(map, key, default \\ nil)

  defp field(map, key, default) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key), default)
    end
  end

  defp session_snapshot(context, request) do
    first_map(field(context, :session), field(request, :session))
  end

  defp coding_snapshot(context, request, metadata) do
    request
    |> field(:coding, %{})
    |> map_or_empty()
    |> Map.merge(metadata |> field(:coding, %{}) |> map_or_empty())
    |> Map.merge(context |> field(:coding, %{}) |> map_or_empty())
    |> Map.take([
      :cwd_jail,
      :workspace_root,
      :pi_mode_enabled,
      :pi_mode_enabled?,
      :approval_mode,
      :default_approval_mode,
      :model_profile,
      :prompt_token_count,
      :prompt_tokenizer,
      :channel_originated?,
      :scheduled?,
      :generated_code_session?,
      "cwd_jail",
      "workspace_root",
      "pi_mode_enabled",
      "pi_mode_enabled?",
      "approval_mode",
      "default_approval_mode",
      "model_profile",
      "prompt_token_count",
      "prompt_tokenizer",
      "channel_originated?",
      "scheduled?",
      "generated_code_session?"
    ])
  end

  defp put_optional_map(map, _key, value) when value in [nil, %{}], do: map
  defp put_optional_map(map, key, value) when is_map(value), do: Map.put(map, key, value)

  defp first_map(value, _fallback) when is_map(value), do: value
  defp first_map(_value, value) when is_map(value), do: value
  defp first_map(_value, _fallback), do: %{}

  defp first_present(values, default \\ nil) do
    Enum.find(values, default, &(&1 not in [nil, ""]))
  end

  defp map_or_empty(value) when is_map(value), do: value
  defp map_or_empty(_value), do: %{}

  defp drop_empty(map) do
    Map.reject(map, fn {_key, value} -> value in [nil, ""] end)
  end
end
