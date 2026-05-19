defmodule AllbertAssist.Workspace.Offline do
  @moduledoc """
  Server-side boundary for browser-originated workspace editor snapshots.

  The browser owns Yjs and IndexedDB. This module validates provenance and
  bounds, then stores opaque Yjs payloads plus human-readable snapshots.
  """

  alias AllbertAssist.Repo
  alias AllbertAssist.Settings
  alias AllbertAssist.Workspace.BodyStore
  alias AllbertAssist.Workspace.Canvas
  alias AllbertAssist.Workspace.Canvas.Revision
  alias AllbertAssist.Workspace.Canvas.Tile
  alias AllbertAssist.Workspace.Events

  @editable_kinds ~w[text markdown]
  @default_max_bytes 33_554_432
  @default_tile_body_max_bytes 65_536
  @attr_keys %{
    "tile_id" => :tile_id,
    "user_id" => :user_id,
    "thread_id" => :thread_id,
    "snapshot" => :snapshot,
    "update" => :update,
    "state_vector" => :state_vector,
    "base_revision_id" => :base_revision_id,
    "origin" => :origin,
    "max_bytes" => :max_bytes,
    "metadata" => :metadata,
    "revision_id" => :revision_id
  }

  @type record_result :: %{
          revision: Revision.t(),
          tile: Tile.t(),
          conflict_count: non_neg_integer(),
          conflict?: boolean()
        }

  @type conflict_summary :: %{
          conflict?: term(),
          conflict_count: term(),
          latest_revision_id: term(),
          previous_revision_id: term(),
          reconciled_at: term(),
          revert_revision_id: term()
        }

  @spec record_client_update(map()) :: {:ok, record_result()} | {:error, term()}
  def record_client_update(attrs) when is_map(attrs) do
    attrs = normalize_attrs(attrs)

    with {:ok, tile_id} <- required_string(attrs, :tile_id),
         {:ok, user_id} <- required_string(attrs, :user_id),
         {:ok, thread_id} <- required_string(attrs, :thread_id),
         {:ok, snapshot} <- required_binary(attrs, :snapshot),
         {:ok, tile} <- Canvas.get_tile(tile_id, user_id),
         :ok <- ensure_thread(tile, thread_id),
         :ok <- ensure_editable_tile(tile),
         {:ok, update} <- optional_base64(attrs, :update),
         {:ok, state_vector} <- optional_base64(attrs, :state_vector),
         :ok <- ensure_bounded(update, state_vector, snapshot, max_bytes(attrs)),
         :ok <- ensure_tile_body_size(tile, snapshot),
         {:ok, origin} <- origin(attrs, :browser) do
      record_snapshot(tile, %{
        base_revision_id: blank_to_nil(Map.get(attrs, :base_revision_id)),
        yjs_update: update,
        state_vector: state_vector,
        text_snapshot: snapshot,
        origin: origin,
        authored_by: user_id,
        metadata: Map.get(attrs, :metadata, %{})
      })
    end
  end

  def record_client_update(_attrs), do: {:error, :invalid_attrs}

  @spec latest_snapshot(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def latest_snapshot(tile_id, user_id) when is_binary(tile_id) and is_binary(user_id) do
    with {:ok, tile} <- Canvas.get_tile(tile_id, user_id),
         :ok <- ensure_editable_tile(tile) do
      {:ok, snapshot_for(tile)}
    end
  end

  @spec pending_conflict_summary(String.t(), String.t()) ::
          {:ok, conflict_summary()} | {:error, term()}
  def pending_conflict_summary(tile_id, user_id)
      when is_binary(tile_id) and is_binary(user_id) do
    with {:ok, tile} <- Canvas.get_tile(tile_id, user_id) do
      {:ok, conflict_summary(tile)}
    end
  end

  @spec revert_to_revision(map()) :: {:ok, record_result()} | {:error, term()}
  def revert_to_revision(attrs) when is_map(attrs) do
    attrs = normalize_attrs(attrs)

    with {:ok, tile_id} <- required_string(attrs, :tile_id),
         {:ok, revision_id} <- required_string(attrs, :revision_id),
         {:ok, user_id} <- required_string(attrs, :user_id),
         {:ok, tile} <- Canvas.get_tile(tile_id, user_id),
         :ok <- ensure_editable_tile(tile),
         {:ok, revision} <- get_revision(tile.id, revision_id),
         {:ok, snapshot} <- revision_snapshot(revision) do
      record_snapshot(tile, %{
        base_revision_id: tile.current_revision_id,
        yjs_update: nil,
        state_vector: nil,
        text_snapshot: snapshot,
        origin: "server",
        authored_by: user_id,
        metadata: %{reverted_to_revision_id: revision.id}
      })
    end
  end

  def revert_to_revision(_attrs), do: {:error, :invalid_attrs}

  defp record_snapshot(%Tile{} = tile, attrs) do
    revision_id = new_id("rev")
    snapshot_path = BodyStore.canvas_revision_path(tile.body_yaml_path, revision_id)
    conflict? = conflict?(tile.current_revision_id, attrs.base_revision_id)
    conflict_count = if conflict?, do: 1, else: 0
    body = snapshot_body(tile, attrs.text_snapshot)

    revision_attrs =
      Map.merge(attrs, %{
        id: revision_id,
        tile_id: tile.id,
        snapshot_yaml_path: snapshot_path,
        conflict_count: conflict_count
      })

    tile_metadata = tile_metadata(tile, revision_attrs, conflict?)

    with :ok <- BodyStore.write_body(snapshot_path, revision_body(revision_attrs)),
         :ok <- BodyStore.write_body(tile.body_yaml_path, body),
         {:ok, result} <-
           Repo.transaction(fn ->
             revision =
               %Revision{}
               |> Revision.changeset(Map.delete(revision_attrs, :metadata))
               |> Repo.insert!()

             updated_tile =
               tile
               |> Tile.changeset(%{current_revision_id: revision.id, metadata: tile_metadata})
               |> Repo.update!()
               |> Map.put(:body, body)

             %{
               revision: revision,
               tile: updated_tile,
               conflict_count: conflict_count,
               conflict?: conflict?
             }
           end) do
      Events.offline_reconciled(result.tile, result.revision, %{
        conflict_count: conflict_count,
        conflict?: conflict?
      })

      Events.tile_updated(result.tile, [:body, :current_revision_id, :metadata], %{
        revision_id: result.revision.id,
        conflict_count: conflict_count
      })

      {:ok, result}
    end
  rescue
    exception ->
      {:error, {exception.__struct__, Exception.message(exception)}}
  end

  defp get_revision(tile_id, revision_id) do
    case Repo.get_by(Revision, id: revision_id, tile_id: tile_id) do
      %Revision{} = revision -> {:ok, revision}
      nil -> {:error, :revision_not_found}
    end
  end

  defp revision_snapshot(%Revision{text_snapshot: snapshot}) when is_binary(snapshot) do
    {:ok, snapshot}
  end

  defp revision_snapshot(%Revision{snapshot_yaml_path: path}) when is_binary(path) do
    with {:ok, body} <- BodyStore.read_body(path),
         snapshot when is_binary(snapshot) <- Map.get(body, "text_snapshot") do
      {:ok, snapshot}
    else
      _other -> {:error, :revision_snapshot_missing}
    end
  end

  defp revision_snapshot(_revision), do: {:error, :revision_snapshot_missing}

  defp ensure_thread(%Tile{thread_id: thread_id}, thread_id), do: :ok
  defp ensure_thread(_tile, _thread_id), do: {:error, :not_found}

  defp ensure_editable_tile(%Tile{kind: kind, body: body, read_only: false})
       when kind in @editable_kinds do
    if fragment_body?(body), do: {:error, :read_only_fragment_tile}, else: :ok
  end

  defp ensure_editable_tile(%Tile{read_only: true}), do: {:error, :thread_completed}
  defp ensure_editable_tile(%Tile{}), do: {:error, :unsupported_tile_kind}

  defp fragment_body?(body) when is_map(body) do
    Map.has_key?(body, :surface) or Map.has_key?(body, "surface")
  end

  defp conflict?(current_revision_id, base_revision_id) do
    blank_to_nil(current_revision_id) != blank_to_nil(base_revision_id)
  end

  defp tile_metadata(tile, attrs, conflict?) do
    offline =
      %{
        "latest_revision_id" => attrs.id,
        "base_revision_id" => attrs.base_revision_id,
        "previous_revision_id" => tile.current_revision_id,
        "revert_revision_id" => if(conflict?, do: tile.current_revision_id),
        "conflict_count" => attrs.conflict_count,
        "conflict" => conflict?,
        "last_origin" => attrs.origin,
        "reconciled_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }
      |> maybe_put_reverted_to(attrs.metadata)

    tile.metadata
    |> Map.new()
    |> Map.put("offline", offline)
  end

  defp maybe_put_reverted_to(offline, metadata) when is_map(metadata) do
    case Map.get(metadata, :reverted_to_revision_id) ||
           Map.get(metadata, "reverted_to_revision_id") do
      revision_id when is_binary(revision_id) ->
        Map.put(offline, "reverted_to_revision_id", revision_id)

      _other ->
        offline
    end
  end

  defp maybe_put_reverted_to(offline, _metadata), do: offline

  defp revision_body(attrs) do
    %{
      text_snapshot: attrs.text_snapshot,
      origin: attrs.origin,
      base_revision_id: attrs.base_revision_id,
      conflict_count: attrs.conflict_count
    }
  end

  defp snapshot_body(%Tile{kind: "markdown", body: body}, snapshot) do
    body
    |> Map.new()
    |> Map.put("markdown", snapshot)
  end

  defp snapshot_body(%Tile{body: body}, snapshot) do
    body
    |> Map.new()
    |> Map.put("text", snapshot)
  end

  defp snapshot_for(%Tile{kind: "markdown", body: body}) do
    text_value(body, [:markdown, :text, :content, :snapshot])
  end

  defp snapshot_for(%Tile{body: body}) do
    text_value(body, [:text, :markdown, :content, :snapshot])
  end

  defp text_value(body, keys) do
    Enum.find_value(keys, "", fn key ->
      case Map.get(body, key) || Map.get(body, Atom.to_string(key)) do
        value when is_binary(value) -> value
        _other -> nil
      end
    end)
  end

  defp conflict_summary(%Tile{metadata: metadata}) when is_map(metadata) do
    offline = Map.get(metadata, "offline") || Map.get(metadata, :offline) || %{}

    %{
      conflict?: offline_value(offline, :conflict, false),
      conflict_count: offline_value(offline, :conflict_count, 0),
      latest_revision_id: offline_value(offline, :latest_revision_id),
      revert_revision_id: offline_value(offline, :revert_revision_id),
      previous_revision_id: offline_value(offline, :previous_revision_id),
      reconciled_at: offline_value(offline, :reconciled_at)
    }
  end

  defp offline_value(offline, key, fallback \\ nil) do
    Map.get(offline, Atom.to_string(key)) || Map.get(offline, key) || fallback
  end

  defp required_string(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, {:missing_required, key}}
    end
  end

  defp required_binary(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) -> {:ok, value}
      _other -> {:error, {:missing_required, key}}
    end
  end

  defp optional_base64(attrs, key) do
    case blank_to_nil(Map.get(attrs, key)) do
      nil -> {:ok, nil}
      value when is_binary(value) -> decode_base64(value, key)
      _other -> {:error, {:invalid_base64, key}}
    end
  end

  defp decode_base64(value, key) do
    case Base.decode64(value) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, {:invalid_base64, key}}
    end
  end

  defp ensure_bounded(update, state_vector, snapshot, max_bytes) do
    size = byte_size(update || "") + byte_size(state_vector || "") + byte_size(snapshot)

    if size <= max_bytes, do: :ok, else: {:error, :payload_too_large}
  end

  defp ensure_tile_body_size(%Tile{} = tile, snapshot) do
    if tile |> snapshot_body(snapshot) |> BodyStore.body_size_bytes() <= tile_body_max_bytes(),
      do: :ok,
      else: {:error, :tile_body_too_large}
  end

  defp max_bytes(attrs) do
    case Map.get(attrs, :max_bytes) do
      value when is_integer(value) and value > 0 -> value
      _other -> @default_max_bytes
    end
  end

  defp tile_body_max_bytes do
    case Settings.get("workspace.canvas.tile_body_max_bytes") do
      {:ok, value} when is_integer(value) -> value
      _other -> @default_tile_body_max_bytes
    end
  end

  defp origin(attrs, default) do
    origin = Map.get(attrs, :origin, default) |> to_string()

    if origin in Revision.origins(),
      do: {:ok, origin},
      else: {:error, :invalid_origin}
  end

  defp normalize_attrs(attrs) do
    Map.new(attrs, fn
      {key, value} when is_binary(key) -> {Map.get(@attr_keys, key, key), value}
      pair -> pair
    end)
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp new_id(prefix), do: "#{prefix}_#{Ecto.UUID.generate()}"
end
