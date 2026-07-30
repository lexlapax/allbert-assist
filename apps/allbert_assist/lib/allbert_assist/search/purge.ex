defmodule AllbertAssist.Search.Purge do
  @moduledoc """
  Canonical-policy precondition and content-free preview boundary for Search purge.

  Projection replacement remains owned by `AllbertAssist.Search.Projection`;
  this context only proves that recurring ingestion cannot immediately restore
  the confirmed target.
  """

  alias AllbertAssist.Conversations.Corpus
  alias AllbertAssist.Search.Control
  alias AllbertAssist.Search.Projection
  alias AllbertAssist.Settings

  @doc "Build an exact HMAC-bound preview after checking current Corpus policy."
  def preview(params, operator_id) do
    with {:ok, target} <- Control.normalize_target(params),
         :ok <- precondition(target, operator_id),
         {:ok, scope} <- Projection.purge_scope(target),
         {:ok, preview} <- Control.bind_preview(target, scope) do
      {:ok, preview}
    end
  end

  @doc "Recheck the approved target immediately before destructive phases."
  def precondition(target, operator_id) when is_map(target) and is_binary(operator_id) do
    case target["target_kind"] do
      "source_ids" -> source_ids_ineligible(target["target_ids"], operator_id)
      "source_class" -> search_disabled()
      "all" -> search_disabled()
      _other -> {:error, :invalid_purge_target}
    end
  end

  def precondition(_target, _operator_id), do: {:error, :invalid_purge_target}

  defp source_ids_ineligible(source_ids, operator_id) do
    policies()
    |> Enum.reduce_while(:ok, fn policy, :ok ->
      case Corpus.rehydrate_and_authorize(operator_id, source_ids, policy) do
        {:ok, results} ->
          policy_result(results)

        {:error, reason}
        when reason in [:origin_grant_required, :e2ee_grant_required, :consumer_disabled] ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp policy_result(results) do
    if Enum.any?(results, &match?({:ok, _envelope}, &1)),
      do: {:halt, {:error, :purge_target_still_eligible}},
      else: {:cont, :ok}
  end

  defp search_disabled do
    case Settings.get("search.enabled") do
      {:ok, false} -> :ok
      {:ok, true} -> {:error, :search_must_be_disabled}
      {:error, reason} -> {:error, reason}
    end
  end

  defp policies do
    grants = setting("search.origin_grants", ["local_operator"])

    [
      %{consumer: :search, origin_scope: :local_operator, e2ee?: false},
      if("mapped_operator_dm" in grants,
        do: %{
          consumer: :search,
          origin_scope: :mapped_operator_dm,
          e2ee?: "e2ee_operator" in grants
        }
      )
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp setting(key, default) do
    case Settings.get(key) do
      {:ok, value} -> value
      {:error, _reason} -> default
    end
  end
end
