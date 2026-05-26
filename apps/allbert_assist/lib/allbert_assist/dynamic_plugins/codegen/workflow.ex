defmodule AllbertAssist.DynamicPlugins.Codegen.Workflow do
  @moduledoc """
  Bounded source-generation plus sandbox-evidence loop for v0.37.2.

  This module coordinates existing authority boundaries; it does not grant any
  live authority. Draft creation remains advisory, sandbox evidence remains
  evidence, and integration still requires the live-loader confirmation path.
  """

  alias AllbertAssist.DynamicPlugins.Codegen.Agent
  alias AllbertAssist.DynamicPlugins.Codegen.Producer
  alias AllbertAssist.DynamicPlugins.Draft
  alias AllbertAssist.DynamicPlugins.MetadataStore
  alias AllbertAssist.DynamicPlugins.SandboxBridge
  alias AllbertAssist.DynamicPlugins.TrustedValidator
  alias AllbertAssist.Settings

  @sandbox_keys [
    :backends,
    :cleanup_staging?,
    :host,
    :policy,
    :project_paths,
    :project_root,
    :security_eval_paths
  ]

  @type result :: %{
          required(:status) => :gate_passed,
          required(:slug) => term(),
          required(:requested) => term(),
          required(:draft) => map(),
          required(:trial) => map(),
          required(:gate) => map(),
          required(:trusted_validation) => map(),
          required(:repairs) => term(),
          required(:repair_count) => term()
        }

  @doc "Request a draft, then run trial/gate evidence with bounded repair."
  @spec request_draft_with_gate(map(), map(), keyword()) :: {:ok, result()} | {:error, term()}
  def request_draft_with_gate(attrs, context \\ %{}, opts \\ [])
      when is_map(attrs) and is_map(context) and is_list(opts) do
    with {:ok, requested} <- Agent.request_draft(attrs, context, agent_opts(opts)) do
      %{
        slug: requested.draft.slug,
        context: context,
        opts: opts,
        repairs: [],
        repair_count: 0,
        max_repairs: max_repairs(opts),
        failures: MapSet.new(),
        requested: requested
      }
      |> run_trial()
    end
  end

  defp run_trial(%{} = state) do
    with {:ok, trial} <- SandboxBridge.run_trial(state.slug, evidence_opts(:trial, state)) do
      case evidence_decision(:trial, trial) do
        :passed -> run_gate(Map.put(state, :trial, trial))
        :repair -> repair_and_retry(:trial, trial, state)
        {:halt, reason} -> {:error, reason}
      end
    end
  end

  defp run_gate(%{} = state) do
    with {:ok, gate} <- SandboxBridge.run_gate(state.slug, evidence_opts(:gate, state)) do
      case evidence_decision(:gate, gate) do
        :passed -> run_trusted_validation(Map.put(state, :gate, gate))
        :repair -> repair_and_retry(:gate, gate, state)
        {:halt, reason} -> {:error, reason}
      end
    end
  end

  defp evidence_decision(_kind, %{status: :completed}), do: :passed
  defp evidence_decision(_kind, %{status: :denied}), do: :repair
  defp evidence_decision(_kind, %{status: :failed}), do: :repair
  defp evidence_decision(_kind, %{status: :timed_out}), do: :repair

  defp evidence_decision(kind, %{status: status}) do
    {:halt, {:dynamic_codegen_evidence_not_repairable, %{stage: kind, status: status}}}
  end

  defp run_trusted_validation(%{} = state) do
    with {:ok, draft} <- MetadataStore.get_draft(state.slug),
         {:ok, manifest} <- MetadataStore.get_manifest(state.slug) do
      case TrustedValidator.validate(draft, manifest) do
        {:ok, validation} ->
          {:ok, completed(Map.put(state, :trusted_validation, validation), state.gate)}

        {:error, reason} ->
          repair_and_retry(
            :trusted_validation,
            %{
              status: :failed,
              draft: Draft.summary(draft),
              report: %{"validation_error" => bounded_inspect(reason)}
            },
            state
          )
      end
    end
  end

  defp repair_and_retry(kind, result, state) do
    evidence = repair_evidence(kind, result)
    fingerprint = evidence_fingerprint(evidence)

    cond do
      state.repair_count >= state.max_repairs ->
        {:error,
         {:dynamic_codegen_repair_impasse,
          %{
            "reason" => "repair_iteration_limit",
            "stage" => Atom.to_string(kind),
            "limit" => state.max_repairs,
            "iterations_used" => state.repair_count,
            "evidence" => evidence
          }}}

      MapSet.member?(state.failures, fingerprint) ->
        {:error,
         {:dynamic_codegen_repair_impasse,
          %{
            "reason" => "repeated_identical_failure",
            "stage" => Atom.to_string(kind),
            "iterations_used" => state.repair_count,
            "evidence" => evidence
          }}}

      true ->
        with {:ok, repair} <- Producer.repair_draft(state.slug, evidence, repair_context(state)) do
          state
          |> Map.update!(:repairs, &(&1 ++ [repair]))
          |> Map.update!(:repair_count, &(&1 + 1))
          |> Map.update!(:failures, &MapSet.put(&1, fingerprint))
          |> run_trial()
        end
    end
  end

  defp completed(state, gate) do
    %{
      status: :gate_passed,
      slug: state.slug,
      requested: state.requested,
      draft: gate.draft,
      trial: summarize_evidence(Map.fetch!(state, :trial)),
      gate: summarize_evidence(gate),
      trusted_validation: trusted_validation_summary(Map.fetch!(state, :trusted_validation)),
      repairs: state.repairs,
      repair_count: state.repair_count
    }
  end

  defp trusted_validation_summary(validation) do
    %{
      modules: Map.get(validation, :modules, []),
      actions: Map.get(validation, :actions, []),
      source_files:
        validation
        |> Map.get(:source_files, [])
        |> Enum.map(&Map.take(&1, [:source_path, :modules])),
      diagnostics: Map.get(validation, :diagnostics, [])
    }
  end

  defp summarize_evidence(result) do
    %{
      status: result.status,
      draft: result.draft,
      report: Map.get(result, :report),
      staging: Map.get(result, :staging),
      bundle: Map.get(result, :bundle)
    }
  end

  defp repair_evidence(kind, result) do
    %{
      "source" => "sandbox_#{kind}",
      "status" => result.status |> Atom.to_string(),
      "draft" => draft_evidence(result.draft),
      "report" => result |> Map.get(:report, %{}) |> json_safe()
    }
  end

  defp draft_evidence(%{revision: revision, slug: slug, tier: tier}) do
    %{"revision" => revision, "slug" => slug, "tier" => tier}
  end

  defp repair_context(state) do
    state.context
    |> Map.put_new(:explicit_generation?, true)
    |> Map.put_new(:source, "dynamic_codegen_workflow")
  end

  defp evidence_opts(kind, state) do
    state.opts
    |> Keyword.take(@sandbox_keys)
    |> Keyword.put(:profiles, profiles(kind, state.opts))
    |> Keyword.put(
      :operator_id,
      context_value(state.context, :operator_id) || context_value(state.context, :actor)
    )
    |> Keyword.put(:channel, context_value(state.context, :channel) || :sandbox)
    |> Keyword.put(:surface, context_value(state.context, :surface) || "dynamic_codegen_workflow")
    |> Keyword.put(:auto_repair?, false)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp profiles(:trial, opts) do
    Keyword.get(opts, :trial_profiles) || Keyword.get(opts, :profiles)
  end

  defp profiles(:gate, opts) do
    Keyword.get(opts, :gate_profiles) || Keyword.get(opts, :profiles)
  end

  defp agent_opts(opts), do: Keyword.get(opts, :agent_opts, [])

  defp max_repairs(opts) do
    case Keyword.get(opts, :max_repairs) do
      value when is_integer(value) and value >= 0 ->
        value

      _other ->
        case Settings.get("dynamic_codegen.max_repair_iterations") do
          {:ok, value} when is_integer(value) and value >= 0 -> value
          _fallback -> 2
        end
    end
  end

  defp evidence_fingerprint(evidence) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(canonical_failure(evidence)))
    |> Base.encode16(case: :lower)
  end

  defp canonical_failure(%{"report" => report} = evidence) do
    %{
      "source" => Map.get(evidence, "source"),
      "status" => Map.get(evidence, "status"),
      "report" => canonical_report(report)
    }
  end

  defp canonical_failure(evidence), do: evidence

  defp canonical_report(report) when is_map(report) do
    report = json_safe(report)

    %{
      "status" => Map.get(report, "status"),
      "exit_status" => Map.get(report, "exit_status"),
      "timed_out?" => Map.get(report, "timed_out?"),
      "truncated?" => Map.get(report, "truncated?"),
      "stdout" => Map.get(report, "stdout"),
      "stderr" => Map.get(report, "stderr"),
      "diagnostics" => Map.get(report, "diagnostics", []),
      "command" => canonical_command(Map.get(report, "command"))
    }
  end

  defp canonical_report(report), do: report

  defp canonical_command(command) when is_map(command) do
    command = json_safe(command)

    Map.take(command, [
      "argv",
      "denial_reason",
      "diagnostics",
      "env_keys",
      "executable",
      "profile",
      "status"
    ])
  end

  defp canonical_command(command), do: command

  defp json_safe(value) when is_map(value) do
    Map.new(value, fn {key, val} -> {json_safe_key(key), json_safe(val)} end)
  end

  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)
  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)
  defp json_safe(value) when is_tuple(value), do: bounded_inspect(value)
  defp json_safe(value), do: value

  defp json_safe_key(key) when is_binary(key), do: key
  defp json_safe_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_safe_key(key), do: bounded_inspect(key)

  defp bounded_inspect(value), do: inspect(value, limit: 20, printable_limit: 2_000)

  defp context_value(context, key), do: Map.get(context, key) || Map.get(context, to_string(key))
end
