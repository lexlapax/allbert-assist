defmodule AllbertAssist.DynamicPlugins.SandboxBridge do
  @moduledoc """
  Bridges v0.37 dynamic drafts into the v0.36 sandbox gate runner.

  This module records evidence only. A passing report can move a draft to a
  higher evidence tier, but it never registers actions, loads modules, or grants
  runtime authority.
  """

  alias AllbertAssist.DynamicPlugins.Draft
  alias AllbertAssist.DynamicPlugins.MetadataStore
  alias AllbertAssist.DynamicPlugins.Staging
  alias AllbertAssist.Sandbox
  alias AllbertAssist.Sandbox.Bundle
  alias AllbertAssist.Sandbox.Report
  alias AllbertAssist.Settings

  @sandbox_opts [:backends, :host, :operator_id, :policy]

  @doc "Run compile/focused-test trial evidence for one draft."
  def run_trial(slug, opts \\ []) when is_binary(slug) do
    run(:trial, slug, opts)
  end

  @doc "Run warning-gate evidence for one draft."
  def run_gate(slug, opts \\ []) when is_binary(slug) do
    run(:gate, slug, opts)
  end

  defp run(kind, slug, opts) do
    with :ok <- ensure_workflow_enabled(),
         {:ok, draft} <- MetadataStore.get_draft(slug),
         :ok <- ensure_runnable_tier(draft),
         {:ok, staging} <- Staging.build(draft, opts) do
      try do
        run_staged(kind, draft, staging, opts)
      after
        cleanup_staging(staging, opts)
      end
    end
  end

  defp ensure_workflow_enabled do
    case Settings.get("dynamic_codegen.enabled") do
      {:ok, true} -> :ok
      _other -> {:error, :dynamic_codegen_disabled}
    end
  end

  defp ensure_runnable_tier(%Draft{tier: tier}) when tier in ["discarded", "integrated"],
    do: {:error, {:draft_tier_not_runnable, tier}}

  defp ensure_runnable_tier(%Draft{}), do: :ok

  defp run_staged(kind, %Draft{} = draft, %Staging{} = staging, opts) do
    with {:ok, bundle} <- Sandbox.build_bundle(Staging.bundle_params(staging), sandbox_opts(opts)),
         {:ok, %Report{} = report} <- Sandbox.run_gate(bundle, gate_opts(kind, staging, opts)),
         {:ok, updated_draft} <- record_report(kind, draft, staging, bundle, report, opts) do
      {:ok,
       %{
         status: report.status,
         draft: Draft.summary(updated_draft),
         report: Report.to_map(report),
         staging: Staging.summary(staging),
         bundle: Bundle.summary(bundle)
       }}
    end
  end

  defp sandbox_opts(opts), do: Keyword.take(opts, @sandbox_opts)

  defp gate_opts(kind, %Staging{} = staging, opts) do
    opts
    |> sandbox_opts()
    |> Keyword.put(:profiles, profiles(kind, staging, opts))
    |> Keyword.put(:focused_test_paths, staging.focused_test_paths)
    |> maybe_put(:security_eval_paths, staging.security_eval_paths)
  end

  defp profiles(:trial, %Staging{} = staging, opts) do
    Keyword.get(opts, :profiles) ||
      if staging.focused_test_paths == [], do: [:compile], else: [:compile, :focused_tests]
  end

  defp profiles(:gate, _staging, opts) do
    Keyword.get(opts, :profiles) || [:compile, :focused_tests, :credo, :dialyzer, :security_evals]
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp record_report(
         kind,
         %Draft{} = draft,
         %Staging{} = staging,
         %Bundle{} = bundle,
         report,
         opts
       ) do
    copied_report_path = copy_report(draft, report)
    report_map = report |> Report.to_map() |> stringify_nested()
    status = evidence_status(kind, report.status)
    tier = evidence_tier(kind, report.status, profiles(kind, staging, opts), draft.tier)

    with {:ok, draft} <- maybe_transition(draft, tier, opts) do
      gate =
        draft.gate
        |> Map.merge(%{
          "status" => status,
          "kind" => Atom.to_string(kind),
          "sandbox_report_id" => report_id(copied_report_path || report.report_path),
          "sandbox_report_path" => copied_report_path,
          "bundle_id" => bundle.id,
          "bundle_report_path" => report.report_path,
          "profiles" => Enum.map(profiles(kind, staging, opts), &Atom.to_string/1),
          "staging" => stringify_nested(Staging.summary(staging)),
          "report" => report_map,
          "updated_at" => timestamp()
        })

      updated = %{draft | gate: gate, diagnostics: stringify_nested(report.diagnostics)}
      MetadataStore.put_draft(updated)
    end
  end

  defp maybe_transition(%Draft{} = draft, tier, _opts) when tier == draft.tier, do: {:ok, draft}

  defp maybe_transition(%Draft{} = draft, tier, opts) do
    Draft.put_tier(draft, tier, Keyword.take(opts, [:now]))
  end

  defp evidence_status(:gate, :completed), do: "passed"
  defp evidence_status(:trial, :completed), do: "passed"
  defp evidence_status(_kind, status), do: Atom.to_string(status)

  defp evidence_tier(:gate, :completed, _profiles, _current), do: "gate_passed"

  defp evidence_tier(:trial, :completed, profiles, _current) do
    if :focused_tests in profiles, do: "sandbox_trialed", else: "sandbox_compiled"
  end

  defp evidence_tier(_kind, _status, _profiles, current), do: current

  defp copy_report(%Draft{} = draft, %Report{report_path: path}) when is_binary(path) do
    if File.regular?(path) do
      reports_root = Path.join(draft.root || MetadataStore.draft_root(draft.slug), "reports")
      target = Path.join(reports_root, Path.basename(path))

      with :ok <- File.mkdir_p(reports_root),
           :ok <- File.cp(path, target) do
        target
      else
        _reason -> nil
      end
    end
  end

  defp report_id(nil), do: nil
  defp report_id(path), do: Path.basename(path, ".json")

  defp cleanup_staging(%Staging{} = staging, opts) do
    if Keyword.get(opts, :cleanup_staging?, true) do
      File.rm_rf(staging.root)
    end
  end

  defp stringify_nested(value) when is_map(value) do
    Map.new(value, fn {key, value} -> {to_string(key), stringify_nested(value)} end)
  end

  defp stringify_nested(values) when is_list(values), do: Enum.map(values, &stringify_nested/1)
  defp stringify_nested(value), do: value

  defp timestamp do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end
