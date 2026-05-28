defmodule AllbertAssist.Actions.Intent.DirectAnswer do
  @moduledoc """
  Side-effect-free response action for plain assistant prompts.
  """

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :agent,
    execution_mode: :read_only,
    skill_backed?: true,
    confirmation: :not_required,
    name: "direct_answer",
    description:
      "Answer a plain prompt without effectful tools; model mode may read bounded reviewed memory.",
    category: "intent",
    tags: ["intent", "safe", "read_only"],
    schema: [
      text: [type: :string, required: true, doc: "User prompt to answer."]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Memory.ActiveMemory
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Settings

  @answerer_config __MODULE__
  @default_answerer __MODULE__.ReqLLMAnswerer
  @fallback_source :bounded_fallback
  @max_reason_bytes 240

  @impl true
  def run(%{text: text}, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)
    {message, direct_answer} = answer(text, context, permission_decision)

    {:ok,
     %{
       message: message,
       status: PermissionGate.response_status(permission_decision),
       permission_decision: permission_decision,
       direct_answer: direct_answer,
       actions: [
         %{
           name: "direct_answer",
           status: :completed,
           permission: :read_only,
           permission_decision: permission_decision,
           direct_answer: direct_answer
         }
       ]
     }}
  end

  defp answer(text, context, permission_decision) do
    if PermissionGate.allowed?(permission_decision) do
      case Settings.get("intent.direct_answer_model_enabled") do
        {:ok, true} -> model_answer(text, context)
        {:ok, false} -> fallback(:model_disabled)
        {:error, reason} -> fallback({:settings_unavailable, reason})
      end
    else
      fallback(:permission_denied)
    end
  end

  defp model_answer(text, context) do
    with {:ok, profile_name} <- direct_answer_model_profile(),
         {:ok, profile} <- Settings.resolve_model_profile(profile_name),
         :ok <- ensure_provider_enabled(profile),
         active_memory <- retrieve_active_memory(text, context),
         {:ok, response} <-
           answerer().answer(
             text,
             Map.merge(context, %{model_profile: profile, active_memory: active_memory.chunks})
           ) do
      {
        response.message,
        %{
          source: :model,
          model_profile: profile.name,
          provider: profile.provider,
          model: profile.model,
          active_memory: ActiveMemory.trace_metadata(active_memory),
          diagnostic: Map.get(response, :diagnostic, %{status: :used})
        }
      }
    else
      {:error, reason} -> fallback({:model_unavailable, reason})
    end
  end

  defp ensure_provider_enabled(%{provider: provider}) when is_binary(provider) do
    case Settings.list_provider_profiles() do
      {:ok, providers} ->
        case Enum.find(providers, &(&1.name == provider)) do
          %{enabled: true} -> :ok
          %{enabled: false} -> {:error, {:provider_disabled, provider}}
          nil -> {:error, {:unknown_provider, provider}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_provider_enabled(profile), do: {:error, {:invalid_model_profile, profile}}

  defp direct_answer_model_profile do
    case Settings.get("intent.direct_answer_model_profile") do
      {:ok, profile} when is_binary(profile) and profile != "" ->
        {:ok, profile}

      _missing_or_invalid ->
        Settings.get("intent.model_profile")
    end
  end

  defp retrieve_active_memory(text, context) do
    params = %{
      query: text,
      user_id: context_value(context, :user_id) || context_value(context, :actor),
      thread_id: context_value(context, :thread_id),
      active_app: context_value(context, :active_app),
      now: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }

    case Runner.run("retrieve_active_memory", params, context) do
      {:ok, %{status: :completed, active_memory: active_memory}} ->
        active_memory

      {:ok, %{active_memory: active_memory}} when is_map(active_memory) ->
        Map.merge(empty_active_memory(), active_memory)

      _other ->
        empty_active_memory()
    end
  end

  defp empty_active_memory do
    %{
      status: :unavailable,
      enabled?: false,
      query_terms_normalized: [],
      scope: %{},
      candidate_count_before_filter: 0,
      candidate_chunk_count_before_filter: 0,
      candidate_count_after_filter: 0,
      chunks: [],
      retrieved_chunks: [],
      excluded_chunks_sample: []
    }
  end

  defp context_value(context, key) do
    Map.get(context, key) ||
      get_in(context, [:request, key]) ||
      get_in(context, [:request, Atom.to_string(key)])
  end

  defp fallback(reason) do
    {
      fallback_message(reason),
      %{
        source: @fallback_source,
        reason: bounded_reason(reason),
        model_enabled?: model_enabled?(),
        diagnostic: %{status: :fallback}
      }
    }
  end

  defp fallback_message(reason) do
    detail =
      case reason do
        :model_disabled ->
          "The direct-answer model is disabled."

        :permission_denied ->
          "The read-only answer boundary was denied."

        {:settings_unavailable, _reason} ->
          "The direct-answer settings could not be read."

        {:model_unavailable, _reason} ->
          "The configured direct-answer model was unavailable."
      end

    """
    I kept this turn side-effect-free and did not run tools, app actions, memory writes, shell commands, package installs, browser actions, or resource requests.

    #{detail}
    """
    |> String.trim()
  end

  defp answerer do
    :allbert_assist
    |> Application.get_env(@answerer_config, [])
    |> Keyword.get(:answerer, @default_answerer)
  end

  defp model_enabled? do
    case Settings.get("intent.direct_answer_model_enabled") do
      {:ok, enabled?} -> enabled?
      _other -> false
    end
  rescue
    _exception -> false
  end

  defp bounded_reason(reason) do
    reason
    |> Redactor.redact()
    |> inspect()
    |> then(fn value ->
      if byte_size(value) <= @max_reason_bytes do
        value
      else
        binary_part(value, 0, @max_reason_bytes) <> "...[truncated]"
      end
    end)
  end
end
