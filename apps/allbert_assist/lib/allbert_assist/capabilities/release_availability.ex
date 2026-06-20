defmodule AllbertAssist.Capabilities.ReleaseAvailability do
  @moduledoc """
  Release-availability decisions for capability surfaces.

  This is not Settings Central and is not operator-overridable. Settings can
  enable or configure a released capability; they cannot turn an implemented but
  unreleased capability into live authority.
  """

  alias AllbertAssist.Plugin.Registry, as: PluginRegistry

  @allowed_kinds [:channel, :action, :plugin, :app]
  @release_statuses [:released, :implemented_not_released]
  @release_status_by_string Map.new(@release_statuses, &{Atom.to_string(&1), &1})

  @default %{
    release_status: :released,
    live_use_allowed?: true,
    decision: "Released for live use.",
    decision_ref: nil,
    future_features_ref: nil
  }

  @type capability_ref :: {atom(), String.t()}
  @type declaration :: map()

  @type decision :: %{
          required(:kind) => atom(),
          required(:id) => String.t(),
          required(:release_status) => atom(),
          required(:live_use_allowed?) => boolean(),
          required(:decision) => String.t(),
          required(:decision_ref) => String.t() | nil,
          required(:future_features_ref) => String.t() | nil
        }

  @spec decision(capability_ref(), keyword()) :: decision()
  def decision(ref, opts \\ []) do
    {kind, id} = normalize_ref(ref)

    (plugin_decision({kind, id}, opts) || @default)
    |> Map.put(:kind, kind)
    |> Map.put(:id, id)
  end

  @spec live_use_allowed?(capability_ref(), keyword()) :: boolean()
  def live_use_allowed?(ref, opts \\ []), do: decision(ref, opts).live_use_allowed?

  @spec release_status(capability_ref(), keyword()) :: atom()
  def release_status(ref, opts \\ []), do: decision(ref, opts).release_status

  @spec implemented_not_released?(capability_ref(), keyword()) :: boolean()
  def implemented_not_released?(ref, opts \\ []),
    do: release_status(ref, opts) == :implemented_not_released

  @spec ensure_live_use_allowed(capability_ref(), keyword()) ::
          :ok | {:error, {atom(), decision()}}
  def ensure_live_use_allowed(ref, opts \\ []) do
    if live_use_allowed?(ref, opts), do: :ok, else: {:error, blocked_reason(ref, opts)}
  end

  @spec blocked_reason(capability_ref(), keyword()) :: {atom(), decision()}
  def blocked_reason(ref, opts \\ []) do
    release_decision = decision(ref, opts)
    {release_decision.release_status, release_decision}
  end

  @spec diagnostic(capability_ref(), keyword()) :: atom() | nil
  def diagnostic(ref, opts \\ []) do
    if implemented_not_released?(ref, opts), do: :implemented_not_released, else: nil
  end

  @spec normalize_declarations(term()) :: {:ok, [declaration()]} | {:error, [term()]}
  def normalize_declarations(declarations) when is_list(declarations) do
    {normalized, errors} =
      Enum.reduce(declarations, {[], []}, fn declaration, {normalized, errors} ->
        case normalize_declaration(declaration) do
          {:ok, declaration} -> {[declaration | normalized], errors}
          {:error, reason} -> {normalized, [reason | errors]}
        end
      end)

    case errors do
      [] -> {:ok, Enum.reverse(normalized)}
      errors -> {:error, Enum.reverse(errors)}
    end
  end

  def normalize_declarations(_declarations), do: {:error, [:expected_list]}

  @spec normalize_declaration(term()) :: {:ok, declaration()} | {:error, term()}
  def normalize_declaration(declaration) when is_map(declaration) do
    with {:ok, kind} <- declaration_atom(declaration, :kind),
         {:ok, id} <- declaration_binary(declaration, :id),
         {:ok, release_status} <- declaration_release_status(declaration),
         {:ok, live_use_allowed?} <- declaration_boolean(declaration, :live_use_allowed?),
         {:ok, decision} <- declaration_binary(declaration, :decision),
         {:ok, decision_ref} <- declaration_optional_binary(declaration, :decision_ref),
         {:ok, future_features_ref} <-
           declaration_optional_binary(declaration, :future_features_ref) do
      {:ok,
       %{
         kind: kind,
         id: id,
         release_status: release_status,
         live_use_allowed?: live_use_allowed?,
         decision: decision,
         decision_ref: decision_ref,
         future_features_ref: future_features_ref
       }}
    end
  end

  def normalize_declaration(_declaration), do: {:error, :expected_map}

  defp normalize_ref({kind, id}) when is_atom(kind) and is_binary(id), do: {kind, id}
  defp normalize_ref({kind, id}) when is_atom(kind), do: {kind, to_string(id)}

  defp plugin_decision(ref, opts) do
    opts
    |> plugin_entries()
    |> Enum.flat_map(&Map.get(&1, :release_availability, []))
    |> Enum.find(fn declaration -> {declaration.kind, declaration.id} == ref end)
  end

  defp plugin_entries(opts) do
    case Keyword.fetch(opts, :plugin_entries) do
      {:ok, entries} when is_list(entries) ->
        entries

      :error ->
        PluginRegistry.registered_plugins()
    end
  catch
    :exit, _reason -> []
  end

  defp declaration_atom(declaration, key) do
    case declaration_value(declaration, key) do
      value when value in @allowed_kinds ->
        {:ok, value}

      value when is_binary(value) ->
        case Map.get(Map.new(@allowed_kinds, &{Atom.to_string(&1), &1}), value) do
          nil -> {:error, {:invalid_atom, key, allowed: @allowed_kinds}}
          kind -> {:ok, kind}
        end

      _other ->
        {:error, {:invalid_atom, key}}
    end
  end

  defp declaration_binary(declaration, key) do
    case declaration_value(declaration, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, {:invalid_string, key}}
    end
  end

  defp declaration_optional_binary(declaration, key) do
    case declaration_value(declaration, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _other -> {:error, {:invalid_optional_string, key}}
    end
  end

  defp declaration_boolean(declaration, :live_use_allowed?) do
    case first_value(declaration, [
           :live_use_allowed?,
           "live_use_allowed?",
           :live_use_allowed,
           "live_use_allowed"
         ]) do
      value when is_boolean(value) -> {:ok, value}
      _other -> {:error, {:invalid_boolean, :live_use_allowed?}}
    end
  end

  defp declaration_boolean(declaration, key) do
    case declaration_value(declaration, key) do
      value when is_boolean(value) -> {:ok, value}
      _other -> {:error, {:invalid_boolean, key}}
    end
  end

  defp declaration_release_status(declaration) do
    case declaration_value(declaration, :release_status) do
      status when status in @release_statuses -> {:ok, status}
      status when is_binary(status) -> release_status_from_string(status)
      _other -> {:error, {:invalid_release_status, @release_statuses}}
    end
  end

  defp release_status_from_string(status) do
    case Map.fetch(@release_status_by_string, status) do
      {:ok, status} -> {:ok, status}
      :error -> {:error, {:invalid_release_status, @release_statuses}}
    end
  end

  defp declaration_value(declaration, key),
    do: first_value(declaration, [key, Atom.to_string(key)])

  defp first_value(declaration, keys) do
    Enum.reduce_while(keys, nil, fn key, _acc ->
      if Map.has_key?(declaration, key) do
        {:halt, Map.get(declaration, key)}
      else
        {:cont, nil}
      end
    end)
  end
end
