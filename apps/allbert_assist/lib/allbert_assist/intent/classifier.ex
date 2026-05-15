defmodule AllbertAssist.Intent.Classifier do
  @moduledoc """
  Optional bounded model-assist hook for v0.19 intent ranking.

  The classifier is disabled by default. When enabled, model output can only
  choose among candidates already collected and validated by the deterministic
  engine.
  """

  alias AllbertAssist.Intent.Candidate
  alias AllbertAssist.Security.Redactor
  alias AllbertAssist.Settings

  defmodule Behaviour do
    @moduledoc "Behaviour for model-assisted intent candidate classifiers."

    @callback classify([map()], map()) :: {:ok, map()} | {:error, term()}
  end

  @default_classifier AllbertAssist.Intent.Classifier.DefaultClassifier
  @summary_limit 20
  @reason_limit 240

  @type result :: {:ok, %{candidate: Candidate.t() | map(), diagnostic: map()}} | {:error, map()}

  @spec classify([Candidate.t()], map()) :: result()
  def classify(candidates, request), do: classify(candidates, request, [])

  @spec classify([Candidate.t()], map(), keyword()) :: result()
  def classify(candidates, request, opts) when is_list(candidates) and is_map(request) do
    with {:ok, true} <- setting("intent.model_assist_enabled"),
         {:ok, profile} <- model_profile(),
         {:ok, timeout_ms} <- setting("intent.model_timeout_ms"),
         {:ok, min_confidence} <- setting("intent.model_min_confidence"),
         {:ok, proposal} <-
           classifier(opts).classify(candidate_summary(candidates), %{
             text: bounded_text(field(request, :text)),
             model_profile: profile,
             timeout_ms: timeout_ms,
             min_confidence: min_confidence
           }),
         {:ok, selected} <- validate_proposal(proposal, candidates, min_confidence) do
      {:ok,
       %{
         candidate: selected,
         diagnostic:
           diagnostic(:used, %{
             confidence: confidence(proposal),
             selected_id: selected.id,
             selected_kind: selected.kind,
             reason: bounded_text(field(proposal, :reason))
           })
       }}
    else
      {:ok, false} ->
        {:error, diagnostic(:disabled)}

      {:error, %{} = diagnostic} ->
        {:error, diagnostic}

      {:error, reason} ->
        {:error, diagnostic(:rejected, %{reason: inspect(Redactor.redact(reason))})}
    end
  rescue
    exception ->
      {:error, diagnostic(:rejected, %{reason: Exception.message(exception)})}
  catch
    :exit, reason ->
      {:error, diagnostic(:rejected, %{reason: inspect(Redactor.redact(reason))})}
  end

  def classify(_candidates, _request, _opts), do: {:error, diagnostic(:invalid_input)}

  @spec candidate_summary([Candidate.t() | map()]) :: [map()]
  def candidate_summary(candidates) when is_list(candidates) do
    candidates
    |> Enum.take(@summary_limit)
    |> Enum.map(fn candidate ->
      %{
        kind: field(candidate, :kind),
        id: field(candidate, :id),
        label: bounded_text(field(candidate, :label)),
        score: field(candidate, :score),
        source: field(candidate, :source),
        reason: bounded_text(field(candidate, :reason))
      }
      |> Redactor.redact()
    end)
  end

  defp model_profile do
    with {:ok, profile_name} <- setting("intent.model_profile"),
         {:ok, profile} <- Settings.resolve_model_profile(profile_name) do
      {:ok, profile}
    end
  end

  defp validate_proposal(proposal, candidates, min_confidence) when is_map(proposal) do
    selected_kind = normalize_kind(field(proposal, :selected_kind))
    selected_id = field(proposal, :selected_id)
    proposal_confidence = confidence(proposal)

    cond do
      not is_binary(selected_id) ->
        {:error, diagnostic(:invalid_proposal, %{reason: :missing_selected_id})}

      is_nil(selected_kind) ->
        {:error, diagnostic(:invalid_proposal, %{reason: :invalid_selected_kind})}

      not is_number(proposal_confidence) ->
        {:error, diagnostic(:invalid_proposal, %{reason: :invalid_confidence})}

      proposal_confidence < min_confidence ->
        {:error,
         diagnostic(:low_confidence, %{confidence: proposal_confidence, minimum: min_confidence})}

      true ->
        select_candidate(candidates, selected_kind, selected_id)
    end
  end

  defp validate_proposal(_proposal, _candidates, _min_confidence),
    do: {:error, diagnostic(:invalid_proposal, %{reason: :invalid_shape})}

  defp select_candidate(candidates, selected_kind, selected_id) do
    case Enum.find(
           candidates,
           &(field(&1, :kind) == selected_kind and field(&1, :id) == selected_id)
         ) do
      nil ->
        {:error,
         diagnostic(:unknown_candidate, %{selected_kind: selected_kind, selected_id: selected_id})}

      candidate ->
        {:ok, candidate}
    end
  end

  defp classifier(opts) do
    Keyword.get(opts, :classifier) ||
      :allbert_assist
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:classifier, @default_classifier)
  end

  defp setting(key) do
    case Settings.get(key) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, reason}
    end
  end

  defp confidence(proposal) do
    case field(proposal, :confidence) do
      value when is_integer(value) -> value / 1
      value when is_float(value) -> value
      _other -> nil
    end
  end

  defp normalize_kind(value) when is_atom(value), do: value

  defp normalize_kind(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.to_existing_atom()
  rescue
    ArgumentError -> nil
  end

  defp normalize_kind(_value), do: nil

  defp diagnostic(status, attrs \\ %{}) do
    %{
      classifier: :intent_model_assist,
      status: status
    }
    |> Map.merge(attrs)
    |> Redactor.redact()
  end

  defp bounded_text(nil), do: nil

  defp bounded_text(value) when is_atom(value), do: bounded_text(Atom.to_string(value))

  defp bounded_text(value) when is_binary(value) do
    if byte_size(value) <= @reason_limit do
      value
    else
      binary_part(value, 0, @reason_limit) <> "...[truncated]"
    end
  end

  defp bounded_text(value), do: value |> inspect() |> bounded_text()

  defp field(map, key, default \\ nil) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end
end
