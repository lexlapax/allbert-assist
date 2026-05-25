defmodule AllbertAssist.Sandbox do
  @moduledoc """
  Public v0.36 Elixir/OTP sandbox and gate-runner facade.

  v0.36 is report-only: a green doctor or future passing gate report never
  grants live runtime authority, loads modules, registers actions, or enables
  skills.
  """

  alias AllbertAssist.Paths
  alias AllbertAssist.Sandbox.Backend.Registry
  alias AllbertAssist.Sandbox.Backend.Resolver
  alias AllbertAssist.Sandbox.Bundle
  alias AllbertAssist.Sandbox.CommandSpec
  alias AllbertAssist.Sandbox.DoctorReport
  alias AllbertAssist.Sandbox.GateRunner
  alias AllbertAssist.Sandbox.Policy
  alias AllbertAssist.Sandbox.Report
  alias AllbertAssist.Sandbox.ReportWriter
  alias AllbertAssist.Signals

  @doc "Return a fail-closed sandbox doctor report."
  @spec doctor(keyword()) :: DoctorReport.t()
  def doctor(opts \\ []) do
    Paths.ensure_home!()
    policy = Policy.load!(opts)

    if policy.enabled? do
      policy
      |> Resolver.resolve(opts)
      |> DoctorReport.from_resolution(policy)
    else
      DoctorReport.disabled(policy)
    end
  end

  @doc "Build a disposable copy-in/copy-out sandbox bundle."
  @spec build_bundle(map(), keyword()) :: {:ok, Bundle.t()} | {:error, map()}
  def build_bundle(params, opts \\ []) when is_map(params) do
    Paths.ensure_home!()
    Bundle.build(params, opts)
  end

  @doc "Run one sandbox command through the configured backend."
  @spec run_command(Bundle.t(), CommandSpec.t() | map(), keyword()) ::
          {:ok, Report.t()} | {:error, term()}
  def run_command(%Bundle{} = bundle, command_spec, opts \\ []) do
    Paths.ensure_home!()
    policy = Keyword.get(opts, :policy) || Policy.load!(opts)

    with {:ok, spec} <- normalize_command(command_spec, bundle, policy),
         :ok <- ensure_enabled(policy, bundle, spec),
         {:ok, backend} <- resolve_backend(policy, bundle, spec, opts) do
      log_sandbox(:command_started, %{
        backend: backend.id(),
        bundle_id: bundle.id,
        command: CommandSpec.summary(spec)
      })

      backend
      |> apply(:run, [bundle, spec])
      |> tap_command_completion(bundle, backend, spec)
    else
      {:error, %CommandSpec{} = denied_spec} ->
        denied_report(bundle, denied_spec, :command_spec_denied, denied_spec.diagnostics)

      {:error, {:sandbox_denied, report}} ->
        {:ok, report}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Run a named sandbox gate over an existing or newly built bundle."
  @spec run_gate(Bundle.t() | map(), keyword()) :: {:ok, Report.t()} | {:error, term()}
  def run_gate(params, opts \\ [])

  def run_gate(%Bundle{} = bundle, opts) do
    log_sandbox(:gate_started, %{bundle_id: bundle.id, profiles: Keyword.get(opts, :profiles)})
    result = GateRunner.run(bundle, opts)
    tap_gate_completion(result, bundle)
  end

  def run_gate(params, opts) when is_map(params) do
    params = atomize_string_keys(params)

    cond do
      match?(%Bundle{}, Map.get(params, :bundle)) ->
        params
        |> Map.fetch!(:bundle)
        |> run_gate(gate_opts(params, opts))

      Map.has_key?(params, :project_root) ->
        with {:ok, bundle} <- build_bundle(params, opts) do
          run_gate(bundle, gate_opts(params, opts))
        end

      true ->
        {:error, :bundle_or_project_root_required}
    end
  end

  @doc "Discard a sandbox bundle."
  @spec cleanup(Bundle.t() | String.t()) :: :ok | {:error, term()}
  def cleanup(%Bundle{root: root}), do: cleanup(root)

  def cleanup(root) when is_binary(root) do
    with {:ok, root} <- normalize_cleanup_root(root) do
      log_sandbox(:cleanup, %{root: root})

      case File.rm_rf(root) do
        {:ok, _paths} -> :ok
        {:error, reason, path} -> {:error, {reason, path}}
      end
    end
  end

  defp normalize_command(%CommandSpec{} = spec, bundle, policy) do
    spec
    |> Map.from_struct()
    |> normalize_command(bundle, policy)
  end

  defp normalize_command(params, bundle, policy) when is_map(params) do
    CommandSpec.normalize(params, policy: policy, bundle: bundle)
  end

  defp normalize_command(_params, bundle, policy) do
    CommandSpec.normalize(%{}, policy: policy, bundle: bundle)
  end

  defp normalize_cleanup_root(root) do
    expanded = Path.expand(root)
    bundles_root = Path.expand(Paths.sandbox_bundles_root())

    cond do
      expanded == bundles_root ->
        {:error, :sandbox_bundle_root_required}

      not inside_root?(expanded, bundles_root) ->
        {:error, {:sandbox_bundle_root_outside_sandbox, expanded}}

      not direct_directory?(expanded) ->
        {:error, {:sandbox_bundle_root_invalid, expanded}}

      not File.regular?(Path.join(expanded, "metadata.json")) ->
        {:error, {:sandbox_bundle_metadata_missing, expanded}}

      true ->
        {:ok, expanded}
    end
  end

  defp inside_root?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp direct_directory?(path) do
    match?({:ok, %File.Stat{type: :directory}}, File.lstat(path))
  end

  defp ensure_enabled(%Policy{enabled?: true}, _bundle, _spec), do: :ok

  defp ensure_enabled(%Policy{} = policy, bundle, spec) do
    denied_report(bundle, spec, :sandbox_disabled, [
      %{reason: :sandbox_disabled, policy: Policy.summary(policy)}
    ])
    |> sandbox_denied()
  end

  defp resolve_backend(policy, bundle, spec, opts) do
    resolution = Resolver.resolve(policy, opts)

    log_sandbox(:backend_resolved, %{
      bundle_id: bundle.id,
      resolved_backend: resolution.resolved_backend,
      candidates: Enum.map(resolution.candidates, &Map.take(&1, [:id, :status, :reason]))
    })

    with backend_id when is_atom(backend_id) <- resolution.resolved_backend,
         {:ok, module} <- module_for_backend(backend_id, opts) do
      {:ok, module}
    else
      _other ->
        denied_report(bundle, spec, :no_available_backend, resolution.diagnostics)
        |> sandbox_denied()
    end
  end

  defp module_for_backend(backend_id, opts) do
    opts
    |> Keyword.get(:backends)
    |> case do
      backends when is_list(backends) ->
        case Enum.find(backends, &(&1.id() == backend_id)) do
          nil -> Registry.module_for(backend_id)
          module -> {:ok, module}
        end

      _other ->
        Registry.module_for(backend_id)
    end
  end

  defp denied_report(bundle, spec, reason, diagnostics) do
    log_sandbox(:command_denied, %{
      bundle_id: bundle.id,
      reason: reason,
      command: CommandSpec.summary(spec)
    })

    ReportWriter.write(bundle, %Report{
      status: :denied,
      backend: :sandbox,
      command: CommandSpec.summary(spec),
      diagnostics: diagnostics,
      metadata: %{reason: reason}
    })
  end

  defp sandbox_denied({:ok, report}), do: {:error, {:sandbox_denied, report}}
  defp sandbox_denied({:error, reason}), do: {:error, reason}

  defp tap_command_completion({:ok, %Report{} = report} = result, bundle, backend, spec) do
    log_sandbox(:command_completed, %{
      backend: backend.id(),
      bundle_id: bundle.id,
      command: CommandSpec.summary(spec),
      status: report.status,
      report_path: report.report_path
    })

    result
  end

  defp tap_command_completion(result, _bundle, _backend, _spec), do: result

  defp tap_gate_completion({:ok, %Report{} = report} = result, bundle) do
    log_sandbox(:gate_completed, %{
      bundle_id: bundle.id,
      status: report.status,
      report_path: report.report_path
    })

    result
  end

  defp tap_gate_completion(result, _bundle), do: result

  defp gate_opts(params, opts) do
    opts
    |> Keyword.put_new(:profiles, Map.get(params, :profiles))
    |> Keyword.put_new(:focused_test_paths, Map.get(params, :focused_test_paths))
    |> Keyword.put_new(:security_eval_paths, Map.get(params, :security_eval_paths))
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp atomize_string_keys(params) do
    params
    |> Enum.map(fn
      {key, value} when is_binary(key) -> {String.to_existing_atom(key), value}
      pair -> pair
    end)
    |> Map.new()
  rescue
    ArgumentError -> params
  end

  defp log_sandbox(kind, metadata) do
    kind
    |> Signals.sandbox_lifecycle(metadata)
    |> case do
      {:ok, signal} -> Signals.log(signal)
      {:error, _reason} -> :ok
    end
  end
end
