defmodule AllbertAssist.Intent.Router.Optimizer do
  @moduledoc """
  v0.54 M9.3c (ADR 0062) — descriptor generation + the reindex/optimize entry point.

  `optimize/1` scans agent-exposed actions that have no resolved descriptor,
  generates a candidate descriptor for each (local model when available, else a
  heuristic from the action name/description), persists it, and rebuilds the index:

    * regular static actions  -> `:generated` YAML tier (loaded)
    * dynamic / write-code actions -> `:review` / learned-review tier (inert) unless
      `intent.descriptor_autoaccept` is true (then `:generated`)

  Generation is **local-only** (no egress) and advisory — a descriptor never grants
  authority (the action's own permission/confirmation gate is unchanged).
  """
  alias AllbertAssist.Actions.Registry, as: ActionsRegistry
  alias AllbertAssist.DynamicPlugins.ActionsOverlay
  alias AllbertAssist.Intent.Descriptor
  alias AllbertAssist.Intent.Eval.Gate
  alias AllbertAssist.Intent.Router.{DescriptorResolver, DescriptorStore, Index}
  alias AllbertAssist.Maps
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.ModelRuntime

  require Logger

  @model_schema [
    label: [
      type: :string,
      required: true,
      doc: "Short operator-facing label for this action."
    ],
    examples: [
      type: {:list, :string},
      required: true,
      doc: "Natural-language requests that should route to this action."
    ],
    synonyms: [
      type: {:list, :string},
      required: false,
      doc: "Short action phrases or aliases."
    ],
    required_slots: [
      type: {:list, :string},
      required: false,
      doc: "Required argument slot names, snake_case only."
    ],
    optional_slots: [
      type: {:list, :string},
      required: false,
      doc: "Optional argument slot names, snake_case only."
    ],
    negative_phrases: [
      type: {:list, :string},
      required: false,
      doc: "Phrases that look nearby but should not route to this action."
    ]
  ]
  @max_model_items 8
  @max_model_text 120
  @max_prompt_chars 5_000
  @slot_name ~r/^[a-z][a-z0-9_]*$/

  @spec optimize(keyword()) :: %{
          coverage: map(),
          generated: [String.t()],
          reviewed: [String.t()],
          rejected: [map()]
        }
  def optimize(opts \\ []) do
    strategy = Keyword.get(opts, :strategy, :model)
    dynamic = dynamic_action_names()
    autoaccept = autoaccept?()

    {generated, reviewed, rejected} =
      uncovered_agent_modules()
      |> Enum.reduce({[], [], []}, fn module, {gen, rev, rej} ->
        attrs = generate(module, strategy, opts)
        tier = tier_for(module.name(), dynamic, autoaccept)

        case accept_candidate(module, tier, attrs, strategy) do
          {:generated, name} -> {[name | gen], rev, rej}
          {:reviewed, name} -> {gen, [name | rev], rej}
          {:rejected, rejection} -> {gen, [module.name() | rev], [rejection | rej]}
        end
      end)

    rebuild_index(opts)

    %{
      coverage: coverage(),
      generated: Enum.reverse(generated),
      reviewed: Enum.reverse(reviewed),
      rejected: Enum.reverse(rejected)
    }
  end

  @doc "Coverage report over the agent-exposed action surface."
  @type coverage_report :: %{
          agent_exposed: non_neg_integer(),
          routable: non_neg_integer(),
          missing: non_neg_integer(),
          generated: non_neg_integer(),
          review_pending: non_neg_integer(),
          overridden: non_neg_integer()
        }

  @spec coverage() :: coverage_report()
  def coverage do
    agent = agent_action_names()
    resolved = resolved_action_names()

    %{
      agent_exposed: MapSet.size(agent),
      routable: MapSet.size(MapSet.intersection(agent, resolved)),
      missing: MapSet.size(MapSet.difference(agent, resolved)),
      generated: length(DescriptorStore.read_attrs(:generated)),
      review_pending: length(DescriptorStore.read_attrs(:review)),
      overridden: length(DescriptorStore.read_attrs(:overrides))
    }
  end

  @doc """
  Generate a candidate descriptor attrs map for an action module.

  `:heuristic` is the deterministic offline generator. `:model` asks the
  configured local `intent.router_model_profile` for a schema-constrained object
  through ReqLLM and falls back to the heuristic on any missing, disabled, remote,
  timed-out, invalid, or unavailable model path. Generated descriptors are advisory
  and operator-curatable regardless.
  """
  @spec generate(module(), :model | :heuristic) :: map()
  @spec generate(module(), :model | :heuristic, keyword()) :: map()
  def generate(module, strategy \\ :heuristic, opts \\ [])

  def generate(module, :model, opts) do
    case model_descriptor(module, opts) do
      {:ok, attrs} ->
        attrs

      {:error, reason} ->
        module
        |> heuristic()
        |> put_generation(:heuristic, %{fallback_reason: reason_label(reason)})
    end
  end

  def generate(module, :heuristic, _opts), do: heuristic(module)
  def generate(module, _strategy, opts), do: generate(module, :heuristic, opts)

  defp accept_candidate(module, :generated, attrs, strategy) do
    case Gate.check_promotion(attrs) do
      :ok ->
        {:ok, _path} = DescriptorStore.put(:generated, attrs)
        audit(module.name(), :generated, strategy)
        {:generated, module.name()}

      {:error, failures} ->
        review_attrs = Map.put(attrs, :gate_failures, failures)
        {:ok, _path} = DescriptorStore.put(:review, review_attrs)
        audit(module.name(), :review, strategy)

        {:rejected,
         %{
           action_name: module.name(),
           app_id: Map.get(attrs, :app_id),
           failures: failures
         }}
    end
  end

  defp accept_candidate(module, tier, attrs, strategy) do
    {:ok, _path} = DescriptorStore.put(tier, attrs)
    audit(module.name(), tier, strategy)
    {:reviewed, module.name()}
  end

  # ── generation ───────────────────────────────────────────────────────────────

  defp model_descriptor(module, opts) do
    client = Keyword.get(opts, :llm_client, ReqLLM)

    with :ok <- ensure_generation_client(client),
         {:ok, profile_name} <- router_model_profile(opts),
         {:ok, profile} <- Settings.resolve_model_profile(profile_name),
         :ok <- local_enabled_text_profile(profile),
         {:ok, spec} <- ModelRuntime.model_spec(profile),
         {:ok, response} <-
           client.generate_object(
             spec,
             model_prompt(module),
             @model_schema,
             request_opts(profile, opts)
           ),
         {:ok, object} <- response_object(response),
         {:ok, attrs} <- descriptor_attrs(module, object),
         :ok <- valid_descriptor?(attrs) do
      {:ok,
       put_generation(attrs, :model, %{
         model_profile: profile.name,
         model: profile.model,
         provider: profile.provider,
         endpoint_kind: profile.provider_endpoint_kind
       })}
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  catch
    :exit, reason -> {:error, reason}
  end

  defp heuristic(module) do
    name = module.name()
    phrase = String.replace(name, "_", " ")
    words = String.split(name, "_")

    %{
      app_id: app_id_for(name),
      action_name: name,
      label: phrase |> String.capitalize(),
      examples: Enum.uniq([phrase, "please #{phrase}"]),
      synonyms: Enum.uniq([phrase, hd(words)]),
      vocabulary: %{
        phrases: Enum.uniq([phrase]),
        negative_phrases: [],
        allow_single_token_match: false
      },
      required_slots: [],
      optional_slots: [],
      handoff_required?: true
    }
  end

  defp descriptor_attrs(module, object) when is_map(object) do
    with {:ok, label} <- required_text(field(object, :label), :label),
         {:ok, examples} <- required_text_list(field(object, :examples), :examples),
         {:ok, synonyms} <- optional_text_list(field(object, :synonyms, []), :synonyms),
         {:ok, required_slots} <- slot_list(field(object, :required_slots, [])),
         {:ok, optional_slots} <- slot_list(field(object, :optional_slots, [])),
         {:ok, negative_phrases} <-
           optional_text_list(field(object, :negative_phrases, []), :negative_phrases) do
      base = heuristic(module)
      phrases = Enum.uniq(examples ++ synonyms) |> Enum.take(@max_model_items)

      {:ok,
       %{
         base
         | label: label,
           examples: examples,
           synonyms: synonyms,
           vocabulary: %{
             phrases: phrases,
             negative_phrases: negative_phrases,
             allow_single_token_match: false
           },
           required_slots: required_slots,
           optional_slots: optional_slots -- required_slots,
           handoff_required?: true
       }}
    end
  end

  defp model_prompt(module) do
    snapshot =
      %{
        action_name: module.name(),
        description: module_text(module, :description),
        category: module_text(module, :category),
        tags: module_list(module, :tags),
        capability: capability_snapshot(module.name()),
        input_schema: schema_snapshot(module)
      }
      |> Redactor.redact()

    """
    Generate an Allbert intent descriptor for one already-registered action.

    Return only schema fields. Do not output secrets, endpoints, provider data,
    raw operator text, permissions, or implementation details. Descriptors are
    routing hints only; they never authorize execution.

    Guidance:
    - `label`: short human label.
    - `examples`: 3-8 natural operator requests that should route to this action.
    - `synonyms`: 2-8 short phrases for the same action.
    - `required_slots` / `optional_slots`: only argument names from the input schema,
      in snake_case. Leave empty if unsure.
    - `negative_phrases`: nearby requests that should not route to this action.

    Registered action metadata:
    #{inspect(snapshot, limit: :infinity)}
    """
    |> String.slice(0, @max_prompt_chars)
  end

  defp capability_snapshot(name) do
    case ActionsRegistry.capability(name) do
      {:ok, capability} ->
        %{
          app_id: capability.app_id || :allbert,
          permission: capability.permission,
          exposure: capability.exposure,
          execution_mode: capability.execution_mode,
          confirmation: capability.confirmation,
          skill_backed?: capability.skill_backed?,
          resumable?: capability.resumable?
        }

      _other ->
        %{}
    end
  end

  defp schema_snapshot(module) do
    module
    |> module_list(:schema)
    |> Enum.take(16)
    |> Enum.map(fn
      {name, opts} when is_list(opts) ->
        %{
          name: to_string(name),
          required?: Keyword.get(opts, :required, false) == true,
          type: opts |> Keyword.get(:type) |> inspect(limit: 10) |> String.slice(0, 80)
        }

      name ->
        %{name: to_string(name)}
    end)
  end

  # ── helpers ──────────────────────────────────────────────────────────────────

  defp uncovered_agent_modules do
    resolved = resolved_action_names()

    ActionsRegistry.agent_modules()
    |> Enum.reject(fn module -> MapSet.member?(resolved, module.name()) end)
  end

  defp resolved_action_names,
    do: DescriptorResolver.resolve() |> MapSet.new(& &1.action_name)

  defp agent_action_names,
    do: ActionsRegistry.agent_modules() |> MapSet.new(& &1.name())

  @spec dynamic_action_names() :: [String.t()]
  defp dynamic_action_names do
    ActionsOverlay.modules()
    |> Enum.map(& &1.name())
    |> Enum.uniq()
  rescue
    _exception -> []
  catch
    :exit, _reason -> []
  end

  @spec tier_for(String.t(), [String.t()], boolean()) :: :generated | :review
  defp tier_for(name, dynamic, autoaccept) do
    cond do
      name not in dynamic -> :generated
      autoaccept -> :generated
      true -> :review
    end
  end

  defp autoaccept? do
    case Settings.get("intent.descriptor_autoaccept") do
      {:ok, true} -> true
      _other -> false
    end
  end

  defp app_id_for(name) do
    case ActionsRegistry.capability(name) do
      {:ok, capability} -> capability.app_id || :allbert
      _other -> :allbert
    end
  rescue
    _exception -> :allbert
  end

  defp rebuild_index(opts) do
    if Keyword.get(opts, :rebuild, true), do: safe_rebuild()
  end

  defp safe_rebuild do
    Index.rebuild()
  rescue
    _exception -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp audit(name, tier, strategy) do
    Logger.info("[intent_descriptor_optimize] action=#{name} tier=#{tier} strategy=#{strategy}")
  end

  defp router_model_profile(opts) do
    case Keyword.get(opts, :model_profile) do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      _other ->
        case Settings.get("intent.router_model_profile") do
          {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
          _other -> {:error, :missing_router_model_profile}
        end
    end
  end

  defp local_enabled_text_profile(%{provider_endpoint_kind: kind}) when kind != "local_endpoint",
    do: {:error, :non_local_model_profile}

  defp local_enabled_text_profile(%{provider_enabled: enabled}) when enabled != true,
    do: {:error, :provider_disabled}

  defp local_enabled_text_profile(%{capabilities: capabilities}) do
    if "text_generation" in List.wrap(capabilities) do
      :ok
    else
      {:error, :missing_text_generation_capability}
    end
  end

  defp local_enabled_text_profile(_profile), do: {:error, :invalid_model_profile}

  defp request_opts(profile, opts) do
    timeout =
      Keyword.get(opts, :receive_timeout) ||
        setting_int("intent.router_model_timeout_ms", 4_000)

    profile
    |> ModelRuntime.request_opts()
    |> Keyword.merge(
      temperature: 0.0,
      max_tokens: ModelRuntime.max_tokens(profile, 512),
      receive_timeout: timeout,
      openai_structured_output_mode: :json_schema
    )
    |> Keyword.merge(Keyword.get(opts, :llm_opts, []))
  end

  defp response_object(%{object: object}) when is_map(object), do: {:ok, object}
  defp response_object(%{"object" => object}) when is_map(object), do: {:ok, object}

  defp response_object(response) do
    if Code.ensure_loaded?(ReqLLM.Response) do
      case ReqLLM.Response.object(response) do
        object when is_map(object) -> {:ok, object}
        _other -> {:error, :empty_model_object}
      end
    else
      {:error, :req_llm_response_unavailable}
    end
  end

  defp ensure_generation_client(client) do
    if Code.ensure_loaded?(client) and function_exported?(client, :generate_object, 4) do
      :ok
    else
      {:error, :req_llm_unavailable}
    end
  end

  defp valid_descriptor?(attrs) do
    case Descriptor.normalize(attrs) do
      {:ok, _descriptor} -> :ok
      {:error, diagnostic} -> {:error, {:invalid_model_descriptor, diagnostic}}
    end
  end

  defp required_text(value, field_name) do
    case bounded_text(value) do
      text when is_binary(text) and text != "" -> {:ok, text}
      _other -> {:error, {:invalid_model_field, field_name}}
    end
  end

  defp required_text_list(value, field_name) do
    with {:ok, values} <- optional_text_list(value, field_name),
         true <- values != [] do
      {:ok, values}
    else
      false -> {:error, {:invalid_model_field, field_name}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp optional_text_list(values, _field_name) when is_list(values) do
    values =
      values
      |> Enum.map(&bounded_text/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.take(@max_model_items)

    {:ok, values}
  end

  defp optional_text_list(_values, field_name), do: {:error, {:invalid_model_field, field_name}}

  defp bounded_text(value) when is_binary(value) do
    value =
      value
      |> String.trim()
      |> Redactor.redact()
      |> to_string()
      |> redact_embedded_secret_refs()
      |> String.trim()

    if value == "", do: nil, else: String.slice(value, 0, @max_model_text)
  end

  defp bounded_text(_value), do: nil

  defp redact_embedded_secret_refs(value),
    do: Regex.replace(~r/secret:\/\/[^\s,;]+/, value, "[SECRET_REF]")

  defp slot_list(values) when is_list(values) do
    values
    |> Enum.map(&slot_name/1)
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, nil}, {:ok, acc} -> {:cont, {:ok, acc}}
      {:ok, slot}, {:ok, acc} -> {:cont, {:ok, [slot | acc]}}
      {:error, reason}, _acc -> {:halt, {:error, reason}}
    end)
    |> case do
      {:ok, slots} -> {:ok, slots |> Enum.reverse() |> Enum.uniq()}
      {:error, reason} -> {:error, reason}
    end
  end

  defp slot_list(_values), do: {:error, :invalid_model_slots}

  defp slot_name(value) when is_binary(value) do
    value =
      value
      |> String.trim()
      |> String.downcase()

    cond do
      value == "" -> {:ok, nil}
      Regex.match?(@slot_name, value) -> {:ok, String.to_atom(value)}
      true -> {:error, {:invalid_model_slot, value}}
    end
  end

  defp slot_name(_value), do: {:error, :invalid_model_slot}

  defp put_generation(attrs, strategy, details) do
    generation =
      details
      |> Map.put(:strategy, Atom.to_string(strategy))
      |> Map.put(:source, "intent_descriptor_optimizer")
      |> Redactor.redact()

    Map.put(attrs, :generation, generation)
  end

  defp reason_label(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp reason_label(reason) do
    reason
    |> inspect(limit: 20, printable_limit: 200)
    |> Redactor.redact()
    |> to_string()
    |> String.slice(0, 200)
  end

  defp module_text(module, function) do
    if function_exported?(module, function, 0) do
      module
      |> apply(function, [])
      |> bounded_text()
    end
  rescue
    _exception -> nil
  catch
    :exit, _reason -> nil
  end

  defp module_list(module, function) do
    if function_exported?(module, function, 0) do
      case apply(module, function, []) do
        values when is_list(values) -> values
        _other -> []
      end
    else
      []
    end
  rescue
    _exception -> []
  catch
    :exit, _reason -> []
  end

  defp field(map, key, default \\ nil) when is_map(map),
    do: Maps.field_truthy(map, key) || default

  defp setting_int(key, default) do
    case Settings.get(key) do
      {:ok, value} when is_integer(value) -> value
      _other -> default
    end
  end
end
