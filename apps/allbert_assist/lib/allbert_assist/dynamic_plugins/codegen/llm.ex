defmodule AllbertAssist.DynamicPlugins.Codegen.LLM do
  @moduledoc """
  Injectable LLM boundary for source-bearing dynamic code generation.

  Production uses `Jido.AI.generate_object/3` so generation returns a
  schema-constrained object. Tests can inject a provider with the same
  `generate_role/5` contract, which keeps CI deterministic while preserving
  the real provider boundary.
  """

  alias AllbertAssist.DynamicPlugins.Codegen.Schema
  alias AllbertAssist.Runtime.Redactor

  @type role :: :planner | :author | :trial_author | :critic | :repair

  @callback generate_role(role(), map(), map(), map(), map()) ::
              {:ok, map()} | {:error, term()}

  @doc "Generate one structured role packet."
  @spec generate_role(role(), map(), map(), map(), map()) :: {:ok, map()} | {:error, term()}
  def generate_role(role, input, profile, budget, context)
      when is_atom(role) and is_map(input) and is_map(profile) and is_map(budget) and
             is_map(context) do
    provider().generate_role(role, input, profile, budget, context)
  end

  defp provider do
    :allbert_assist
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:provider, __MODULE__.JidoAI)
  end

  defmodule JidoAI do
    @moduledoc false

    alias AllbertAssist.DynamicPlugins.Codegen.Schema
    alias AllbertAssist.DynamicPlugins.Delegate
    alias AllbertAssist.Runtime.Redactor
    alias AllbertAssist.Settings

    @spec generate_role(atom(), map(), map(), map(), map()) ::
            {:ok, map()} | {:error, term()}
    def generate_role(role, input, profile, budget, context) do
      prompt = prompt(role, input, budget, context)

      with :ok <- ensure_jido_ai!(),
           {:ok, result} <-
             Jido.AI.generate_object(
               prompt,
               Schema.role_schema(role),
               [
                 model: model_option(profile),
                 system_prompt: system_prompt(role),
                 max_tokens: Map.get(profile, :max_tokens) || 2_000,
                 temperature: Map.get(profile, :temperature) || 0.1,
                 timeout: Map.get(profile, :timeout_ms) || 30_000
               ]
               |> maybe_put_base_url(profile)
               |> maybe_put_provider_options(profile)
             ),
           {:ok, object} <- response_object(result) do
        {:ok, normalize_object(role, object, result, prompt)}
      else
        {:error, reason} -> {:error, reason}
      end
    rescue
      exception -> {:error, Exception.message(exception)}
    catch
      :exit, reason -> {:error, reason}
    end

    defp ensure_jido_ai! do
      if Code.ensure_loaded?(Jido.AI) do
        :ok
      else
        {:error, :jido_ai_unavailable}
      end
    end

    defp response_object(%ReqLLM.Response{} = response) do
      case ReqLLM.Response.object(response) do
        object when is_map(object) -> {:ok, object}
        nil -> {:error, :empty_dynamic_codegen_object}
      end
    end

    defp normalize_object(role, object, result, prompt) do
      object
      |> Map.take(role_fields(role))
      |> Map.put_new("notes", [])
      |> Map.put_new("usage", response_usage(result))
      |> Map.put_new("prompt_hash", prompt_hash(prompt))
      |> Redactor.redact()
    end

    defp response_usage(%ReqLLM.Response{} = response), do: ReqLLM.Response.usage(response) || %{}

    defp role_fields(:planner) do
      ~w[target_shape permission_ceiling summary acceptance_criteria constraints test_strategy notes usage_units]
    end

    defp role_fields(:author), do: ~w[action_name description source notes usage_units]
    defp role_fields(:trial_author), do: ~w[test_source focused_test_paths notes usage_units]
    defp role_fields(:critic), do: ~w[verdict findings repair_instructions notes usage_units]

    defp role_fields(:repair) do
      ~w[status action_name description source test_source notes usage_units]
    end

    defp model_option(%{model: model, provider_type: provider_type})
         when is_binary(model) and model != "" do
      model_spec(provider_type, model)
    end

    defp model_option(%{name: name}) when is_binary(name), do: model_alias_or_spec(name)
    defp model_option(%{model: model}) when is_binary(model), do: model
    defp model_option(_profile), do: :fast

    defp model_spec(provider_type, model) do
      cond do
        provider_prefixed?(model) ->
          model

        provider = req_llm_provider(provider_type) ->
          "#{provider}:#{model}"

        true ->
          model
      end
    end

    defp provider_prefixed?(model) do
      case String.split(model, ":", parts: 2) do
        [provider, _model] ->
          provider in ~w[anthropic openai openai_codex openrouter google mistral]

        _other ->
          false
      end
    end

    defp req_llm_provider("openai"), do: "openai"
    defp req_llm_provider("openai_compatible"), do: "openai"
    defp req_llm_provider("local"), do: "openai"
    defp req_llm_provider("anthropic"), do: "anthropic"
    defp req_llm_provider("openrouter"), do: "openrouter"
    defp req_llm_provider(_provider_type), do: nil

    defp model_alias_or_spec("fast"), do: :fast
    defp model_alias_or_spec("capable"), do: :capable
    defp model_alias_or_spec("slow"), do: :slow
    defp model_alias_or_spec("thinking"), do: :thinking
    defp model_alias_or_spec("gpt"), do: :gpt
    defp model_alias_or_spec("local"), do: :local
    defp model_alias_or_spec(name), do: name

    defp maybe_put_base_url(opts, %{provider_type: "openai", provider_base_url: nil}) do
      Keyword.put(opts, :base_url, "https://api.openai.com/v1")
    end

    defp maybe_put_base_url(opts, %{provider_base_url: base_url})
         when is_binary(base_url) and base_url != "" do
      Keyword.put(opts, :base_url, base_url)
    end

    defp maybe_put_base_url(opts, _profile), do: opts

    defp maybe_put_provider_options(opts, %{provider_type: "openrouter"}) do
      Keyword.put(opts, :provider_options,
        openrouter_structured_output_mode: :json_schema,
        openrouter_usage: %{include: true}
      )
    end

    defp maybe_put_provider_options(opts, _profile), do: opts

    defp system_prompt(:planner) do
      """
      You are the Planner in Allbert's dynamic code generation committee.

      Return only the requested structured object. Convert the explicit
      capability gap into an implementation spec for one action. The target_shape
      must be "action". The permission_ceiling must be one of the configured
      generated action permissions. If the plan needs memory or external network
      effects, it must require delegation through one configured reviewed facade;
      otherwise use read_only. Do not request settings writes, secrets, direct
      network calls, dependencies, package installs, sandbox execution, routes,
      child processes, or durable private loops. Every schema field is required:
      use [] for empty lists and 0 for usage_units when provider usage is
      unavailable.
      """
    end

    defp system_prompt(:author) do
      """
      You are the Author in Allbert's dynamic code generation committee.

      Return only the requested structured object. The source and test_source
      are separate role outputs; return source only. Use placeholders
      {{MODULE}} and {{ACTION_NAME}} instead of hard-coded module/action names.
      The action must use AllbertAssist.Action with one configured permission,
      exposure :internal, execution_mode matching that permission, skill_backed?:
      false, confirmation :not_required, and resumable?: false. Pure read-only
      actions must output %{message: string, status: :completed, actions: []}.
      Effectful actions must call only
      AllbertAssist.DynamicPlugins.Delegate.run("facade_name", params, context)
      with a literal configured facade name; they must not call any Allbert
      action, Settings, confirmation, resource, memory, network, or protected
      subsystem directly. Do not use System, File, Code, Mix, Application,
      Process, Port, Node, Repo, dependencies, @on_load, dynamic atoms, or direct
      network calls. The only allowed macro is the required
      `use AllbertAssist.Action` declaration. Every schema field is required:
      use an empty string for action_name when the default name is fine, [] for
      notes when there are no notes, and 0 for usage_units when provider usage
      is unavailable.
      """
    end

    defp system_prompt(:trial_author) do
      """
      You are the TrialAuthor in Allbert's dynamic code generation committee.

      Return only the requested structured object. Write one focused ExUnit test
      file for the generated action. Use placeholders {{TEST_MODULE}} and
      {{MODULE}} instead of hard-coded module names. The test must call
      {{MODULE}}.run/2 directly, assert the expected deterministic response, and
      stay deterministic. For delegated writes, assert the delegated facade
      response shape without bypassing facade policy. Every schema field is
      required: use [] for empty lists and 0 for usage_units when provider usage
      is unavailable.
      """
    end

    defp system_prompt(:critic) do
      """
      You are the Critic in Allbert's dynamic code generation committee.

      Return only the requested structured object. Review the plan, source,
      test, and deterministic validation evidence. Your output is advisory: it
      can accept, reject, or request repair, but it cannot trust, integrate, or
      authorize anything. Request repair if placeholders, action metadata,
      literal delegation, deterministic behavior, or validation diagnostics are
      not clean.
      Every schema field is required: use an empty repair_instructions string
      when accepted, [] for empty lists, and 0 for usage_units when provider
      usage is unavailable.
      """
    end

    defp system_prompt(:repair) do
      """
      You are the Repair role in Allbert's dynamic code generation committee.

      Return only the requested structured object. If repair is unnecessary,
      return status "not_needed" and empty source/test_source. If repair is
      possible, return status "repaired" with complete replacement source and
      test_source. Use placeholders {{MODULE}}, {{TEST_MODULE}}, and
      {{ACTION_NAME}}. Do not broaden permissions beyond the configured policy
      or introduce any protected runtime authority. The source must include the
      literal text `use AllbertAssist.Action` and
      `confirmation: :not_required`; non-read-only effects must use only
      AllbertAssist.DynamicPlugins.Delegate.run/3 with a literal configured
      facade. Every schema field is required: use empty strings for unused
      source fields, [] for empty lists, and 0 for usage_units when provider
      usage is unavailable.
      """
    end

    defp prompt(:planner, input, budget, context) do
      """
      Plan one Allbert action for this explicit capability gap.

      Gap:
      #{Jason.encode!(Map.get(input, "gap", %{}))}

      Budget:
      #{Jason.encode!(Map.take(budget, ["provider_calls_budget", "provider_usage_units_budget"]))}

      Request context:
      #{Jason.encode!(Redactor.redact(Map.take(context, [:actor, :channel, :surface])))}

      Dynamic codegen policy:
      #{Jason.encode!(generation_policy())}
      """
    end

    defp prompt(:author, input, _budget, _context) do
      """
      Write the action source for this generation plan.

      Plan:
      #{Jason.encode!(Map.get(input, "planner", %{}))}

      Gap:
      #{Jason.encode!(Map.get(input, "gap", %{}))}

      Dynamic codegen policy:
      #{Jason.encode!(generation_policy())}

      Requirements:
      - Generate normal deterministic Elixir logic. It may format strings, do
        arithmetic/comparison, iterate lists, and call Delegate.run/3 only when
        the selected permission/facade policy requires a reviewed effect.
      - For read_only, keep the action body pure.
      - For memory_write, use only Delegate.run("append_memory", params, context).
      - For external_network, use only Delegate.run("external_network_request", params, context).
      - Adapt one of these source skeletons; keep the literal placeholders
        {{MODULE}} and {{ACTION_NAME}} in the source field.

      #{required_action_template()}

      #{required_delegated_action_template()}

      - Keep source under 160 lines.
      """
    end

    defp prompt(:trial_author, input, _budget, _context) do
      """
      Write focused ExUnit tests for this generated action.

      Plan:
      #{Jason.encode!(Map.get(input, "planner", %{}))}

      Source summary:
      #{Jason.encode!(Map.get(input, "source_summary", %{}))}

      Dynamic codegen policy:
      #{Jason.encode!(generation_policy())}

      Requirements:
      - Include one focused ExUnit test that calls {{MODULE}}.run/2 directly.
      - Adapt this exact test skeleton; keep the literal placeholders
        {{TEST_MODULE}} and {{MODULE}} in the test_source field:

      #{required_test_template()}

      - Keep test_source under 120 lines.
      """
    end

    defp prompt(:critic, input, _budget, _context) do
      """
      Review this generated action attempt.

      Plan:
      #{Jason.encode!(Map.get(input, "planner", %{}))}

      Deterministic evidence:
      #{Jason.encode!(Map.get(input, "evidence", %{}))}

      Source summary:
      #{Jason.encode!(Map.get(input, "source_summary", %{}))}

      Test summary:
      #{Jason.encode!(Map.get(input, "test_summary", %{}))}

      Dynamic codegen policy:
      #{Jason.encode!(generation_policy())}
      """
    end

    defp prompt(:repair, input, _budget, _context) do
      """
      Repair this generated action attempt if needed.

      Plan:
      #{Jason.encode!(Map.get(input, "planner", %{}))}

      Critic:
      #{Jason.encode!(Map.get(input, "critic", %{}))}

      Deterministic evidence:
      #{Jason.encode!(Map.get(input, "evidence", %{}))}

      Current source:
      #{Map.get(input, "source", "")}

      Current test_source:
      #{Map.get(input, "test_source", "")}

      Replacement source skeleton:
      #{required_action_template()}

      Replacement delegated source skeleton:
      #{required_delegated_action_template()}

      Replacement test_source skeleton:
      #{required_test_template()}
      """
    end

    defp prompt(_role, input, _budget, _context), do: Jason.encode!(input)

    defp required_action_template do
      ~S"""
      Pure read-only template:

      defmodule {{MODULE}} do
        use AllbertAssist.Action,
          permission: :read_only,
          exposure: :internal,
          execution_mode: :read_only,
          skill_backed?: false,
          confirmation: :not_required,
          name: "{{ACTION_NAME}}",
          description: "Summarize a name, score, and tags.",
          category: "dynamic_plugins",
          tags: ["dynamic", "generated"],
          schema: [
            name: [type: :string, required: false],
            score: [type: :integer, required: false],
            tags: [type: {:list, :string}, required: false]
          ],
          output_schema: [
            message: [type: :string, required: true],
            status: [type: :atom, required: true],
            actions: [type: {:list, :map}, required: true]
          ]

        @impl true
        def run(params, _context) do
          name = params |> Map.get(:name, "item") |> to_string() |> String.trim()
          tags = Map.get(params, :tags, [])
          normalized_tags = Enum.map(tags, fn tag -> tag |> to_string() |> String.upcase() end)
          score = Map.get(params, :score, 0)
          adjusted_score = score + Enum.count(normalized_tags)

          tier =
            if adjusted_score >= 10 do
              "high"
            else
              "normal"
            end

          message =
            name <>
              ": " <>
              tier <>
              " score=" <>
              Integer.to_string(adjusted_score) <>
              " tags=" <>
              Enum.join(normalized_tags, ", ")

          {:ok, %{message: message, status: :completed, actions: []}}
        end
      end
      """
    end

    defp required_delegated_action_template do
      ~S"""
      Delegated reviewed-facade template:

      defmodule {{MODULE}} do
        use AllbertAssist.Action,
          permission: :memory_write,
          exposure: :internal,
          execution_mode: :memory_write,
          skill_backed?: false,
          confirmation: :not_required,
          resumable?: false,
          name: "{{ACTION_NAME}}",
          description: "Delegate a reviewed memory write.",
          category: "dynamic_plugins",
          tags: ["dynamic", "generated", "delegated"],
          schema: [
            memory: [type: :string, required: true],
            source_text: [type: :string, required: false]
          ],
          output_schema: [
            message: [type: :string, required: true],
            status: [type: :atom, required: true],
            actions: [type: {:list, :map}, required: true]
          ]

        @impl true
        def run(params, context) do
          memory = params |> Map.get(:memory, "") |> to_string() |> String.trim()

          delegate_params = %{
            memory: memory,
            source_text: Map.get(params, :source_text)
          }

          AllbertAssist.DynamicPlugins.Delegate.run("append_memory", delegate_params, context)
        end
      end
      """
    end

    defp required_test_template do
      ~S"""
      defmodule {{TEST_MODULE}} do
        use ExUnit.Case, async: true

        test "generated read-only action summarizes params" do
          assert {:ok, %{status: :completed, message: message, actions: []}} =
                   {{MODULE}}.run(%{name: " Ada ", score: 8, tags: ["math", "code"]}, %{})

          assert message == "Ada: high score=10 tags=MATH, CODE"
        end
      end
      """
    end

    defp generation_policy do
      allowed_facades = allowed_facades()

      %{
        "allowed_action_permissions" => allowed_action_permissions(),
        "allowed_facades" =>
          Enum.map(allowed_facades, fn facade ->
            {:ok, permission} = Delegate.facade_permission(facade)
            %{"name" => facade, "permission" => Atom.to_string(permission)}
          end),
        "delegation_rules" => %{
          "append_memory" => "Use only with permission :memory_write.",
          "external_network_request" => "Use only with permission :external_network."
        }
      }
    end

    defp allowed_action_permissions do
      case Settings.get("dynamic_codegen.allowed_action_permissions") do
        {:ok, values} when is_list(values) -> Enum.map(values, &to_string/1)
        _other -> ["read_only"]
      end
    end

    defp allowed_facades do
      hard_facades = Delegate.hard_facades()

      case Settings.get("dynamic_codegen.allowed_facades") do
        {:ok, values} when is_list(values) ->
          values
          |> Enum.map(&to_string/1)
          |> Enum.filter(&(&1 in hard_facades))

        _other ->
          []
      end
    end

    defp prompt_hash(prompt) do
      hash =
        :sha256
        |> :crypto.hash(prompt)
        |> Base.encode16(case: :lower)

      "sha256:" <> hash
    end
  end
end
