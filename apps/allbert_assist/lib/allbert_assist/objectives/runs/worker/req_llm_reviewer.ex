defmodule AllbertAssist.Objectives.Runs.Worker.ReqLLMReviewer do
  @moduledoc """
  One-shot structured reviewer/reviser for a grounded DirectAnswer child.

  Preparation resolves the closed `fanout_synthesis` task route, disclosure,
  prompt, and remaining bounds without invoking a provider. `invoke/2` then
  spends exactly one advisory provider call. Neither phase is a registered
  capability action or grants durable completion authority.
  """

  alias AllbertAssist.FirstRun.Disclosure
  alias AllbertAssist.Maps
  alias AllbertAssist.Models.{ClosedRuleEvidence, PromptEnvelope}
  alias AllbertAssist.Objectives.{CanonicalJSON, ObservationSummary}
  alias AllbertAssist.Objectives.Runs.Worker.QualityPolicy
  alias AllbertAssist.Settings.{ModelRuntime, Models}
  alias ReqLLM.Response

  @reviewer_config_version 2
  @reviewer_config_domain "allbert:fanout-worker-reviewer-config:v2\0"
  @maximum_output_tokens 512
  @schema %{
    "type" => "object",
    "properties" => %{
      "final_answer" => %{
        "type" => "string",
        "description" => "The reviewed and, when needed, revised child answer itself."
      },
      "rule_violations" => ClosedRuleEvidence.schema!(QualityPolicy.rule_ids())
    },
    "required" => ["final_answer", "rule_violations"],
    "additionalProperties" => false
  }

  @type prepared :: %{
          required(:model_spec) => map(),
          required(:client) => module(),
          required(:profile) => map(),
          required(:prompt) => term(),
          required(:request_opts) => keyword(),
          required(:timeout_ms) => pos_integer(),
          required(:max_output_tokens) => pos_integer(),
          required(:reviewer_config_sha256) => String.t()
        }

  @doc "Resolve and authorize the reviewer without spending its provider call."
  @spec prepare(map(), String.t(), map()) :: {:ok, prepared()} | {:error, term()}
  def prepare(contract, draft, context)
      when is_map(contract) and is_binary(draft) and is_map(context) do
    with {:ok, _task_digest} <- QualityPolicy.digest(contract),
         draft <- ObservationSummary.normalize(draft),
         :ok <- nonempty_draft(draft),
         client <- req_llm_client(context),
         :ok <- ensure_req_llm(client),
         {:ok, %{profile: profile}} <- models(context).for(:fanout_synthesis, context),
         :ok <- disclosure(context).authorize_transport(profile, context),
         {:ok, model_spec} <- ModelRuntime.model_spec(profile),
         {:ok, timeout_ms} <- remaining_timeout(profile, context),
         {:ok, max_output_tokens} <- output_tokens(profile, context),
         {:ok, prompt} <- prompt(contract, draft),
         reviewer_config_sha256 <-
           reviewer_config_digest(profile, timeout_ms, max_output_tokens) do
      {:ok,
       %{
         model_spec: model_spec,
         client: client,
         profile: profile,
         prompt: prompt,
         request_opts: request_opts(profile, timeout_ms, max_output_tokens, context),
         timeout_ms: timeout_ms,
         max_output_tokens: max_output_tokens,
         reviewer_config_sha256: reviewer_config_sha256
       }}
    end
  rescue
    exception -> {:error, exception.__struct__}
  catch
    :exit, reason -> {:error, reason}
    kind, reason -> {:error, {kind, reason}}
  end

  def prepare(_contract, _draft, _context), do: {:error, :invalid_quality_review_request}

  @doc "Invoke the one prepared structured reviewer call and validate its closed result."
  @spec invoke(prepared(), map()) :: {:ok, map()} | {:error, term()}
  def invoke(%{} = prepared, context) when is_map(context) do
    with :ok <- valid_prepared(prepared),
         {:ok, response} <-
           prepared.client.generate_object(
             prepared.model_spec,
             prepared.prompt,
             @schema,
             prepared.request_opts
           ),
         :ok <- validate_finish_reason(response),
         object when is_map(object) <- response_object(response),
         {:ok, reviewed} <- QualityPolicy.validate_review(object) do
      {:ok, Map.put(reviewed, :reviewer_config_sha256, prepared.reviewer_config_sha256)}
    else
      nil -> {:error, :empty_quality_review}
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_quality_review}
    end
  rescue
    exception -> {:error, exception.__struct__}
  catch
    :exit, reason -> {:error, reason}
    kind, reason -> {:error, {kind, reason}}
  end

  def invoke(_prepared, _context), do: {:error, :invalid_quality_review_request}

  defp prompt(contract, draft) do
    with {:ok, projection} <- QualityPolicy.provider_projection(contract) do
      PromptEnvelope.build(
        purpose: :fanout_worker_quality_review,
        instruction:
          "Review the draft against every declared rule and return the answer itself after any necessary revision. " <>
            ClosedRuleEvidence.violation_semantics() <>
            " Allbert derives the aggregate outcome locally.",
        rules: Enum.map(QualityPolicy.rule_specs(), &{&1.id, &1.instruction}),
        input:
          CanonicalJSON.encode(%{
            "task_contract" => projection,
            "draft" => draft
          }),
        input_class: :advisory_data
      )
    end
  end

  defp remaining_timeout(profile, context) do
    now_unix_ms = System.system_time(:millisecond)
    now_monotonic_ms = System.monotonic_time(:millisecond)

    with {:ok, unix_remaining} <-
           required_remaining(Map.get(context, :fanout_deadline_unix_ms), now_unix_ms),
         {:ok, monotonic_remaining} <-
           required_remaining(
             Map.get(context, :fanout_worker_deadline_monotonic_ms),
             now_monotonic_ms
           ),
         profile_timeout when is_integer(profile_timeout) and profile_timeout > 0 <-
           Map.get(profile, :timeout_ms) do
      {:ok, Enum.min([profile_timeout, unix_remaining, monotonic_remaining])}
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_quality_review_timeout_bound}
    end
  end

  defp required_remaining(deadline, now) when is_integer(deadline) and deadline > now,
    do: {:ok, deadline - now}

  defp required_remaining(deadline, now) when is_integer(deadline) and deadline <= now,
    do: {:error, :fanout_plan_deadline_exhausted}

  defp required_remaining(_deadline, _now),
    do: {:error, :invalid_quality_review_timeout_bound}

  defp output_tokens(profile, context) do
    tokens =
      profile
      |> ModelRuntime.max_tokens(@maximum_output_tokens)
      |> min(Map.get(context, :model_max_output_tokens, @maximum_output_tokens))
      |> min(@maximum_output_tokens)

    if is_integer(tokens) and tokens > 0,
      do: {:ok, tokens},
      else: {:error, :invalid_quality_review_output_bound}
  end

  defp reviewer_config_digest(profile, timeout_ms, max_output_tokens) do
    config = %{
      "version" => @reviewer_config_version,
      "model_profile" => profile_value(profile, :name),
      "provider" => profile_value(profile, :provider),
      "model" => profile_value(profile, :model),
      "timeout_ms" => timeout_ms,
      "max_output_tokens" => max_output_tokens,
      "transport" => %{
        "closed_rule_evidence_version" => ClosedRuleEvidence.transport_version(),
        "response_schema_sha256" => sha256(CanonicalJSON.encode(@schema))
      }
    }

    sha256(@reviewer_config_domain <> CanonicalJSON.encode(config))
  end

  defp request_opts(profile, timeout_ms, max_output_tokens, context) do
    profile
    |> ModelRuntime.request_opts()
    |> Keyword.merge(
      temperature: 0.0,
      max_tokens: max_output_tokens,
      receive_timeout: timeout_ms,
      openai_structured_output_mode: :json_schema,
      json_repair: false
    )
    |> maybe_put_test_pid(context)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp valid_prepared(%{
         client: client,
         model_spec: model_spec,
         prompt: prompt,
         request_opts: opts,
         reviewer_config_sha256: digest
       })
       when is_atom(client) and is_map(model_spec) and is_list(opts) and is_binary(digest) and
              not is_nil(prompt),
       do: :ok

  defp valid_prepared(_prepared), do: {:error, :invalid_quality_review_request}

  defp nonempty_draft(draft) do
    if String.trim(draft) == "", do: {:error, :empty_quality_review_draft}, else: :ok
  end

  defp validate_finish_reason(response) do
    case response_finish_reason(response) do
      :stop -> :ok
      "stop" -> :ok
      nil -> {:error, :missing_quality_review_finish_reason}
      reason -> {:error, {:incomplete_quality_review, reason}}
    end
  end

  defp response_finish_reason(response) when is_map(response) do
    Map.get(response, :finish_reason) || Map.get(response, "finish_reason")
  end

  defp response_finish_reason(_response), do: nil

  defp response_object(response) do
    cond do
      is_map(response) and is_map(Maps.field_truthy(response, :object)) ->
        Maps.field_truthy(response, :object)

      Code.ensure_loaded?(Response) and function_exported?(Response, :object, 1) ->
        Response.object(response)

      true ->
        nil
    end
  end

  defp models(context), do: Map.get(context, :models, Models)
  defp disclosure(context), do: Map.get(context, :disclosure, Disclosure)
  defp req_llm_client(context), do: Map.get(context, :req_llm_client, ReqLLM)

  defp ensure_req_llm(client) do
    if Code.ensure_loaded?(client) and function_exported?(client, :generate_object, 4),
      do: :ok,
      else: {:error, :req_llm_unavailable}
  end

  defp maybe_put_test_pid(opts, %{test_pid: pid}) when is_pid(pid),
    do: Keyword.put(opts, :test_pid, pid)

  defp maybe_put_test_pid(opts, _context), do: opts

  defp profile_value(profile, key),
    do: Map.get(profile, key) || Map.get(profile, Atom.to_string(key))

  defp sha256(value) do
    :sha256
    |> :crypto.hash(value)
    |> Base.encode16(case: :lower)
  end
end
