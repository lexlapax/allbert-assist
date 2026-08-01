defmodule AllbertAssist.Intent.FanoutManager do
  @moduledoc """
  Conversational planning Interface for one central Runtime turn.

  One DirectAnswer-qualified model call must return either a useful answer or
  an inert ordered `FanoutPlan`. Invalid structured output may receive one
  repair call. If repair cannot produce a valid plan, a useful answer already
  returned by the model is retained and the turn fails closed to single-task
  handling.

  This module is deliberately stateless. Durable work begins only after the
  caller hands a compiled plan to `AllbertAssist.Objectives`; model output does
  not grant action, permission, confirmation, identity, or scheduling authority.
  """

  alias AllbertAssist.FirstRun.Disclosure
  alias AllbertAssist.Intent.FanoutPlan
  alias AllbertAssist.Objectives.Fanout.Budget
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Models

  @default_model_client __MODULE__.ReqLLMImplementation
  @model_config __MODULE__
  @allowed_response_keys ~w[mode answer children_json]
  @max_request_bytes 4_000
  @max_answer_bytes 32_000
  @profile_binding_fields ~w[
    name
    provider
    provider_type
    provider_endpoint_kind
    model
    aliases
    capabilities
    media
    temperature
    max_tokens
    timeout_ms
    provider_base_url
    provider_api_key_ref
  ]a

  @type answer_result :: %{
          kind: :answer,
          message: String.t(),
          diagnostic: map()
        }
  @type fanout_result :: %{
          kind: :fanout,
          plan: FanoutPlan.t(),
          fallback_answer: String.t(),
          diagnostic: map()
        }
  @type clarification_result :: %{
          kind: :clarify,
          clarification: map(),
          fallback_answer: String.t(),
          diagnostic: map()
        }
  @type profile_binding :: %{required(String.t()) => term()}

  @spec respond(String.t(), map()) ::
          {:ok, answer_result() | fanout_result() | clarification_result()} | {:error, term()}
  def respond(text, context \\ %{})

  def respond(text, context) when is_binary(text) and is_map(context) do
    with :ok <- validate_request(text),
         :ok <- ensure_model_enabled(context),
         {:ok, profile} <- resolve_profile(context),
         :ok <- Disclosure.authorize_transport(profile, context),
         {:ok, budget_limits} <- Budget.limits(),
         context <- put_plan_deadline(context, profile, budget_limits),
         {:ok, response} <- call_model(text, profile, context, :initial) do
      resolve_initial(text, profile, context, response, budget_limits)
    end
  end

  def respond(_text, _context), do: {:error, :invalid_fanout_manager_request}

  @doc "Return a content-free binding for the exact qualified manager profile configuration."
  @spec profile_binding(map()) :: profile_binding()
  def profile_binding(profile) when is_map(profile) do
    %{
      "name" => profile_name(profile),
      "configuration_sha256" => profile_configuration_digest(profile)
    }
  end

  @doc "Verify a re-resolved profile against a durable content-free binding."
  @spec profile_matches?(map(), map()) :: boolean()
  def profile_matches?(profile, %{} = binding) when is_map(profile),
    do: profile_binding(profile) == binding

  def profile_matches?(_profile, _binding), do: false

  defp validate_request(text) do
    cond do
      String.trim(text) == "" -> {:error, :invalid_fanout_manager_request}
      byte_size(text) > @max_request_bytes -> {:error, :request_too_large_for_fanout}
      true -> :ok
    end
  end

  defp resolve_initial(text, profile, context, response, budget_limits) do
    case interpret_response(text, response, context) do
      {:ok, result} -> {:ok, decorate(result, profile, 1, budget_limits, context)}
      {:error, reason} -> repair_once(text, profile, context, response, reason, budget_limits)
    end
  end

  defp repair_once(text, profile, context, initial_response, initial_reason, budget_limits) do
    initial_answer = usable_answer(initial_response)

    case call_model(text, profile, context, {:repair, initial_reason}) do
      {:ok, repaired_response} ->
        case interpret_response(text, repaired_response, context) do
          {:ok, result} ->
            {:ok, decorate(result, profile, 2, budget_limits, context)}

          {:error, repair_reason} ->
            retain_answer_or_error(
              initial_answer || usable_answer(repaired_response),
              profile,
              initial_reason,
              repair_reason,
              budget_limits,
              context
            )
        end

      {:error, repair_reason} ->
        retain_answer_or_error(
          initial_answer,
          profile,
          initial_reason,
          repair_reason,
          budget_limits,
          context
        )
    end
  end

  defp retain_answer_or_error(
         answer,
         profile,
         initial_reason,
         repair_reason,
         budget_limits,
         context
       )
       when is_binary(answer) do
    {:ok,
     %{
       kind: :answer,
       message: answer,
       diagnostic: %{
         outcome: :answered_after_invalid_plan,
         attempts: attempted_calls(repair_reason),
         model_profile: profile_name(profile),
         model_profile_sha256: profile_configuration_digest(profile),
         budget_limits: budget_limits,
         plan_deadline_unix_ms: Map.fetch!(context, :fanout_plan_deadline_unix_ms),
         plan_error: initial_reason,
         repair_error: repair_reason
       }
     }}
  end

  defp retain_answer_or_error(
         nil,
         _profile,
         initial_reason,
         repair_reason,
         _budget_limits,
         _context
       ) do
    {:error, {:fanout_manager_failed, {initial_reason, repair_reason}}}
  end

  defp interpret_response(text, response, context) do
    with {:ok, object} <- closed_response(response),
         {:ok, answer} <- answer(Map.fetch!(object, "answer")),
         {:ok, children} <- decode_children(Map.fetch!(object, "children_json")) do
      interpret_mode(Map.fetch!(object, "mode"), text, answer, children, context)
    end
  end

  defp interpret_mode("answer", _text, answer, [], _context),
    do: {:ok, %{kind: :answer, message: answer}}

  defp interpret_mode("answer", _text, _answer, _children, _context),
    do: {:error, :answer_mode_includes_children}

  defp interpret_mode("fanout", text, answer, children, context) do
    case FanoutPlan.compile_admission(text, children,
           max_children: max_children(context),
           source: :model
         ) do
      {:ok, plan} ->
        {:ok, %{kind: :fanout, plan: plan, fallback_answer: answer}}

      {:clarify, clarification} ->
        {:ok, %{kind: :clarify, clarification: clarification, fallback_answer: answer}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp interpret_mode(_mode, _text, _answer, _children, _context),
    do: {:error, :invalid_manager_mode}

  defp closed_response(response) when is_map(response) do
    pairs = Enum.map(response, fn {key, value} -> {normalize_key(key), value} end)
    keys = Enum.map(pairs, &elem(&1, 0))

    if length(keys) == length(@allowed_response_keys) and
         Enum.sort(keys) == Enum.sort(@allowed_response_keys) do
      {:ok, Map.new(pairs)}
    else
      {:error, :invalid_manager_response_keys}
    end
  end

  defp answer(value) when is_binary(value) do
    value = String.trim(value)

    if value != "" and byte_size(value) <= @max_answer_bytes,
      do: {:ok, value},
      else: {:error, :invalid_manager_answer}
  end

  defp answer(_value), do: {:error, :invalid_manager_answer}

  defp usable_answer(response) when is_map(response) do
    response
    |> Enum.find_value(fn
      {key, value} when key in [:answer, "answer"] -> value
      _field -> nil
    end)
    |> answer()
    |> case do
      {:ok, answer} -> answer
      {:error, _reason} -> nil
    end
  end

  defp decode_children(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, children} when is_list(children) -> {:ok, children}
      {:ok, _other} -> {:error, :children_json_is_not_a_list}
      {:error, _reason} -> {:error, :invalid_children_json}
    end
  end

  defp decode_children(_value), do: {:error, :invalid_children_json}

  defp decorate(%{kind: :answer} = result, profile, attempts, budget_limits, context) do
    Map.put(result, :diagnostic, %{
      outcome: :answered,
      attempts: attempts,
      model_profile: profile_name(profile),
      model_profile_sha256: profile_configuration_digest(profile),
      budget_limits: budget_limits,
      plan_deadline_unix_ms: Map.fetch!(context, :fanout_plan_deadline_unix_ms)
    })
  end

  defp decorate(%{kind: :fanout} = result, profile, attempts, budget_limits, context) do
    Map.put(result, :diagnostic, %{
      outcome: :planned,
      attempts: attempts,
      model_profile: profile_name(profile),
      model_profile_sha256: profile_configuration_digest(profile),
      budget_limits: budget_limits,
      plan_deadline_unix_ms: Map.fetch!(context, :fanout_plan_deadline_unix_ms),
      semantic_validation: :model_claim,
      semantic_claims: [
        :independent_children,
        :advisory_or_read_only_children,
        :supplied_text_owned_by_outer_request
      ]
    })
  end

  defp decorate(%{kind: :clarify} = result, profile, attempts, budget_limits, context) do
    Map.put(result, :diagnostic, %{
      outcome: :overflow,
      attempts: attempts,
      model_profile: profile_name(profile),
      model_profile_sha256: profile_configuration_digest(profile),
      budget_limits: budget_limits,
      plan_deadline_unix_ms: Map.fetch!(context, :fanout_plan_deadline_unix_ms)
    })
  end

  defp call_model(text, profile, context, attempt) do
    with :ok <- authorize_manager_attempt(context, attempt),
         {:ok, timeout_ms} <- remaining_timeout(context) do
      client = model_client(context)

      call_context =
        context
        |> Map.put(:fanout_manager_attempt, attempt)
        |> Map.put(:timeout_ms, timeout_ms)

      case client.respond(text, profile, call_context) do
        {:ok, response} when is_map(response) -> {:ok, response}
        {:error, reason} -> {:error, {:model_call_failed, Redactor.redact(reason)}}
        _other -> {:error, {:model_call_failed, :invalid_callback_return}}
      end
    end
  rescue
    exception -> {:error, {:model_call_failed, exception.__struct__}}
  catch
    :exit, reason -> {:error, {:model_call_failed, Redactor.redact(reason)}}
    kind, reason -> {:error, {:model_call_failed, Redactor.redact({kind, reason})}}
  end

  defp authorize_manager_attempt(context, attempt) do
    Budget.authorize_manager_attempt(
      Map.fetch!(context, :fanout_budget_limits),
      manager_attempt_number(attempt)
    )
  end

  defp manager_attempt_number(:initial), do: 1
  defp manager_attempt_number({:repair, _reason}), do: 2

  defp model_client(context) do
    Map.get(context, :model_client) ||
      :allbert_assist
      |> Application.get_env(@model_config, [])
      |> Keyword.get(:model_client, @default_model_client)
  end

  defp ensure_model_enabled(%{model_enabled?: true}), do: :ok
  defp ensure_model_enabled(%{model_enabled?: false}), do: {:error, :direct_answer_model_disabled}

  defp ensure_model_enabled(_context) do
    case Settings.get("intent.direct_answer_model_enabled") do
      {:ok, true} -> :ok
      {:ok, false} -> {:error, :direct_answer_model_disabled}
      {:error, reason} -> {:error, {:settings_unavailable, reason}}
    end
  end

  defp resolve_profile(%{model_profile: profile}) when is_map(profile), do: {:ok, profile}

  defp resolve_profile(context) do
    case Models.for(:direct_answer, context) do
      {:ok, %{profile: profile}} -> {:ok, profile}
      {:error, reason} -> {:error, {:model_unavailable, reason}}
    end
  end

  defp max_children(context), do: Map.get(context, :max_children_per_fanout, 8)

  defp put_plan_deadline(context, profile, budget_limits) do
    request_timeout = Map.get(context, :timeout_ms, Map.get(profile, :timeout_ms, 10_000))

    timeout_ms =
      [request_timeout, Map.get(profile, :timeout_ms, 10_000), budget_limits.max_elapsed_ms]
      |> Enum.filter(&(is_integer(&1) and &1 > 0))
      |> Enum.min(fn -> 10_000 end)

    context
    |> Map.put(:fanout_budget_limits, budget_limits)
    |> Map.put(:fanout_manager_deadline_ms, System.monotonic_time(:millisecond) + timeout_ms)
    |> Map.put(
      :fanout_plan_deadline_unix_ms,
      System.system_time(:millisecond) + budget_limits.max_elapsed_ms
    )
  end

  defp remaining_timeout(context) do
    remaining =
      Map.fetch!(context, :fanout_manager_deadline_ms) - System.monotonic_time(:millisecond)

    if remaining > 0,
      do: {:ok, remaining},
      else: {:error, :fanout_manager_deadline_exhausted}
  end

  defp attempted_calls(:fanout_manager_deadline_exhausted), do: 1
  defp attempted_calls({:fanout_budget_exhausted, _detail}), do: 1
  defp attempted_calls(_repair_reason), do: 2

  defp profile_name(profile), do: Map.get(profile, :name) || Map.get(profile, "name")

  defp profile_configuration_digest(profile) do
    canonical =
      Enum.map(@profile_binding_fields, fn key ->
        value = Map.get(profile, key) || Map.get(profile, Atom.to_string(key))
        encoded = canonical_value(value)
        [Atom.to_string(key), ?:, Integer.to_string(byte_size(encoded)), ?:, encoded, ?;]
      end)

    :sha256
    |> :crypto.hash(canonical)
    |> Base.encode16(case: :lower)
  end

  defp canonical_value(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested} -> {to_string(key), nested} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {key, nested} -> [key, ?=, canonical_value(nested), ?;] end)
    |> IO.iodata_to_binary()
  end

  defp canonical_value(value) when is_list(value) do
    value
    |> Enum.map(fn nested ->
      encoded = canonical_value(nested)
      [Integer.to_string(byte_size(encoded)), ?:, encoded, ?;]
    end)
    |> IO.iodata_to_binary()
  end

  defp canonical_value(value), do: Jason.encode!(value)

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(key), do: inspect(key)
end
