defmodule AllbertAssist.DynamicPlugins.Codegen.Roles do
  @moduledoc """
  Bounded v0.37 generator role pipeline.

  Planner, Author, TrialAuthor, Critic, and Repair are advisory LLM-backed
  roles. Their packets can explain, veto, or request repair, but they never
  grant authority, advance trust tiers, or integrate runtime code.
  """

  alias AllbertAssist.DynamicPlugins.Codegen.CapabilityGap
  alias AllbertAssist.DynamicPlugins.Codegen.LLM
  alias AllbertAssist.DynamicPlugins.Delegate
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Settings

  @required_generated_fields ~w[description source test_source]
  @max_wall_clock_ms 120_000

  @doc "Run the bounded role pipeline for one action draft."
  def run(%CapabilityGap{} = gap, profile, budget, context)
      when is_map(profile) and is_map(budget) and is_map(context) do
    started_at = System.monotonic_time(:millisecond)

    with {:ok, planner, budget} <- plan(gap, profile, budget, context),
         {:ok, role_packets, generated, budget} <-
           attempt_loop(gap, profile, budget, context, planner, started_at) do
      {:ok, [planner | role_packets], generated, budget}
    end
  end

  @doc "Repair one generated packet from deterministic validation or sandbox evidence."
  def repair_from_evidence(%CapabilityGap{} = gap, profile, budget, context, generated, evidence)
      when is_map(profile) and is_map(budget) and is_map(context) and is_map(generated) and
             is_map(evidence) do
    with {:ok, planner, budget} <- plan(gap, profile, budget, context),
         {:ok, critic, budget} <-
           critic(gap, profile, budget, context, planner, generated, evidence),
         {:ok, repair, repaired, budget} <-
           repair(gap, profile, budget, context, planner, generated, evidence, critic) do
      case Map.get(repair, "status") do
        "repaired" -> {:ok, [planner, critic, repair], repaired, budget}
        _other -> {:error, {:dynamic_codegen_repair_not_available, repair}}
      end
    end
  end

  defp plan(%CapabilityGap{} = gap, profile, budget, context) do
    input = %{"gap" => CapabilityGap.summary(gap)}

    with {:ok, packet} <- LLM.generate_role(:planner, input, profile, budget, context),
         {:ok, budget} <- consume_budget(budget, "planner", packet) do
      {:ok,
       role_packet("planner", "planned", profile, packet, %{
         "target_shape" => Map.get(packet, "target_shape"),
         "permission_ceiling" => Map.get(packet, "permission_ceiling"),
         "summary" => Map.get(packet, "summary"),
         "acceptance_criteria" => normalize_list(Map.get(packet, "acceptance_criteria")),
         "constraints" => normalize_list(Map.get(packet, "constraints")),
         "test_strategy" => Map.get(packet, "test_strategy")
       }), budget}
    end
  end

  defp attempt_loop(gap, profile, budget, context, planner, started_at) do
    %{
      gap: gap,
      profile: profile,
      budget: budget,
      context: context,
      planner: planner,
      started_at: started_at,
      attempt: 0,
      max_repairs: max_repair_iterations(),
      failures: MapSet.new()
    }
    |> initial_attempt()
  end

  defp initial_attempt(%{} = state) do
    with :ok <- ensure_wall_clock(state.started_at),
         {:ok, author, author_output, budget} <-
           author(state.gap, state.profile, state.budget, state.context, state.planner),
         state <- %{state | budget: budget},
         {:ok, trial_author, trial_output, budget} <-
           trial_author(
             state.gap,
             state.profile,
             state.budget,
             state.context,
             state.planner,
             author_output
           ),
         state <- %{state | budget: budget},
         generated <- merge_generated(author_output, trial_output),
         evidence <- deterministic_evidence(generated),
         {:ok, critic, budget} <-
           critic(
             state.gap,
             state.profile,
             state.budget,
             state.context,
             state.planner,
             generated,
             evidence
           ),
         state <- %{state | budget: budget} do
      continue_or_finish(state, generated, evidence, critic, [author, trial_author, critic])
    end
  end

  defp repair_loop(%{} = state, generated, packets) do
    with :ok <- ensure_wall_clock(state.started_at),
         evidence <- deterministic_evidence(generated),
         {:ok, critic, budget} <-
           critic(
             state.gap,
             state.profile,
             state.budget,
             state.context,
             state.planner,
             generated,
             evidence
           ),
         state <- %{state | budget: budget} do
      continue_or_finish(state, generated, evidence, critic, packets ++ [critic])
    end
  end

  defp continue_or_finish(state, generated, evidence, critic, packets) do
    cond do
      decision(evidence, critic) == :accepted ->
        {:ok, packets, generated, state.budget}

      state.attempt >= state.max_repairs ->
        repair_impasse("repair_iteration_limit", state, evidence)

      MapSet.member?(state.failures, failure_fingerprint(evidence, critic)) ->
        repair_impasse("repeated_identical_failure", state, evidence)

      true ->
        repair_and_continue(state, generated, evidence, critic, packets)
    end
  end

  defp repair_and_continue(state, generated, evidence, critic, packets) do
    with {:ok, repair, repaired, budget} <-
           repair(
             state.gap,
             state.profile,
             state.budget,
             state.context,
             state.planner,
             generated,
             evidence,
             critic
           ),
         :ok <- ensure_repaired(repair) do
      state
      |> Map.put(:budget, budget)
      |> Map.update!(:attempt, &(&1 + 1))
      |> Map.update!(:failures, &MapSet.put(&1, failure_fingerprint(evidence, critic)))
      |> repair_loop(repaired, packets ++ [repair])
    end
  end

  defp repair_impasse(reason, state, evidence) do
    payload = %{
      "reason" => reason,
      "iterations_used" => state.attempt,
      "evidence" => evidence_summary(evidence)
    }

    payload =
      if reason == "repair_iteration_limit" do
        Map.put(payload, "limit", state.max_repairs)
      else
        payload
      end

    {:error, {:dynamic_codegen_repair_impasse, payload}}
  end

  defp author(%CapabilityGap{} = gap, profile, budget, context, planner) do
    input = %{
      "gap" => CapabilityGap.summary(gap),
      "planner" => Map.get(planner, "metadata", %{})
    }

    with {:ok, packet} <- LLM.generate_role(:author, input, profile, budget, context),
         {:ok, budget} <- consume_budget(budget, "author", packet) do
      {:ok,
       role_packet("author", "generated", profile, packet, %{
         "description" => Map.get(packet, "description"),
         "notes" => normalize_list(Map.get(packet, "notes"))
       }), packet, budget}
    end
  end

  defp trial_author(%CapabilityGap{} = gap, profile, budget, context, planner, author_output) do
    input = %{
      "gap" => CapabilityGap.summary(gap),
      "planner" => Map.get(planner, "metadata", %{}),
      "source_summary" => source_summary(Map.get(author_output, "source"))
    }

    with {:ok, packet} <- LLM.generate_role(:trial_author, input, profile, budget, context),
         {:ok, budget} <- consume_budget(budget, "trial_author", packet) do
      {:ok,
       role_packet("trial_author", "test_authored", profile, packet, %{
         "focused_tests" => normalize_list(Map.get(packet, "focused_test_paths")),
         "notes" => normalize_list(Map.get(packet, "notes"))
       }), packet, budget}
    end
  end

  defp critic(%CapabilityGap{} = gap, profile, budget, context, planner, generated, evidence) do
    input = %{
      "gap" => CapabilityGap.summary(gap),
      "planner" => Map.get(planner, "metadata", %{}),
      "source_summary" => source_summary(Map.get(generated, "source")),
      "test_summary" => source_summary(Map.get(generated, "test_source")),
      "evidence" => evidence_summary(evidence)
    }

    with {:ok, packet} <- LLM.generate_role(:critic, input, profile, budget, context),
         {:ok, budget} <- consume_budget(budget, "critic", packet) do
      {:ok,
       role_packet("critic", critic_status(packet), profile, packet, %{
         "verdict" => Map.get(packet, "verdict"),
         "findings" => normalize_list(Map.get(packet, "findings")),
         "repair_instructions" => Map.get(packet, "repair_instructions", ""),
         "evidence" => evidence_summary(evidence)
       }), budget}
    end
  end

  defp repair(
         %CapabilityGap{} = gap,
         profile,
         budget,
         context,
         planner,
         generated,
         evidence,
         critic
       ) do
    input = %{
      "gap" => CapabilityGap.summary(gap),
      "planner" => Map.get(planner, "metadata", %{}),
      "critic" => Map.get(critic, "metadata", %{}),
      "evidence" => evidence_summary(evidence),
      "source" => Map.get(generated, "source", ""),
      "test_source" => Map.get(generated, "test_source", "")
    }

    with {:ok, packet} <- LLM.generate_role(:repair, input, profile, budget, context),
         {:ok, budget} <- consume_budget(budget, "repair", packet) do
      repaired = repair_output(packet, generated)

      {:ok,
       role_packet("repair", Map.get(packet, "status"), profile, packet, %{
         "status" => Map.get(packet, "status"),
         "notes" => normalize_list(Map.get(packet, "notes"))
       }), repaired, budget}
    end
  end

  defp merge_generated(author_output, trial_output) do
    %{
      "action_name" => Map.get(author_output, "action_name", ""),
      "description" => Map.get(author_output, "description", ""),
      "source" => Map.get(author_output, "source", ""),
      "test_source" => Map.get(trial_output, "test_source", ""),
      "notes" =>
        normalize_list(Map.get(author_output, "notes")) ++
          normalize_list(Map.get(trial_output, "notes")),
      "usage" => %{
        "total_tokens" => usage_units(author_output) + usage_units(trial_output)
      }
    }
  end

  defp repair_output(%{"status" => "repaired"} = packet, generated) do
    %{
      "action_name" =>
        fallback(Map.get(packet, "action_name"), Map.get(generated, "action_name")),
      "description" =>
        fallback(Map.get(packet, "description"), Map.get(generated, "description")),
      "source" => fallback(Map.get(packet, "source"), Map.get(generated, "source")),
      "test_source" =>
        fallback(Map.get(packet, "test_source"), Map.get(generated, "test_source")),
      "notes" => normalize_list(Map.get(packet, "notes")),
      "usage" => %{"total_tokens" => usage_units(packet)}
    }
  end

  defp repair_output(_packet, generated), do: generated

  defp fallback(value, fallback) when is_binary(value) do
    if String.trim(value) == "", do: fallback, else: value
  end

  defp fallback(_value, fallback), do: fallback

  defp deterministic_evidence(generated) do
    checks = [
      require_generated_fields(generated),
      require_placeholder(Map.get(generated, "source"), "{{MODULE}}"),
      require_placeholder(Map.get(generated, "source"), "{{ACTION_NAME}}"),
      require_placeholder(Map.get(generated, "test_source"), "{{TEST_MODULE}}"),
      require_placeholder(Map.get(generated, "test_source"), "{{MODULE}}"),
      require_source_marker(generated, "use AllbertAssist.Action"),
      require_allowed_source_permission(generated),
      require_source_marker(generated, "confirmation: :not_required"),
      require_delegation_contract(generated)
    ]

    failures =
      checks
      |> Enum.reject(&(&1 == :ok))
      |> Enum.map(fn {:error, reason} -> reason end)

    %{
      "status" => if(failures == [], do: "passed", else: "repair_requested"),
      "failures" => failures
    }
  end

  defp decision(%{"status" => "passed"}, %{"metadata" => %{"verdict" => "accepted"}}),
    do: :accepted

  defp decision(_evidence, _critic), do: :repair_requested

  defp ensure_repaired(%{"status" => "repaired"}), do: :ok

  defp ensure_repaired(%{"status" => status}),
    do: {:error, {:dynamic_codegen_repair_failed, status}}

  defp consume_budget(budget, role, packet) do
    calls_used = Map.get(budget, "provider_calls_used", 0) + 1
    usage_used = Map.get(budget, "provider_usage_units_used", 0) + usage_units(packet)

    cond do
      calls_used > Map.get(budget, "provider_calls_budget", calls_used) ->
        {:error,
         {:dynamic_codegen_budget_exhausted,
          %{
            "budget" => "provider_calls",
            "role" => role,
            "requested" => calls_used,
            "limit" => Map.get(budget, "provider_calls_budget")
          }}}

      is_integer(Map.get(budget, "provider_usage_units_budget")) and
          usage_used > Map.get(budget, "provider_usage_units_budget") ->
        {:error,
         {:dynamic_codegen_budget_exhausted,
          %{
            "budget" => "provider_usage_units",
            "role" => role,
            "requested" => usage_used,
            "limit" => Map.get(budget, "provider_usage_units_budget")
          }}}

      true ->
        {:ok,
         budget
         |> Map.put("provider_calls_used", calls_used)
         |> Map.put("provider_usage_units_used", usage_used)}
    end
  end

  defp role_packet(role, status, profile, raw, attrs) do
    %{
      "role" => role,
      "status" => status || "unknown",
      "authority" => "none",
      "metadata" =>
        attrs
        |> Map.put("provider_profile", Map.get(profile, :name))
        |> Map.put("model", Map.get(profile, :model))
        |> Map.put("prompt_hash", Map.get(raw, "prompt_hash"))
        |> Map.put("usage_units", usage_units(raw))
        |> Redactor.redact()
    }
  end

  defp critic_status(%{"verdict" => "accepted"}), do: "accepted"
  defp critic_status(%{"verdict" => "rejected"}), do: "rejected"
  defp critic_status(_packet), do: "repair_requested"

  defp max_repair_iterations do
    case Settings.get("dynamic_codegen.max_repair_iterations") do
      {:ok, value} when is_integer(value) and value >= 0 -> value
      _other -> 2
    end
  end

  defp ensure_wall_clock(started_at) do
    elapsed = System.monotonic_time(:millisecond) - started_at

    if elapsed <= @max_wall_clock_ms do
      :ok
    else
      {:error, {:dynamic_codegen_repair_impasse, %{"reason" => "wall_clock_timeout"}}}
    end
  end

  defp failure_fingerprint(evidence, critic) do
    data =
      Jason.encode!(%{
        "evidence" => evidence_summary(evidence),
        "critic" => Map.get(critic, "metadata", %{}) |> Map.take(["verdict", "findings"])
      })

    :sha256
    |> :crypto.hash(data)
    |> Base.encode16(case: :lower)
  end

  defp evidence_summary(%{"status" => status, "failures" => failures}) do
    %{"status" => status, "failures" => failures}
  end

  defp evidence_summary(evidence) when is_map(evidence), do: Redactor.redact(evidence)

  defp source_summary(source) when is_binary(source) do
    %{
      "bytes" => byte_size(source),
      "lines" => source |> String.split("\n") |> length(),
      "sha256" =>
        :sha256
        |> :crypto.hash(source)
        |> Base.encode16(case: :lower)
    }
  end

  defp source_summary(_source), do: %{"bytes" => 0, "lines" => 0}

  defp require_generated_fields(generated) do
    missing =
      Enum.reject(@required_generated_fields, fn field ->
        generated |> Map.get(field) |> present_string?()
      end)

    case missing do
      [] -> :ok
      _fields -> {:error, %{"missing" => missing}}
    end
  end

  defp require_placeholder(value, placeholder) do
    if is_binary(value) and String.contains?(value, placeholder) do
      :ok
    else
      {:error, %{"missing_placeholder" => placeholder}}
    end
  end

  defp require_source_marker(generated, marker) do
    source = Map.get(generated, "source")

    if is_binary(source) and String.contains?(source, marker) do
      :ok
    else
      {:error, %{"missing_source_marker" => marker}}
    end
  end

  defp require_allowed_source_permission(generated) do
    with {:ok, permission} <- source_action_permission(Map.get(generated, "source")) do
      if Atom.to_string(permission) in allowed_action_permissions() do
        :ok
      else
        {:error,
         %{
           "unsupported_action_permission" => Atom.to_string(permission),
           "allowed" => allowed_action_permissions()
         }}
      end
    else
      {:error, reason} -> {:error, %{"invalid_action_permission" => inspect(reason)}}
    end
  end

  defp require_delegation_contract(generated) do
    source = Map.get(generated, "source")

    with {:ok, permission} <- source_action_permission(source),
         {:ok, facades} <- source_delegate_facades(source) do
      cond do
        permission == :read_only and facades == [] ->
          :ok

        permission == :read_only ->
          {:error, %{"read_only_delegate_denied" => facades}}

        facades == [] ->
          {:error, %{"missing_delegate_facade" => Atom.to_string(permission)}}

        true ->
          validate_source_facades(permission, facades)
      end
    else
      {:error, reason} -> {:error, %{"invalid_delegate_contract" => inspect(reason)}}
    end
  end

  defp validate_source_facades(permission, facades) do
    allowed_facades = allowed_facades()

    Enum.reduce_while(facades, :ok, fn facade, :ok ->
      case validate_source_facade(permission, facade, allowed_facades) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_source_facade(permission, facade, allowed_facades) do
    case Delegate.facade_permission(facade) do
      {:ok, ^permission} ->
        validate_source_facade_allowed(facade, allowed_facades)

      {:ok, facade_permission} ->
        {:error, delegate_permission_mismatch(permission, facade, facade_permission)}

      {:error, reason} ->
        {:error, %{"delegate_facade_not_supported" => inspect(reason)}}
    end
  end

  defp validate_source_facade_allowed(facade, allowed_facades) do
    if facade in allowed_facades do
      :ok
    else
      {:error, %{"delegate_facade_not_allowed" => facade}}
    end
  end

  defp delegate_permission_mismatch(permission, facade, facade_permission) do
    %{
      "delegate_permission_mismatch" => %{
        "facade" => facade,
        "facade_permission" => Atom.to_string(facade_permission),
        "action_permission" => Atom.to_string(permission)
      }
    }
  end

  defp source_action_permission(source) when is_binary(source) do
    with {:ok, ast} <- quoted_source(source),
         {:ok, permission} <- parsed_action_permission(ast) do
      {:ok, permission}
    end
  end

  defp source_action_permission(_source), do: {:error, :missing_source}

  defp source_delegate_facades(source) when is_binary(source) do
    with {:ok, ast} <- quoted_source(source) do
      {_ast, facades} =
        Macro.prewalk(ast, [], &collect_source_delegate_facade/2)

      {:ok, facades |> Enum.reverse() |> Enum.uniq()}
    end
  end

  defp collect_source_delegate_facade(
         {{:., _meta, [module_ast, :run]}, _call_meta, [facade_name, _params, _context]} = node,
         acc
       )
       when is_binary(facade_name) do
    if module_name(module_ast) == "AllbertAssist.DynamicPlugins.Delegate" do
      {node, [facade_name | acc]}
    else
      {node, acc}
    end
  end

  defp collect_source_delegate_facade(node, acc), do: {node, acc}

  defp quoted_source(source) do
    source
    |> String.replace("{{MODULE}}", "AllbertAssist.DynamicPlugins.Generated.Placeholder.Action")
    |> Code.string_to_quoted()
  end

  defp parsed_action_permission(ast) do
    {_ast, permissions} =
      Macro.prewalk(ast, [], fn
        {:use, _meta, [target | args]} = node, acc ->
          if module_name(target) == "AllbertAssist.Action" do
            {node, [action_use_permission(args) | acc]}
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    permissions =
      permissions
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case permissions do
      [permission] -> {:ok, permission}
      [] -> {:error, :missing_action_permission}
      many -> {:error, {:multiple_action_permissions, many}}
    end
  end

  defp action_use_permission(args) do
    args
    |> List.flatten()
    |> Enum.find_value(fn
      {:permission, permission} when is_atom(permission) -> permission
      _other -> nil
    end)
  end

  defp module_name({:__aliases__, _meta, parts}), do: Enum.map_join(parts, ".", &to_string/1)
  defp module_name(module) when is_atom(module), do: inspect(module)
  defp module_name(_module), do: nil

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

  defp present_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp usage_units(packet) do
    cond do
      is_integer(Map.get(packet, "usage_units")) ->
        Map.get(packet, "usage_units")

      is_integer(get_in(packet, ["usage", "total_tokens"])) ->
        get_in(packet, ["usage", "total_tokens"])

      is_integer(get_in(packet, ["usage", :total_tokens])) ->
        get_in(packet, ["usage", :total_tokens])

      is_integer(get_in(packet, [:usage, :total_tokens])) ->
        get_in(packet, [:usage, :total_tokens])

      true ->
        0
    end
  end

  defp normalize_list(values) when is_list(values), do: Enum.map(values, &to_string/1)
  defp normalize_list(_values), do: []
end
