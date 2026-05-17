defmodule AllbertAssist.Objectives.ProposerBehaviour do
  @moduledoc """
  Behaviour for app-owned deterministic objective step proposers.

  Proposers are advisory. They return inspectable step attributes; the
  objective engine persists those rows and later execution still crosses
  registered action boundaries.
  """

  @type hint :: {atom(), map()}
  @type continuation :: :done | {:more, hint()}

  @callback propose(map(), map() | keyword()) ::
              {:ok, [map()], continuation()} | {:no_steps, atom()}
end

defmodule AllbertAssist.Objectives.Proposer do
  @moduledoc """
  Deterministic dispatcher for app-owned objective step proposers.

  v0.24 keeps proposer registration explicit and local. A proposer module may
  contribute step attributes and an opaque continuation hint; those outputs are
  advisory and bounded. They never execute work or grant authority.
  """

  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.Security.Redactor

  @registry_key {__MODULE__, :registered_proposers}
  @max_state_bytes 3_500
  @max_steps 10

  @type hint :: {atom(), map()}
  @type continuation :: :done | {:more, hint()}

  @spec register_app_proposer(atom(), module()) :: :ok | {:error, term()}
  def register_app_proposer(app_id, proposer_module)
      when is_atom(app_id) and is_atom(proposer_module) do
    with :ok <- validate_app_id(app_id),
         :ok <- validate_proposer(proposer_module) do
      registry =
        @registry_key
        |> :persistent_term.get(%{})
        |> Map.put(app_id, proposer_module)

      :persistent_term.put(@registry_key, registry)
      :ok
    end
  end

  def register_app_proposer(app_id, proposer_module),
    do: {:error, {:invalid_proposer_registration, app_id, proposer_module}}

  @spec unregister_app_proposer(atom()) :: :ok
  def unregister_app_proposer(app_id) when is_atom(app_id) do
    registry = :persistent_term.get(@registry_key, %{})
    :persistent_term.put(@registry_key, Map.delete(registry, app_id))
    :ok
  end

  @spec registered_proposers() :: %{optional(atom()) => module()}
  def registered_proposers, do: :persistent_term.get(@registry_key, %{})

  @spec proposer_for(atom() | String.t() | nil) :: {:ok, module()} | {:error, term()}
  def proposer_for(app_id) do
    with {:ok, app_id} when not is_nil(app_id) <- normalize_app_id(app_id),
         {:ok, proposer} <- fetch_proposer(app_id) do
      {:ok, proposer}
    else
      {:ok, nil} -> {:error, :missing_app_id}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec propose(map(), map() | keyword()) ::
          {:ok, [map()], continuation()} | {:no_steps, atom()} | {:error, term()}
  def propose(intent_decision, context) when is_map(intent_decision) do
    context = normalize_context(context)

    with {:ok, app_id} <- app_id(intent_decision, context),
         {:ok, proposer} <- fetch_proposer(app_id) do
      proposer
      |> safe_propose(intent_decision, context)
      |> validate_result()
    end
  end

  def propose(_intent_decision, _context), do: {:error, :invalid_intent_decision}

  @spec hint_to_map(hint()) :: {:ok, map()} | {:error, term()}
  def hint_to_map({app_id, %{} = state}) when is_atom(app_id) do
    redacted = Redactor.redact(state)

    with {:ok, app_id} <- AppRegistry.normalize_app_id(app_id),
         {:ok, _json} <- bounded_json(redacted) do
      {:ok, %{"app_id" => Atom.to_string(app_id), "state" => redacted}}
    end
  catch
    :exit, reason -> {:error, {:unknown_app_id, app_id, reason}}
  end

  def hint_to_map(other), do: {:error, {:invalid_hint, other}}

  @spec normalize_hint(map() | tuple() | nil) :: {:ok, hint() | nil} | {:error, term()}
  def normalize_hint(nil), do: {:ok, nil}

  def normalize_hint({app_id, %{} = state}),
    do: normalize_hint(%{"app_id" => app_id, "state" => state})

  def normalize_hint(%{} = hint) do
    app_id = Map.get(hint, "app_id") || Map.get(hint, :app_id)
    state = Map.get(hint, "state") || Map.get(hint, :state)

    with {:ok, app_id} <- normalize_app_id(app_id),
         true <- is_map(state) do
      {:ok, {app_id, Redactor.redact(state)}}
    else
      false -> {:error, {:invalid_hint_state, state}}
      {:error, reason} -> {:error, reason}
    end
  end

  def normalize_hint(other), do: {:error, {:invalid_hint, other}}

  defp validate_proposer(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :propose, 2) do
      :ok
    else
      {:error, {:invalid_proposer_module, module}}
    end
  end

  defp validate_app_id(app_id) when is_atom(app_id) and app_id not in [nil, false, true] do
    :ok
  end

  defp validate_app_id(app_id), do: {:error, {:invalid_app_id, app_id}}

  defp app_id(intent_decision, context) do
    requested =
      field(context, :active_app) || field(context, :app_id) ||
        field(intent_decision, :active_app) || field(intent_decision, :app_id)

    normalize_app_id(requested)
  end

  defp normalize_app_id(nil), do: {:ok, nil}

  defp normalize_app_id(app_id) do
    AppRegistry.normalize_app_id(app_id)
  catch
    :exit, reason -> {:error, {:unknown_app_id, app_id, reason}}
  end

  defp fetch_proposer(app_id) do
    case Map.fetch(registered_proposers(), app_id) do
      {:ok, proposer} -> {:ok, proposer}
      :error -> {:error, {:no_proposer, app_id}}
    end
  end

  defp safe_propose(proposer, intent_decision, context) do
    proposer.propose(intent_decision, context)
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp validate_result({:ok, steps, continuation}) when is_list(steps) do
    with {:ok, steps} <- validate_steps(steps),
         {:ok, continuation} <- validate_continuation(continuation) do
      {:ok, steps, continuation}
    end
  end

  defp validate_result({:no_steps, reason}) when is_atom(reason), do: {:no_steps, reason}
  defp validate_result({:error, reason}), do: {:error, reason}
  defp validate_result(other), do: {:error, {:invalid_proposer_result, other}}

  defp validate_steps(steps) when length(steps) <= @max_steps do
    if Enum.all?(steps, &is_map/1) do
      {:ok, Enum.map(steps, &Redactor.redact/1)}
    else
      {:error, :invalid_step_attrs}
    end
  end

  defp validate_steps(_steps), do: {:error, :too_many_steps}

  defp validate_continuation(:done), do: {:ok, :done}

  defp validate_continuation({:more, hint}) do
    with {:ok, normalized} <- normalize_hint(hint),
         {:ok, _map} <- hint_to_map(normalized) do
      {:ok, {:more, normalized}}
    end
  end

  defp validate_continuation(other), do: {:error, {:invalid_continuation, other}}

  defp bounded_json(value) do
    case Jason.encode(value) do
      {:ok, json} when byte_size(json) <= @max_state_bytes -> {:ok, json}
      {:ok, _json} -> {:error, :hint_too_large}
      {:error, reason} -> {:error, {:invalid_hint_json, reason}}
    end
  end

  defp normalize_context(context) when is_list(context), do: Map.new(context)
  defp normalize_context(context) when is_map(context), do: context
  defp normalize_context(_context), do: %{}

  defp field(%_struct{} = struct, key), do: Map.get(struct, key)

  defp field(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
