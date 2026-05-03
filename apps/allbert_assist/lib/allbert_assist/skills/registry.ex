defmodule AllbertAssist.Skills.Registry do
  @moduledoc """
  Stateless v0.03 Agent Skills registry.

  The registry discovers bounded skill directories, parses `SKILL.md` files,
  applies trust and enablement policy, and returns only model-facing trusted
  skills while keeping skipped declarations visible through diagnostics.
  """

  alias AllbertAssist.Paths
  alias AllbertAssist.Security.Policy
  alias AllbertAssist.Settings
  alias AllbertAssist.Skills.CapabilityContract
  alias AllbertAssist.Skills.Parser
  alias AllbertAssist.Skills.Skill

  @built_in_names [
    "direct-answer",
    "append-memory",
    "read-recent-memory",
    "list-skills",
    "read-skill",
    "plan-shell-command",
    "external-network-request"
  ]

  @settings_defaults %{
    "scan_paths" => [],
    "trusted_project_roots" => [],
    "enabled" => [],
    "disabled" => [],
    "imported_cache_policy" => "disabled"
  }

  @legacy_built_ins [
    %{
      name: "direct-answer",
      action_name: "direct_answer",
      title: "Direct Answer",
      description: "Answer plain local-assistant prompts without taking side effects.",
      permission: :read_only,
      status: :available
    },
    %{
      name: "append-memory",
      action_name: "append_memory",
      title: "Append Memory",
      description:
        "Save explicit memory requests and low-risk personal preference heuristics as durable markdown.",
      permission: :memory_write,
      status: :available
    },
    %{
      name: "read-recent-memory",
      action_name: "read_recent_memory",
      title: "Read Recent Memory",
      description: "Read recent markdown-backed memory entries.",
      permission: :read_only,
      status: :available
    },
    %{
      name: "list-skills",
      action_name: "list_skills",
      title: "List Skills",
      description: "List the safe capabilities that Allbert can inspect or select.",
      permission: :read_only,
      status: :available
    },
    %{
      name: "read-skill",
      action_name: "read_skill",
      title: "Read Skill",
      description: "Read one skill declaration by name.",
      permission: :read_only,
      status: :available
    },
    %{
      name: "plan-shell-command",
      action_name: "plan_shell_command",
      title: "Plan Shell Command",
      description: "Draft a command plan or safety note without executing any shell command.",
      permission: :command_plan,
      status: :available
    },
    %{
      name: "external-network-request",
      action_name: "external_network_request",
      title: "External Network Request",
      description:
        "Recognize external network requests and require confirmation without making a call.",
      permission: :external_network,
      status: :needs_confirmation
    }
  ]

  @doc "Return trusted, enabled, model-facing skills."
  @spec list(map()) :: {:ok, [Skill.t()]}
  def list(context \\ %{}) do
    {:ok, load(context).skills}
  end

  @doc "Read one trusted, enabled skill by canonical name, title, or alias."
  @spec get(String.t(), map()) :: {:ok, Skill.t()} | {:error, :not_found}
  def get(name, context \\ %{})

  def get(name, context) when is_binary(name) do
    normalized = normalize_name(name)

    load(context).skills
    |> Enum.find(&skill_matches?(&1, normalized))
    |> case do
      nil -> {:error, :not_found}
      skill -> {:ok, skill}
    end
  end

  def get(_name, _context), do: {:error, :not_found}

  @doc "Read one skill declaration and parser diagnostics."
  def read(name, context \\ %{}) do
    with {:ok, skill} <- get(name, context) do
      {:ok, %{skill: skill, body: skill_body(skill), diagnostics: skill.diagnostics}}
    end
  end

  @doc "Activate one trusted skill for progressive disclosure."
  def activate(name, context \\ %{}) do
    with {:ok, skill} <- get(name, context) do
      {:ok, activation(skill)}
    end
  end

  @doc "Return diagnostics for invalid, pending, disabled, duplicate, and hidden skills."
  @spec diagnostics(map()) :: {:ok, [map()]}
  def diagnostics(context \\ %{}) do
    {:ok, load(context).diagnostics}
  end

  @doc "Load the full registry snapshot."
  @spec load(map()) :: %{skills: [Skill.t()], diagnostics: [map()]}
  def load(context \\ %{}) do
    settings = registry_settings(context)
    discoveries = discoveries(context, settings)
    {parsed_skills, parse_diagnostics} = parse_discoveries(discoveries)
    parsed_skills = parsed_skills ++ legacy_built_ins(parsed_skills, context)
    policy_results = Enum.map(parsed_skills, &apply_policy(&1, settings))
    {eligible, policy_diagnostics} = split_policy_results(policy_results)
    {reserved, unreserved} = Enum.split_with(eligible, &reserved_non_builtin?/1)
    {winners, duplicate_diagnostics} = resolve_duplicates(unreserved)

    %{
      skills: Enum.sort_by(winners, & &1.name),
      diagnostics:
        parse_diagnostics ++
          policy_diagnostics ++ reserved_diagnostics(reserved) ++ duplicate_diagnostics
    }
  end

  @doc "Normalize public names and snake-case aliases to canonical kebab case."
  @spec normalize_name(String.t()) :: String.t()
  def normalize_name(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp parse_discoveries(discoveries) do
    discoveries
    |> Enum.map(&parse_discovery/1)
    |> Enum.reduce({[], []}, fn
      {:ok, skill}, {skills, diagnostics} ->
        {[skill | skills], skill.diagnostics ++ diagnostics}

      {:error, diagnostics}, {skills, all_diagnostics} ->
        {skills, diagnostics ++ all_diagnostics}
    end)
    |> then(fn {skills, diagnostics} -> {Enum.reverse(skills), Enum.reverse(diagnostics)} end)
  end

  defp parse_discovery(discovery) do
    case Parser.parse_dir(discovery.path) do
      {:ok, spec} ->
        {:ok, skill_from_spec(spec, discovery)}

      {:error, diagnostics} ->
        {:error, Enum.map(diagnostics, &tag_diagnostic(&1, discovery))}
    end
  end

  defp skill_from_spec(spec, discovery) do
    contract = CapabilityContract.from_metadata(spec.metadata)
    name = normalize_name(spec.name)

    skill = %Skill{
      name: name,
      original_name: spec.name,
      title: titleize(name),
      description: spec.description,
      source_scope: discovery.source_scope,
      source_path: spec.root_path,
      trust_status: discovery.trust_status,
      kind: skill_kind(discovery.source_scope, spec, contract),
      activation_mode: :progressive_disclosure,
      spec: spec,
      capability_contract: contract,
      permission: skill_permission(contract),
      status: :available,
      aliases: aliases(name, spec.name),
      diagnostics: Enum.map(spec.diagnostics, &tag_diagnostic(&1, discovery))
    }

    %{skill | contract_validation: CapabilityContract.validate(contract, skill: skill)}
  end

  defp discoveries(context, settings) do
    context
    |> source_roots(settings)
    |> Enum.flat_map(&skill_dirs/1)
  end

  defp source_roots(context, settings) do
    project_root = project_root(context)
    trusted_project? = trusted_project?(project_root, settings)

    [
      root_spec(:built_in, built_in_root(context), :trusted, true, 0),
      root_spec(
        :project_native,
        Path.join([project_root, ".allbert", "skills"]),
        project_trust(trusted_project?),
        true,
        1
      ),
      root_spec(
        :project_interoperable,
        Path.join([project_root, ".agents", "skills"]),
        project_trust(trusted_project?),
        true,
        2
      ),
      root_spec(:user_native, Paths.skills_root(), :trusted, true, 3),
      root_spec(:user_interoperable, user_interoperable_root(context), :trusted, true, 4)
    ] ++ configured_roots(settings, project_root) ++ [imported_root(settings)]
  end

  defp root_spec(source_scope, root_path, trust_status, default_enabled?, precedence) do
    %{
      source_scope: source_scope,
      root_path: Path.expand(root_path),
      trust_status: trust_status,
      default_enabled?: default_enabled?,
      precedence: precedence
    }
  end

  defp configured_roots(settings, project_root) do
    settings["scan_paths"]
    |> Enum.with_index(5)
    |> Enum.map(fn {path, precedence} ->
      root_spec(
        :configured_scan_path,
        Path.expand(path, project_root),
        :trusted,
        true,
        precedence
      )
    end)
  end

  defp imported_root(settings) do
    trust_status =
      if settings["imported_cache_policy"] == "enabled_manual_trust" do
        :trusted
      else
        :pending
      end

    root_spec(:imported_cache, Path.join(Paths.cache_root(), "skills"), trust_status, false, 100)
  end

  defp skill_dirs(%{source_scope: :imported_cache, root_path: root_path} = source) do
    root_path
    |> recursive_skill_dirs(3)
    |> Enum.map(&Map.put(source, :path, &1))
  end

  defp skill_dirs(%{root_path: root_path} = source) do
    root_path
    |> child_dirs()
    |> Enum.filter(&File.regular?(Path.join(&1, "SKILL.md")))
    |> Enum.map(&Map.put(source, :path, &1))
  end

  defp recursive_skill_dirs(root_path, depth) when depth <= 0 do
    if File.regular?(Path.join(root_path, "SKILL.md")), do: [root_path], else: []
  end

  defp recursive_skill_dirs(root_path, depth) do
    own = if File.regular?(Path.join(root_path, "SKILL.md")), do: [root_path], else: []

    children =
      root_path
      |> child_dirs()
      |> Enum.reject(&(Path.basename(&1) == "_sources"))
      |> Enum.flat_map(&recursive_skill_dirs(&1, depth - 1))

    own ++ children
  end

  defp child_dirs(root_path) do
    case File.ls(root_path) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&hidden_path?/1)
        |> Enum.map(&Path.join(root_path, &1))
        |> Enum.filter(&File.dir?/1)
        |> Enum.sort()

      {:error, _reason} ->
        []
    end
  end

  defp apply_policy(skill, settings) do
    cond do
      selected?(skill, settings["disabled"]) ->
        policy_result(skill, false, disabled_diagnostic(skill))

      skill.source_scope == :project_native and skill.trust_status == :pending ->
        policy_result(skill, false, project_pending_diagnostic(skill))

      skill.source_scope == :project_interoperable and skill.trust_status == :pending ->
        policy_result(skill, false, project_pending_diagnostic(skill))

      skill.source_scope == :imported_cache and not imported_enabled?(skill, settings) ->
        policy_result(skill, false, imported_disabled_diagnostic(skill))

      true ->
        policy_result(trust_imported_if_enabled(skill, settings), true, nil)
    end
  end

  defp split_policy_results(policy_results) do
    policy_results
    |> Enum.reduce({[], []}, fn result, {skills, diagnostics} ->
      diagnostics = result.diagnostics ++ diagnostics

      if result.catalog? do
        {[result.skill | skills], diagnostics}
      else
        {skills, diagnostics}
      end
    end)
    |> then(fn {skills, diagnostics} -> {Enum.reverse(skills), Enum.reverse(diagnostics)} end)
  end

  defp policy_result(skill, catalog?, nil),
    do: %{skill: skill, catalog?: catalog?, diagnostics: []}

  defp policy_result(skill, catalog?, diagnostic),
    do: %{skill: skill, catalog?: catalog?, diagnostics: [diagnostic]}

  defp imported_enabled?(skill, settings) do
    settings["imported_cache_policy"] == "enabled_manual_trust" and
      selected?(skill, settings["enabled"])
  end

  defp trust_imported_if_enabled(%{source_scope: :imported_cache} = skill, settings) do
    if imported_enabled?(skill, settings), do: %{skill | trust_status: :trusted}, else: skill
  end

  defp trust_imported_if_enabled(skill, _settings), do: skill

  defp resolve_duplicates(skills) do
    skills
    |> Enum.sort_by(&{skill_precedence(&1), &1.source_path})
    |> Enum.group_by(& &1.name)
    |> Enum.reduce({[], []}, &select_duplicate_winner/2)
    |> then(fn {winners, diagnostics} -> {Enum.reverse(winners), Enum.reverse(diagnostics)} end)
  end

  defp select_duplicate_winner({_name, [winner | hidden]}, {winners, diagnostics}) do
    hidden_diagnostics = Enum.map(hidden, &duplicate_hidden_diagnostic(&1, winner))
    {[winner | winners], hidden_diagnostics ++ diagnostics}
  end

  defp reserved_non_builtin?(skill) do
    skill.source_scope not in [:built_in, :built_in_legacy] and skill.name in @built_in_names
  end

  defp reserved_diagnostics(skills), do: Enum.map(skills, &reserved_name_diagnostic/1)

  defp legacy_built_ins(parsed_skills, context) do
    if legacy_built_ins_enabled?(parsed_skills, context) do
      Enum.map(@legacy_built_ins, &legacy_skill/1)
    else
      []
    end
  end

  defp legacy_built_ins_enabled?(parsed_skills, context) do
    not Map.get(context, :disable_legacy_built_ins, false) and
      not Enum.any?(parsed_skills, &(&1.source_scope == :built_in))
  end

  defp legacy_skill(attrs) do
    skill = %Skill{
      name: attrs.name,
      original_name: attrs.name,
      title: attrs.title,
      description: attrs.description,
      source_scope: :built_in_legacy,
      source_path: "static://allbert/v0.01/#{attrs.name}",
      trust_status: :trusted,
      kind: :native_action,
      activation_mode: :legacy_static_until_v0_03_m4,
      spec: nil,
      capability_contract: CapabilityContract.legacy(attrs.action_name, attrs.permission),
      permission: attrs.permission,
      status: attrs.status,
      instructions: legacy_instructions(attrs),
      aliases: aliases(attrs.name, attrs.action_name),
      diagnostics: [
        diagnostic(
          :info,
          :legacy_static_skill,
          "Legacy static built-in until the M4 SKILL.md pack lands.",
          source_scope: :built_in_legacy,
          source_path: "static://allbert/v0.01/#{attrs.name}"
        )
      ]
    }

    %{
      skill
      | contract_validation: CapabilityContract.validate(skill.capability_contract, skill: skill)
    }
  end

  defp registry_settings(context) do
    context
    |> Map.get(:settings)
    |> case do
      settings when is_map(settings) -> Map.merge(@settings_defaults, stringify_keys(settings))
      _other -> read_registry_settings()
    end
  end

  defp read_registry_settings do
    Map.new(@settings_defaults, fn {key, default} ->
      {"skills.#{key}", default}
      |> read_setting()
      |> then(&{key, &1})
    end)
  end

  defp read_setting({key, default}) do
    case Settings.get(key) do
      {:ok, value} -> value
      _error -> default
    end
  end

  defp stringify_keys(settings) do
    Map.new(settings, fn {key, value} -> {to_string(key), value} end)
  end

  defp selected?(skill, names) do
    normalized_names = Enum.map(names, &normalize_name/1)
    Enum.any?([skill.name | skill.aliases], &(&1 in normalized_names))
  end

  defp trusted_project?(project_root, settings) do
    trusted_roots =
      settings["trusted_project_roots"]
      |> Enum.map(&Path.expand/1)

    Path.expand(project_root) in trusted_roots
  end

  defp project_trust(true), do: :trusted
  defp project_trust(false), do: :pending

  defp project_root(context) do
    context
    |> Map.get(:project_root, Keyword.get(registry_config(), :project_root, File.cwd!()))
    |> Path.expand()
  end

  defp built_in_root(context) do
    Map.get(
      context,
      :built_in_root,
      Keyword.get(registry_config(), :built_in_root, default_built_in_root())
    )
  end

  defp user_interoperable_root(context) do
    Map.get(
      context,
      :user_interoperable_root,
      Keyword.get(registry_config(), :user_interoperable_root, Path.expand("~/.agents/skills"))
    )
  end

  defp registry_config, do: Application.get_env(:allbert_assist, __MODULE__, [])

  defp default_built_in_root do
    case :code.priv_dir(:allbert_assist) do
      path when is_list(path) -> Path.join(List.to_string(path), "skills")
      {:error, _reason} -> Path.expand("apps/allbert_assist/priv/skills", File.cwd!())
    end
  end

  defp skill_kind(source_scope, _spec, %CapabilityContract{status: status})
       when source_scope in [:built_in, :built_in_legacy] and status in [:draft, :legacy],
       do: :native_action

  defp skill_kind(_source_scope, _spec, %CapabilityContract{status: :draft}),
    do: :capability_candidate

  defp skill_kind(:imported_cache, _spec, _contract), do: :external_candidate
  defp skill_kind(_source_scope, %{resources: [_resource | _rest]}, _contract), do: :workflow
  defp skill_kind(_source_scope, _spec, _contract), do: :instruction

  defp skill_permission(%CapabilityContract{permissions: [permission | _rest]}) do
    Policy.permission_classes()
    |> Enum.find(:read_only, &(to_string(&1) == permission))
  end

  defp skill_permission(_contract), do: :read_only

  defp skill_matches?(skill, normalized) do
    normalized in [skill.name | skill.aliases] or normalize_name(skill.title) == normalized
  end

  defp skill_body(%{spec: %{body: body}}), do: body
  defp skill_body(%{instructions: instructions}) when is_binary(instructions), do: instructions
  defp skill_body(skill), do: skill.description

  defp activation(skill) do
    resources = resource_inventory(skill)
    contract = contract_summary(skill.capability_contract, skill.contract_validation)

    %{
      name: skill.name,
      title: skill.title,
      kind: skill.kind,
      source_scope: skill.source_scope,
      source_path: skill.source_path,
      trust_status: skill.trust_status,
      activation_mode: skill.activation_mode,
      instructions: wrapped_instructions(skill, resources, contract),
      resource_inventory: resources,
      capability_contract: contract,
      diagnostics: skill.diagnostics
    }
  end

  defp wrapped_instructions(skill, resources, contract) do
    """
    ## Skill Context

    Name: #{skill.name}
    Title: #{skill.title}
    Kind: #{skill.kind}
    Source scope: #{skill.source_scope}
    Trust: #{skill.trust_status}
    Activation mode: #{skill.activation_mode}
    Capability actions: #{Enum.join(contract.actions, ", ")}
    Capability permissions: #{Enum.join(contract.permissions, ", ")}
    Contract validation: #{contract.validation_status}
    Execution eligible: #{contract.execution_eligible?}

    ## Instructions

    #{skill_body(skill)}

    ## Resource Inventory

    #{resource_inventory_text(resources)}

    ## v0.03 Safety Boundary

    This activation loaded instructions and resource metadata only. It did not
    execute scripts, shell commands, package installs, network calls, external
    tools, or Jido actions described by skill metadata.
    """
    |> String.trim()
  end

  defp resource_inventory(skill) do
    skill
    |> skill_resources()
    |> Enum.map(&resource_summary/1)
  end

  defp skill_resources(%{spec: %{resources: resources}}), do: resources
  defp skill_resources(_skill), do: []

  defp resource_summary(resource) do
    %{
      path: resource.path,
      kind: resource.kind,
      byte_size: resource.byte_size,
      sha256: resource.sha256
    }
  end

  defp resource_inventory_text([]), do: "No bundled resources."

  defp resource_inventory_text(resources) do
    resources
    |> Enum.map(fn resource ->
      "- #{resource.path} (#{resource.kind}, #{resource.byte_size} bytes, sha256 #{resource.sha256})"
    end)
    |> Enum.join("\n")
  end

  defp contract_summary(nil, _validation),
    do: %{status: :none, actions: [], permissions: [], validation_status: :none}

  defp contract_summary(contract, validation) do
    %{
      status: contract.status,
      actions: contract.actions,
      permissions: contract.permissions,
      confirmation: contract.confirmation,
      memory_effects: contract.memory_effects,
      trace_effects: contract.trace_effects,
      validation_status: Map.get(validation || %{}, :status, :none),
      execution_eligible?: Map.get(validation || %{}, :execution_eligible?, false),
      validated_actions: Map.get(validation || %{}, :actions, []),
      validated_permissions: Map.get(validation || %{}, :permissions, []),
      validation_diagnostics: Map.get(validation || %{}, :diagnostics, [])
    }
  end

  defp aliases(canonical_name, original_name) do
    [String.replace(canonical_name, "-", "_"), normalize_name(original_name)]
    |> Enum.reject(&(&1 == "" or &1 == canonical_name))
    |> Enum.uniq()
  end

  defp titleize(name) do
    name
    |> String.split("-", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp tag_diagnostic(diagnostic, discovery) do
    diagnostic
    |> Map.put(:source_scope, discovery.source_scope)
    |> Map.put(:source_path, Map.get(diagnostic, :path, discovery.path))
  end

  defp disabled_diagnostic(skill) do
    skill_diagnostic(:warning, :disabled_skill, "Skill is disabled by Settings Central.", skill)
  end

  defp project_pending_diagnostic(skill) do
    skill_diagnostic(:warning, :project_skill_pending, "Project skill is pending trust.", skill)
  end

  defp imported_disabled_diagnostic(skill) do
    skill_diagnostic(
      :warning,
      :imported_skill_disabled,
      "Imported cache skill is disabled by policy.",
      skill
    )
  end

  defp duplicate_hidden_diagnostic(skill, winner) do
    skill_diagnostic(
      :warning,
      :duplicate_skill_hidden,
      "Duplicate skill hidden by precedence.",
      skill,
      winning_source_path: winner.source_path,
      winning_source_scope: winner.source_scope
    )
  end

  defp reserved_name_diagnostic(skill) do
    skill_diagnostic(
      :warning,
      :built_in_name_reserved,
      "Built-in skill names are reserved in v0.03.",
      skill
    )
  end

  defp skill_diagnostic(severity, code, message, skill, extra \\ []) do
    diagnostic(
      severity,
      code,
      message,
      [name: skill.name, source_scope: skill.source_scope, source_path: skill.source_path] ++
        extra
    )
  end

  defp legacy_instructions(attrs) do
    """
    #{attrs.description}

    Action: #{attrs.action_name}
    Permission: #{attrs.permission}
    Status: #{attrs.status}

    This legacy declaration is read-only registry context until the v0.03 M4
    built-in `SKILL.md` pack replaces it. It does not execute scripts, shell
    commands, package installs, network calls, or additional Jido actions.
    """
    |> String.trim()
  end

  defp hidden_path?(path), do: String.starts_with?(path, ".")

  defp skill_precedence(skill), do: scope_precedence(skill.source_scope)

  defp scope_precedence(:built_in), do: 0
  defp scope_precedence(:built_in_legacy), do: 0
  defp scope_precedence(:project_native), do: 1
  defp scope_precedence(:project_interoperable), do: 2
  defp scope_precedence(:user_native), do: 3
  defp scope_precedence(:user_interoperable), do: 4
  defp scope_precedence(:configured_scan_path), do: 5
  defp scope_precedence(:imported_cache), do: 100

  defp diagnostic(severity, code, message, opts) do
    opts
    |> Enum.into(%{severity: severity, code: code, message: message})
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
