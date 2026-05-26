defmodule AllbertAssist.DynamicPlugins.Codegen.Roles do
  @moduledoc """
  Bounded v0.37.2 generator role pipeline.

  Planner, Author, TrialAuthor, Critic, and Repair are advisory LLM-backed
  roles. Their packets can explain, veto, or request repair, but they never
  grant authority, advance trust tiers, or integrate runtime code.
  """

  alias AllbertAssist.DynamicPlugins.Codegen.CapabilityGap
  alias AllbertAssist.DynamicPlugins.Codegen.LLM
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Settings

  @required_generated_fields ~w[description source test_source]
  @max_wall_clock_ms 120_000

  @doc "Run the bounded role pipeline for one read-only action draft."
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
    max_repairs = max_repair_iterations()
    loop(gap, profile, budget, context, planner, started_at, 0, max_repairs, MapSet.new())
  end

  defp loop(gap, profile, budget, context, planner, started_at, attempt, max_repairs, failures) do
    with :ok <- ensure_wall_clock(started_at),
         {:ok, author, author_output, budget} <- author(gap, profile, budget, context, planner),
         {:ok, trial_author, trial_output, budget} <-
           trial_author(gap, profile, budget, context, planner, author_output),
         generated <- merge_generated(author_output, trial_output),
         evidence <- deterministic_evidence(generated),
         {:ok, critic, budget} <-
           critic(gap, profile, budget, context, planner, generated, evidence),
         {:decision, decision} <- {:decision, decision(evidence, critic)} do
      cond do
        decision == :accepted ->
          {:ok, [author, trial_author, critic], generated, budget}

        attempt >= max_repairs ->
          {:error,
           {:dynamic_codegen_repair_impasse,
            %{
              "reason" => "repair_iteration_limit",
              "iterations_used" => attempt,
              "limit" => max_repairs,
              "evidence" => evidence_summary(evidence)
            }}}

        MapSet.member?(failures, failure_fingerprint(evidence, critic)) ->
          {:error,
           {:dynamic_codegen_repair_impasse,
            %{
              "reason" => "repeated_identical_failure",
              "iterations_used" => attempt,
              "evidence" => evidence_summary(evidence)
            }}}

        true ->
          with {:ok, repair, repaired, budget} <-
                 repair(gap, profile, budget, context, planner, generated, evidence, critic),
               :ok <- ensure_repaired(repair) do
            repair_loop(
              gap,
              profile,
              budget,
              context,
              planner,
              repaired,
              started_at,
              attempt + 1,
              max_repairs,
              MapSet.put(failures, failure_fingerprint(evidence, critic)),
              [author, trial_author, critic, repair]
            )
          end
      end
    end
  end

  defp repair_loop(
         gap,
         profile,
         budget,
         context,
         planner,
         generated,
         started_at,
         attempt,
         max_repairs,
         failures,
         packets
       ) do
    with :ok <- ensure_wall_clock(started_at),
         evidence <- deterministic_evidence(generated),
         {:ok, critic, budget} <-
           critic(gap, profile, budget, context, planner, generated, evidence),
         {:decision, decision} <- {:decision, decision(evidence, critic)} do
      cond do
        decision == :accepted ->
          {:ok, packets ++ [critic], generated, budget}

        attempt >= max_repairs ->
          {:error,
           {:dynamic_codegen_repair_impasse,
            %{
              "reason" => "repair_iteration_limit",
              "iterations_used" => attempt,
              "limit" => max_repairs,
              "evidence" => evidence_summary(evidence)
            }}}

        MapSet.member?(failures, failure_fingerprint(evidence, critic)) ->
          {:error,
           {:dynamic_codegen_repair_impasse,
            %{
              "reason" => "repeated_identical_failure",
              "iterations_used" => attempt,
              "evidence" => evidence_summary(evidence)
            }}}

        true ->
          with {:ok, repair, repaired, budget} <-
                 repair(gap, profile, budget, context, planner, generated, evidence, critic),
               :ok <- ensure_repaired(repair) do
            repair_loop(
              gap,
              profile,
              budget,
              context,
              planner,
              repaired,
              started_at,
              attempt + 1,
              max_repairs,
              MapSet.put(failures, failure_fingerprint(evidence, critic)),
              packets ++ [critic, repair]
            )
          end
      end
    end
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
      require_source_marker(generated, "permission: :read_only"),
      require_source_marker(generated, "confirmation: :not_required")
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
