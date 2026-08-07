defmodule AllbertAssist.Settings do
  @moduledoc """
  Settings Central for Allbert-owned operator configuration.
  """

  alias AllbertAssist.Conversations.Corpus
  alias AllbertAssist.FirstRun.Disclosure
  alias AllbertAssist.Jobs.Managed
  alias AllbertAssist.Pack.EffectGuard
  alias AllbertAssist.Memory.ReviewCadence
  alias AllbertAssist.Settings.ModelRoles
  alias AllbertAssist.Settings.Schema
  alias AllbertAssist.Settings.Secrets
  alias AllbertAssist.Settings.Store

  @legacy_key_aliases %{
    "workspace.theme" => "workspace.theme.mode"
  }
  @write_key_aliases %{
    "intent.model_profile" => {:single, "model_preferences.primary"},
    "intent.direct_answer_model_profile" => {:list, "model_preferences.tasks.direct_answer"}
  }

  defdelegate root(), to: Store
  defdelegate ensure_root!(), to: Store
  defdelegate read_user_settings(), to: Store

  # The central facade is an effect boundary.  Store remains deliberately pure
  # so fixture/setup code can use it directly; product writes must carry E1.
  def write_user_settings(settings, opts \\ []),
    do: write_user_settings(settings, opts, %{})

  def write_user_settings(settings, opts, context) when is_map(context) do
    result =
      with :ok <- validate_effect_epoch(context),
           {:ok, _settings} = write_result <- Store.write_user_settings(settings, opts) do
        write_result
      end

    case result do
      {:ok, _settings} = result ->
        _diagnostics = reconcile_direct_answer_disclosure()
        result

      error ->
        error
    end
  end

  def write_user_settings(_settings, _opts, _context), do: {:error, :product_not_ready}

  # v1.0.2 M8.4: turn-scoped resolved-settings snapshot — pin one resolution
  # per intent turn / policy evaluation. See `Store.with_resolved_settings/1`
  # for the write-visibility semantics.
  defdelegate with_resolved_settings(fun), to: Store

  def defaults, do: Schema.defaults()
  def schema, do: Schema.schema()
  def setting_metadata(key), do: Schema.setting_metadata(key)
  def safe_write_keys, do: Schema.safe_write_keys()

  def known_key?(key) when is_binary(key), do: key |> canonical_key() |> Schema.known_key?()

  def safe_write_key?(key) when is_binary(key),
    do: key |> canonical_key() |> Schema.safe_write_key?()

  def list(namespace_or_opts \\ []) do
    namespace = namespace(namespace_or_opts)

    with {:ok, settings, user_settings} <- Store.resolved_settings() do
      settings
      |> flatten()
      |> Enum.filter(fn {key, _value} ->
        is_nil(namespace) or String.starts_with?(key, namespace)
      end)
      |> Enum.map(fn {key, value} -> resolved_setting(key, value, settings, user_settings) end)
      |> Enum.sort_by(& &1.key)
      |> then(&{:ok, &1})
    end
  end

  def get(key, context \\ %{}) when is_binary(key) do
    with {:ok, resolved} <- resolve(key, context) do
      {:ok, resolved.value}
    end
  end

  def put(key, value, context \\ %{}) when is_binary(key) do
    key = canonical_key(key)
    {storage_key, storage_value} = write_key_value(key, value)

    with :ok <- validate_write_alias_value(key, value),
         # This remains adjacent to the Store mutation: none of the audit,
         # signal, or post-write reconciliation paths run after E1 is stale.
         :ok <- validate_effect_epoch(context),
         {:ok, settings, user_settings, diagnostics} <-
           Store.put_user_setting(storage_key, storage_value, context) do
      diagnostics =
        diagnostics ++
          post_write_diagnostics(key, value, context) ++
          maybe_reconcile_direct_answer_disclosure(storage_key)

      resolved = resolved_setting(key, Schema.get_dotted(settings, key), settings, user_settings)

      {:ok,
       resolved
       |> Map.put(:context, sanitize_context(context))
       |> Map.put(:diagnostics, diagnostics)}
    end
  end

  def resolve(key, _context \\ %{}) when is_binary(key) do
    key = canonical_key(key)

    with {:ok, settings, user_settings} <- Store.resolved_settings() do
      if Schema.known_key?(key) do
        {:ok, resolved_setting(key, Schema.get_dotted(settings, key), settings, user_settings)}
      else
        {:error, :not_found}
      end
    end
  end

  def explain(key, context \\ %{}), do: resolve(key, context)

  def validate(settings_or_key_value, opts \\ [])

  def validate({key, value}, opts) when is_binary(key) do
    key = canonical_key(key)
    settings = Keyword.get(opts, :settings, defaults())
    Schema.validate_key_value(key, value, settings)
  end

  def validate(settings, opts) when is_map(settings), do: Schema.validate_settings(settings, opts)

  def list_provider_profiles do
    with {:ok, settings, _user_settings} <- Store.resolved_settings() do
      settings
      |> Map.get("providers", %{})
      |> Enum.map(fn {name, attrs} -> provider_profile(name, attrs, :redacted) end)
      |> Enum.sort_by(& &1.name)
      |> then(&{:ok, &1})
    end
  end

  def list_model_profiles do
    with {:ok, settings, _user_settings} <- Store.resolved_settings() do
      settings
      |> Map.get("model_profiles", %{})
      |> Enum.map(fn {name, attrs} -> model_profile(name, attrs, settings, :redacted) end)
      |> Enum.sort_by(& &1.name)
      |> then(&{:ok, &1})
    end
  end

  def resolve_model_profile(name, _context \\ %{}) when is_binary(name) do
    with {:ok, settings, _user_settings} <- Store.resolved_settings(),
         {:ok, attrs} <- fetch_named(settings, "model_profiles", name) do
      {:ok, model_profile(name, attrs, settings, :runtime)}
    end
  end

  def resolve_provider_profile(name, _context \\ %{}) when is_binary(name) do
    with {:ok, settings, _user_settings} <- Store.resolved_settings(),
         {:ok, attrs} <- fetch_named(settings, "providers", name) do
      {:ok, provider_profile(name, attrs, :runtime)}
    end
  end

  defp provider_profile(name, attrs, mode) do
    api_key_ref = Map.get(attrs, "api_key_ref")

    profile = %{
      name: name,
      type: Map.get(attrs, "type"),
      enabled: Map.get(attrs, "enabled", false),
      endpoint_kind: endpoint_kind(name, attrs),
      credential_status: secret_status(api_key_ref)
    }

    case mode do
      :runtime ->
        Map.merge(profile, %{base_url: Map.get(attrs, "base_url"), api_key_ref: api_key_ref})

      :redacted ->
        profile
    end
  end

  defp model_profile(name, attrs, settings, mode) do
    provider = Map.get(attrs, "provider")
    provider_attrs = get_in(settings, ["providers", provider]) || %{}
    api_key_ref = Map.get(provider_attrs, "api_key_ref")

    profile = %{
      name: name,
      provider: provider,
      provider_type: Map.get(provider_attrs, "type"),
      provider_enabled: Map.get(provider_attrs, "enabled", false),
      provider_endpoint_kind: endpoint_kind(provider, provider_attrs),
      model: Map.get(attrs, "model"),
      aliases: Map.get(attrs, "aliases", []),
      capabilities: Map.get(attrs, "capabilities", []),
      media: Map.get(attrs, "media", %{}),
      temperature: Map.get(attrs, "temperature"),
      max_tokens: Map.get(attrs, "max_tokens"),
      timeout_ms: Map.get(attrs, "timeout_ms"),
      credential_status: secret_status(api_key_ref)
    }

    case mode do
      :runtime ->
        Map.merge(profile, %{
          provider_base_url: Map.get(provider_attrs, "base_url"),
          provider_api_key_ref: api_key_ref
        })

      :redacted ->
        profile
    end
  end

  defp secret_status(nil), do: :missing
  defp secret_status(ref), do: Secrets.status(ref)

  defp endpoint_kind("local_ollama", attrs),
    do: Map.get(attrs, "endpoint_kind") || "local_endpoint"

  defp endpoint_kind(_name, attrs), do: Map.get(attrs, "endpoint_kind") || "credentialed_remote"

  defp resolved_setting(key, value, settings, user_settings) do
    {value, default_value, operator_value} = resolved_values(key, value, settings, user_settings)
    source = if is_nil(operator_value), do: :default, else: :operator
    metadata = Schema.setting_metadata(key)

    %{
      key: key,
      value: Secrets.redact(key, value),
      source: source,
      writable?: Schema.safe_write_key?(key),
      sensitive?: Schema.sensitive_key?(key),
      deprecated?: Map.get(metadata, :deprecated?, false),
      deprecation_reason: Map.get(metadata, :deprecation_reason),
      layers: layers(default_value, operator_value),
      diagnostics: [],
      namespace: key |> String.split(".", parts: 2) |> List.first()
    }
  end

  defp layers(default_value, nil), do: [%{source: :default, value: default_value}]

  defp layers(default_value, operator_value) do
    [
      %{source: :default, value: default_value},
      %{source: :operator, value: operator_value}
    ]
  end

  defp flatten(map), do: flatten(map, [])

  defp flatten(map, prefix) when is_map(map) do
    Enum.flat_map(map, fn {key, value} -> flatten(value, prefix ++ [key]) end)
  end

  defp flatten(value, prefix), do: [{Enum.join(prefix, "."), value}]

  defp fetch_named(settings, namespace, name) do
    case get_in(settings, [namespace, name]) do
      attrs when is_map(attrs) -> {:ok, attrs}
      _other -> {:error, :not_found}
    end
  end

  defp namespace(opts) when is_list(opts), do: Keyword.get(opts, :namespace)
  defp namespace(namespace) when is_binary(namespace), do: namespace
  defp namespace(_namespace), do: nil

  defp canonical_key(key), do: Map.get(@legacy_key_aliases, key, key)

  defp write_key_value(key, value) do
    case Map.get(@write_key_aliases, key) do
      {:single, storage_key} -> {storage_key, value}
      {:list, storage_key} -> {storage_key, [value]}
      nil -> {key, value}
    end
  end

  # Write aliases preserve their legacy scalar contract even when their storage
  # target accepts a broader value shape. In particular, task preference lists
  # may contain model-role references, while the legacy direct-answer selector
  # remains a concrete-profile-only setting.
  defp validate_write_alias_value("intent.direct_answer_model_profile" = key, value)
       when is_binary(value) do
    if ModelRoles.reference?(value),
      do: {:error, {:invalid_setting, key, {:unknown_model_profile, value}}},
      else: :ok
  end

  defp validate_write_alias_value(_key, _value), do: :ok

  defp resolved_values("intent.model_profile", _value, settings, user_settings) do
    key = "model_preferences.primary"

    {
      Schema.get_dotted(settings, key),
      Schema.get_dotted(defaults(), key),
      Schema.get_dotted(user_settings, key)
    }
  end

  defp resolved_values("intent.direct_answer_model_profile", _value, settings, user_settings) do
    key = "model_preferences.tasks.direct_answer"

    value =
      settings
      |> Schema.get_dotted(key)
      |> preference_head(Schema.get_dotted(settings, "model_preferences.primary"))

    default_value =
      defaults()
      |> Schema.get_dotted(key)
      |> preference_head(Schema.get_dotted(defaults(), "model_preferences.primary"))

    operator_value =
      case Schema.get_dotted(user_settings, key) do
        nil ->
          nil

        profiles ->
          preference_head(profiles, Schema.get_dotted(settings, "model_preferences.primary"))
      end

    {value, default_value, operator_value}
  end

  defp resolved_values(key, value, _settings, user_settings) do
    {value, Schema.get_dotted(defaults(), key), Schema.get_dotted(user_settings, key)}
  end

  defp preference_head([head | _rest], _fallback), do: head
  defp preference_head(_profiles, fallback), do: fallback

  defp sanitize_context(context) when is_map(context) do
    Map.drop(context, [:secret, "secret", :api_key, "api_key", :token, "token"])
  end

  defp post_write_diagnostics("memory.review_cadence", value, context) do
    case ReviewCadence.sync(value, context) do
      {:ok, diagnostic} -> [diagnostic]
      {:error, reason} -> [%{source: :memory_review_cadence, error: inspect(reason)}]
    end
  rescue
    exception ->
      [
        %{
          source: :memory_review_cadence,
          error: Exception.message(exception),
          kind: exception.__struct__
        }
      ]
  end

  defp post_write_diagnostics(key, _value, context)
       when key in ["search.enabled", "search.origin_grants"] do
    if context_value(context, :skip_search_policy_reconcile?) do
      []
    else
      with {:ok, epoch} <- Corpus.bump_eligibility_epoch(:search),
           {:ok, reconciliation} <- Managed.reconcile("local") do
        [
          %{
            source: :search_policy,
            eligibility_epoch: epoch,
            reconciliation: reconciliation,
            kicks: kick_search_jobs()
          }
        ]
      else
        {:error, reason} -> [%{source: :search_policy, error: inspect(reason)}]
      end
    end
  end

  defp post_write_diagnostics(key, _value, context)
       when key in ["memory.consolidation.enabled", "memory.collection.origin_grants"] do
    if context_value(context, :skip_memory_policy_reconcile?) do
      []
    else
      with {:ok, epoch} <- Corpus.bump_eligibility_epoch(:memory),
           {:ok, reconciliation} <- Managed.reconcile("local") do
        [
          %{
            source: :memory_policy,
            eligibility_epoch: epoch,
            reconciliation: reconciliation
          }
        ]
      else
        {:error, reason} -> [%{source: :memory_policy, error: inspect(reason)}]
      end
    end
  end

  defp post_write_diagnostics("channels." <> key, _value, _context) do
    if String.ends_with?(key, ".identity_map") do
      case Corpus.bump_eligibility_epoch(:all) do
        {:ok, epochs} ->
          [
            %{
              source: :corpus_identity_policy,
              eligibility_epochs: epochs,
              kicks: kick_search_jobs()
            }
          ]

        {:error, reason} ->
          [%{source: :corpus_identity_policy, error: inspect(reason)}]
      end
    else
      []
    end
  rescue
    exception ->
      [
        %{
          source: :corpus_identity_policy,
          error: Exception.message(exception),
          kind: exception.__struct__
        }
      ]
  end

  defp post_write_diagnostics(_key, _value, _context), do: []

  defp maybe_reconcile_direct_answer_disclosure(key) do
    if direct_answer_affecting_key?(key) do
      reconcile_direct_answer_disclosure()
    else
      []
    end
  end

  defp direct_answer_affecting_key?(key) do
    key in [
      "intent.direct_answer_model_enabled",
      "model_preferences.primary",
      "model_preferences.tasks.direct_answer",
      "model_preferences.tasks.fanout_manager",
      "model_preferences.tasks.fanout_synthesis",
      "models.fallback.enabled",
      "models.fallback.allow_local_to_hosted"
    ] or String.starts_with?(key, "model_profiles.") or
      String.starts_with?(key, "model_roles.") or
      String.starts_with?(key, "providers.")
  end

  defp reconcile_direct_answer_disclosure do
    case Disclosure.reconcile_current_direct_answer_route() do
      :ok -> []
      {:error, reason} -> [%{source: :model_disclosure, error: inspect(reason)}]
    end
  rescue
    exception ->
      [
        %{
          source: :model_disclosure,
          error: Exception.message(exception),
          kind: exception.__struct__
        }
      ]
  catch
    kind, reason -> [%{source: :model_disclosure, error: inspect({kind, reason})}]
  end

  defp kick_search_jobs do
    Enum.map(["search-rebuild", "search-index"], fn identity ->
      {identity, Managed.kick(identity, "local")}
    end)
  end

  defp context_value(context, key) when is_map(context),
    do: Map.get(context, key, Map.get(context, Atom.to_string(key)))

  defp context_value(_context, _key), do: nil

  defp validate_effect_epoch(%{allbert_pack_activation: _carrier}),
    do: {:error, :product_not_ready}

  defp validate_effect_epoch(%{allbert_pack_epoch: epoch}), do: EffectGuard.validate(epoch)

  defp validate_effect_epoch(_context), do: {:error, :product_not_ready}
end
