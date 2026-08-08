if Mix.env() == :test do
  defmodule AllbertAssist.Kernel.Contract.TestProviders do
    @moduledoc false

    # Explicit test seam for the sealed-contract binder, kept in `lib/` for the
    # same reason as `AllbertAssist.Pack.EffectGuard.TestRegistry`: a provider
    # must reside in a started application's module list, and a `test/support`
    # module does not. One module satisfies every contract in the closed set —
    # no callback name/arity is shared between two contracts — so a valid
    # complete set is one row per contract pointing here.

    alias AllbertAssist.Kernel.Contract

    @settings_key {__MODULE__, :settings}
    @home_roots_key {__MODULE__, :home_roots}

    @doc """
    Substitute this module as the `settings` provider for the current binding.

    A kernel concern's real dependency after M8 is its contract, not Settings
    Central, so a kernel test states the settings it needs and binds them here
    instead of writing a temporary Allbert Home and driving `Settings.put/3`
    through the residual. The rest of the bound set is carried over unchanged,
    so nothing else about the generation changes.

    Returns a zero-arity restore function.
    """
    @spec stub_settings!(%{optional(String.t()) => term()}) :: (-> :ok)
    def stub_settings!(values) when is_map(values), do: rebind!(:settings, @settings_key, values)

    @doc """
    Substitute this module as the `home_roots` provider for the current binding.

    Keys are the canonical root ids `AllbertAssist.Kernel.Contract.HomeRoots`
    accepts. This is how a kernel test states an owner-contributed root override
    without naming the residual module whose application-environment key used to
    carry it.
    """
    @spec stub_home_roots!(%{optional(atom()) => Path.t()}) :: (-> :ok)
    def stub_home_roots!(values) when is_map(values),
      do: rebind!(:home_roots, @home_roots_key, values)

    defp rebind!(contract, key, values) do
      {:ok, binding} = Contract.current()
      :persistent_term.put(key, values)

      {:ok, _stubbed} =
        Contract.bind(providers(binding, contract), binding.generation, binding.barrier_pid)

      fn ->
        :persistent_term.erase(key)
        {:ok, _restored} = Contract.bind(providers(binding), binding.generation, binding.barrier_pid)
        :ok
      end
    end

    defp providers(binding, stubbed \\ nil) do
      Enum.map(binding.providers, fn
        {^stubbed, _provider} when not is_nil(stubbed) -> {stubbed, __MODULE__, :allbert_kernel}
        {contract, provider} -> {contract, provider.implementation, provider.application}
      end)
    end

    defp stubbed_settings, do: :persistent_term.get(@settings_key, %{})
    defp stubbed_home_roots, do: :persistent_term.get(@home_roots_key, %{})

    @doc "A complete, valid provider set for the closed contract catalog."
    @spec complete(module()) :: [{atom(), module(), atom()}]
    def complete(implementation \\ __MODULE__) do
      Enum.map(Contract.ids(), &{&1, implementation, :allbert_kernel})
    end

    @doc "A complete set with `contract` removed."
    @spec without(atom()) :: [{atom(), module(), atom()}]
    def without(contract), do: Enum.reject(complete(), &(elem(&1, 0) == contract))

    @doc "A complete set with `contract` declared twice."
    @spec duplicating(atom()) :: [{atom(), module(), atom()}]
    def duplicating(contract) do
      complete() ++ [{contract, __MODULE__, :allbert_kernel}]
    end

    @doc "A complete set whose `contract` row points at `implementation`."
    @spec replacing(atom(), module(), atom()) :: [{atom(), module(), atom()}]
    def replacing(contract, implementation, application \\ :allbert_kernel) do
      Enum.map(complete(), fn
        {^contract, _module, _app} -> {contract, implementation, application}
        row -> row
      end)
    end

    # actions_overlay
    def modules(_opts), do: []
    def agent_modules(_opts), do: []
    def actions_for_app(_app_id, _opts), do: []
    def diagnostics(_opts), do: []
    def overlay_server(_opts), do: __MODULE__

    # confirmations
    def list(_opts), do: []

    # grants
    def applicable?(_permission, _context), do: false
    def canonical_ref(_params), do: :error
    def redacted_ref(_ref), do: nil

    # home_roots
    def override(root_id), do: Map.get(stubbed_home_roots(), root_id)

    # membership
    def app_id_for_action(_module, _opts), do: nil
    def plugin_id_for_action(_module, _opts), do: nil
    def known_app_id?(_app_id, _opts), do: false
    def registered_plugins(_opts), do: []

    # release_availability
    def ensure_live_use_allowed(_ref, _opts), do: :ok

    # resource_refs
    def from_external_request_summary(_summary), do: []

    # response_values
    def decision?(_term), do: false
    def decision_to_map(_decision), do: %{}
    def decision_diagnostics(_decision), do: []
    def decision_resource_access_maps(_decision), do: []
    def decision_approval_handoff_map(_decision), do: nil
    def resource_access_to_maps(_entries), do: []
    def approval_handoff_to_map(_handoff), do: nil

    # settings, plus `skills.get/2` grouped here so the compiler does not warn
    # about split clauses of the same name.
    def get(key) do
      case Map.fetch(stubbed_settings(), key) do
        {:ok, value} -> {:ok, value}
        :error -> {:error, :not_found}
      end
    end
    def get(_selected, _context), do: {:error, :not_found}
    def defaults, do: %{}
    def resolved_settings, do: {:error, :unavailable}
    def get_dotted(_settings, _key), do: nil
    def secret_status(_ref), do: %{}
    def version_contract_status, do: %{}

    # signals
    def action_requested(_signal, _module, _params, _context), do: :ok
    def action_completed(_signal, _module, _status, _response, _context, _duration_ms), do: :ok
    def log(_signal), do: :ok
    def emit_registration(_reason, _metadata), do: :ok
  end
end
