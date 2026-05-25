defmodule AllbertAssist.Sandbox.GateRunner do
  @moduledoc """
  Deterministic v0.36 Elixir/OTP sandbox gate runner.

  The gate runner is a plain module: it holds no durable state and only
  coordinates public sandbox facade calls over reviewed gate profiles.
  """

  alias AllbertAssist.Sandbox
  alias AllbertAssist.Sandbox.Bundle
  alias AllbertAssist.Sandbox.Report
  alias AllbertAssist.Sandbox.ReportWriter

  @default_profiles [:compile, :focused_tests, :credo, :dialyzer, :security_evals]
  @security_eval_paths ["apps/allbert_assist/test/security/sandbox_eval_test.exs"]

  @spec run(Bundle.t(), keyword()) :: {:ok, Report.t()} | {:error, term()}
  def run(%Bundle{} = bundle, opts \\ []) do
    started_at = System.monotonic_time(:millisecond)
    profiles = profiles(opts)
    steps = Enum.flat_map(profiles, &steps_for(&1, opts))

    {status, reports} = run_steps(bundle, steps, opts)

    write_report(bundle, status, reports, profiles, started_at)
  end

  defp profiles(opts) do
    opts
    |> Keyword.get(:profiles, @default_profiles)
    |> List.wrap()
    |> Enum.map(&normalize_profile/1)
  end

  defp normalize_profile(profile) when is_atom(profile), do: profile
  defp normalize_profile(profile) when is_binary(profile), do: String.to_existing_atom(profile)

  defp steps_for(:compile, _opts) do
    [%{executable: "mix", argv: ["compile", "--warnings-as-errors"], profile: :compile}]
  end

  defp steps_for(:focused_tests, opts) do
    paths = Keyword.get(opts, :focused_test_paths, [])

    [
      test_step(
        ["test" | paths],
        :focused_tests,
        Keyword.get(opts, :focused_test_cwd) || Keyword.get(opts, :test_cwd)
      )
    ]
  end

  defp steps_for(:credo, _opts) do
    [%{executable: "mix", argv: ["credo", "--strict"], profile: :credo}]
  end

  defp steps_for(:dialyzer, _opts) do
    [%{executable: "mix", argv: ["dialyzer"], profile: :dialyzer}]
  end

  defp steps_for(:security_evals, opts) do
    paths = Keyword.get(opts, :security_eval_paths, @security_eval_paths)

    [
      test_step(
        ["test" | paths],
        :security_evals,
        Keyword.get(opts, :security_eval_cwd) || Keyword.get(opts, :test_cwd)
      )
    ]
  end

  defp steps_for(:precommit, _opts) do
    [%{executable: "mix", argv: ["precommit"], profile: :precommit}]
  end

  defp steps_for(other, _opts), do: raise(ArgumentError, "unknown sandbox gate profile #{other}")

  defp test_step(argv, profile, nil), do: %{executable: "mix", argv: argv, profile: profile}

  defp test_step(argv, profile, cwd),
    do: %{executable: "mix", argv: argv, profile: profile, cwd: cwd}

  defp run_steps(bundle, steps, opts) do
    Enum.reduce_while(steps, {:completed, []}, fn step, {_status, reports} ->
      case Sandbox.run_command(bundle, step, opts) do
        {:ok, %Report{status: :completed} = report} ->
          {:cont, {:completed, [report | reports]}}

        {:ok, %Report{} = report} ->
          {:halt, {report.status, [report | reports]}}

        {:error, reason} ->
          report = error_report(step, reason)
          {:halt, {:failed, [report | reports]}}
      end
    end)
    |> then(fn {status, reports} -> {status, Enum.reverse(reports)} end)
  end

  defp write_report(bundle, status, reports, profiles, started_at) do
    diagnostics =
      reports
      |> Enum.reject(&(&1.status == :completed))
      |> Enum.flat_map(& &1.diagnostics)

    ReportWriter.write(bundle, %Report{
      status: status,
      backend: :gate_runner,
      command: %{profiles: profiles},
      duration_ms: System.monotonic_time(:millisecond) - started_at,
      diagnostics: diagnostics,
      metadata: %{
        step_count: length(reports),
        steps: Enum.map(reports, &Report.to_map/1)
      }
    })
  end

  defp error_report(step, reason) do
    %Report{
      status: :failed,
      backend: :gate_runner,
      command: step,
      diagnostics: [%{reason: reason}]
    }
  end
end
