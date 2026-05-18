defmodule AllbertAssist.Workspace do
  @moduledoc """
  Public facade for the workspace canvas and ephemeral surface substrate.

  Web-side surfaces call this facade instead of reaching into Canvas,
  Ephemeral, or Fragment internals.
  """

  alias AllbertAssist.Workspace.Canvas
  alias AllbertAssist.Workspace.Ephemeral
  alias AllbertAssist.Workspace.Fragment
  alias AllbertAssist.Workspace.Offline

  @spec canvas_tiles(String.t(), String.t()) :: {:ok, [Canvas.tile()]} | {:error, term()}
  defdelegate canvas_tiles(thread_id, user_id), to: Canvas, as: :tiles_for_thread

  @spec canvas_tiles(String.t(), String.t(), keyword()) ::
          {:ok, [Canvas.tile()]} | {:error, term()}
  defdelegate canvas_tiles(thread_id, user_id, opts), to: Canvas, as: :tiles_for_thread

  @spec get_tile(String.t(), String.t(), keyword()) :: {:ok, Canvas.tile()} | {:error, term()}
  defdelegate get_tile(tile_id, user_id, opts \\ []), to: Canvas

  @spec add_tile(map()) :: {:ok, Canvas.tile()} | {:error, term()}
  defdelegate add_tile(attrs), to: Canvas

  @spec update_tile(String.t(), map()) :: {:ok, Canvas.tile()} | {:error, term()}
  defdelegate update_tile(tile_id, attrs), to: Canvas

  @spec remove_tile(String.t(), String.t()) :: :ok | {:error, term()}
  defdelegate remove_tile(tile_id, user_id), to: Canvas

  @spec pin_tile(String.t(), String.t()) :: {:ok, Canvas.tile()} | {:error, term()}
  defdelegate pin_tile(tile_id, user_id), to: Canvas

  @spec unpin_tile(String.t(), String.t()) :: {:ok, Canvas.tile()} | {:error, term()}
  defdelegate unpin_tile(tile_id, user_id), to: Canvas

  @spec restore_tile(String.t(), String.t()) :: {:ok, Canvas.tile()} | {:error, term()}
  defdelegate restore_tile(tile_id, user_id), to: Canvas

  @spec purge_deleted_tiles(String.t(), DateTime.t()) :: {:ok, [Canvas.tile()]} | {:error, term()}
  defdelegate purge_deleted_tiles(user_id, before), to: Canvas, as: :purge_deleted_before

  @spec ephemeral_surfaces(String.t(), String.t()) ::
          {:ok, [Ephemeral.surface()]} | {:error, term()}
  defdelegate ephemeral_surfaces(thread_id, user_id), to: Ephemeral, as: :surfaces_for_thread

  @spec ephemeral_surfaces(String.t(), String.t(), keyword()) ::
          {:ok, [Ephemeral.surface()]} | {:error, term()}
  defdelegate ephemeral_surfaces(thread_id, user_id, opts),
    to: Ephemeral,
    as: :surfaces_for_thread

  @spec open_ephemeral(map()) :: {:ok, Ephemeral.surface()} | {:error, term()}
  defdelegate open_ephemeral(attrs), to: Ephemeral, as: :open

  @spec emit_fragment(Fragment.Envelope.t()) :: :ok | {:error, Fragment.error_reason()}
  defdelegate emit_fragment(envelope), to: Fragment, as: :emit

  @spec record_offline_update(map()) ::
          {:ok, Offline.record_result()} | {:error, term()}
  defdelegate record_offline_update(attrs), to: Offline, as: :record_client_update

  @spec latest_offline_snapshot(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  defdelegate latest_offline_snapshot(tile_id, user_id), to: Offline, as: :latest_snapshot

  @spec pending_offline_conflict_summary(String.t(), String.t()) ::
          {:ok, Offline.conflict_summary()} | {:error, term()}
  defdelegate pending_offline_conflict_summary(tile_id, user_id),
    to: Offline,
    as: :pending_conflict_summary

  @spec revert_tile_revision(map()) :: {:ok, Offline.record_result()} | {:error, term()}
  defdelegate revert_tile_revision(attrs), to: Offline, as: :revert_to_revision
end
