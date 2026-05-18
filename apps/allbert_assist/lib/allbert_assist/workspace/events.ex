defmodule AllbertAssist.Workspace.Events do
  @moduledoc false

  require Logger

  alias AllbertAssist.Security.Redactor
  alias AllbertAssist.SignalBus
  alias AllbertAssist.Surface
  alias AllbertAssist.Surface.Node
  alias AllbertAssist.Workspace.Canvas.Tile
  alias AllbertAssist.Workspace.Fragment
  alias AllbertAssist.Workspace.Fragment.Envelope
  alias AllbertAssist.Workspace.Fragment.SigningSecret
  alias Jido.Signal
  alias Jido.Signal.Bus

  @canvas_emitter "AllbertAssist.Workspace.Canvas"

  @spec tile_added(Tile.t(), map()) :: :ok
  def tile_added(%Tile{} = tile, metadata \\ %{}) do
    publish_tile_signal("allbert.workspace.tile.added", tile, metadata)
  end

  @spec tile_updated(Tile.t(), [atom() | String.t()], map()) :: :ok
  def tile_updated(%Tile{} = tile, changed_fields, metadata \\ %{}) do
    metadata =
      metadata
      |> Map.new()
      |> Map.put(:changed_fields, Enum.map(changed_fields, &normalize_field/1))

    publish_tile_signal("allbert.workspace.tile.updated", tile, metadata)
  end

  @spec tile_removed(Tile.t(), atom(), map()) :: :ok
  def tile_removed(%Tile{} = tile, reason, metadata \\ %{}) do
    metadata =
      metadata
      |> Map.new()
      |> Map.put(:removed_reason, reason)

    publish_tile_signal("allbert.workspace.tile.removed", tile, metadata)
  end

  @spec canvas_eviction_badge(Tile.t(), non_neg_integer()) :: :ok
  def canvas_eviction_badge(%Tile{} = tile, archived_count \\ 1) do
    message = "#{archived_count} older tile(s) archived"

    attrs = %{
      surface: eviction_badge_surface(message),
      emitter_id: @canvas_emitter,
      user_id: tile.user_id,
      thread_id: tile.thread_id,
      scope: :canvas,
      kind: :badge_strip,
      emitted_at: DateTime.utc_now(),
      metadata: %{
        placement: "canvas_header",
        archived_count: archived_count,
        removed_tile_id: tile.id,
        body: message
      }
    }

    with secret <- SigningSecret.ensure!(),
         {:ok, envelope} <- Envelope.sign(attrs, secret),
         :ok <- Fragment.emit(envelope) do
      :ok
    else
      {:error, reason} ->
        Logger.debug("workspace eviction badge skipped reason=#{inspect(reason)}")
        :ok
    end
  rescue
    exception ->
      Logger.debug("workspace eviction badge failed reason=#{Exception.message(exception)}")
      :ok
  catch
    :exit, reason ->
      Logger.debug("workspace eviction badge unavailable reason=#{inspect(reason)}")
      :ok
  end

  defp publish_tile_signal(type, %Tile{} = tile, metadata) do
    data =
      %{
        tile_id: tile.id,
        user_id: tile.user_id,
        thread_id: tile.thread_id,
        kind: tile.kind,
        position: tile.position,
        pinned: tile.pinned,
        body_yaml_path: tile.body_yaml_path,
        metadata: metadata
      }
      |> Redactor.redact()

    case Signal.new(type, data,
           source: "/allbert/workspace/canvas/#{tile.id}",
           subject: tile.user_id
         ) do
      {:ok, signal} -> publish(signal)
      {:error, reason} -> Logger.debug("workspace tile signal skipped reason=#{inspect(reason)}")
    end

    :ok
  end

  defp publish(%Signal{} = signal) do
    case Bus.publish(SignalBus, [signal]) do
      {:ok, _recorded} ->
        :ok

      {:error, reason} ->
        Logger.debug(
          "workspace tile signal publish skipped type=#{signal.type} reason=#{inspect(reason)}"
        )

        :ok
    end
  rescue
    exception ->
      Logger.debug(
        "workspace tile signal publish failed type=#{signal.type} reason=#{Exception.message(exception)}"
      )

      :ok
  catch
    :exit, reason ->
      Logger.debug(
        "workspace tile signal publish unavailable type=#{signal.type} reason=#{inspect(reason)}"
      )

      :ok
  end

  defp eviction_badge_surface(message) do
    %Surface{
      id: :workspace_canvas_eviction_badge,
      app_id: :allbert,
      label: "Canvas Archive Notice",
      path: "/agent",
      kind: :canvas,
      status: :available,
      fallback_text: message,
      nodes: [
        %Node{
          id: "canvas-archive-badge",
          component: :status_badge,
          props: %{
            title: message,
            body: "View archived tiles with mix allbert.workspace canvas list --include-deleted.",
            status: "info"
          }
        }
      ]
    }
  end

  defp normalize_field(field) when is_atom(field), do: field
  defp normalize_field(field) when is_binary(field), do: String.to_atom(field)
  defp normalize_field(field), do: field |> to_string() |> String.to_atom()
end
