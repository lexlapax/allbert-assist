defmodule AllbertAssist.Coding.SessionGuard do
  @moduledoc """
  Runtime guard for Pi-mode coding actions.

  Coding actions are registered capabilities so the local TUI can invoke them
  through the normal Runner boundary, but they are not general intent-agent or
  public-protocol tools. A call must carry active Pi-mode session metadata and
  must resolve to the local-coding operator tier before touching files or shell.
  """

  alias AllbertAssist.Security.PermissionGate

  @type denial_reason :: :coding_session_required | :local_coding_operator_required
  @type normalized_context :: %{required(:coding) => map(), optional(any()) => any()}

  @spec ensure_active(map()) ::
          {:ok, normalized_context()} | {:error, denial_reason(), normalized_context()}
  def ensure_active(context) when is_map(context) do
    normalized = normalize_context(context)

    cond do
      not coding_session?(normalized) ->
        {:error, :coding_session_required, normalized}

      PermissionGate.coding_tier(normalized) != :local_coding_operator ->
        {:error, :local_coding_operator_required, normalized}

      true ->
        {:ok, normalized}
    end
  end

  @spec denied_decision(atom(), map(), denial_reason()) :: PermissionGate.decision()
  def denied_decision(permission, context, reason) do
    permission
    |> PermissionGate.authorize(normalize_context(context))
    |> Map.merge(%{
      decision: :denied,
      requires_confirmation: false,
      reason: denial_reason(reason)
    })
  end

  @spec normalize_context(map()) :: normalized_context()
  def normalize_context(context) when is_map(context) do
    request = map_value(context, :request) |> map_or_empty()
    metadata = metadata(context, request)
    coding = coding_context(context, request, metadata)

    session =
      first_map(
        map_value(context, :session),
        map_value(metadata, :session),
        map_value(request, :session)
      )

    channel =
      first_value(
        map_value(context, :channel),
        map_value(metadata, :channel),
        map_value(request, :channel)
      )

    surface =
      first_value(
        map_value(context, :surface),
        map_value(metadata, :surface),
        map_value(request, :surface)
      )

    operator_id =
      first_value(
        map_value(context, :operator_id),
        map_value(metadata, :operator_id),
        map_value(request, :operator_id)
      )

    actor =
      first_value(
        map_value(context, :actor),
        map_value(metadata, :actor),
        map_value(request, :actor),
        operator_id
      )

    cwd_jail = cwd_jail(context, coding)

    context
    |> maybe_put(:channel, channel)
    |> maybe_put(:surface, surface)
    |> maybe_put(:session, session)
    |> maybe_put(:operator_id, operator_id)
    |> maybe_put(
      :user_id,
      first_value(map_value(context, :user_id), map_value(request, :user_id), operator_id)
    )
    |> maybe_put(:actor, actor)
    |> maybe_put(:cwd_jail, cwd_jail)
    |> Map.put(:coding, coding)
  end

  defp coding_session?(context) do
    coding = map_value(context, :coding) |> map_or_empty()

    truthy?(map_value(coding, :pi_mode_enabled) || map_value(coding, :pi_mode_enabled?)) and
      binary_present?(
        map_value(coding, :cwd_jail) || map_value(coding, :workspace_root) ||
          map_value(context, :cwd_jail)
      )
  end

  defp metadata(context, request) do
    first_map(map_value(context, :metadata), map_value(request, :metadata))
  end

  defp coding_context(context, request, metadata) do
    context_coding = map_value(context, :coding) |> map_or_empty()
    metadata_coding = map_value(metadata, :coding) |> map_or_empty()
    request_coding = map_value(request, :coding) |> map_or_empty()

    request_coding
    |> Map.merge(metadata_coding)
    |> Map.merge(context_coding)
  end

  defp cwd_jail(context, coding) do
    first_value(
      map_value(context, :cwd_jail),
      map_value(context, :workspace_root),
      map_value(coding, :cwd_jail),
      map_value(coding, :workspace_root)
    )
  end

  defp denial_reason(:coding_session_required), do: "active Pi-mode coding session required"
  defp denial_reason(:local_coding_operator_required), do: "local coding operator tier required"

  defp first_map(left, right, fallback \\ %{})
  defp first_map(value, _right, _fallback) when is_map(value), do: value
  defp first_map(_value, value, _fallback) when is_map(value), do: value
  defp first_map(_value, _right, fallback) when is_map(fallback), do: fallback
  defp first_map(_value, _right, _fallback), do: %{}

  defp first_value(value, _second, _third, _fourth) when not is_nil(value), do: value
  defp first_value(_value, value, _third, _fourth) when not is_nil(value), do: value
  defp first_value(_value, _second, value, _fourth) when not is_nil(value), do: value
  defp first_value(_value, _second, _third, value), do: value

  defp first_value(value, _second, _third) when not is_nil(value), do: value
  defp first_value(_value, value, _third) when not is_nil(value), do: value
  defp first_value(_value, _second, value), do: value

  defp map_or_empty(value) when is_map(value), do: value
  defp map_or_empty(_value), do: %{}

  defp map_value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp binary_present?(value) when is_binary(value), do: String.trim(value) != ""
  defp binary_present?(_value), do: false

  defp truthy?(value), do: value in [true, "true", "1", 1, true, "enabled", :enabled]
end
