defmodule AllbertAssist.Workspace do
  @moduledoc """
  Public facade for the workspace canvas and ephemeral surface substrate.

  Web-side surfaces call this facade instead of reaching into Canvas,
  Ephemeral, or Fragment internals.
  """

  alias AllbertAssist.Workspace.Canvas
  alias AllbertAssist.Workspace.Ephemeral
  alias AllbertAssist.Workspace.Fragment

  @spec canvas_tiles(String.t(), String.t()) :: {:ok, [Canvas.tile()]} | {:error, term()}
  defdelegate canvas_tiles(thread_id, user_id), to: Canvas, as: :tiles_for_thread

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

  @spec ephemeral_surfaces(String.t(), String.t()) ::
          {:ok, [Ephemeral.surface()]} | {:error, term()}
  defdelegate ephemeral_surfaces(thread_id, user_id), to: Ephemeral, as: :surfaces_for_thread

  @spec open_ephemeral(map()) :: {:ok, Ephemeral.surface()} | {:error, term()}
  defdelegate open_ephemeral(attrs), to: Ephemeral, as: :open

  @spec emit_fragment(Fragment.Envelope.t()) :: :ok | {:error, Fragment.error_reason()}
  defdelegate emit_fragment(envelope), to: Fragment, as: :emit
end
