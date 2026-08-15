defmodule AllbertAssist.Kernel.Contract do
  @moduledoc """
  Closed catalog and atomic binder for the kernel's sealed concern contracts.

  ADR 0098 §2 forbids the kernel from depending on a pack. The relocated
  concerns still need facts and effects that live in a pack, so each one owns a
  narrow contract here and a compiled owner supplies an implementation through
  composition.

  This is deliberately **not** a service locator. There is no `get(:anything)`
  entry point and no free-form context: `@contracts` below is a closed compile
  time set, `fetch/1` accepts only a member of it, and a kernel concern reaches
  its provider through its own named contract module rather than through this
  one. A concern therefore cannot reach a provider it was not bound to, which is
  the property that keeps the boundary from regrowing into the monolith behind a
  new name.

  ## Sealed binding, live values

  Composition validates the complete set and binds it atomically to the exact
  finalized Registry generation before effects open. What is sealed is the
  *binding*: which module answers for a concern, that it is compiled first-party
  code, and which generation it belongs to. It is not the data. Several
  providers read state an operator can change at runtime — Settings Central most
  of all — and freezing those values at composition time would silently defer
  every operator security-settings write until the next rebind. That is a
  product behaviour change the freeze forbids, so reads stay live (operator
  decision 2026-08-08, recorded in `docs/plans/archives/v1.4-plan.md` M7.1). The sealed
  immutable facts in this release are the Pack action catalog, which
  `AllbertAssist.Pack.Registry.snapshot/1` already owns.

  ## Fail-closed

  Missing, duplicate, malformed, stale, or lost providers leave the kernel
  unbound. An unbound concern returns its own existing fail-closed result — a
  denial for Security, `:product_not_ready` for the action Runner, an empty
  catalog for the Registry — never a guess and never a previously bound
  generation.
  """

  alias AllbertAssist.Kernel.Contract.{Binding, Provider}

  @term_key {__MODULE__, :binding}

  # The closed contract set. Each entry names the callbacks a provider must
  # export; a provider missing any of them is malformed and the whole bind
  # fails. Adding a row here is an additive change to the kernel contract and
  # requires a compiled owner to supply it before the set can bind.
  @contracts %{
    actions_overlay: [
      modules: 1,
      agent_modules: 1,
      actions_for_app: 2,
      diagnostics: 1,
      overlay_server: 1
    ],
    confirmations: [list: 1],
    grants: [applicable?: 2, canonical_ref: 1, redacted_ref: 1],
    home_roots: [override: 1],
    membership: [
      app_id_for_action: 2,
      plugin_id_for_action: 2,
      known_app_id?: 2,
      registered_plugins: 1
    ],
    release_availability: [ensure_live_use_allowed: 2],
    resource_refs: [from_external_request_summary: 1],
    response_values: [
      decision?: 1,
      decision_to_map: 1,
      decision_diagnostics: 1,
      decision_resource_access_maps: 1,
      decision_approval_handoff_map: 1,
      resource_access_to_maps: 1,
      approval_handoff_to_map: 1
    ],
    settings: [
      get: 1,
      defaults: 0,
      resolved_settings: 0,
      get_dotted: 2,
      secret_status: 1,
      version_contract_status: 0
    ],
    signals: [
      action_requested: 4,
      action_completed: 6,
      log: 1,
      emit_registration: 2
    ],
    skills: [get: 2]
  }

  @contract_ids @contracts |> Map.keys() |> Enum.sort()

  @typedoc "A member of the closed contract set."
  @type id ::
          :actions_overlay
          | :confirmations
          | :grants
          | :home_roots
          | :membership
          | :release_availability
          | :resource_refs
          | :response_values
          | :settings
          | :signals
          | :skills

  @doc "Every contract id in the closed set, sorted."
  @spec ids() :: [id()]
  def ids, do: @contracts |> Map.keys() |> Enum.sort()

  @doc "The callbacks a provider for `id` must export."
  @spec required_callbacks(id()) :: keyword(arity()) | nil
  def required_callbacks(id), do: Map.get(@contracts, id)

  @doc """
  Validate and atomically publish the complete contract set.

  Every contract in the closed set must be supplied exactly once by a loaded
  first-party module that exports its callbacks and resides in a started
  application. Validation completes before anything is published, so a rejected
  set leaves any existing binding untouched and never leaves a half-bound
  kernel.
  """
  @spec bind([term()], String.t(), pid()) :: {:ok, Binding.t()} | {:error, term()}
  def bind(providers, generation, barrier_pid) do
    with :ok <- validate_generation(generation),
         :ok <- validate_barrier(barrier_pid),
         {:ok, declared} <- normalize(providers),
         {:ok, indexed} <- index_by_contract(declared),
         :ok <- validate_coverage(indexed),
         :ok <- validate_implementations(indexed) do
      binding = %Binding{
        generation: generation,
        barrier_pid: barrier_pid,
        providers: indexed
      }

      :persistent_term.put(@term_key, binding)
      {:ok, binding}
    end
  end

  @doc """
  Delete the current binding as a unit.

  Release is how loss is expressed. Nothing is retained for a later read, so a
  concern that runs after a release fails closed rather than answering from a
  generation that no longer exists.
  """
  @spec release() :: :ok
  def release do
    :persistent_term.erase(@term_key)
    :ok
  end

  @doc "The currently bound set, or `{:error, :unbound}`."
  @spec current() :: {:ok, Binding.t()} | {:error, :unbound}
  def current do
    case :persistent_term.get(@term_key, nil) do
      %Binding{} = binding -> {:ok, binding}
      _unbound -> {:error, :unbound}
    end
  end

  @doc "The generation the current set is bound to, or `{:error, :unbound}`."
  @spec generation() :: {:ok, String.t()} | {:error, :unbound}
  def generation do
    with {:ok, %Binding{generation: generation}} <- current(), do: {:ok, generation}
  end

  @doc """
  Resolve the implementation bound for `id`.

  Only a member of the closed set resolves; an unknown id is a programming
  error in the kernel itself and is reported as one rather than being looked up.
  """
  @spec fetch(id()) :: {:ok, module()} | {:error, term()}
  def fetch(id) when is_map_key(@contracts, id) do
    with {:ok, %Binding{providers: providers}} <- current() do
      case Map.fetch(providers, id) do
        {:ok, %Provider{implementation: implementation}} -> {:ok, implementation}
        :error -> {:error, {:unbound_contract, id}}
      end
    end
  end

  def fetch(id), do: {:error, {:unknown_contract, id}}

  @doc """
  Resolve `id` only when the caller's generation is the bound one.

  A caller carrying an epoch token from an earlier composition is holding a
  stale reference; it is refused rather than served from the current generation,
  because silently upgrading it would let work admitted under one epoch complete
  under another.
  """
  @spec fetch(id(), String.t()) :: {:ok, module()} | {:error, term()}
  def fetch(id, generation) when is_map_key(@contracts, id) do
    with {:ok, %Binding{generation: bound}} <- current() do
      if bound == generation do
        fetch(id)
      else
        {:error, {:stale_generation, bound, generation}}
      end
    end
  end

  def fetch(id, _generation), do: {:error, {:unknown_contract, id}}

  defp validate_generation(generation) when is_binary(generation) and generation != "", do: :ok
  defp validate_generation(generation), do: {:error, {:invalid_generation, generation}}

  defp validate_barrier(pid) when is_pid(pid) do
    if Process.alive?(pid), do: :ok, else: {:error, {:barrier_not_alive, pid}}
  end

  defp validate_barrier(other), do: {:error, {:invalid_barrier, other}}

  defp normalize(providers) when is_list(providers) do
    Enum.reduce_while(providers, {:ok, []}, fn row, {:ok, acc} ->
      case Provider.new(row) do
        {:ok, provider} -> {:cont, {:ok, [provider | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, declared} -> {:ok, Enum.reverse(declared)}
      error -> error
    end
  end

  defp normalize(other), do: {:error, {:malformed_provider, other}}

  defp index_by_contract(declared) do
    duplicates =
      declared
      |> Enum.frequencies_by(& &1.contract)
      |> Enum.filter(fn {_contract, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    case duplicates do
      [] -> {:ok, Map.new(declared, &{&1.contract, &1})}
      _duplicated -> {:error, {:duplicate_providers, duplicates}}
    end
  end

  defp validate_coverage(indexed) do
    declared = Map.keys(indexed)

    missing = Enum.sort(@contract_ids -- declared)
    unknown = Enum.sort(declared -- @contract_ids)

    cond do
      unknown != [] -> {:error, {:unknown_contracts, unknown}}
      missing != [] -> {:error, {:missing_contracts, missing}}
      true -> :ok
    end
  end

  defp validate_implementations(indexed) do
    Enum.reduce_while(indexed, :ok, fn {contract, provider}, :ok ->
      case validate_implementation(contract, provider) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_implementation(contract, %Provider{} = provider) do
    with :ok <- validate_loaded(contract, provider),
         :ok <- validate_exports(contract, provider) do
      validate_residence(contract, provider)
    end
  end

  defp validate_loaded(contract, %Provider{implementation: implementation}) do
    if Code.ensure_loaded?(implementation) do
      :ok
    else
      {:error, {:provider_not_loaded, contract, implementation}}
    end
  end

  defp validate_exports(contract, %Provider{implementation: implementation}) do
    missing =
      @contracts
      |> Map.fetch!(contract)
      |> Enum.reject(fn {fun, arity} -> function_exported?(implementation, fun, arity) end)
      |> Enum.sort()

    case missing do
      [] -> :ok
      _absent -> {:error, {:malformed_provider, contract, implementation, missing}}
    end
  end

  # A provider must live in the application that declared it and that
  # application must be running. This is what makes a bound module compiled
  # first-party code rather than any module atom that happens to export the
  # right names.
  defp validate_residence(contract, %Provider{} = provider) do
    %Provider{implementation: implementation, application: application} = provider

    cond do
      not application_started?(application) ->
        {:error, {:provider_application_unavailable, contract, application}}

      implementation not in application_modules(application) ->
        {:error, {:provider_application_mismatch, contract, implementation, application}}

      true ->
        :ok
    end
  end

  defp application_started?(application) do
    Enum.any?(Application.started_applications(), &(elem(&1, 0) == application))
  end

  # An unloaded or specless application yields no modules, so a provider
  # claiming residence in one fails the membership check above rather than
  # passing on an empty list.
  defp application_modules(application) do
    case :application.get_key(application, :modules) do
      {:ok, modules} -> modules
      _undefined -> []
    end
  end
end
