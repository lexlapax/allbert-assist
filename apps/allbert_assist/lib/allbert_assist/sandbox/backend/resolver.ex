defmodule AllbertAssist.Sandbox.Backend.Resolver do
  @moduledoc """
  OS-aware v0.36 sandbox backend resolver.
  """

  alias AllbertAssist.Sandbox.Backend.Registry
  alias AllbertAssist.Sandbox.Host
  alias AllbertAssist.Sandbox.Policy

  @type backend_id :: :apple_container | :docker | :docker_runsc | :podman_rootless

  @spec resolve(Policy.t(), keyword()) :: map()
  def resolve(%Policy{} = policy, opts \\ []) do
    host = Keyword.get(opts, :host, policy.host)
    backends = Keyword.get(opts, :backends, Registry.backends())
    candidates = candidate_modules(policy.backend, host, backends)
    evaluated = Enum.map(candidates, &evaluate_candidate(&1, policy, host, opts))
    selected = Enum.find(evaluated, &(&1.status == :available))

    %{
      resolved_backend: selected && selected.id,
      candidates: evaluated,
      diagnostics: diagnostics(policy, evaluated, selected)
    }
  end

  @spec auto_candidate_ids(Host.t()) :: [backend_id()]
  def auto_candidate_ids(%Host{} = host) do
    cond do
      Host.macos_apple_container_capable?(host) -> [:apple_container, :docker_runsc, :docker]
      host.os == :macos -> [:docker_runsc, :docker]
      host.os == :linux -> [:podman_rootless, :docker_runsc, :docker]
      true -> []
    end
  end

  defp candidate_modules("auto", host, backends) do
    ids = auto_candidate_ids(host)

    Enum.flat_map(ids, fn id ->
      case Enum.find(backends, &(&1.id() == id)) do
        nil -> [{:missing, id}]
        module -> [module]
      end
    end)
  end

  defp candidate_modules(backend, _host, backends) when is_binary(backend) do
    case Enum.find(backends, &(Atom.to_string(&1.id()) == backend)) do
      nil -> [{:missing, backend}]
      module -> [module]
    end
  end

  defp evaluate_candidate({:missing, id}, _policy, _host, _opts) do
    %{id: id, status: :unavailable, reason: :unknown_backend, diagnostics: []}
  end

  defp evaluate_candidate(module, policy, host, opts) do
    id = module.id()

    if host.os in module.platforms() do
      module
      |> doctor(policy, opts)
      |> Map.put_new(:id, id)
    else
      %{
        id: id,
        status: :unsupported,
        reason: {:unsupported_platform, host.os},
        diagnostics: []
      }
    end
  rescue
    exception ->
      %{
        id: safe_id(module),
        status: :unavailable,
        reason: {:doctor_error, exception.__struct__, Exception.message(exception)},
        diagnostics: []
      }
  end

  defp doctor(module, policy, opts) do
    if function_exported?(module, :doctor, 2) do
      apply(module, :doctor, [policy, opts])
    else
      apply(module, :doctor, [policy])
    end
  end

  defp diagnostics(policy, candidates, nil) do
    [
      %{
        reason: :no_available_backend,
        configured_backend: policy.backend,
        candidates: Enum.map(candidates, &Map.take(&1, [:id, :status, :reason]))
      }
    ]
  end

  defp diagnostics(_policy, _candidates, _selected), do: []

  defp safe_id(module) when is_atom(module) do
    if function_exported?(module, :id, 0), do: module.id(), else: module
  end

  defp safe_id(other), do: other
end
