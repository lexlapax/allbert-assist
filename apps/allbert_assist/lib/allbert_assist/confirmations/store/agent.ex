defmodule AllbertAssist.Confirmations.Store.Agent do
  @moduledoc """
  JidoBacked coordinator for durable confirmation records.

  Confirmation files under Allbert Home remain authoritative. This agent owns a
  rebuildable projection of pending ids and routes lifecycle commands through
  private Jido actions so the confirmation store follows the same substrate
  pattern that v0.24 objectives will use.
  """

  alias AllbertAssist.Confirmations.Store.Commands
  alias AllbertAssist.Confirmations.Store.Persistence
  alias AllbertAssist.JidoBacked
  alias AllbertAssist.Pack.EffectGuard

  @create "allbert.confirmations.store.create"
  @read "allbert.confirmations.store.read"
  @list "allbert.confirmations.store.list"
  @resolve "allbert.confirmations.store.resolve"
  @annotate_resolution "allbert.confirmations.store.annotate_resolution"
  @expire "allbert.confirmations.store.expire"
  @rebuild "allbert.confirmations.store.rebuild"

  use JidoBacked,
    name: "allbert_confirmations_store",
    description: "Coordinates durable confirmation store lifecycle transitions.",
    signal_routes: [
      {@create, Commands.Create},
      {@read, Commands.Read},
      {@list, Commands.List},
      {@resolve, Commands.Resolve},
      {@annotate_resolution, Commands.AnnotateResolution},
      {@expire, Commands.Expire},
      {@rebuild, Commands.Rebuild}
    ]

  @doc false
  @impl true
  def rebuild_state(opts) do
    Persistence.rebuild_projection(opts)
  end

  @doc false
  @impl true
  def command_modules do
    [
      Commands.Create,
      Commands.Read,
      Commands.List,
      Commands.Resolve,
      Commands.AnnotateResolution,
      Commands.Expire,
      Commands.Rebuild
    ]
  end

  @doc false
  def create(attrs, effect_context, opts \\ [])

  def create(attrs, effect_context, opts)
      when is_map(attrs) and is_map(effect_context) and is_list(opts) do
    with :ok <- validate_effect_context(effect_context) do
      dispatch(@create, %{attrs: attrs, effect_context: effect_context, opts: opts})
    end
  end

  def create(_attrs, _effect_context, _opts), do: {:error, :product_not_ready}

  @doc false
  def read(id) when is_binary(id), do: dispatch(@read, %{id: id})

  @doc false
  def list(opts \\ []) when is_list(opts) do
    case dispatch(@list, %{opts: opts}) do
      {:ok, records} when is_list(records) -> records
      {:error, _reason} -> []
    end
  end

  @doc false
  def resolve(id, status, resolution_attrs, effect_context, opts \\ [])

  def resolve(id, status, resolution_attrs, effect_context, opts)
      when is_binary(id) and is_map(resolution_attrs) and is_map(effect_context) and is_list(opts) do
    with :ok <- validate_effect_context(effect_context) do
      dispatch(@resolve, %{
        id: id,
        status: status,
        resolution_attrs: resolution_attrs,
        effect_context: effect_context,
        opts: opts
      })
    end
  end

  def resolve(_id, _status, _attrs, _effect_context, _opts), do: {:error, :product_not_ready}

  @doc false
  def annotate_resolution(id, attrs, effect_context, opts \\ [])

  def annotate_resolution(id, attrs, effect_context, opts)
      when is_binary(id) and is_map(attrs) and is_map(effect_context) and is_list(opts) do
    with :ok <- validate_effect_context(effect_context) do
      dispatch(@annotate_resolution, %{
        id: id,
        attrs: attrs,
        effect_context: effect_context,
        opts: opts
      })
    end
  end

  def annotate_resolution(_id, _attrs, _effect_context, _opts), do: {:error, :product_not_ready}

  @doc false
  def expire(effect_context, opts \\ [])

  def expire(effect_context, opts) when is_map(effect_context) and is_list(opts) do
    with :ok <- validate_effect_context(effect_context) do
      dispatch(@expire, %{effect_context: effect_context, opts: opts})
    end
  end

  def expire(_effect_context, _opts), do: {:error, :product_not_ready}

  @doc false
  def ensure_root!, do: Persistence.ensure_root!()

  @doc false
  def dispatch(signal_type, data) when is_binary(signal_type) and is_map(data) do
    JidoBacked.dispatch(__MODULE__, signal_type, data,
      source: "/allbert/confirmations/store",
      timeout: :infinity
    )
  end

  defp validate_effect_context(%{allbert_pack_activation: _}), do: {:error, :product_not_ready}

  defp validate_effect_context(%{allbert_pack_epoch: epoch}), do: EffectGuard.validate(epoch)

  defp validate_effect_context(_context), do: {:error, :product_not_ready}
end
