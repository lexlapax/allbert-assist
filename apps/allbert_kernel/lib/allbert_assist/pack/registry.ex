defmodule AllbertAssist.Pack.Registry do
  @moduledoc """
  Atomic owner of the collecting/finalized Pack snapshot lifecycle.

  This is a plain GenServer because it owns bounded lifecycle state and an
  immutable snapshot. It performs no model reasoning, Skill composition,
  permission decision, or Pack effect.
  """

  use GenServer

  alias AllbertAssist.Pack.Canonical
  alias AllbertAssist.Pack.{CompatibilityDiagnostic, ValidationDiagnostic}
  alias AllbertAssist.Pack.Registry.{Candidate, Snapshot}

  @default_coordinator :allbert_pack_composition_owner
  @call_timeout 30_000
  @start_option_keys [:name, :publication, :coordinator]

  defstruct phase: :collecting,
            publication: :shadow,
            coordinator: @default_coordinator,
            candidate: nil,
            snapshot: nil,
            effectful_ids: nil,
            canonical_bytes: nil,
            diagnostics: []

  @type phase :: :collecting | :finalized
  @type publication :: :shadow | :authoritative

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    with :ok <- validate_start_options(opts) do
      case Keyword.get(opts, :publication, :shadow) do
        publication when publication in [:shadow, :authoritative] ->
          start_registry(opts)

        publication ->
          {:error, {:unsupported_publication, publication}}
      end
    end
  end

  defp start_registry(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl true
  def init(opts) do
    {:ok,
     %__MODULE__{
       publication: Keyword.get(opts, :publication, :shadow),
       coordinator: Keyword.get(opts, :coordinator, @default_coordinator)
     }}
  end

  @spec status(keyword()) ::
          {:ok,
           %{
             phase: phase(),
             publication: publication(),
             behavior_digest: String.t() | nil
           }}
          | {:error, :unavailable}
  def status(opts \\ []), do: call(opts, :status)

  @spec snapshot(keyword()) :: {:ok, Snapshot.t()} | {:error, :collecting | :unavailable}
  def snapshot(opts \\ []), do: call(opts, :snapshot)

  @spec finalize(Candidate.t(), keyword()) ::
          {:ok, Snapshot.t()}
          | {:error, :unavailable}
          | {:error, {:not_coordinator, ValidationDiagnostic.t()}}
          | {:error, {:invalid_candidate, [ValidationDiagnostic.t()]}}
          | {:error, {:already_finalized, String.t()}}
  def finalize(candidate, opts \\ []) do
    with {:ok, server, effectful_ids} <- finalize_options(opts) do
      safe_call(server, {:finalize, candidate, effectful_ids})
    end
  end

  @doc false
  @spec effectful_ids(keyword()) :: {:ok, [String.t()]} | {:error, :collecting | :unavailable}
  def effectful_ids(opts \\ []), do: call(opts, :effectful_ids)

  @spec diagnostics(keyword()) :: {:ok, [CompatibilityDiagnostic.t()]} | {:error, :unavailable}
  def diagnostics(opts \\ []), do: call(opts, :diagnostics)

  @impl true
  def handle_call(:status, _from, state) do
    digest = if state.snapshot, do: state.snapshot.behavior_digest

    {:reply,
     {:ok,
      %{
        phase: state.phase,
        publication: state.publication,
        behavior_digest: digest
      }}, state}
  end

  def handle_call(:snapshot, _from, %{phase: :collecting} = state),
    do: {:reply, {:error, :collecting}, state}

  def handle_call(:snapshot, _from, state), do: {:reply, {:ok, state.snapshot}, state}

  def handle_call(:effectful_ids, _from, %{phase: :collecting} = state),
    do: {:reply, {:error, :collecting}, state}

  def handle_call(:effectful_ids, _from, state),
    do: {:reply, {:ok, state.effectful_ids}, state}

  def handle_call(:diagnostics, _from, state), do: {:reply, {:ok, state.diagnostics}, state}

  def handle_call(
        {:finalize, candidate, requested_effectful_ids},
        {caller, _tag},
        %{phase: :collecting} = state
      ) do
    if coordinator?(state.coordinator, caller) do
      finalize_collecting_candidate(candidate, requested_effectful_ids, state)
    else
      {:reply, not_coordinator_error(), state}
    end
  end

  def handle_call(
        {:finalize, candidate, requested_effectful_ids},
        {caller, _tag},
        %{phase: :finalized} = state
      ) do
    requested_effectful_ids =
      normalize_requested_effectful_ids(requested_effectful_ids, state.snapshot)

    cond do
      not coordinator?(state.coordinator, caller) ->
        {:reply, not_coordinator_error(), state}

      requested_effectful_ids != {:ok, state.effectful_ids} ->
        {:reply, {:error, {:already_finalized, state.snapshot.behavior_digest}}, state}

      candidate == state.candidate ->
        {:reply, {:ok, state.snapshot}, state}

      true ->
        case canonicalize_candidate(candidate, state.publication) do
          {:ok, candidate_snapshot, candidate_bytes}
          when candidate_bytes == state.canonical_bytes and
                 candidate_snapshot.behavior_digest == state.snapshot.behavior_digest ->
            {:reply, {:ok, state.snapshot}, state}

          {:ok, _candidate_snapshot, _candidate_bytes} ->
            {:reply, {:error, {:already_finalized, state.snapshot.behavior_digest}}, state}

          {:error, reason} ->
            {:reply, {:error, {:invalid_candidate, reason}}, state}
        end
    end
  end

  defp finalize_collecting_candidate(candidate, requested_effectful_ids, state) do
    case canonicalize_candidate(candidate, state.publication) do
      {:ok, snapshot, bytes} ->
        finalize_with_effectful_ids(candidate, requested_effectful_ids, snapshot, bytes, state)

      {:error, reason} ->
        {:reply, {:error, {:invalid_candidate, reason}}, state}
    end
  end

  defp finalize_with_effectful_ids(candidate, requested_effectful_ids, snapshot, bytes, state) do
    with {:ok, effectful_ids} <- validate_effectful_ids(requested_effectful_ids, snapshot) do
      {:reply, {:ok, snapshot},
       %{
         state
         | phase: :finalized,
           candidate: candidate,
           snapshot: snapshot,
           effectful_ids: effectful_ids,
           canonical_bytes: bytes,
           diagnostics: snapshot.compatibility_diagnostics
       }}
    else
      {:error, diagnostics} ->
        {:reply, {:error, {:invalid_candidate, diagnostics}}, state}
    end
  end

  defp call(opts, message) when is_list(opts) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) == Enum.uniq(Keyword.keys(opts)) and
         Enum.all?(Keyword.keys(opts), &(&1 == :server)) do
      server = Keyword.get(opts, :server, __MODULE__)

      if valid_call_server?(server) do
        try do
          GenServer.call(server, message, @call_timeout)
        rescue
          _error -> {:error, :unavailable}
        catch
          _kind, _reason -> {:error, :unavailable}
        end
      else
        {:error, :unavailable}
      end
    else
      {:error, :unavailable}
    end
  end

  defp call(_opts, _message), do: {:error, :unavailable}

  defp finalize_options(opts) when is_list(opts) do
    keys = Keyword.keys(opts)

    if Keyword.keyword?(opts) and keys == Enum.uniq(keys) and
         Enum.all?(keys, &(&1 in [:server, :effectful_ids])) do
      server = Keyword.get(opts, :server, __MODULE__)

      if valid_call_server?(server) do
        {:ok, server, Keyword.get(opts, :effectful_ids, :derive_all)}
      else
        {:error, :unavailable}
      end
    else
      {:error, :unavailable}
    end
  end

  defp finalize_options(_opts), do: {:error, :unavailable}

  defp safe_call(server, message) do
    try do
      GenServer.call(server, message, @call_timeout)
    rescue
      _error -> {:error, :unavailable}
    catch
      _kind, _reason -> {:error, :unavailable}
    end
  end

  defp validate_effectful_ids(requested, snapshot) do
    case normalize_requested_effectful_ids(requested, snapshot) do
      {:ok, ids} ->
        {:ok, ids}

      :error ->
        {:error,
         [
           %ValidationDiagnostic{
             schema_version: 1,
             code: :invalid_value,
             path: [],
             owner: nil,
             detail: %{reason: :invalid_effectful_ids}
           }
         ]}
    end
  end

  defp normalize_requested_effectful_ids(:derive_all, snapshot) do
    {:ok, effective_owner_ids(snapshot)}
  end

  defp normalize_requested_effectful_ids(ids, snapshot) when is_list(ids) do
    owner_ids = snapshot |> effective_owner_ids() |> MapSet.new()

    if ids == Enum.sort(Enum.uniq(ids)) and Enum.all?(ids, &is_binary/1) and
         Enum.all?(ids, &MapSet.member?(owner_ids, &1)) do
      {:ok, ids}
    else
      :error
    end
  end

  defp normalize_requested_effectful_ids(_ids, _snapshot), do: :error

  defp effective_owner_ids(snapshot) do
    snapshot.contributions
    |> Enum.reject(&(&1.compatibility.kind == :deprecated_alias))
    |> Enum.map(& &1.owner.id)
    |> Enum.sort()
  end

  defp coordinator?(coordinator, caller) when is_pid(coordinator), do: coordinator == caller

  defp coordinator?(coordinator, caller) do
    try do
      GenServer.whereis(coordinator) == caller
    rescue
      _error -> false
    catch
      _kind, _reason -> false
    end
  end

  defp canonicalize_candidate(candidate, publication) do
    try do
      with {:ok, snapshot} <- Canonical.build_snapshot(candidate, publication),
           {:ok, bytes} <- Canonical.snapshot_bytes(snapshot) do
        {:ok, snapshot, bytes}
      else
        {:error, [%ValidationDiagnostic{} | _diagnostics]} = error -> error
        _error -> canonicalization_rejection()
      end
    rescue
      _error -> canonicalization_rejection()
    catch
      _kind, _reason -> canonicalization_rejection()
    end
  end

  defp canonicalization_rejection do
    {:error,
     [
       %ValidationDiagnostic{
         schema_version: 1,
         code: :canonicalization_rejected,
         path: [],
         owner: nil,
         detail: %{value_kind: "candidate"}
       }
     ]}
  end

  defp validate_start_options(opts) when is_list(opts) do
    cond do
      not Keyword.keyword?(opts) ->
        {:error, {:invalid_options, :not_keyword}}

      duplicate = duplicate_option(opts) ->
        {:error, {:invalid_options, {:duplicate, duplicate}}}

      unknown = Enum.find(Keyword.keys(opts), &(&1 not in @start_option_keys)) ->
        {:error, {:invalid_options, {:unknown, unknown}}}

      not valid_registration_name?(Keyword.get(opts, :name, __MODULE__)) ->
        {:error, {:invalid_options, {:invalid, :name}}}

      not valid_coordinator?(Keyword.get(opts, :coordinator, @default_coordinator)) ->
        {:error, {:invalid_options, {:invalid, :coordinator}}}

      true ->
        :ok
    end
  end

  defp validate_start_options(_opts), do: {:error, {:invalid_options, :not_keyword}}

  defp duplicate_option(opts) do
    opts
    |> Keyword.keys()
    |> Enum.frequencies()
    |> Enum.filter(fn {_key, count} -> count > 1 end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
    |> List.first()
  end

  defp valid_coordinator?(coordinator) when is_pid(coordinator), do: true

  defp valid_coordinator?(coordinator)
       when is_atom(coordinator) and coordinator not in [nil, true, false],
       do: true

  defp valid_coordinator?({:global, _term}), do: true

  defp valid_coordinator?({:via, module, _term}) when is_atom(module),
    do: via_lookup_module?(module)

  defp valid_coordinator?(_coordinator), do: false

  defp valid_call_server?(server) when is_pid(server), do: true
  defp valid_call_server?(server), do: valid_registration_name?(server) and not is_nil(server)

  defp valid_registration_name?(nil), do: true

  defp valid_registration_name?(server)
       when is_atom(server) and server not in [true, false],
       do: true

  defp valid_registration_name?({:global, _term}), do: true

  defp valid_registration_name?({:via, module, _term}) when is_atom(module) do
    via_lookup_module?(module) and
      Enum.all?([{:register_name, 2}, {:unregister_name, 1}, {:send, 2}], fn {function, arity} ->
        function_exported?(module, function, arity)
      end)
  end

  defp valid_registration_name?(_server), do: false

  defp via_lookup_module?(module),
    do: Code.ensure_loaded?(module) and function_exported?(module, :whereis_name, 1)

  defp not_coordinator_error do
    {:error,
     {:not_coordinator,
      %ValidationDiagnostic{
        schema_version: 1,
        code: :not_coordinator,
        path: [],
        owner: nil,
        detail: %{expected: :registered_coordinator, actual: :different_process}
      }}}
  end
end
