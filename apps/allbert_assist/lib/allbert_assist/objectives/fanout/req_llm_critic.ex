defmodule AllbertAssist.Objectives.Fanout.ReqLLMCritic do
  @moduledoc """
  Shared one-call ReqLLM Adapter for one private fan-out critic group.

  The Adapter resolves the closed `fanout_review` task route and Disclosure
  immediately before egress, then requests only typed tri-state evidence for
  the assigned rules. It returns the raw structured assessment to
  `CriticAgent`, whose local protocol validation remains authoritative. It owns
  no Objective, persistence, retry loop, logging, revision, or effect authority.
  """

  alias AllbertAssist.FirstRun.Disclosure
  alias AllbertAssist.Maps
  alias AllbertAssist.Models.PromptEnvelope
  alias AllbertAssist.Objectives.CanonicalJSON
  alias AllbertAssist.Objectives.Fanout.{ReviewProtocol, ReviewRound}
  alias AllbertAssist.Settings.{ModelRuntime, Models}
  alias ReqLLM.Response

  @maximum_output_tokens 512
  @reviewer_config_version 1
  @reviewer_config_domain "allbert:fanout-reviewer-config:v1\0"
  @statuses ["satisfied", "violated", "unresolved"]
  @source_handles ["task_contract", "candidate"]
  @request_keys ~w[
    review_protocol_version policy_version rule_group_catalog_version
    rule_group_catalog_sha256 group sources
  ]
  @group_keys ~w[id rule_ids rules]

  @doc "Assess one closed rule group through the live fanout_review model route."
  @spec assess(map(), map()) :: {:ok, map()} | {:error, atom()}
  def assess(request, context) when is_map(request) and is_map(context) do
    with {:ok, group} <- validate_request(request),
         client <- req_llm_client(context),
         :ok <- ensure_req_llm(client),
         {:ok, %{profile: profile}} <- resolve_profile(context),
         :ok <- authorize_transport(profile, context),
         {:ok, model_spec} <- model_spec(profile),
         {:ok, timeout_ms} <- remaining_timeout(profile, context),
         {:ok, max_output_tokens} <- output_tokens(profile, context),
         {:ok, prompt} <- prompt(request, group),
         schema <- schema(group),
         opts <- request_opts(profile, timeout_ms, max_output_tokens, context),
         reviewer_config_sha256 <-
           reviewer_config_digest(
             profile,
             request,
             schema,
             timeout_ms,
             max_output_tokens
           ),
         {:ok, response} <- invoke(client, model_spec, prompt, schema, opts, context),
         :ok <- validate_finish_reason(response),
         object when is_map(object) <- response_object(response) do
      {:ok,
       %{
         assessment: object,
         reviewer_config_sha256: reviewer_config_sha256
       }}
    else
      nil -> {:error, :invalid_fanout_review_response}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _invalid -> {:error, :invalid_fanout_review_response}
    end
  rescue
    _exception -> {:error, :fanout_review_failed}
  catch
    :exit, _reason -> {:error, :fanout_review_failed}
    _kind, _reason -> {:error, :fanout_review_failed}
  end

  def assess(_request, _context), do: {:error, :invalid_fanout_review_request}

  defp validate_request(request) do
    with true <- exact_keys?(request, @request_keys),
         version when is_integer(version) and version > 0 <- request["review_protocol_version"],
         policy_version when is_integer(policy_version) and policy_version > 0 <-
           request["policy_version"],
         group_catalog_version
         when is_integer(group_catalog_version) and group_catalog_version > 0 <-
           request["rule_group_catalog_version"],
         true <- sha256?(request["rule_group_catalog_sha256"]),
         %{} = group <- request["group"],
         true <- valid_group?(group),
         true <- valid_sources?(request["sources"]) do
      {:ok, group}
    else
      _invalid -> {:error, :invalid_fanout_review_request}
    end
  end

  defp valid_group?(group) do
    exact_keys?(group, @group_keys) and nonempty?(group["id"]) and
      is_list(group["rule_ids"]) and group["rule_ids"] != [] and
      unique_nonempty_ids?(group["rule_ids"]) and is_list(group["rules"]) and
      Enum.map(group["rules"], &Map.get(&1, "id")) == group["rule_ids"] and
      Enum.all?(group["rules"], &valid_rule?/1)
  end

  defp valid_rule?(rule) when is_map(rule) do
    allowed_keys = ~w[id instruction criteria]
    keys = Map.keys(rule)

    keys != [] and Enum.all?(keys, &(&1 in allowed_keys)) and nonempty?(rule["id"]) and
      nonempty?(rule["instruction"])
  end

  defp valid_rule?(_rule), do: false

  defp valid_sources?(
         %{
           "task_contract" => %{"content" => task_contract},
           "candidate" => %{"content" => candidate}
         } = sources
       )
       when map_size(sources) == 2 and is_binary(task_contract) and is_binary(candidate) do
    case ReviewProtocol.bind_sources(%{"task_contract" => task_contract}, candidate) do
      {:ok, rebound} -> rebound == sources
      {:error, _reason} -> false
    end
  end

  defp valid_sources?(_sources), do: false

  defp resolve_profile(context) do
    case models(context).for(:fanout_review, context) do
      {:ok, %{profile: profile}} when is_map(profile) -> {:ok, %{profile: profile}}
      _unavailable -> {:error, :fanout_review_profile_unavailable}
    end
  end

  defp authorize_transport(profile, context) do
    case disclosure(context).authorize_transport(profile, context) do
      :ok -> :ok
      _denied -> {:error, :fanout_review_transport_denied}
    end
  end

  defp model_spec(profile) do
    case ModelRuntime.model_spec(profile) do
      {:ok, spec} -> {:ok, spec}
      {:error, _reason} -> {:error, :fanout_review_profile_unavailable}
    end
  end

  defp remaining_timeout(profile, context) do
    now_unix_ms = System.system_time(:millisecond)
    now_monotonic_ms = System.monotonic_time(:millisecond)

    with {:ok, unix_remaining} <-
           required_remaining(Map.get(context, :fanout_deadline_unix_ms), now_unix_ms),
         {:ok, monotonic_remaining} <-
           required_remaining(
             Map.get(context, :fanout_review_deadline_monotonic_ms),
             now_monotonic_ms
           ),
         profile_timeout when is_integer(profile_timeout) and profile_timeout > 0 <-
           Map.get(profile, :timeout_ms) do
      {:ok, Enum.min([profile_timeout, unix_remaining, monotonic_remaining])}
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_fanout_review_timeout_bound}
    end
  end

  defp required_remaining(deadline, now) when is_integer(deadline) and deadline > now,
    do: {:ok, deadline - now}

  defp required_remaining(deadline, now) when is_integer(deadline) and deadline <= now,
    do: {:error, :fanout_plan_deadline_exhausted}

  defp required_remaining(_deadline, _now),
    do: {:error, :invalid_fanout_review_timeout_bound}

  defp output_tokens(profile, context) do
    case Map.get(context, :model_max_output_tokens, @maximum_output_tokens) do
      context_max when is_integer(context_max) and context_max > 0 ->
        {:ok,
         profile
         |> ModelRuntime.max_tokens(@maximum_output_tokens)
         |> min(context_max)
         |> min(@maximum_output_tokens)}

      _invalid ->
        {:error, :invalid_fanout_review_output_bound}
    end
  end

  defp prompt(request, group) do
    with {:ok, rules} <- prompt_rules(group["rules"]) do
      input = %{
        "review_protocol_version" => request["review_protocol_version"],
        "policy_version" => request["policy_version"],
        "rule_group_catalog_version" => request["rule_group_catalog_version"],
        "rule_group_catalog_sha256" => request["rule_group_catalog_sha256"],
        "group" => Map.take(group, ~w[id rule_ids]),
        "sources" => request["sources"]
      }

      PromptEnvelope.build(
        purpose: :fanout_rule_critic,
        instruction:
          "Assess only the assigned rules against the supplied task contract and candidate. Return typed evidence only; do not revise the candidate, choose an action, or claim an effect.",
        rules: rules,
        input: CanonicalJSON.encode(input),
        input_class: :advisory_data
      )
    end
  end

  defp prompt_rules(rules) do
    rules
    |> Enum.reduce_while({:ok, []}, fn rule, {:ok, acc} ->
      try do
        id = String.to_existing_atom(rule["id"])
        {:cont, {:ok, [{id, rule["instruction"]} | acc]}}
      rescue
        ArgumentError -> {:halt, {:error, :invalid_fanout_review_request}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp schema(group) do
    rule_ids = group["rule_ids"]
    rule_count = length(rule_ids)

    %{
      "type" => "object",
      "properties" => %{
        "group_id" => %{"type" => "string", "enum" => [group["id"]]},
        "assessments" => %{
          "type" => "array",
          "minItems" => rule_count,
          "maxItems" => rule_count,
          "items" => %{
            "type" => "object",
            "properties" => %{
              "rule_id" => %{"type" => "string", "enum" => rule_ids},
              "status" => %{"type" => "string", "enum" => @statuses},
              "source_handles" => %{
                "type" => "array",
                "minItems" => 1,
                "maxItems" => length(@source_handles),
                "uniqueItems" => true,
                "items" => %{"type" => "string", "enum" => @source_handles}
              }
            },
            "required" => ["rule_id", "status", "source_handles"],
            "additionalProperties" => false
          }
        }
      },
      "required" => ["group_id", "assessments"],
      "additionalProperties" => false
    }
  end

  defp request_opts(profile, timeout_ms, max_output_tokens, context) do
    profile
    |> ModelRuntime.request_opts()
    |> Keyword.merge(
      temperature: 0.0,
      max_tokens: max_output_tokens,
      receive_timeout: timeout_ms,
      total_timeout: timeout_ms,
      max_retries: 0,
      openai_structured_output_mode: :json_schema,
      json_repair: false
    )
    |> maybe_put_test_pid(context)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp reviewer_config_digest(
         profile,
         request,
         schema,
         timeout_ms,
         max_output_tokens
       ) do
    config = %{
      "version" => @reviewer_config_version,
      "role" => "fanout_review",
      "model_profile" => profile_value(profile, :name),
      "provider" => profile_value(profile, :provider),
      "provider_type" => profile_value(profile, :provider_type),
      "model" => profile_value(profile, :model),
      "timeout_ms" => timeout_ms,
      "max_output_tokens" => max_output_tokens,
      "review_protocol_version" => request["review_protocol_version"],
      "policy_version" => request["policy_version"],
      "group_id" => request["group"]["id"],
      "rule_group_catalog_version" => request["rule_group_catalog_version"],
      "rule_group_catalog_sha256" => request["rule_group_catalog_sha256"],
      "transport" => %{
        "response_schema_sha256" => sha256(CanonicalJSON.encode(schema)),
        "temperature" => 0.0,
        "max_retries" => 0,
        "json_repair" => false,
        "structured_output_mode" => "json_schema"
      }
    }

    sha256(@reviewer_config_domain <> CanonicalJSON.encode(config))
  end

  defp invoke(client, model_spec, prompt, schema, opts, context) do
    with :ok <- ReviewRound.note_provider_attempt(context) do
      case client.generate_object(model_spec, prompt, schema, opts) do
        {:ok, response} -> {:ok, response}
        _failure -> {:error, :fanout_review_provider_failed}
      end
    end
  rescue
    _exception -> {:error, :fanout_review_provider_failed}
  catch
    :exit, _reason -> {:error, :fanout_review_provider_failed}
    _kind, _reason -> {:error, :fanout_review_provider_failed}
  end

  defp validate_finish_reason(response) do
    case response_finish_reason(response) do
      :stop -> :ok
      "stop" -> :ok
      _other -> {:error, :incomplete_fanout_review}
    end
  end

  defp response_finish_reason(%Response{} = response), do: Response.finish_reason(response)

  defp response_finish_reason(response) when is_map(response),
    do: Map.get(response, :finish_reason) || Map.get(response, "finish_reason")

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

  defp unique_nonempty_ids?(values) do
    Enum.all?(values, &nonempty?/1) and length(values) == MapSet.size(MapSet.new(values))
  end

  defp exact_keys?(map, keys), do: Enum.sort(Map.keys(map)) == Enum.sort(keys)
  defp nonempty?(value), do: is_binary(value) and String.trim(value) != ""

  defp sha256?(value) when is_binary(value) and byte_size(value) == 64 do
    case Base.decode16(value, case: :lower) do
      {:ok, bytes} -> byte_size(bytes) == 32
      :error -> false
    end
  end

  defp sha256?(_value), do: false

  defp sha256(value) do
    :sha256
    |> :crypto.hash(value)
    |> Base.encode16(case: :lower)
  end
end
