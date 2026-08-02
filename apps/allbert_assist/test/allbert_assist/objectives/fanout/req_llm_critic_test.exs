defmodule AllbertAssist.Objectives.Fanout.ReqLLMCriticTest do
  use ExUnit.Case, async: true

  @moduletag :pure_async

  alias AllbertAssist.Objectives.CanonicalJSON
  alias AllbertAssist.Objectives.Fanout.{ReqLLMCritic, ReviewProtocol}
  alias AllbertAssist.Objectives.Runs.Worker.QualityPolicy
  alias ReqLLM.Response

  @reviewer_config_domain "allbert:fanout-reviewer-config:v1\0"

  defmodule FixtureModels do
    def for(role, context) do
      send(context.test_pid, {:model_resolved, role})

      {:ok,
       %{
         profile: %{
           name: "review-profile",
           provider: "local_ollama",
           provider_type: "openai_compatible",
           model: "fixture-review-model",
           max_tokens: 2_048,
           timeout_ms: 5_000
         }
       }}
    end
  end

  defmodule AllowDisclosure do
    def authorize_transport(profile, context) do
      send(context.test_pid, {:transport_authorized, profile.name})
      :ok
    end
  end

  defmodule DenyDisclosure do
    def authorize_transport(_profile, context) do
      send(context.test_pid, :transport_denied)
      {:error, :operator_disclosure_required}
    end
  end

  defmodule UnavailableModels do
    def for(role, context) do
      send(context.test_pid, {:model_unavailable, role})
      {:error, :no_profile}
    end
  end

  defmodule RecordingReqLLM do
    def generate_object(model_spec, prompt, schema, opts) do
      send(
        Keyword.fetch!(opts, :test_pid),
        {:critic_provider_call, model_spec, prompt, schema, opts}
      )

      rule_ids =
        get_in(schema, ["properties", "assessments", "items", "properties", "rule_id", "enum"])

      group_id = get_in(schema, ["properties", "group_id", "enum"]) |> List.first()

      {:ok,
       %Response{
         id: "critic-response",
         model: "fixture-review-model",
         context: prompt,
         finish_reason: :stop,
         object: %{
           "group_id" => group_id,
           "assessments" =>
             Enum.map(rule_ids, fn rule_id ->
               %{
                 "rule_id" => rule_id,
                 "status" => "satisfied",
                 "source_handles" => ["task_contract", "candidate"]
               }
             end)
         }
       }}
    end
  end

  defmodule UnexpectedReqLLM do
    def generate_object(_model_spec, _prompt, _schema, opts) do
      send(Keyword.fetch!(opts, :test_pid), :unexpected_critic_provider_call)
      {:error, :unexpected_provider_call}
    end
  end

  defmodule IncompleteReqLLM do
    def generate_object(_model_spec, prompt, _schema, _opts) do
      {:ok,
       %Response{
         id: "incomplete-critic-response",
         model: "fixture-review-model",
         context: prompt,
         finish_reason: :length,
         object: %{"group_id" => "coverage_fidelity", "assessments" => []}
       }}
    end
  end

  test "one critic resolves the review role and makes one bounded group-specific call" do
    assert {:ok, protocol} = QualityPolicy.review_protocol()

    assert {:ok, source_bindings} =
             ReviewProtocol.bind_sources(
               %{"task_contract" => CanonicalJSON.encode(%{"task" => "bounded child"})},
               "Candidate answer."
             )

    assert {:ok, request} =
             ReviewProtocol.critic_request(protocol, "coverage_fidelity", source_bindings)

    now_unix_ms = System.system_time(:millisecond)
    now_monotonic_ms = System.monotonic_time(:millisecond)

    context = %{
      models: FixtureModels,
      disclosure: AllowDisclosure,
      req_llm_client: RecordingReqLLM,
      test_pid: self(),
      fanout_deadline_unix_ms: now_unix_ms + 2_000,
      fanout_review_deadline_monotonic_ms: now_monotonic_ms + 1_500,
      model_max_output_tokens: 1_024
    }

    assert {:ok,
            %{
              assessment: assessment,
              reviewer_config_sha256: reviewer_config_sha256
            }} = ReqLLMCritic.assess(request, context)

    assert assessment["group_id"] == "coverage_fidelity"

    assert Enum.map(assessment["assessments"], & &1["rule_id"]) ==
             hd(protocol.groups)["rule_ids"]

    assert_receive {:model_resolved, :fanout_review}
    assert_receive {:transport_authorized, "review-profile"}

    assert_receive {:critic_provider_call, %{provider: :openai, id: "fixture-review-model"},
                    prompt, schema, opts}

    assert hd(prompt.messages).metadata.allbert_prompt == %{
             schema_version: 2,
             purpose: :fanout_rule_critic,
             content_class: :allbert_instructions,
             rule_ids: Enum.map(hd(protocol.groups)["rule_ids"], &String.to_existing_atom/1)
           }

    assert List.last(prompt.messages).metadata.allbert_prompt.content_class == :advisory_data

    assert get_in(schema, ["properties", "group_id", "enum"]) == ["coverage_fidelity"]

    assert get_in(schema, ["properties", "assessments", "minItems"]) == 7
    assert get_in(schema, ["properties", "assessments", "maxItems"]) == 7

    assert get_in(schema, ["properties", "assessments", "items", "properties", "rule_id", "enum"]) ==
             hd(protocol.groups)["rule_ids"]

    assert get_in(schema, ["properties", "assessments", "items", "properties", "status", "enum"]) ==
             ["satisfied", "violated", "unresolved"]

    assert get_in(
             schema,
             [
               "properties",
               "assessments",
               "items",
               "properties",
               "source_handles",
               "items",
               "enum"
             ]
           ) == ["task_contract", "candidate"]

    assert opts[:temperature] == 0.0
    assert opts[:max_tokens] == 512
    assert opts[:receive_timeout] in 1..1_500
    assert opts[:max_retries] == 0
    assert opts[:openai_structured_output_mode] == :json_schema
    assert opts[:json_repair] == false

    expected_config = %{
      "version" => 1,
      "role" => "fanout_review",
      "model_profile" => "review-profile",
      "provider" => "local_ollama",
      "provider_type" => "openai_compatible",
      "model" => "fixture-review-model",
      "timeout_ms" => opts[:receive_timeout],
      "max_output_tokens" => 512,
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

    assert reviewer_config_sha256 ==
             sha256(@reviewer_config_domain <> CanonicalJSON.encode(expected_config))
  end

  test "profile disclosure and both deadlines fail before provider egress" do
    request = coverage_request!()
    now_unix_ms = System.system_time(:millisecond)
    now_monotonic_ms = System.monotonic_time(:millisecond)

    base_context = %{
      disclosure: AllowDisclosure,
      req_llm_client: UnexpectedReqLLM,
      test_pid: self(),
      fanout_deadline_unix_ms: now_unix_ms + 2_000,
      fanout_review_deadline_monotonic_ms: now_monotonic_ms + 1_500,
      model_max_output_tokens: 512
    }

    assert {:error, :fanout_review_profile_unavailable} =
             ReqLLMCritic.assess(request, Map.put(base_context, :models, UnavailableModels))

    assert_receive {:model_unavailable, :fanout_review}
    refute_receive :unexpected_critic_provider_call

    denied_context =
      base_context
      |> Map.put(:models, FixtureModels)
      |> Map.put(:disclosure, DenyDisclosure)

    assert {:error, :fanout_review_transport_denied} =
             ReqLLMCritic.assess(request, denied_context)

    assert_receive :transport_denied
    refute_receive :unexpected_critic_provider_call

    expired_context =
      base_context
      |> Map.put(:models, FixtureModels)
      |> Map.put(:fanout_review_deadline_monotonic_ms, now_monotonic_ms - 1)

    assert {:error, :fanout_plan_deadline_exhausted} =
             ReqLLMCritic.assess(request, expired_context)

    refute_receive :unexpected_critic_provider_call
  end

  test "a non-stop finish reason cannot produce critic evidence" do
    context = %{
      models: FixtureModels,
      disclosure: AllowDisclosure,
      req_llm_client: IncompleteReqLLM,
      test_pid: self(),
      fanout_deadline_unix_ms: System.system_time(:millisecond) + 2_000,
      fanout_review_deadline_monotonic_ms: System.monotonic_time(:millisecond) + 1_500,
      model_max_output_tokens: 512
    }

    assert {:error, :incomplete_fanout_review} =
             ReqLLMCritic.assess(coverage_request!(), context)
  end

  defp coverage_request! do
    assert {:ok, protocol} = QualityPolicy.review_protocol()

    assert {:ok, source_bindings} =
             ReviewProtocol.bind_sources(
               %{"task_contract" => CanonicalJSON.encode(%{"task" => "bounded child"})},
               "Candidate answer."
             )

    assert {:ok, request} =
             ReviewProtocol.critic_request(protocol, "coverage_fidelity", source_bindings)

    request
  end

  defp sha256(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
