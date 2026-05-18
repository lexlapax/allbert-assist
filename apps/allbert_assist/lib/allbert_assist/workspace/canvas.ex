defmodule AllbertAssist.Workspace.Canvas do
  @moduledoc """
  Plain Ecto-backed store for per-thread workspace canvas tiles.
  """

  import Ecto.Query

  alias AllbertAssist.Repo
  alias AllbertAssist.Settings
  alias AllbertAssist.Workspace.BodyStore
  alias AllbertAssist.Workspace.Canvas.Tile

  @default_max_tiles 64

  @type tile :: Tile.t()

  @spec tiles_for_thread(String.t(), String.t(), keyword()) :: {:ok, [tile()]} | {:error, term()}
  def tiles_for_thread(thread_id, user_id, opts \\ [])
      when is_binary(thread_id) and is_binary(user_id) do
    include_deleted? = Keyword.get(opts, :include_deleted, false)

    Tile
    |> where([tile], tile.thread_id == ^thread_id and tile.user_id == ^user_id)
    |> maybe_live_only(include_deleted?)
    |> order_by([tile], asc: tile.position, asc: tile.inserted_at)
    |> Repo.all()
    |> load_bodies()
  end

  @spec add_tile(map()) :: {:ok, tile()} | {:error, term()}
  def add_tile(attrs) when is_map(attrs) do
    attrs = normalize_attrs(attrs)

    with {:ok, attrs} <- put_create_defaults(attrs),
         :ok <- enforce_cap(attrs.user_id, attrs.thread_id),
         :ok <- BodyStore.write_body(attrs.body_yaml_path, attrs.body) do
      %Tile{}
      |> Tile.changeset(Map.delete(attrs, :body))
      |> Repo.insert()
      |> load_body_result()
    end
  end

  def add_tile(_attrs), do: {:error, :invalid_tile_attrs}

  @spec update_tile(String.t(), map()) :: {:ok, tile()} | {:error, term()}
  def update_tile(tile_id, attrs) when is_binary(tile_id) and is_map(attrs) do
    attrs = normalize_attrs(attrs)

    with {:ok, tile} <- get_live_tile(tile_id),
         :ok <- authorize_scope(tile, attrs),
         :ok <- maybe_write_body(tile.body_yaml_path, Map.fetch(attrs, :body)) do
      tile
      |> Tile.changeset(Map.drop(attrs, [:body, :user_id, :thread_id]))
      |> Repo.update()
      |> load_body_result()
    end
  end

  @spec remove_tile(String.t(), String.t()) :: :ok | {:error, term()}
  def remove_tile(tile_id, user_id) when is_binary(tile_id) and is_binary(user_id) do
    with {:ok, tile} <- get_user_tile(tile_id, user_id),
         :ok <- soft_delete(tile, DateTime.utc_now()) do
      :ok
    end
  end

  @spec pin_tile(String.t(), String.t()) :: {:ok, tile()} | {:error, term()}
  def pin_tile(tile_id, user_id), do: set_pinned(tile_id, user_id, true)

  @spec unpin_tile(String.t(), String.t()) :: {:ok, tile()} | {:error, term()}
  def unpin_tile(tile_id, user_id), do: set_pinned(tile_id, user_id, false)

  @spec restore_tile(String.t(), String.t()) :: {:ok, tile()} | {:error, term()}
  def restore_tile(tile_id, user_id) when is_binary(tile_id) and is_binary(user_id) do
    with {:ok, tile} <- get_user_tile(tile_id, user_id, include_deleted: true),
         {:ok, restored_path} <- restore_body_path(tile),
         :ok <- enforce_cap(tile.user_id, tile.thread_id),
         position <- next_position(tile.user_id, tile.thread_id) do
      tile
      |> Tile.changeset(%{
        body_yaml_path: restored_path,
        deleted_at: nil,
        position: position
      })
      |> Repo.update()
      |> load_body_result()
    end
  end

  defp set_pinned(tile_id, user_id, pinned?) do
    with {:ok, tile} <- get_user_tile(tile_id, user_id) do
      tile
      |> Tile.changeset(%{pinned: pinned?})
      |> Repo.update()
      |> load_body_result()
    end
  end

  defp get_live_tile(tile_id) do
    case Repo.get(Tile, tile_id) do
      %Tile{deleted_at: nil} = tile -> {:ok, tile}
      _other -> {:error, :not_found}
    end
  end

  defp get_user_tile(tile_id, user_id, opts \\ []) do
    include_deleted? = Keyword.get(opts, :include_deleted, false)

    query =
      Tile
      |> where([tile], tile.id == ^tile_id and tile.user_id == ^user_id)
      |> maybe_live_only(include_deleted?)

    case Repo.one(query) do
      %Tile{} = tile -> {:ok, tile}
      nil -> {:error, :not_found}
    end
  end

  defp put_create_defaults(attrs) do
    id = Map.get(attrs, :id) || new_id("tile")
    user_id = required_string(attrs, :user_id)
    thread_id = required_string(attrs, :thread_id)
    kind = attrs |> Map.get(:kind, :text) |> normalize_kind()

    cond do
      is_nil(user_id) -> {:error, {:missing_required, :user_id}}
      is_nil(thread_id) -> {:error, {:missing_required, :thread_id}}
      true -> {:ok, create_defaults(attrs, id, user_id, thread_id, kind)}
    end
  end

  defp create_defaults(attrs, id, user_id, thread_id, kind) do
    attrs
    |> Map.put(:id, id)
    |> Map.put(:user_id, user_id)
    |> Map.put(:thread_id, thread_id)
    |> Map.put(:kind, kind)
    |> Map.put_new(:position, next_position(user_id, thread_id))
    |> Map.put_new(:size_width, 400)
    |> Map.put_new(:size_height, 300)
    |> Map.put_new(:pinned, false)
    |> Map.put_new(:metadata, %{})
    |> Map.put_new(:body, %{})
    |> Map.put_new(:body_yaml_path, BodyStore.canvas_body_path(user_id, thread_id, id))
  end

  defp enforce_cap(user_id, thread_id) do
    active_count =
      Tile
      |> where(
        [tile],
        tile.user_id == ^user_id and tile.thread_id == ^thread_id and is_nil(tile.deleted_at)
      )
      |> Repo.aggregate(:count, :id)

    if active_count < max_tiles_per_thread() do
      :ok
    else
      evict_oldest_non_pinned(user_id, thread_id)
    end
  end

  defp evict_oldest_non_pinned(user_id, thread_id) do
    tile =
      Tile
      |> where(
        [tile],
        tile.user_id == ^user_id and tile.thread_id == ^thread_id and is_nil(tile.deleted_at) and
          tile.pinned == false
      )
      |> order_by([tile], asc: tile.inserted_at, asc: tile.position)
      |> limit(1)
      |> Repo.one()

    case tile do
      %Tile{} -> soft_delete(tile, DateTime.utc_now())
      nil -> {:error, :canvas_cap_exceeded}
    end
  end

  defp soft_delete(%Tile{} = tile, timestamp) do
    deleted_path = BodyStore.deleted_canvas_body_path(tile.body_yaml_path, timestamp)

    with :ok <- BodyStore.move(tile.body_yaml_path, deleted_path),
         {:ok, _tile} <-
           tile
           |> Tile.changeset(%{deleted_at: timestamp, body_yaml_path: deleted_path})
           |> Repo.update() do
      :ok
    end
  end

  defp restore_body_path(%Tile{
         body_yaml_path: path,
         id: id,
         user_id: user_id,
         thread_id: thread_id
       }) do
    restored_path = BodyStore.canvas_body_path(user_id, thread_id, id)

    with :ok <- BodyStore.move(path, restored_path) do
      {:ok, restored_path}
    end
  end

  defp maybe_write_body(_path, :error), do: :ok
  defp maybe_write_body(path, {:ok, body}) when is_map(body), do: BodyStore.write_body(path, body)
  defp maybe_write_body(_path, {:ok, _body}), do: {:error, :invalid_body}

  defp authorize_scope(tile, attrs) do
    cond do
      Map.has_key?(attrs, :user_id) and attrs.user_id != tile.user_id ->
        {:error, :not_found}

      Map.has_key?(attrs, :thread_id) and attrs.thread_id != tile.thread_id ->
        {:error, :not_found}

      true ->
        :ok
    end
  end

  defp load_bodies(tiles) do
    tiles
    |> Enum.reduce_while([], fn tile, acc ->
      case load_body(tile) do
        {:ok, loaded} -> {:cont, [loaded | acc]}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:error, reason} -> {:error, reason}
      loaded -> {:ok, Enum.reverse(loaded)}
    end
  end

  defp load_body_result({:ok, %Tile{} = tile}), do: load_body(tile)
  defp load_body_result({:error, reason}), do: {:error, reason}

  defp load_body(%Tile{} = tile) do
    with {:ok, body} <- BodyStore.read_body(tile.body_yaml_path) do
      {:ok, %{tile | body: body}}
    end
  end

  defp maybe_live_only(query, true), do: query
  defp maybe_live_only(query, false), do: where(query, [record], is_nil(record.deleted_at))

  defp next_position(user_id, thread_id) do
    Tile
    |> where(
      [tile],
      tile.user_id == ^user_id and tile.thread_id == ^thread_id and is_nil(tile.deleted_at)
    )
    |> select([tile], max(tile.position))
    |> Repo.one()
    |> case do
      nil -> 0
      position -> position + 1
    end
  end

  defp max_tiles_per_thread do
    case Settings.get("workspace.canvas.max_tiles_per_thread") do
      {:ok, value} when is_integer(value) -> value
      _other -> @default_max_tiles
    end
  end

  defp normalize_attrs(attrs) do
    Map.new(attrs, fn
      {key, value} when is_binary(key) -> {String.to_atom(key), value}
      pair -> pair
    end)
  end

  defp normalize_kind(kind) when is_atom(kind), do: Atom.to_string(kind)
  defp normalize_kind(kind) when is_binary(kind), do: kind
  defp normalize_kind(kind), do: to_string(kind)

  defp required_string(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) and value != "" -> value
      value when is_atom(value) -> Atom.to_string(value)
      _other -> nil
    end
  end

  defp new_id(prefix), do: "#{prefix}_#{Ecto.UUID.generate()}"
end
